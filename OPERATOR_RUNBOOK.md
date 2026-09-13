# sQuark AI Browser AWS Operator Runbook

## Purpose

This runbook is for engineers who need to deploy, inspect, troubleshoot, or recover the sQuark AI browser AWS stack.

Use it when:

- deployment fails
- Terraform succeeds but the app does not work
- Lambda is not handling requests correctly
- ECS workers are not processing jobs
- browser jobs are stuck in the queue

## System Checklist

Before debugging anything, check these basics first:

1. AWS credentials are valid.
2. Terraform validates successfully.
3. Docker is running locally.
4. The ECR image push succeeded.
5. The Lambda and ECS resources exist in AWS.

## Useful Files

- [sQuark.tf](sQuark.tf)
- [deploy_browser_stack.sh](deploy_browser_stack.sh)
- [lambda/index.py](lambda/index.py)
- [terraform.tfvars.example](terraform.tfvars.example)

## Standard Deployment Flow

```bash
cd "/Users/mesonx/MY LAB/sQuark/cloud_formation"
cp terraform.tfvars.example terraform.tfvars
./deploy_browser_stack.sh
```

## Fast Health Checks

Run these first when something feels wrong.

## AWS Console Navigation Notes

If you prefer the AWS Console over the CLI, use these paths as your first stop.

### API Gateway WebSocket

Console path:

1. Open AWS Console.
2. Search for `API Gateway`.
3. Open `APIs`.
4. Select the sQuark WebSocket API.
5. Check `Routes`, `Integrations`, and `Stages`.

Use this page when:

- users cannot connect
- WebSocket routes do not seem to trigger
- the deployed stage looks out of date

### Lambda Orchestrator

Console path:

1. Open AWS Console.
2. Search for `Lambda`.
3. Open `Functions`.
4. Select the sQuark orchestrator function.
5. Check `Code`, `Configuration`, `Environment variables`, `Monitor`, and `Logs`.

Use this page when:

- Lambda is throwing errors
- environment variables look wrong
- you need to inspect recent invocations

### SQS Queue

Console path:

1. Open AWS Console.
2. Search for `SQS`.
3. Open `Queues`.
4. Select the main task queue and, if needed, the dead-letter queue.
5. Inspect `Monitoring` and the queue details.

Use this page when:

- work seems delayed
- messages are piling up
- dead-letter queue traffic is increasing

### ECS Service and Tasks

Console path:

1. Open AWS Console.
2. Search for `ECS`.
3. Open `Clusters`.
4. Select the sQuark cluster.
5. Open the browser service.
6. Inspect `Tasks`, `Events`, and `Logs`.

Use this page when:

- workers are not starting
- tasks are restarting repeatedly
- the service has fewer running tasks than expected

### DynamoDB Session Table

Console path:

1. Open AWS Console.
2. Search for `DynamoDB`.
3. Open `Tables`.
4. Select the sQuark session table.
5. Use `Explore table items`.

Use this page when:

- session state looks wrong
- connection records are missing
- you want to inspect stored items directly

### S3 Assets Bucket

Console path:

1. Open AWS Console.
2. Search for `S3`.
3. Open `Buckets`.
4. Select the sQuark assets bucket.
5. Inspect object paths and upload times.

Use this page when:

- screenshots are missing
- generated files are not appearing
- you need to verify whether uploads happened at all

### CloudWatch Logs

Console path:

1. Open AWS Console.
2. Search for `CloudWatch`.
3. Open `Logs` then `Log groups`.
4. Open the Lambda or ECS log group for sQuark.

Use this page when:

- you need stack traces
- startup failures are unclear
- the system is running but behaving incorrectly

### Validate Terraform

```bash
cd "/Users/mesonx/MY LAB/sQuark/cloud_formation"
terraform validate
```

### See Current Outputs

```bash
cd "/Users/mesonx/MY LAB/sQuark/cloud_formation"
terraform output
```

### Confirm AWS Identity

```bash
aws sts get-caller-identity
```

## Common Failure Scenarios

### 1. Terraform validate fails

What it usually means:

- syntax error in Terraform
- provider or variable mismatch
- broken reference to a resource

What to do:

1. Run `terraform fmt`.
2. Run `terraform init -backend=false`.
3. Run `terraform validate` again.
4. Fix the first reported error before looking at later ones.

