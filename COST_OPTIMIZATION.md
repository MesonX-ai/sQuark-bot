# 💰 Cost-Optimized Deployment ($10-20/month)

**For Low-Traffic Chatbot APIs (<100K calls/month, no auth)**

**Serves**: sQuark AI Browser + Chatbot in sQuark.ai Website

---

## Architecture Comparison

### ❌ ORIGINAL (EXPENSIVE)
```
ECS Fargate (always-on container)
├─ $50-75/month
├─ Overkill for occasional requests
└─ Not suitable for <100K calls/month

Cognito User Pool
├─ $50/month
├─ Not needed (public API, no auth)
└─ Unnecessary cost

Total: $120-170/month
```

### ✅ OPTIMIZED (BUDGET-FRIENDLY)
```
Lambda Functions (serverless)
├─ $0.20 per 1M API calls
├─ <100K calls = FREE (within free tier)
└─ Perfect for occasional requests

API Gateway
├─ $0.35 per 1M API calls
├─ <100K calls = ~$0.04/month
└─ Perfect for public API

DynamoDB (optional, for chat history)
├─ On-demand pricing: $1.25/M writes, $0.25/M reads
├─ <100K calls = ~$0.10/month
└─ No provisioned capacity needed

Total: $8-15/month ✅
```

---

## Monthly Cost Breakdown

| Item | Cost | Notes |
|------|------|-------|
| Lambda Invocations | FREE | Within 1M/month free tier |
| API Gateway Calls | ~$0.04 | 100K calls × $0.35/M |
| DynamoDB | ~$0.10 | Estimated 50K ops/month |
| CloudWatch Logs | FREE | Within 5GB/month free tier |
| S3 Storage | FREE | Within 5GB/month free tier |
| **Total** | **$8-15** | ✅ Under $50 |

**Plus**: LLM API costs (Gemini, OpenAI, Claude) are separate and scale with usage.

---

## Architecture Diagram

```
┌─────────────────────────────────────────┐
│          Frontend/User                   │
│     (Web, Mobile, Desktop)              │
└────────────────┬────────────────────────┘
                 │
                 ▼
        ┌────────────────┐
        │ API Gateway    │ ($0.04/month)
        │ (Public HTTP)  │
        └────────┬───────┘
                 │
    ┌────────────┼────────────┐
    │            │            │
    ▼            ▼            ▼
┌──────────┐ ┌──────────┐ ┌──────────┐
│Lambda 1  │ │Lambda 2  │ │Lambda 3  │ (FREE - within 1M/month)
│Auth*     │ │Orchestr. │ │LLM Proxy │
│(optional)│ │          │ │          │
└────┬─────┘ └────┬─────┘ └────┬─────┘
     │            │            │
     └────────────┼────────────┘
                  │
          ┌───────┴───────┐
          ▼               ▼
      ┌─────────┐   ┌──────────┐
      │DynamoDB │   │CloudWatch│
      │(Chat)   │   │(Logs)    │
      │$0.10/mo │   │FREE      │
      └─────────┘   └──────────┘
          │
          ▼
    ┌──────────────┐
    │ECR Container │ (optional: if needed)
    │Stored: FREE  │
    └──────────────┘

* Auth in Lambda with JWT tokens (not Cognito)
```

---

## Step 1: Remove ECS Fargate

The original deployment used ECS Fargate for a containerized chatbot worker running 24/7. 

**Cost**: $50-75/month

**Replace with**: Lambda functions ($0.20/1M calls)

**Change in terraform.tfvars**:
```hcl
# REMOVE or set to false:
# enable_ecs_fargate = false
# enable_cognito = false
```

---

## Step 2: Remove Cognito User Pool

Cognito adds $50/month and isn't needed for a public API.

**Cost**: $50/month

**Replace with**: Simple JWT token validation in Lambda (free)

**Lambda Auth Handler** (new minimal version):
```python
import json
import hmac
import hashlib
from datetime import datetime, timedelta

SECRET_KEY = "your-secret-key"

def lambda_handler(event, context):
    """Validate API key or JWT token"""
    
    api_key = event.get('headers', {}).get('x-api-key')
    
    # Simple API key validation
    if api_key == SECRET_KEY:
        return {
            'statusCode': 200,
            'body': json.dumps({'authorized': True})
        }
    
    return {
        'statusCode': 401,
        'body': json.dumps({'error': 'Unauthorized'})
    }
```

