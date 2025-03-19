import json
import boto3
from openai import OpenAI
from google.cloud import texttospeech
from pymilvus import connections, Collection, exceptions as milvus_exceptions
from langchain.text_splitter import RecursiveCharacterTextSplitter
import PyPDF2
import os
import time
import signal
import sys
import http.server
import socketserver
import threading
import pathlib
import importlib.util

# Import Milvus setup utilities
from milvus_setup import create_milvus_collection

# Load .env file for local development
try:
    from dotenv import load_dotenv
    env_path = pathlib.Path(__file__).parent / '.env'
    if env_path.exists():
        print(f"Loading environment from {env_path}")
        load_dotenv(dotenv_path=env_path)
    else:
        print(f".env file not found at {env_path}, using environment variables")
except ImportError:
    print("python-dotenv not installed, using environment variables")

# Initialize AWS clients
s3 = boto3.client('s3')
secrets_client = boto3.client('secretsmanager')

# Initialize global variables that will be populated in init function
openai_client = None
google_tts = None
collection = None
embedder = None

# Flag to track initialization status
is_initialized = False

# Simple fallback embedding class when HuggingFace isn't available
class DummyEmbedder:
    """
    Fallback embedder that uses OpenAI for embeddings when HuggingFace isn't available.
    This ensures the service can still function without the local embedding model.
    """
    def __init__(self, openai_client):
        self.openai_client = openai_client
        print("Using OpenAI embeddings as fallback")

    def embed_query(self, text):
        if not self.openai_client:
            raise ValueError("OpenAI client not initialized")
        response = self.openai_client.embeddings.create(
            model="text-embedding-3-small",
            input=text
        )
        return response.data[0].embedding
        
    def embed_documents(self, texts):
        if not self.openai_client:
            raise ValueError("OpenAI client not initialized")
        response = self.openai_client.embeddings.create(
            model="text-embedding-3-small",
            input=texts
        )
        return [item.embedding for item in response.data]

# Try to import HuggingFaceEmbeddings
hf_embeddings_available = False
try:
    from langchain.embeddings import HuggingFaceEmbeddings
    import sentence_transformers
    hf_embeddings_available = True
    print("HuggingFace and sentence_transformers imported successfully")
except ImportError as e:
    print(f"WARNING: Unable to import embedding modules: {str(e)}")
    print("Will use OpenAI embeddings as fallback if OpenAI is available")

def init():
    """Initialize connections and clients with graceful error handling"""
    global openai_client, google_tts, collection, embedder, is_initialized
    
    # Initialize OpenAI client first as it may be needed for fallback embeddings
    try:
        # Fetch API keys from Secrets Manager using ARNs
        openai_secret_arn = os.getenv('OPENAI_SECRET_ARN')
        google_secret_arn = os.getenv('GOOGLE_SECRET_ARN')
        
        if openai_secret_arn and google_secret_arn:
            openai_key = secrets_client.get_secret_value(SecretId=openai_secret_arn)['SecretString']
            google_key = secrets_client.get_secret_value(SecretId=google_secret_arn)['SecretString']
            
            # In local dev, fall back to environment variables if secrets can't be retrieved
            openai_client = OpenAI(api_key=openai_key)
            
            # Set up Google credentials
            os.environ['GOOGLE_APPLICATION_CREDENTIALS'] = '/tmp/google_credentials.json'
            with open('/tmp/google_credentials.json', 'w') as f:
                f.write(google_key)
            google_tts = texttospeech.TextToSpeechClient()
        else:
            # Local development fallback
            print("Secrets ARNs not found, using local environment variables")
            openai_client = OpenAI(api_key=os.getenv('OPENAI_API_KEY'))
            
            # Set up Google credentials for local development
            google_creds_path = os.getenv('GOOGLE_API_KEY')
            if google_creds_path:
                # Handle relative paths in local development
                if not os.path.isabs(google_creds_path):
                    google_creds_path = os.path.join(os.path.dirname(__file__), google_creds_path)
                
                if os.path.exists(google_creds_path):
                    print(f"Using Google credentials from: {google_creds_path}")
                    os.environ['GOOGLE_APPLICATION_CREDENTIALS'] = google_creds_path
                else:
                    print(f"Warning: Google credentials file not found at {google_creds_path}")
            
            # Initialize Google TTS client
            try:
                google_tts = texttospeech.TextToSpeechClient()
                print("Successfully initialized Google TTS client")
            except Exception as e:
                print(f"Error initializing Google TTS client: {str(e)}")
                google_tts = None
                
        # Initialize Milvus and create collection if needed
        try:
            # Milvus Connection
            milvus_host = os.getenv('MILVUS_HOST', 'localhost')
            milvus_port = os.getenv('MILVUS_PORT', '19530')
            
            print("Initializing Milvus collection")
            collection = create_milvus_collection(milvus_host, milvus_port)
            print("Milvus collection ready")
        except Exception as e:
            print(f"Error setting up Milvus collection: {str(e)}")
        
        # Initialize embedding model with fallback strategy
        if hf_embeddings_available:
            try:
                print("Initializing HuggingFace embeddings model")
                embedder = HuggingFaceEmbeddings(model_name='BAAI/bge-base-en')
                print("HuggingFace embeddings model ready")
            except Exception as e:
                print(f"Error initializing HuggingFace embeddings model: {str(e)}")
                if openai_client:
                    print("Falling back to OpenAI embeddings")
                    embedder = DummyEmbedder(openai_client)
                else:
                    print("No embedding service available")
                    embedder = None
        else:
            if openai_client:
                print("Using OpenAI embeddings as HuggingFace is not available")
                embedder = DummyEmbedder(openai_client)
            else:
                print("No embedding service available")
                embedder = None
        
        is_initialized = True
        print("Initialization complete")
    except Exception as e:
        print(f"Initialization error: {str(e)}")
        # Don't raise, let the service continue and retry init later

