# Frontend Development Guide

This document provides a comprehensive guide for developing the frontend application that connects to the Lambda API and Milvus database.

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Development Setup](#development-setup)
3. [API Client](#api-client)
4. [Environment Configuration](#environment-configuration)
5. [Deployment with AWS Amplify](#deployment-with-aws-amplify)
6. [Lambda Function Updates](#lambda-function-updates)
7. [Development Workflow](#development-workflow)
8. [Troubleshooting](#troubleshooting)
9. [AWS CDK Outputs Reference](#aws-cdk-outputs-reference)

## Architecture Overview

The application consists of three main components:

1. **React Frontend**: This application that provides the user interface.
2. **Lambda API**: Handles business logic, processing, and interfaces with other services.
3. **Milvus Database**: Vector database running on Amazon EKS for semantic search capabilities.

The frontend communicates with the Lambda API, which in turn communicates with the Milvus database. This architecture allows for efficient development and deployment of each component independently.

```
┌─────────────┐    ┌─────────────┐    ┌─────────────┐
│   React     │    │   Lambda    │    │   Milvus    │
│  Frontend   │───>│    API      │───>│  Database   │
│  (Amplify)  │    │  (AWS)      │    │   (EKS)     │
└─────────────┘    └─────────────┘    └─────────────┘
```

## Development Setup

### Prerequisites

- Node.js and npm
- AWS CLI configured with appropriate credentials
- Git

### Initial Setup

1. Clone the repository:
   ```bash
   git clone <repository-url>
   cd largo-chat
   ```

2. Install frontend dependencies:
   ```bash
   cd frontend
   npm install
   ```

3. Set up environment files:
   ```bash
   # Frontend environment
   cp .env.example .env
   # Edit .env with your configuration
   ```

## API Client

The frontend uses a dedicated API client to communicate with the Lambda API. This client is located at `src/api/api-client.ts`:

```typescript
// src/api/api-client.ts
import axios from 'axios';

// Define the base URL for the API
const API_BASE_URL = process.env.REACT_APP_API_ENDPOINT || 'http://localhost:8000';

// Create an axios instance with the base URL
const apiClient = axios.create({
  baseURL: API_BASE_URL,
  headers: {
    'Content-Type': 'application/json',
  },
});

// API methods
export const api = {
  // Search in Milvus
  search: async (request) => {
    const response = await apiClient.post('/search', request);
    return response.data;
  },

  // Upload files to be processed and stored in Milvus
  upload: async (request) => {
    const formData = new FormData();
    
    request.files.forEach((file, index) => {
      formData.append(`file${index}`, file);
    });
    
    if (request.metadata) {
      formData.append('metadata', JSON.stringify(request.metadata));
    }
    
    const response = await apiClient.post('/upload', formData, {
      headers: {
        'Content-Type': 'multipart/form-data',
      },
    });
    
    return response.data;
  },

  // Get collection info from Milvus
  getCollections: async () => {
    const response = await apiClient.get('/collections');
    return response.data;
  },

  // Health check endpoint
  health: async () => {
    const response = await apiClient.get('/health');
    return response.data;
  }
};
```

### Using the API Client in React Components

Example usage in a React component:

```jsx
import React, { useState, useEffect } from 'react';
import { api } from '../api/api-client';

function CollectionsList() {
  const [collections, setCollections] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);

  useEffect(() => {
    const fetchCollections = async () => {
      try {
        const data = await api.getCollections();
        setCollections(data);
        setLoading(false);
      } catch (err) {
        setError(err.message);
        setLoading(false);
      }
    };

    fetchCollections();
  }, []);

  if (loading) return <p>Loading collections...</p>;
  if (error) return <p>Error: {error}</p>;

  return (
    <div>
      <h2>Milvus Collections</h2>
      <ul>
        {collections.map((collection) => (
          <li key={collection.name}>{collection.name}</li>
        ))}
      </ul>
    </div>
  );
}

export default CollectionsList;
```

## Environment Configuration

### Frontend Environment Variables

Create a `.env` file in the frontend directory with the following variables:

```
# API endpoint (Lambda function URL or API Gateway URL)
# For local development:
# REACT_APP_API_ENDPOINT=http://localhost:8000
# For production (use the API endpoint from CDK output):
REACT_APP_API_ENDPOINT=https://z159wnpazl.execute-api.eu-central-1.amazonaws.com/prod/

# If direct Milvus connection is needed (usually not required if using Lambda as intermediary)
# REACT_APP_MILVUS_HOST=milvus.your-domain.com
# REACT_APP_MILVUS_PORT=19530

# Other application settings
REACT_APP_MAX_UPLOAD_SIZE=10485760  # 10MB in bytes
```

For local development, set `REACT_APP_API_ENDPOINT` to your local Lambda server (typically `http://localhost:8000`). For testing with the deployed Lambda, use its HTTP endpoint.

### Lambda Environment Variables

The Lambda function should be configured with these environment variables:

```
# API Keys
OPENAI_API_KEY=your-openai-key
GOOGLE_API_KEY=path-to-google-credentials.json

# Milvus Connection (values for AWS)
MILVUS_HOST=k8s-milvus-milvus-6d3070a14d-31edb78254d7939f.elb.eu-central-1.amazonaws.com
MILVUS_PORT=19530

# S3 Configuration
BUCKET_NAME=chatbotstack-contentbucket52d4b12c-3nzaezgr3s7l

# Local Server Configuration
PORT=8000

# AWS Credentials
AWS_ACCESS_KEY_ID=your-access-key
AWS_SECRET_ACCESS_KEY=your-secret-key
AWS_REGION=eu-central-1
AWS_DEFAULT_REGION=eu-central-1
```

## Deployment with AWS Amplify

This project uses AWS Amplify for frontend deployment. Amplify provides CI/CD capabilities, hosting, and environment management.

### Manual Deployment

Use the deployment script to deploy your frontend to Amplify:

```bash
./scripts/deploy-frontend.sh
```

This script:
1. Gets your Amplify app ID
2. Determines your current git branch
3. Creates the branch in Amplify if it doesn't exist
4. Starts a build job

### Amplify Configuration

The Amplify configuration is defined in `amplify.yml` in the frontend directory:

```yaml
version: 1
frontend:
  phases:
    preBuild:
      commands:
        - npm ci
    build:
      commands:
        - npm run build
  artifacts:
    baseDirectory: build
    files:
      - '**/*'
  cache:
    paths:
      - node_modules/**/*
```

### Accessing Deployed Frontend

After deployment, you can access your frontend at the URL provided by Amplify:
```
https://<branch-name>.<app-id>.amplifyapp.com
```

## Lambda Function Updates

When you need to update Lambda functions without redeploying the entire stack, use the Lambda deployment script:

```bash
./scripts/deploy-lambda.sh your-function-name
```

This script:
1. Creates a deployment package (ZIP) of your Lambda code
2. Updates only the specified Lambda function
3. Cleans up temporary files

## Development Workflow

### Local Development

1. **Start your local Lambda server:**
   ```bash
   cd lambda
   # Start the local server (specific command depends on your setup)
   ```

2. **Start your React development server:**
   ```bash
   cd frontend
   npm start
   ```

3. **Make frontend changes with hot reloading**
   - Modify React components
   - API calls will go to your local Lambda server
   - Changes are immediately visible in the browser

### Connecting to Deployed Services

To test with the deployed Milvus database:

1. Update Lambda's `.env` to use the EKS Milvus endpoint:
   ```
   MILVUS_HOST=k8s-milvus-milvus-6d3070a14d-31edb78254d7939f.elb.eu-central-1.amazonaws.com
   MILVUS_PORT=19530
   ```

2. Restart your local Lambda server to apply the changes

### Deployment Workflow

1. **Develop and test locally**
2. **Commit changes to Git**
3. **Deploy Lambda updates:**
   ```bash
   ./scripts/deploy-lambda.sh your-function-name
   ```
4. **Deploy frontend to Amplify:**
   ```bash
   ./scripts/deploy-frontend.sh
   ```

## Troubleshooting

### Common Issues

#### Cannot Connect to Lambda API

- Check that your Lambda server is running
- Verify the `REACT_APP_API_ENDPOINT` in your `.env` file
- Check browser console for CORS errors

#### Cannot Connect to Milvus

- Verify the Milvus host and port in Lambda's `.env`
- Ensure the EKS cluster is running: `kubectl get pods -n milvus`
- Check that the LoadBalancer is accessible:
  ```bash
  kubectl get svc -n milvus milvus
  ```

#### Deployment Issues

- **Amplify deployment fails**: Check the Amplify console for build logs
- **Lambda deployment fails**: Check AWS CLI error messages and Lambda permissions

### Getting Milvus LoadBalancer Endpoint

If you need to get the Milvus LoadBalancer endpoint again:

```bash
kubectl get svc -n milvus milvus -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

This will output the hostname to use in your Lambda's `.env` file.

---

For additional help or questions, please refer to the EKS deployment documentation or contact the project maintainers.

## AWS CDK Outputs Reference

After deploying the CDK stack, you'll receive several important outputs. Here's how to use each of them:

### API Endpoints
```
ChatbotStack.ApiEndpoint = https://z159wnpazl.execute-api.eu-central-1.amazonaws.com/prod/
ChatbotStack.ChatApiEndpoint467C6B40 = https://z159wnpazl.execute-api.eu-central-1.amazonaws.com/prod/
```
- Use in your `frontend/.env` file as `REACT_APP_API_ENDPOINT`
- This is the production endpoint for your API

### Storage Buckets
```
ChatbotStack.ContentBucketName = chatbotstack-contentbucket52d4b12c-3nzaezgr3s7l
ChatbotStack.MilvusBucketName = chatbotstack-milvusbucket698b444d-xg1hdzshb9ii
```
- Set `BUCKET_NAME` in your Lambda environment to the Content Bucket name
- The Milvus bucket is used internally by Milvus

### EKS Cluster Details
```
ChatbotStack.EksClusterName = milvus-cluster
ChatbotStack.EksConnectionCommand = aws eks update-kubeconfig --name milvus-cluster --region eu-central-1
```
- Run the EKS connection command to configure kubectl
- Use the cluster name when referring to your EKS cluster in scripts

### Lambda Function Details
```
ChatbotStack.LambdaFunctionName = ChatbotStack-ChatLambda59BC07ED-JZpcgRYikmH3
```
- Use with the Lambda deployment script:
  ```bash
  ./scripts/deploy-lambda.sh ChatbotStack-ChatLambda59BC07ED-JZpcgRYikmH3
  ```

### Authentication Information
```
ChatbotStack.UserPoolClientId = 2v3eiooib760odbkcgg949op8j
ChatbotStack.UserPoolId = eu-central-1_vuBhAGI2h
```
- For Amplify authentication configuration:
  ```javascript
  // src/index.js or App.js
  import { Amplify } from 'aws-amplify';
  
  Amplify.configure({
    Auth: {
      region: 'eu-central-1',
      userPoolId: 'eu-central-1_vuBhAGI2h',
      userPoolWebClientId: '2v3eiooib760odbkcgg949op8j'
    }
  });
  ```

### GitHub Actions Role
```
ChatbotStack.GitHubActionsRoleARN = arn:aws:iam::615022891451:role/ChatbotStack-GitHubActionsRole4F1BBA26-RAKgG5OuwnSu
```
- Use in GitHub Actions workflows for CI/CD
- Add to your GitHub repository secrets if using GitHub Actions
