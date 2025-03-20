#!/bin/bash
# Consolidated script for preparing the EKS environment for Milvus deployment
# This script combines functionality from several individual scripts:
# - setup-eks-access.sh
# - create-lb-service-account.sh
# - tag-eks-subnets.sh
# - setup-loadbalancer-irsa.sh

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Check if required environment variables are set
if [ -z "$AWS_REGION" ]; then
  echo -e "${YELLOW}AWS_REGION not set. Using default: eu-central-1${NC}"
  AWS_REGION="eu-central-1"
fi

if [ -z "$EKS_CLUSTER_NAME" ]; then
  echo -e "${RED}EKS_CLUSTER_NAME not set. Please export EKS_CLUSTER_NAME.${NC}"
  exit 1
fi

# Check for AWS credentials
if [ -z "$AWS_ACCESS_KEY_ID" ] || [ -z "$AWS_SECRET_ACCESS_KEY" ]; then
  echo -e "${RED}AWS credentials not set. Please export AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY.${NC}"
  exit 1
fi

# Function to check if a command exists
command_exists() {
  command -v "$1" >/dev/null 2>&1
}

# Check if required tools are installed
for cmd in aws kubectl helm jq; do
  if ! command_exists $cmd; then
    echo -e "${RED}$cmd is not installed. Please install it first.${NC}"
    exit 1
  fi
done

# Function to configure AWS CLI
configure_aws_cli() {
  echo -e "${BLUE}=== Configuring AWS CLI ===${NC}"
  
  # Configure AWS CLI
  aws configure set region $AWS_REGION
  
  # Verify AWS identity
  echo -e "${GREEN}Verifying AWS identity...${NC}"
  aws sts get-caller-identity
  
  # Get VPC ID
  VPC_ID=$(aws eks describe-cluster --name $EKS_CLUSTER_NAME --query "cluster.resourcesVpcConfig.vpcId" --output text)
  echo -e "${GREEN}VPC ID: $VPC_ID${NC}"
  
  echo
}

# Function to set up EKS access
setup_eks_access() {
  echo -e "${BLUE}=== Setting up EKS Access ===${NC}"
  
  # Create kubeconfig for the EKS cluster
  echo -e "${GREEN}Creating kubeconfig for EKS cluster...${NC}"
  aws eks update-kubeconfig --name $EKS_CLUSTER_NAME --region $AWS_REGION
  
  # Test kubectl access
  echo -e "${GREEN}Testing kubectl access...${NC}"
  kubectl get svc
  
  # Get current IAM user/role ARN
  IAM_ARN=$(aws sts get-caller-identity --query "Arn" --output text)
  echo -e "${GREEN}Current IAM identity: $IAM_ARN${NC}"
  
  # Check if we need to update aws-auth ConfigMap
  echo -e "${GREEN}Checking if we need to update aws-auth ConfigMap...${NC}"
  
  # Extract the current aws-auth ConfigMap
  if kubectl get configmap aws-auth -n kube-system &>/dev/null; then
    echo -e "${GREEN}aws-auth ConfigMap exists${NC}"
    
    # Check if our ARN is already in the ConfigMap
    if kubectl get configmap aws-auth -n kube-system -o json | jq -r '.data.mapRoles' | grep -q "$IAM_ARN"; then
      echo -e "${GREEN}IAM identity already in aws-auth ConfigMap${NC}"
    else
      echo -e "${YELLOW}IAM identity not found in aws-auth ConfigMap. Adding...${NC}"
      
      # Create a patch file
      cat > aws-auth-patch.yaml << EOF
data:
  mapRoles: |
    $(kubectl get configmap aws-auth -n kube-system -o json | jq -r '.data.mapRoles')
    - rolearn: $IAM_ARN
      username: admin
      groups:
        - system:masters
EOF
      
      # Apply the patch
      kubectl patch configmap aws-auth -n kube-system --patch "$(cat aws-auth-patch.yaml)"
      
      # Clean up
      rm aws-auth-patch.yaml
      
      echo -e "${GREEN}aws-auth ConfigMap updated${NC}"
    fi
  else
    echo -e "${YELLOW}aws-auth ConfigMap not found. Creating...${NC}"
    
    # Create the aws-auth ConfigMap
    cat > aws-auth-cm.yaml << EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: aws-auth
  namespace: kube-system
data:
  mapRoles: |
    - rolearn: $IAM_ARN
      username: admin
      groups:
        - system:masters
EOF
    
    # Apply the ConfigMap
    kubectl apply -f aws-auth-cm.yaml
    
    # Clean up
    rm aws-auth-cm.yaml
    
    echo -e "${GREEN}aws-auth ConfigMap created${NC}"
  fi
  
  echo
}

