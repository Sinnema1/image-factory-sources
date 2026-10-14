# Use UBI 10 (RHEL 10-based) as the base image
FROM registry.access.redhat.com/ubi10/ubi-minimal:latest

# Install HashiCorp Packer.
# The repository declares the vSphere plugin, which packer init installs.
ARG PACKER_VERSION=1.16.0
ARG YQ_VERSION=v4.45.1
ARG TARGETARCH=amd64
ARG GOVC_VERSION=v0.56.0

# Install minimal dependencies (curl and unzip)
RUN microdnf update -y && \
    microdnf install -y \
        ca-certificates \
        curl \
        git \
        make \
        jq \
        unzip \
        tar && \
    microdnf clean all

RUN curl -fsSLo /tmp/packer.zip \
"https://releases.hashicorp.com/packer/${PACKER_VERSION}/packer_${PACKER_VERSION}_linux_${TARGETARCH}.zip" && \
    unzip /tmp/packer.zip -d /usr/local/bin && \
    rm -f /tmp/packer.zip && \
    packer version

RUN curl -fsSLo /usr/local/bin/yq \
    "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${TARGETARCH}" \
    && chmod 0755 /usr/local/bin/yq \
    && /usr/local/bin/yq --version

RUN curl -fsSLo /tmp/govc.tar.gz \
    "https://github.com/vmware/govmomi/releases/download/${GOVC_VERSION}/govc_Linux_x86_64.tar.gz" \
    && tar -C /usr/local/bin -xzf /tmp/govc.tar.gz govc \
    && chmod 0755 /usr/local/bin/govc \
    && /usr/local/bin/govc version    

COPY scripts/download-packages.sh /usr/local/bin/download-packages
RUN chmod 0755 /usr/local/bin/download-packages   

# Set working directory
WORKDIR /app

# Default command (override in CI)
CMD ["/bin/bash"]