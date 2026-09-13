#!/bin/bash

################################################################################
#                                                                              #
#        sQuark Bot Backend - Deployment Script (GitHub + AWS)               #
#        Checks in changes to GitHub and deploys infrastructure to AWS       #
#                                                                              #
################################################################################

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration
GITHUB_REPO="https://github.com/MesonX-ai/sQuark-bot.git"
GITHUB_BRANCH="main"
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="${PROJECT_DIR}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="${PROJECT_DIR}/deploy_${TIMESTAMP}.log"

################################################################################
# Helper Functions
################################################################################

log() {
    echo -e "${BLUE}[$(date '+%H:%M:%S')]${NC} $1" | tee -a "$LOG_FILE"
}

success() {
    echo -e "${GREEN}✅ $1${NC}" | tee -a "$LOG_FILE"
}

warning() {
    echo -e "${YELLOW}⚠️  $1${NC}" | tee -a "$LOG_FILE"
}

error() {
    echo -e "${RED}❌ $1${NC}" | tee -a "$LOG_FILE"
}

header() {
    echo -e "\n${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║ $1${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}\n" | tee -a "$LOG_FILE"
}

footer() {
    echo -e "\n${CYAN}════════════════════════════════════════════════════════════${NC}\n" | tee -a "$LOG_FILE"
}

################################################################################
# Validation Functions
################################################################################

check_prerequisites() {
    header "Checking Prerequisites"
    
    # Check AWS CLI
    log "Checking AWS CLI..."
    if ! command -v aws &> /dev/null; then
        error "AWS CLI not found. Please install it first."
        echo "Install: https://aws.amazon.com/cli/"
        exit 1
    fi
    AWS_VERSION=$(aws --version)
    success "AWS CLI found: $AWS_VERSION"
    
    # Check AWS credentials
    log "Checking AWS credentials..."
    if ! aws sts get-caller-identity &> /dev/null; then
        error "AWS credentials not configured. Run: aws login or aws configure"
        exit 1
    fi
    AWS_ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
    AWS_USER=$(aws sts get-caller-identity --query Arn --output text)
    success "AWS credentials verified (Account: $AWS_ACCOUNT)"
    log "  User/Role: $AWS_USER"
    
    # Check Terraform
    log "Checking Terraform..."
    if ! command -v terraform &> /dev/null; then
        error "Terraform not found. Please install Terraform 1.6 or higher."
        echo "Install: https://www.terraform.io/downloads"
        exit 1
    fi
    TERRAFORM_VERSION=$(terraform -version | head -n1)
    success "Terraform found: $TERRAFORM_VERSION"
    
    # Check Git
    log "Checking Git..."
    if ! command -v git &> /dev/null; then
        error "Git not found. Please install it first."
        exit 1
    fi
    GIT_VERSION=$(git --version)
    success "Git found: $GIT_VERSION"
    
    footer
}

check_git_config() {
    header "Checking Git Configuration"
    
    log "Verifying git repository..."
    if [ ! -d "${PROJECT_DIR}/.git" ]; then
        error "Not a git repository. Initializing..."
        cd "$PROJECT_DIR"
        git init
        success "Git repository initialized"
    fi
    
    log "Checking git configuration..."
    GIT_USER=$(git config user.name 2>/dev/null || echo "")
    GIT_EMAIL=$(git config user.email 2>/dev/null || echo "")
    
    if [ -z "$GIT_USER" ] || [ -z "$GIT_EMAIL" ]; then
        warning "Git user not configured globally. Configuring for this repo..."
        git config user.name "MesonX Bot" || true
        git config user.email "bot@mesonx.ai" || true
    fi
    
    GIT_USER=$(git config user.name)
    GIT_EMAIL=$(git config user.email)
    success "Git user: $GIT_USER <$GIT_EMAIL>"
    
    # Check remote
    log "Checking git remote..."
    if ! git remote get-url origin &> /dev/null; then
        log "Adding remote origin..."
        git remote add origin "$GITHUB_REPO" || true
    fi
    
    REMOTE_URL=$(git remote get-url origin)
    success "Remote URL: $REMOTE_URL"
    
    footer
}