# Function to get EKS node role ARN
get_node_role_arn() {
  echo -e "${BLUE}=== Getting Node Group IAM Role ===${NC}"
  
  # Get the node group name
  NODE_GROUP=$(aws eks list-nodegroups --cluster-name $EKS_CLUSTER_NAME --region $AWS_REGION --query "nodegroups[0]" --output text)
  
  if [ -z "$NODE_GROUP" ] || [ "$NODE_GROUP" == "None" ]; then
    echo -e "${RED}No node group found for cluster $EKS_CLUSTER_NAME${NC}"
    exit 1
  fi
  
  echo -e "${GREEN}Node group: $NODE_GROUP${NC}"
  
  # Get the node role ARN
  NODE_ROLE_ARN=$(aws eks describe-nodegroup --cluster-name $EKS_CLUSTER_NAME --nodegroup-name $NODE_GROUP --region $AWS_REGION --query "nodegroup.nodeRole" --output text)
  
  if [ -z "$NODE_ROLE_ARN" ] || [ "$NODE_ROLE_ARN" == "None" ]; then
    echo -e "${RED}No IAM role found for node group $NODE_GROUP${NC}"
    exit 1
  fi
  
  echo -e "${GREEN}Node role ARN: $NODE_ROLE_ARN${NC}"
  
  echo
}

# Function to tag subnets for LoadBalancer access
tag_eks_subnets() {
  echo -e "${BLUE}=== Tagging EKS Subnets for LoadBalancer ===${NC}"
  
  # Get all subnets in the VPC
  SUBNETS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --query "Subnets[*].{ID:SubnetId,AZ:AvailabilityZone,Public:MapPublicIpOnLaunch}" --output json)
  
  # Tag public subnets
  echo -e "${GREEN}Tagging public subnets...${NC}"
  PUBLIC_SUBNETS=$(echo $SUBNETS | jq -r '.[] | select(.Public==true) | .ID')
  
  for subnet in $PUBLIC_SUBNETS; do
    echo -e "${GREEN}Tagging subnet $subnet as public ELB subnet${NC}"
    aws ec2 create-tags --resources $subnet --tags Key=kubernetes.io/role/elb,Value=1
    aws ec2 create-tags --resources $subnet --tags Key=kubernetes.io/cluster/$EKS_CLUSTER_NAME,Value=shared
  done
  
  # Tag private subnets
  echo -e "${GREEN}Tagging private subnets...${NC}"
  PRIVATE_SUBNETS=$(echo $SUBNETS | jq -r '.[] | select(.Public==false) | .ID')
  
  for subnet in $PRIVATE_SUBNETS; do
    echo -e "${GREEN}Tagging subnet $subnet as private ELB subnet${NC}"
    aws ec2 create-tags --resources $subnet --tags Key=kubernetes.io/role/internal-elb,Value=1
    aws ec2 create-tags --resources $subnet --tags Key=kubernetes.io/cluster/$EKS_CLUSTER_NAME,Value=shared
  done
  
  echo
}

# Function to create IAM policy for Load Balancer Controller
create_lb_iam_policy() {
  echo -e "${BLUE}=== Creating IAM Policy for Load Balancer Controller ===${NC}"
  
  # Check if policy already exists
  LB_POLICY_ARN=$(aws iam list-policies --query "Policies[?PolicyName=='AWSLoadBalancerControllerIAMPolicy'].Arn" --output text)
  
  if [ -z "$LB_POLICY_ARN" ] || [ "$LB_POLICY_ARN" == "None" ]; then
    echo -e "${GREEN}Creating new IAM policy for AWS Load Balancer Controller...${NC}"
    
    # Download the policy document
    echo -e "${GREEN}Downloading policy document...${NC}"
    curl -o iam_policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json
    
    # Create the policy
    LB_POLICY_ARN=$(aws iam create-policy \
      --policy-name AWSLoadBalancerControllerIAMPolicy \
      --policy-document file://iam_policy.json \
      --query "Policy.Arn" \
      --output text)
    
    # Clean up
    rm iam_policy.json
  else
    echo -e "${GREEN}IAM policy for AWS Load Balancer Controller already exists${NC}"
  fi
  
  echo -e "${GREEN}Load Balancer Controller IAM Policy ARN: $LB_POLICY_ARN${NC}"
  
  echo
}

