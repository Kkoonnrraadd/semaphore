<#
.SYNOPSIS
    Automatically detects Azure parameters from the current Azure environment

.DESCRIPTION
    This script analyzes the current Azure subscription and environment to automatically
    determine parameters that were previously hardcoded in self_service_defaults.json

.PARAMETER Source
    Optional source environment name (if not provided, will be auto-detected)

.PARAMETER Destination
    Optional destination environment name (if not provided, will be auto-detected)

.PARAMETER SourceNamespace
    Optional source namespace (if not provided, will be auto-detected)

.PARAMETER DestinationNamespace
    Optional destination namespace (if not provided, will be auto-detected)

.EXAMPLE
    $params = Get-AzureParameters
    Write-Host "Detected source: $($params.Source)"
    Write-Host "Detected cloud: $($params.Cloud)"

.EXAMPLE
    $params = Get-AzureParameters -Source "prod" -DestinationNamespace "test"
    Write-Host "Using provided source: $($params.Source)"
    Write-Host "Auto-detected cloud: $($params.Cloud)"
#>

param(
    [AllowEmptyString()][string]$Source,
    [AllowEmptyString()][string]$Destination,
    [AllowEmptyString()][string]$SourceNamespace,
    [AllowEmptyString()][string]$DestinationNamespace
)

function Get-AzureCloudEnvironment {
    <#
    .SYNOPSIS
        Determines the Azure cloud environment from the current Azure CLI context
    #>
    try {
        $cloudInfo = az account show --query "environmentName" -o tsv 2>$null
        if ($cloudInfo) {
            return $cloudInfo
        }
    } catch {
        Write-Host "⚠️ Could not determine Azure cloud environment, using default: AzureUSGovernment" -ForegroundColor Yellow
    }
    
    # Default fallback
    return "AzureUSGovernment"
}

function Get-SourceFromSubscription {
    <#
    .SYNOPSIS
        Attempts to determine the source environment from subscription information
    #>
    try {
        # Get subscription information
        $subscription = az account show --query "{id:id, name:name, displayName:displayName}" -o json 2>$null | ConvertFrom-Json
        
        if ($subscription) {
            $subscriptionName = $subscription.name
            $subscriptionDisplayName = $subscription.displayName
            
            Write-Host "🔍 Analyzing subscription: $subscriptionDisplayName ($subscriptionName)" -ForegroundColor Gray
            
            # Try to extract environment from subscription name
            # Look for patterns like "wus018", "gwc001", "dev", "test", etc.
            # Extract the environment code after the last underscore
            if ($subscriptionName -match ".*_([A-Za-z0-9]+)$") {
                $detectedSource = $matches[1].ToLower()
                Write-Host "✅ Detected source from subscription name: $detectedSource" -ForegroundColor Green
                return $detectedSource
            }
            
            # Try to extract from display name with same pattern
            if ($subscriptionDisplayName -match ".*_([A-Za-z0-9]+)$") {
                $detectedSource = $matches[1].ToLower()
                Write-Host "✅ Detected source from subscription display name: $detectedSource" -ForegroundColor Green
                return $detectedSource
            }
            
            # If no pattern matches, try to get from Azure Graph query
            return Get-SourceFromAzureGraph
        }
    } catch {
        Write-Host "⚠️ Could not analyze subscription information: $($_.Exception.Message)" -ForegroundColor Yellow
    }
    
    # Final fallback
    return "gov001"
}

function Get-SourceFromAzureGraph {
    <#
    .SYNOPSIS
        Uses Azure Graph to find the most common environment in the current subscription
    #>
    try {
        Write-Host "🔍 Querying Azure Graph for environment information..." -ForegroundColor Gray
        
        # Query for SQL servers to find environment tags
        $graphQuery = @"
resources
| where type =~ 'microsoft.sql/servers'
| where tags.Environment != ''
| summarize count() by Environment = tags.Environment
| order by count_ desc
| take 1
| project Environment
"@
        
        $result = az graph query -q $graphQuery --query "data[0].Environment" -o tsv 2>$null
        
        if ($result -and $result -ne "null") {
            Write-Host "✅ Detected source from Azure Graph: $result" -ForegroundColor Green
            return $result
        }
    } catch {
        Write-Host "⚠️ Azure Graph query failed: $($_.Exception.Message)" -ForegroundColor Yellow
    }
    
    # Fallback
    return "gov001"
}

function Get-NamespaceFromEnvironment {
    <#
    .SYNOPSIS
        Determines the appropriate namespace based on environment and user input
    #>
    param(
        [string]$Environment,
        [string]$UserProvidedNamespace,
        [string]$DefaultNamespace,
        [string]$NamespaceType = "destination"  # "source" or "destination"
    )
    
    # If user provided a namespace, use it
    if (-not [string]::IsNullOrWhiteSpace($UserProvidedNamespace)) {
        return $UserProvidedNamespace
    }
    
    # For source namespace, almost always "manufacturo"
    if ($NamespaceType -eq "source") {
        return "manufacturo"
    }
    
    # For destination namespace, default to "test" unless user specifically provides "dev"
    # This ensures "test" is the default for all environments
    return "test"
    
    # Use default
    return $DefaultNamespace
}

