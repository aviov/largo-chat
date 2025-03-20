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
  echo -e "${YELLOW}Please create a lambda/.env file with the following:${NC}"
  echo -e "AWS_ACCESS_KEY_ID=your-access-key-id"
  echo -e "AWS_SECRET_ACCESS_KEY=your-secret-access-key"
  echo -e "AWS_REGION=eu-central-1"
  echo -e "AWS_DEFAULT_REGION=eu-central-1"
  exit 1
fi

# Check for required environment variables
if [ -z "$AWS_ACCESS_KEY_ID" ] || [ -z "$AWS_SECRET_ACCESS_KEY" ]; then
  echo -e "${RED}Error: AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY environment variables are required.${NC}"
  echo -e "${YELLOW}Please ensure they are correctly set in lambda/.env${NC}"
  exit 1
fi

# Configuration
CLUSTER_NAME="milvus-cluster"
REGION=${AWS_REGION:-"eu-central-1"}
AWS_DEFAULT_REGION=${REGION}
ADMIN_USER_ARN="arn:aws:iam::615022891451:user/admin"

echo -e "${GREEN}=== Complete EKS Access Setup ===${NC}"
echo -e "${GREEN}This script will configure proper access to the EKS cluster${NC}"
echo -e "${GREEN}Using AWS credentials from lambda/.env${NC}"

# Step 1: Create an IAM policy for EKS admin access
echo -e "${GREEN}Step 1: Creating EKS Admin IAM policy${NC}"

# Create policy document
cat > /tmp/eks-admin-policy.json << EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "eks:*",
                "ec2:DescribeInstances",
                "ec2:DescribeRouteTables",
                "ec2:DescribeSecurityGroups",
                "ec2:DescribeSubnets",
                "ec2:DescribeVpcs",
                "iam:ListRoles"
            ],
            "Resource": "*"
        }
    ]
}
EOF

# Create the policy
POLICY_ARN=$(aws iam create-policy \
  --policy-name EksAdminPolicy \
  --policy-document file:///tmp/eks-admin-policy.json \
  --query 'Policy.Arn' \
  --output text 2>/dev/null || \
  aws iam list-policies \
    --query 'Policies[?PolicyName==`EksAdminPolicy`].Arn' \
    --output text)

echo -e "${GREEN}EKS Admin policy created/found: ${POLICY_ARN}${NC}"

# Step 2: Create an IAM role for EKS admin access
echo -e "${GREEN}Step 2: Creating/Updating EKS Admin IAM role${NC}"

# Create trust policy
cat > /tmp/eks-admin-trust-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "AWS": "${ADMIN_USER_ARN}",
        "Service": "eks.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

# Create the role (or get existing)
ROLE_NAME="eks-admin-role"
ROLE_ARN=$(aws iam create-role \
  --role-name ${ROLE_NAME} \
  --assume-role-policy-document file:///tmp/eks-admin-trust-policy.json \
  --query 'Role.Arn' \
  --output text 2>/dev/null || \
  aws iam get-role \
    --role-name ${ROLE_NAME} \
    --query 'Role.Arn' \
    --output text)

echo -e "${GREEN}EKS Admin role created/found: ${ROLE_ARN}${NC}"

# Attach the policy to the role
aws iam attach-role-policy \
  --role-name ${ROLE_NAME} \
  --policy-arn ${POLICY_ARN}

echo -e "${GREEN}Attached EKS Admin policy to role${NC}"

# Step 3: Update the aws-auth ConfigMap
echo -e "${GREEN}Step 3: Updating aws-auth ConfigMap with admin role and user${NC}"

# First get Node Instance Role ARN
NODE_INSTANCE_ROLE=$(aws eks describe-nodegroup \
  --cluster-name ${CLUSTER_NAME} \
  --nodegroup-name milvus-nodes \
  --region ${REGION} \
  --query "nodegroup.nodeRole" \
  --output text)

echo -e "${GREEN}Node Instance Role: ${NODE_INSTANCE_ROLE}${NC}"

# Update kubeconfig to use the admin role
echo -e "${GREEN}Updating kubeconfig to use admin role${NC}"
aws eks update-kubeconfig \
  --name ${CLUSTER_NAME} \
  --region ${REGION} \
  --role-arn ${ROLE_ARN}

# Create or update aws-auth ConfigMap
echo -e "${GREEN}Creating/updating aws-auth ConfigMap...${NC}"

