terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.54"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.5"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

variable "aws_region" {
  description = "AWS region for all sQuark AI browser resources."
  type        = string
  default     = "us-east-2"
}

variable "project_name" {
  description = "Resource prefix used across the AI browser infrastructure."
  type        = string
  default     = "squark-ai-browser"
}

variable "environment" {
  description = "Deployment environment name."
  type        = string
  default     = "prod"
}

variable "browser_container_image" {
  description = "Container image URI for the AI browser worker, such as an ECR image."
  type        = string
  default     = null
  nullable    = true
}

variable "browser_image_tag" {
  description = "Container image tag to use from the managed ECR repository when browser_container_image is not set."
  type        = string
  default     = "latest"
}

variable "browser_container_port" {
  description = "Container port exposed by the AI browser worker."
  type        = number
  default     = 3000
}

variable "browser_cpu" {
  description = "Fargate task CPU units for the AI browser worker."
  type        = number
  default     = 1024
}

variable "browser_memory" {
  description = "Fargate task memory in MiB for the AI browser worker."
  type        = number
  default     = 2048
}

variable "browser_desired_count" {
  description = "Number of always-on AI browser workers."
  type        = number
  default     = 1
}

variable "lambda_timeout" {
  description = "Timeout in seconds for the agent orchestrator Lambda."
  type        = number
  default     = 60
}

variable "lambda_memory_size" {
  description = "Memory size in MiB for the agent orchestrator Lambda."
  type        = number
  default     = 1024
}

variable "tags" {
  description = "Additional tags to merge onto all supported resources."
  type        = map(string)
  default     = {}
}

variable "admin_email" {
  description = "Initial admin user email for Cognito. Leave empty to skip default admin creation."
  type        = string
  default     = ""
}

variable "cognito_domain_prefix" {
  description = "Cognito hosted UI domain prefix (must be globally unique)."
  type        = string
  default     = "squark-ai-browser"
}

variable "cognito_callback_urls" {
  description = "Allowed callback URLs for the Cognito hosted UI / OAuth flow."
  type        = list(string)
  default     = ["http://localhost:3000", "http://localhost:8080", "https://squark-browser.ai"]
}

variable "cognito_logout_urls" {
  description = "Allowed logout URLs for the Cognito hosted UI / OAuth flow."
  type        = list(string)
  default     = ["http://localhost:3000", "http://localhost:8080", "https://squark-browser.ai"]
}

variable "gemini_api_key" {
  description = "Google Gemini API key injected into the LLM proxy Lambda as GEMINI_API_KEY. Takes precedence over the Secrets Manager secret so the free Gemini Flash tier works without manual secret edits. Leave empty to rely on the secret."
  type        = string
  default     = ""
  sensitive   = true
}

data "aws_caller_identity" "current" {}

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  name_prefix = "${var.project_name}-${var.environment}"

  common_tags = merge(
    {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "Terraform"
      Service     = "ai-browser"
    },
    var.tags
  )

  assets_bucket_name    = lower("${local.name_prefix}-${data.aws_caller_identity.current.account_id}-assets")
  artifacts_bucket_name = lower("${local.name_prefix}-${data.aws_caller_identity.current.account_id}-artifacts")
  browser_image_uri     = coalesce(var.browser_container_image, "${aws_ecr_repository.browser.repository_url}:${var.browser_image_tag}")
}

# ---------------------------------------------------------------------------
# Cognito — user registration, email/phone sign-up, MFA
# ---------------------------------------------------------------------------

resource "aws_cognito_user_pool" "main" {
  name = "${local.name_prefix}-users"

  mfa_configuration = "ON"

  sms_configuration {
    external_id    = "${local.name_prefix}-sms"
    sns_caller_arn = aws_iam_role.cognito_sms.arn
  }

  email_configuration {
    email_sending_account = "COGNITO_DEFAULT"
  }

  user_pool_add_ons {
    advanced_security_mode = "ENFORCED"
  }

  password_policy {
    minimum_length    = 8
    require_lowercase = true
    require_uppercase = true
    require_numbers   = true
    require_symbols   = false
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
    recovery_mechanism {
      name     = "verified_phone_number"
      priority = 2
    }
  }

  auto_verified_attributes = ["email", "phone_number"]

  verification_message_template {
    default_email_option = "CONFIRM_WITH_CODE"
    email_message        = "Your sQuark verification code is {####}"
    email_subject        = "Verify your sQuark account"
    sms_message          = "Your sQuark verification code is {####}"
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-user-pool"
  })
}

