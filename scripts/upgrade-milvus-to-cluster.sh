#!/bin/bash
# Script to upgrade Milvus from standalone to cluster mode with Pulsar

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Check if required environment variables are set
if [ -z "$AWS_REGION" ]; then
  echo -e "${YELLOW}AWS_REGION not set. Using default: eu-central-1${NC}"
  AWS_REGION="eu-central-1"
fi

if [ -z "$EKS_CLUSTER_NAME" ]; then
  echo -e "${RED}EKS_CLUSTER_NAME not set. Please export EKS_CLUSTER_NAME.${NC}"
  exit 1
fi

if [ -z "$EKS_NAMESPACE" ]; then
  echo -e "${YELLOW}EKS_NAMESPACE not set. Using default: milvus${NC}"
  EKS_NAMESPACE="milvus"
fi

if [ -z "$MILVUS_BUCKET_NAME" ]; then
  echo -e "${RED}MILVUS_BUCKET_NAME not set. Please export MILVUS_BUCKET_NAME for S3 storage.${NC}"
  exit 1
fi

# New backup bucket name
if [ -z "$MILVUS_BACKUP_BUCKET_NAME" ]; then
  MILVUS_BACKUP_BUCKET_NAME="${MILVUS_BUCKET_NAME}-backup"
  echo -e "${YELLOW}MILVUS_BACKUP_BUCKET_NAME not set. Using: $MILVUS_BACKUP_BUCKET_NAME${NC}"
fi

# Check for AWS credentials
if [ -z "$AWS_ACCESS_KEY_ID" ] || [ -z "$AWS_SECRET_ACCESS_KEY" ]; then
  echo -e "${RED}AWS credentials not set. Please export AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY.${NC}"
  exit 1
fi

# Check if AWS CLI is installed
if ! command -v aws &> /dev/null; then
  echo -e "${RED}AWS CLI is not installed. Please install it first.${NC}"
  exit 1
fi

# Check if kubectl is installed
if ! command -v kubectl &> /dev/null; then
  echo -e "${RED}kubectl is not installed. Please install it first.${NC}"
  exit 1
fi

# Check if helm is installed
if ! command -v helm &> /dev/null; then
  echo -e "${RED}helm is not installed. Please install it first.${NC}"
  exit 1
fi

# Function to check cluster resources
check_cluster_resources() {
  echo -e "${BLUE}=== Checking Cluster Resources ===${NC}"
  
  # Get node count
  NODE_COUNT=$(kubectl get nodes --no-headers | wc -l)
  if [ "$NODE_COUNT" -lt 5 ]; then
    echo -e "${YELLOW}⚠️ Warning: Found only $NODE_COUNT nodes. Recommended: at least 5 nodes for cluster mode.${NC}"
  else
    echo -e "${GREEN}✅ Node count: $NODE_COUNT (sufficient for cluster mode)${NC}"
  fi
  
  # Check node sizes
  echo -e "${GREEN}Node sizes:${NC}"
  kubectl get nodes -o custom-columns=NAME:.metadata.name,INSTANCE-TYPE:.metadata.labels.node\\.kubernetes\\.io/instance-type
  
  # Check available storage
  echo -e "${GREEN}Storage classes:${NC}"
  kubectl get storageclass
  
  # Check if gp2 storage class exists
  if ! kubectl get storageclass | grep -q gp2; then
    echo -e "${YELLOW}⚠️ Warning: gp2 storage class not found. This may cause issues with persistent volumes.${NC}"
  else
    echo -e "${GREEN}✅ gp2 storage class found${NC}"
  fi
  
  echo
}

