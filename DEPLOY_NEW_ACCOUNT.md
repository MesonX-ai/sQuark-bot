# 🤖 sQuark Bot Backend - Agentic Chatbot Infrastructure

**Extracted from**: sQuark Desktop Application (PyQt)  
**Purpose**: Unified backend for sQuark AI chatbot using different AWS account  
**Infrastructure**: Terraform (ECS Fargate, Lambda, Cognito, API Gateway)  
**Cost**: Estimated $150-300/month (with chat processing)

---

## 📋 What's Included

### Terraform Configuration
- **sQuark.tf** (39 KB) - Complete infrastructure-as-code for sQuark chatbot backend
- **terraform.tfvars.example** - Configuration template for your AWS account

### Lambda Functions
- **lambda/index.py** - Agent orchestrator Lambda
- **lambda_auth/index.py** - Cognito authentication handler
- **lambda_llm_proxy/index.py** - LLM provider integration (Gemini, OpenAI, Claude)

### Build Artifacts
- **build/** - Pre-built Lambda deployment packages (.zip files)
- **deploy_browser_stack.sh** - Deployment automation script

### Documentation
- **ARCHITECTURE_WHITEPAPER.md** - Detailed technical architecture
- **EXECUTIVE_SUMMARY.md** - High-level overview
- **OPERATOR_RUNBOOK.md** - Operations and troubleshooting guide
- **README.md** - Original documentation

---

## 🚀 Quick Start: Deploy to Different AWS Account

### Prerequisites

1. **AWS Account Access**
   ```bash
   aws login  # Or configure credentials
   aws sts get-caller-identity  # Verify access
   ```

2. **Tools Required**
   ```bash
   terraform --version  # Must be >= 1.6.0
   aws --version        # AWS CLI v2
   python3 --version    # Python 3.11+
   ```

### Step 1: Configure for Your AWS Account

```bash
# Copy the example configuration
cp terraform.tfvars.example terraform.tfvars

# Edit with your AWS account details
cat terraform.tfvars
```

**Key variables to update:**
```hcl
aws_region               = "us-east-2"  # Change to your region
project_name             = "squark-bot"  # Your project name
environment              = "prod"        # dev/staging/prod
admin_email              = "your-email@example.com"  # For Cognito
cognito_domain_prefix    = "your-unique-squark"      # Must be globally unique
cognito_callback_urls    = ["https://your-domain.com"]
cognito_logout_urls      = ["https://your-domain.com"]
gemini_api_key           = "your-gemini-key"  # Or set via Secrets Manager
```

### Step 2: Initialize Terraform

```bash
terraform init
```

**Expected output:**
```
Terraform has been successfully configured!
```

### Step 3: Review the Plan

```bash
terraform plan -out=tfplan
```

**Verify**:
- ✅ All resources show `(created)`
- ✅ No resource conflicts
- ✅ Correct AWS region

### Step 4: Deploy Infrastructure

```bash
terraform apply tfplan
```

**This creates**:
- ✅ ECS Fargate cluster for chatbot worker
- ✅ Lambda functions (auth, orchestrator, LLM proxy)
- ✅ Cognito user pool with MFA
- ✅ API Gateway with OAuth
- ✅ ECR repository for container images
- ✅ CloudWatch logs and monitoring
- ✅ S3 buckets (assets, artifacts)

**Estimated time**: 10-15 minutes

### Step 5: Get Deployment Outputs

```bash
terraform output -raw api_endpoint
terraform output -raw cognito_domain
terraform output -raw ecr_repository_url
```

**Save these values** - you'll need them for:
- Frontend integration
- Mobile app configuration
- CI/CD pipeline setup

---

## 📊 Infrastructure Overview

### Architecture

```
┌─────────────────────────────────────────┐
│        sQuark Chatbot Client            │
│  (Web/Mobile/Desktop Application)       │
└────────────────┬────────────────────────┘
                 │
         ┌───────▼────────┐
         │  API Gateway   │ ← Public HTTP endpoint
         │  (with OAuth)  │
         └───────┬────────┘
                 │
    ┌────────────┼────────────┐
    │            │            │
┌───▼──┐  ┌──────▼──┐  ┌─────▼─────┐
│Lambda│  │Lambda   │  │  ECS      │
│Auth  │  │Orch.    │  │ Fargate   │
│      │  │(Agent)  │  │ (Worker)  │
└──────┘  └─────────┘  └───────────┘
    │         │              │
    └─────────┼──────────────┘
              │
         ┌────▼─────┐
         │ DynamoDB │ ← Session/Chat history
         │ + S3     │
         └──────────┘
```

### Key Services

| Service | Purpose | Cost |
|---------|---------|------|
| ECS Fargate | Chatbot worker (1 vCPU, 2GB RAM) | ~$75/month |
| Lambda | Auth, orchestration, LLM proxy | ~$5-10/month |
| API Gateway | HTTP endpoint (REST) | ~$3.50/1M requests |
| Cognito | User authentication & MFA | ~$50-150/month (per MAU) |
| DynamoDB | Session/chat storage (on-demand) | ~$5-20/month |
| CloudWatch | Logs & monitoring | ~$2-5/month |
| ECR | Container registry | ~$0.10/GB storage |
| S3 | Static assets & artifacts | ~$1-5/month |

**Total Estimated**: $150-300/month (depending on usage)

---

## 🔑 Environment Variables

Create `.env` for local testing:

```bash
# AWS Configuration
AWS_REGION=us-east-2
AWS_ACCOUNT_ID=123456789012  # Your account ID

# Cognito
COGNITO_USER_POOL_ID=us-east-2_abc123def
COGNITO_CLIENT_ID=1234567890abcdefghijklmnop
COGNITO_DOMAIN=your-unique-squark

# API
API_ENDPOINT=https://abc123def.execute-api.us-east-2.amazonaws.com
API_STAGE=prod

# LLM Configuration
GEMINI_API_KEY=your-gemini-key  # Get from https://ai.google.dev
OPENAI_API_KEY=sk-xxx           # Optional
ANTHROPIC_API_KEY=sk-ant-xxx    # Optional

# Logging
LOG_LEVEL=INFO
ENABLE_DEBUG=false
```

---

## 📝 Deployment Checklist

- [ ] AWS account access verified (`aws sts get-caller-identity`)
- [ ] Terraform installed (`terraform --version >= 1.6.0`)
- [ ] `terraform.tfvars` created and configured
- [ ] `terraform init` completed successfully
- [ ] `terraform plan` reviewed and approved
- [ ] `terraform apply` completed
- [ ] All outputs saved (API endpoint, Cognito domain, etc.)
- [ ] Lambda functions packaged in `build/`
- [ ] ECR repository created and ready for container image
- [ ] API Gateway endpoint tested (`curl https://...`)
- [ ] Cognito user pool accessible
- [ ] CloudWatch logs being created

---

## 🧪 Testing After Deployment

### 1. Verify API Gateway

```bash
API=$(terraform output -raw api_endpoint)
curl $API/ping
# Expected: {"status": "ok"}
```

### 2. Check Lambda Functions

```bash
aws logs tail /aws/lambda/squark-bot-auth --follow
aws logs tail /aws/lambda/squark-bot-orchestrator --follow
aws logs tail /aws/lambda/squark-bot-llm-proxy --follow
```

### 3. Cognito User Pool

```bash
aws cognito-idp describe-user-pool \
  --user-pool-id $(terraform output -raw cognito_user_pool_id) \
  --region us-east-2
```

### 4. ECR Repository

```bash
aws ecr describe-repositories \
  --region us-east-2
```

---

## 🔄 Connecting to Frontend

After deployment, integrate with your sQuark chatbot client:

### Web Application (Next.js/React)
```typescript
const API_ENDPOINT = terraform output -raw api_endpoint
const COGNITO_DOMAIN = terraform output -raw cognito_domain

const config = {
  apiEndpoint: API_ENDPOINT,
  cognitoDomain: COGNITO_DOMAIN,
  clientId: /* from Cognito console */,
  redirectUri: 'https://your-app.com/callback'
}
```

### Mobile Application (React Native/Flutter)
```javascript
const config = {
  apiEndpoint: API_ENDPOINT,
  cognitoRegion: 'us-east-2',
  cognitoUserPoolId: /* from Cognito */,
  cognitoClientId: /* from Cognito */
}
```

### Desktop Application (PyQt/Electron)
```python
BACKEND_URL = terraform output -raw api_endpoint
COGNITO_DOMAIN = terraform output -raw cognito_domain
```

---

## 🆘 Troubleshooting

### Terraform Issues

| Issue | Solution |
|-------|----------|
| `Provider plugins not found` | Run `terraform init` |
| `Permission denied` | Check AWS credentials: `aws sts get-caller-identity` |
| `Resource already exists` | Previous deployment exists; run `terraform destroy` first |
| `State lock timeout` | Another deployment in progress; wait 10 minutes |

### Lambda Issues

```bash
# View lambda errors
aws logs tail /aws/lambda/squark-bot-orchestrator --follow

