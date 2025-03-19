import * as cdk from 'aws-cdk-lib';
import { Construct } from 'constructs';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as eks from 'aws-cdk-lib/aws-eks';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as apigateway from 'aws-cdk-lib/aws-apigateway';
import * as amplify from '@aws-cdk/aws-amplify-alpha';
import * as s3 from 'aws-cdk-lib/aws-s3';
import * as cognito from 'aws-cdk-lib/aws-cognito';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as secretsmanager from 'aws-cdk-lib/aws-secretsmanager';
import * as logs from 'aws-cdk-lib/aws-logs';
import * as codebuild from 'aws-cdk-lib/aws-codebuild';

export class ChatbotStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props?: cdk.StackProps) {
    super(scope, id, props);

    // GitHub OIDC provider for GitHub Actions authentication
    // Import the existing OIDC provider instead of creating a new one
    const githubOidcProvider = iam.OpenIdConnectProvider.fromOpenIdConnectProviderArn(
      this,
      'GitHubOidcProvider',
      `arn:aws:iam::${this.account}:oidc-provider/token.actions.githubusercontent.com`
    );
    
    // Create GitHub Actions role using the imported provider
    const githubActionsRole = new iam.Role(this, 'GitHubActionsRole', {
      assumedBy: new iam.WebIdentityPrincipal(githubOidcProvider.openIdConnectProviderArn, {
        StringEquals: {
          'token.actions.githubusercontent.com:aud': 'sts.amazonaws.com'
        },
        StringLike: {
          'token.actions.githubusercontent.com:sub': 'repo:*:*'
        }
      }),
      description: 'Role assumed by GitHub Actions for CDK deployments',
      managedPolicies: [
        iam.ManagedPolicy.fromAwsManagedPolicyName('AdministratorAccess')
      ]
    });
    
    // Output the role ARN for GitHub Actions
    new cdk.CfnOutput(this, 'GitHubActionsRoleARN', {
      value: githubActionsRole.roleArn,
      description: 'ARN of the IAM role for GitHub Actions',
      exportName: 'GitHubActionsRoleARN'
    });

    // Create placeholder secrets in AWS Secrets Manager
    // Instead of hardcoding values, these will be populated through GitHub Actions with OIDC
    const openaiSecret = new secretsmanager.Secret(this, 'OpenAISecret', {
      description: 'OpenAI API key for chatbot',
      secretName: 'largo-chat/openai-api-key'
    });
    
    const googleSecret = new secretsmanager.Secret(this, 'GoogleSecret', {
      description: 'Google Cloud API key for TTS',
      secretName: 'largo-chat/google-api-key'
    });

    // Create VPC for EKS
    const vpc = new ec2.Vpc(this, 'Vpc', { 
      maxAzs: 2,
      natGateways: 1
    });

    // Create S3 bucket for Milvus
    const milvusBucket = new s3.Bucket(this, 'MilvusBucket', {
      removalPolicy: cdk.RemovalPolicy.DESTROY,
      autoDeleteObjects: true,
      versioned: true,
      encryption: s3.BucketEncryption.S3_MANAGED,
    });

    // Create IAM policy for Milvus to access S3
    const milvusS3Policy = new iam.ManagedPolicy(this, 'MilvusS3Policy', {
      managedPolicyName: 'MilvusS3ReadWrite',
      statements: [
        new iam.PolicyStatement({
          effect: iam.Effect.ALLOW,
          actions: [
            's3:GetObject',
            's3:PutObject',
            's3:DeleteObject',
            's3:ListBucket',
          ],
          resources: [
            milvusBucket.bucketArn,
            `${milvusBucket.bucketArn}/*`
          ]
        })
      ]
    });

    // Create a security group for the EKS cluster
    const clusterSecurityGroup = new ec2.SecurityGroup(this, 'EksClusterSG', {
      vpc,
      description: 'Security group for EKS cluster',
      allowAllOutbound: true
    });