check_terraform_config() {
    header "Checking Terraform Configuration"
    
    if [ ! -f "${TERRAFORM_DIR}/sQuark.tf" ]; then
        error "sQuark.tf not found in ${TERRAFORM_DIR}"
        exit 1
    fi
    success "Terraform configuration found: sQuark.tf"
    
    if [ ! -f "${TERRAFORM_DIR}/terraform.tfvars" ]; then
        if [ -f "${TERRAFORM_DIR}/terraform.tfvars.new-account" ]; then
            warning "terraform.tfvars not found, using terraform.tfvars.new-account as template"
            log "Run: cp terraform.tfvars.new-account terraform.tfvars"
            log "Then edit terraform.tfvars with your AWS account details"
            error "terraform.tfvars not configured"
            exit 1
        else
            error "terraform.tfvars not found"
            exit 1
        fi
    fi
    success "Terraform variables file found: terraform.tfvars"
    
    # Validate Terraform syntax
    log "Validating Terraform syntax..."
    if ! terraform -chdir="${TERRAFORM_DIR}" validate > /dev/null 2>&1; then
        error "Terraform validation failed"
        terraform -chdir="${TERRAFORM_DIR}" validate
        exit 1
    fi
    success "Terraform syntax validated"
    
    footer
}

################################################################################
# Git Commit & Push
################################################################################

git_commit_push() {
    header "Committing Changes to GitHub"
    
    log "Checking git status..."
    if [ -z "$(git status --porcelain)" ]; then
        warning "No uncommitted changes found"
        return 0
    fi
    
    log "Staging all changes..."
    git add -A
    success "Changes staged"
    
    COMMIT_MESSAGE="Deploy sQuark Bot Backend - $TIMESTAMP"
    log "Creating commit: $COMMIT_MESSAGE"
    git commit -m "$COMMIT_MESSAGE" || true
    success "Changes committed"
    
    log "Checking branch..."
    CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
    if [ "$CURRENT_BRANCH" != "$GITHUB_BRANCH" ]; then
        log "Switching to $GITHUB_BRANCH branch..."
        git checkout -b "$GITHUB_BRANCH" 2>/dev/null || git checkout "$GITHUB_BRANCH"
    fi
    success "On branch: $CURRENT_BRANCH"
    
    log "Pushing to GitHub..."
    if git push -u origin "$GITHUB_BRANCH" 2>&1; then
        success "Changes pushed to GitHub"
        log "Repository: $GITHUB_REPO"
        log "Branch: $GITHUB_BRANCH"
    else
        warning "Git push encountered an issue (may already be up to date)"
    fi
    
    footer
}

################################################################################
# Terraform Deployment
################################################################################

terraform_init() {
    header "Initializing Terraform"
    
    log "Running terraform init..."
    cd "$TERRAFORM_DIR"
    
    if terraform init -upgrade; then
        success "Terraform initialized successfully"
        log "Backend: Local state file (terraform.tfstate)"
    else
        error "Terraform initialization failed"
        exit 1
    fi
    
    footer
}

terraform_plan() {
    header "Terraform Plan"
    
    log "Running terraform plan..."
    PLAN_FILE="${TERRAFORM_DIR}/tfplan_${TIMESTAMP}"
    
    if terraform -chdir="${TERRAFORM_DIR}" plan -out="$PLAN_FILE" 2>&1 | tee -a "$LOG_FILE"; then
        success "Terraform plan completed"
        log "Plan saved to: $PLAN_FILE"
        return 0
    else
        error "Terraform plan failed"
        exit 1
    fi
    
    footer
}

terraform_apply() {
    header "Applying Terraform Configuration"
    
    PLAN_FILE="${TERRAFORM_DIR}/tfplan_${TIMESTAMP}"
    
    if [ ! -f "$PLAN_FILE" ]; then
        error "Plan file not found: $PLAN_FILE"
        exit 1
    fi
    
    log "Review the plan above carefully."
    log ""
    read -p "Do you want to apply these changes? (yes/no): " -r APPLY_CONFIRM
    
    if [ "$APPLY_CONFIRM" != "yes" ]; then
        warning "Deployment cancelled by user"
        exit 0
    fi
    
    log "Applying Terraform configuration..."
    if terraform -chdir="${TERRAFORM_DIR}" apply "$PLAN_FILE" 2>&1 | tee -a "$LOG_FILE"; then
        success "Terraform apply completed successfully"
    else
        error "Terraform apply failed"
        exit 1
    fi
    
    footer
}