def connect_to_milvus(host, port, max_retries=5):
    """Connect to Milvus with retry logic"""
    global collection
    
    retries = 0
    while retries < max_retries:
        try:
            connections.connect(host=host, port=port)
            collection = Collection('docs')  # Precreated via milvus_setup.py
            print(f"Successfully connected to Milvus at {host}:{port}")
            return True
        except milvus_exceptions.MilvusException as e:
            retries += 1
            print(f"Failed to connect to Milvus (attempt {retries}/{max_retries}): {str(e)}")
            if retries >= max_retries:
                print("Max retries reached, continuing without Milvus connection")
                return False
            time.sleep(3)  # Wait before retrying

def process_pdf(bucket, key):
    if not collection or not embedder:
        print("ERROR: Cannot process PDF without Milvus collection and embeddings model")
        return False
        
    try:
        pdf_file = s3.get_object(Bucket=bucket, Key=key)['Body']
        text = ''.join(PyPDF2.PdfReader(pdf_file).pages[i].extract_text() for i in range(len(PyPDF2.PdfReader(pdf_file).pages)))
        splitter = RecursiveCharacterTextSplitter(chunk_size=1000, chunk_overlap=200)
        chunks = splitter.split_text(text)
        embeddings = embedder.embed_documents(chunks)
        collection.insert([[i for i in range(len(chunks))], embeddings, chunks, [key]*len(chunks)])
        return True
    except Exception as e:
        print(f"Error processing PDF: {str(e)}")
        return False

def speech_to_text(audio_data):
    if not openai_client:
        print("ERROR: OpenAI client not initialized")
        return None
        
    try:
        with open('/tmp/audio.wav', 'wb') as f:
            f.write(bytes.fromhex(audio_data))
        with open('/tmp/audio.wav', 'rb') as f:
            transcript = openai_client.audio.transcriptions.create(model='whisper-1', file=f, language='et')
        return transcript.text
    except Exception as e:
        print(f"Error in speech-to-text: {str(e)}")
        return None

def text_to_speech(text):
    if not google_tts:
        print("ERROR: Google TTS client not initialized")
        return None
        
    try:
        synthesis_input = texttospeech.SynthesisInput(text=text)
        voice = texttospeech.VoiceSelectionParams(language_code='et-EE', name='et-EE-Wavenet-A')
        audio_config = texttospeech.AudioConfig(audio_encoding='MP3')
        response = google_tts.synthesize_speech(input=synthesis_input, voice=voice, audio_config=audio_config)
        return response.audio_content.hex()
    except Exception as e:
        print(f"Error in text-to-speech: {str(e)}")
        return None

def health_check():
    """Health check endpoint following our established pattern"""
    # Always return a 200 status code for health checks
    # Add detailed component status for troubleshooting
    embedding_type = "HuggingFace" if isinstance(embedder, HuggingFaceEmbeddings) else \
                     "OpenAI fallback" if embedder else "None"
    
    status = {
        "service": "largo-chat-lambda",
        "status": "healthy",
        "timestamp": time.time(),
        "initialized": is_initialized,
        "components": {
            "milvus": collection is not None,
            "openai": openai_client is not None,
            "google_tts": google_tts is not None,
            "embeddings": embedder is not None,
            "embedding_type": embedding_type
        },
        "version": "1.0.0"
    }
    return status