resource "aws_cognito_user_pool_client" "browser" {
  name         = "${local.name_prefix}-browser-client"
  user_pool_id = aws_cognito_user_pool.main.id

  generate_secret               = false
  prevent_user_existence_errors = "ENABLED"
  explicit_auth_flows = [
    "ALLOW_USER_SRP_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH",
    "ALLOW_CUSTOM_AUTH",
  ]
  supported_identity_providers = ["COGNITO"]

  callback_urls                        = var.cognito_callback_urls
  logout_urls                          = var.cognito_logout_urls
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["email", "openid", "profile"]
  allowed_oauth_flows_user_pool_client = true

  default_redirect_uri = var.cognito_callback_urls[0]
}

resource "aws_cognito_identity_pool" "main" {
  identity_pool_name = "${local.name_prefix}-identity"

  allow_unauthenticated_identities = false

  cognito_identity_providers {
    client_id               = aws_cognito_user_pool_client.browser.id
    provider_name           = aws_cognito_user_pool.main.endpoint
    server_side_token_check = true
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-identity-pool"
  })
}

resource "aws_iam_role" "cognito_authenticated" {
  name = "${local.name_prefix}-cognito-authenticated-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = "cognito-identity.amazonaws.com"
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "cognito-identity.amazonaws.com:aud" = aws_cognito_identity_pool.main.id
          }
          "ForAnyValue:StringLike" = {
            "cognito-identity.amazonaws.com:amr" = "authenticated"
          }
        }
      }
    ]
  })

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-cognito-authenticated-role"
  })
}

resource "aws_iam_role" "cognito_unauthenticated" {
  name = "${local.name_prefix}-cognito-unauthenticated-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = "cognito-identity.amazonaws.com"
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "cognito-identity.amazonaws.com:aud" = aws_cognito_identity_pool.main.id
          }
          "ForAnyValue:StringLike" = {
            "cognito-identity.amazonaws.com:amr" = "unauthenticated"
          }
        }
      }
    ]
  })

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-cognito-unauthenticated-role"
  })
}

resource "aws_iam_role_policy_attachment" "cognito_authenticated_basic" {
  role       = aws_iam_role.cognito_authenticated.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonCognitoPowerUser"
}

resource "aws_iam_role_policy_attachment" "cognito_unauthenticated_basic" {
  role       = aws_iam_role.cognito_unauthenticated.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonCognitoReadOnly"
}

resource "aws_cognito_identity_pool_roles_attachment" "main" {
  identity_pool_id = aws_cognito_identity_pool.main.id

  roles = {
    "authenticated"   = aws_iam_role.cognito_authenticated.arn
    "unauthenticated" = aws_iam_role.cognito_unauthenticated.arn
  }
}

resource "aws_iam_role" "cognito_sms" {
  name = "${local.name_prefix}-cognito-sms-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "cognito-idp.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-cognito-sms-role"
  })
}

resource "aws_iam_role_policy" "cognito_sms" {
  name = "${local.name_prefix}-cognito-sms-policy"
  role = aws_iam_role.cognito_sms.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = "*"
      }
    ]
  })
}

resource "aws_cognito_user" "admin" {
  user_pool_id = aws_cognito_user_pool.main.id
  username     = var.admin_email != "" ? var.admin_email : "admin@example.com"

  temporary_password = "TempPass123!"

  attributes = {
    email          = var.admin_email != "" ? var.admin_email : "admin@example.com"
    email_verified = true
  }

  lifecycle {
    ignore_changes = [
      temporary_password,
    ]
  }
}

resource "aws_cognito_user_group" "admin" {
  name         = "admin"
  user_pool_id = aws_cognito_user_pool.main.id
  description  = "Administrators"
}

resource "aws_cognito_user_group" "users" {
  name         = "users"
  user_pool_id = aws_cognito_user_pool.main.id
  description  = "Standard users"
}

resource "aws_cognito_user_in_group" "admin" {
  user_pool_id = aws_cognito_user_pool.main.id
  group_name   = aws_cognito_user_group.admin.name
  username     = aws_cognito_user.admin.username
}

