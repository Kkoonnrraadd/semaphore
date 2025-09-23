param(
    [string]$Cloud = "AzureUSGovernment"
)

Write-Host "🔐 Setting up Azure authentication..." -ForegroundColor Cyan
Write-Host "🌐 Using cloud: $Cloud" -ForegroundColor Gray

# Set Azure CLI to use the correct cloud
Write-Host "⚙️ Configuring Azure CLI for $Cloud..." -ForegroundColor Yellow
az cloud set --name $Cloud 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "⚠️ Warning: Could not set cloud to $Cloud, using default" -ForegroundColor Yellow
}

# Check if already authenticated
try {
    $context = az account show 2>$null | ConvertFrom-Json
    if ($context) {
        Write-Host "✅ Already authenticated to Azure" -ForegroundColor Green
        Write-Host "   Subscription: $($context.name) ($($context.id))" -ForegroundColor Gray
        return $true
    }
} catch {
    # Not authenticated, continue with login
}

# Try Service Principal authentication first
if ($env:AZURE_CLIENT_ID -and $env:AZURE_CLIENT_SECRET -and $env:AZURE_TENANT_ID) {
    Write-Host "🔑 Using Service Principal authentication..." -ForegroundColor Yellow
    
    try {
        $result = az login --service-principal --username $env:AZURE_CLIENT_ID --password $env:AZURE_CLIENT_SECRET --tenant $env:AZURE_TENANT_ID --output json 2>&1
            
        if ($LASTEXITCODE -eq 0) {
            Write-Host "✅ Service Principal authentication successful" -ForegroundColor Green
            
            # Set default subscription if provided
            if ($env:AZURE_SUBSCRIPTION_ID) {
                az account set --subscription $env:AZURE_SUBSCRIPTION_ID
                Write-Host "📋 Set default subscription: $env:AZURE_SUBSCRIPTION_ID" -ForegroundColor Green
            }
            
            return $true
        } else {
            Write-Host "❌ Service Principal authentication failed: $result" -ForegroundColor Red
        }
    } catch {
        Write-Host "❌ Service Principal authentication error: $($_.Exception.Message)" -ForegroundColor Red
    }
} else {
    Write-Host "⚠️ Service Principal credentials not found in environment variables" -ForegroundColor Yellow
}

# No authentication method available
Write-Host "❌ No Azure credentials found in environment variables" -ForegroundColor Red
Write-Host "   Please set up Azure credentials in Semaphore Key Store:" -ForegroundColor Yellow
Write-Host "   - Service Principal: AZURE_CLIENT_ID, AZURE_CLIENT_SECRET, AZURE_TENANT_ID" -ForegroundColor Yellow
Write-Host "   - Optional: AZURE_SUBSCRIPTION_ID for default subscription" -ForegroundColor Yellow

return $false