terraform_outputs() {
    header "Deployment Outputs"
    
    log "Retrieving Terraform outputs..."
    
    cd "$TERRAFORM_DIR"
    
    if terraform output -json > /dev/null 2>&1; then
        echo -e "\n${YELLOW}Terraform Outputs:${NC}\n"
        terraform output -json | python3 -m json.tool 2>/dev/null || terraform output
        
        echo -e "\n${YELLOW}Key Endpoints:${NC}\n"
        
        # Try to get specific outputs
        API_ENDPOINT=$(terraform output -raw api_endpoint 2>/dev/null || echo "N/A")
        COGNITO_DOMAIN=$(terraform output -raw cognito_domain 2>/dev/null || echo "N/A")
        ECR_REPO=$(terraform output -raw ecr_repository_url 2>/dev/null || echo "N/A")
        
        echo -e "  API Endpoint:      ${CYAN}$API_ENDPOINT${NC}"
        echo -e "  Cognito Domain:    ${CYAN}$COGNITO_DOMAIN${NC}"
        echo -e "  ECR Repository:    ${CYAN}$ECR_REPO${NC}"
        
        success "Outputs retrieved successfully"
    else
        warning "No outputs available yet"
    fi
    
    footer
}

################################################################################
# Post-Deployment
################################################################################

deployment_summary() {
    header "Deployment Summary"
    
    echo -e "${GREEN}✅ Deployment Completed Successfully!${NC}\n"
    
    echo -e "${YELLOW}What was deployed:${NC}"
    echo "  ✓ Changes committed and pushed to GitHub"
    echo "  ✓ Terraform infrastructure applied"
    echo "  ✓ AWS resources created"
    echo ""
    
    echo -e "${YELLOW}Next Steps:${NC}"
    echo "  1. Review the outputs above (API endpoint, Cognito domain, etc.)"
    echo "  2. Save the outputs for frontend integration"
    echo "  3. Update your frontend with the API endpoint"
    echo "  4. Configure Cognito user pool (if needed)"
    echo "  5. Build and push container image to ECR"
    echo "  6. Monitor CloudWatch logs:"
    echo "     aws logs tail /aws/lambda/squark-bot-* --follow"
    echo "  7. Test API endpoints:"
    echo "     curl <API_ENDPOINT>/health"
    echo ""
    
    echo -e "${YELLOW}Useful Commands:${NC}"
    echo "  • View logs:"
    echo "    terraform output -raw api_endpoint"
    echo "  • Destroy resources:"
    echo "    terraform destroy"
    echo "  • View state:"
    echo "    terraform state list"
    echo ""
    
    echo -e "${YELLOW}Documentation:${NC}"
    echo "  • Setup Guide:     SETUP_GUIDE.md"
    echo "  • Deploy Guide:    DEPLOY_NEW_ACCOUNT.md"
    echo "  • Architecture:    ARCHITECTURE_WHITEPAPER.md"
    echo "  • Operations:      OPERATOR_RUNBOOK.md"
    echo ""
    
    echo -e "${YELLOW}Deployment Log:${NC}"
    echo "  Location: $LOG_FILE"
    echo ""
    
    footer
}

error_handler() {
    header "Deployment Failed"
    error "An error occurred during deployment"
    echo -e "\n${YELLOW}Troubleshooting:${NC}"
    echo "  1. Check the log file: $LOG_FILE"
    echo "  2. Review AWS credentials: aws sts get-caller-identity"
    echo "  3. Check Terraform state: terraform state list"
    echo "  4. Verify terraform.tfvars configuration"
    echo ""
    error "Deployment log saved to: $LOG_FILE"
    footer
    exit 1
}

################################################################################
# Main Deployment Flow
################################################################################

main() {
    clear
    
    echo -e "${CYAN}"
    cat << "EOF"
╔══════════════════════════════════════════════════════════════════╗
║                                                                  ║
║     sQuark Bot Backend - Deployment Script                      ║
║     Check in to GitHub + Deploy AWS Infrastructure              ║
║                                                                  ║
╚══════════════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}\n"
    
    echo "Starting deployment at $(date '+%Y-%m-%d %H:%M:%S')" | tee "$LOG_FILE"
    echo "Log file: $LOG_FILE" | tee -a "$LOG_FILE"
    echo ""
    
    # Set error trap
    trap error_handler ERR
    
    # Run all checks
    check_prerequisites
    check_git_config
    check_terraform_config
    
    # Git operations
    git_commit_push
    
    # Terraform operations
    terraform_init
    terraform_plan
    terraform_apply
    terraform_outputs
    
    # Summary
    deployment_summary
    
    log "Deployment completed at $(date '+%Y-%m-%d %H:%M:%S')"
    success "All done! 🚀"
}

# Run main function
main "$@"
