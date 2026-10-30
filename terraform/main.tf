terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }

    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }

  required_version = ">= 1.6.0"
}

provider "aws" {
  region = "ap-south-1"
}

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda/lambda_function.py"
  output_path = "${path.module}/lambda/lambda_function.zip"
}

data "archive_file" "join_lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda/join_lambda.py"
  output_path = "${path.module}/lambda/join_lambda.zip"
}

resource "aws_dynamodb_table" "queue_sessions" {
  name         = "QueueSessions"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "session_id"

  attribute {
    name = "session_id"
    type = "S"
  }
}

resource "aws_sqs_queue" "waiting_room" {
  name                        = "waiting-room.fifo"
  fifo_queue                  = true
  content_based_deduplication = true
}

resource "aws_iam_role" "lambda_role" {
  name = "virtual-waiting-room-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"

    Statement = [{
      Effect = "Allow"

      Principal = {
        Service = "lambda.amazonaws.com"
      }

      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic_execution" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_lambda_function" "queue_processor" {
  function_name = "virtual-waiting-room-queue-processor"

  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  handler = "lambda_function.lambda_handler"
  runtime = "python3.12"

  role = aws_iam_role.lambda_role.arn
}

resource "aws_lambda_function" "join" {
  function_name = "virtual-waiting-room-join"

  filename         = data.archive_file.join_lambda_zip.output_path
  source_code_hash = data.archive_file.join_lambda_zip.output_base64sha256

  handler = "join_lambda.lambda_handler"
  runtime = "python3.12"

  role = aws_iam_role.lambda_role.arn

  environment {
    variables = {
      WAITING_ROOM_QUEUE_URL = aws_sqs_queue.waiting_room.url
    }
  }
}
resource "aws_iam_role_policy" "lambda_sqs_access" {
  name = "virtual-waiting-room-lambda-sqs-access"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"

    Statement = [{
      Effect = "Allow"

      Action = [
        "sqs:ReceiveMessage",
        "sqs:DeleteMessage",
        "sqs:GetQueueAttributes",
        "sqs:ChangeMessageVisibility"
      ]

      Resource = aws_sqs_queue.waiting_room.arn
    }]
  })
}

resource "aws_iam_role_policy" "lambda_sqs_send" {
  name = "virtual-waiting-room-lambda-sqs-send"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"

    Statement = [{
      Effect   = "Allow"
      Action   = ["sqs:SendMessage"]
      Resource = aws_sqs_queue.waiting_room.arn
    }]
  })
}
resource "aws_lambda_event_source_mapping" "sqs_to_lambda" {
  event_source_arn = aws_sqs_queue.waiting_room.arn
  function_name    = aws_lambda_function.queue_processor.arn

  batch_size = 1
  enabled    = true
}
resource "aws_iam_role_policy" "lambda_dynamodb_access" {
  name = "virtual-waiting-room-lambda-dynamodb-access"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"

    Statement = [{
      Effect = "Allow"

      Action = [
        "dynamodb:PutItem",
        "dynamodb:GetItem",
        "dynamodb:UpdateItem",
          "dynamodb:Scan"
      ]

      Resource = aws_dynamodb_table.queue_sessions.arn
    }]
  })
}
resource "aws_api_gateway_rest_api" "waiting_room_api" {
  name = "virtual-waiting-room-api"

  description = "API for the Virtual Waiting Room"
}
resource "aws_api_gateway_resource" "join" {
  rest_api_id = aws_api_gateway_rest_api.waiting_room_api.id
  parent_id   = aws_api_gateway_rest_api.waiting_room_api.root_resource_id
  path_part   = "join"
}

resource "aws_api_gateway_method" "join_post" {
  rest_api_id   = aws_api_gateway_rest_api.waiting_room_api.id
  resource_id   = aws_api_gateway_resource.join.id
  http_method   = "POST"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "join_post" {
  rest_api_id = aws_api_gateway_rest_api.waiting_room_api.id
  resource_id = aws_api_gateway_resource.join.id
  http_method = aws_api_gateway_method.join_post.http_method

  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.join.invoke_arn
}

resource "aws_api_gateway_deployment" "waiting_room_api" {
  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_integration.join_post.id,
      aws_api_gateway_integration.status_get.id,
      aws_api_gateway_method.status_get.id,
      aws_api_gateway_resource.status_session.id,
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }

  rest_api_id = aws_api_gateway_rest_api.waiting_room_api.id

  depends_on = [
    aws_api_gateway_integration.join_post
  ]
}

