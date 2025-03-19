#!/bin/bash
set -e

# Colors for better output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Script Configuration - These values should match your CDK outputs
CLUSTER_NAME="milvus-cluster"
EKS_NAMESPACE="milvus"
REGION=$(aws configure get region || echo "eu-central-1")
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

# Step 2: Install AWS EBS CSI Driver
echo -e "${GREEN}Step 2: Installing AWS EBS CSI Driver${NC}"
kubectl apply -k "github.com/kubernetes-sigs/aws-ebs-csi-driver/deploy/kubernetes/overlays/stable/?ref=master"
echo

# Step 3: Create Storage Class for EBS volumes
echo -e "${GREEN}Step 3: Creating gp3 Storage Class for EBS volumes${NC}"
cat <<EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ebs-gp3-sc
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: ebs.csi.aws.com
volumeBindingMode: WaitForFirstConsumer
parameters:
  type: gp3
EOF

# Update the existing gp2 storage class to not be default
cat <<EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp2
  annotations:
    storageclass.kubernetes.io/is-default-class: "false"
provisioner: kubernetes.io/aws-ebs
EOF
echo

# Step 4: Install AWS Load Balancer Controller
echo -e "${GREEN}Step 4: Installing AWS Load Balancer Controller${NC}"
helm repo add eks https://aws.github.io/eks-charts
helm repo update
# Check if the controller is already installed
if ! helm list -n kube-system | grep -q aws-load-balancer-controller; then
  helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
    --namespace kube-system \
    --set clusterName=$CLUSTER_NAME \
    --set serviceAccount.create=true \
    --set serviceAccount.name=aws-load-balancer-controller
else
  echo "AWS Load Balancer Controller already installed, updating..."
  helm upgrade aws-load-balancer-controller eks/aws-load-balancer-controller \
    --namespace kube-system \
    --set clusterName=$CLUSTER_NAME \
    --set serviceAccount.create=true \
    --set serviceAccount.name=aws-load-balancer-controller
fi
echo

# Step 5: Install Milvus using Helm
echo -e "${GREEN}Step 5: Installing Milvus using Helm${NC}"
# Create namespace if it doesn't exist
kubectl create namespace $EKS_NAMESPACE --dry-run=client -o yaml | kubectl apply -f -

# Add Milvus Helm repository
helm repo add milvus https://zilliztech.github.io/milvus-helm/
helm repo update

# Check if MILVUS_BUCKET_NAME is available
if [ -z "$MILVUS_BUCKET_NAME" ]; then
  echo -e "${RED}Error: Could not retrieve Milvus S3 bucket name from CloudFormation stack${NC}"
  echo -e "${YELLOW}Using default value: 'milvus-storage'${NC}"
  MILVUS_BUCKET_NAME="milvus-storage"
fi

# Install/upgrade Milvus
echo "Using S3 bucket: $MILVUS_BUCKET_NAME for Milvus storage"
helm upgrade --install milvus milvus/milvus \
  --namespace $EKS_NAMESPACE \
  --set cluster.enabled=true \
  --set service.type=LoadBalancer \
  --set service.annotations."service\.beta\.kubernetes\.io/aws-load-balancer-type"=external \
  --set service.annotations."service\.beta\.kubernetes\.io/aws-load-balancer-scheme"=internet-facing \
  --set service.annotations."service\.beta\.kubernetes\.io/aws-load-balancer-nlb-target-type"=ip \
  --set minio.enabled=false \
  --set externalS3.enabled=true \
  --set externalS3.host="s3.$REGION.amazonaws.com" \
  --set externalS3.port=443 \
  --set externalS3.useSSL=true \
  --set externalS3.bucketName=$MILVUS_BUCKET_NAME \
  --set externalS3.useIAM=true \
  --set externalS3.cloudProvider=aws \
  --set externalS3.region=$REGION \
  --set "rootCoordinator.resources.limits.cpu=1" \
  --set "rootCoordinator.resources.limits.memory=2Gi" \
  --set "rootCoordinator.replicas=1" \
  --set "indexCoordinator.resources.limits.cpu=0.5" \
  --set "indexCoordinator.resources.limits.memory=0.5Gi" \
  --set "indexCoordinator.replicas=1" \
  --set "queryCoordinator.resources.limits.cpu=0.5" \
  --set "queryCoordinator.resources.limits.memory=0.5Gi" \
  --set "queryCoordinator.replicas=1" \
  --set "dataCoordinator.resources.limits.cpu=0.5" \
  --set "dataCoordinator.resources.limits.memory=0.5Gi" \
  --set "dataCoordinator.replicas=1" \
  --set "proxy.resources.limits.cpu=1" \
  --set "proxy.resources.limits.memory=2Gi" \
  --set "proxy.replicas=2"
echo

# Step 6: Wait for Milvus to be ready
echo -e "${GREEN}Step 6: Waiting for Milvus to be ready${NC}"
kubectl rollout status statefulset/milvus-rootcoord --namespace $EKS_NAMESPACE --timeout=300s
kubectl rollout status statefulset/milvus-proxy --namespace $EKS_NAMESPACE --timeout=300s
echo

# Step 7: Get the Milvus endpoint
echo -e "${GREEN}Step 7: Getting Milvus Endpoint${NC}"
echo "Waiting for Load Balancer to be provisioned..."
sleep 10
MILVUS_ENDPOINT=$(kubectl get svc -n $EKS_NAMESPACE milvus-milvus -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
MILVUS_PORT="19530"

echo -e "${GREEN}Milvus has been successfully deployed!${NC}"
echo -e "${GREEN}Milvus Endpoint: ${YELLOW}$MILVUS_ENDPOINT${NC}"
echo -e "${GREEN}Milvus Port: ${YELLOW}$MILVUS_PORT${NC}"

# Step 8: Update Lambda function environment variables
echo -e "${GREEN}Step 8: Updating Lambda environment variables${NC}"
LAMBDA_FUNCTION_NAME=$(aws cloudformation describe-stacks --stack-name ChatbotStack --query "Stacks[0].Outputs[?OutputKey=='LambdaFunctionName'].OutputValue" --output text)

if [ -n "$LAMBDA_FUNCTION_NAME" ]; then
  echo "Updating Lambda function $LAMBDA_FUNCTION_NAME with Milvus endpoint"
  aws lambda update-function-configuration \
    --function-name $LAMBDA_FUNCTION_NAME \
    --environment "Variables={MILVUS_HOST=$MILVUS_ENDPOINT,MILVUS_PORT=$MILVUS_PORT}"
  echo -e "${GREEN}Lambda environment variables updated successfully!${NC}"
else
  echo -e "${YELLOW}Warning: Could not find Lambda function name from CloudFormation stack${NC}"
  echo -e "${YELLOW}You will need to manually update your Lambda function with these environment variables:${NC}"
  echo -e "${YELLOW}MILVUS_HOST=$MILVUS_ENDPOINT${NC}"
  echo -e "${YELLOW}MILVUS_PORT=$MILVUS_PORT${NC}"
fi

echo
echo -e "${GREEN}=============================================================${NC}"
echo -e "${GREEN}Milvus deployment to EKS complete!${NC}"
echo -e "${GREEN}You can now use Milvus through the endpoint: ${YELLOW}$MILVUS_ENDPOINT:$MILVUS_PORT${NC}"
echo -e "${GREEN}=============================================================${NC}"