    // Create IAM role for EKS cluster
    const eksClusterRole = new iam.Role(this, 'EksClusterRole', {
      assumedBy: new iam.ServicePrincipal('eks.amazonaws.com'),
      managedPolicies: [
        iam.ManagedPolicy.fromAwsManagedPolicyName('AmazonEKSClusterPolicy')
      ]
    });

    // Create an EKS cluster with minimal configuration to avoid kubectl layer issues
    const eksClusterName = 'milvus-cluster';
    
    // Create the EKS cluster resource directly instead of using the high-level construct
    const eksCluster = new cdk.aws_eks.CfnCluster(this, 'EksCfnCluster', {
      name: eksClusterName,
      roleArn: eksClusterRole.roleArn,
      version: '1.27',
      resourcesVpcConfig: {
        subnetIds: vpc.privateSubnets.map(subnet => subnet.subnetId),
        endpointPublicAccess: true,
        endpointPrivateAccess: true,
        securityGroupIds: [clusterSecurityGroup.securityGroupId]
      }
    });

    // Create IAM role for EKS node group
    const nodeGroupRole = new iam.Role(this, 'EksNodeGroupRole', {
      assumedBy: new iam.ServicePrincipal('ec2.amazonaws.com'),
      managedPolicies: [
        iam.ManagedPolicy.fromAwsManagedPolicyName('AmazonEKSWorkerNodePolicy'),
        iam.ManagedPolicy.fromAwsManagedPolicyName('AmazonEKS_CNI_Policy'),
        iam.ManagedPolicy.fromAwsManagedPolicyName('AmazonEC2ContainerRegistryReadOnly'),
        iam.ManagedPolicy.fromAwsManagedPolicyName('AmazonSSMManagedInstanceCore')
      ]
    });

    // Add S3 access policy to the node group role
    nodeGroupRole.addToPrincipalPolicy(
      new iam.PolicyStatement({
        actions: [
          's3:GetObject',
          's3:PutObject',
          's3:DeleteObject',
          's3:ListBucket'
        ],
        resources: [
          milvusBucket.bucketArn,
          `${milvusBucket.bucketArn}/*`
        ]
      })
    );

    // Create EKS managed node group
    const nodeGroup = new cdk.aws_eks.CfnNodegroup(this, 'EksNodeGroup', {
      clusterName: eksClusterName,
      nodegroupName: 'milvus-nodes',
      nodeRole: nodeGroupRole.roleArn,
      subnets: vpc.privateSubnets.map(subnet => subnet.subnetId),
      instanceTypes: ['m5.large', 'm5.xlarge'],
      diskSize: 50,
      scalingConfig: {
        desiredSize: 2,
        minSize: 1,
        maxSize: 3
      }
    });

    // Add dependency to ensure proper creation order
    nodeGroup.addDependsOn(eksCluster);

    // Output the EKS cluster name for reference
    new cdk.CfnOutput(this, 'EksClusterName', {
      value: eksClusterName,
      description: 'The name of the EKS cluster',
      exportName: 'MilvusEksClusterName'
    });

    // Output instructions for connecting to the cluster
    new cdk.CfnOutput(this, 'EksConnectionCommand', {
      value: `aws eks update-kubeconfig --name ${eksClusterName} --region ${this.region}`,
      description: 'Command to configure kubectl for this cluster'
    });

    // S3 for Content Upload
    const contentBucket = new s3.Bucket(this, 'ContentBucket', {
      removalPolicy: cdk.RemovalPolicy.DESTROY,
      autoDeleteObjects: true,
    });

    // Lambda Role with Policies
    const lambdaRole = new iam.Role(this, 'ChatLambdaRole', {
      assumedBy: new iam.ServicePrincipal('lambda.amazonaws.com'),
    });
    lambdaRole.addManagedPolicy(iam.ManagedPolicy.fromAwsManagedPolicyName('service-role/AWSLambdaBasicExecutionRole')); // Logs
    lambdaRole.addToPolicy(new iam.PolicyStatement({
      actions: ['s3:GetObject', 's3:PutObject'],
      resources: [contentBucket.bucketArn, `${contentBucket.bucketArn}/*`],
    }));
    lambdaRole.addToPolicy(new iam.PolicyStatement({
      actions: ['secretsmanager:GetSecretValue'],
      resources: [openaiSecret.secretArn, googleSecret.secretArn],
    }));

