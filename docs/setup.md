# Setup Guide

## Prerequisites

- Semaphore CI/CD instance
- PowerShell Core 7.x
- Azure CLI
- Access to Azure US Government cloud

## 1. Semaphore Configuration

### Variable Groups
Create a Variable Group named "Azure-Credentials" with:

**For Service Principal (Recommended):**
- `AZURE_CLIENT_ID`: Your service principal client ID
- `AZURE_CLIENT_SECRET`: Your service principal secret
- `AZURE_TENANT_ID`: Your Azure tenant ID
- `AZURE_SUBSCRIPTION_ID`: Default subscription ID (optional)

**For Username/Password:**
- `AZURE_USERNAME`: Your Azure username
- `AZURE_PASSWORD`: Your Azure password  
- `AZURE_TENANT_ID`: Your tenant ID (optional)

### Template Import
1. Go to Semaphore → Templates
2. Import templates from `.semaphore/templates/`
3. Assign Variable Groups to your project

## 2. Docker Configuration

Update your Dockerfile to include PowerShell and Azure CLI:

```dockerfile
# Install PowerShell
RUN curl -sL -o packages-microsoft-prod.deb https://packages.microsoft.com/config/ubuntu/22.04/packages-microsoft-prod.deb && \
    dpkg -i packages-microsoft-prod.deb && \
    apt-get update && \
    apt-get install -y powershell && \
    rm packages-microsoft-prod.deb && \
    ln -sf /usr/bin/pwsh /usr/bin/powershell

# Install Azure CLI  
RUN curl -sL https://packages.microsoft.com/keys/microsoft.asc | \
    gpg --dearmor | \
    tee /etc/apt/trusted.gpg.d/microsoft.gpg > /dev/null && \
    echo "deb [arch=amd64 signed-by=/etc/apt/trusted.gpg.d/microsoft.gpg] \
    https://packages.microsoft.com/repos/azure-cli/ $(lsb_release -cs) main" | \
    tee /etc/apt/sources.list.d/azure-cli.list && \
    apt-get update && apt-get install -y azure-cli
```

## 3. Volume Mounts

Mount the scripts directory in your docker-compose.yml:

```yaml
volumes:
  - ./scripts:/scripts:ro
  - ./config:/config:ro
```

## 4. Testing

Test the setup:

```bash
# Test authentication
pwsh scripts/common/Connect-Azure.ps1

# Test main script
pwsh scripts/main/self_service.ps1 -DryRun -AutoApprove
```

## 5. Environment Configuration

Update `config/environments.json` with your specific:
- Subscription IDs
- Resource groups  
- Server names
- Cluster names
- Locations

## Troubleshooting

### Authentication Issues
- Verify Variable Groups are assigned to project
- Check Azure CLI version
- Test with direct `az login`

### Path Issues  
- Ensure scripts directory is mounted correctly
- Check file permissions in container
- Verify PowerShell execution policy

### Script Errors
- Check logs in `/tmp/self_service_*.log`
- Run with `-DryRun` first
- Verify Azure permissions
