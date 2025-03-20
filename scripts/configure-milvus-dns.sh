#!/bin/bash
# Script to configure DNS for Milvus using Route53

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
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

if [ -z "$EKS_NAMESPACE" ]; then
  echo -e "${YELLOW}EKS_NAMESPACE not set. Using default: milvus${NC}"
  EKS_NAMESPACE="milvus"
fi

# Check if AWS CLI is installed
if ! command -v aws &> /dev/null; then
  echo -e "${RED}AWS CLI is not installed. Please install it first.${NC}"
  exit 1
fi

# Parse command line arguments
HOSTED_ZONE_ID=""
DNS_NAME=""

print_usage() {
  echo "Usage: $0 --hosted-zone-id <HOSTED_ZONE_ID> --dns-name <DNS_NAME>"
  echo "Example: $0 --hosted-zone-id Z1234567890ABCDEF --dns-name milvus.example.com"
}

while [[ $# -gt 0 ]]; do
  key="$1"
  case $key in
    --hosted-zone-id)
      HOSTED_ZONE_ID="$2"
      shift # past argument
      shift # past value
      ;;
    --dns-name)
      DNS_NAME="$2"
      shift # past argument
      shift # past value
      ;;
    --help)
      print_usage
      exit 0
      ;;
    *)
      echo -e "${RED}Unknown option: $1${NC}"
      print_usage
      exit 1
      ;;
  esac
done

# Validate required parameters
if [ -z "$HOSTED_ZONE_ID" ]; then
  echo -e "${RED}Error: --hosted-zone-id is required${NC}"
  print_usage
  exit 1
fi

if [ -z "$DNS_NAME" ]; then
  echo -e "${RED}Error: --dns-name is required${NC}"
  print_usage
  exit 1
fi

# Ensure kubectl is installed
if ! command -v kubectl &> /dev/null; then
  echo -e "${RED}kubectl is not installed. Please install it first.${NC}"
  exit 1
fi

# Validate AWS credentials
echo -e "${GREEN}Validating AWS credentials...${NC}"
if ! aws sts get-caller-identity &> /dev/null; then
  echo -e "${RED}Error: Invalid AWS credentials. Please check your AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY.${NC}"
  exit 1
fi

echo -e "${GREEN}Validating Route53 hosted zone...${NC}"
if ! aws route53 get-hosted-zone --id $HOSTED_ZONE_ID &> /dev/null; then
  echo -e "${RED}Error: Invalid hosted zone ID. Please check your --hosted-zone-id parameter.${NC}"
  exit 1
fi

# Get the LoadBalancer address
echo -e "${GREEN}Getting LoadBalancer address for Milvus service...${NC}"
LB_DNS_NAME=$(kubectl get svc -n $EKS_NAMESPACE milvus -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

if [ -z "$LB_DNS_NAME" ]; then
  echo -e "${RED}Error: Could not get LoadBalancer address for Milvus service.${NC}"
  echo -e "${YELLOW}Make sure the Milvus service is deployed and has a LoadBalancer.${NC}"
  echo -e "${YELLOW}Check with: kubectl get svc -n $EKS_NAMESPACE milvus${NC}"
  exit 1
fi

echo -e "${GREEN}LoadBalancer address found: $LB_DNS_NAME${NC}"

# Create the DNS change batch file
echo -e "${GREEN}Creating DNS change batch...${NC}"
cat > dns-change-batch.json << EOF
{
  "Changes": [
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "$DNS_NAME",
        "Type": "CNAME",
        "TTL": 300,
        "ResourceRecords": [
          {
            "Value": "$LB_DNS_NAME"
          }
        ]
      }
    }
  ]
}
EOF

# Apply the DNS change
echo -e "${GREEN}Applying DNS change to Route53...${NC}"
if aws route53 change-resource-record-sets --hosted-zone-id $HOSTED_ZONE_ID --change-batch file://dns-change-batch.json; then
  echo -e "${GREEN}DNS record successfully created/updated!${NC}"
  echo -e "${GREEN}Milvus is now accessible at: $DNS_NAME:19530${NC}"
else
  echo -e "${RED}Error: Failed to create/update DNS record.${NC}"
  exit 1
fi

# Clean up
rm dns-change-batch.json

# Test DNS resolution
echo -e "${GREEN}Testing DNS resolution...${NC}"
echo -e "${YELLOW}This may take a few minutes to propagate...${NC}"
sleep 10

if host $DNS_NAME &> /dev/null; then
  echo -e "${GREEN}DNS resolution successful!${NC}"
  echo -e "${GREEN}$DNS_NAME resolves to: $(host $DNS_NAME | grep "has address" || host $DNS_NAME | grep "is an alias")${NC}"
else
  echo -e "${YELLOW}Warning: DNS resolution not yet available. This is normal and may take some time to propagate.${NC}"
  echo -e "${YELLOW}You can check again later with: host $DNS_NAME${NC}"
fi

echo -e "${GREEN}You can use the following endpoint in your application:${NC}"
echo -e "Host: ${GREEN}$DNS_NAME${NC}"
echo -e "Port: ${GREEN}19530${NC}"
