param(
    [string]$Cloud = ""
)

Write-Host "🔐 Setting up Azure authentication..." -ForegroundColor Cyan

# Check if already authenticated
try {
    $context = az account show 2>$null | ConvertFrom-Json
    if ($context) {
        Write-Host "✅ Already authenticated to Azure" -ForegroundColor Green
        $currentCloud = az cloud show --query "name" -o tsv 2>$null
        Write-Host "   Cloud: $currentCloud" -ForegroundColor Gray
        Write-Host "   Tenant: $($context.tenantId)" -ForegroundColor Gray
        Write-Host "   Current Subscription: $($context.name)" -ForegroundColor Gray
        Write-Host "   Total Subscriptions: $((az account list --query 'length(@)' -o tsv 2>$null)) available" -ForegroundColor Gray
        return $true
    }
} catch {
    # Not authenticated, continue with login
}

# Try Service Principal authentication
if ($env:AZURE_CLIENT_ID -and $env:AZURE_CLIENT_SECRET -and $env:AZURE_TENANT_ID) {
    Write-Host "🔑 Authenticating with Service Principal..." -ForegroundColor Yellow
    
    try {
        Write-Host "🔐 Attempting login..." -ForegroundColor Gray
        Write-Host "   Tenant ID: $env:AZURE_TENANT_ID" -ForegroundColor DarkGray
        Write-Host "   Client ID: $env:AZURE_CLIENT_ID" -ForegroundColor DarkGray
        
        # Determine which cloud to try first
        $firstCloud = if (-not [string]::IsNullOrWhiteSpace($Cloud)) { $Cloud } else { "AzureUSGovernment" }
        $secondCloud = if ($firstCloud -eq "AzureUSGovernment") { "AzureCloud" } else { "AzureUSGovernment" }
        
        # Try first cloud
        Write-Host "🌐 Trying $firstCloud cloud..." -ForegroundColor Gray
        az cloud set --name $firstCloud 2>$null
        $result = az login --service-principal --username $env:AZURE_CLIENT_ID --password $env:AZURE_CLIENT_SECRET --tenant $env:AZURE_TENANT_ID --output json 2>&1
        
        if ($LASTEXITCODE -ne 0) {
            # Failed - try second cloud
            Write-Host "⚠️  $firstCloud failed - trying $secondCloud..." -ForegroundColor Yellow
            az cloud set --name $secondCloud 2>$null
            $result = az login --service-principal --username $env:AZURE_CLIENT_ID --password $env:AZURE_CLIENT_SECRET --tenant $env:AZURE_TENANT_ID --output json 2>&1
        }
            
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
Write-Host "   Required: AZURE_CLIENT_ID, AZURE_CLIENT_SECRET, AZURE_TENANT_ID" -ForegroundColor Yellow
Write-Host "   Note: Cloud context will be automatically detected after authentication" -ForegroundColor Gray

return $false
