#!/bin/bash
set -e

# Get the node instance role ARN
NODE_INSTANCE_ROLE=$(aws eks describe-nodegroup --cluster-name milvus-cluster --nodegroup-name milvus-nodes --region eu-central-1 --query "nodegroup.nodeRole" --output text)

echo "Node instance role: $NODE_INSTANCE_ROLE"

# Create a temp kubeconfig using the node instance role
aws eks update-kubeconfig --name milvus-cluster --region eu-central-1 --role-arn $NODE_INSTANCE_ROLE

# Check if we can access the cluster with this role
kubectl get nodes

# Create aws-auth configmap if it doesn't exist
if ! kubectl get configmap aws-auth -n kube-system &>/dev/null; then
  echo "Creating aws-auth ConfigMap..."
  kubectl create configmap aws-auth -n kube-system
fi

# Apply the correct aws-auth configuration with admin user
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: aws-auth
  namespace: kube-system
data:
  mapRoles: |
    - rolearn: $NODE_INSTANCE_ROLE
      username: system:node:{{EC2PrivateDNSName}}
      groups:
        - system:bootstrappers
        - system:nodes
  mapUsers: |
    - userarn: arn:aws:iam::615022891451:user/admin
      username: admin
      groups:
        - system:masters
EOF

# Switch back to the admin user credentials
aws eks update-kubeconfig --name milvus-cluster --region eu-central-1

# Verify access
echo "Verifying access as admin user..."
kubectl get nodes

echo "Setup complete! You should now have admin access to the EKS cluster."
