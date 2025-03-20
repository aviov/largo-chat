#!/bin/bash

# Set colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Load AWS credentials
if [ -f lambda/.env ]; then
  echo "Loading AWS credentials from lambda/.env"
  source lambda/.env
fi

# Set AWS region if not already set
AWS_REGION=${AWS_REGION:-eu-central-1}

echo -e "${GREEN}=== Creating Service Account for AWS Load Balancer Controller ===${NC}"

# Get account ID
ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
echo "AWS Account ID: $ACCOUNT_ID"

# Create service account YAML
echo -e "${GREEN}Creating service account with IAM role annotation...${NC}"
ROLE_NAME="AmazonEKSLoadBalancerControllerRole"
ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"

cat > aws-lb-service-account.yaml << EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  labels:
    app.kubernetes.io/component: controller
    app.kubernetes.io/name: aws-load-balancer-controller
  name: aws-load-balancer-controller
  namespace: kube-system
  annotations:
    eks.amazonaws.com/role-arn: ${ROLE_ARN}
EOF

kubectl apply -f aws-lb-service-account.yaml

# Restart the AWS Load Balancer Controller deployment
echo -e "${GREEN}Restarting AWS Load Balancer Controller deployment...${NC}"
kubectl rollout restart deployment/aws-load-balancer-controller -n kube-system

# Wait for the deployment to stabilize
echo -e "${GREEN}Waiting for AWS Load Balancer Controller deployment to stabilize...${NC}"
kubectl rollout status deployment/aws-load-balancer-controller -n kube-system

echo -e "${GREEN}=== Service Account Setup Complete ===${NC}"
echo -e "The AWS Load Balancer Controller should now have the proper permissions."