# Function to create backup
create_backup() {
  echo -e "${BLUE}=== Creating Backup ===${NC}"
  
  # Create backup bucket if it doesn't exist
  echo -e "${GREEN}Creating/checking backup bucket: $MILVUS_BACKUP_BUCKET_NAME${NC}"
  if ! aws s3api head-bucket --bucket "$MILVUS_BACKUP_BUCKET_NAME" 2>/dev/null; then
    aws s3 mb "s3://$MILVUS_BACKUP_BUCKET_NAME" --region "$AWS_REGION"
    echo -e "${GREEN}Created backup bucket: $MILVUS_BACKUP_BUCKET_NAME${NC}"
  else
    echo -e "${GREEN}Backup bucket already exists: $MILVUS_BACKUP_BUCKET_NAME${NC}"
  fi
  
  # Generate timestamp for the backup
  TIMESTAMP=$(date +%Y%m%d%H%M%S)
  
  # Create the backup job manifest
  echo -e "${GREEN}Creating backup job manifest...${NC}"
  cat > milvus-backup-job.yaml << EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: milvus-backup-$TIMESTAMP
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
          pip install pymilvus boto3
          python -c '
          from pymilvus import connections, utility
          import json, os, subprocess, time
          import boto3
          
          # Wait for connection to be available
          max_retries = 10
          retry_interval = 5
          for i in range(max_retries):
              try:
                  connections.connect(host="milvus", port="19530")
                  print("Connected to Milvus")
                  break
              except Exception as e:
                  print(f"Connection attempt {i+1}/{max_retries} failed: {str(e)}")
                  if i < max_retries - 1:
                      print(f"Retrying in {retry_interval} seconds...")
                      time.sleep(retry_interval)
                  else:
                      print("Failed to connect to Milvus after multiple attempts")
                      exit(1)
          
          # Get all collections
          collections = utility.list_collections()
          print(f"Collections to backup: {collections}")
          
          # Create backup directory for metadata
          os.makedirs("/tmp/milvus-backup", exist_ok=True)
          
          # Connect to S3
          s3 = boto3.client("s3")
          
          # Export collections metadata
          for collection_name in collections:
              print(f"Backing up collection: {collection_name}")
              
              try:
                  # Get collection schema
                  collection = connections.get_connection().get_collection(collection_name)
                  schema = collection.schema
                  
                  # Convert schema to JSON-compatible format
                  schema_dict = {
                      "name": schema.name,
                      "description": schema.description,
                      "fields": []
                  }
                  
                  for field in schema.fields:
                      field_dict = {
                          "name": field.name,
                          "description": field.description,
                          "type": str(field.dtype),
                          "is_primary": field.is_primary,
                          "auto_id": field.auto_id
                      }
                      if hasattr(field, "params"):
                          field_dict["params"] = field.params
                      schema_dict["fields"].append(field_dict)
                  
                  # Save schema to file
                  schema_file = f"/tmp/milvus-backup/{collection_name}_schema.json"
                  with open(schema_file, "w") as f:
                      json.dump(schema_dict, f, indent=2)
                  
                  # Upload schema to S3
                  s3.upload_file(
                      schema_file,
                      "${MILVUS_BACKUP_BUCKET_NAME}",
                      f"backup-${TIMESTAMP}/{collection_name}/schema.json"
                  )
                  
                  print(f"Uploaded schema for {collection_name}")
                  
                  # Get index information
                  indexes = []
                  for field in schema.fields:
                      if collection.has_index(field.name):
                          index_info = collection.index(field.name)
                          indexes.append({
                              "field_name": field.name,
                              "index_type": index_info["index_type"],
                              "params": index_info["params"]
                          })
                  
                  # Save index info
                  if indexes:
                      index_file = f"/tmp/milvus-backup/{collection_name}_indexes.json"
                      with open(index_file, "w") as f:
                          json.dump(indexes, f, indent=2)
                      
                      # Upload index info to S3
                      s3.upload_file(
                          index_file,
                          "${MILVUS_BACKUP_BUCKET_NAME}",
                          f"backup-${TIMESTAMP}/{collection_name}/indexes.json"
                      )
                      
                      print(f"Uploaded index information for {collection_name}")
                  
              except Exception as e:
                  print(f"Error backing up {collection_name}: {str(e)}")
          
          print("Backup completed at: backup-${TIMESTAMP}/")
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
  
  # Apply the backup job
  echo -e "${GREEN}Creating backup job...${NC}"
  kubectl apply -f milvus-backup-job.yaml
  
  # Wait for job to complete
  echo -e "${GREEN}Waiting for backup job to complete...${NC}"
  kubectl wait --for=condition=complete --timeout=300s job/milvus-backup-$TIMESTAMP -n $EKS_NAMESPACE
  
  # Check job status
  if kubectl get job milvus-backup-$TIMESTAMP -n $EKS_NAMESPACE -o jsonpath='{.status.succeeded}' | grep -q 1; then
    echo -e "${GREEN}✅ Backup completed successfully${NC}"
    echo -e "${GREEN}Backup location: s3://$MILVUS_BACKUP_BUCKET_NAME/backup-$TIMESTAMP/${NC}"
    
    # Save backup info for restoration
    echo "MILVUS_BACKUP_PATH=backup-$TIMESTAMP" > milvus-backup-info.env
  else
    echo -e "${RED}❌ Backup failed. Check job logs:${NC}"
    kubectl logs job/milvus-backup-$TIMESTAMP -n $EKS_NAMESPACE
    
    echo -e "${YELLOW}Do you want to continue with the upgrade anyway? (y/N)${NC}"
    read -r continue_anyway
    
    if [[ ! "$continue_anyway" =~ ^[Yy]$ ]]; then
      echo -e "${RED}Upgrade aborted.${NC}"
      exit 1
    fi
  fi
  
  echo
}

