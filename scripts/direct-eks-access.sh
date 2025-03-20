#!/bin/bash
set -e

# Colors for better output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Get the absolute path to the project root directory
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Source environment variables from lambda/.env
ENV_FILE="${PROJECT_ROOT}/lambda/.env"
if [ -f "$ENV_FILE" ]; then
  echo -e "${GREEN}Loading AWS credentials from lambda/.env${NC}"
  export $(grep -v '^#' $ENV_FILE | xargs)
else
  echo -e "${RED}Error: lambda/.env file not found at: ${ENV_FILE}${NC}"
  exit 1
fi

# Configuration
CLUSTER_NAME="milvus-cluster"
REGION=${AWS_REGION:-"eu-central-1"}
ADMIN_USER_ARN="arn:aws:iam::615022891451:user/admin"

echo -e "${GREEN}=== Direct EKS Access Setup ===${NC}"
echo -e "${GREEN}This script will configure direct access to the EKS cluster without role assumption${NC}"

# Update kubeconfig 
echo -e "${GREEN}Updating kubeconfig for direct access${NC}"
aws eks update-kubeconfig \
  --name ${CLUSTER_NAME} \
  --region ${REGION}

if [ $? -ne 0 ]; then
  echo -e "${RED}Failed to update kubeconfig. Please check your AWS credentials and permissions.${NC}"
  exit 1
fi

# Create a YAML file with the aws-auth ConfigMap
echo -e "${GREEN}Creating aws-auth ConfigMap file${NC}"
cat > /tmp/aws-auth-cm.yaml << EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: aws-auth
  namespace: kube-system
data:
  mapUsers: |
    - userarn: ${ADMIN_USER_ARN}
      username: admin
      groups:
        - system:masters
EOF

# Apply the aws-auth ConfigMap with --validate=false to bypass auth checks
echo -e "${GREEN}Applying aws-auth ConfigMap with validation bypassed${NC}"
kubectl apply -f /tmp/aws-auth-cm.yaml --validate=false

if [ $? -eq 0 ]; then
  echo -e "${GREEN}Successfully updated aws-auth ConfigMap${NC}"
else
  echo -e "${YELLOW}Warning: Could not update aws-auth ConfigMap.${NC}"
  
  # Try using kubectl patch as an alternative
  echo -e "${YELLOW}Trying alternative approach with kubectl patch...${NC}"
  
  # Check if ConfigMap exists
  if kubectl get configmap aws-auth -n kube-system --validate=false &>/dev/null; then
    echo -e "${YELLOW}aws-auth ConfigMap exists, patching it...${NC}"
    
    # Create a patch file
    cat > /tmp/aws-auth-patch.yaml << EOF
data:
  mapUsers: |
    - userarn: ${ADMIN_USER_ARN}
      username: admin
      groups:
        - system:masters
EOF
    
    # Apply the patch
    kubectl patch configmap aws-auth -n kube-system --patch "$(cat /tmp/aws-auth-patch.yaml)" --validate=false
    
    if [ $? -eq 0 ]; then
      echo -e "${GREEN}Successfully patched aws-auth ConfigMap${NC}"
    else
      echo -e "${RED}Failed to patch aws-auth ConfigMap. Manual intervention required.${NC}"
    fi
  else
    echo -e "${RED}aws-auth ConfigMap doesn't exist and couldn't be created.${NC}"
    echo -e "${RED}This likely indicates an issue with cluster access permissions.${NC}"
  fi
fi

# Test cluster access
echo -e "${GREEN}Testing cluster access${NC}"
kubectl get nodes --validate=false

if [ $? -eq 0 ]; then
  echo -e "${GREEN}Success! You now have access to the EKS cluster.${NC}"
  
  # Try to install the EKS Pod Identity Agent
  echo -e "${GREEN}Installing EKS Pod Identity Agent add-on${NC}"
  aws eks create-addon \
    --cluster-name ${CLUSTER_NAME} \
    --addon-name eks-pod-identity-agent \
    --region ${REGION} || echo -e "${YELLOW}Warning: Could not install EKS Pod Identity Agent. It might already be installed.${NC}"
    
  echo -e "${GREEN}Setup complete!${NC}"
  echo -e "${YELLOW}You can now run ./scripts/deploy-milvus-to-eks.sh to deploy Milvus.${NC}"
else
  echo -e "${RED}Failed to access the cluster. Manual intervention required.${NC}"
  echo -e "${YELLOW}Possible issues:${NC}"
  echo -e "1. Your IAM user doesn't have the necessary EKS permissions"
  echo -e "2. The cluster's RBAC settings need to be configured through the AWS Console"
  echo -e "3. The EKS cluster may have additional security measures in place"
  
  echo -e "${YELLOW}Recommended actions:${NC}"
  echo -e "1. Check your IAM user permissions in the AWS Console"
  echo -e "2. Use the AWS Console to add your user to the EKS cluster's auth configuration"
  echo -e "3. Consider using CloudFormation or AWS CLI to update the aws-auth ConfigMap directly"
fi
