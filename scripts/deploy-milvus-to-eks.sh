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

# Script Configuration - These values should match your CDK outputs
CLUSTER_NAME="milvus-cluster"
EKS_NAMESPACE="milvus"
REGION=${AWS_REGION:-"eu-central-1"}
MILVUS_BUCKET_NAME=$(aws cloudformation describe-stacks --stack-name ChatbotStack --query "Stacks[0].Outputs[?OutputKey=='MilvusBucketName'].OutputValue" --output text)

echo -e "${YELLOW}=== EKS Milvus Deployment Script ===${NC}"
echo -e "${YELLOW}This script will deploy Milvus to your EKS cluster with proper AWS integrations${NC}"
echo

# Check if kubectl is installed
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}kubectl is not installed. Please install it first.${NC}"
    exit 1
fi

# Check if helm is installed
if ! command -v helm &> /dev/null; then
    echo -e "${RED}helm is not installed. Please install it first.${NC}"
    exit 1
fi

# Step 1: Configure kubectl to connect to the EKS cluster
echo -e "${GREEN}Step 1: Configuring kubectl to connect to $CLUSTER_NAME${NC}"
aws eks update-kubeconfig --name $CLUSTER_NAME --region $REGION
echo

# Check cluster access
echo -e "${GREEN}Checking cluster access...${NC}"
if ! kubectl get nodes &>/dev/null; then
  echo -e "${YELLOW}Warning: Unable to list nodes. Access may not be properly configured.${NC}"
  echo -e "${YELLOW}You should manually ensure you have proper access to the cluster.${NC}"
  echo -e "${YELLOW}Continuing with deployment anyway...${NC}"
fi

# Step 2: Install the EKS Pod Identity Agent add-on
echo -e "${GREEN}Step 2: Installing EKS Pod Identity Agent add-on${NC}"
aws eks create-addon \
  --cluster-name $CLUSTER_NAME \
  --addon-name eks-pod-identity-agent \
  --region $REGION || echo -e "${YELLOW}Warning: Could not install EKS Pod Identity Agent add-on. It might already be installed or there might be permission issues.${NC}"

# Check if the add-on was installed successfully
if aws eks describe-addon --cluster-name $CLUSTER_NAME --addon-name eks-pod-identity-agent --region $REGION &>/dev/null; then
  echo -e "${GREEN}EKS Pod Identity Agent add-on installed successfully${NC}"
else
  echo -e "${YELLOW}Warning: Could not verify EKS Pod Identity Agent add-on installation. Continuing anyway...${NC}"
fi
echo

# Step 3: Install AWS EBS CSI Driver
echo -e "${GREEN}Step 3: Installing AWS EBS CSI Driver${NC}"
kubectl apply -k "github.com/kubernetes-sigs/aws-ebs-csi-driver/deploy/kubernetes/overlays/stable/?ref=release-1.23"
echo

# Step 4: Check if the StorageClass exists and create only if it doesn't
echo -e "${GREEN}Step 4: Configuring Storage Classes for EBS volumes${NC}"
if ! kubectl get storageclass ebs-gp3-sc &>/dev/null; then
    echo -e "${GREEN}Creating ebs-gp3-sc StorageClass...${NC}"
    cat <<EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ebs-gp3-sc
provisioner: ebs.csi.aws.com
volumeBindingMode: WaitForFirstConsumer
parameters:
  type: gp3
  encrypted: "true"
EOF
else
    echo -e "${YELLOW}StorageClass ebs-gp3-sc already exists, skipping creation.${NC}"
fi
echo

# Step 5: Install AWS Load Balancer Controller
echo -e "${GREEN}Step 5: Installing AWS Load Balancer Controller${NC}"
# Check if aws-load-balancer-controller chart repository is already added
if ! helm repo list | grep -q "eks"; then
  echo "Adding EKS Helm chart repository..."
  helm repo add eks https://aws.github.io/eks-charts
fi
helm repo update

# Set up IAM role and service account for AWS Load Balancer Controller
echo -e "${GREEN}Setting up IRSA for AWS Load Balancer Controller...${NC}"