# Function to upgrade to cluster mode
upgrade_to_cluster() {
  echo -e "${BLUE}=== Upgrading to Cluster Mode ===${NC}"
  
  # Update Helm repository
  echo -e "${GREEN}Updating Helm repository...${NC}"
  helm repo update
  
  # Get current values
  echo -e "${GREEN}Backing up current Helm values...${NC}"
  helm get values milvus -n $EKS_NAMESPACE -o yaml > milvus-values-backup.yaml
  
  # Upgrade Milvus to cluster mode
  echo -e "${GREEN}Upgrading Milvus to cluster mode with Pulsar...${NC}"
  
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
  
  echo -e "${GREEN}Upgrade command executed. Waiting for pods to start...${NC}"
  
  # Wait for pods to be ready (initial wait)
  echo -e "${GREEN}Initial wait for pods to start (2 minutes)...${NC}"
  sleep 120
  
  # Check pod status
  echo -e "${GREEN}Current pod status:${NC}"
  kubectl get pods -n $EKS_NAMESPACE
  
  # Wait for all pods to be ready
  echo -e "${GREEN}Waiting for all pods to be ready...${NC}"
  kubectl wait --for=condition=ready pod --all -n $EKS_NAMESPACE --timeout=600s || true
  
  # Check final pod status
  echo -e "${GREEN}Final pod status:${NC}"
  kubectl get pods -n $EKS_NAMESPACE
  
  echo
}