---

## Step 3: Optimize Lambda Functions

Keep the 3 Lambda functions but run them on-demand:

| Function | Memory | Timeout | Cost/1M calls |
|----------|--------|---------|---------------|
| orchestrator | 512 MB | 30s | $0.10 |
| llm_proxy | 512 MB | 60s | $0.20 |
| auth (optional) | 128 MB | 10s | $0.02 |
| **Total** | - | - | **$0.20** |

For <100K calls/month:
- **Cost**: FREE (within 1M/month free tier)
- **Scaling**: Automatically scales from 0 to thousands of concurrent invocations

---

## Step 4: Optimize API Gateway

Current: HTTP API with rate limiting
Optimized: Keep same, but optimize pricing

**Options**:

### Option A: HTTP API (Recommended - Cheapest)
```
Cost: $0.35 per million API calls
For <100K calls: $0.04/month
```

### Option B: REST API (More features, slightly more expensive)
```
Cost: $3.50 + $0.35 per million calls
For <100K calls: $3.54/month
```

**Recommendation**: Stick with HTTP API for chatbot

---

## Step 5: DynamoDB - On-Demand Pricing

**Current**: Provisioned capacity ($5-20/month)

**Optimized**: On-demand pricing ($1.25 per million writes, $0.25 per million reads)

For <100K chatbot calls with chat history:
- Estimated 50K-100K DynamoDB operations/month
- **Cost**: $0.05-0.15/month

**In terraform.tfvars**:
```hcl
dynamodb_billing_mode = "PAY_PER_REQUEST"  # On-demand
dynamodb_enable_ttl = true                 # Auto-delete old records
```

---

## Step 6: Free Tier Benefits

AWS Free Tier (always active) includes:

| Service | Free Allowance |
|---------|----------------|
| Lambda | 1M invocations/month + 400,000 GB-seconds |
| API Gateway | 1M API calls/month |
| DynamoDB | 25 GB storage + 25 provisioned write/read units |
| CloudWatch | 5GB logs/month + 1M API calls |
| S3 | 5GB storage |
| ECR | Unlimited free storage (pay only for data transfer) |

**For <100K calls/month**: You stay within free tier for Lambda + API Gateway + most of CloudWatch!

---

## Deployment Steps for Cost-Optimized Version

### 1. Update terraform.tfvars

```hcl
# Remove expensive services
enable_ecs_fargate = false
enable_cognito = false
enable_dynamodb = true  # Optional, for chat history

# Use on-demand DynamoDB
dynamodb_billing_mode = "PAY_PER_REQUEST"

# Lambda settings (keep as-is)
lambda_memory_size = 512
lambda_timeout = 60
```

### 2. Deploy with Cost-Optimized Config

```bash
cd /Users/mesonx/MY\ LAB/sQuark-bot

# Option A: Modify terraform.tfvars and deploy
cp terraform.tfvars.new-account terraform.tfvars
nano terraform.tfvars
./deploy.sh

# Option B: Use cost-optimized template (if available)
cp terraform.tfvars.cost-optimized terraform.tfvars
./deploy.sh
```

### 3. Update Lambda Functions (Remove Cognito Auth)

**lambda_auth/index.py** → Simplify to API key validation:

```python
import json
import os

API_KEY = os.environ['API_KEY']

def lambda_handler(event, context):
    auth_header = event.get('headers', {}).get('authorization', '')
    
    if auth_header.startswith('Bearer ') and auth_header[7:] == API_KEY:
        return {'statusCode': 200, 'body': json.dumps({'auth': 'ok'})}
    
    return {'statusCode': 401, 'body': json.dumps({'error': 'Unauthorized'})}
```

---

## Cost Monitoring

### 1. Set AWS Budget Alert

```bash
aws budgets create-budget \
  --account-id $(aws sts get-caller-identity --query Account --output text) \
  --budget BudgetName=MonthlyLimit,BudgetLimit='{Amount=50,Unit=USD}',TimeUnit=MONTHLY,BudgetType=COST \
  --notifications-with-subscribers file://notifications.json
```

### 2. CloudWatch Cost Anomaly Detection

