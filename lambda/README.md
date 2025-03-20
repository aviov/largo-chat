# Largo Chat Lambda Function

This Lambda function serves as the backend for the RAG-based chatbot, providing API endpoints for content processing, speech-to-text, text-to-speech, and chat functionality.

## Local Development Setup

### Environment Variables

For local development, you can use a `.env` file to manage your environment variables. Copy the `.env.example` file to create your own `.env` file:

```bash
cp .env.example .env
```

Then edit the `.env` file with your actual API keys and configuration:

```
# Required for local development
OPENAI_API_KEY=your_openai_api_key_here
GOOGLE_API_KEY=/path/to/google_credentials.json
MILVUS_HOST=localhost
MILVUS_PORT=19530
```

With the dotenv integration, you won't need to export these variables manually - they'll be loaded automatically when you run the Lambda handler locally.

### Running Milvus with Docker Compose

The project includes a Docker Compose file to run Milvus locally:

```bash
# From the project root directory
docker-compose up -d
```

This will start Milvus and its dependent services (etcd, minio) in the background.

### Running the Lambda Function Locally

With environment variables set in your `.env` file and Milvus running via Docker Compose, you can run the Lambda function locally:

```bash
# From the lambda directory
pip install -r requirements.txt
python handler.py
```

This will start a local HTTP server on port 8000 (or the port specified in your `.env` file) that emulates API Gateway.

### Testing the Local API

You can test the local API with curl:

```bash
# Health check
curl http://localhost:8000/health

# Chat query
curl -X POST http://localhost:8000 -d '{"query": "What can you tell me about this product?"}'
```

## Production Deployment

In production, the Lambda function uses AWS Secrets Manager to retrieve API keys securely. The GitHub Actions workflow automatically updates these secrets during deployment.

### Secrets Required in GitHub

To deploy with GitHub Actions, you'll need to set these repository secrets:

- `AWS_ROLE_ARN`: The ARN of the GitHub Actions role (from CDK output)
- `AWS_REGION`: Your AWS region (e.g., "eu-central-1")
- `OPENAI_API_KEY`: Your OpenAI API key
- `GOOGLE_API_KEY`: Your Google Cloud API key (or JSON credentials)
