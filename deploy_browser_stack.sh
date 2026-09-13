#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
VARS_FILE="${1:-$SCRIPT_DIR/terraform.tfvars}"
IMAGE_TAG="${2:-latest}"
LOCAL_IMAGE="squark-ai-browser:${IMAGE_TAG}"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require_command aws
require_command docker
require_command terraform

if [[ ! -f "$VARS_FILE" ]]; then
  echo "Terraform vars file not found: $VARS_FILE" >&2
  exit 1
fi

echo "Initializing Terraform..."
terraform -chdir="$SCRIPT_DIR" init

echo "Bootstrapping ECR repository..."
terraform -chdir="$SCRIPT_DIR" apply -auto-approve -var-file="$VARS_FILE" -target=aws_ecr_repository.browser

REPOSITORY_URL="$(terraform -chdir="$SCRIPT_DIR" output -raw browser_ecr_repository_url)"
REGISTRY_HOST="${REPOSITORY_URL%%/*}"
AWS_REGION="$(printf '%s' "$REGISTRY_HOST" | awk -F. '{print $4}')"

if [[ -z "$AWS_REGION" ]]; then
  echo "Could not determine AWS region from repository URL: $REPOSITORY_URL" >&2
  exit 1
fi

echo "Logging in to ECR in region $AWS_REGION..."
aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$REGISTRY_HOST"

echo "Building browser image $LOCAL_IMAGE..."
docker build -t "$LOCAL_IMAGE" "$REPO_ROOT"

echo "Pushing browser image to $REPOSITORY_URL:$IMAGE_TAG..."
docker tag "$LOCAL_IMAGE" "$REPOSITORY_URL:$IMAGE_TAG"
docker push "$REPOSITORY_URL:$IMAGE_TAG"

echo "Applying full Terraform stack..."
terraform -chdir="$SCRIPT_DIR" apply -auto-approve -var-file="$VARS_FILE" -var="browser_image_tag=$IMAGE_TAG"

echo
echo "Deployment complete. Useful outputs:"
terraform -chdir="$SCRIPT_DIR" output