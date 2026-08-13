import os
import time

import boto3

# CloudWatch Logs API를 호출하기 위한 boto3 클라이언트 생성
logs_client = boto3.client("logs")

RETENTION_DAYS = int(os.environ.get("RETENTION_DAYS", "30"))
LOG_GROUP_PREFIX = os.environ.get("LOG_GROUP_PREFIX", "/aws/ecs/")


def handler(event, context):
    cutoff_ms = int((time.time() - RETENTION_DAYS * 86400) * 1000)
    deleted_streams = 0   # 삭제한 로그 스트림 개수 (통계용)
    scanned_groups = 0    # 검사한 로그 그룹 개수 (통계용)

    # paginator를 쓰는 이유: 로그 그룹이 많으면 한 번의 API 호출로 다 못 가져오므로 자동으로 페이지를 넘겨가며 전부 가져오기 위함
    group_paginator = logs_client.get_paginator("describe_log_groups")
    for group_page in group_paginator.paginate(logGroupNamePrefix=LOG_GROUP_PREFIX):
        for log_group in group_page["logGroups"]:
            scanned_groups += 1
            deleted_streams += _cleanup_log_group(log_group["logGroupName"], cutoff_ms)

    result = {
        "scannedGroups": scanned_groups,
        "deletedStreams": deleted_streams,
        "retentionDays": RETENTION_DAYS,
    }
    print(result)
    return result


def _cleanup_log_group(log_group_name, cutoff_ms):
    deleted = 0
    stream_paginator = logs_client.get_paginator("describe_log_streams")

    for stream_page in stream_paginator.paginate(
        logGroupName=log_group_name,
        orderBy="LastEventTime",
    ):
        for stream in stream_page["logStreams"]:
            last_event_ms = stream.get("lastEventTimestamp", stream.get("creationTime", 0))
            if last_event_ms >= cutoff_ms:
                # LastEventTime 순으로 정렬되어 있으므로 이 지점부터는 전부 최신 로그
                return deleted

            logs_client.delete_log_stream(
                logGroupName=log_group_name,
                logStreamName=stream["logStreamName"],
            )
            deleted += 1

    return deleted
