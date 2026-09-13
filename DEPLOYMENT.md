# 🚀 sQuark Bot Backend - Deployment Guide

Automated deployment of unified chatbot backend for:
- **sQuark AI Browser** (Desktop application)
- **Chatbot in sQuark.ai Website** (Web widget)

GitHub integration and AWS infrastructure automation.

---

## 📋 Available Scripts

### 1. `deploy.sh` — Full Deployment (Recommended for First Time)

**Purpose**: Complete deployment pipeline with all checks and validations.

**What it does**:
- ✅ Validates AWS credentials and tools
- ✅ Configures Git repository
- ✅ Validates Terraform configuration
- ✅ Commits changes to GitHub
- ✅ Pushes to main branch
- ✅ Initializes Terraform
- ✅ Plans infrastructure changes
- ✅ Applies Terraform configuration
- ✅ Shows deployment outputs

**When to use**:
- Initial deployment to new AWS account
- Major infrastructure changes
- After significant configuration updates

**Time**: 15-20 minutes

**Usage**:
```bash
cd /Users/mesonx/MY\ LAB/sQuark-bot
./deploy.sh
```

**Requirements**:
- AWS credentials configured (`aws sts get-caller-identity` works)
- Git configured locally
- Terraform 1.6+ installed
- `terraform.tfvars` already configured with your AWS account details

---

### 2. `deploy-quick.sh` — Quick Deploy (For Updates)

**Purpose**: Fast deployment for updates after initial setup.

**What it does**:
- ✅ Commits and pushes to GitHub (if changes exist)
- ✅ Plans infrastructure changes
- ✅ Applies Terraform configuration
- ✅ Shows API endpoint

**When to use**:
- Updating configuration after initial deployment
- Applying Terraform variable changes
- Quick iterations during development

**Time**: 5-10 minutes

**Usage**:
```bash
cd /Users/mesonx/MY\ LAB/sQuark-bot
./deploy-quick.sh
```

**Prerequisites**:
- Terraform already initialized (`terraform init` completed)
- AWS credentials active
- No breaking changes to infrastructure

---

## ⚙️ Configuration Before Deployment

### Step 1: Configure Terraform Variables

Before running either script, configure `terraform.tfvars`:

```bash
cd /Users/mesonx/MY\ LAB/sQuark-bot

# Copy the template
cp terraform.tfvars.new-account terraform.tfvars

# Edit with your AWS account details
nano terraform.tfvars
```

**Required Variables**:
```hcl
aws_region                = "us-east-2"           # Your AWS region
project_name              = "squark-bot"          # Project name
environment               = "prod"                # Environment
admin_email               = "admin@example.com"   # Admin email
cognito_domain_prefix     = "squark-bot-unique"   # Must be globally unique!
cognito_callback_urls     = [...]                 # Your frontend URLs
cognito_logout_urls       = [...]                 # Your frontend URLs
```

**Critical**: `cognito_domain_prefix` must be globally unique across all AWS accounts.

### Step 2: Configure Git (If Not Already Done)

```bash
git config --global user.name "Your Name"
git config --global user.email "your@email.com"
```

Or locally for this repo:
```bash
cd /Users/mesonx/MY\ LAB/sQuark-bot
git config user.name "Your Name"
git config user.email "your@email.com"
```

### Step 3: Verify AWS Access

```bash
aws sts get-caller-identity
# Output should show your AWS account ID and ARN
```

---

## 🎯 Deployment Workflow

### Option A: First-Time Deployment

```bash
cd /Users/mesonx/MY\ LAB/sQuark-bot

# 1. Configure Terraform variables
cp terraform.tfvars.new-account terraform.tfvars
nano terraform.tfvars  # Edit with your account details

# 2. Run full deployment
./deploy.sh

# Script will:
# - Check prerequisites
# - Validate configuration
# - Commit to GitHub
# - Deploy infrastructure
# - Show outputs
```

**Expected time**: 15-20 minutes

### Option B: Update After Initial Deployment

```bash
cd /Users/mesonx/MY\ LAB/sQuark-bot

# 1. Make changes to terraform.tfvars or other files
nano terraform.tfvars

# 2. Run quick deployment
./deploy-quick.sh

# Script will:
# - Commit changes
# - Push to GitHub
# - Apply updates
```

**Expected time**: 5-10 minutes

### Option C: Manual Step-by-Step

```bash
cd /Users/mesonx/MY\ LAB/sQuark-bot

# 1. Initialize Terraform
terraform init

# 2. Review changes
terraform plan

# 3. Apply changes
terraform apply

# 4. Get outputs
terraform output
```

---

## 📊 What Gets Deployed

### AWS Resources Created

| Service | Details |
|---------|---------|
| **ECS Fargate** | Chatbot worker container (1-2 vCPU, 2-4 GB RAM) |
| **Lambda** | 3 functions (auth, orchestrator, LLM proxy) |
| **Cognito** | User pool with MFA and OAuth 2.0 |
| **API Gateway** | HTTP API with REST endpoints |
| **ECR** | Private container registry |
| **DynamoDB** | Optional session storage |
| **CloudWatch** | Logs and monitoring |
| **IAM** | Roles and policies |
| **S3** | Assets and artifacts storage |

### Estimated Cost

| Service | Monthly Cost |
|---------|------------|
| ECS Fargate | $50-75 |
| Lambda | $5-10 |
| Cognito | $50 |
| API Gateway | $3.50 |
| DynamoDB | $5-20 |
| Other | $5-10 |
| **Total** | **$120-170** |

