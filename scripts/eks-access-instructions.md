# EKS Access and Milvus Deployment Instructions

## Step 1: Configure EKS Access Through AWS Console

To grant your IAM user access to the EKS cluster through the AWS Console:

1. Open the **EKS Console** and select your cluster (milvus-cluster)
2. Go to the **Access** tab
3. Click **Add mapping**
4. For **User/Role**, select your IAM user (admin)
5. For **Username**, enter `admin`
6. For **Groups**, add `system:masters`
7. Click **Add mapping**

This will update the aws-auth ConfigMap and grant your IAM user admin access to the cluster without requiring initial Kubernetes access.

After adding the mapping, wait about 30 seconds and try running:

```bash
kubectl get nodes
```

You should now be able to access the cluster resources.

## EKS Access Configuration Guide

This document provides step-by-step instructions for configuring proper access to an Amazon EKS cluster for Milvus deployment.

### Prerequisites
- AWS CLI installed and configured
- `kubectl` installed
- `eksctl` installed
- AWS account with appropriate permissions

### Step 1: Configure AWS Credentials

Ensure your AWS credentials are properly configured in `lambda/.env`:

```
AWS_ACCESS_KEY_ID="your-access-key"
AWS_SECRET_ACCESS_KEY="your-secret-key"
AWS_REGION="eu-central-1"
```

### Step 2: Run the Complete Setup Script

```bash
./scripts/complete-eks-setup.sh
```

This script will:
- Create necessary IAM policies (EksAdminPolicy)
- Create an IAM role (eks-admin-role) for EKS access
- Attempt to update the aws-auth ConfigMap

**Note:** The script may produce some errors if you don't have sufficient permissions initially. This is expected.

### Step 3: Configure Access Entries via AWS Console

1. Go to the AWS Console > EKS > Clusters > your-cluster > Access tab
2. Click "Create access entry"
3. Add entries for both IAM users and roles:

   For Admin User:
   - Type: Standard
   - IAM principal ARN: `arn:aws:iam::ACCOUNT_ID:user/admin`
   - Username: `admin`
   - Groups: `masters` (and optionally `nodes`)
   - Access policies: `AmazonEKSClusterAdminPolicy`

   For Root User:
   - Type: Standard
   - IAM principal ARN: `arn:aws:iam::ACCOUNT_ID:root`
   - Username: `arn:aws:iam::ACCOUNT_ID:root`
   - Groups: `masters` (and optionally `nodes`)
   - Access policies: `AmazonEKSClusterAdminPolicy`

   For Admin Role:
   - Type: Standard
   - IAM principal ARN: `arn:aws:iam::ACCOUNT_ID:role/eks-admin-role`
   - Username: `eks-admin-role`
   - Groups: `masters`
   - Access policies: `AmazonEKSClusterAdminPolicy`

### Step 4: Update Kubeconfig and Verify Access

```bash
# Update kubeconfig to use your EKS cluster
aws eks update-kubeconfig --name milvus-cluster --region eu-central-1

# Verify access by listing nodes
kubectl get nodes
```

If you see your cluster nodes, your access is configured correctly.

## Step 2: Install EKS Pod Identity Agent Add-on

The EKS Pod Identity Agent add-on is required for pods to assume IAM roles. Install it through the AWS Console:

1. Open the **EKS Console** and select your cluster (milvus-cluster)
2. Go to the **Add-ons** tab
3. Click **Get more add-ons**
4. Select **Amazon EKS Pod Identity Agent**
5. Click **Next**
6. Maintain the default settings (latest version) and click **Next**
7. Review and click **Create**

Wait for the add-on to be fully installed before proceeding to the next step. You can check the status in the Add-ons tab.

## Step 3: Deploy Milvus

Once access is configured and the EKS Pod Identity Agent is installed, run the deployment script:

```bash
# Ensure AWS credentials are loaded from lambda/.env
export $(grep -v '^#' ./lambda/.env | xargs)

# Run the deployment script
./scripts/deploy-milvus-to-eks.sh
```

The script will:
1. Configure kubectl to use your cluster
2. Install necessary components (EBS CSI Driver, storage classes, AWS Load Balancer Controller)
3. Deploy Milvus with appropriate health checks and AWS integrations
4. Configure the Lambda function with the Milvus endpoint

## Step 4: Verify Deployment

After deployment completes, check the status of Milvus pods:

```bash
kubectl get pods -n milvus
```

All pods should eventually reach the Running state. This may take a few minutes.

### Step 5: Deploy Milvus

```bash
./scripts/deploy-milvus-to-eks.sh
```

This script will deploy Milvus to your EKS cluster.

### Troubleshooting

1. **"User cannot list resource nodes"**:
   - Make sure you've added the IAM entity to both the correct Kubernetes group (`masters`) AND assigned the appropriate AWS IAM policy (`AmazonEKSClusterAdminPolicy`)
   - Both RBAC (Kubernetes) permissions and IAM (AWS) permissions are needed

2. **aws-auth ConfigMap issues**:
   - Try using the Access Entries in the AWS Console instead of modifying the aws-auth ConfigMap directly
   - The AWS Console approach is newer and more reliable

3. **AWS Credentials not found**:
   - Make sure `lambda/.env` exists and contains the correct credentials
   - Try running `aws sts get-caller-identity` to verify your credentials are working

4. **Authentication Issues**:
   - **AWS IAM Permissions**: Ensure your IAM user has the necessary permissions for EKS:
     - `eks:*`
     - `ec2:DescribeInstances`
     - `ec2:DescribeRouteTables`
     - `ec2:DescribeSecurityGroups`
     - `ec2:DescribeSubnets`
     - `ec2:DescribeVpcs`
     - `iam:ListRoles`

   - **Kubeconfig**: Refresh your kubeconfig file:
     ```bash
     aws eks update-kubeconfig --name milvus-cluster --region eu-central-1
     ```

   - **Pod Health Issues**: If Milvus pods aren't starting properly, check pod events:
     ```bash
     kubectl describe pod <pod-name> -n milvus
     ```

   - **View Container Logs**: To see container logs:
     ```bash
     kubectl logs <pod-name> -n milvus
     ```

### Important Notes

- **Security:** The `system:masters` group has full admin access to the Kubernetes cluster. Use with caution.
- **Best Practice:** Always use the principle of least privilege when assigning roles and policies.
- **AWS Console vs. aws-auth ConfigMap:** The AWS Console Access Entries approach is the recommended method for configuring access.
- **Dual Permission Model:** Remember that EKS requires both:
  1. Kubernetes RBAC permissions (via groups like `system:masters`)
  2. AWS IAM permissions (via policies like `AmazonEKSClusterAdminPolicy`)