resource "aws_api_gateway_stage" "waiting_room_api" {
  rest_api_id   = aws_api_gateway_rest_api.waiting_room_api.id
  deployment_id = aws_api_gateway_deployment.waiting_room_api.id
  stage_name    = "dev"
}

resource "aws_lambda_permission" "api_gateway_join" {
  statement_id  = "AllowAPIGatewayInvokeJoin"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.join.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.waiting_room_api.execution_arn}/*/*"
}

data "archive_file" "status_lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda/status_lambda.py"
  output_path = "${path.module}/lambda/status_lambda.zip"
}

resource "aws_lambda_function" "status" {
  function_name = "virtual-waiting-room-status"

  filename         = data.archive_file.status_lambda_zip.output_path
  source_code_hash = data.archive_file.status_lambda_zip.output_base64sha256

  handler = "status_lambda.lambda_handler"
  runtime = "python3.12"

  role = aws_iam_role.lambda_role.arn

  environment {
    variables = {
      SESSIONS_TABLE = aws_dynamodb_table.queue_sessions.name
    }
  }
}

resource "aws_api_gateway_resource" "status" {
  rest_api_id = aws_api_gateway_rest_api.waiting_room_api.id
  parent_id   = aws_api_gateway_rest_api.waiting_room_api.root_resource_id
  path_part   = "status"
}

resource "aws_api_gateway_resource" "status_session" {
  rest_api_id = aws_api_gateway_rest_api.waiting_room_api.id
  parent_id   = aws_api_gateway_resource.status.id
  path_part   = "{session_id}"
}

resource "aws_api_gateway_method" "status_get" {
  rest_api_id   = aws_api_gateway_rest_api.waiting_room_api.id
  resource_id   = aws_api_gateway_resource.status_session.id
  http_method   = "GET"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "status_get" {
  rest_api_id = aws_api_gateway_rest_api.waiting_room_api.id
  resource_id = aws_api_gateway_resource.status_session.id
  http_method = aws_api_gateway_method.status_get.http_method

  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.status.invoke_arn
}

resource "aws_lambda_permission" "api_gateway_status" {
  statement_id  = "AllowAPIGatewayInvokeStatus"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.status.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.waiting_room_api.execution_arn}/*/*"
}



data "archive_file" "admission_lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda/admission_lambda.py"
  output_path = "${path.module}/lambda/admission_lambda.zip"
}

resource "aws_lambda_function" "admission" {
  function_name = "virtual-waiting-room-admission"

  filename         = data.archive_file.admission_lambda_zip.output_path
  source_code_hash = data.archive_file.admission_lambda_zip.output_base64sha256

  handler = "admission_lambda.lambda_handler"
  runtime = "python3.12"

  role = aws_iam_role.lambda_role.arn

  environment {
    variables = {
      SESSIONS_TABLE = aws_dynamodb_table.queue_sessions.name
    }
  }
}

data "archive_file" "backend_lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda/backend_lambda.py"
  output_path = "${path.module}/lambda/backend_lambda.zip"
}

resource "aws_lambda_function" "backend" {
  function_name = "virtual-waiting-room-backend"

  filename         = data.archive_file.backend_lambda_zip.output_path
  source_code_hash = data.archive_file.backend_lambda_zip.output_base64sha256

  handler = "backend_lambda.lambda_handler"
  runtime = "python3.12"

  role = aws_iam_role.lambda_role.arn

  environment {
    variables = {
      SESSIONS_TABLE   = aws_dynamodb_table.queue_sessions.name
      BACKEND_CAPACITY = "10"
    }
  }
}

data "archive_file" "throttler_lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda/throttler_lambda.py"
  output_path = "${path.module}/lambda/throttler_lambda.zip"
}

resource "aws_iam_role_policy" "lambda_invoke_lambdas" {
  name = "virtual-waiting-room-lambda-invoke-lambdas"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"

    Statement = [{
      Effect = "Allow"
      Action = ["lambda:InvokeFunction"]
      Resource = [
        aws_lambda_function.backend.arn,
        aws_lambda_function.admission.arn
      ]
    }]
  })
}

