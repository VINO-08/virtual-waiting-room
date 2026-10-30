import json
import os
from datetime import datetime, timedelta, timezone

import boto3
from boto3.dynamodb.conditions import Attr

lambda_client = boto3.client("lambda")
cloudwatch = boto3.client("cloudwatch")
dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(os.environ.get("SESSIONS_TABLE", "QueueSessions"))

BACKEND_FUNCTION = os.environ["BACKEND_FUNCTION"]
ADMISSION_FUNCTION = os.environ["ADMISSION_FUNCTION"]
SESSION_SECONDS = int(os.environ.get("SESSION_SECONDS", "120"))

CONTROL_KEY = {"session_id": "__CONTROL__"}
START_RATE = 2
MIN_RATE = 1
MAX_RATE = 20
INCREASE_STEP = 2
METRIC_NAMESPACE = "VirtualWaitingRoom"


def call_lambda(function_name, payload):
    response = lambda_client.invoke(
        FunctionName=function_name,
        Payload=json.dumps(payload).encode("utf-8"),
    )
    return json.loads(response["Payload"].read())


def get_rate():
    item = table.get_item(Key=CONTROL_KEY).get("Item")
    if item:
        return int(item["admission_rate"])
    return START_RATE


def save_rate(rate):
    table.put_item(Item={**CONTROL_KEY, "admission_rate": rate})


def scan_all(condition):
    items = []
    kwargs = {"FilterExpression": condition}
    while True:
        result = table.scan(**kwargs)
        items.extend(result.get("Items", []))
        last_key = result.get("LastEvaluatedKey")
        if not last_key:
            break
        kwargs["ExclusiveStartKey"] = last_key
    return items


def complete_expired_sessions():
    cutoff = (datetime.now(timezone.utc) - timedelta(seconds=SESSION_SECONDS)).strftime(
        "%Y-%m-%dT%H:%M:%SZ"
    )
    condition = Attr("status").eq("ADMITTED") & (
        Attr("admitted_at").not_exists() | Attr("admitted_at").lt(cutoff)
    )
    expired = scan_all(condition)
    for item in expired:
        table.update_item(
            Key={"session_id": item["session_id"]},
            UpdateExpression="SET #s = :done",
            ExpressionAttributeNames={"#s": "status"},
            ExpressionAttributeValues={":done": "COMPLETED"},
        )
    return len(expired)


def publish_metrics(queue_size, backend_load, rate, latency_ms):
    try:
        cloudwatch.put_metric_data(
            Namespace=METRIC_NAMESPACE,
            MetricData=[
                {"MetricName": "QueueSize", "Value": queue_size, "Unit": "Count"},
                {"MetricName": "BackendLoad", "Value": backend_load, "Unit": "Count"},
                {"MetricName": "AdmissionRate", "Value": rate, "Unit": "Count"},
                {"MetricName": "BackendLatencyMs", "Value": latency_ms, "Unit": "Milliseconds"},
            ],
        )
    except Exception as error:
        print("Could not publish metrics:", error)


def lambda_handler(event, context):
    completed = complete_expired_sessions()

    backend = call_lambda(BACKEND_FUNCTION, {})
    old_rate = get_rate()

    if backend["health"] == "HEALTHY":
        new_rate = min(MAX_RATE, old_rate + INCREASE_STEP)
    elif backend["health"] == "STRESSED":
        new_rate = old_rate
    else:
        new_rate = max(MIN_RATE, old_rate // 2)

    save_rate(new_rate)

    waiting_before = len(scan_all(Attr("status").eq("WAITING")))
    headroom = max(0, backend["capacity"] - backend["load"])
    admit_count = min(new_rate, headroom)

    admitted = 0
    if admit_count > 0:
        result = call_lambda(ADMISSION_FUNCTION, {"admit_count": admit_count})
        admitted = result.get("admitted", 0)

    queue_size = max(0, waiting_before - admitted)
    publish_metrics(queue_size, backend["load"] + admitted, new_rate, backend["latency_ms"])

    return {
        "completed": completed,
        "backend_health": backend["health"],
        "backend_load": backend["load"],
        "old_rate": old_rate,
        "new_rate": new_rate,
        "headroom": headroom,
        "admitted": admitted,
        "queue_size": queue_size,
    }
