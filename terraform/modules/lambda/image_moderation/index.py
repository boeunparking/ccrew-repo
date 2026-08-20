import json
import os

import boto3

rekognition_client = boto3.client("rekognition")
s3_client = boto3.client("s3")

MIN_CONFIDENCE = float(os.environ.get("MIN_CONFIDENCE", "75"))


def handler(event, context):
    # SQS 배치 중 일부만 실패해도 성공한 메시지까지 재시도되지 않도록
    # 실패한 messageId만 개별로 보고한다 (event_source_mapping의 ReportBatchItemFailures).
    batch_item_failures = []

    for record in event.get("Records", []):
        try:
            _process_record(record)
        except Exception as exc:  # noqa: BLE001 - 실패는 SQS 재시도/DLQ에 맡기고 여기선 기록만
            print(f"moderation failed for message {record['messageId']}: {exc}")
            batch_item_failures.append({"itemIdentifier": record["messageId"]})

    return {"batchItemFailures": batch_item_failures}


def _process_record(record):
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