    // Lambda for Chat/STT/TTS
    const chatLambda = new lambda.Function(this, 'ChatLambda', {
      runtime: lambda.Runtime.PYTHON_3_9,
      handler: 'handler.main',
      code: lambda.Code.fromAsset('../lambda'),
      timeout: cdk.Duration.seconds(30),
      memorySize: 1024,
      role: lambdaRole,
      environment: {
        OPENAI_SECRET_ARN: openaiSecret.secretArn,
        GOOGLE_SECRET_ARN: googleSecret.secretArn,
        BUCKET_NAME: contentBucket.bucketName,
      },
    });

    // API Gateway with Cognito Authorizer
    const userPool = new cognito.UserPool(this, 'UserPool', {
      selfSignUpEnabled: true,
      signInAliases: { email: true },
      autoVerify: { email: true },
    });
    const userPoolClient = userPool.addClient('AppClient');
    const authorizer = new apigateway.CognitoUserPoolsAuthorizer(this, 'ApiAuthorizer', {
      cognitoUserPools: [userPool],
    });
    const api = new apigateway.LambdaRestApi(this, 'ChatApi', {
      handler: chatLambda,
      defaultMethodOptions: { authorizer },
      proxy: false
    });
    const chatResource = api.root.addResource('chat');
    chatResource.addMethod('POST');

    // Add Upload Resources
    const uploadResource = api.root.addResource('upload');
    uploadResource.addMethod('POST');

    // Comment out the Amplify Hosting configuration since it's causing deployment errors
    // You can uncomment and properly configure this after creating the github-token secret
    /*
    const amplifyApp = new amplify.App(this, 'ChatApp', {
      sourceCodeProvider: new amplify.GitHubSourceCodeProvider({
        owner: 'your-github-username-or-org', // Update with your actual GitHub owner
        repository: 'largo-chat',
        oauthToken: cdk.SecretValue.secretsManager('github-token', { jsonField: 'token' }) // Using SecretManager to store the token
      }),
      autoBranchCreation: { 
        patterns: ['main', 'dev', 'feature/*'] 
      },
      autoBranchDeletion: true
    });
    
    // Add main branch with environment variables
    amplifyApp.addBranch('main', {
      environmentVariables: {
        'API_ENDPOINT': api.url,
        'COGNITO_USER_POOL_ID': userPool.userPoolId,
        'COGNITO_CLIENT_ID': userPoolClient.userPoolClientId
      }
    });
    
    // Add custom rule for SPA routing
    amplifyApp.addCustomRule({
      source: '/<*>',
      target: '/index.html',
      status: amplify.RedirectStatus.NOT_FOUND_REWRITE
    });
    */

    // Output important resources
    new cdk.CfnOutput(this, 'ApiEndpoint', {
      value: api.url,
      description: 'API Gateway endpoint URL',
    });
    
    new cdk.CfnOutput(this, 'UserPoolId', {
      value: userPool.userPoolId,
      description: 'Cognito User Pool ID',
    });
    
    new cdk.CfnOutput(this, 'UserPoolClientId', {
      value: userPoolClient.userPoolClientId,
      description: 'Cognito User Pool Client ID',
    });
    
    new cdk.CfnOutput(this, 'ContentBucketName', {
      value: contentBucket.bucketName,
      description: 'Content S3 Bucket Name',
    });
    
    // Add outputs for Milvus deployment script
    new cdk.CfnOutput(this, 'MilvusBucketName', {
      value: milvusBucket.bucketName,
      description: 'Milvus S3 Bucket Name',
      exportName: 'MilvusBucketName'
    });

    new cdk.CfnOutput(this, 'LambdaFunctionName', {
      value: chatLambda.functionName,
      description: 'Chat Lambda Function Name',
      exportName: 'ChatLambdaFunctionName'
    });
  }
}