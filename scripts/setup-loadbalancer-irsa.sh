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

echo -e "${GREEN}=== Setting up IRSA for AWS Load Balancer Controller ===${NC}"
echo -e "This script will create an IAM role and service account for the AWS Load Balancer Controller"

# Get the OIDC provider URL for the EKS cluster
echo -e "${GREEN}Getting OIDC provider URL for the EKS cluster...${NC}"
OIDC_PROVIDER=$(aws eks describe-cluster --name milvus-cluster --region $AWS_REGION --query "cluster.identity.oidc.issuer" --output text | sed -e "s/^https:\/\///")

if [ -z "$OIDC_PROVIDER" ]; then
  echo -e "${RED}Error: Failed to get OIDC provider URL for the EKS cluster.${NC}"
  exit 1
fi

echo -e "EKS cluster OIDC provider: $OIDC_PROVIDER"

# Check if the OIDC provider is already registered in IAM
echo -e "${GREEN}Checking if OIDC provider is registered in IAM...${NC}"
if ! aws iam list-open-id-connect-providers | grep -q $(echo $OIDC_PROVIDER | tr -d '/'); then
  echo -e "${YELLOW}OIDC provider not found in IAM, registering...${NC}"
  aws eks associate-identity-provider-config \
    --cluster-name milvus-cluster \
    --region $AWS_REGION \
    --oidc \
    --identity-provider-config name=oidc,issuerUrl=https://$OIDC_PROVIDER
  echo -e "${GREEN}OIDC provider registered.${NC}"
else
  echo -e "${GREEN}OIDC provider already registered in IAM.${NC}"
fi

# Create IAM policy for the AWS Load Balancer Controller
echo -e "${GREEN}Creating IAM policy for AWS Load Balancer Controller...${NC}"
POLICY_NAME="AWSLoadBalancerControllerIAMPolicy"

# Check if policy already exists
if aws iam get-policy --policy-arn arn:aws:iam::$(aws sts get-caller-identity --query "Account" --output text):policy/$POLICY_NAME 2>/dev/null; then
  echo -e "${GREEN}IAM policy $POLICY_NAME already exists.${NC}"
  POLICY_ARN="arn:aws:iam::$(aws sts get-caller-identity --query "Account" --output text):policy/$POLICY_NAME"
else
  echo -e "${YELLOW}Creating IAM policy for AWS Load Balancer Controller...${NC}"
  # Download the policy JSON from AWS
  curl -s -o iam_policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json
  
  # Create the policy
  POLICY_ARN=$(aws iam create-policy \
    --policy-name $POLICY_NAME \
    --policy-document file://iam_policy.json \
    --query 'Policy.Arn' \
    --output text)
  
  # Clean up
  rm iam_policy.json
  
  echo -e "${GREEN}IAM policy created: $POLICY_ARN${NC}"
fi

# Create IAM role for service account
echo -e "${GREEN}Creating IAM role for service account...${NC}"
ROLE_NAME="AmazonEKSLoadBalancerControllerRole"
NAMESPACE="kube-system"
SERVICE_ACCOUNT_NAME="aws-load-balancer-controller"

# Check if role already exists
if aws iam get-role --role-name $ROLE_NAME 2>/dev/null; then
  echo -e "${GREEN}IAM role $ROLE_NAME already exists.${NC}"
  ROLE_ARN=$(aws iam get-role --role-name $ROLE_NAME --query 'Role.Arn' --output text)
else
  echo -e "${YELLOW}Creating IAM role for service account...${NC}"
  
  # Create trust policy
  cat > trust-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::$(aws sts get-caller-identity --query "Account" --output text):oidc-provider/$OIDC_PROVIDER"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "$OIDC_PROVIDER:aud": "sts.amazonaws.com",
          "$OIDC_PROVIDER:sub": "system:serviceaccount:$NAMESPACE:$SERVICE_ACCOUNT_NAME"
        }
      }
    }
  ]
}
EOF
  
  # Create the role
  ROLE_ARN=$(aws iam create-role \
    --role-name $ROLE_NAME \
    --assume-role-policy-document file://trust-policy.json \
    --query 'Role.Arn' \
    --output text)
  
  # Attach the policy to the role
  aws iam attach-role-policy \
    --role-name $ROLE_NAME \
    --policy-arn $POLICY_ARN
  
  # Clean up
  rm trust-policy.json
  
  echo -e "${GREEN}IAM role created and policy attached: $ROLE_ARN${NC}"
fi

# Update service account with the IAM role
echo -e "${GREEN}Updating Kubernetes service account with IAM role annotation...${NC}"
cat > service-account.yaml << EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: $SERVICE_ACCOUNT_NAME
  namespace: $NAMESPACE
  annotations:
    eks.amazonaws.com/role-arn: $ROLE_ARN
EOF

kubectl apply -f service-account.yaml

# Clean up
rm service-account.yaml

echo -e "${GREEN}=== IRSA setup for AWS Load Balancer Controller complete ===${NC}"
echo -e "Now you need to update the Load Balancer Controller deployment to use the service account"

# Update Helm chart for AWS Load Balancer Controller
echo -e "${GREEN}Updating AWS Load Balancer Controller Helm chart to use IRSA...${NC}"
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  --namespace kube-system \
  --set clusterName=milvus-cluster \
  --set serviceAccount.create=false \
  --set serviceAccount.name=$SERVICE_ACCOUNT_NAME \
  --set region=$AWS_REGION

echo -e "${GREEN}AWS Load Balancer Controller has been updated to use IRSA.${NC}"
echo -e "${GREEN}Waiting for the AWS Load Balancer Controller pods to restart...${NC}"
kubectl rollout restart deployment aws-load-balancer-controller -n kube-system
kubectl rollout status deployment aws-load-balancer-controller -n kube-system

echo -e "${GREEN}=== IRSA setup complete! ===${NC}"
echo -e "The AWS Load Balancer Controller should now have proper permissions to create load balancers."
