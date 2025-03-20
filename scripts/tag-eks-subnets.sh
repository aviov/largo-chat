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

echo -e "${GREEN}=== EKS Subnet Tagging Script ===${NC}"
echo -e "This script will tag subnets for EKS Load Balancer use"

# Get EKS cluster VPC ID
echo -e "${GREEN}Getting VPC ID for the EKS cluster...${NC}"
VPC_ID=$(aws eks describe-cluster --name milvus-cluster --region $AWS_REGION --query "cluster.resourcesVpcConfig.vpcId" --output text)

if [ -z "$VPC_ID" ]; then
  echo -e "${RED}Error: Failed to get VPC ID for the EKS cluster.${NC}"
  exit 1
fi

echo -e "EKS cluster VPC ID: $VPC_ID"

# Get all subnets in the VPC
echo -e "${GREEN}Getting subnets in VPC...${NC}"
SUBNET_IDS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --query "Subnets[*].SubnetId" --output text)

if [ -z "$SUBNET_IDS" ]; then
  echo -e "${RED}Error: No subnets found in VPC $VPC_ID.${NC}"
  exit 1
fi

# Tag all subnets
echo -e "${GREEN}Tagging subnets for EKS load balancer use...${NC}"
for SUBNET_ID in $SUBNET_IDS; do
  # Check if subnet is public by checking if it has a route to an internet gateway
  ROUTE_TABLE_ID=$(aws ec2 describe-route-tables --filters "Name=association.subnet-id,Values=$SUBNET_ID" --query "RouteTables[0].RouteTableId" --output text)
  
  if [ "$ROUTE_TABLE_ID" != "None" ]; then
    HAS_IGW=$(aws ec2 describe-route-tables --route-table-ids $ROUTE_TABLE_ID --query "RouteTables[0].Routes[?GatewayId!=null && starts_with(GatewayId, 'igw-')].GatewayId" --output text)
    
    if [ -n "$HAS_IGW" ]; then
      echo "Subnet $SUBNET_ID is public, tagging with kubernetes.io/role/elb=1"
      aws ec2 create-tags --resources $SUBNET_ID --tags Key=kubernetes.io/role/elb,Value=1
    else
      echo "Subnet $SUBNET_ID is private, tagging with kubernetes.io/role/internal-elb=1"
      aws ec2 create-tags --resources $SUBNET_ID --tags Key=kubernetes.io/role/internal-elb,Value=1
    fi
    
    # Tag all subnets with cluster ownership for good measure
    aws ec2 create-tags --resources $SUBNET_ID --tags Key=kubernetes.io/cluster/milvus-cluster,Value=shared
  fi
done

echo -e "${GREEN}=== Subnet tagging complete ===${NC}"
echo -e "Public subnets are now tagged with kubernetes.io/role/elb=1"
echo -e "Private subnets are now tagged with kubernetes.io/role/internal-elb=1"
echo -e "All subnets are tagged with kubernetes.io/cluster/milvus-cluster=shared"