resource "aws_cognito_user_pool_domain" "main" {
  domain       = var.cognito_domain_prefix
  user_pool_id = aws_cognito_user_pool.main.id
}

data "archive_file" "auth_lambda" {
  type        = "zip"
  source_dir  = "${path.module}/lambda_auth"
  output_path = "${path.module}/build/auth_lambda.zip"
}

resource "aws_iam_role" "auth_lambda_role" {
  name = "${local.name_prefix}-auth-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-auth-lambda-role"
  })
}

resource "aws_iam_role_policy_attachment" "auth_lambda_basic" {
  role       = aws_iam_role.auth_lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "auth_lambda_cognito_access" {
  name = "${local.name_prefix}-auth-lambda-cognito-access"
  role = aws_iam_role.auth_lambda_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "cognito-idp:AdminCreateUser",
          "cognito-idp:AdminSetUserPassword",
          "cognito-idp:AdminAddUserToGroup",
          "cognito-idp:AdminRemoveUserFromGroup",
          "cognito-idp:ListUsers",
          "cognito-idp:AdminGetUser",
          "cognito-idp:AdminResetUserPassword",
        ]
        Resource = aws_cognito_user_pool.main.arn
      }
    ]
  })
}

resource "aws_lambda_function" "auth_lambda" {
  function_name    = "${local.name_prefix}-auth-lambda"
  role             = aws_iam_role.auth_lambda_role.arn
  handler          = "index.handler"
  runtime          = "python3.12"
  timeout          = 30
  memory_size      = 1024
  filename         = data.archive_file.auth_lambda.output_path
  source_code_hash = data.archive_file.auth_lambda.output_base64sha256

  environment {
    variables = {
      USER_POOL_ID     = aws_cognito_user_pool.main.id
      APP_CLIENT_ID    = aws_cognito_user_pool_client.browser.id
      IDENTITY_POOL_ID = aws_cognito_identity_pool.main.id
    }
  }

  depends_on = [aws_iam_role_policy_attachment.auth_lambda_basic]

  tags = local.common_tags
}

resource "aws_apigatewayv2_authorizer" "llm_cognito_authorizer" {
  api_id           = aws_apigatewayv2_api.llm_api.id
  authorizer_type  = "JWT"
  identity_sources = ["$request.header.Authorization"]
  name             = "${local.name_prefix}-llm-cognito-auth"

  jwt_configuration {
    audience = [aws_cognito_user_pool_client.browser.id]
    issuer   = "https://cognito-idp.${var.aws_region}.amazonaws.com/${aws_cognito_user_pool.main.id}"
  }
}

data "archive_file" "agent_orchestrator" {
  type        = "zip"
  source_dir  = "${path.module}/lambda"
  output_path = "${path.module}/build/orchestrator.zip"
}

resource "aws_vpc" "main" {
  cidr_block           = "10.42.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-vpc"
  })
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-igw"
  })
}

resource "aws_subnet" "public" {
  count = 2

  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(aws_vpc.main.cidr_block, 8, count.index)
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-public-${count.index + 1}"
    Tier = "public"
  })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-public-rt"
  })
}

resource "aws_route_table_association" "public" {
  count = length(aws_subnet.public)

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "browser_tasks" {
  name        = "${local.name_prefix}-browser-sg"
  description = "Security group for AI browser Fargate tasks"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "Allow browser control traffic"
    from_port   = var.browser_container_port
    to_port     = var.browser_container_port
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-browser-sg"
  })
}

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${local.name_prefix}-orchestrator"
  retention_in_days = 14

  tags = local.common_tags
}

resource "aws_cloudwatch_log_group" "ecs" {
  name              = "/ecs/${local.name_prefix}-browser"
  retention_in_days = 14

  tags = local.common_tags
}

resource "aws_sqs_queue" "task_dlq" {
  name = "${local.name_prefix}-task-dlq"

  tags = local.common_tags
}

resource "aws_sqs_queue" "task_buffer" {
  name                       = "${local.name_prefix}-task-buffer"
  visibility_timeout_seconds = 180
  message_retention_seconds  = 1209600

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.task_dlq.arn
    maxReceiveCount     = 5
  })

  tags = local.common_tags
}

