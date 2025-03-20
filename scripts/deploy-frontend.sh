#!/bin/bash
# Script for deploying frontend to AWS Amplify
# Usage: ./scripts/deploy-frontend.sh [environment]

# Default to development environment if not specified
ENVIRONMENT=${1:-dev}

# Load environment variables if .env exists
if [ -f "./lambda/.env" ]; then
  export $(grep -v '^#' ./lambda/.env | xargs)
fi

# Check for AWS credentials
if [ -z "$AWS_ACCESS_KEY_ID" ] || [ -z "$AWS_SECRET_ACCESS_KEY" ] || [ -z "$AWS_REGION" ]; then
  echo "Error: AWS credentials not found. Please set AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, and AWS_REGION"
  exit 1
fi

echo "=== Deploying frontend to AWS Amplify ($ENVIRONMENT) ==="

# Get the Amplify app ID
# Note: You'll need to set this to your actual Amplify app ID
AMPLIFY_APP_ID=$(aws amplify list-apps --query "apps[?name=='largo-chat'].appId" --output text)

if [ -z "$AMPLIFY_APP_ID" ] || [ "$AMPLIFY_APP_ID" == "None" ]; then
  echo "Error: Could not find Amplify app 'largo-chat'. Please check your Amplify configuration."
  exit 1
fi

echo "Found Amplify app ID: $AMPLIFY_APP_ID"

# Get current git branch
BRANCH=$(git rev-parse --abbrev-ref HEAD)
echo "Current git branch: $BRANCH"

# Check if branch exists in Amplify
BRANCH_EXISTS=$(aws amplify get-branch --app-id $AMPLIFY_APP_ID --branch-name $BRANCH 2>/dev/null || echo "false")

if [ "$BRANCH_EXISTS" == "false" ]; then
  echo "Creating new branch in Amplify: $BRANCH"
  aws amplify create-branch --app-id $AMPLIFY_APP_ID --branch-name $BRANCH
fi

# Start a build
echo "Starting build for branch: $BRANCH"
aws amplify start-job --app-id $AMPLIFY_APP_ID --branch-name $BRANCH --job-type RELEASE

echo "=== Frontend deployment initiated ==="
echo "Check the Amplify console for build status and URL"