# Function to create IAM role for Load Balancer Controller
create_lb_iam_role() {
  echo -e "${BLUE}=== Creating IAM Role for Load Balancer Controller ===${NC}"
  
  # Create trust policy document
  cat > lb-trust-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::$(aws sts get-caller-identity --query "Account" --output text):oidc-provider/$(aws eks describe-cluster --name $EKS_CLUSTER_NAME --query "cluster.identity.oidc.issuer" --output text | sed 's|https://||')"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "$(aws eks describe-cluster --name $EKS_CLUSTER_NAME --query "cluster.identity.oidc.issuer" --output text | sed 's|https://||'):sub": "system:serviceaccount:kube-system:aws-load-balancer-controller"
        }
      }
    }
  ]
}
EOF
  
  # Check if role already exists
  LB_ROLE_ARN=$(aws iam list-roles --query "Roles[?RoleName=='AmazonEKSLoadBalancerControllerRole'].Arn" --output text)
  
  if [ -z "$LB_ROLE_ARN" ] || [ "$LB_ROLE_ARN" == "None" ]; then
    echo -e "${GREEN}Creating new IAM role for AWS Load Balancer Controller...${NC}"
    
    # Create the role
    LB_ROLE_ARN=$(aws iam create-role \
      --role-name AmazonEKSLoadBalancerControllerRole \
      --assume-role-policy-document file://lb-trust-policy.json \
      --query "Role.Arn" \
      --output text)
      
    # Attach the policy to the role
    aws iam attach-role-policy \
      --role-name AmazonEKSLoadBalancerControllerRole \
      --policy-arn $LB_POLICY_ARN
  else
    echo -e "${GREEN}IAM role for AWS Load Balancer Controller already exists${NC}"
  fi
  
  # Clean up
  rm lb-trust-policy.json
  
  echo -e "${GREEN}Load Balancer Controller IAM Role ARN: $LB_ROLE_ARN${NC}"
  
  echo
}

# Function to create service account for Load Balancer Controller
create_lb_service_account() {
  echo -e "${BLUE}=== Creating Service Account for Load Balancer Controller ===${NC}"
  
  # Create service account manifest
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
    eks.amazonaws.com/role-arn: $LB_ROLE_ARN
EOF
  
  # Apply service account
  echo -e "${GREEN}Creating service account...${NC}"
  kubectl apply -f aws-lb-service-account.yaml
  
  # Clean up
  # Keep the file for reference
  mv aws-lb-service-account.yaml ../aws-lb-service-account.yaml
  
  echo
}

# Function to install AWS Load Balancer Controller
install_lb_controller() {
  echo -e "${BLUE}=== Installing AWS Load Balancer Controller ===${NC}"
  
  # Add helm repo if not already added
  if ! helm repo list | grep -q "eks"; then
    echo -e "${GREEN}Adding eks helm repo...${NC}"
    helm repo add eks https://aws.github.io/eks-charts
    helm repo update
  fi
  
  # Check if controller is already installed
  if kubectl get deployment -n kube-system aws-load-balancer-controller &>/dev/null; then
    echo -e "${GREEN}AWS Load Balancer Controller already installed, updating...${NC}"
    
    # Update controller
    helm upgrade aws-load-balancer-controller eks/aws-load-balancer-controller \
      -n kube-system \
      --set clusterName=$EKS_CLUSTER_NAME \
      --set serviceAccount.create=false \
      --set serviceAccount.name=aws-load-balancer-controller \
      --set region=$AWS_REGION
  else
    echo -e "${GREEN}Installing AWS Load Balancer Controller...${NC}"
    
    # Install controller
    helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
      -n kube-system \
      --set clusterName=$EKS_CLUSTER_NAME \
      --set serviceAccount.create=false \
      --set serviceAccount.name=aws-load-balancer-controller \
      --set region=$AWS_REGION
  fi
  
  # Wait for controller to be ready
  echo -e "${GREEN}Waiting for controller to be ready...${NC}"
  kubectl wait --for=condition=available --timeout=180s deployment/aws-load-balancer-controller -n kube-system
  
  # Verify controller deployment
  echo -e "${GREEN}AWS Load Balancer Controller pods:${NC}"
  kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller
  
  echo
}