# Function to restore data
restore_data() {
  if [ ! -f milvus-backup-info.env ]; then
    echo -e "${YELLOW}No backup information found. Skipping restoration.${NC}"
    return
  fi
  
  # Source backup info
  source milvus-backup-info.env
  
  echo -e "${BLUE}=== Restoring Data from Backup ===${NC}"
  echo -e "${GREEN}Restore source: s3://$MILVUS_BACKUP_BUCKET_NAME/$MILVUS_BACKUP_PATH/${NC}"
  
  # Create restore job
  cat > milvus-restore-job.yaml << EOF
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
          import boto3, time, json
          from pymilvus import connections, utility, Collection, FieldSchema, CollectionSchema, DataType
          
          # Wait for Milvus to be ready
          print("Waiting for Milvus to be ready...")
          time.sleep(120)
          
          # Connect to Milvus with retries
          max_retries = 10
          retry_interval = 5
          for i in range(max_retries):
              try:
                  connections.connect(host="milvus", port="19530")
                  print("Connected to Milvus")
                  break
              except Exception as e:
                  print(f"Connection attempt {i+1}/{max_retries} failed: {str(e)}")
                  if i < max_retries - 1:
                      print(f"Retrying in {retry_interval} seconds...")
                      time.sleep(retry_interval)
                  else:
                      print("Failed to connect to Milvus after multiple attempts")
                      exit(1)
          
          # Create S3 client
          s3 = boto3.client("s3")
          
          # List all collections in the backup
          try:
              response = s3.list_objects_v2(
                  Bucket="${MILVUS_BACKUP_BUCKET_NAME}",
                  Prefix="${MILVUS_BACKUP_PATH}/"
              )
              
              # Get unique collection names from backup
              if "Contents" not in response:
                  print("No backup content found")
                  exit(0)
                  
              # Extract collection names from paths
              collection_paths = {}
              for obj in response.get("Contents", []):
                  path_parts = obj["Key"].split("/")
                  if len(path_parts) >= 3:  # backup-path/collection/file
                      collection_name = path_parts[1]
                      if collection_name not in collection_paths:
                          collection_paths[collection_name] = []
                      collection_paths[collection_name].append(obj["Key"])
              
              # Process each collection
              for collection_name, paths in collection_paths.items():
                  print(f"Processing collection: {collection_name}")
                  
                  # Find schema file
                  schema_file = None
                  for path in paths:
                      if path.endswith("/schema.json"):
                          schema_file = path
                          break
                  
                  if not schema_file:
                      print(f"Schema file not found for {collection_name}, skipping")
                      continue
                  
                  # Download schema file
                  s3.download_file(
                      "${MILVUS_BACKUP_BUCKET_NAME}",
                      schema_file,
                      "/tmp/schema.json"
                  )
                  
                  # Parse schema file
                  with open("/tmp/schema.json", "r") as f:
                      schema_data = json.load(f)
                  
                  # Convert schema dictionary to Milvus schema objects
                  field_schemas = []
                  for field in schema_data["fields"]:
                      # Map string type to proper DataType enum
                      dtype_map = {
                          "DataType.INT64": DataType.INT64,
                          "DataType.FLOAT": DataType.FLOAT,
                          "DataType.FLOAT_VECTOR": DataType.FLOAT_VECTOR,
                          "DataType.BINARY_VECTOR": DataType.BINARY_VECTOR,
                          "DataType.VARCHAR": DataType.VARCHAR,
                          # Add other data types as needed
                      }
                      
                      for dtype_str, dtype_enum in dtype_map.items():
                          if dtype_str in field["type"]:
                              field_type = dtype_enum
                              break
                      else:
                          print(f"Unknown data type: {field['type']}")
                          continue
                      
                      # Create field schema
                      field_kwargs = {
                          "name": field["name"],
                          "dtype": field_type,
                          "is_primary": field.get("is_primary", False),
                          "description": field.get("description", ""),
                          "auto_id": field.get("auto_id", False)
                      }
                      
                      # Handle vector field parameters
                      if field_type in [DataType.FLOAT_VECTOR, DataType.BINARY_VECTOR] and "params" in field:
                          field_kwargs["dim"] = field["params"].get("dim", 128)
                      
                      # Create field schema object
                      field_schemas.append(FieldSchema(**field_kwargs))
                  
                  # Create collection schema
                  collection_schema = CollectionSchema(
                      fields=field_schemas,
                      description=schema_data.get("description", "")
                  )
                  
                  # Check if collection exists and drop it if needed
                  if utility.has_collection(collection_name):
                      print(f"Collection {collection_name} already exists, dropping it")
                      utility.drop_collection(collection_name)
                  
                  # Create collection
                  print(f"Creating collection {collection_name}")
                  collection = Collection(
                      name=collection_name,
                      schema=collection_schema
                  )
                  
                  # Find index file
                  index_file = None
                  for path in paths:
                      if path.endswith("/indexes.json"):
                          index_file = path
                          break
                  
                  # Create indexes if available
                  if index_file:
                      # Download index file
                      s3.download_file(
                          "${MILVUS_BACKUP_BUCKET_NAME}",
                          index_file,
                          "/tmp/indexes.json"
                      )
                      
                      # Parse index file
                      with open("/tmp/indexes.json", "r") as f:
                          indexes = json.load(f)
                      
                      # Create indexes
                      for index in indexes:
                          field_name = index["field_name"]
                          index_type = index["index_type"]
                          index_params = index["params"]
                          
                          print(f"Creating index on {field_name} with type {index_type}")
                          collection.create_index(
                              field_name=field_name,
                              index_type=index_type,
                              params=index_params
                          )
                  
                  print(f"Collection {collection_name} restored successfully")
              
              print("Restore completed")
          
          except Exception as e:
              print(f"Error during restoration: {str(e)}")
              import traceback
              traceback.print_exc()
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
  
  # Apply the restore job
  echo -e "${GREEN}Creating restore job...${NC}"
  kubectl apply -f milvus-restore-job.yaml
  
  # Wait for job to start
  echo -e "${GREEN}Waiting for restore job to start...${NC}"
  sleep 10
  
  # Follow logs
  echo -e "${GREEN}Restore job logs:${NC}"
  kubectl logs -f job/milvus-restore -n $EKS_NAMESPACE || true
  
  # Check job status
  if kubectl get job milvus-restore -n $EKS_NAMESPACE -o jsonpath='{.status.succeeded}' | grep -q 1; then
    echo -e "${GREEN}✅ Restoration completed successfully${NC}"
  else
    echo -e "${YELLOW}⚠️ Restoration may not have completed successfully. Check job logs for details.${NC}"
  fi
  
  echo
}