resource "aws_dynamodb_table" "session_state" {
  name         = "${local.name_prefix}-session-state"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "SessionID"

  attribute {
    name = "SessionID"
    type = "S"
  }

  tags = local.common_tags
}

resource "aws_s3_bucket" "assets" {
  bucket        = local.assets_bucket_name
  force_destroy = false

  tags = local.common_tags
}

resource "aws_s3_bucket" "artifacts" {
  bucket        = local.artifacts_bucket_name
  force_destroy = false

  tags = merge(local.common_tags, {
    Purpose = "deployment-artifacts"
  })
}

resource "aws_s3_bucket_versioning" "assets" {
  bucket = aws_s3_bucket.assets.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "assets" {
  bucket = aws_s3_bucket.assets.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "assets" {
  bucket = aws_s3_bucket.assets.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_ecr_repository" "browser" {
  name                 = "${local.name_prefix}-browser"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = local.common_tags
}

resource "aws_ecr_lifecycle_policy" "browser" {
  repository = aws_ecr_repository.browser.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep the most recent 20 images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 20
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

resource "aws_secretsmanager_secret" "api_keys" {
  name                    = "${local.name_prefix}/api-keys"
  recovery_window_in_days = 7

  tags = local.common_tags
}

data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "ecs_task_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "lambda_access" {
  statement {
    sid = "SqsAccess"
    actions = [
      "sqs:SendMessage",
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes"
    ]
    resources = [aws_sqs_queue.task_buffer.arn]
  }

  statement {
    sid = "DynamoAccess"
    actions = [
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:UpdateItem",
      "dynamodb:DeleteItem",
      "dynamodb:Query",
      "dynamodb:Scan"
    ]
    resources = [aws_dynamodb_table.session_state.arn]
  }

  statement {
    sid = "SecretAccess"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret"
    ]
    resources = [aws_secretsmanager_secret.api_keys.arn]
  }

  statement {
    sid = "AssetAccess"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject"
    ]
    resources = ["${aws_s3_bucket.assets.arn}/*"]
  }

  statement {
    sid = "BedrockInvoke"
    actions = [
      "bedrock:InvokeModel",
      "bedrock:InvokeModelWithResponseStream"
    ]
    resources = ["*"]
  }
}

