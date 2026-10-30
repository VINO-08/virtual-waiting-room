import json
import os

import boto3
from boto3.dynamodb.conditions import Attr

dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(os.environ.get("SESSIONS_TABLE", "QueueSessions"))

CAPACITY = int(os.environ.get("BACKEND_CAPACITY", "10"))
BASE_LATENCY_MS = 100


def count_admitted():
    count = 0
    kwargs = {"FilterExpression": Attr("status").eq("ADMITTED")}
    while True:
        result = table.scan(**kwargs)
        count += len(result.get("Items", []))
        last_key = result.get("LastEvaluatedKey")
        if not last_key:
            break
        kwargs["ExclusiveStartKey"] = last_key
    return count


def lambda_handler(event, context):
    load = count_admitted()
    usage = load / CAPACITY

    latency_ms = int(BASE_LATENCY_MS * (1 + usage * usage * 4))
    if usage <= 0.8:
        error_rate = 0.0
    else:
        error_rate = round(min(1.0, (usage - 0.8) * 2.5), 2)

    if usage < 0.7:
        health = "HEALTHY"
    elif usage < 1.0:
        health = "STRESSED"
    else:
        health = "OVERLOADED"

    return {
        "load": load,
        "capacity": CAPACITY,
        "latency_ms": latency_ms,
        "error_rate": error_rate,
        "health": health,
    }