# Function to verify the deployment
verify_deployment() {
  echo -e "${BLUE}=== Verifying Cluster Deployment ===${NC}"
  
  # Check all pods
  echo -e "${GREEN}Pod status:${NC}"
  kubectl get pods -n $EKS_NAMESPACE
  
  # Check services
  echo -e "${GREEN}Service status:${NC}"
  kubectl get svc -n $EKS_NAMESPACE
  
  # Check persistent volumes
  echo -e "${GREEN}Persistent volume claims:${NC}"
  kubectl get pvc -n $EKS_NAMESPACE
  
  # Get the LoadBalancer address
  LB_DNS_NAME=$(kubectl get svc -n $EKS_NAMESPACE milvus -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
  if [ -n "$LB_DNS_NAME" ]; then
    echo -e "${GREEN}Milvus is accessible at: $LB_DNS_NAME:19530${NC}"
  else
    echo -e "${YELLOW}⚠️ LoadBalancer address not found${NC}"
  fi
  
  echo
}

# Main script flow
echo -e "${BLUE}=======================================================${NC}"
echo -e "${BLUE}  Milvus Upgrade: Standalone to Cluster Mode with Pulsar${NC}"
echo -e "${BLUE}=======================================================${NC}"
echo

check_cluster_resources

echo -e "${YELLOW}This script will upgrade your Milvus deployment from standalone to cluster mode.${NC}"
echo -e "${YELLOW}This process will:${NC}"
echo -e "${YELLOW}1. Back up your existing collections to S3${NC}"
echo -e "${YELLOW}2. Upgrade Milvus to cluster mode with Pulsar${NC}"
echo -e "${YELLOW}3. Restore your collections from backup${NC}"
echo
echo -e "${YELLOW}Do you want to continue? (y/N)${NC}"
read -r proceed

if [[ ! "$proceed" =~ ^[Yy]$ ]]; then
  echo -e "${RED}Upgrade aborted.${NC}"
  exit 0
fi

# Execute the upgrade process
create_backup
upgrade_to_cluster
restore_data
verify_deployment

echo -e "${BLUE}=======================================================${NC}"
echo -e "${GREEN}Milvus has been upgraded to cluster mode with Pulsar!${NC}"
echo -e "${BLUE}=======================================================${NC}"
echo
echo -e "${GREEN}Next steps:${NC}"
echo -e "1. Verify that your collections have been restored properly"
echo -e "2. Update your application connection settings if necessary"
echo -e "3. Update your DNS configuration with ./scripts/configure-milvus-dns.sh"
echo -e "4. Consider creating a monitoring dashboard for your cluster"
echo
echo -e "${YELLOW}Note: If you need to roll back, you can reinstall Milvus in standalone mode${NC}"
echo -e "${YELLOW}and restore from the backup at: s3://$MILVUS_BACKUP_BUCKET_NAME/$MILVUS_BACKUP_PATH/${NC}"