def main(event, context):
    """Main handler for AWS Lambda"""
    # Always start HTTP server before attempting connections
    # This follows our resilient application startup pattern
    
    # Initialize on first invocation
    if not is_initialized:
        init()
    
    # Handle health check (always respond even if not fully initialized)
    if event.get('path') == '/health' and event.get('httpMethod') == 'GET':
        return {
            'statusCode': 200,
            'body': json.dumps(health_check())
        }
    
    # Process actual requests
    try:
        body = json.loads(event.get('body', '{}'))
        
        # Content Upload
        if 's3_upload' in body:
            if process_pdf(os.getenv('BUCKET_NAME'), body['s3_upload']):
                return {'statusCode': 200, 'body': json.dumps({'message': 'Content processed'})}
            else:
                return {'statusCode': 500, 'body': json.dumps({'error': 'Failed to process content'})}
        
        # STT
        if 'audio' in body:
            text = speech_to_text(body['audio'])
            if text:
                return {'statusCode': 200, 'body': json.dumps({'text': text})}
            else:
                return {'statusCode': 500, 'body': json.dumps({'error': 'Speech-to-text failed'})}
        
        # Chat or TTS
        if 'query' in body:
            if not collection or not embedder:
                return {'statusCode': 503, 'body': json.dumps({
                    'error': 'Service not fully initialized', 
                    'details': 'Vector search capabilities unavailable'
                })}
                
            try:
                query_embedding = embedder.embed_query(body['query'])
                results = collection.search([query_embedding], 'embeddings', {"metric_type": "L2"}, limit=5)
                context_docs = [hit.entity.get('text') for hit in results[0]]
                
                prompt = f"Based only on this context:\n{''.join(context_docs)}\nGenerate a 50-word pitch if asked to present capabilities, else answer: {body['query']}"
                response = openai_client.chat.completions.create(model='gpt-4o', messages=[{'role': 'user', 'content': prompt}], max_tokens=100)
                text = response.choices[0].message.content
                
                if body.get('to_speech'):
                    audio = text_to_speech(text)
                    if audio:
                        return {'statusCode': 200, 'body': json.dumps({'text': text, 'audio': audio})}
                    else:
                        return {'statusCode': 200, 'body': json.dumps({'text': text, 'error': 'Text-to-speech failed'})}
                        
                return {'statusCode': 200, 'body': json.dumps({'text': text})}
            except Exception as e:
                return {'statusCode': 500, 'body': json.dumps({'error': f'Query processing error: {str(e)}'})}
            
        return {'statusCode': 400, 'body': json.dumps({'error': 'Invalid request'})}
    except Exception as e:
        print(f"Error processing request: {str(e)}")
        return {'statusCode': 500, 'body': json.dumps({'error': f'Internal error: {str(e)}'})}

# For local development
class LocalServer(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/health':
            self.send_response(200)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps(health_check()).encode())
        else:
            self.send_response(404)
            self.end_headers()
    
    def do_POST(self):
        content_length = int(self.headers['Content-Length'])
        post_data = self.rfile.read(content_length)
        event = {
            'path': self.path,
            'httpMethod': 'POST',
            'body': post_data.decode('utf-8')
        }
        
        result = main(event, None)
        
        self.send_response(result['statusCode'])
        self.send_header('Content-type', 'application/json')
        self.end_headers()
        self.wfile.write(result['body'].encode())

def run_local_server():
    """Start local server with port fallback mechanism"""
    default_port = int(os.getenv('PORT', 8000))
    max_port = default_port + 10  # Try up to 10 ports
    
    # Try ports in sequence until we find one that works
    for port in range(default_port, max_port):
        try:
            server = socketserver.TCPServer(("", port), LocalServer)
            print(f"Starting local server on port {port}")
            
            # Register server for graceful shutdown
            def server_shutdown():
                server.shutdown()
                server.server_close()
                print("Server shut down gracefully")
            
            # Register additional shutdown hook
            original_sigterm_handler = signal.getsignal(signal.SIGTERM)
            def sigterm_handler(sig, frame):
                print("SIGTERM received, shutting down server...")
                server_shutdown()
                if original_sigterm_handler:
                    original_sigterm_handler(sig, frame)
            signal.signal(signal.SIGTERM, sigterm_handler)
            
            # Register additional SIGINT handler
            original_sigint_handler = signal.getsignal(signal.SIGINT)
            def sigint_handler(sig, frame):
                print("SIGINT received, shutting down server...")
                server_shutdown()
                if original_sigint_handler:
                    original_sigint_handler(sig, frame)
            signal.signal(signal.SIGINT, sigint_handler)
            
            # Start server
            server.serve_forever()
            break
        except OSError as e:
            if e.errno == 48:  # Address already in use
                print(f"Port {port} is already in use, trying port {port+1}")
                if port == max_port - 1:
                    print(f"All ports from {default_port} to {max_port-1} are in use. Please free a port and try again.")
                    sys.exit(1)
            else:
                print(f"Error starting server: {e}")
                sys.exit(1)

def graceful_shutdown(sig, frame):
    """Global graceful shutdown handler"""
    print('Shutting down gracefully...')
    # Clean up connections
    try:
        connections.disconnect()
    except:
        pass
    sys.exit(0)

# Entry point for CLI
if __name__ == "__main__":
    # Set up signal handling for graceful shutdown
    signal.signal(signal.SIGINT, graceful_shutdown)
    signal.signal(signal.SIGTERM, graceful_shutdown)
    
    # Start HTTP server before initializing components
    # This ensures health checks can succeed even during initialization
    print("Starting local server before initialization")
    
    # Initialize in a separate thread to keep server responsive
    threading.Thread(target=init, daemon=True).start()
    
    # Start local server
    run_local_server()