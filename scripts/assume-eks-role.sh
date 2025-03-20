#!/bin/bash

# Colors for better output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Configuration
CLUSTER_NAME="milvus-cluster"
REGION=$(aws configure get region || echo "eu-central-1")
ADMIN_ROLE_ARN="arn:aws:iam::615022891451:role/eks-admin-role-1742411659"
SESSION_NAME="EksAdminSession"

echo -e "${GREEN}Assuming role ${ADMIN_ROLE_ARN} for EKS cluster access${NC}"

# Create temporary credentials file to store the output
TEMP_CREDS_FILE=$(mktemp)

# Get temporary credentials by assuming the role
aws sts assume-role \
  --role-arn ${ADMIN_ROLE_ARN} \
  --role-session-name ${SESSION_NAME} \
  --query "Credentials" \
  --output json > ${TEMP_CREDS_FILE}

if [ $? -ne 0 ]; then
  echo -e "${RED}Failed to assume role. Please check the role ARN and your permissions.${NC}"
  rm -f ${TEMP_CREDS_FILE}
  exit 1
fi

# Extract credentials without using jq (using grep and cut)
ACCESS_KEY=$(grep -o '"AccessKeyId": "[^"]*' ${TEMP_CREDS_FILE} | cut -d'"' -f4)
SECRET_KEY=$(grep -o '"SecretAccessKey": "[^"]*' ${TEMP_CREDS_FILE} | cut -d'"' -f4)
SESSION_TOKEN=$(grep -o '"SessionToken": "[^"]*' ${TEMP_CREDS_FILE} | cut -d'"' -f4)
EXPIRATION=$(grep -o '"Expiration": "[^"]*' ${TEMP_CREDS_FILE} | cut -d'"' -f4)

# Clean up the temporary file
rm -f ${TEMP_CREDS_FILE}

# Export the credentials
export AWS_ACCESS_KEY_ID=${ACCESS_KEY}
export AWS_SECRET_ACCESS_KEY=${SECRET_KEY}
export AWS_SESSION_TOKEN=${SESSION_TOKEN}

echo -e "${GREEN}Successfully assumed role. Credentials will expire at ${EXPIRATION}${NC}"
echo -e "${GREEN}Credentials have been exported to the current shell session.${NC}"

# Update kubeconfig to use the assumed role
echo -e "${GREEN}Updating kubeconfig with explicit credentials${NC}"

# Create AWS CLI config and credentials with the assumed role
mkdir -p ~/.aws
cat > ~/.aws/credentials << EOF
[eks-admin]
aws_access_key_id = ${ACCESS_KEY}
aws_secret_access_key = ${SECRET_KEY}
aws_session_token = ${SESSION_TOKEN}
EOF

# Update kubeconfig using the profile
aws eks update-kubeconfig \
  --name ${CLUSTER_NAME} \
  --region ${REGION} \
  --profile eks-admin \
  --role-arn ${ADMIN_ROLE_ARN}

if [ $? -ne 0 ]; then
  echo -e "${RED}Failed to update kubeconfig. Please check the cluster name and region.${NC}"
  exit 1
fi

echo -e "${GREEN}Successfully updated kubeconfig. Testing cluster access...${NC}"

# Test cluster access
if kubectl get nodes; then
  echo -e "${GREEN}Success! You now have access to the EKS cluster.${NC}"
else
  echo -e "${RED}Failed to access the cluster. Let's try with explicit AWS environment variables...${NC}"
  
  # Try using AWS CLI with explicit environment variables
  echo -e "${YELLOW}Trying alternative authentication method...${NC}"
  
  # Create a fresh kubeconfig file
  KUBECONFIG=$(mktemp)
  export KUBECONFIG
  
  # Use aws-iam-authenticator method
  aws eks update-kubeconfig \
    --name ${CLUSTER_NAME} \
    --region ${REGION} \
    --kubeconfig ${KUBECONFIG}
  
  # Test again
  if kubectl get nodes; then
    echo -e "${GREEN}Success! You now have access to the EKS cluster with the alternative method.${NC}"
    echo -e "${YELLOW}For future sessions, use this kubeconfig file: ${KUBECONFIG}${NC}"
  else
    echo -e "${RED}Both authentication methods failed. Please check your AWS and EKS configurations.${NC}"
    echo -e "${YELLOW}Possible issues:${NC}"
    echo -e "1. The IAM role may not have the correct permissions"
    echo -e "2. The aws-auth ConfigMap in the cluster may not be properly configured"
    echo -e "3. The cluster's RBAC settings may need to be updated"
    exit 1
  fi
fi

echo -e "${YELLOW}Note: These credentials are temporary and will expire at ${EXPIRATION}.${NC}"
echo -e "${YELLOW}To use these credentials in a new terminal session, run:${NC}"
echo -e "export AWS_ACCESS_KEY_ID=${ACCESS_KEY}"
echo -e "export AWS_SECRET_ACCESS_KEY=${SECRET_KEY}"
echo -e "export AWS_SESSION_TOKEN=${SESSION_TOKEN}"