data "aws_iam_policy_document" "ecs_task_access" {
  statement {
    sid = "QueueAccess"
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:ChangeMessageVisibility",
      "sqs:GetQueueAttributes"
    ]
    resources = [aws_sqs_queue.task_buffer.arn]
  }

  statement {
    sid = "DynamoAccess"
    actions = [
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:UpdateItem",
      "dynamodb:DeleteItem",
      "dynamodb:Query",
      "dynamodb:Scan"
    ]
    resources = [aws_dynamodb_table.session_state.arn]
  }

  statement {
    sid = "SecretAccess"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret"
    ]
    resources = [aws_secretsmanager_secret.api_keys.arn]
  }

  statement {
    sid = "AssetAccess"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject"
    ]
    resources = ["${aws_s3_bucket.assets.arn}/*"]
  }

  statement {
    sid = "BedrockInvoke"
    actions = [
      "bedrock:InvokeModel",
      "bedrock:InvokeModelWithResponseStream"
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role" "lambda_role" {
  name               = "${local.name_prefix}-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "lambda_access" {
  name   = "${local.name_prefix}-lambda-access"
  role   = aws_iam_role.lambda_role.id
  policy = data.aws_iam_policy_document.lambda_access.json
}

resource "aws_iam_role" "ecs_task_execution_role" {
  name               = "${local.name_prefix}-ecs-execution-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume_role.json

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "ecs_task_role" {
  name               = "${local.name_prefix}-ecs-task-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume_role.json

  tags = local.common_tags
}

resource "aws_iam_role_policy" "ecs_task_access" {
  name   = "${local.name_prefix}-ecs-task-access"
  role   = aws_iam_role.ecs_task_role.id
  policy = data.aws_iam_policy_document.ecs_task_access.json
}

resource "aws_lambda_function" "agent_orchestrator" {
  function_name    = "${local.name_prefix}-agent-orchestrator"
  role             = aws_iam_role.lambda_role.arn
  handler          = "index.handler"
  runtime          = "python3.12"
  timeout          = var.lambda_timeout
  memory_size      = var.lambda_memory_size
  filename         = data.archive_file.agent_orchestrator.output_path
  source_code_hash = data.archive_file.agent_orchestrator.output_base64sha256

  environment {
    variables = {
      TASK_QUEUE_URL  = aws_sqs_queue.task_buffer.url
      SESSION_TABLE   = aws_dynamodb_table.session_state.name
      ASSETS_BUCKET   = aws_s3_bucket.assets.bucket
      API_SECRET_ARN  = aws_secretsmanager_secret.api_keys.arn
      LLM_PROXY_URL   = aws_apigatewayv2_stage.llm_prod.invoke_url
      ECS_CLUSTER_ARN = aws_ecs_cluster.squark_cluster.arn
      ECS_SERVICE_ARN = aws_ecs_service.browser_service.id
    }
  }

  depends_on = [aws_cloudwatch_log_group.lambda]

  tags = local.common_tags
}

resource "aws_apigatewayv2_api" "squark_api" {
  name                       = "${local.name_prefix}-gateway"
  protocol_type              = "WEBSOCKET"
  route_selection_expression = "$request.body.action"

  tags = local.common_tags
}

resource "aws_apigatewayv2_integration" "orchestrator" {
  api_id           = aws_apigatewayv2_api.squark_api.id
  integration_type = "AWS_PROXY"
  integration_uri  = aws_lambda_function.agent_orchestrator.invoke_arn
}

resource "aws_apigatewayv2_route" "connect" {
  api_id    = aws_apigatewayv2_api.squark_api.id
  route_key = "$connect"
  target    = "integrations/${aws_apigatewayv2_integration.orchestrator.id}"
}

resource "aws_apigatewayv2_route" "disconnect" {
  api_id    = aws_apigatewayv2_api.squark_api.id
  route_key = "$disconnect"
  target    = "integrations/${aws_apigatewayv2_integration.orchestrator.id}"
}

resource "aws_apigatewayv2_route" "default" {
  api_id    = aws_apigatewayv2_api.squark_api.id
  route_key = "$default"
  target    = "integrations/${aws_apigatewayv2_integration.orchestrator.id}"
}

resource "aws_apigatewayv2_stage" "prod" {
  api_id      = aws_apigatewayv2_api.squark_api.id
  name        = var.environment
  auto_deploy = true

  default_route_settings {
    throttling_burst_limit = 200
    throttling_rate_limit  = 100
  }

  tags = local.common_tags
}

resource "aws_lambda_permission" "allow_apigw" {
  statement_id  = "AllowExecutionFromApiGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.agent_orchestrator.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.squark_api.execution_arn}/*/*"
}

resource "aws_ecs_cluster" "squark_cluster" {
  name = "${local.name_prefix}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = local.common_tags
}

resource "aws_ecs_task_definition" "headless_browser_task" {
  family                   = "${local.name_prefix}-browser"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = tostring(var.browser_cpu)
  memory                   = tostring(var.browser_memory)
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn
  task_role_arn            = aws_iam_role.ecs_task_role.arn

  container_definitions = jsonencode([
    {
      name      = "ai-browser"
      image     = local.browser_image_uri
      essential = true
      portMappings = [
        {
          containerPort = var.browser_container_port
          hostPort      = var.browser_container_port
          protocol      = "tcp"
        }
      ]
      environment = [
        { name = "TASK_QUEUE_URL", value = aws_sqs_queue.task_buffer.url },
        { name = "SESSION_TABLE", value = aws_dynamodb_table.session_state.name },
        { name = "ASSETS_BUCKET", value = aws_s3_bucket.assets.bucket },
        { name = "API_SECRET_ARN", value = aws_secretsmanager_secret.api_keys.arn },
        { name = "LLM_PROXY_URL", value = aws_apigatewayv2_stage.llm_prod.invoke_url }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.ecs.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "ecs"
        }
      }
    }
  ])

  tags = local.common_tags
}

resource "aws_ecs_service" "browser_service" {
  name            = "${local.name_prefix}-browser-service"
  cluster         = aws_ecs_cluster.squark_cluster.id
  task_definition = aws_ecs_task_definition.headless_browser_task.arn
  desired_count   = var.browser_desired_count
  launch_type     = "FARGATE"

  network_configuration {
    assign_public_ip = true
    subnets          = aws_subnet.public[*].id
    security_groups  = [aws_security_group.browser_tasks.id]
  }

  depends_on = [aws_iam_role_policy_attachment.ecs_task_execution]

  tags = local.common_tags
}

output "api_gateway_websocket_url" {
  description = "WebSocket endpoint for the AI browser control plane."
  value       = aws_apigatewayv2_stage.prod.invoke_url
}

output "task_queue_url" {
  description = "SQS queue URL used for browser task dispatch."
  value       = aws_sqs_queue.task_buffer.url
}

output "assets_bucket_name" {
  description = "S3 bucket storing browser screenshots and generated assets."
  value       = aws_s3_bucket.assets.bucket
}

output "lambda_artifacts_bucket_name" {
  description = "S3 bucket reserved for deployment artifacts and future packaged assets."
  value       = aws_s3_bucket.artifacts.bucket
}

output "session_table_name" {
  description = "DynamoDB table storing AI browser session state."
  value       = aws_dynamodb_table.session_state.name
}

output "ecs_cluster_name" {
  description = "ECS cluster hosting the AI browser workers."
  value       = aws_ecs_cluster.squark_cluster.name
}

output "browser_service_name" {
  description = "ECS service running the AI browser workers."
  value       = aws_ecs_service.browser_service.name
}

output "browser_ecr_repository_url" {
  description = "Managed ECR repository URL for the AI browser worker image."
  value       = aws_ecr_repository.browser.repository_url
}

output "orchestrator_lambda_name" {
  description = "Lambda function name for the agent orchestrator."
  value       = aws_lambda_function.agent_orchestrator.function_name
}

# ---------------------------------------------------------------------------
# LLM Gateway — free-tier LLM routing with quota + telemetry
# ---------------------------------------------------------------------------

data "archive_file" "llm_proxy" {
  type        = "zip"
  source_dir  = "${path.module}/lambda_llm_proxy"
  output_path = "${path.module}/build/llm_proxy.zip"
}

resource "aws_dynamodb_table" "llm_usage" {
  name         = "${local.name_prefix}-llm-usage"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "user_id#provider#date"

  attribute {
    name = "user_id#provider#date"
    type = "S"
  }

  ttl {
    attribute_name = "expire_at"
    enabled        = true
  }

  tags = local.common_tags
}

resource "aws_dynamodb_table" "llm_telemetry" {
  name         = "${local.name_prefix}-llm-telemetry"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "request_id"
  range_key    = "timestamp"

  attribute {
    name = "request_id"
    type = "S"
  }

  attribute {
    name = "timestamp"
    type = "S"
  }

  ttl {
    attribute_name = "expire_at"
    enabled        = true
  }

  tags = local.common_tags
}

data "aws_iam_policy_document" "llm_proxy_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "llm_proxy_access" {
  statement {
    sid = "DynamoUsageAccess"
    actions = [
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:UpdateItem",
      "dynamodb:Query",
      "dynamodb:Scan",
    ]
    resources = [
      aws_dynamodb_table.llm_usage.arn,
      "${aws_dynamodb_table.llm_usage.arn}/*",
    ]
  }

  statement {
    sid = "DynamoTelemetryAccess"
    actions = [
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:UpdateItem",
      "dynamodb:Query",
      "dynamodb:Scan",
    ]
    resources = [
      aws_dynamodb_table.llm_telemetry.arn,
      "${aws_dynamodb_table.llm_telemetry.arn}/*",
    ]
  }

  statement {
    sid = "SecretAccess"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]
    resources = [aws_secretsmanager_secret.api_keys.arn]
  }

  statement {
    sid = "BedrockAccess"
    actions = [
      "bedrock:InvokeModel",
      "bedrock:InvokeModelWithResponseStream",
    ]
    resources = ["*"]
  }

  statement {
    sid = "CloudWatchMetrics"
    actions = [
      "cloudwatch:PutMetricData",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role" "llm_proxy_role" {
  name               = "${local.name_prefix}-llm-proxy-role"
  assume_role_policy = data.aws_iam_policy_document.llm_proxy_assume_role.json

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "llm_proxy_basic" {
  role       = aws_iam_role.llm_proxy_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "llm_proxy_access" {
  name   = "${local.name_prefix}-llm-proxy-access"
  role   = aws_iam_role.llm_proxy_role.id
  policy = data.aws_iam_policy_document.llm_proxy_access.json
}

resource "aws_lambda_function" "llm_proxy" {
  function_name    = "${local.name_prefix}-llm-proxy"
  role             = aws_iam_role.llm_proxy_role.arn
  handler          = "index.handler"
  runtime          = "python3.12"
  timeout          = 30
  memory_size      = 1024
  filename         = data.archive_file.llm_proxy.output_path
  source_code_hash = data.archive_file.llm_proxy.output_base64sha256

  environment {
    variables = {
      USAGE_TABLE     = aws_dynamodb_table.llm_usage.name
      TELEMETRY_TABLE = aws_dynamodb_table.llm_telemetry.name
      SECRETS_ARN     = aws_secretsmanager_secret.api_keys.arn
      GEMINI_API_KEY  = var.gemini_api_key
    }
  }

  depends_on = [aws_iam_role_policy_attachment.llm_proxy_basic]

  tags = local.common_tags
}

resource "aws_apigatewayv2_api" "llm_api" {
  name          = "${local.name_prefix}-llm-api"
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins = ["*"]
    allow_methods = ["POST", "OPTIONS"]
    allow_headers = ["Content-Type", "X-API-Key"]
    max_age       = 86400
  }

  tags = local.common_tags
}

resource "aws_apigatewayv2_stage" "llm_prod" {
  api_id      = aws_apigatewayv2_api.llm_api.id
  name        = var.environment
  auto_deploy = true

  default_route_settings {
    throttling_burst_limit = 100
    throttling_rate_limit  = 50
  }

  tags = local.common_tags
}

resource "aws_apigatewayv2_integration" "llm_proxy_integration" {
  api_id                 = aws_apigatewayv2_api.llm_api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.llm_proxy.invoke_arn
  # Format 1.0 enables Lambda response streaming (token-by-token SSE to the client).
  payload_format_version = "1.0"
}

resource "aws_apigatewayv2_route" "llm_chat" {
  api_id        = aws_apigatewayv2_api.llm_api.id
  route_key     = "POST /llm/chat"
  authorizer_id = aws_apigatewayv2_authorizer.llm_cognito_authorizer.id
  target        = "integrations/${aws_apigatewayv2_integration.llm_proxy_integration.id}"
}

resource "aws_lambda_permission" "allow_llm_api" {
  statement_id  = "AllowExecutionFromLLMApiGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.llm_proxy.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.llm_api.execution_arn}/*/*"
}

# CloudWatch Alarms
resource "aws_cloudwatch_metric_alarm" "llm_quota_gemini_near_limit" {
  alarm_name          = "${local.name_prefix}-llm-gemini-near-limit"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "LLMRequests"
  namespace           = "sQuark/LLM"
  period              = 3600
  statistic           = "Sum"
  threshold           = 800
  dimensions = {
    Provider = "gemini"
  }

  alarm_description = "Gemini daily requests approaching free-tier limit (1000)"
  tags              = local.common_tags
}

resource "aws_cloudwatch_metric_alarm" "llm_quota_openrouter_near_limit" {
  alarm_name          = "${local.name_prefix}-llm-openrouter-near-limit"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "LLMRequests"
  namespace           = "sQuark/LLM"
  period              = 3600
  statistic           = "Sum"
  threshold           = 160
  dimensions = {
    Provider = "openrouter"
  }

  alarm_description = "OpenRouter daily requests approaching free-tier limit (200)"
  tags              = local.common_tags
}

# ---------------------------------------------------------------------------
# Auth API Gateway — public endpoints for registration, login, MFA
# ---------------------------------------------------------------------------

resource "aws_apigatewayv2_api" "auth_api" {
  name          = "${local.name_prefix}-auth-api"
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins = ["*"]
    allow_methods = ["POST", "OPTIONS"]
    allow_headers = ["Content-Type", "Authorization"]
    max_age       = 86400
  }

  tags = local.common_tags
}

resource "aws_apigatewayv2_stage" "auth_prod" {
  api_id      = aws_apigatewayv2_api.auth_api.id
  name        = var.environment
  auto_deploy = true

  default_route_settings {
    throttling_burst_limit = 50
    throttling_rate_limit  = 25
  }

  tags = local.common_tags
}

resource "aws_apigatewayv2_integration" "auth_lambda_integration" {
  api_id           = aws_apigatewayv2_api.auth_api.id
  integration_type = "AWS_PROXY"
  integration_uri  = aws_lambda_function.auth_lambda.invoke_arn
}

resource "aws_apigatewayv2_route" "auth_register" {
  api_id    = aws_apigatewayv2_api.auth_api.id
  route_key = "POST /auth/register"
  target    = "integrations/${aws_apigatewayv2_integration.auth_lambda_integration.id}"
}

resource "aws_apigatewayv2_route" "auth_confirm" {
  api_id    = aws_apigatewayv2_api.auth_api.id
  route_key = "POST /auth/confirm_signup"
  target    = "integrations/${aws_apigatewayv2_integration.auth_lambda_integration.id}"
}

resource "aws_apigatewayv2_route" "auth_resend" {
  api_id    = aws_apigatewayv2_api.auth_api.id
  route_key = "POST /auth/resend_confirmation"
  target    = "integrations/${aws_apigatewayv2_integration.auth_lambda_integration.id}"
}

resource "aws_apigatewayv2_route" "auth_login" {
  api_id    = aws_apigatewayv2_api.auth_api.id
  route_key = "POST /auth/login"
  target    = "integrations/${aws_apigatewayv2_integration.auth_lambda_integration.id}"
}

resource "aws_apigatewayv2_route" "auth_mfa" {
  api_id    = aws_apigatewayv2_api.auth_api.id
  route_key = "POST /auth/respond_to_mfa_challenge"
  target    = "integrations/${aws_apigatewayv2_integration.auth_lambda_integration.id}"
}

resource "aws_apigatewayv2_route" "auth_setup_mfa" {
  api_id    = aws_apigatewayv2_api.auth_api.id
  route_key = "POST /auth/setup_mfa"
  target    = "integrations/${aws_apigatewayv2_integration.auth_lambda_integration.id}"
}

resource "aws_apigatewayv2_route" "auth_get_user" {
  api_id    = aws_apigatewayv2_api.auth_api.id
  route_key = "POST /auth/get_user"
  target    = "integrations/${aws_apigatewayv2_integration.auth_lambda_integration.id}"
}

resource "aws_lambda_permission" "allow_auth_api" {
  statement_id  = "AllowExecutionFromAuthApiGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.auth_lambda.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.auth_api.execution_arn}/*/*"
}

# Outputs
output "llm_proxy_api_url" {
  description = "HTTP endpoint for the LLM proxy gateway."
  value       = "${aws_apigatewayv2_stage.llm_prod.invoke_url}/llm/chat"
}

output "llm_usage_table_name" {
  description = "DynamoDB table tracking per-user LLM quota usage."
  value       = aws_dynamodb_table.llm_usage.name
}

output "llm_telemetry_table_name" {
  description = "DynamoDB table storing LLM request telemetry."
  value       = aws_dynamodb_table.llm_telemetry.name
}

output "llm_proxy_lambda_name" {
  description = "Lambda function name for the LLM proxy."
  value       = aws_lambda_function.llm_proxy.function_name
}

output "cognito_user_pool_id" {
  description = "Cognito User Pool ID for user authentication."
  value       = aws_cognito_user_pool.main.id
}

output "cognito_user_pool_client_id" {
  description = "Cognito User Pool Client ID for the browser app."
  value       = aws_cognito_user_pool_client.browser.id
}

output "cognito_identity_pool_id" {
  description = "Cognito Identity Pool ID for AWS credentials."
  value       = aws_cognito_identity_pool.main.id
}

output "cognito_hosted_ui_url" {
  description = "Cognito Hosted UI URL for OAuth flows."
  value       = "https://${aws_cognito_user_pool_domain.main.domain}.auth.${var.aws_region}.amazoncognito.com"
}

output "auth_lambda_name" {
  description = "Lambda function name for custom auth flows."
  value       = aws_lambda_function.auth_lambda.function_name
}

output "auth_api_url" {
  description = "HTTP endpoint for the Auth API."
  value       = "${aws_apigatewayv2_stage.auth_prod.invoke_url}/auth"
}
