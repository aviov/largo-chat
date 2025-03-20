#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
cd ${SCRIPT_DIR}

# Build the Docker image
docker build -t kubectl-layer .

# Create a container and extract the layer content
CONTAINER_ID=$(docker create kubectl-layer)
rm -rf layer && mkdir -p layer
docker cp ${CONTAINER_ID}:/opt/kubectl layer/
docker rm ${CONTAINER_ID}

echo "Layer files have been extracted to ${SCRIPT_DIR}/layer"
