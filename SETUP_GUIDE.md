# 🚀 sQuark Bot Backend Setup Guide

## Quick Start (5 minutes)

### 1. Copy Configuration Template
```bash
cp terraform.tfvars.new-account terraform.tfvars
```

### 2. Edit Configuration
```bash
# Update with your AWS account details
nano terraform.tfvars
```

**Must change:**
- `cognito_domain_prefix` — Make it unique (e.g., `squark-bot-mycompany-2026`)
- `cognito_callback_urls` — Add your domain
- `cognito_logout_urls` — Add your domain
- `admin_email` — Your admin email
- `aws_region` — Your AWS region (default: us-east-2)

### 3. Initialize Terraform
```bash
terraform init
```

### 4. Review & Deploy
```bash
terraform plan
terraform apply
```

### 5. Save Outputs
```bash
terraform output
# Save these values for frontend integration
```

---

## File Structure

```
sQuark-bot/
├── sQuark.tf                    # Main Terraform configuration
├── terraform.tfvars.example     # Original template
├── terraform.tfvars.new-account # Template for new AWS account
├── terraform.tfvars             # Your configuration (DO NOT COMMIT)
│
├── lambda/                      # Agent orchestrator
│   └── index.py
├── lambda_auth/                 # Cognito auth handler
│   └── index.py
├── lambda_llm_proxy/            # LLM integration
│   └── index.py
│
├── build/                       # Lambda deployment packages
│   ├── auth_lambda.zip
│   ├── orchestrator.zip
│   └── llm_proxy.zip
│
├── DEPLOY_NEW_ACCOUNT.md        # Complete deployment guide
├── ARCHITECTURE_WHITEPAPER.md   # Technical deep dive
├── EXECUTIVE_SUMMARY.md         # High-level overview
├── OPERATOR_RUNBOOK.md          # Operations guide
└── README.md                    # Original documentation
```

---

## Key Differences from Original

| Aspect | Original | New Account Setup |
|--------|----------|------------------|
| AWS Account | sQuark team account | Your account |
| Terraform State | Remote (if configured) | Local (start fresh) |
| Domain | squark-ai-browser.com | Your domain |
| Cognito Pool | Existing | Create new |
| API Gateway | Existing | Create new |
| Lambda Functions | Deployed | Deploy new |
| Container Registry | Existing ECR | Create new ECR |

---

## Deployment Workflow

```
1. Copy terraform.tfvars.new-account → terraform.tfvars
2. Edit terraform.tfvars (5 min)
3. terraform init (1 min)
4. terraform plan (2 min)
5. terraform apply (10-15 min)
6. Save outputs
7. Test API endpoint
8. Update frontend configuration
```

**Total Time**: 30-40 minutes

---

## Cost Estimation

| Service | Estimated Monthly Cost |
|---------|----------------------|
| ECS Fargate (1 vCPU, 2GB) | $50-75 |
| Lambda functions | $5-10 |
| API Gateway | $3.50 |
| Cognito (100 MAU) | $50 |
| DynamoDB (on-demand) | $5-20 |
| CloudWatch | $2-5 |
| ECR & S3 | $1-5 |
| **Total** | **$120-170/month** |

*Cost scales with usage. Adjust `browser_desired_count` and resource sizes as needed.*

---

## Next Steps After Deployment

1. **Build Container Image**
   ```bash
   aws ecr get-login-password --region us-east-2 | docker login --username AWS --password-stdin <ECR_URI>
   docker build -t squark-bot .
   docker tag squark-bot:latest <ECR_URI>:latest
   docker push <ECR_URI>:latest
   ```

2. **Update Frontend**
   - Add API endpoint to your frontend configuration
   - Configure OAuth with Cognito domain
   - Update callback URLs

3. **Deploy Frontend**
   - Test with new backend
   - Verify authentication flow
   - Monitor CloudWatch logs

4. **Set Up Monitoring**
   ```bash
   aws logs tail /aws/ecs/squark-bot-prod --follow
   aws logs tail /aws/lambda/squark-bot-* --follow
   ```

---

## Troubleshooting

### Cognito Domain Already Exists
```bash
# Error: Cognito domain prefix already in use
# Solution: Change cognito_domain_prefix to something unique
nano terraform.tfvars
# Change: cognito_domain_prefix = "squark-bot-unique-12345"
terraform apply
```

### Lambda Deployment Package Not Found
```bash
# Error: build/ directory missing
# Solution: Copy from original sQuark/cloud_formation/build/
cp /Users/mesonx/MY\ LAB/sQuark/cloud_formation/build/* ./build/
terraform apply
```

### Permission Denied (AWS Credentials)
```bash
# Solution: Set up AWS credentials
aws configure
# Or use: aws login
```

### API Gateway URL Not Working
```bash
# Check Lambda logs
aws logs tail /aws/lambda/squark-bot-orchestrator-prod --follow

# Check API Gateway
aws apigateway get-rest-apis --region us-east-2
```

---

## Support Resources

- 📖 [DEPLOY_NEW_ACCOUNT.md](./DEPLOY_NEW_ACCOUNT.md) - Detailed guide
- 🏗️ [ARCHITECTURE_WHITEPAPER.md](./ARCHITECTURE_WHITEPAPER.md) - Technical details
- 📋 [OPERATOR_RUNBOOK.md](./OPERATOR_RUNBOOK.md) - Operations guide
- 📊 Architecture diagrams (PNG files)

---

## Important: DO NOT COMMIT

Add to `.gitignore`:
- `terraform.tfvars` — Contains your AWS configuration
- `.terraform/` — Terraform cache
- `terraform.tfstate*` — AWS state files
- `build/*.zip` — Binary deployment files

These are already in `.gitignore` but verify before `git push`.

---

**Ready to deploy sQuark Bot Backend!** 🤖✨