---

## 🔍 Monitoring Deployment

### View Logs During Deployment

```bash
# Full deployment (deploy.sh)
tail -f deploy_20260912_220000.log

# Quick deployment
tail -f /tmp/deploy-quick.log
```

### Check AWS Resources After Deployment

```bash
# List all Lambda functions
aws lambda list-functions --region us-east-2

# Check ECS clusters
aws ecs list-clusters --region us-east-2

# View Cognito user pools
aws cognito-idp list-user-pools --max-results 10 --region us-east-2

# Check CloudWatch logs
aws logs tail /aws/lambda/squark-bot-* --follow
```

### View Terraform Outputs

```bash
cd /Users/mesonx/MY\ LAB/sQuark-bot
terraform output
```

---

## 🛠️ Troubleshooting

### Error: "AWS credentials not configured"

**Solution**:
```bash
aws login
# Or
aws configure
```

Then verify:
```bash
aws sts get-caller-identity
```

### Error: "terraform.tfvars not found"

**Solution**:
```bash
cd /Users/mesonx/MY\ LAB/sQuark-bot
cp terraform.tfvars.new-account terraform.tfvars
nano terraform.tfvars
```

### Error: "Cognito domain already exists"

**Solution**: The domain prefix must be globally unique. Change it in `terraform.tfvars`:
```hcl
cognito_domain_prefix = "squark-bot-company-2026"  # Make it unique
```

Then rerun the script.

### Error: "Permission denied" during push

**Solution**: Check git remote and credentials:
```bash
git remote -v
git credentials approve  # Or reconfigure SSH/HTTPS access
```

### Error: "Terraform initialization failed"

**Solution**: Clear Terraform cache and retry:
```bash
rm -rf .terraform
rm .terraform.lock.hcl
./deploy.sh
```

### Error: "Lambda deployment package not found"

**Solution**: Ensure `build/` directory exists:
```bash
ls -la build/
# Should show: auth_lambda.zip, orchestrator.zip, llm_proxy.zip
```

---

## 📈 Scaling Infrastructure

To scale for production, edit `terraform.tfvars`:

```hcl
# For high traffic
browser_cpu             = 2048    # 2 vCPU (from 1024)
browser_memory          = 4096    # 4 GB (from 2048)
browser_desired_count   = 3       # 3 instances (from 1)
lambda_memory_size      = 2048    # 2 GB (from 1024)
lambda_timeout          = 120     # 2 minutes (from 60s)
```

Then run:
```bash
./deploy-quick.sh
```

---

## 🔒 Security Checklist

- [ ] AWS credentials are temporary/rotated
- [ ] `terraform.tfvars` is NOT committed to git (it's in .gitignore)
- [ ] Cognito MFA is enabled
- [ ] API Gateway uses HTTPS only
- [ ] Lambda environment variables don't expose secrets
- [ ] CloudTrail is enabled for audit logging
- [ ] CloudWatch alarms are configured
- [ ] backup/disaster recovery plan is documented

---

## 📚 Additional Resources

- [SETUP_GUIDE.md](./SETUP_GUIDE.md) - Quick 5-minute setup
- [DEPLOY_NEW_ACCOUNT.md](./DEPLOY_NEW_ACCOUNT.md) - Complete guide
- [ARCHITECTURE_WHITEPAPER.md](./ARCHITECTURE_WHITEPAPER.md) - Technical details
- [OPERATOR_RUNBOOK.md](./OPERATOR_RUNBOOK.md) - Operations guide
- [Terraform Documentation](https://www.terraform.io/docs)
- [AWS CLI Documentation](https://docs.aws.amazon.com/cli/)

---

## 🆘 Need Help?

### Common Issues

| Issue | Solution |
|-------|----------|
| Script not running | `chmod +x deploy.sh` |
| AWS CLI not found | Install: `brew install awscli` |
| Terraform not found | Install: `brew install terraform` |
| Git not configured | Run: `git config --global user.name "Name"` |
| Cognito domain taken | Change `cognito_domain_prefix` to unique value |

### Get More Info

```bash
# Show script help
./deploy.sh --help  # (not implemented, but scripts are well-commented)

# Check AWS account
aws sts get-caller-identity

# Check Terraform version
terraform -version

# View deployment logs
cat deploy_*.log

# Destroy and start over
cd /Users/mesonx/MY\ LAB/sQuark-bot
terraform destroy  # WARNING: Removes all AWS resources
```

---

## 🎬 Next Steps After Deployment

1. **Save Outputs**
   ```bash
   terraform output > deployment_outputs.txt
   ```

2. **Update Frontend Configuration**
   - Add API endpoint to your frontend
   - Configure Cognito OAuth
   - Update callback URLs

3. **Build Container Image**
   ```bash
   docker build -t squark-bot .
   aws ecr get-login-password | docker login --username AWS --password-stdin <ECR_URL>
   docker tag squark-bot:latest <ECR_URL>:latest
   docker push <ECR_URL>:latest
   ```

4. **Monitor Deployment**
   ```bash
   aws logs tail /aws/lambda/squark-bot-* --follow
   aws logs tail /aws/ecs/squark-bot-prod --follow
   ```

5. **Set Up Alerts**
   - Configure CloudWatch alarms
   - Enable SNS notifications
   - Set up email alerts for failures

---

**Happy deploying! 🚀**

For questions or issues, refer to the documentation files or check the deployment logs.
