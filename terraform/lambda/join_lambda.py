import json
import os
import uuid
from datetime import datetime, timezone

import boto3

sqs = boto3.client("sqs")
QUEUE_URL = os.environ["WAITING_ROOM_QUEUE_URL"]


def lambda_handler(event, context):
    session_id = str(uuid.uuid4())
    joined_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    message = {
        "session_id": session_id,
        "joined_at": joined_at,
    }

    sqs.send_message(
        QueueUrl=QUEUE_URL,
        MessageBody=json.dumps(message),
        MessageGroupId="waiting-room",
    )

    return {
        "statusCode": 200,
        "headers": {
            "Content-Type": "application/json",
            "Access-Control-Allow-Origin": "*",
        },
        "body": json.dumps({
            "session_id": session_id,
            "joined_at": joined_at,
            "status": "WAITING",
            "message": "You have joined the waiting room",
        }),
    }

