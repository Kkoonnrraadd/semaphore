param(
    [string]$Cloud = ""
)

Write-Host "🔐 Setting up Azure authentication..." -ForegroundColor Cyan

# If Cloud is provided, use it. Otherwise, try to detect or try both clouds
if (-not [string]::IsNullOrWhiteSpace($Cloud)) {
    Write-Host "🌐 Using specified cloud: $Cloud" -ForegroundColor Gray
    az cloud set --name $Cloud 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "⚠️ Warning: Could not set cloud to $Cloud" -ForegroundColor Yellow
    }
} else {
    # Try to detect from current context
    try {
        $currentCloud = az cloud show --query "name" -o tsv 2>$null
        if (-not [string]::IsNullOrWhiteSpace($currentCloud)) {
            Write-Host "🌐 Detected current cloud: $currentCloud" -ForegroundColor Gray
            $Cloud = $currentCloud
        } else {
            Write-Host "❌ No cloud context found and no Cloud parameter provided" -ForegroundColor Red
            Write-Host "   Please provide -Cloud parameter or ensure Azure CLI has a cloud context set" -ForegroundColor Yellow
            return $false
        }
    } catch {
        Write-Host "❌ Failed to detect Azure cloud context" -ForegroundColor Red
        Write-Host "   Please provide -Cloud parameter (e.g., 'AzureCloud' or 'AzureUSGovernment')" -ForegroundColor Yellow
        return $false
    }
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

# Try Username/Password authentication
# if ($env:AZURE_USERNAME -and $env:AZURE_PASSWORD) {
#     Write-Host "🔑 Using Username/Password authentication..." -ForegroundColor Yellow
    
#     try {
#         $result = az login --username $env:AZURE_USERNAME --password $env:AZURE_PASSWORD --output json 2>&1
            
#         if ($LASTEXITCODE -eq 0) {
#             Write-Host "✅ Username/Password authentication successful" -ForegroundColor Green
            
#             # Set default subscription if provided
#             if ($env:AZURE_SUBSCRIPTION_ID) {
#                 az account set --subscription $env:AZURE_SUBSCRIPTION_ID
#                 Write-Host "📋 Set default subscription: $env:AZURE_SUBSCRIPTION_ID" -ForegroundColor Green
#             }
            
#             return $true
#         } else {
#             Write-Host "❌ Username/Password authentication failed: $result" -ForegroundColor Red
#         }
#     } catch {
#         Write-Host "❌ Username/Password authentication error: $($_.Exception.Message)" -ForegroundColor Red
#     }
# } else {
#     Write-Host "⚠️ Username/Password credentials not found in environment variables" -ForegroundColor Yellow
# }

# No authentication method available
Write-Host "❌ No Azure credentials found in environment variables" -ForegroundColor Red
Write-Host "   - Service Principal: AZURE_CLIENT_ID, AZURE_CLIENT_SECRET, AZURE_TENANT_ID" -ForegroundColor Yellow
Write-Host "   - Username/Password: AZURE_USERNAME, AZURE_PASSWORD" -ForegroundColor Yellow
Write-Host "   - Optional: AZURE_SUBSCRIPTION_ID for default subscription" -ForegroundColor Yellow

return $false
