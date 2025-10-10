# Simplified Semaphore Runner Image - PowerShell + Azure CLI only
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

USER root

# Copy and install CA certificate BEFORE any network operations
COPY config/certs/ProxyCA.crt /usr/local/share/ca-certificates/
RUN apt-get update && apt-get install -y ca-certificates && \
    update-ca-certificates

# Install minimal required packages (removed Ansible/Python build tools)
RUN apt update && apt install -y \
    python3 \
    bash \
    ca-certificates \
    tar \
    curl \
    apt-transport-https \
    lsb-release \
    gnupg \
    git \
    jq \
    openssh-client \
    --no-install-recommends && \
    rm -rf /var/lib/apt/lists/*

# Install Semaphore
ARG SEMAPHORE_VERSION=2.14.10
RUN curl -L https://github.com/ansible-semaphore/semaphore/releases/download/v${SEMAPHORE_VERSION}/semaphore_${SEMAPHORE_VERSION}_linux_amd64.deb -o /tmp/semaphore.deb && \
    apt install -y /tmp/semaphore.deb && \
    rm /tmp/semaphore.deb

# Install Azure CLI
RUN curl -sL https://packages.microsoft.com/keys/microsoft.asc | \
    gpg --dearmor | \
    tee /etc/apt/trusted.gpg.d/microsoft.gpg > /dev/null && \
    echo "deb [arch=amd64 signed-by=/etc/apt/trusted.gpg.d/microsoft.gpg] \
    https://packages.microsoft.com/repos/azure-cli/ $(lsb_release -cs) main" | \
    tee /etc/apt/sources.list.d/azure-cli.list

# Install AzCopy
RUN curl -sL https://aka.ms/downloadazcopy-v10-linux | tar -xz -C /tmp
RUN cp /tmp/azcopy_linux_amd64_*/azcopy /usr/local/bin/ && \
    chmod +x /usr/local/bin/azcopy && \
    rm -rf /tmp/azcopy_linux_amd64_*

# Update package lists and install Azure CLI
RUN apt-get update && apt-get install -y azure-cli

# Install Azure CLI extensions as root first
RUN az extension add --name resource-graph --yes --system

# Install PowerShell
RUN curl -sL -o packages-microsoft-prod.deb https://packages.microsoft.com/config/ubuntu/22.04/packages-microsoft-prod.deb && \
    dpkg -i packages-microsoft-prod.deb && \
    apt-get update && \
    apt-get install -y powershell && \
    rm packages-microsoft-prod.deb && \
    ln -sf /usr/bin/pwsh /usr/bin/powershell

# Install kubectl
RUN curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.31/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg && \
    echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.31/deb/ /' | tee /etc/apt/sources.list.d/kubernetes.list && \
    apt-get update && \
    apt-get install -y kubectl && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Install kubelogin for Azure AD authentication
RUN curl -fsSL https://github.com/Azure/kubelogin/releases/latest/download/kubelogin-linux-amd64.zip -o /tmp/kubelogin.zip && \
    apt-get update && apt-get install -y unzip && \
    unzip /tmp/kubelogin.zip -d /tmp && \
    mv /tmp/bin/linux_amd64/kubelogin /usr/local/bin/ && \
    chmod +x /usr/local/bin/kubelogin && \
    rm -rf /tmp/kubelogin.zip /tmp/bin

# Install sqlcmd
RUN curl https://packages.microsoft.com/config/ubuntu/22.04/prod.list > /etc/apt/sources.list.d/mssql-release.list && \
    apt-get update && \
    ACCEPT_EULA=Y apt-get install -y msodbcsql18 unixodbc-dev mssql-tools18 && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Create the semaphore user and relevant directories
RUN useradd -m -s /bin/bash semaphore || true
RUN mkdir -p /var/lib/semaphore /etc/semaphore /opt/semaphore
RUN chown -R semaphore:semaphore /var/lib/semaphore /etc/semaphore /opt/semaphore

RUN mkdir -p /home/semaphore/.azure && chown -R semaphore:semaphore /home/semaphore/.azure
RUN mkdir -p /scripts && chown -R semaphore:semaphore /scripts
RUN mkdir -p /config && chown -R semaphore:semaphore /config

# Copy scripts and configuration files into the image
COPY --chown=semaphore:semaphore ./scripts /scripts
COPY --chown=semaphore:semaphore ./config /config
COPY config.json /etc/semaphore/config.json

# Install PowerShell modules as root before switching to semaphore user
RUN pwsh -Command "Install-Module -Name SqlServer -Scope AllUsers -Force -AllowClobber"

# Copy Azure CLI extensions to a persistent location that won't be overridden by volume mounts
RUN mkdir -p /opt/azure-cli-extensions && \
    cp -r /root/.azure/cliextensions/* /opt/azure-cli-extensions/ 2>/dev/null || true && \
    chmod -R 755 /opt/azure-cli-extensions

# Install extensions for the semaphore user as well
RUN su - semaphore -c "az extension add --name resource-graph --yes" || true

# Install timezone data (before switching to semaphore user)
RUN apt-get update && \
    apt-get install -y --no-install-recommends tzdata && \
    rm -rf /var/lib/apt/lists/*

USER semaphore

# Environment configuration
ENV PATH="/opt/mssql-tools18/bin:$PATH"
ENV AZURE_EXTENSION_DIR="/opt/azure-cli-extensions"
RUN echo 'export PATH="/opt/mssql-tools18/bin:$PATH"' >> /home/semaphore/.bashrc
RUN echo 'export AZURE_EXTENSION_DIR="/opt/azure-cli-extensions"' >> /home/semaphore/.bashrc
    
# Verify binary installations and extensions
RUN az version
RUN az extension list
RUN az graph query -q "Resources | limit 1" --output none || echo "Graph extension working but no Azure context"
RUN azcopy --version
RUN kubectl version --client
RUN kubelogin --version

EXPOSE 3000

CMD ["semaphore", "server", "--config", "/etc/semaphore/config.json"]

# Note: Azure authentication setup will be done at runtime:
# Connect-AzAccount -Environment AzureUSGovernment
# Enable-AzContextAutoSave -Scope CurrentUser
