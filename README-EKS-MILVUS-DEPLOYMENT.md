# EKS Milvus Deployment Guide

This guide documents the complete process for deploying the Milvus vector database on Amazon EKS, from CDK stack deployment to setting up LoadBalancer access with DNS configuration.

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [CDK Stack Deployment](#cdk-stack-deployment)
3. [Setting Up EKS Access](#setting-up-eks-access)
4. [Deploying Milvus to EKS](#deploying-milvus-to-eks)
5. [Configure DNS for Milvus](#configure-dns-for-milvus)
6. [Testing the Milvus Connection](#testing-the-milvus-connection)
7. [Troubleshooting](#troubleshooting)
8. [Maintenance and Monitoring](#maintenance-and-monitoring)
9. [Scaling Milvus: Upgrading from Standalone to Cluster Mode](#scaling-milvus-upgrading-from-standalone-to-cluster-mode)
10. [Handling Kubernetes Version Upgrades](#handling-kubernetes-version-upgrades)

## Prerequisites

Before starting the deployment process, ensure you have the following tools and resources:

- AWS CLI installed and configured with appropriate permissions
- Node.js and npm installed (for CDK)
- AWS CDK CLI installed: `npm install -g aws-cdk`
- kubectl installed: `brew install kubernetes-cli` (on macOS)
- helm installed: `brew install helm` (on macOS)
- Python 3.x with pip installed
- AWS account with sufficient permissions to create:
  - EKS clusters
  - IAM roles and policies
  - EC2 instances
  - S3 buckets
  - Load Balancers
  - Route53 DNS records

## CDK Stack Deployment

The CDK stack creates all the necessary AWS resources, including the EKS cluster, VPC, and S3 bucket for Milvus.

### 1. Clone the Repository

```bash
git clone https://github.com/your-org/largo-chat.git
cd largo-chat
```

### 2. Install Dependencies

```bash
npm install
```

### 3. Configure CDK Environment Variables

Create a `.env` file with the following variables:

```
AWS_REGION=eu-central-1
STACK_NAME=LargoChat
EKS_CLUSTER_NAME=largo-chat-eks
VPC_CIDR=10.0.0.0/16
MILVUS_BUCKET_NAME=largo-chat-milvus-storage
```

### 4. Deploy the CDK Stack

```bash
npx cdk bootstrap aws://<AWS_ACCOUNT_ID>/<AWS_REGION>
npx cdk deploy
```

This will deploy the following resources:
- VPC with public and private subnets
- EKS cluster
- Node group for the EKS cluster
- IAM roles and policies
- S3 bucket for Milvus storage

## Setting Up EKS Access

After deploying the CDK stack, you need to configure kubectl to access the EKS cluster.

### 1. Update Kubeconfig

```bash
aws eks update-kubeconfig --name <EKS_CLUSTER_NAME> --region <AWS_REGION>
```

### 2. Verify Access

```bash
kubectl get nodes
```

### 3. Set Up Access for Team Members

For team members who need access to the EKS cluster, run the `setup-eks-access.sh` script:

```bash
./scripts/setup-eks-access.sh <USER_ARN>
```

This script:
- Updates the `aws-auth` ConfigMap to grant the specified IAM user or role access to the cluster
- Creates appropriate RBAC permissions

## Deploying Milvus to EKS

The deployment process involves setting up IAM permissions, configuring the AWS Load Balancer Controller, and deploying Milvus using Helm.

### 1. Set AWS Environment Variables

```bash
export AWS_REGION=eu-central-1
export AWS_ACCESS_KEY_ID=<your-access-key>
export AWS_SECRET_ACCESS_KEY=<your-secret-key>
export EKS_CLUSTER_NAME=largo-chat-eks
export MILVUS_BUCKET_NAME=largo-chat-milvus-storage
```

### 2. Run the Deployment Script

```bash
./scripts/deploy-milvus-to-eks.sh
```

This script performs the following actions:
- Creates an EKS namespace for Milvus
- Sets up the AWS Load Balancer Controller
- Configures IAM roles and service accounts using IRSA
- Tags VPC subnets for LoadBalancer use
- Deploys Milvus using Helm with S3 integration
- Configures the LoadBalancer for external access

### Understanding the Key Configurations

#### AWS Load Balancer Controller

The AWS Load Balancer Controller is essential for creating AWS LoadBalancers from Kubernetes services. Key setup includes:

- IAM Roles for Service Accounts (IRSA)
- Service account with proper IAM role annotation
- AWS managed policies for Load Balancer permissions

#### VPC Subnet Tagging

Subnet tagging is crucial for LoadBalancer functionality:

- Public subnets: `kubernetes.io/role/elb=1`
- Private subnets: `kubernetes.io/role/internal-elb=1`
- Cluster ownership: `kubernetes.io/cluster/<cluster-name>=shared`

#### Milvus LoadBalancer Configuration

```yaml
service:
  type: LoadBalancer
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-scheme: internet-facing
    service.beta.kubernetes.io/aws-load-balancer-type: nlb
```

## Configure DNS for Milvus

After deploying Milvus with a LoadBalancer, you can configure a DNS record for easier access.

### 1. Get the LoadBalancer Address

```bash
kubectl get svc -n milvus milvus -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

### 2. Create DNS Record

#### Using AWS CLI (for Route53)

```bash
export HOSTED_ZONE_ID=<your-route53-hosted-zone-id>
export DNS_NAME=milvus.example.com
export LB_DNS_NAME=$(kubectl get svc -n milvus milvus -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

# Create the DNS record
aws route53 change-resource-record-sets \
  --hosted-zone-id $HOSTED_ZONE_ID \
  --change-batch '{
    "Changes": [
      {
        "Action": "UPSERT",
        "ResourceRecordSet": {
          "Name": "'$DNS_NAME'",
          "Type": "CNAME",
          "TTL": 300,
          "ResourceRecords": [
            {
              "Value": "'$LB_DNS_NAME'"
            }
          ]
        }
      }
    ]
  }'
```

#### Using AWS Console

1. Go to the Route53 console
2. Select your hosted zone
3. Click "Create Record"
4. Enter your subdomain (e.g., `milvus`)
5. Select "CNAME" as the record type
6. Enter the LoadBalancer address as the value
7. Click "Create records"

## Testing the Milvus Connection

After setting up Milvus with the LoadBalancer and DNS, you can test the connection.

### 1. Install the pymilvus Python Package

```bash
pip install pymilvus
```

### 2. Run the Connection Test Script

Create a file `test-milvus-connection.py`:

```python
#!/usr/bin/env python3
import sys
import time
from pymilvus import connections, utility

# Set your Milvus endpoint
MILVUS_HOST = "milvus.example.com"  # or the LoadBalancer DNS
MILVUS_PORT = "19530"

def test_milvus_connection():
    print(f"Testing connection to Milvus at {MILVUS_HOST}:{MILVUS_PORT}")
    
    try:
        # Connect to Milvus
        connections.connect(
            alias="default", 
            host=MILVUS_HOST,
            port=MILVUS_PORT,
            timeout=10  # 10 seconds timeout
        )
        
        print("✅ Successfully connected to Milvus!")
        
        # Try to list collections
        try:
            collections = utility.list_collections()
            print(f"✅ Collections in Milvus: {collections}")
        except Exception as e:
            print(f"ℹ️ Could not list collections (this is OK for a new installation): {e}")
        
        # Disconnect
        connections.disconnect("default")
        print("✅ Disconnected from Milvus")
        
        return True
        
    except Exception as e:
        print(f"❌ Error connecting to Milvus: {e}")
        return False

if __name__ == "__main__":
    # Try to connect with retries
    max_retries = 3
    retry_delay = 5  # seconds
    
    for attempt in range(max_retries):
        print(f"Connection attempt {attempt + 1}/{max_retries}")
        
        if test_milvus_connection():
            print("\n✅ Milvus connection test successful!")
            sys.exit(0)
        else:
            if attempt < max_retries - 1:
                print(f"Retrying in {retry_delay} seconds...\n")
                time.sleep(retry_delay)
    
    print("\n❌ Failed to connect to Milvus after multiple attempts.")
    sys.exit(1)
```

Run the script:

```bash
python test-milvus-connection.py
```

## Troubleshooting

### Common Issues and Solutions

#### EKS Access Issues

If you're having trouble accessing the EKS cluster:

```bash
# Check if your AWS CLI is properly configured
aws sts get-caller-identity

# Ensure your IAM user/role is added to the aws-auth ConfigMap
kubectl describe configmap aws-auth -n kube-system

# Fix access issues with
./scripts/fix-eks-access.sh <USER_ARN>
```

#### LoadBalancer Not Provisioning

If the LoadBalancer is not provisioning correctly:

```bash
# Check AWS Load Balancer Controller logs
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller

# Verify subnet tagging
aws ec2 describe-subnets --filters "Name=vpc-id,Values=<VPC_ID>" --query 'Subnets[*].[SubnetId,Tags]'

# Verify IAM permissions
aws iam get-role --role-name AmazonEKSLoadBalancerControllerRole
```

#### Milvus Pod Issues

If Milvus pods are not starting properly:

```bash
# Check pod status
kubectl get pods -n milvus

# View detailed pod information
kubectl describe pod <pod-name> -n milvus

# Check pod logs
kubectl logs <pod-name> -n milvus
```

### Health Check Configuration

Based on best practices, the following health check configuration is recommended:

```yaml
readinessProbe:
  initialDelaySeconds: 120
  periodSeconds: 30
  timeoutSeconds: 10
  successThreshold: 1
  failureThreshold: 12
livenessProbe:
  initialDelaySeconds: 300
  periodSeconds: 30
  timeoutSeconds: 10
  successThreshold: 1
  failureThreshold: 6
```

## Maintenance and Monitoring

### Regular Maintenance

1. **EKS Cluster Updates**: Regularly update the EKS cluster to maintain security and access the latest features.

   ```bash
   aws eks update-cluster-version --name <EKS_CLUSTER_NAME> --kubernetes-version <VERSION>
   ```

2. **Node Group Updates**: Update the node groups to use the latest AMIs.

   ```bash
   aws eks update-nodegroup-version --cluster-name <EKS_CLUSTER_NAME> --nodegroup-name <NODEGROUP_NAME>
   ```

3. **Milvus Updates**: Update Milvus using Helm.

   ```bash
   helm repo update
   helm upgrade milvus milvus/milvus -n milvus
   ```

### Monitoring

Monitor your Milvus deployment using:

1. **CloudWatch**: Set up CloudWatch dashboards and alarms for EKS metrics.
2. **Prometheus and Grafana**: Deploy the Prometheus Operator in the cluster for detailed monitoring.
3. **EKS Logs**: Enable EKS control plane logging to CloudWatch.

```bash
aws eks update-cluster-config \
  --name <EKS_CLUSTER_NAME> \
  --logging '{"clusterLogging":[{"types":["api","audit","authenticator","controllerManager","scheduler"],"enabled":true}]}'
```

## Scaling Milvus: Upgrading from Standalone to Cluster Mode

As your application grows, you may need to upgrade from a standalone Milvus deployment to a clustered deployment with Pulsar for message queuing. This section outlines the process for such an upgrade.

### Prerequisites for Cluster Deployment

Before upgrading to cluster mode, ensure your EKS cluster has:

1. **Sufficient Resources**:
   - At least 5 worker nodes (t3.xlarge or larger recommended)
   - At least 80GB of available storage for persistent volumes
   - Nodes with adequate CPU and memory (minimum 16 vCPU and 32GB RAM total)

2. **Properly Configured Storage Class**:
   - The `gp2` storage class should be available
   - Make sure it supports the `ReadWriteOnce` access mode

3. **Network Policies**:
   - Ensure network policies allow internal communication between pods
   - Ports 9000 (Minio), 2181 (ZooKeeper), 6650 (Pulsar) must be allowed

### Backup Existing Data

Before upgrading, back up your existing data:

```bash
# Create an S3 backup bucket (if not already exist)
aws s3 mb s3://$MILVUS_BACKUP_BUCKET_NAME --region $AWS_REGION

# Run a backup job to export collections
cat > milvus-backup.yaml << EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: milvus-backup
  namespace: $EKS_NAMESPACE
spec:
  template:
    spec:
      containers:
      - name: milvus-backup
        image: milvusdb/milvus:latest
        command: ["/bin/bash"]
        args:
        - -c
        - |
          pip install pymilvus
          python -c '
          from pymilvus import connections, utility
          import json, os, subprocess
          
          # Connect to Milvus
          connections.connect(host="milvus", port="19530")
          
          # Get all collections
          collections = utility.list_collections()
          print(f"Collections to backup: {collections}")
          
          # Export collections metadata to S3
          for collection_name in collections:
            print(f"Backing up collection: {collection_name}")
            subprocess.run([
              "aws", "s3", "cp",
              f"/var/lib/milvus/data/meta/{collection_name}", 
              f"s3://${MILVUS_BACKUP_BUCKET_NAME}/{collection_name}",
              "--recursive"
            ])
          
          print("Backup completed")
          '
        env:
        - name: AWS_ACCESS_KEY_ID
          value: "$AWS_ACCESS_KEY_ID"
        - name: AWS_SECRET_ACCESS_KEY
          value: "$AWS_SECRET_ACCESS_KEY"
        - name: AWS_REGION
          value: "$AWS_REGION"
      restartPolicy: Never
  backoffLimit: 3
EOF

kubectl apply -f milvus-backup.yaml
```

Monitor the backup job:

```bash
kubectl logs -f job/milvus-backup -n $EKS_NAMESPACE
```

### Upgrade to Cluster Mode with Pulsar

Once your backup is complete, you can upgrade to cluster mode:

```bash
# Update Helm repository
helm repo update

# Upgrade Milvus to cluster mode
helm upgrade milvus milvus/milvus --namespace $EKS_NAMESPACE \
  --set cluster.enabled=true \
  --set standalone.enabled=false \
  --set pulsar.enabled=true \
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
  --set pulsar.broker.replicaCount=3 \
  --set pulsar.bookkeeper.replicaCount=3 \
  --set pulsar.zookeeper.replicaCount=3 \
  --set pulsar.proxy.replicaCount=2 \
  --set dataCoord.replicas=2 \
  --set indexCoord.replicas=2 \
  --set queryCoord.replicas=2 \
  --set dataNode.replicas=2 \
  --set indexNode.replicas=2 \
  --set queryNode.replicas=2 \
  --set persistence.enabled=true \
  --set pulsar.persistence.enabled=true \
  --set etcd.persistence.enabled=true \
  --set pulsar.zookeeper.persistence.enabled=true \
  --set pulsar.bookkeeper.persistence.enabled=true
```

### Restoring Data After Upgrade

After upgrading to cluster mode, restore your data:

```bash
# Create a restore job
cat > milvus-restore.yaml << EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: milvus-restore
  namespace: $EKS_NAMESPACE
spec:
  template:
    spec:
      containers:
      - name: milvus-restore
        image: milvusdb/milvus:latest
        command: ["/bin/bash"]
        args:
        - -c
        - |
          pip install pymilvus boto3
          python -c '
          import boto3, time
          from pymilvus import connections, utility, Collection, CollectionSchema
          
          # Wait for Milvus to be ready
          print("Waiting for Milvus to be ready...")
          time.sleep(120)
          
          # Connect to Milvus
          connections.connect(host="milvus", port="19530")
          print("Connected to Milvus")
          
          # List all collections in the backup
          s3 = boto3.client("s3")
          response = s3.list_objects_v2(Bucket="${MILVUS_BACKUP_BUCKET_NAME}")
          
          # Import collections from S3
          for obj in response.get("Contents", []):
            collection_name = obj["Key"].split("/")[0]
            print(f"Restoring collection: {collection_name}")
            
            # Download collection schema
            s3.download_file(
              "${MILVUS_BACKUP_BUCKET_NAME}", 
              f"{collection_name}/schema.json",
              "schema.json"
            )
            
            # Use schema to recreate collection
            # This is a simplified example - actual restoration
            # would need to parse the schema file and create appropriate
            # CollectionSchema objects
            
          print("Restore completed")
          '
        env:
        - name: AWS_ACCESS_KEY_ID
          value: "$AWS_ACCESS_KEY_ID"
        - name: AWS_SECRET_ACCESS_KEY
          value: "$AWS_SECRET_ACCESS_KEY"
        - name: AWS_REGION
          value: "$AWS_REGION"
      restartPolicy: Never
  backoffLimit: 3
EOF

kubectl apply -f milvus-restore.yaml
```

Monitor the restore job:

```bash
kubectl logs -f job/milvus-restore -n $EKS_NAMESPACE
```

### Verifying the Cluster Deployment

After upgrading, verify the cluster deployment:

```bash
# Check all pods are running
kubectl get pods -n $EKS_NAMESPACE

# Verify the service
kubectl get svc -n $EKS_NAMESPACE

# Test connectivity with the test script
python3 scripts/test-milvus-connection.py
```

## Handling Kubernetes Version Upgrades

When upgrading the EKS cluster version, careful planning is required to minimize downtime.

### Pre-upgrade Preparations

1. **Backup Data**:
   Use the backup procedure described in the scaling section above.

2. **Document Current Configuration**:
   ```bash
   # Export current Helm values
   helm get values milvus -n $EKS_NAMESPACE -o yaml > milvus-values-backup.yaml
   
   # Export all Kubernetes resources
   kubectl get all -n $EKS_NAMESPACE -o yaml > milvus-resources-backup.yaml
   ```

3. **Check Compatibility**:
   - Verify that the Milvus version is compatible with the new Kubernetes version
   - Check Helm chart compatibility
   - Review AWS EKS-specific considerations for the new version

### Performing the EKS Upgrade

EKS upgrades involve updating the control plane and then the node groups.

1. **Update the EKS Control Plane**:
   ```bash
   aws eks update-cluster-version \
     --name $EKS_CLUSTER_NAME \
     --kubernetes-version X.XX \
     --region $AWS_REGION
   ```

2. **Monitor the Upgrade**:
   ```bash
   aws eks describe-update \
     --name $EKS_CLUSTER_NAME \
     --update-id <update-id> \
     --region $AWS_REGION
   ```

3. **Update Node Groups**:
   ```bash
   # Get node group name
   NODE_GROUP=$(aws eks list-nodegroups --cluster-name $EKS_CLUSTER_NAME --region $AWS_REGION --output text)
   
   # Update node group to match control plane version
   aws eks update-nodegroup-version \
     --cluster-name $EKS_CLUSTER_NAME \
     --nodegroup-name $NODE_GROUP \
     --region $AWS_REGION
   ```

4. **Verify the Nodes**:
   ```bash
   kubectl get nodes
   ```

### Post-upgrade Steps

1. **Verify AWS Load Balancer Controller**:
   ```bash
   kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller
   ```

   If there are issues, reinstall:
   ```bash
   helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
     -n kube-system \
     --set clusterName=$EKS_CLUSTER_NAME \
     --set serviceAccount.create=false \
     --set serviceAccount.name=aws-load-balancer-controller \
     --set region=$AWS_REGION
   ```

2. **Restart Milvus Pods** (if needed):
   ```bash
   kubectl rollout restart statefulset,deployment -n $EKS_NAMESPACE -l app.kubernetes.io/instance=milvus
   ```

3. **Verify Milvus Operation**:
   ```bash
   # Test connection
   python3 scripts/test-milvus-connection.py
   
   # Check that all components are functioning
   kubectl get pods -n $EKS_NAMESPACE
   ```

4. **Update DNS Configuration** (if endpoint changed):
   ```bash
   ./scripts/configure-milvus-dns.sh --hosted-zone-id <HOSTED_ZONE_ID> --dns-name <DNS_NAME>
   ```

### Rollback Procedure

If the upgrade causes issues, have a rollback plan:

1. **Rollback EKS Cluster**:
   ```bash
   # For control plane
   aws eks update-cluster-version \
     --name $EKS_CLUSTER_NAME \
     --kubernetes-version <previous-version> \
     --region $AWS_REGION
     
   # For node groups
   aws eks update-nodegroup-version \
     --cluster-name $EKS_CLUSTER_NAME \
     --nodegroup-name $NODE_GROUP \
     --region $AWS_REGION \
     --launch-template name=<previous-template-name>,version=<previous-version>
   ```

2. **Restore Milvus from Backup**:
   If data was lost, use the restoration procedure outlined earlier.

## Conclusion

Following this guide will help you successfully deploy Milvus on Amazon EKS with proper LoadBalancer configuration and DNS setup. The deployment is designed to be scalable, secure, and maintainable.

For any questions or issues, please reach out to the DevOps team or file an issue on the project repository.
