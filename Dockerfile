# Stage 1: Build Ansible Environment in a Virtual Environment
FROM ubuntu:22.04 AS ansible_builder

ENV DEBIAN_FRONTEND=noninteractive

USER root

RUN apt update && apt install -y \
    python3 \
    python3-pip \
    python3-venv \
    build-essential \
    libffi-dev \
    libssl-dev \
    cargo \
    git \
    --no-install-recommends && \
    rm -rf /var/lib/apt/lists/*

RUN python3 -m venv /opt/ansible_venv
ENV PATH="/opt/ansible_venv/bin:${PATH}"

# Install Ansible and required Azure SDK dependencies
RUN pip3 install --no-cache-dir ansible

COPY ./azure-requirements.txt /tmp/azure-requirements.txt
RUN pip3 install --no-cache-dir -r /tmp/azure-requirements.txt
RUN pip3 install --no-cache-dir azure-cli

# Clean existing collection versions and install only v3.3.1
RUN rm -rf ~/.ansible/collections/ansible_collections/azure/azcollection && \
    ansible-galaxy collection install azure.azcollection:3.3.1 -p ~/.ansible/collections
RUN rm -rf /opt/ansible_venv/lib/python3.10/site-packages/ansible_collections/azure/azcollection
RUN ansible-galaxy collection install azure.azcollection:3.3.1 -p ~/.ansible/collections

# Stage 2: Final Semaphore Runner Image
FROM ubuntu:22.04 AS semaphore_runner

ENV DEBIAN_FRONTEND=noninteractive

USER root

RUN apt update && apt install -y \
    python3 \
    python3-pip \
    bash \
    ca-certificates \
    tar \
    curl \
    apt-transport-https \
    lsb-release \
    gnupg \
    software-properties-common \
    git \
    jq \
    openssh-client \
    --no-install-recommends && \
    rm -rf /var/lib/apt/lists/*

ARG SEMAPHORE_VERSION=2.14.10
RUN curl -L https://github.com/ansible-semaphore/semaphore/releases/download/v${SEMAPHORE_VERSION}/semaphore_${SEMAPHORE_VERSION}_linux_amd64.deb -o /tmp/semaphore.deb && \
    apt install -y /tmp/semaphore.deb && \
    rm /tmp/semaphore.deb

RUN curl -sL https://packages.microsoft.com/keys/microsoft.asc | \
    gpg --dearmor | \
    tee /etc/apt/trusted.gpg.d/microsoft.gpg > /dev/null && \
    echo "deb [arch=amd64 signed-by=/etc/apt/trusted.gpg.d/microsoft.gpg] \
    https://packages.microsoft.com/repos/azure-cli/ $(lsb_release -cs) main" | \
    tee /etc/apt/sources.list.d/azure-cli.list

RUN curl -sL https://aka.ms/downloadazcopy-v10-linux | tar -xz -C /tmp

# Update package lists and install Azure CLI and AzCopy
RUN apt-get update && apt-get install -y azure-cli
# Move AzCopy to /usr/local/bin and set permissions
RUN cp /tmp/azcopy_linux_amd64_*/azcopy /usr/local/bin/ && \
    chmod +x /usr/local/bin/azcopy && \
    rm -rf /tmp/azcopy_linux_amd64_*

# # Install Terraform
# RUN curl -fsSL https://apt.releases.hashicorp.com/gpg \
#     | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg && \
#     echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
#     > /etc/apt/sources.list.d/hashicorp.list
# RUN apt-get update && apt-get install -y terraform

# # Install Terragrunt
# ARG TERRAGRUNT_VERSION=0.79.0
# RUN curl -L -o /usr/local/bin/terragrunt https://github.com/gruntwork-io/terragrunt/releases/download/v${TERRAGRUNT_VERSION}/terragrunt_linux_amd64 && \
#     chmod +x /usr/local/bin/terragrunt

# Install Powershell
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

# Install sqlcmd
RUN curl https://packages.microsoft.com/config/ubuntu/22.04/prod.list > /etc/apt/sources.list.d/mssql-release.list && \
    apt-get update && \
    ACCEPT_EULA=Y apt-get install -y msodbcsql18 unixodbc-dev mssql-tools18 && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Copy virtual environment from builder
COPY --from=ansible_builder /opt/ansible_venv /opt/ansible_venv

# Create system-wide collections path and copy only the required collection
RUN mkdir -p /usr/share/ansible/collections
COPY --from=ansible_builder /root/.ansible/collections /usr/share/ansible/collections
RUN chmod -R a+rX /usr/share/ansible/collections

# Create the semaphore user and relevant directories
RUN useradd -m -s /bin/bash semaphore || true
RUN mkdir -p /var/lib/semaphore /etc/semaphore /opt/semaphore
RUN chown -R semaphore:semaphore /var/lib/semaphore /etc/semaphore /opt/semaphore

RUN mkdir -p /ansible && chown -R semaphore:semaphore /ansible
RUN mkdir -p /home/semaphore/.azure && chown -R semaphore:semaphore /home/semaphore/.azure
RUN mkdir -p /scripts && chown -R semaphore:semaphore /scripts
RUN mkdir -p /config && chown -R semaphore:semaphore /config

# Copy scripts and configuration files into the image
COPY --chown=semaphore:semaphore ./scripts /scripts
COPY --chown=semaphore:semaphore ./config /config
COPY --chown=semaphore:semaphore ./ansible-for-semaphore /ansible
COPY config.json /etc/semaphore/config.json

RUN rm -rf /root/.ansible \
    /home/semaphore/.ansible \
    /tmp/.ansible \
    /etc/ansible/collections || true

ENV PATH="/opt/ansible_venv/bin:/opt/mssql-tools18/bin:$PATH"

# Install PowerShell modules as root before switching to semaphore user
RUN pwsh -Command "Install-Module -Name SqlServer -Scope AllUsers -Force -AllowClobber"
RUN pwsh -Command "Install-Module -Name Az.Account -Scope AllUsers -Force -AllowClobber"
RUN pwsh -Command "Install-Module -Name Az.Resources -Scope AllUsers -Force -AllowClobber"
RUN pwsh -Command "Install-Module -Name Az.Sql -Scope AllUsers -Force -AllowClobber"

USER semaphore
RUN rm -rf ~/.ansible

# Environment configuration
ENV PATH="/opt/ansible_venv/bin:/opt/mssql-tools18/bin:$PATH"
RUN echo 'export PATH="/opt/ansible_venv/bin:/opt/mssql-tools18/bin:$PATH"' >> /home/semaphore/.bashrc

ENV ANSIBLE_PYTHON_INTERPRETER=/opt/ansible_venv/bin/python3
ENV ANSIBLE_COLLECTIONS_PATHS=/usr/share/ansible/collections

# Verify binary installations
RUN az version
RUN azcopy --version
RUN terraform --version && terragrunt --version
RUN kubectl version --client
# RUN sqlcmd -?  # ?? This doesn't work but is visible in container...

EXPOSE 3000

CMD ["semaphore", "server", "--config", "/etc/semaphore/config.json"]

# Note: Azure authentication setup will be done at runtime:
# Connect-AzAccount -Environment AzureUSGovernment
# Enable-AzContextAutoSave -Scope CurrentUser
