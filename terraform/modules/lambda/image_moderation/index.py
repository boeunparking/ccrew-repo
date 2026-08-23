import json
import os

import boto3
import pymysql

rekognition_client = boto3.client("rekognition")
s3_client = boto3.client("s3")
secretsmanager_client = boto3.client("secretsmanager")
ses_client = boto3.client("sesv2")

MIN_CONFIDENCE = float(os.environ.get("MIN_CONFIDENCE", "75"))

DB_HOST = os.environ.get("DB_HOST")
DB_PORT = int(os.environ.get("DB_PORT", "3306"))
DB_NAME = os.environ.get("DB_NAME", "cloud_duck")
DB_SECRET_ARN = os.environ.get("DB_SECRET_ARN")

SES_FROM_ADDRESS = os.environ.get("SES_FROM_ADDRESS", "noreply@cloudduck.cloud")

# 소셜 로그인에서 이메일을 못 받은 계정에 붙는 자리표시자 도메인 (web/src/oauth.js,
# batch/src/jobs.js의 NO_EMAIL_DOMAIN과 동일). MX 레코드가 없어 보내면 100% 하드
# 바운스이고, SES는 바운스율이 높아지면 발송 자체를 정지시키므로 아예 시도하지 않는다.
NO_EMAIL_DOMAIN = "@no-email.cloudduck.cloud"

_db_secret = None  # 콜드 스타트당 한 번만 조회 (Secrets Manager 호출/과금 절약)


def handler(event, context):
    # SQS 배치 중 일부만 실패해도 성공한 메시지까지 재시도되지 않도록
    # 실패한 messageId만 개별로 보고한다 (event_source_mapping의 ReportBatchItemFailures).
    batch_item_failures = []

    # DB 연결은 이 배치에서 실제로 REJECTED가 나올 때 첫 필요 시점에 딱 한 번만 연다.
    # 부팅 시점에 미리 열면 RDS 접속 장애 하나가 이 배치의 APPROVED 메시지까지
    # 전부 실패로 만들어버린다 — 지연 연결로 그 메시지들은 정상 처리되게 한다.
    db_conn_holder = {"conn": None}

    try:
        for record in event.get("Records", []):
            try:
                _process_record(record, db_conn_holder)
            except Exception as exc:  # noqa: BLE001 - 실패는 SQS 재시도/DLQ에 맡기고 여기선 기록만
                print(f"moderation failed for message {record['messageId']}: {exc}")
                batch_item_failures.append({"itemIdentifier": record["messageId"]})
    finally:
        if db_conn_holder["conn"]:
            db_conn_holder["conn"].close()

    return {"batchItemFailures": batch_item_failures}


def _process_record(record, db_conn_holder):
    detail = json.loads(record["body"])["detail"]
    bucket = detail["bucket"]["name"]
    key = detail["object"]["key"]

    response = rekognition_client.detect_moderation_labels(
        Image={"S3Object": {"Bucket": bucket, "Name": key}},
        MinConfidence=MIN_CONFIDENCE,
    )
    labels = response.get("ModerationLabels", [])
    status = "REJECTED" if labels else "APPROVED"
    label_names = ",".join(sorted({label["Name"] for label in labels}))[:250]

    s3_client.put_object_tagging(
        Bucket=bucket,
        Key=key,
        Tagging={
            "TagSet": [
                {"Key": "moderation-status", "Value": status},
                {"Key": "moderation-labels", "Value": label_names},
            ]
        },
    )

    print(f"{key}: {status} ({label_names or 'clean'})")

    # APPROVED는 이미 공개 상태인 정상 이미지라 추가로 손댈 게 없다 — S3 태그로 충분하다.
    if status != "REJECTED":
        return

    if db_conn_holder["conn"] is None:
        db_conn_holder["conn"] = _connect_db()
    if db_conn_holder["conn"] is not None:
        _handle_rejected(key, label_names, db_conn_holder["conn"])


