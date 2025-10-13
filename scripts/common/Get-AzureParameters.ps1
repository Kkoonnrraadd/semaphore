<#
.SYNOPSIS
    Gets Azure parameters from environment variables and Azure CLI context

.DESCRIPTION
    This script collects parameters from:
    - ENVIRONMENT variable → Source
    - Azure CLI context → Cloud (from Connect-Azure.ps1)
    - SEMAPHORE_SCHEDULE_TIMEZONE → Timezone
    - Defaults → Namespaces (manufacturo, test)
    
    No complex detection - uses simple, explicit configuration.

.PARAMETER Source
    Optional source environment name (if not provided, uses ENVIRONMENT variable)

.PARAMETER Destination
    Optional destination environment name (defaults to same as source)

.PARAMETER SourceNamespace
    Optional source namespace (defaults to "manufacturo")

.PARAMETER DestinationNamespace
    Optional destination namespace (defaults to "test")

.EXAMPLE
    # With ENVIRONMENT=gov001 set
    $params = & Get-AzureParameters.ps1
    # Returns: Source=gov001, Cloud=AzureUSGovernment, etc.

.EXAMPLE
    # Override specific values
    $params = & Get-AzureParameters.ps1 -Source "prod" -DestinationNamespace "qa"
#>

param(
    [AllowEmptyString()][string]$Source,
    [AllowEmptyString()][string]$Destination,
    [AllowEmptyString()][string]$SourceNamespace,
    [AllowEmptyString()][string]$DestinationNamespace
)

function Get-NamespaceFromEnvironment {
    <#
    .SYNOPSIS
        Returns namespace - either user-provided or organizational default
    #>
    param(
        [string]$UserProvidedNamespace,
        [string]$NamespaceType = "destination"  # "source" or "destination"
    )
    
    # If user provided a namespace, use it (ALWAYS wins)
    if (-not [string]::IsNullOrWhiteSpace($UserProvidedNamespace)) {
        Write-Host "✅ Using provided $NamespaceType namespace: $UserProvidedNamespace" -ForegroundColor Green
        return $UserProvidedNamespace
    }
    
    # Use organizational defaults
    # These are the ONLY valid namespaces for your organization
    if ($NamespaceType -eq "source") {
        Write-Host "✅ Using default source namespace: manufacturo" -ForegroundColor Green
        return "manufacturo"
    } else {
        Write-Host "✅ Using default destination namespace: test" -ForegroundColor Green
        return "test"
    }
}

# Main parameter detection logic
Write-Host "🔍 Auto-detecting Azure parameters..." -ForegroundColor Cyan

# 1. Get Cloud from authenticated Azure CLI context (already set by Connect-Azure.ps1)
$Cloud = az cloud show --query "name" -o tsv 2>$null
if (-not $Cloud) {
    Write-Host "❌ ERROR: Not authenticated to Azure. Please run Connect-Azure.ps1 first." -ForegroundColor Red
    throw "Azure authentication required"
}
Write-Host "☁️  Cloud from Azure CLI context: $Cloud" -ForegroundColor Green

# 2. Get Source from ENVIRONMENT variable or parameter
if ([string]::IsNullOrWhiteSpace($Source)) {
    # Get from ENVIRONMENT variable (required)
    if ($env:ENVIRONMENT) {
        $Source = $env:ENVIRONMENT.ToLower()
        Write-Host "🎯 Source from ENVIRONMENT variable: $Source" -ForegroundColor Green
    } else {
        Write-Host "" -ForegroundColor Red
        Write-Host "❌ FATAL ERROR: Source environment not provided and ENVIRONMENT variable not set" -ForegroundColor Red
        Write-Host "   Please either:" -ForegroundColor Yellow
        Write-Host "   1. Set ENVIRONMENT variable (e.g., export ENVIRONMENT='gov001')" -ForegroundColor Gray
        Write-Host "   2. Provide the Source parameter explicitly (e.g., -Source 'gov001')" -ForegroundColor Gray
        Write-Host "" -ForegroundColor Red
        throw "Source environment must be provided via ENVIRONMENT variable or -Source parameter."
    }
} else {
    # User explicitly provided Source - respect their choice
    Write-Host "🎯 Using USER-PROVIDED source: $Source" -ForegroundColor Yellow
    $Source = $Source.ToLower()
}

# 3. Detect Source Namespace (if not provided)
if ([string]::IsNullOrWhiteSpace($SourceNamespace)) {
    $SourceNamespace = Get-NamespaceFromEnvironment -UserProvidedNamespace $SourceNamespace -NamespaceType "source"
    # Already logged in function
} else {
    Write-Host "🏷️ Using provided source namespace: $SourceNamespace" -ForegroundColor Yellow
}

# 4. Detect Destination (if not provided)
if ([string]::IsNullOrWhiteSpace($Destination)) {
    $Destination = $Source  # Same as source by default
    Write-Host "🎯 Auto-detected destination: $Destination (same as source)" -ForegroundColor Green
} else {
    # User explicitly provided Destination - respect their choice
    Write-Host "🎯 Using USER-PROVIDED destination: $Destination" -ForegroundColor Yellow
    $Destination = $Destination.ToLower()
}

