import json
import boto3

dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table("QueueSessions")


def lambda_handler(event, context):

    for record in event["Records"]:

        message = json.loads(record["body"])

        session_id = message["session_id"]
        joined_at = message["joined_at"]

        table.put_item(
            Item={
                "session_id": session_id,
                "joined_at": joined_at,
                "status": "WAITING",
                "queue_position": 0
            }
        )

        print(f"Saved session {session_id} to DynamoDB")

    return {
        "statusCode": 200,
        "body": json.dumps({
            "message": "Queue session saved successfully"
        })
    }
