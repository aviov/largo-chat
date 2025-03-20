#!/bin/bash
# Script to validate Milvus health check configurations based on best practices

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Check if required environment variables are set
if [ -z "$EKS_NAMESPACE" ]; then
  echo -e "${YELLOW}EKS_NAMESPACE not set. Using default: milvus${NC}"
  EKS_NAMESPACE="milvus"
fi

# Ensure kubectl is installed
if ! command -v kubectl &> /dev/null; then
  echo -e "${RED}kubectl is not installed. Please install it first.${NC}"
  exit 1
fi

echo -e "${BLUE}=== Milvus Health Check Validation ===${NC}"
echo -e "${BLUE}This script will validate the health check configuration for Milvus deployments.${NC}"
echo

# Get Milvus deployment and statefulset resources
echo -e "${GREEN}Retrieving Milvus resources...${NC}"
RESOURCES=$(kubectl get deploy,statefulset -n $EKS_NAMESPACE -l app.kubernetes.io/instance=milvus -o name)

if [ -z "$RESOURCES" ]; then
  echo -e "${RED}Error: No Milvus resources found in namespace $EKS_NAMESPACE.${NC}"
  echo -e "${YELLOW}Please ensure Milvus is deployed and check the namespace.${NC}"
  exit 1
fi

echo -e "${GREEN}Found the following Milvus resources:${NC}"
echo "$RESOURCES"
echo

# Define recommended health check values based on best practices
RECOMMENDED_READINESS_INITIAL_DELAY=120
RECOMMENDED_READINESS_PERIOD=30
RECOMMENDED_READINESS_TIMEOUT=10
RECOMMENDED_READINESS_SUCCESS=1
RECOMMENDED_READINESS_FAILURE=12

RECOMMENDED_LIVENESS_INITIAL_DELAY=300
RECOMMENDED_LIVENESS_PERIOD=30
RECOMMENDED_LIVENESS_TIMEOUT=10
RECOMMENDED_LIVENESS_SUCCESS=1
RECOMMENDED_LIVENESS_FAILURE=6

echo -e "${BLUE}=== Recommended Health Check Values ===${NC}"
echo -e "${GREEN}Readiness Probe:${NC}"
echo -e "  initialDelaySeconds: $RECOMMENDED_READINESS_INITIAL_DELAY"
echo -e "  periodSeconds: $RECOMMENDED_READINESS_PERIOD"
echo -e "  timeoutSeconds: $RECOMMENDED_READINESS_TIMEOUT"
echo -e "  successThreshold: $RECOMMENDED_READINESS_SUCCESS"
echo -e "  failureThreshold: $RECOMMENDED_READINESS_FAILURE"
echo
echo -e "${GREEN}Liveness Probe:${NC}"
echo -e "  initialDelaySeconds: $RECOMMENDED_LIVENESS_INITIAL_DELAY"
echo -e "  periodSeconds: $RECOMMENDED_LIVENESS_PERIOD"
echo -e "  timeoutSeconds: $RECOMMENDED_LIVENESS_TIMEOUT"
echo -e "  successThreshold: $RECOMMENDED_LIVENESS_SUCCESS"
echo -e "  failureThreshold: $RECOMMENDED_LIVENESS_FAILURE"
echo
echo -e "${BLUE}=== Current Configuration ===${NC}"

