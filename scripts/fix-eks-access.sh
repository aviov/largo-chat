#!/bin/bash

# Colors for better output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Configuration
CLUSTER_NAME="milvus-cluster"
REGION=$(aws configure get region || echo "eu-central-1")
ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
ADMIN_USER_ARN="arn:aws:iam::${ACCOUNT_ID}:user/admin"

echo -e "${GREEN}Fixing EKS access for cluster: ${CLUSTER_NAME}${NC}"

# Step 1: Create an IAM role for EKS admin access
echo -e "${GREEN}Step 1: Creating temporary admin role for EKS cluster access${NC}"

# Create trust policy document
cat > /tmp/eks-admin-trust-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "AWS": "${ADMIN_USER_ARN}"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

# Create admin role
ROLE_NAME="eks-admin-role-$(date +%s)"
aws iam create-role \
  --role-name ${ROLE_NAME} \
  --assume-role-policy-document file:///tmp/eks-admin-trust-policy.json

# Attach EKS admin policies
aws iam attach-role-policy \
  --role-name ${ROLE_NAME} \
  --policy-arn arn:aws:iam::aws:policy/AmazonEKSClusterPolicy

aws iam attach-role-policy \
  --role-name ${ROLE_NAME} \
  --policy-arn arn:aws:iam::aws:policy/AmazonEKSServicePolicy

ADMIN_ROLE_ARN=$(aws iam get-role --role-name ${ROLE_NAME} --query "Role.Arn" --output text)
echo -e "${GREEN}Created temporary admin role: ${ADMIN_ROLE_ARN}${NC}"

# Step 2: Update aws-auth ConfigMap with the new role
echo -e "${GREEN}Step 2: Updating aws-auth ConfigMap${NC}"

# Configure kubectl
aws eks update-kubeconfig --name ${CLUSTER_NAME} --region ${REGION}

# Check if aws-auth ConfigMap exists
if kubectl get configmap aws-auth -n kube-system &>/dev/null; then
  echo "aws-auth ConfigMap exists, updating it"
  
  # Get current aws-auth ConfigMap
  kubectl get configmap aws-auth -n kube-system -o yaml > /tmp/aws-auth.yaml
  
  # Backup the original ConfigMap
  cp /tmp/aws-auth.yaml /tmp/aws-auth.yaml.bak
  
  # Update aws-auth ConfigMap with both the admin role and direct user mapping
  cat > /tmp/aws-auth-patch.yaml << EOF
data:
  mapRoles: |
    - rolearn: ${ADMIN_ROLE_ARN}
      username: admin
      groups:
        - system:masters
  mapUsers: |
    - userarn: ${ADMIN_USER_ARN}
      username: admin
      groups:
        - system:masters
EOF

  # Patch the ConfigMap
  kubectl patch configmap aws-auth -n kube-system --patch "$(cat /tmp/aws-auth-patch.yaml)"
else
  echo "aws-auth ConfigMap doesn't exist, creating it"
  
  # Create new aws-auth ConfigMap
  cat > /tmp/aws-auth.yaml << EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: aws-auth
  namespace: kube-system
data:
  mapRoles: |
    - rolearn: ${ADMIN_ROLE_ARN}
      username: admin
      groups:
        - system:masters
  mapUsers: |
    - userarn: ${ADMIN_USER_ARN}
      username: admin
      groups:
        - system:masters
EOF

  # Apply the ConfigMap
  kubectl apply -f /tmp/aws-auth.yaml
fi

# Step 3: Verify setup
echo -e "${GREEN}Step 3: Verifying EKS access${NC}"

# Try to list nodes
kubectl get nodes

if [ $? -eq 0 ]; then
  echo -e "${GREEN}EKS access verification successful!${NC}"
else
  echo -e "${YELLOW}EKS access verification failed. You may need to assume the admin role.${NC}"
  echo -e "Use the following command to assume the role:"
  echo -e "${YELLOW}aws sts assume-role --role-arn ${ADMIN_ROLE_ARN} --role-session-name EksAdminSession${NC}"
fi

echo -e "${GREEN}Admin role ARN: ${ADMIN_ROLE_ARN}${NC}"
echo -e "${GREEN}Remember to use this role when accessing the EKS cluster${NC}"

# Clean up temporary files
rm -f /tmp/eks-admin-trust-policy.json /tmp/aws-auth.yaml /tmp/aws-auth.yaml.bak /tmp/aws-auth-patch.yaml

echo -e "${GREEN}Done!${NC}"
