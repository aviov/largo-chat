# EKS Environment Setup for Milvus

This document explains how to prepare your Amazon EKS environment for Milvus deployment, including the consolidated script approach and individual scripts for specific use cases.

## Table of Contents

1. [Overview](#overview)
2. [Consolidated Setup Script](#consolidated-setup-script)
3. [Individual Scripts Reference](#individual-scripts-reference)
4. [Configuration Files Reference](#configuration-files-reference)
5. [Tools and Binaries](#tools-and-binaries)
6. [Troubleshooting](#troubleshooting)

## Overview

Setting up an EKS environment for Milvus involves multiple components:

1. **EKS Cluster Access**: Configure authentication and permissions
2. **Load Balancer Controller**: Set up the AWS Load Balancer Controller using IRSA
3. **Subnet Configuration**: Tag subnets correctly for LoadBalancer services
4. **Milvus Deployment**: Deploy Milvus with the correct LoadBalancer configuration
5. **DNS Configuration**: Set up DNS records for the Milvus endpoint

While we originally created individual scripts for each task, we've now consolidated the core functionality into a single script for easier use.

## Consolidated Setup Script

The [`prepare-eks-environment.sh`](./scripts/prepare-eks-environment.sh) script provides an end-to-end solution for preparing your EKS environment for Milvus deployment.

### Usage

```bash
# Set required environment variables
export EKS_CLUSTER_NAME=your-cluster-name
export AWS_REGION=eu-central-1
export AWS_ACCESS_KEY_ID=your-access-key
export AWS_SECRET_ACCESS_KEY=your-secret-key
export EKS_NAMESPACE=milvus  # Optional, defaults to 'milvus'

# Run the consolidated script
./scripts/prepare-eks-environment.sh
```

### What the Script Does

1. **AWS & EKS Configuration**
   - Configures AWS CLI with the provided credentials
   - Sets up EKS kubeconfig access
   - Updates the aws-auth ConfigMap to grant permissions

2. **Load Balancer Controller Setup**
   - Creates IAM policy for the AWS Load Balancer Controller
   - Creates IAM role with appropriate trust relationship
   - Creates service account with role annotation
   - Installs the AWS Load Balancer Controller using Helm

3. **Subnet Configuration**
   - Tags public subnets with `kubernetes.io/role/elb=1`
   - Tags private subnets with `kubernetes.io/role/internal-elb=1`
   - Adds cluster ownership tags (`kubernetes.io/cluster/<cluster-name>=shared`)

4. **Milvus Namespace and Validation**
   - Creates the namespace for Milvus deployment
   - Validates the entire setup
   - Provides next steps for deployment

### After Running the Script

After the environment is prepared, you can:

1. Deploy Milvus using: `./scripts/deploy-milvus-to-eks.sh`
2. Configure DNS: `./scripts/configure-milvus-dns.sh --hosted-zone-id <HOSTED_ZONE_ID> --dns-name <DNS_NAME>`
3. Test the connection: `python ./scripts/test-milvus-connection.py`

## Individual Scripts Reference

We've maintained individual scripts for flexibility, special cases, and learning purposes:

| Script | Description | Usage Scenario |
|--------|-------------|----------------|
| [`setup-eks-access.sh`](./scripts/setup-eks-access.sh) | Configures EKS access through kubeconfig and aws-auth | When you only need to update access permissions |
| [`create-lb-service-account.sh`](./scripts/create-lb-service-account.sh) | Creates service account for AWS Load Balancer Controller | When replacing/updating only the service account |
| [`tag-eks-subnets.sh`](./scripts/tag-eks-subnets.sh) | Tags subnets for LoadBalancer functionality | When subnet tags need to be updated |
| [`deploy-milvus-to-eks.sh`](./scripts/deploy-milvus-to-eks.sh) | Deploys Milvus to EKS with LoadBalancer | Main deployment script |
| [`configure-milvus-dns.sh`](./scripts/configure-milvus-dns.sh) | Configures DNS records for Milvus endpoint | When you need to update DNS records |
| [`test-milvus-connection.py`](./scripts/test-milvus-connection.py) | Validates Milvus connection | For testing connectivity |
| [`validate-milvus-health-checks.sh`](./scripts/validate-milvus-health-checks.sh) | Validates health check configurations | For optimizing reliability |
| [`upgrade-milvus-to-cluster.sh`](./scripts/upgrade-milvus-to-cluster.sh) | Upgrades from standalone to cluster mode | When scaling Milvus |

### Troubleshooting Scripts

These scripts were created during troubleshooting and may be useful in specific scenarios:

| Script | Description | Usage Scenario |
|--------|-------------|----------------|
| [`fix-eks-access.sh`](./scripts/fix-eks-access.sh) | Alternative approach to fixing EKS access issues | When standard access setup fails |
| [`direct-eks-access.sh`](./scripts/direct-eks-access.sh) | Establishes direct access to EKS | When IRSA approach isn't working |
| [`assume-eks-role.sh`](./scripts/assume-eks-role.sh) | Script for assuming a specific EKS role | When using cross-account roles |
| [`apply-aws-auth.sh`](./scripts/apply-aws-auth.sh) | Directly applies aws-auth ConfigMap | When the standard approach fails |

## Configuration Files Reference

The repository contains several configuration files that are either used directly or generated during the setup process:

| File | Description | How It's Used |
|------|-------------|---------------|
| [`aws-lb-service-account.yaml`](./aws-lb-service-account.yaml) | Service account definition for AWS Load Balancer Controller | Applied to Kubernetes to create the service account with IRSA |
| [`aws-auth-configmap.yaml`](./aws-auth-configmap.yaml) | ConfigMap for AWS IAM authentication | Applied to Kubernetes to grant IAM entities access to the cluster |
| [`aws-auth-cm.yaml`](./aws-auth-cm.yaml) | Alternative format of the aws-auth ConfigMap | Used in some troubleshooting scenarios |
| [`eks-admin-policy.json`](./eks-admin-policy.json) | IAM policy definition for EKS administration | Can be used to create an IAM policy with appropriate permissions |
| [`eks-admin-role.yaml`](./eks-admin-role.yaml) | Kubernetes role definition for EKS admins | Can be applied to grant admin permissions within Kubernetes |

### Generating/Updating Configuration Files

Most configuration files are generated automatically by the setup scripts. If you need to regenerate them:

```bash
# Generate AWS Load Balancer Controller service account
./scripts/create-lb-service-account.sh

# Generate aws-auth ConfigMap
kubectl get configmap aws-auth -n kube-system -o yaml > aws-auth-configmap.yaml
```

## Tools and Binaries

The repository includes some binaries and archives that were downloaded during the setup process:

| File | Description | Usage |
|------|-------------|-------|
| [`eksctl_Darwin_amd64.tar.gz`](./eksctl_Darwin_amd64.tar.gz) | Archive containing the eksctl tool for macOS | Tool for managing EKS clusters |
| [`aws-iam-authenticator`](./aws-iam-authenticator) | Binary for AWS IAM authentication | Used by kubectl to authenticate with EKS |

### Installing Tools Manually

You can also install these tools using package managers:

```bash
# Install eksctl
brew tap weaveworks/tap
brew install weaveworks/tap/eksctl

# Install aws-iam-authenticator
brew install aws-iam-authenticator
```

## Troubleshooting

Here are some common issues and their solutions:

### Cannot Access EKS Cluster

If you cannot access the EKS cluster after running the setup scripts:

1. Verify your AWS credentials are correct and have the necessary permissions
2. Check that aws-auth ConfigMap includes your IAM entity:
   ```bash
   kubectl get configmap aws-auth -n kube-system -o yaml
   ```
3. Try the direct access approach:
   ```bash
   ./scripts/direct-eks-access.sh
   ```

### Load Balancer Not Provisioning

If the LoadBalancer for Milvus is not being provisioned:

1. Verify the AWS Load Balancer Controller is running:
   ```bash
   kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller
   ```
2. Check that subnets are tagged correctly:
   ```bash
   ./scripts/tag-eks-subnets.sh
   ```
3. Check for errors in the controller logs:
   ```bash
   kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller
   ```

### Additional Help

For more detailed troubleshooting and deployment information, refer to the main [Milvus EKS Deployment README](./README-EKS-MILVUS-DEPLOYMENT.md).
