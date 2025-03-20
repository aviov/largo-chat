#!/bin/bash

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Load AWS credentials if available
if [ -f "lambda/.env" ]; then
  echo "Loading AWS credentials from lambda/.env"
  source lambda/.env
fi

# Check if the load balancer is ready
wait_for_lb() {
  echo -e "${GREEN}Waiting for Milvus LoadBalancer to be provisioned...${NC}"
  
  # Maximum wait time in seconds (10 minutes)
  MAX_WAIT=600
  ELAPSED=0
  
  while [ $ELAPSED -lt $MAX_WAIT ]; do
    EXTERNAL_IP=$(kubectl get svc milvus -n milvus -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
    
    if [ -n "$EXTERNAL_IP" ] && [ "$EXTERNAL_IP" != "<pending>" ]; then
      echo -e "${GREEN}LoadBalancer is ready with endpoint: ${EXTERNAL_IP}${NC}"
      return 0
    fi
    
    echo -e "${YELLOW}LoadBalancer still provisioning... (${ELAPSED}s elapsed)${NC}"
    sleep 15
    ELAPSED=$((ELAPSED + 15))
  done
  
  echo -e "${RED}Timed out waiting for LoadBalancer (${MAX_WAIT}s)${NC}"
  return 1
}

# Update Lambda function with Milvus endpoint
update_lambda() {
  if [ -z "$1" ]; then
    echo -e "${RED}No Milvus endpoint provided${NC}"
    return 1
  fi
  
  MILVUS_ENDPOINT=$1
  echo -e "${GREEN}Updating Lambda function with Milvus endpoint: ${MILVUS_ENDPOINT}${NC}"
  
  # Get the Lambda function name from CloudFormation outputs
  LAMBDA_FUNCTION=$(aws cloudformation describe-stacks --stack-name MilvusStack --query "Stacks[0].Outputs[?OutputKey=='LambdaFunctionName'].OutputValue" --output text)
  
  if [ -z "$LAMBDA_FUNCTION" ]; then
    echo -e "${RED}Could not find Lambda function from CloudFormation stack${NC}"
    return 1
  fi
  
  echo -e "${GREEN}Updating Lambda function: ${LAMBDA_FUNCTION}${NC}"
  
  # Update the Lambda environment variables
  aws lambda update-function-configuration \
    --function-name "$LAMBDA_FUNCTION" \
    --environment "Variables={MILVUS_HOST=${MILVUS_ENDPOINT},MILVUS_PORT=19530}"
  
  if [ $? -eq 0 ]; then
    echo -e "${GREEN}Successfully updated Lambda environment variables${NC}"
    return 0
  else
    echo -e "${RED}Failed to update Lambda environment variables${NC}"
    return 1
  fi
}

# Main execution
wait_for_lb

if [ $? -eq 0 ]; then
  MILVUS_ENDPOINT=$(kubectl get svc milvus -n milvus -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
  
  if [ -n "$MILVUS_ENDPOINT" ]; then
    update_lambda "$MILVUS_ENDPOINT"
  else
    echo -e "${RED}Could not retrieve Milvus endpoint${NC}"
    exit 1
  fi
else
  echo -e "${RED}Failed to get Milvus endpoint${NC}"
  exit 1
fi

echo -e "${GREEN}==============================================================${NC}"
echo -e "${GREEN}Milvus deployment details:${NC}"
echo -e "Milvus endpoint: ${MILVUS_ENDPOINT}"
echo -e "Milvus port: 19530"
echo -e "Check connection: nc -zv ${MILVUS_ENDPOINT} 19530"
echo -e "${GREEN}==============================================================${NC}"