def _handle_rejected(key, label_names, db_conn):
    """
    REJECTED 후속 처리: DB에 반영해 경매를 자동 비공개하고 판매자에게 알린다.

    이미지 업로드(S3 presign)는 경매 생성보다 먼저 일어나므로, 이 시점에 아직
    auction_images 행이 없을 수 있다 — 그래서 판정 결과를 image_key 하나로 독립적으로
    남겨두고(image_moderation_rejections), 나중에 경매가 만들어질 때 web(store.js
    createAuction)이 그걸 조회해 반영한다. 이미 경매가 만들어져 있는 경우를 위해
    auction_images/auctions도 best-effort로 같이 갱신한다(없으면 0행 영향, 무해).
    """
    with db_conn.cursor() as cur:
        cur.execute(
            """
            INSERT INTO image_moderation_rejections (image_key, labels, rejected_at)
            VALUES (%s, %s, NOW())
            ON DUPLICATE KEY UPDATE labels = VALUES(labels), rejected_at = VALUES(rejected_at)
            """,
            (key, label_names),
        )

        cur.execute(
            """
            UPDATE auction_images ai
            JOIN auctions a ON a.id = ai.auction_id
            SET ai.moderation_status = 'REJECTED',
                ai.moderation_labels = %s,
                ai.moderated_at = NOW(),
                a.hidden_at = COALESCE(a.hidden_at, NOW()),
                a.hidden_reason = COALESCE(a.hidden_reason, '업로드 이미지가 자동 검수에서 반려되었습니다')
            WHERE ai.image_key = %s
            """,
            (label_names, key),
        )
    db_conn.commit()

    _notify_seller(key, label_names, db_conn)


def _notify_seller(key, label_names, db_conn):
    # 업로드 키 형식: auctions/{userId}/{timestamp}-{uuid}.{ext} (web/src/routes/uploadRoutes.js)
    parts = key.split("/")
    if len(parts) < 2:
        print(f"{key}: 업로드 키 형식이 아니라 판매자를 알 수 없음 — 알림 건너뜀")
        return
    user_id = parts[1]

    with db_conn.cursor() as cur:
        cur.execute("SELECT email FROM users WHERE id = %s", (user_id,))
        row = cur.fetchone()

    if not row or not row[0]:
        print(f"{key}: 판매자 이메일을 찾을 수 없음 — 알림 건너뜀")
        return

    email = row[0]
    if email.endswith(NO_EMAIL_DOMAIN):
        print(f"{key}: 판매자에게 이메일이 없음 — 알림 건너뜀")
        return

    try:
        ses_client.send_email(
            FromEmailAddress=SES_FROM_ADDRESS,
            Destination={"ToAddresses": [email]},
            Content={
                "Simple": {
                    "Subject": {"Data": "[CloudDuck] 업로드하신 이미지가 반려되었습니다"},
                    "Body": {
                        "Text": {
                            "Data": (
                                "업로드하신 이미지가 자동 검수에서 부적절한 콘텐츠로 판정되어 "
                                "반려되었습니다.\n"
                                f"사유: {label_names or '정책 위반'}\n\n"
                                "해당 이미지가 포함된 경매는 비공개 처리되었습니다. "
                                "다른 이미지로 교체 후 다시 등록해 주세요."
                            )
                        }
                    },
                }
            },
        )
        print(f"{key}: 반려 메일 발송 완료 → {email}")
    except Exception as exc:  # noqa: BLE001 - 메일 실패로 전체 판정 처리를 실패시키지 않는다
        print(f"{key}: 반려 메일 발송 실패: {exc}")


def _connect_db():
    if not DB_HOST or not DB_SECRET_ARN:
        print("DB_HOST/DB_SECRET_ARN이 설정되지 않음 — 후속 처리(DB 반영/메일) 없이 태깅만 수행")
        return None

    global _db_secret
    if _db_secret is None:
        secret = secretsmanager_client.get_secret_value(SecretId=DB_SECRET_ARN)
        _db_secret = json.loads(secret["SecretString"])

    return pymysql.connect(
        host=DB_HOST,
        port=DB_PORT,
        user=_db_secret["username"],
        password=_db_secret["password"],
        database=DB_NAME,
        autocommit=False,
        connect_timeout=10,
    )