### 2. ECR push fails

What it usually means:

- Docker is not running
- AWS ECR login expired
- repository was not created yet

What to do:

```bash
cd "/Users/mesonx/MY LAB/sQuark/cloud_formation"
terraform output browser_ecr_repository_url
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin <registry-host>
```

Then retry the push.

### 3. Lambda deploys but WebSocket requests fail

What it usually means:

- API Gateway reached Lambda, but Lambda threw an error
- environment variables are missing or wrong
- DynamoDB table name or queue URL is wrong

What to do:

1. Open CloudWatch logs for the Lambda function.
2. Check whether `$connect`, `$disconnect`, or normal message routes are failing.
3. Verify these environment variables exist in Lambda:
   - `TASK_QUEUE_URL`
   - `SESSION_TABLE`
   - `AWS_REGION`
4. Confirm the DynamoDB table and SQS queue actually exist.

### 4. Messages are entering SQS but work is not happening

What it usually means:

- ECS workers are not running
- ECS tasks cannot start
- the worker container image is broken

What to do:

1. Check ECS service desired count versus running count.
2. Check ECS task events.
3. Inspect container logs in CloudWatch.
4. Confirm the image tag in ECR matches the deployed tag.

### 5. ECS tasks keep restarting

What it usually means:

- container crash on startup
- missing environment variable
- container port mismatch
- application process exits immediately

What to do:

1. Inspect ECS task logs.
2. Confirm the container listens on the expected port.
3. Run the container locally with similar environment variables.
4. Rebuild and repush the image if needed.

### 6. Assets are not appearing in S3

What it usually means:

- worker never wrote the file
- wrong bucket name in the worker config
- IAM policy is missing required S3 access

What to do:

1. Confirm the worker reached the asset-writing code path.
2. Check the ECS task IAM role permissions.
3. Confirm the bucket output from Terraform matches the app config.

## AWS Areas to Check During Incidents

### API Gateway

Check when:

- clients cannot connect
- WebSocket routes seem broken

Look for:

- stage deployment
- route configuration
- Lambda integration target

### Lambda

Check when:

- sessions are not created
- SQS messages are not being enqueued

Look for:

- CloudWatch log errors
- missing environment variables
- permission problems

### SQS

Check when:

- work is delayed or stuck

Look for:

- growing queue depth
- messages moving to dead-letter queue

### ECS

Check when:

- browser work never starts
- workers are unstable

Look for:

- failing tasks
- image pull errors
- startup crashes

### DynamoDB

Check when:

- session tracking is wrong

Look for:

- missing session items
- unexpected keys or stale values

### S3

Check when:

- screenshots or exports are missing

Look for:

- missing uploads
- wrong bucket path
- permission issues

## Recovery Playbooks

### Redeploy the whole stack

```bash
cd "/Users/mesonx/MY LAB/sQuark/cloud_formation"
./deploy_browser_stack.sh
```

### Rebuild and repush only the browser image

```bash
cd "/Users/mesonx/MY LAB/sQuark/cloud_formation"
terraform output browser_ecr_repository_url
docker build -t squark-ai-browser:latest ..
docker tag squark-ai-browser:latest <repository-url>:latest
docker push <repository-url>:latest
terraform apply -var-file=terraform.tfvars -var="browser_image_tag=latest"
```

### Reapply only Terraform changes

```bash
cd "/Users/mesonx/MY LAB/sQuark/cloud_formation"
terraform apply -var-file=terraform.tfvars
```

### Destroy the environment

Use this only when you are sure the environment can be safely removed.

```bash
cd "/Users/mesonx/MY LAB/sQuark/cloud_formation"
terraform destroy -var-file=terraform.tfvars
```

## Day-2 Improvement Checklist

When operations mature, these are the best next upgrades:

- add CloudWatch alarms
- add ECS autoscaling from SQS depth
- add structured metrics and dashboards
- add a WebSocket client test harness
- add a dead-letter queue investigation workflow
- add a documented rollback process

## Mental Model for Operators

When debugging, ask these five questions in order:

1. Did the request enter through API Gateway?
2. Did Lambda receive and process it?
3. Did the message land in SQS?
4. Did an ECS worker pick it up?
5. Did the result get stored in DynamoDB or S3?

If you answer those in sequence, you can usually find the failure quickly.