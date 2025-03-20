# Milvus EKS Deployment Guide

This guide provides instructions for deploying Milvus on Amazon EKS using our AWS CDK infrastructure.

## Prerequisites

- AWS CLI configured with appropriate permissions
- kubectl installed
- Helm installed

## Automated Deployment

### GitHub Actions (CI/CD)

The GitHub Actions workflow in `.github/workflows/deploy.yml` will:

1. Deploy the CDK stack with EKS infrastructure
2. Create/update necessary secrets in AWS Secrets Manager
3. Deploy Milvus to the EKS cluster using Helm

To use this automated deployment:

1. Ensure the following GitHub secrets are configured in your repository:
   - `AWS_ROLE_ARN`: ARN of the IAM role with permission to deploy
   - `AWS_REGION`: AWS region to deploy to
   - `OPENAI_API_KEY`: Your OpenAI API key
   - `GOOGLE_API_KEY`: Your Google API key for TTS services

2. Push to the main branch or manually trigger the workflow from the Actions tab

### Manual Local Deployment

For local deployment, follow these steps:

1. Deploy the CDK stack:
   ```bash
   cd cdk
   npm ci
   npm run build
   npm run cdk deploy
   ```

2. Run the Milvus deployment script:
   ```bash
   ./scripts/deploy-milvus-to-eks.sh
   ```

## Manual Deployment Steps (If Script Fails)

If you need to manually deploy Milvus to the EKS cluster:

1. Configure kubectl to connect to your EKS cluster:
   ```bash
   aws eks update-kubeconfig --name milvus-cluster --region <your-region>
   ```

2. Install AWS EBS CSI Driver:
   ```bash
   kubectl apply -k "github.com/kubernetes-sigs/aws-ebs-csi-driver/deploy/kubernetes/overlays/stable/?ref=master"
   ```

3. Create a Storage Class for EBS volumes:
   ```bash
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
   ```

4. Install AWS Load Balancer Controller:
   ```bash
   helm repo add eks https://aws.github.io/eks-charts
   helm repo update
   helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
     --namespace kube-system \
     --set clusterName=milvus-cluster \
     --set serviceAccount.create=true \
     --set serviceAccount.name=aws-load-balancer-controller
   ```

5. Create a namespace for Milvus:
   ```bash
   kubectl create namespace milvus
   ```

6. Install Milvus using Helm:
   ```bash
   # Get Milvus bucket name from CloudFormation outputs
   MILVUS_BUCKET_NAME=$(aws cloudformation describe-stacks --stack-name ChatbotStack --query "Stacks[0].Outputs[?OutputKey=='MilvusBucketName'].OutputValue" --output text)
   
   # Install Milvus
   helm repo add milvus https://zilliztech.github.io/milvus-helm/
   helm repo update
   helm install milvus milvus/milvus \
     --namespace milvus \
     --set cluster.enabled=true \
     --set service.type=LoadBalancer \
     --set service.annotations."service\.beta\.kubernetes\.io/aws-load-balancer-type"=external \
     --set service.annotations."service\.beta\.kubernetes\.io/aws-load-balancer-scheme"=internet-facing \
     --set minio.enabled=false \
     --set externalS3.enabled=true \
     --set externalS3.host="s3.<your-region>.amazonaws.com" \
     --set externalS3.port=443 \
     --set externalS3.useSSL=true \
     --set externalS3.bucketName=$MILVUS_BUCKET_NAME \
     --set externalS3.useIAM=true \
     --set externalS3.cloudProvider=aws \
     --set externalS3.region=<your-region>
   ```

7. Get the Milvus endpoint:
   ```bash
   kubectl get svc -n milvus milvus-milvus -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
   ```

8. Update your Lambda function with the Milvus endpoint (if applicable):
   ```bash
   aws lambda update-function-configuration \
     --function-name <your-lambda-function> \
     --environment "Variables={MILVUS_HOST=<milvus-endpoint>,MILVUS_PORT=19530}"
   ```

## Troubleshooting

### Common Issues

1. **EKS Cluster Creation Fails**:
   - Check IAM permissions for the deploying user/role
   - Ensure there are no VPC conflicts

2. **Milvus Pods Not Starting**:
   - Check pod status: `kubectl get pods -n milvus`
   - View logs: `kubectl logs <pod-name> -n milvus`
   - Check EBS volumes: `kubectl get pvc -n milvus`

3. **S3 Connection Issues**:
   - Verify IAM permissions for the EKS node group
   - Check that the S3 bucket exists and is accessible

### Health Check Best Practices

For any containerized services in this deployment, we follow these health check best practices:

1. **Resilient Application Startup**:
   - Start HTTP server before attempting database connections
   - Handle connection failures gracefully without crashing
   - Implement proper SIGTERM handling for graceful shutdown

2. **Standardized Health Check Endpoints**:
   - Use a single `/health` endpoint across all services
   - Include diagnostic information in health check responses
   - Implement appropriate logging for troubleshooting

3. **Kubernetes Health Checks**:
   - Configure liveness probe with appropriate failure thresholds
   - Set readiness probe to ensure traffic only routes to ready services
   - Use startup probe with sufficient time for initial boot

## Maintenance

### Upgrading Milvus

To upgrade Milvus to a new version:

```bash
helm repo update
helm upgrade milvus milvus/milvus \
  --namespace milvus \
  [include all the original parameters]
```

### Monitoring

Set up CloudWatch metrics for:
- EKS cluster metrics
- EC2 node metrics
- Milvus service metrics

### Backup and Restore

S3 bucket data should be backed up according to your organization's backup policy.