# Function to create namespace for Milvus
create_milvus_namespace() {
  echo -e "${BLUE}=== Creating Namespace for Milvus ===${NC}"
  
  # Set default namespace if not provided
  if [ -z "$EKS_NAMESPACE" ]; then
    EKS_NAMESPACE="milvus"
    echo -e "${YELLOW}EKS_NAMESPACE not set. Using default: milvus${NC}"
  fi
  
  # Create namespace if it doesn't exist
  if ! kubectl get namespace $EKS_NAMESPACE &>/dev/null; then
    echo -e "${GREEN}Creating namespace $EKS_NAMESPACE...${NC}"
    kubectl create namespace $EKS_NAMESPACE
  else
    echo -e "${GREEN}Namespace $EKS_NAMESPACE already exists${NC}"
  fi
  
  echo
}

# Function to validate the setup
validate_setup() {
  echo -e "${BLUE}=== Validating EKS Environment Setup ===${NC}"
  
  # Check kubectl access
  echo -e "${GREEN}Checking kubectl access...${NC}"
  if kubectl get nodes &>/dev/null; then
    echo -e "${GREEN}✅ kubectl access is working${NC}"
  else
    echo -e "${RED}❌ kubectl access is not working${NC}"
  fi
  
  # Check Load Balancer Controller
  echo -e "${GREEN}Checking AWS Load Balancer Controller...${NC}"
  if kubectl get deployment -n kube-system aws-load-balancer-controller &>/dev/null; then
    echo -e "${GREEN}✅ AWS Load Balancer Controller is installed${NC}"
  else
    echo -e "${RED}❌ AWS Load Balancer Controller is not installed${NC}"
  fi
  
  # Check subnet tagging
  echo -e "${GREEN}Checking subnet tagging...${NC}"
  PUBLIC_TAGGED=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:kubernetes.io/role/elb,Values=1" --query "Subnets[*].SubnetId" --output text)
  PRIVATE_TAGGED=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:kubernetes.io/role/internal-elb,Values=1" --query "Subnets[*].SubnetId" --output text)
  
  if [ -n "$PUBLIC_TAGGED" ]; then
    echo -e "${GREEN}✅ Public subnets are tagged for ELB: $PUBLIC_TAGGED${NC}"
  else
    echo -e "${RED}❌ No public subnets tagged for ELB${NC}"
  fi
  
  if [ -n "$PRIVATE_TAGGED" ]; then
    echo -e "${GREEN}✅ Private subnets are tagged for internal ELB: $PRIVATE_TAGGED${NC}"
  else
    echo -e "${RED}❌ No private subnets tagged for internal ELB${NC}"
  fi
  
  # Check Milvus namespace
  echo -e "${GREEN}Checking Milvus namespace...${NC}"
  if kubectl get namespace $EKS_NAMESPACE &>/dev/null; then
    echo -e "${GREEN}✅ Milvus namespace ($EKS_NAMESPACE) exists${NC}"
  else
    echo -e "${RED}❌ Milvus namespace ($EKS_NAMESPACE) does not exist${NC}"
  fi
  
  echo
}

# Main script execution
main() {
  echo -e "${BLUE}=======================================================${NC}"
  echo -e "${BLUE}  Preparing EKS Environment for Milvus Deployment${NC}"
  echo -e "${BLUE}=======================================================${NC}"
  echo
  
  # Execute functions
  configure_aws_cli
  setup_eks_access
  get_node_role_arn
  tag_eks_subnets
  create_lb_iam_policy
  create_lb_iam_role
  create_lb_service_account
  install_lb_controller
  create_milvus_namespace
  validate_setup
  
  echo -e "${BLUE}=======================================================${NC}"
  echo -e "${GREEN}EKS environment setup complete!${NC}"
  echo -e "${BLUE}=======================================================${NC}"
  echo
  echo -e "${GREEN}Next steps:${NC}"
  echo -e "1. Deploy Milvus with the following command:${NC}"
  echo -e "   ${YELLOW}./scripts/deploy-milvus-to-eks.sh${NC}"
  echo -e "2. Configure DNS with the following command:${NC}"
  echo -e "   ${YELLOW}./scripts/configure-milvus-dns.sh --hosted-zone-id <HOSTED_ZONE_ID> --dns-name <DNS_NAME>${NC}"
  echo -e "3. Test the Milvus connection with:${NC}"
  echo -e "   ${YELLOW}python ./scripts/test-milvus-connection.py${NC}"
  echo
}

# Execute the main function
main
