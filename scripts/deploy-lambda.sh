#!/bin/bash
# Script for deploying individual Lambda functions
# Usage: ./scripts/deploy-lambda.sh function-name

if [ $# -lt 1 ]; then
  echo "Usage: $0 <function-name>"
  echo "Example: $0 search-function"
  exit 1
fi

FUNCTION_NAME=$1
LAMBDA_DIR="./lambda"

echo "=== Deploying Lambda function: $FUNCTION_NAME ==="

# Load environment variables if .env exists
if [ -f "$LAMBDA_DIR/.env" ]; then
  export $(grep -v '^#' $LAMBDA_DIR/.env | xargs)
fi

# Check for AWS credentials
if [ -z "$AWS_ACCESS_KEY_ID" ] || [ -z "$AWS_SECRET_ACCESS_KEY" ] || [ -z "$AWS_REGION" ]; then
  echo "Error: AWS credentials not found. Please set AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, and AWS_REGION"
  exit 1
fi

# Create deployment package
echo "Creating deployment package..."
cd $LAMBDA_DIR
rm -f ../lambda-deploy.zip
zip -r ../lambda-deploy.zip . -x "*.git*" "*.env*" "*__pycache__*" "*.pytest_cache*" "node_modules/*"
cd ..

# Update the Lambda function
echo "Updating Lambda function code..."
aws lambda update-function-code \
  --function-name $FUNCTION_NAME \
  --zip-file fileb://lambda-deploy.zip

# Clean up
rm lambda-deploy.zip

echo "=== Lambda function $FUNCTION_NAME deployed successfully ==="
