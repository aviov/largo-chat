#!/bin/bash

# Load AWS credentials from lambda/.env
echo "Loading AWS credentials from lambda/.env"
if [ -f "lambda/.env" ]; then
  export AWS_ACCESS_KEY_ID=$(grep AWS_ACCESS_KEY_ID lambda/.env | cut -d '=' -f2 | tr -d '"')
  export AWS_SECRET_ACCESS_KEY=$(grep AWS_SECRET_ACCESS_KEY lambda/.env | cut -d '=' -f2 | tr -d '"')
  export AWS_REGION=$(grep AWS_REGION lambda/.env | cut -d '=' -f2 | tr -d '"' || echo "eu-central-1")
else
  echo "Error: lambda/.env file not found!"
  exit 1
fi

# Verify that AWS credentials are loaded
if [ -z "$AWS_ACCESS_KEY_ID" ] || [ -z "$AWS_SECRET_ACCESS_KEY" ]; then
  echo "Error: AWS credentials not found in lambda/.env"
  exit 1
fi

echo "Using AWS credentials from lambda/.env"
echo "Using region: $AWS_REGION"

# Create a temporary aws-auth ConfigMap file
cat > aws-auth-cm.yaml << EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: aws-auth
  namespace: kube-system
data:
  mapRoles: |
    - rolearn: arn:aws:iam::615022891451:role/ChatbotStack-EksNodeGroupRoleEBD66BF6-knLJzRsCb3PS
      username: system:node:{{EC2PrivateDNSName}}
      groups:
        - system:bootstrappers
        - system:nodes
    - rolearn: arn:aws:iam::615022891451:role/eks-admin-role
      username: admin
      groups:
        - system:masters
  mapUsers: |
    - userarn: arn:aws:iam::615022891451:user/admin
      username: admin
      groups:
        - system:masters
    - userarn: arn:aws:iam::615022891451:root
      username: root
      groups:
        - system:masters
EOF

echo "Created aws-auth ConfigMap file with proper mappings"

# Get temporary admin credentials for kubectl
echo "Obtaining cluster endpoint and temporary credentials..."
CLUSTER_NAME=milvus-cluster
REGION=${AWS_REGION}

echo "Testing AWS CLI..."
aws sts get-caller-identity

# Update the kubeconfig with the role
echo "Updating kubeconfig with EKS cluster info..."
aws eks update-kubeconfig --name $CLUSTER_NAME --region $REGION

# First try to apply with validate=false flag to bypass API server validation
echo "Applying ConfigMap using kubectl with validate=false..."
kubectl apply -f aws-auth-cm.yaml --validate=false

echo "ConfigMap applied. Testing access..."
sleep 5  # Give the cluster a moment to process the ConfigMap changes
kubectl get nodes
