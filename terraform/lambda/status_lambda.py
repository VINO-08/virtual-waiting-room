import json
import os

import boto3
from boto3.dynamodb.conditions import Attr

dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(os.environ.get("SESSIONS_TABLE", "QueueSessions"))


def build_response(status_code, body):
    return {
        "statusCode": status_code,
        "headers": {"Content-Type": "application/json", "Access-Control-Allow-Origin": "*"},
        "body": json.dumps(body),
    }


def count_waiting_before(joined_at):
    count = 0
    kwargs = {
        "FilterExpression": Attr("status").eq("WAITING") & Attr("joined_at").lt(joined_at)
    }
    while True:
        result = table.scan(**kwargs)
        count += len(result.get("Items", []))
        last_key = result.get("LastEvaluatedKey")
        if not last_key:
            break
        kwargs["ExclusiveStartKey"] = last_key
    return count


def lambda_handler(event, context):
    session_id = (event.get("pathParameters") or {}).get("session_id")
    if not session_id:
        return build_response(400, {"message": "session_id is required"})

    item = table.get_item(Key={"session_id": session_id}).get("Item")
    if not item:
        return build_response(404, {"message": "Session not found"})

    status = item.get("status", "UNKNOWN")
    body = {
        "session_id": session_id,
        "status": status,
        "joined_at": item.get("joined_at"),
    }

    if status == "WAITING":
        body["queue_position"] = count_waiting_before(item["joined_at"]) + 1

    return build_response(200, body)