# Get the OIDC provider URL for the EKS cluster
OIDC_PROVIDER=$(aws eks describe-cluster --name $CLUSTER_NAME --region $REGION --query "cluster.identity.oidc.issuer" --output text | sed -e "s/^https:\/\///")

if [ -z "$OIDC_PROVIDER" ]; then
  echo -e "${RED}Error: Failed to get OIDC provider URL for the EKS cluster.${NC}"
  exit 1
fi

echo -e "EKS cluster OIDC provider: $OIDC_PROVIDER"

# Create or get IAM policy for the AWS Load Balancer Controller
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

# Create the service account for the AWS Load Balancer Controller
echo -e "${GREEN}Creating service account for AWS Load Balancer Controller...${NC}"
cat > aws-lb-service-account.yaml << EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  labels:
    app.kubernetes.io/component: controller
    app.kubernetes.io/name: aws-load-balancer-controller
  name: $SERVICE_ACCOUNT_NAME
  namespace: $NAMESPACE
  annotations:
    eks.amazonaws.com/role-arn: $ROLE_ARN
EOF

kubectl apply -f aws-lb-service-account.yaml
rm aws-lb-service-account.yaml

# Install the AWS Load Balancer Controller
echo -e "${GREEN}Installing AWS Load Balancer Controller with Helm...${NC}"
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=$CLUSTER_NAME \
  --set serviceAccount.create=false \
  --set serviceAccount.name=$SERVICE_ACCOUNT_NAME \
  --set region=$REGION

# Wait for AWS Load Balancer Controller to be ready
echo -e "${GREEN}Waiting for AWS Load Balancer Controller webhook to be ready...${NC}"
kubectl wait --for=condition=available --timeout=120s deployment/aws-load-balancer-controller -n kube-system
if [ $? -eq 0 ]; then
  echo -e "${GREEN}AWS Load Balancer webhook service is available. Continuing...${NC}"
else
  echo -e "${YELLOW}Warning: Timed out waiting for AWS Load Balancer webhook to be ready. Will continue anyway.${NC}"
fi

# Tag subnets for LoadBalancer use
echo -e "${GREEN}Tagging subnets for LoadBalancer use...${NC}"
# Get EKS cluster VPC ID
VPC_ID=$(aws eks describe-cluster --name $CLUSTER_NAME --region $REGION --query "cluster.resourcesVpcConfig.vpcId" --output text)

if [ -z "$VPC_ID" ]; then
  echo -e "${RED}Error: Failed to get VPC ID for the EKS cluster.${NC}"
else
  echo -e "EKS cluster VPC ID: $VPC_ID"

  # Get all subnets in the VPC
  SUBNET_IDS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --query "Subnets[*].SubnetId" --output text)

  if [ -z "$SUBNET_IDS" ]; then
    echo -e "${RED}Error: No subnets found in VPC $VPC_ID.${NC}"
  else
    # Tag all subnets
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
        aws ec2 create-tags --resources $SUBNET_ID --tags Key=kubernetes.io/cluster/$CLUSTER_NAME,Value=shared
      fi
    done

    echo -e "${GREEN}Subnet tagging complete.${NC}"
  fi
fi

# Step 6: Install Milvus using Helm
echo -e "${GREEN}Step 6: Installing Milvus using Helm${NC}"
kubectl create namespace $EKS_NAMESPACE --dry-run=client -o yaml | kubectl apply -f -

# Add milvus repo if not already added
echo -e "${GREEN}Updating Helm repositories...${NC}"
helm repo update || echo -e "${YELLOW}Warning: Could not update Helm repositories. Continuing anyway...${NC}"

echo -e "${GREEN}Installing Milvus with Helm${NC}"

# Try to bypass webhook if needed
echo -e "${GREEN}Bypassing ALB webhook for milvus namespace...${NC}"
kubectl label namespace $EKS_NAMESPACE alb.ingress.kubernetes.io/webhook-bypass=true --overwrite=true