```bash
aws ce create-anomaly-monitor \
  --anomaly-monitor '{
    "MonitorName": "DailySpend",
    "MonitorType": "DIMENSIONAL",
    "MonitorDimension": "SERVICE"
  }'
```

### 3. Check Monthly Spending

```bash
aws ce get-cost-and-usage \
  --time-period Start=2026-09-01,End=2026-10-01 \
  --granularity MONTHLY \
  --metrics BlendedCost \
  --group-by Type=DIMENSION,Key=SERVICE
```

---

## Migration Checklist

- [ ] Remove ECS Fargate configuration from sQuark.tf
- [ ] Remove Cognito configuration from sQuark.tf
- [ ] Update lambda_auth to use simple API key validation
- [ ] Update terraform.tfvars with `enable_ecs_fargate = false`
- [ ] Update terraform.tfvars with `enable_cognito = false`
- [ ] Set DynamoDB to on-demand billing
- [ ] Deploy with `./deploy.sh`
- [ ] Test API endpoints with curl or Postman
- [ ] Verify no Cognito domain created
- [ ] Check CloudWatch for Lambda invocations
- [ ] Set up cost alerts in AWS

---

## Example: Deploying Cost-Optimized Version

### Before (Expensive)
```bash
./deploy.sh
# Creates: ECS Fargate + Cognito + Lambda + API Gateway
# Cost: $120-170/month
```

### After (Budget-Friendly)
```bash
# 1. Edit terraform.tfvars
nano terraform.tfvars
# Set: enable_ecs_fargate = false
#      enable_cognito = false

# 2. Deploy
./deploy.sh
# Creates: Lambda + API Gateway + DynamoDB
# Cost: $8-15/month ✅
```

---

## Scaling Above Free Tier

If your usage grows beyond 1M Lambda calls/month:

| Monthly Calls | Lambda Cost | API Gateway Cost | Total |
|---------------|-------------|------------------|-------|
| 100K | FREE | $0.04 | **$0.04** |
| 500K | FREE | $0.18 | **$0.18** |
| 1M | FREE | $0.35 | **$0.35** |
| 2M | $0.20 | $0.70 | **$0.90** |
| 5M | $0.50 | $1.75 | **$2.25** |
| 10M | $1.00 | $3.50 | **$4.50** |
| 50M | $5.00 | $17.50 | **$22.50** |
| 100M | $10.00 | $35.00 | **$45.00** |

**You stay under $50 for up to ~85M calls/month!**

---

## FAQ

**Q: Do I lose any functionality?**
A: No. You lose the "always-on container" and "managed OAuth" features, but gain:
- ✅ Better scalability (auto-scales from 0 to thousands)
- ✅ Pay-per-use (only pay for actual requests)
- ✅ Same chatbot capabilities
- ✅ Same API endpoints

**Q: Can I add authentication later?**
A: Yes! You can add Cognito anytime when you're ready to pay for it, or use a cheaper alternative like:
- Auth0 (free tier)
- Firebase Auth ($free for small usage)
- Simple JWT tokens (free, implemented in Lambda)

**Q: What if traffic spikes?**
A: Lambda auto-scales instantly, and you're charged only for what you use. No surprise bills—you'll see it in Cost Explorer before it happens.

**Q: Can I use this with ECR container images?**
A: Yes! Terraform can still build and push to ECR, but instead of running in ECS, the container is used by Lambda.

**Q: What's the catch?**
A: None! This is the intended use case for Lambda. You're using AWS services as designed for low-traffic APIs.

---

## Next Steps

1. **Read this guide** → Understand the cost differences
2. **Update terraform.tfvars** → Set `enable_ecs_fargate = false` and `enable_cognito = false`
3. **Simplify lambda_auth** → Use API key instead of Cognito
4. **Deploy** → Run `./deploy.sh` with updated config
5. **Monitor costs** → Set up AWS budget alerts
6. **Celebrate** → You're now spending $8-15/month instead of $120-170! 🎉

---

**Questions about cost optimization?**
- Check AWS Pricing: https://aws.amazon.com/pricing/
- Lambda Pricing: https://aws.amazon.com/lambda/pricing/
- API Gateway Pricing: https://aws.amazon.com/api-gateway/pricing/
- Free Tier: https://aws.amazon.com/free/

