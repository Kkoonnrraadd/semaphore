param(
    [string]$Cloud
)

Write-Host "🔐 Setting up Azure authentication..." -ForegroundColor Cyan

# Try Service Principal authentication
if ($env:AZURE_CLIENT_ID -and $env:AZURE_TENANT_ID -and $env:AZURE_FEDERATED_TOKEN_FILE) {
    Write-Host "🔑 Authenticating with Service Principal..." -ForegroundColor Yellow
    
    try {
        Write-Host "🔐 Attempting login..." -ForegroundColor Gray
        Write-Host "   Tenant ID: $env:AZURE_TENANT_ID" -ForegroundColor DarkGray
        Write-Host "   Client ID: $env:AZURE_CLIENT_ID" -ForegroundColor DarkGray
        
        # Try first cloud
        Write-Host "🌐 Trying $Cloud cloud..." -ForegroundColor Gray
        az cloud set --name $Cloud 2>$null
        $result = az login --federated-token "$(cat $env:AZURE_FEDERATED_TOKEN_FILE)" --service-principal -u $env:AZURE_CLIENT_ID -t $env:AZURE_TENANT_ID --output json 2>&1
        
        if ($LASTEXITCODE -eq 0) {
            Write-Host "✅ Service Principal authentication successful" -ForegroundColor Green
            
            # Get cloud context from authenticated session
            $detectedCloud = az cloud show --query "name" -o tsv 2>$null
            Write-Host "🌐 Active cloud: $detectedCloud" -ForegroundColor Gray
            
            # Validate cloud if explicitly provided
            if (-not [string]::IsNullOrWhiteSpace($Cloud) -and $detectedCloud -ne $Cloud) {
                Write-Host "⚠️ Warning: Expected cloud '$Cloud' but authenticated to '$detectedCloud'" -ForegroundColor Yellow
            }
            
            # Show available subscriptions
            $subscriptions = az account list --query "[].{name:name, id:id, state:state}" -o json 2>$null | ConvertFrom-Json
            if ($subscriptions -and $subscriptions.Count -gt 0) {
                Write-Host "📋 Available subscriptions: $($subscriptions.Count)" -ForegroundColor Gray
                foreach ($sub in $subscriptions) {
                    $marker = if ($sub.state -eq "Enabled") { "✓" } else { "○" }
                    Write-Host "   $marker $($sub.name) ($($sub.id))" -ForegroundColor DarkGray
                }
            }
            
            # Check for ENVIRONMENT variable and set subscription context based on it
            if ($env:ENVIRONMENT) {
                Write-Host "`n🎯 ENVIRONMENT variable detected: $env:ENVIRONMENT" -ForegroundColor Cyan
                Write-Host "   Searching for subscription containing resources with this environment tag..." -ForegroundColor Gray
                
                try {
                    # Use Azure Resource Graph to find resources with this environment tag
                    # This will return the subscription ID where these resources exist
                    $envLower = $env:ENVIRONMENT.ToLower()
                    $graphQuery = "resources | where tags.Environment == '$envLower' | project subscriptionId | limit 1"
                    
                    $queryResult = az graph query -q $graphQuery --query "data[0].subscriptionId" -o tsv 2>$null
                    
                    if ($queryResult -and -not [string]::IsNullOrWhiteSpace($queryResult)) {
                        # Set this subscription as the default context
                        az account set --subscription $queryResult 2>$null
                        
                        if ($LASTEXITCODE -eq 0) {
                            $subContext = az account show --query "{name:name, id:id}" -o json 2>$null | ConvertFrom-Json
                            Write-Host "✅ Set subscription context based on ENVIRONMENT '$env:ENVIRONMENT'" -ForegroundColor Green
                            Write-Host "   → Subscription: $($subContext.name)" -ForegroundColor Gray
                            Write-Host "   → ID: $($subContext.id)" -ForegroundColor Gray
                        } else {
                            Write-Host "⚠️ Warning: Could not set subscription context to: $queryResult" -ForegroundColor Yellow
                        }
                    } else {
                        Write-Host "⚠️ Warning: No resources found with Environment tag '$env:ENVIRONMENT'" -ForegroundColor Yellow
                        Write-Host "   Using default subscription from authentication" -ForegroundColor Gray
                    }
                } catch {
                    Write-Host "⚠️ Warning: Could not query resources for ENVIRONMENT '$env:ENVIRONMENT'" -ForegroundColor Yellow
                    Write-Host "   Error: $($_.Exception.Message)" -ForegroundColor Gray
                    Write-Host "   Using default subscription from authentication" -ForegroundColor Gray
                }
            } else {
                Write-Host "`nℹ️  No ENVIRONMENT variable set" -ForegroundColor Gray
                Write-Host "   Operations will need to specify subscription explicitly via --subscription flag" -ForegroundColor Gray
                Write-Host "   Or set ENVIRONMENT variable (e.g., 'gov001') to auto-select subscription" -ForegroundColor Gray
            }
            
            return $true
        } else {
            Write-Host "❌ Service Principal authentication failed: $result" -ForegroundColor Red
            $global:LASTEXITCODE = 1
            throw "Service Principal authentication failed: $result"
        }
    } catch {
        Write-Host "❌ Service Principal authentication error: $($_.Exception.Message)" -ForegroundColor Red
        $global:LASTEXITCODE = 1
        throw "Service Principal authentication error: $($_.Exception.Message)"
    }
} else {
    Write-Host "⚠️ Service Principal credentials not found in environment variables" -ForegroundColor Yellow
    $global:LASTEXITCODE = 1
    throw "Service Principal credentials not found in environment variables"
}

# No authentication method available
Write-Host "❌ No Azure credentials found in environment variables" -ForegroundColor Red
Write-Host "   Required: AZURE_CLIENT_ID, AZURE_CLIENT_SECRET, AZURE_TENANT_ID" -ForegroundColor Yellow
Write-Host "   Note: Cloud context will be automatically detected after authentication" -ForegroundColor Gray

return $false