# Function to check health check config against recommendations
check_health_config() {
  local resource="$1"
  local container="$2"

  echo -e "${GREEN}Checking $resource container $container:${NC}"
  
  # Get readiness probe configuration
  READINESS_CONFIG=$(kubectl get $resource -n $EKS_NAMESPACE -o jsonpath="{.spec.template.spec.containers[?(@.name=='$container')].readinessProbe}")
  
  if [ -z "$READINESS_CONFIG" ]; then
    echo -e "${RED}  ❌ No readiness probe configured!${NC}"
  else
    # Extract values
    R_INITIAL=$(kubectl get $resource -n $EKS_NAMESPACE -o jsonpath="{.spec.template.spec.containers[?(@.name=='$container')].readinessProbe.initialDelaySeconds}")
    R_PERIOD=$(kubectl get $resource -n $EKS_NAMESPACE -o jsonpath="{.spec.template.spec.containers[?(@.name=='$container')].readinessProbe.periodSeconds}")
    R_TIMEOUT=$(kubectl get $resource -n $EKS_NAMESPACE -o jsonpath="{.spec.template.spec.containers[?(@.name=='$container')].readinessProbe.timeoutSeconds}")
    R_SUCCESS=$(kubectl get $resource -n $EKS_NAMESPACE -o jsonpath="{.spec.template.spec.containers[?(@.name=='$container')].readinessProbe.successThreshold}")
    R_FAILURE=$(kubectl get $resource -n $EKS_NAMESPACE -o jsonpath="{.spec.template.spec.containers[?(@.name=='$container')].readinessProbe.failureThreshold}")

    echo -e "${GREEN}  Readiness Probe:${NC}"
    
    # Check initialDelaySeconds
    if [ -z "$R_INITIAL" ] || [ "$R_INITIAL" -lt "$RECOMMENDED_READINESS_INITIAL_DELAY" ]; then
      echo -e "${YELLOW}    ⚠️ initialDelaySeconds: $R_INITIAL (Recommended: $RECOMMENDED_READINESS_INITIAL_DELAY)${NC}"
    else
      echo -e "${GREEN}    ✅ initialDelaySeconds: $R_INITIAL${NC}"
    fi
    
    # Check periodSeconds
    if [ -z "$R_PERIOD" ] || [ "$R_PERIOD" -ne "$RECOMMENDED_READINESS_PERIOD" ]; then
      echo -e "${YELLOW}    ⚠️ periodSeconds: $R_PERIOD (Recommended: $RECOMMENDED_READINESS_PERIOD)${NC}"
    else
      echo -e "${GREEN}    ✅ periodSeconds: $R_PERIOD${NC}"
    fi
    
    # Check timeoutSeconds
    if [ -z "$R_TIMEOUT" ] || [ "$R_TIMEOUT" -ne "$RECOMMENDED_READINESS_TIMEOUT" ]; then
      echo -e "${YELLOW}    ⚠️ timeoutSeconds: $R_TIMEOUT (Recommended: $RECOMMENDED_READINESS_TIMEOUT)${NC}"
    else
      echo -e "${GREEN}    ✅ timeoutSeconds: $R_TIMEOUT${NC}"
    fi
    
    # Check successThreshold
    if [ -z "$R_SUCCESS" ] || [ "$R_SUCCESS" -ne "$RECOMMENDED_READINESS_SUCCESS" ]; then
      echo -e "${YELLOW}    ⚠️ successThreshold: $R_SUCCESS (Recommended: $RECOMMENDED_READINESS_SUCCESS)${NC}"
    else
      echo -e "${GREEN}    ✅ successThreshold: $R_SUCCESS${NC}"
    fi
    
    # Check failureThreshold
    if [ -z "$R_FAILURE" ] || [ "$R_FAILURE" -lt "$RECOMMENDED_READINESS_FAILURE" ]; then
      echo -e "${YELLOW}    ⚠️ failureThreshold: $R_FAILURE (Recommended: $RECOMMENDED_READINESS_FAILURE)${NC}"
    else
      echo -e "${GREEN}    ✅ failureThreshold: $R_FAILURE${NC}"
    fi
  fi
  
  # Get liveness probe configuration
  LIVENESS_CONFIG=$(kubectl get $resource -n $EKS_NAMESPACE -o jsonpath="{.spec.template.spec.containers[?(@.name=='$container')].livenessProbe}")
  
  if [ -z "$LIVENESS_CONFIG" ]; then
    echo -e "${RED}  ❌ No liveness probe configured!${NC}"
  else
    # Extract values
    L_INITIAL=$(kubectl get $resource -n $EKS_NAMESPACE -o jsonpath="{.spec.template.spec.containers[?(@.name=='$container')].livenessProbe.initialDelaySeconds}")
    L_PERIOD=$(kubectl get $resource -n $EKS_NAMESPACE -o jsonpath="{.spec.template.spec.containers[?(@.name=='$container')].livenessProbe.periodSeconds}")
    L_TIMEOUT=$(kubectl get $resource -n $EKS_NAMESPACE -o jsonpath="{.spec.template.spec.containers[?(@.name=='$container')].livenessProbe.timeoutSeconds}")
    L_SUCCESS=$(kubectl get $resource -n $EKS_NAMESPACE -o jsonpath="{.spec.template.spec.containers[?(@.name=='$container')].livenessProbe.successThreshold}")
    L_FAILURE=$(kubectl get $resource -n $EKS_NAMESPACE -o jsonpath="{.spec.template.spec.containers[?(@.name=='$container')].livenessProbe.failureThreshold}")

    echo -e "${GREEN}  Liveness Probe:${NC}"
    
    # Check initialDelaySeconds
    if [ -z "$L_INITIAL" ] || [ "$L_INITIAL" -lt "$RECOMMENDED_LIVENESS_INITIAL_DELAY" ]; then
      echo -e "${YELLOW}    ⚠️ initialDelaySeconds: $L_INITIAL (Recommended: $RECOMMENDED_LIVENESS_INITIAL_DELAY)${NC}"
    else
      echo -e "${GREEN}    ✅ initialDelaySeconds: $L_INITIAL${NC}"
    fi
    
    # Check periodSeconds
    if [ -z "$L_PERIOD" ] || [ "$L_PERIOD" -ne "$RECOMMENDED_LIVENESS_PERIOD" ]; then
      echo -e "${YELLOW}    ⚠️ periodSeconds: $L_PERIOD (Recommended: $RECOMMENDED_LIVENESS_PERIOD)${NC}"
    else
      echo -e "${GREEN}    ✅ periodSeconds: $L_PERIOD${NC}"
    fi
    
    # Check timeoutSeconds
    if [ -z "$L_TIMEOUT" ] || [ "$L_TIMEOUT" -ne "$RECOMMENDED_LIVENESS_TIMEOUT" ]; then
      echo -e "${YELLOW}    ⚠️ timeoutSeconds: $L_TIMEOUT (Recommended: $RECOMMENDED_LIVENESS_TIMEOUT)${NC}"
    else
      echo -e "${GREEN}    ✅ timeoutSeconds: $L_TIMEOUT${NC}"
    fi
    
    # Check successThreshold
    if [ -z "$L_SUCCESS" ] || [ "$L_SUCCESS" -ne "$RECOMMENDED_LIVENESS_SUCCESS" ]; then
      echo -e "${YELLOW}    ⚠️ successThreshold: $L_SUCCESS (Recommended: $RECOMMENDED_LIVENESS_SUCCESS)${NC}"
    else
      echo -e "${GREEN}    ✅ successThreshold: $L_SUCCESS${NC}"
    fi
    
    # Check failureThreshold
    if [ -z "$L_FAILURE" ] || [ "$L_FAILURE" -lt "$RECOMMENDED_LIVENESS_FAILURE" ]; then
      echo -e "${YELLOW}    ⚠️ failureThreshold: $L_FAILURE (Recommended: $RECOMMENDED_LIVENESS_FAILURE)${NC}"
    else
      echo -e "${GREEN}    ✅ failureThreshold: $L_FAILURE${NC}"
    fi
  fi
  
  echo
}