# 5. Detect Destination Namespace (if not provided)
if ([string]::IsNullOrWhiteSpace($DestinationNamespace)) {
    $DestinationNamespace = Get-NamespaceFromEnvironment -UserProvidedNamespace $DestinationNamespace -NamespaceType "destination"
    # Already logged in function
} else {
    Write-Host "🏷️ Using provided destination namespace: $DestinationNamespace" -ForegroundColor Yellow
}

# SAFETY CHECK: Prevent Source = Destination (would overwrite source!)
if ($Source -eq $Destination -and $SourceNamespace -eq $DestinationNamespace) {
    Write-Host "" -ForegroundColor Red
    Write-Host "🚫 BLOCKED: Source and Destination cannot be the same!" -ForegroundColor Red
    Write-Host "   Source: $Source/$SourceNamespace" -ForegroundColor Yellow
    Write-Host "   Destination: $Destination/$DestinationNamespace" -ForegroundColor Yellow
    Write-Host "" -ForegroundColor Red
    Write-Host "   This would overwrite the source environment and cause data loss!" -ForegroundColor Red
    Write-Host "   Please specify a different destination environment." -ForegroundColor Yellow
    Write-Host "" -ForegroundColor Red
    throw "SAFETY: Source and Destination must be different to prevent data loss"
}
# 6. Set default values for time-sensitive parameters
# Check for SEMAPHORE_SCHEDULE_TIMEZONE environment variable (required for safety)
$envTimezone = [System.Environment]::GetEnvironmentVariable("SEMAPHORE_SCHEDULE_TIMEZONE")
if (-not [string]::IsNullOrWhiteSpace($envTimezone)) {
    $DefaultTimezone = $envTimezone
    Write-Host "🕐 Set default timezone from SEMAPHORE_SCHEDULE_TIMEZONE: $DefaultTimezone" -ForegroundColor Green
} else {
    # FAIL: Timezone is required to prevent incorrect data exports
    Write-Host "" -ForegroundColor Red
    Write-Host "❌ FATAL ERROR: SEMAPHORE_SCHEDULE_TIMEZONE environment variable is not set" -ForegroundColor Red
    Write-Host "   This is required to prevent incorrect timezone assumptions." -ForegroundColor Yellow
    Write-Host "   Please set SEMAPHORE_SCHEDULE_TIMEZONE in docker-compose.yaml" -ForegroundColor Yellow
    Write-Host "   Example: SEMAPHORE_SCHEDULE_TIMEZONE: 'UTC'" -ForegroundColor Gray
    Write-Host "" -ForegroundColor Red
    throw "SEMAPHORE_SCHEDULE_TIMEZONE environment variable must be set. No default will be assumed to prevent data errors."
}

# Calculate default restore time in the configured timezone
# Use backup propagation delay (10 minutes) to ensure backups are ready
try {
    $timezoneInfo = [System.TimeZoneInfo]::FindSystemTimeZoneById($DefaultTimezone)
    # Get current UTC time
    $utcNow = [DateTime]::UtcNow
    # Convert to the configured timezone
    $currentTimeInTimezone = [System.TimeZoneInfo]::ConvertTimeFromUtc($utcNow, $timezoneInfo)
    # Subtract 10 minutes (Azure SQL backup propagation delay)
    $BackupPropagationDelayMinutes = 10
    $DefaultRestoreDateTime = $currentTimeInTimezone.AddMinutes(-$BackupPropagationDelayMinutes).ToString("yyyy-MM-dd HH:mm:ss")
    Write-Host "🕐 Set default restore time: $DefaultRestoreDateTime ($BackupPropagationDelayMinutes minutes ago in $DefaultTimezone)" -ForegroundColor Green
    Write-Host "   (Safe buffer for Azure SQL backup propagation)" -ForegroundColor Gray
} catch {
    Write-Host "" -ForegroundColor Red
    Write-Host "❌ FATAL ERROR: Invalid timezone '$DefaultTimezone'" -ForegroundColor Red
    Write-Host "   Error: $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host "   Please use a valid IANA timezone identifier" -ForegroundColor Yellow
    Write-Host "" -ForegroundColor Red
    throw "Invalid timezone configuration: $DefaultTimezone"
}

Write-Host "✅ Parameter detection completed" -ForegroundColor Green
Write-Host "📋 Detected parameters:" -ForegroundColor Cyan
Write-Host "   Source: $Source" -ForegroundColor Gray
Write-Host "   Source Namespace: $SourceNamespace" -ForegroundColor Gray
Write-Host "   Destination: $Destination" -ForegroundColor Gray
Write-Host "   Destination Namespace: $DestinationNamespace" -ForegroundColor Gray
Write-Host "   Cloud: $Cloud" -ForegroundColor Gray

# Return the detected parameters
return @{
    Source = $Source
    SourceNamespace = $SourceNamespace
    Destination = $Destination
    DestinationNamespace = $DestinationNamespace
    Cloud = $Cloud
    DefaultTimezone = $DefaultTimezone
    DefaultRestoreDateTime = $DefaultRestoreDateTime
}
