# Virtual Waiting Room for Flash-Traffic Events

A serverless, event-driven waiting room on AWS. It protects a website's backend from sudden traffic spikes (ticket sales, product launches, limited offers, exam registrations). An **adaptive throttler** decides how many waiting users to let in, based on how healthy the backend is.

## The idea in simple words

When thousands of people open a website at the same moment, the website can crash. This project puts people in a line and lets them in a few at a time. A smart "doorman" (the adaptive throttler) checks the backend every minute. It lets in more people when the backend is healthy, and fewer when it is struggling.

## How it works

1. A user joins: `POST /join` goes through API Gateway to the Join Lambda, which puts the user in an SQS FIFO queue and returns a ticket (session ID).
2. The Queue Processor Lambda saves each user in DynamoDB with the status `WAITING`.
3. The user checks their place with `GET /status/{session_id}`. The Status Lambda returns the status and the queue position.
4. Every minute, an EventBridge schedule runs the **adaptive throttler** Lambda. It:
   - marks users who have been inside for 2 minutes as `COMPLETED`, which frees up room;
   - asks the backend simulator how healthy it is;
   - changes the admission rate: +2 if `HEALTHY`, unchanged if `STRESSED`, halved if `OVERLOADED` (minimum 1, maximum 20);
   - never admits more users than the backend has room for;
   - calls the Admission Lambda, which moves the oldest `WAITING` users to `ADMITTED`;
   - sends its numbers to CloudWatch.
5. The **backend simulator** is a Lambda that pretends to be a protected website with room for 10 users. Its latency rises, and it starts to fail, as more users are inside. It reports `HEALTHY`, `STRESSED` or `OVERLOADED`.
6. A CloudWatch dashboard draws four custom metrics: QueueSize, BackendLoad, AdmissionRate and BackendLatencyMs.
7. A simple web page (`frontend/index.html`) lets a user press Join and see their place in line.

## AWS services used

API Gateway, Lambda (Python 3.12), SQS FIFO, DynamoDB, EventBridge, CloudWatch (custom metrics and dashboard), IAM and S3. Everything is created with Terraform in the `ap-south-1` (Mumbai) region.

## Project structure

- `terraform/main.tf` - all the AWS resources
- `terraform/lambda/join_lambda.py` - joins the waiting room
- `terraform/lambda/lambda_function.py` - Queue Processor, saves users in DynamoDB
- `terraform/lambda/status_lambda.py` - returns status and queue position
- `terraform/lambda/admission_lambda.py` - lets in the oldest waiting users
- `terraform/lambda/backend_lambda.py` - protected backend simulator
- `terraform/lambda/throttler_lambda.py` - the adaptive throttler
- `frontend/index.html` - the web page

## What was tested

- A single join worked through API Gateway, the queue and DynamoDB.
- Queue positions were correct and moved forward as users were admitted.
- Forty simulated users joined at the same moment. The backend never had more than 10 users inside, and the admission rate fell from 20 to about 5 within a minute. All users were served in waves.
- The throttler ran by itself every minute, and finished every test user without any manual step.

## How to deploy

You need an AWS account, the AWS CLI (configured) and Terraform. From the `terraform` folder:

    terraform init
    terraform plan
    terraform apply

The web page has the API address written near the top of `frontend/index.html` (`const API`). Change it to your own API address. The Terraform file also contains CloudFront resources. On new AWS accounts, AWS may refuse them until the account is verified (we received a 403 error), so remove them if you only want the waiting room itself.

## Limitations and future work

- The backend is a simulation, not a real website.
- The admission rate keeps rising while nobody is waiting. It should only rise when users are waiting.
- CloudFront hosting is waiting for AWS account verification.
- No bot protection or login yet.
- CI/CD (automatic deployment) is planned.
