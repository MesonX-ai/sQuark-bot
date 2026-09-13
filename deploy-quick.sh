#!/bin/bash

################################################################################
#                                                                              #
#        sQuark Bot Backend - Quick Deploy Script                            #
#        Fast deployment for updates (assumes Terraform already initialized) #
#                                                                              #
################################################################################

set -e

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

log() {
    echo -e "${BLUE}[$(date '+%H:%M:%S')]${NC} $1"
}

success() {
    echo -e "${GREEN}✅ $1${NC}"
}

warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

error() {
    echo -e "${RED}❌ $1${NC}"
}

header() {
    echo -e "\n${CYAN}════════════════════════════════════════════════════════════${NC}\n"
    echo -e "${CYAN}$1${NC}\n"
}

footer() {
    echo -e "\n${CYAN}════════════════════════════════════════════════════════════${NC}\n"
}

main() {
    clear
    
    echo -e "${CYAN}"
    cat << "EOF"
╔══════════════════════════════════════════════════════════════════╗
║                                                                  ║
║     sQuark Bot Backend - Quick Deploy                           ║
║     Git push + Terraform apply (fast update)                    ║
║                                                                  ║
╚══════════════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}\n"
    
    # Check prerequisites
    header "Checking Prerequisites"
    
    if ! command -v git &> /dev/null; then
        error "Git not found"
        exit 1
    fi
    success "Git found"
    
    if ! command -v terraform &> /dev/null; then
        error "Terraform not found"
        exit 1
    fi
    success "Terraform found"
    
    if ! aws sts get-caller-identity &> /dev/null; then
        error "AWS credentials not configured"
        exit 1
    fi
    AWS_ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
    success "AWS account: $AWS_ACCOUNT"
    
    footer
    
    # Git push
    header "Pushing Changes to GitHub"
    
    cd "$PROJECT_DIR"
    
    if [ -z "$(git status --porcelain)" ]; then
        warning "No changes to commit"
    else
        log "Staging changes..."
        git add -A
        
        COMMIT_MSG="Update sQuark Bot Backend - $TIMESTAMP"
        log "Committing..."
        git commit -m "$COMMIT_MSG" || true
        success "Committed: $COMMIT_MSG"
        
        log "Pushing to GitHub..."
        git push origin main
        success "Pushed to GitHub"
    fi
    
    footer
    
    # Terraform update
    header "Applying Terraform Changes"
    
    log "Running terraform plan..."
    if terraform -chdir="$PROJECT_DIR" plan -out=tfplan_quick; then
        success "Plan created"
    else
        error "Plan failed"
        exit 1
    fi
    
    read -p "Apply changes? (yes/no): " -r CONFIRM
    if [ "$CONFIRM" != "yes" ]; then
        warning "Cancelled"
        exit 0
    fi
    
    log "Applying..."
    if terraform -chdir="$PROJECT_DIR" apply tfplan_quick; then
        success "Applied successfully"
    else
        error "Apply failed"
        exit 1
    fi
    
    footer
    
    # Summary
    header "Deployment Complete"
    
    echo -e "${GREEN}✅ Quick Deploy Completed!${NC}\n"
    echo "Changes pushed to GitHub and infrastructure updated.\n"
    
    API_ENDPOINT=$(terraform -chdir="$PROJECT_DIR" output -raw api_endpoint 2>/dev/null || echo "N/A")
    echo -e "API Endpoint: ${CYAN}$API_ENDPOINT${NC}\n"
    
    footer
    
    success "Done! 🚀"
}

main "$@"