function Get-CustomerAliasToRemove {
    <#
    .SYNOPSIS
        Determines the customer alias to remove based on customer alias pattern
    #>
    param(
        [string]$Source,
        [string]$CustomerAlias
    )
    
    # If customer alias is provided, extract the prefix before the suffix
    if (-not [string]::IsNullOrWhiteSpace($CustomerAlias)) {
        # Pattern: mil-space-test -> mil-space, mil-space-dev -> mil-space
        if ($CustomerAlias -match "^(.+)-(test|dev)$") {
            $prefix = $matches[1]
            Write-Host "✅ Extracted customer alias to remove: $prefix (from $CustomerAlias)" -ForegroundColor Green
            return $prefix
        }
    }
    
    # Fallback: Customer alias to remove is same as source
    return $Source
}

function Get-CustomerAlias {
    <#
    .SYNOPSIS
        Returns the customer alias (should be provided by user)
    #>
    param(
        [string]$UserProvidedCustomerAlias
    )
    
    # Customer alias should be provided by the user
    # If not provided, return empty string (user must provide it)
    return $UserProvidedCustomerAlias
}

# Main parameter detection logic
Write-Host "🔍 Auto-detecting Azure parameters..." -ForegroundColor Cyan

# 1. Detect Azure Cloud Environment
$Cloud = Get-AzureCloudEnvironment
Write-Host "☁️ Detected cloud: $Cloud" -ForegroundColor Green

# 2. Detect Source (if not provided)
if ([string]::IsNullOrWhiteSpace($Source)) {
    $Source = Get-SourceFromSubscription
    Write-Host "🎯 Auto-detected source: $Source" -ForegroundColor Green
} else {
    Write-Host "🎯 Using provided source: $Source" -ForegroundColor Yellow
}

# 3. Detect Source Namespace (if not provided)
if ([string]::IsNullOrWhiteSpace($SourceNamespace)) {
    $SourceNamespace = Get-NamespaceFromEnvironment -Environment $Source -UserProvidedNamespace $SourceNamespace -DefaultNamespace "manufacturo" -NamespaceType "source"
    Write-Host "🏷️ Auto-detected source namespace: $SourceNamespace" -ForegroundColor Green
} else {
    Write-Host "🏷️ Using provided source namespace: $SourceNamespace" -ForegroundColor Yellow
}

# 4. Detect Destination (if not provided)
if ([string]::IsNullOrWhiteSpace($Destination)) {
    $Destination = $Source  # Same as source by default
    Write-Host "🎯 Auto-detected destination: $Destination (same as source)" -ForegroundColor Green
} else {
    Write-Host "🎯 Using provided destination: $Destination" -ForegroundColor Yellow
}

# 5. Detect Destination Namespace (if not provided)
if ([string]::IsNullOrWhiteSpace($DestinationNamespace)) {
    $DestinationNamespace = Get-NamespaceFromEnvironment -Environment $Destination -UserProvidedNamespace $DestinationNamespace -DefaultNamespace "test" -NamespaceType "destination"
    Write-Host "🏷️ Auto-detected destination namespace: $DestinationNamespace" -ForegroundColor Green
} else {
    Write-Host "🏷️ Using provided destination namespace: $DestinationNamespace" -ForegroundColor Yellow
}

# 6. Generate derived parameters
# CustomerAlias should be provided by user - no auto-generation
$CustomerAlias = ""  # Will be handled by the calling script
# CustomerAliasToRemove will be calculated in the calling script when CustomerAlias is available

# 7. Set default values for time-sensitive parameters
$DefaultTimezone = [System.TimeZoneInfo]::Local.Id  # Use system timezone
$DefaultRestoreDateTime = (Get-Date).AddMinutes(-5).ToString("yyyy-MM-dd HH:mm:ss")  # 5 minutes ago

Write-Host "🕐 Set default timezone: $DefaultTimezone (system timezone)" -ForegroundColor Green
Write-Host "🕐 Set default restore time: $DefaultRestoreDateTime (5 minutes ago)" -ForegroundColor Green

Write-Host "✅ Parameter detection completed" -ForegroundColor Green
Write-Host "📋 Detected parameters:" -ForegroundColor Cyan
Write-Host "   Source: $Source" -ForegroundColor Gray
Write-Host "   Source Namespace: $SourceNamespace" -ForegroundColor Gray
Write-Host "   Destination: $Destination" -ForegroundColor Gray
Write-Host "   Destination Namespace: $DestinationNamespace" -ForegroundColor Gray
Write-Host "   Customer Alias: $CustomerAlias" -ForegroundColor Gray
Write-Host "   Cloud: $Cloud" -ForegroundColor Gray

# Return the detected parameters
return @{
    Source = $Source
    SourceNamespace = $SourceNamespace
    Destination = $Destination
    DestinationNamespace = $DestinationNamespace
    CustomerAlias = $CustomerAlias
    Cloud = $Cloud
    DefaultTimezone = $DefaultTimezone
    DefaultRestoreDateTime = $DefaultRestoreDateTime
}