# Check health configs for each Milvus resource
for resource in $RESOURCES; do
  # Get containers in the resource
  CONTAINERS=$(kubectl get $resource -n $EKS_NAMESPACE -o jsonpath="{.spec.template.spec.containers[*].name}")
  
  for container in $CONTAINERS; do
    check_health_config "$resource" "$container"
  done
done

# Show update instructions if needed
echo -e "${BLUE}=== Update Instructions ===${NC}"
echo -e "${GREEN}To update health check configurations to match best practices, use the following helm upgrade command:${NC}"
echo
echo "helm upgrade milvus milvus/milvus -n $EKS_NAMESPACE \\
  --reuse-values \\
  --set standalone.readinessProbe.initialDelaySeconds=$RECOMMENDED_READINESS_INITIAL_DELAY \\
  --set standalone.readinessProbe.periodSeconds=$RECOMMENDED_READINESS_PERIOD \\
  --set standalone.readinessProbe.timeoutSeconds=$RECOMMENDED_READINESS_TIMEOUT \\
  --set standalone.readinessProbe.successThreshold=$RECOMMENDED_READINESS_SUCCESS \\
  --set standalone.readinessProbe.failureThreshold=$RECOMMENDED_READINESS_FAILURE \\
  --set standalone.livenessProbe.initialDelaySeconds=$RECOMMENDED_LIVENESS_INITIAL_DELAY \\
  --set standalone.livenessProbe.periodSeconds=$RECOMMENDED_LIVENESS_PERIOD \\
  --set standalone.livenessProbe.timeoutSeconds=$RECOMMENDED_LIVENESS_TIMEOUT \\
  --set standalone.livenessProbe.successThreshold=$RECOMMENDED_LIVENESS_SUCCESS \\
  --set standalone.livenessProbe.failureThreshold=$RECOMMENDED_LIVENESS_FAILURE"

echo
echo -e "${BLUE}=== Validation Complete ===${NC}"
echo -e "${GREEN}Remember to adjust health check parameters based on your specific workload characteristics.${NC}"
echo -e "${GREEN}Larger initial delays are safer but slow down deployment speed.${NC}"
echo -e "${GREEN}Smaller initial delays speed up deployment but may cause premature restarts if the application is slow to start.${NC}"
