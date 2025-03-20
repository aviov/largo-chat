#!/usr/bin/env python3
import sys
import time
from pymilvus import connections, utility

# Set your Milvus endpoint
MILVUS_HOST = "k8s-milvus-milvus-6d3070a14d-31edb78254d7939f.elb.eu-central-1.amazonaws.com"
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
        
        # Try to list collections using the correct API
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
