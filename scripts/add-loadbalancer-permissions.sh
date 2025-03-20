#!/bin/bash

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

EKS_CLUSTER_NAME=${1:-milvus-cluster}
AWS_REGION=${2:-eu-central-1}

# Load AWS credentials if available
if [ -f "lambda/.env" ]; then
  echo "Loading AWS credentials from lambda/.env"
  source lambda/.env
fi

# Get the EKS node role ARN
get_node_role_arn() {
  NODE_ROLE_ARN=$(aws eks describe-nodegroup \
    --cluster-name $EKS_CLUSTER_NAME \
    --nodegroup-name $(aws eks list-nodegroups --cluster-name $EKS_CLUSTER_NAME --query 'nodegroups[0]' --output text) \
    --query 'nodegroup.nodeRole' \
    --output text)
  
  if [ -z "$NODE_ROLE_ARN" ]; then
    echo -e "${RED}Failed to get node role ARN.${NC}"
    return 1
  fi
  
  echo $NODE_ROLE_ARN
}

# Attach managed policy to role
attach_managed_policy() {
  local role_name=$1
  local policy_arn=$2
  
  # Extract role name from ARN
  role_name=$(echo $role_name | cut -d'/' -f2)
  
  echo -e "${GREEN}Attaching policy $policy_arn to role $role_name...${NC}"
  
  # Check if policy is already attached
  ATTACHED=$(aws iam list-attached-role-policies --role-name $role_name --query "AttachedPolicies[?PolicyArn=='$policy_arn'].PolicyArn" --output text)
  
  if [ -n "$ATTACHED" ]; then
    echo -e "${YELLOW}Policy is already attached to the role.${NC}"
    return 0
  fi
  
  aws iam attach-role-policy \
    --role-name $role_name \
    --policy-arn $policy_arn
  
  if [ $? -ne 0 ]; then
    echo -e "${RED}Failed to attach policy to role.${NC}"
    return 1
  fi
  
  echo -e "${GREEN}Successfully attached policy to role.${NC}"
  return 0
}

# Main execution
echo -e "${GREEN}Adding LoadBalancer permissions to EKS nodes...${NC}"

NODE_ROLE_ARN=$(get_node_role_arn)
if [ -z "$NODE_ROLE_ARN" ]; then
  exit 1
fi

echo -e "${GREEN}Found node role: $NODE_ROLE_ARN${NC}"

# Use AWS managed policies for EKS load balancing
MANAGED_POLICIES=(
  "arn:aws:iam::aws:policy/AmazonEKSLoadBalancerControllerPolicy"
  "arn:aws:iam::aws:policy/ElasticLoadBalancingFullAccess"
)

for POLICY_ARN in "${MANAGED_POLICIES[@]}"; do
  echo -e "${GREEN}Attaching managed policy: $POLICY_ARN${NC}"
  attach_managed_policy "$NODE_ROLE_ARN" "$POLICY_ARN"
done

echo -e "${GREEN}==============================================================${NC}"
echo -e "${GREEN}LoadBalancer permissions have been added to EKS nodes.${NC}"
echo -e "${GREEN}After a few minutes, you can redeploy Milvus with LoadBalancer type.${NC}"
echo -e "${GREEN}==============================================================${NC}"