resource "aws_lambda_function" "throttler" {
  function_name = "virtual-waiting-room-throttler"

  filename         = data.archive_file.throttler_lambda_zip.output_path
  source_code_hash = data.archive_file.throttler_lambda_zip.output_base64sha256

  handler = "throttler_lambda.lambda_handler"
  runtime = "python3.12"
  timeout = 30

  role = aws_iam_role.lambda_role.arn

  environment {
    variables = {
      SESSIONS_TABLE     = aws_dynamodb_table.queue_sessions.name
      BACKEND_FUNCTION   = aws_lambda_function.backend.function_name
      ADMISSION_FUNCTION = aws_lambda_function.admission.function_name
    }
  }
}

resource "aws_cloudwatch_event_rule" "throttler_schedule" {
  name                = "virtual-waiting-room-throttler-schedule"
  description         = "Runs the adaptive throttler every minute"
  schedule_expression = "rate(1 minute)"
}

resource "aws_cloudwatch_event_target" "throttler" {
  rule = aws_cloudwatch_event_rule.throttler_schedule.name
  arn  = aws_lambda_function.throttler.arn
}

resource "aws_lambda_permission" "eventbridge_throttler" {
  statement_id  = "AllowEventBridgeInvokeThrottler"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.throttler.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.throttler_schedule.arn
}

resource "aws_iam_role_policy" "lambda_cloudwatch_metrics" {
  name = "virtual-waiting-room-lambda-cloudwatch-metrics"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"

    Statement = [{
      Effect   = "Allow"
      Action   = ["cloudwatch:PutMetricData"]
      Resource = "*"
      Condition = {
        StringEquals = {
          "cloudwatch:namespace" = "VirtualWaitingRoom"
        }
      }
    }]
  })
}

resource "aws_cloudwatch_dashboard" "waiting_room" {
  dashboard_name = "virtual-waiting-room"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "Users waiting in queue"
          region = "ap-south-1"
          view   = "timeSeries"
          stat   = "Maximum"
          period = 60
          metrics = [
            ["VirtualWaitingRoom", "QueueSize"]
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "Backend load and admission rate"
          region = "ap-south-1"
          view   = "timeSeries"
          stat   = "Maximum"
          period = 60
          metrics = [
            ["VirtualWaitingRoom", "BackendLoad"],
            ["VirtualWaitingRoom", "AdmissionRate"]
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 24
        height = 6
        properties = {
          title  = "Backend latency (ms)"
          region = "ap-south-1"
          view   = "timeSeries"
          stat   = "Maximum"
          period = 60
          metrics = [
            ["VirtualWaitingRoom", "BackendLatencyMs"]
          ]
        }
      }
    ]
  })
}

data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "frontend" {
  bucket = "virtual-waiting-room-frontend-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket_public_access_block" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_object" "frontend_index" {
  bucket       = aws_s3_bucket.frontend.id
  key          = "index.html"
  source       = "${path.module}/../frontend/index.html"
  etag         = filemd5("${path.module}/../frontend/index.html")
  content_type = "text/html"
}

resource "aws_cloudfront_origin_access_control" "frontend" {
  name                              = "virtual-waiting-room-frontend"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "frontend" {
  enabled             = true
  default_root_object = "index.html"
  price_class         = "PriceClass_200"
  comment             = "Virtual waiting room web page"

  origin {
    domain_name              = aws_s3_bucket.frontend.bucket_regional_domain_name
    origin_id                = "s3-frontend"
    origin_access_control_id = aws_cloudfront_origin_access_control.frontend.id
  }

  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "s3-frontend"
    viewer_protocol_policy = "redirect-to-https"
    compress               = true
    cache_policy_id        = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

resource "aws_s3_bucket_policy" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  policy = jsonencode({
    Version = "2012-10-17"

    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "cloudfront.amazonaws.com" }
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.frontend.arn}/*"
      Condition = {
        StringEquals = {
          "AWS:SourceArn" = aws_cloudfront_distribution.frontend.arn
        }
      }
    }]
  })
}

output "frontend_url" {
  value = "https://${aws_cloudfront_distribution.frontend.domain_name}"
}
