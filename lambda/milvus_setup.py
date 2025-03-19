from pymilvus import connections, Collection, FieldSchema, CollectionSchema, DataType, utility
import os
import time
import pathlib
from dotenv import load_dotenv

# Load environment variables
env_path = pathlib.Path(__file__).parent / '.env'
if env_path.exists():
    print(f"Loading environment from {env_path}")
    load_dotenv(dotenv_path=env_path)

def create_milvus_collection(host='localhost', port='19530', collection_name='docs'):
    """Create Milvus collection with retry logic"""
    max_retries = 5
    retry_delay = 3  # seconds
    
    for attempt in range(max_retries):
        try:
            # Connect to Milvus
            print(f"Connecting to Milvus at {host}:{port} (attempt {attempt+1}/{max_retries})")
            connections.connect(host=host, port=port)
            
            # Check if collection exists
            if utility.has_collection(collection_name):
                print(f"Collection '{collection_name}' already exists")
                collection = Collection(collection_name)
                return collection
            
            # Define schema
            fields = [
                FieldSchema(name='id', dtype=DataType.INT64, is_primary=True, auto_id=True),
                FieldSchema(name='embeddings', dtype=DataType.FLOAT_VECTOR, dim=768),  # bge-base-en dim
                FieldSchema(name='text', dtype=DataType.VARCHAR, max_length=65535),
                FieldSchema(name='doc_key', dtype=DataType.VARCHAR, max_length=255),
            ]
            schema = CollectionSchema(fields=fields, description='Chatbot documents')
            
            # Create collection
            print(f"Creating collection '{collection_name}'")
            collection = Collection(collection_name, schema)
            
            # Create index
            print("Creating vector index (this may take a while for large collections)")
            collection.create_index('embeddings', {
                "index_type": "HNSW", 
                "metric_type": "L2", 
                "params": {"M": 16, "efConstruction": 200}
            })
            
            print(f"Collection '{collection_name}' created and indexed successfully")
            return collection
            
        except Exception as e:
            print(f"Milvus setup error (attempt {attempt+1}/{max_retries}): {str(e)}")
            if attempt < max_retries - 1:
                print(f"Retrying in {retry_delay} seconds...")
                time.sleep(retry_delay)
            else:
                print("Max retries reached. Milvus setup failed.")
                raise

if __name__ == "__main__":
    # Get connection details from environment
    host = os.getenv('MILVUS_HOST', 'localhost')
    port = os.getenv('MILVUS_PORT', '19530')
    
    try:
        create_milvus_collection(host, port)
        print("Milvus setup completed successfully")
    except Exception as e:
        print(f"Milvus setup failed: {str(e)}")