# Check function configuration
aws lambda get-function-configuration \
  --function-name squark-bot-orchestrator-prod
```

### Cognito Issues

```bash
# Test authentication
aws cognito-idp initiate-auth \
  --client-id <CLIENT_ID> \
  --auth-flow ADMIN_NO_SRP_AUTH \
  --auth-parameters USERNAME=test@example.com,PASSWORD=TempPassword123!
```

### ECS Fargate Issues

```bash
# Check cluster status
aws ecs describe-clusters \
  --clusters squark-bot-prod \
  --include ATTACHMENTS

# Check task status
aws ecs list-tasks --cluster squark-bot-prod
aws ecs describe-tasks \
  --cluster squark-bot-prod \
  --tasks <TASK_ARN>
```

---

## 🔐 Security Best Practices

- ✅ Never commit `terraform.tfvars` to Git (add to `.gitignore`)
- ✅ Enable MFA in Cognito (configured by default)
- ✅ Use Secrets Manager for API keys (Lambda LLM proxy)
- ✅ Enable VPC endpoints for private API access
- ✅ Enable CloudTrail for audit logging
- ✅ Use IAM roles (never hardcode credentials)
- ✅ Enable encryption at rest (DynamoDB, S3)
- ✅ Use HTTPS only for API endpoints

---

## 📈 Scaling Configuration

For production use, adjust these variables in `terraform.tfvars`:

```hcl
# For high traffic
browser_cpu              = 2048    # 2 vCPU (default: 1024)
browser_memory           = 4096    # 4 GB RAM (default: 2048)
browser_desired_count    = 3       # 3 instances (default: 1)
lambda_memory_size       = 2048    # 2 GB (default: 1024)
lambda_timeout           = 120     # 2 minutes (default: 60)

# For multi-region
# Repeat this deployment in multiple regions for HA
```

---

## 📚 Additional Resources

- [sQuark Architecture Whitepaper](./ARCHITECTURE_WHITEPAPER.md)
- [Operations Runbook](./OPERATOR_RUNBOOK.md)
- [Executive Summary](./EXECUTIVE_SUMMARY.md)
- [Terraform AWS Provider](https://registry.terraform.io/providers/hashicorp/aws/latest)
- [AWS Cognito Documentation](https://docs.aws.amazon.com/cognito/)
- [ECS Fargate Guide](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/what-is-fargate.html)

---

## 🆘 Support

For issues or questions:
1. Check [OPERATOR_RUNBOOK.md](./OPERATOR_RUNBOOK.md) for troubleshooting
2. Review CloudWatch logs: `aws logs tail /aws/lambda/squark-bot-* --follow`
3. Check Terraform state: `terraform state list`
4. Enable debug logging: Set `LOG_LEVEL=DEBUG` in Lambda environment

---

**Ready to deploy your sQuark chatbot backend!** 🚀
