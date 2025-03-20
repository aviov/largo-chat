FROM amazon/aws-cli:latest

# Install curl
RUN yum install -y curl unzip

# Install kubectl
RUN curl -LO https://storage.googleapis.com/kubernetes-release/release/v1.24.0/bin/linux/amd64/kubectl && \
    chmod +x ./kubectl && \
    mv ./kubectl /usr/local/bin/kubectl

# Install helm
RUN curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 && \
    chmod +x get_helm.sh && \
    ./get_helm.sh

# Layer setup
RUN mkdir -p /opt/kubectl/bin
RUN cp /usr/local/bin/kubectl /opt/kubectl/bin/
RUN cp /usr/local/bin/helm /opt/kubectl/bin/