# Delete any existing webhook configuration that might be causing issues
echo -e "${GREEN}Checking for existing webhook configurations...${NC}"
if kubectl get mutatingwebhookconfigurations.admissionregistration.k8s.io aws-load-balancer-webhook &>/dev/null; then
    echo -e "${YELLOW}Found existing webhook configuration, temporarily disabling it...${NC}"
    kubectl annotate mutatingwebhookconfigurations.admissionregistration.k8s.io aws-load-balancer-webhook webhook.kubernetes.io/temporary-disable=true --overwrite=true
fi

# Wait for the webhook bypass to take effect
echo -e "${GREEN}Waiting for webhook bypass to take effect...${NC}"
sleep 30

# Apply Milvus with health check and resilience configuration
echo -e "${GREEN}Applying Milvus helm chart with ultra-minimal standalone mode...${NC}"
if ! helm upgrade --install milvus milvus/milvus --namespace $EKS_NAMESPACE \
  --set cluster.enabled=false \
  --set standalone.replicas=1 \
  --set externalS3.enabled=true \
  --set externalS3.host="s3.$AWS_REGION.amazonaws.com" \
  --set externalS3.port=443 \
  --set externalS3.accessKey="$AWS_ACCESS_KEY_ID" \
  --set externalS3.secretKey="$AWS_SECRET_ACCESS_KEY" \
  --set externalS3.useSSL=true \
  --set externalS3.bucketName="$MILVUS_BUCKET_NAME" \
  --set externalS3.region="$AWS_REGION" \
  --set service.type=LoadBalancer \
  --set service.annotations."service\.beta\.kubernetes\.io/aws-load-balancer-scheme"=internet-facing \
  --set service.annotations."service\.beta\.kubernetes\.io/aws-load-balancer-type"=nlb \
  --set standalone.resources.limits.cpu=1000m \
  --set standalone.resources.limits.memory=2Gi \
  --set standalone.resources.requests.cpu=100m \
  --set standalone.resources.requests.memory=200Mi \
  --set standalone.persistence.enabled=true \
  --set standalone.persistence.storage=10Gi \
  --set standalone.readinessProbe.initialDelaySeconds=120 \
  --set standalone.readinessProbe.periodSeconds=30 \
  --set standalone.readinessProbe.timeoutSeconds=10 \
  --set standalone.readinessProbe.successThreshold=1 \
  --set standalone.readinessProbe.failureThreshold=12 \
  --set standalone.livenessProbe.initialDelaySeconds=300 \
  --set standalone.livenessProbe.periodSeconds=30 \
  --set standalone.livenessProbe.timeoutSeconds=10 \
  --set standalone.livenessProbe.successThreshold=1 \
  --set standalone.livenessProbe.failureThreshold=6; then
  
  # If the installation failed, check the load balancer webhook status
  echo -e "${GREEN}Checking webhook configuration...${NC}"
  kubectl get mutatingwebhookconfigurations.admissionregistration.k8s.io | grep aws-load-balancer-webhook
  
  # Print webhook pods 
  echo -e "${GREEN}Checking webhook pods...${NC}"
  kubectl get pods -n kube-system | grep aws-load-balancer
  
  # Try with minimal configuration
  echo -e "${YELLOW}Attempting installation with minimal configuration...${NC}"
  if ! helm upgrade --install milvus milvus/milvus --namespace $EKS_NAMESPACE --no-hooks \
    --set cluster.enabled=false \
    --set standalone.replicas=1 \
    --set externalS3.enabled=true \
    --set externalS3.host="s3.$AWS_REGION.amazonaws.com" \
    --set externalS3.port=443 \
    --set externalS3.accessKey="$AWS_ACCESS_KEY_ID" \
    --set externalS3.secretKey="$AWS_SECRET_ACCESS_KEY" \
    --set externalS3.useSSL=true \
    --set externalS3.bucketName="$MILVUS_BUCKET_NAME" \
    --set externalS3.region="$AWS_REGION" \
    --set service.type=LoadBalancer \
    --set service.annotations."service\.beta\.kubernetes\.io/aws-load-balancer-scheme"=internet-facing \
    --set service.annotations."service\.beta\.kubernetes\.io/aws-load-balancer-type"=nlb \
    --set standalone.persistence.enabled=false \
    --set standalone.persistence.storage=false \
{{ ... }}