# Check if eksctl is installed
if ! command -v eksctl &> /dev/null; then
    echo -e "${YELLOW}eksctl not found. Using kubectl instead.${NC}"
    
    # Create aws-auth ConfigMap YAML
    cat > /tmp/aws-auth-cm.yaml << EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: aws-auth
  namespace: kube-system
data:
  mapRoles: |
    - rolearn: ${NODE_INSTANCE_ROLE}
      username: system:node:{{EC2PrivateDNSName}}
      groups:
        - system:bootstrappers
        - system:nodes
    - rolearn: ${ROLE_ARN}
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
    kubectl apply -f /tmp/aws-auth-cm.yaml --force || echo -e "${YELLOW}Warning: Could not update aws-auth ConfigMap. This might require manual intervention.${NC}"
else
    echo -e "${GREEN}Using eksctl to configure cluster access${NC}"
    
    # Associate IAM role for service accounts
    eksctl create iamserviceaccount \
      --cluster=${CLUSTER_NAME} \
      --region=${REGION} \
      --name=eks-admin \
      --namespace=kube-system \
      --role-name=${ROLE_NAME} \
      --attach-policy-arn=${POLICY_ARN} \
      --approve || echo -e "${YELLOW}Warning: Could not create IAM service account. It might already exist.${NC}"
    
    # Create IAM identity mapping for the admin role
    eksctl create iamidentitymapping \
      --cluster ${CLUSTER_NAME} \
      --region=${REGION} \
      --arn ${ROLE_ARN} \
      --username admin \
      --group system:masters || echo -e "${YELLOW}Warning: Could not create IAM identity mapping for role. It might already exist.${NC}"
    
    # Create IAM identity mapping for the admin user
    eksctl create iamidentitymapping \
      --cluster ${CLUSTER_NAME} \
      --region=${REGION} \
      --arn ${ADMIN_USER_ARN} \
      --username admin \
      --group system:masters || echo -e "${YELLOW}Warning: Could not create IAM identity mapping for user. It might already exist.${NC}"
fi

# Step 4: Verify Access with Admin Role
echo -e "${GREEN}Step 4: Verifying access with admin role${NC}"
aws eks update-kubeconfig \
  --name ${CLUSTER_NAME} \
  --region ${REGION} \
  --role-arn ${ROLE_ARN}

# Try to access the cluster
echo -e "${GREEN}Testing cluster access...${NC}"
if kubectl get nodes; then
  echo -e "${GREEN}Success! Admin role has access to the EKS cluster.${NC}"
else
  echo -e "${YELLOW}Warning: Could not verify access. Trying another approach...${NC}"
  
  # Try to assume the role explicitly
  echo -e "${GREEN}Assuming the admin role explicitly...${NC}"
  CREDS=$(aws sts assume-role \
    --role-arn ${ROLE_ARN} \
    --role-session-name EksAdminSession \
    --query 'Credentials' \
    --output json)
  
  # Extract credentials
  export AWS_ACCESS_KEY_ID=$(echo $CREDS | grep -o '"AccessKeyId": "[^"]*' | cut -d'"' -f4)
  export AWS_SECRET_ACCESS_KEY=$(echo $CREDS | grep -o '"SecretAccessKey": "[^"]*' | cut -d'"' -f4)
  export AWS_SESSION_TOKEN=$(echo $CREDS | grep -o '"SessionToken": "[^"]*' | cut -d'"' -f4)
  
  # Update kubeconfig again with fresh credentials
  aws eks update-kubeconfig \
    --name ${CLUSTER_NAME} \
    --region ${REGION}
  
  # Test access again
  if kubectl get nodes; then
    echo -e "${GREEN}Success! Admin role has access to the EKS cluster after explicit role assumption.${NC}"
  else
    echo -e "${RED}Error: Could not achieve cluster access after multiple attempts.${NC}"
    echo -e "${RED}Manual intervention may be required.${NC}"
  fi
fi

echo -e "${GREEN}Setup complete!${NC}"
echo -e "${YELLOW}To access the EKS cluster, use:${NC}"
echo -e "aws eks update-kubeconfig --name ${CLUSTER_NAME} --region ${REGION} --role-arn ${ROLE_ARN}"
echo -e "${YELLOW}For further session use, simply run:${NC}"
echo -e "export AWS_ROLE_ARN=${ROLE_ARN}"
