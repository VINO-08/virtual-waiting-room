import json
import os
from datetime import datetime, timezone

import boto3
from boto3.dynamodb.conditions import Attr

dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(os.environ.get("SESSIONS_TABLE", "QueueSessions"))


def get_waiting_sessions():
    items = []
    kwargs = {"FilterExpression": Attr("status").eq("WAITING")}
    while True:
        result = table.scan(**kwargs)
        items.extend(result.get("Items", []))
        last_key = result.get("LastEvaluatedKey")
        if not last_key:
            break
        kwargs["ExclusiveStartKey"] = last_key
    return items


def lambda_handler(event, context):
    count = int((event or {}).get("admit_count", 0))
    if count <= 0:
        return {"admitted": 0, "message": "admit_count must be 1 or more"}

    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    waiting = sorted(get_waiting_sessions(), key=lambda item: item["joined_at"])
    to_admit = waiting[:count]

    for item in to_admit:
        table.update_item(
            Key={"session_id": item["session_id"]},
            UpdateExpression="SET #s = :admitted, admitted_at = :now",
            ExpressionAttributeNames={"#s": "status"},
            ExpressionAttributeValues={":admitted": "ADMITTED", ":now": now},
        )

    return {
        "admitted": len(to_admit),
        "session_ids": [item["session_id"] for item in to_admit],
        "still_waiting": len(waiting) - len(to_admit),
    }
