<#
.SYNOPSIS
    Semaphore wrapper script for self_service.ps1

.DESCRIPTION
    This script handles the parameter conversion from Semaphore's format to the self_service.ps1 format.
    Semaphore passes parameters as positional arguments, but we need to convert them to named parameters.

.PARAMETER RestoreDateTime
    Point in time to restore to (yyyy-MM-dd HH:mm:ss)

.PARAMETER Timezone
    Timezone for restore datetime

.PARAMETER SourceNamespace
    Source namespace (e.g., manufacturo)

.PARAMETER Source
    Source environment (e.g., gov001)

.PARAMETER DestinationNamespace
    Destination namespace (e.g., test)

.PARAMETER Destination
    Destination environment (e.g., gov001)

.PARAMETER InstanceAlias
    Instance alias for this refresh

.PARAMETER InstanceAliasToRemove
    Instance alias to remove (optional)

.PARAMETER Cloud
    Azure cloud environment

.PARAMETER DryRun
    Enable dry run mode (preview only, no changes)

.PARAMETER MaxWaitMinutes
    Maximum minutes to wait for operations

.PARAMETER production_confirm
    Production confirmation (PRODUCTION template only)
#>

# Don't use param() - we'll parse arguments manually to handle any order

# Function to parse command line arguments and extract parameter values
function Parse-Arguments {
    param(
        [string[]]$Arguments
    )
    
    $parameters = @{}
    
    # Parse each argument
    for ($i = 0; $i -lt $Arguments.Length; $i++) {
        $arg = $Arguments[$i]
        
        # Skip if empty
        if ([string]::IsNullOrWhiteSpace($arg)) {
            continue
        }
        
        # Check if it's in "ParameterName=Value" format
        if ($arg -match "^([^=]+)=(.*)$") {
            $paramName = $matches[1].Trim()
            $paramValue = $matches[2].Trim()
            
            # Remove quotes if present
            if ($paramValue.StartsWith('"') -and $paramValue.EndsWith('"')) {
                $paramValue = $paramValue.Substring(1, $paramValue.Length - 2)
            }
            if ($paramValue.StartsWith("'") -and $paramValue.EndsWith("'")) {
                $paramValue = $paramValue.Substring(1, $paramValue.Length - 2)
            }
            
            $parameters[$paramName] = $paramValue
            Write-Host "🔧 Parsed parameter: $paramName = $paramValue" -ForegroundColor Yellow
        }
        # Check if it's a boolean value (like "DryRun=true")
        elseif ($arg -match "^(DryRun)=(true|false)$") {
            $paramName = $matches[1]
            $paramValue = $matches[2] -eq "true"
            $parameters[$paramName] = $paramValue
            Write-Host "🔧 Parsed boolean parameter: $paramName = $paramValue" -ForegroundColor Yellow
        }
        # Handle other formats as needed
        else {
            Write-Host "⚠️ Unrecognized argument format: $arg" -ForegroundColor Yellow
        }
    }
    
    return $parameters
}

# ============================================================================
# DATETIME NORMALIZATION
# ============================================================================

function Normalize-DateTime {
    param (
        [string]$InputDateTime
    )
    
    if ([string]::IsNullOrWhiteSpace($InputDateTime)) {
        return ""
    }
    
    Write-Host "📅 Parsing datetime input: '$InputDateTime'" -ForegroundColor Gray
    
    # Define common datetime formats to try
    $formats = @(
        # Standard format
        'yyyy-MM-dd HH:mm:ss',
        
        # ISO 8601 formats
        'yyyy-MM-ddTHH:mm:ss',
        'yyyy-MM-dd HH:mm',
        'yyyy-MM-dd',
        
        # US formats
        'M/d/yyyy h:mm:ss tt',    # 1/15/2025 2:30:00 PM
        'M/d/yyyy H:mm:ss',       # 1/15/2025 14:30:00
        'M/d/yyyy h:mm tt',       # 1/15/2025 2:30 PM
        'M/d/yyyy H:mm',          # 1/15/2025 14:30
        'M/d/yyyy',               # 1/15/2025
        'MM/dd/yyyy HH:mm:ss',    # 01/15/2025 14:30:00
        'MM/dd/yyyy',             # 01/15/2025
        
        # European formats
        'dd/MM/yyyy HH:mm:ss',    # 15/01/2025 14:30:00
        'dd/MM/yyyy',             # 15/01/2025
        'd/M/yyyy H:mm:ss',       # 15/1/2025 14:30:00
        'd/M/yyyy',               # 15/1/2025
        
        # Alternative separators
        'yyyy.MM.dd HH:mm:ss',
        'yyyy.MM.dd',
        'dd.MM.yyyy HH:mm:ss',
        'dd.MM.yyyy',
        
        # With dashes
        'dd-MM-yyyy HH:mm:ss',
        'dd-MM-yyyy',
        'MM-dd-yyyy HH:mm:ss',
        'MM-dd-yyyy'
    )
    
    # Try to parse with each format
    foreach ($format in $formats) {
        try {
            $parsedDate = [DateTime]::ParseExact($InputDateTime, $format, [System.Globalization.CultureInfo]::InvariantCulture)
            $normalizedDate = $parsedDate.ToString('yyyy-MM-dd HH:mm:ss')
            Write-Host "  ✅ Parsed successfully using format: $format" -ForegroundColor Green
            Write-Host "  ✅ Normalized to: $normalizedDate" -ForegroundColor Green
            return $normalizedDate
        } catch {
            # Try next format
        }
    }
    
    # If all formats fail, try .NET's automatic parsing as last resort
    try {
        $parsedDate = [DateTime]::Parse($InputDateTime)
        $normalizedDate = $parsedDate.ToString('yyyy-MM-dd HH:mm:ss')
        Write-Host "  ✅ Parsed successfully using automatic parsing" -ForegroundColor Green
        Write-Host "  ✅ Normalized to: $normalizedDate" -ForegroundColor Green
        return $normalizedDate
    } catch {
        # All parsing attempts failed
        Write-Host "" -ForegroundColor Red
        Write-Host "❌ FATAL ERROR: Could not parse datetime: '$InputDateTime'" -ForegroundColor Red
        Write-Host "   Please use one of these formats:" -ForegroundColor Yellow
        Write-Host "   • Standard: 2025-01-15 14:30:00 (recommended)" -ForegroundColor Gray
        Write-Host "   • ISO 8601: 2025-01-15T14:30:00" -ForegroundColor Gray
        Write-Host "   • US Format: 1/15/2025 2:30:00 PM" -ForegroundColor Gray
        Write-Host "   • European: 15/01/2025 14:30:00" -ForegroundColor Gray
        Write-Host "   • Date Only: 2025-01-15 (time defaults to 00:00:00)" -ForegroundColor Gray
        Write-Host "" -ForegroundColor Red
        Write-Host "Examples of valid inputs:" -ForegroundColor Cyan
        Write-Host "  • 2025-10-11 14:30:00" -ForegroundColor Gray
        Write-Host "  • 10/11/2025 2:30 PM" -ForegroundColor Gray
        Write-Host "  • 11/10/2025 14:30:00" -ForegroundColor Gray
        Write-Host "  • 2025-10-11" -ForegroundColor Gray
        Write-Host "" -ForegroundColor Red
        $global:LASTEXITCODE = 1
        throw "Could not parse datetime: '$InputDateTime' - please use a valid datetime format"
    }
}


# Parse all command line arguments
Write-Host "🔧 Semaphore Wrapper: Parsing command line arguments..." -ForegroundColor Cyan
Write-Host "📋 Raw arguments: $($args -join ' ')" -ForegroundColor Gray

$parsedParams = Parse-Arguments -Arguments $args

# Extract parameters - no defaults needed as self_service.ps1 will auto-detect them
$RestoreDateTime = if ($parsedParams.ContainsKey("RestoreDateTime")) { $parsedParams["RestoreDateTime"] } else { "" }
$Timezone = if ($parsedParams.ContainsKey("Timezone")) { $parsedParams["Timezone"] } else { "" }
$SourceNamespace = if ($parsedParams.ContainsKey("SourceNamespace")) { $parsedParams["SourceNamespace"] } else { "" }
$Source = if ($parsedParams.ContainsKey("Source")) { $parsedParams["Source"] } else { "" }
$DestinationNamespace = if ($parsedParams.ContainsKey("DestinationNamespace")) { $parsedParams["DestinationNamespace"] } else { "" }
$Destination = if ($parsedParams.ContainsKey("Destination")) { $parsedParams["Destination"] } else { "" }
$InstanceAlias = if ($parsedParams.ContainsKey("InstanceAlias")) { $parsedParams["InstanceAlias"] } else { "" }
$InstanceAliasToRemove = if ($parsedParams.ContainsKey("InstanceAliasToRemove")) { $parsedParams["InstanceAliasToRemove"] } else { "" }
$Cloud = if ($parsedParams.ContainsKey("Cloud")) { $parsedParams["Cloud"] } else { "" }
$MaxWaitMinutes = if ($parsedParams.ContainsKey("MaxWaitMinutes")) { $parsedParams["MaxWaitMinutes"] } else { "" }

$DryRun = if ($parsedParams.ContainsKey("DryRun")) { 
    $dryRunValue = $parsedParams["DryRun"]
    $dryRunBool = if ($dryRunValue -eq "false" -or $dryRunValue -eq $false) { $false } else { $true }
    Write-Host "🔧 Converted DryRun: '$dryRunValue' → $dryRunBool" -ForegroundColor Yellow
    $dryRunBool
} else { 
    Write-Host "🔧 Using default DryRun: true" -ForegroundColor Yellow
    $true 
}

$production_confirm = if ($parsedParams.ContainsKey("production_confirm")) { $parsedParams["production_confirm"] } else { "" }

Write-Host "🔧 Semaphore Wrapper: Converting parameters for self_service.ps1" -ForegroundColor Cyan
Write-Host "📋 Sanitized parameters:" -ForegroundColor Gray
Write-Host "  RestoreDateTime: $RestoreDateTime" -ForegroundColor Gray
Write-Host "  Timezone: $Timezone" -ForegroundColor Gray
Write-Host "  SourceNamespace: $SourceNamespace" -ForegroundColor Gray
Write-Host "  Source: $Source" -ForegroundColor Gray
Write-Host "  DestinationNamespace: $DestinationNamespace" -ForegroundColor Gray
Write-Host "  Destination: $Destination" -ForegroundColor Gray
Write-Host "  InstanceAlias: $InstanceAlias" -ForegroundColor Gray
Write-Host "  InstanceAliasToRemove: $InstanceAliasToRemove" -ForegroundColor Gray
Write-Host "  Cloud: $Cloud" -ForegroundColor Gray
Write-Host "  DryRun: $DryRun" -ForegroundColor Gray
Write-Host "  MaxWaitMinutes: $MaxWaitMinutes" -ForegroundColor Gray
if ($production_confirm) {
    Write-Host "  production_confirm: $production_confirm" -ForegroundColor Gray
}

# Get the directory of this script using dynamic path detection
# This ensures we always use the latest repository folder (repository_1_template_N)
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# Dynamically detect the latest repository path
$baseDir = "/tmp/semaphore/project_1"
Write-Host "🔍 Detecting latest repository path in $baseDir..." -ForegroundColor Cyan

# First, update the entry point repository to ensure we have latest code
$entryRepo = Join-Path $baseDir "repository_1_template_1"
if (Test-Path $entryRepo) {
    Write-Host "   🔄 Updating entry repository..." -ForegroundColor Gray
    try {
        git -C $entryRepo fetch origin 2>&1 | Out-Null
        git -C $entryRepo reset --hard origin/main 2>&1 | Out-Null
        Write-Host "   ✅ Entry repository updated to latest" -ForegroundColor Green
    } catch {
        Write-Host "   ⚠️  Could not update entry repository (will use existing): $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

$repositories = Get-ChildItem -Path $baseDir -Directory -ErrorAction SilentlyContinue | 
    Where-Object { $_.Name -match '^repository_\d+_template_\d+$' } |
    Sort-Object LastWriteTime -Descending

if ($repositories -and $repositories.Count -gt 0) {
    $latestRepo = $repositories[0]
    $latestRepoPath = $latestRepo.FullName
    Write-Host "✅ Using latest repository: $($latestRepo.Name) (modified: $($latestRepo.LastWriteTime))" -ForegroundColor Green
    
    # Update script directory to point to latest repository
    $scriptDir = Join-Path $latestRepoPath "scripts/main"
} else {
    Write-Host "⚠️ Could not detect repository folders, using current script directory" -ForegroundColor Yellow
}

$selfServiceScript = Join-Path $scriptDir "self_service.ps1"
Write-Host "📂 Self-service script path: $selfServiceScript" -ForegroundColor Gray

# Safety check: Verify the script exists
if (-not (Test-Path $selfServiceScript)) {
    Write-Host "" -ForegroundColor Red
    Write-Host "❌ FATAL ERROR: self_service.ps1 not found at expected path" -ForegroundColor Red
    Write-Host "   Expected: $selfServiceScript" -ForegroundColor Yellow
    Write-Host "   This usually means the repository was not properly cloned by Semaphore" -ForegroundColor Yellow
    Write-Host "" -ForegroundColor Red
    Write-Host "📋 Troubleshooting:" -ForegroundColor Cyan
    Write-Host "   1. Check if Semaphore has cloned the repository" -ForegroundColor Gray
    Write-Host "   2. Verify the git repository is accessible" -ForegroundColor Gray
    Write-Host "   3. Check Semaphore task logs for clone errors" -ForegroundColor Gray
    Write-Host "" -ForegroundColor Red
    $global:LASTEXITCODE = 1
    throw "self_service.ps1 not found - repository may not be properly initialized"
}

Write-Host "🚀 Calling self_service.ps1 with converted parameters..." -ForegroundColor Green
# Build parameter hashtable - only include non-empty values
# $parsedParams = @{}

# ============================================================================
# TIMEZONE VALIDATION AND DEFAULTING
# ============================================================================

# Get effective timezone (user-provided or from environment)
if (-not [string]::IsNullOrWhiteSpace($Timezone)) {
    # User provided timezone - use it (user override wins)
    # $parsedParams['Timezone'] = $Timezone
    Write-Host "🕐 Using user-provided timezone: $Timezone" -ForegroundColor Yellow
} else {
    # Check for SEMAPHORE_SCHEDULE_TIMEZONE environment variable
    $envTimezone = $env:SEMAPHORE_SCHEDULE_TIMEZONE
    if (-not [string]::IsNullOrWhiteSpace($envTimezone)) {
        # $parsedParams['Timezone'] = $envTimezone
        $Timezone = $envTimezone
        Write-Host "🕐 Using timezone from SEMAPHORE_SCHEDULE_TIMEZONE: $Timezone" -ForegroundColor Green
    } else {
        Write-Host "❌ FATAL ERROR: Timezone not provided and SEMAPHORE_SCHEDULE_TIMEZONE not set" -ForegroundColor Red
        Write-Host "   Restore operations require a timezone to prevent incorrect restore points." -ForegroundColor Yellow
        Write-Host "   Please either:" -ForegroundColor Yellow
        Write-Host "   1. Set SEMAPHORE_SCHEDULE_TIMEZONE environment variable" -ForegroundColor Gray
        Write-Host "   2. Provide Timezone parameter explicitly" -ForegroundColor Gray
        $global:LASTEXITCODE = 1
        throw "Timezone not provided and SEMAPHORE_SCHEDULE_TIMEZONE not set - restore operations require a timezone"
    }
}

# Calculate default restore time in the configured timezone
# Use backup propagation delay (10 minutes) to ensure backups are ready
try {

    # $timezoneInfo = [System.TimeZoneInfo]::FindSystemTimeZoneById($parsedParams['Timezone'])
    $timezoneInfo = [System.TimeZoneInfo]::FindSystemTimeZoneById($Timezone)
    # Get current UTC time
    $utcNow = [DateTime]::UtcNow
    # Convert to the configured timezone
    $currentTimeInTimezone = [System.TimeZoneInfo]::ConvertTimeFromUtc($utcNow, $timezoneInfo)
    # Subtract 10 minutes (Azure SQL backup propagation delay)
    $BackupPropagationDelayMinutes = 10

    # Normalize RestoreDateTime if provided
    if (-not [string]::IsNullOrWhiteSpace($RestoreDateTime)) {
        $RestoreDateTime  = Normalize-DateTime -InputDateTime $RestoreDateTime
        Write-Host "🕐 Using provided RestoreDateTime: $RestoreDateTime" -ForegroundColor Green
    }else{
        $RestoreDateTime = $currentTimeInTimezone.AddMinutes(-$BackupPropagationDelayMinutes).ToString("yyyy-MM-dd HH:mm:ss")
        Write-Host "🕐 Using default RestoreDateTime: $RestoreDateTime ($BackupPropagationDelayMinutes minutes ago in $Timezone)" -ForegroundColor Gray
        Write-Host "   (Safe buffer for Azure SQL backup propagation)" -ForegroundColor Gray
    }

} catch {
    Write-Host "" -ForegroundColor Red
    Write-Host "❌ FATAL ERROR: Invalid restore datetime '$RestoreDateTime' for timezone '$Timezone'"
    Write-Host "   Error: $($_.Exception.Message)" -ForegroundColor Yellow
    $global:LASTEXITCODE = 1
    throw "Invalid timezone configuration: $parsedParams['Timezone']. Please use a valid IANA timezone identifier and datetime format e.g (yyyy-MM-dd HH:mm:ss) for more information see README.md and DOCS/"
}




# ============================================================================
# MAX WAIT MINUTES VALIDATION AND DEFAULTING
# ============================================================================

# Convert MaxWaitMinutes to integer
# Default value
$DefaultMaxWaitMinutes = 60

if (-not [string]::IsNullOrWhiteSpace($MaxWaitMinutes)) {
    try {
        $MaxWaitMinutesInt = [int]::Parse($MaxWaitMinutes)
        if ($MaxWaitMinutesInt -lt 1 -or $MaxWaitMinutesInt -gt 360) {
            Write-Host "⚠️ Invalid MaxWaitMinutes '$MaxWaitMinutes', must be between 1 and 360 minutes" -ForegroundColor Yellow
            Write-Host "   Using default: 60 minutes" -ForegroundColor Gray
            $MaxWaitMinutes = $DefaultMaxWaitMinutes
        } else {
            Write-Host "🕐 Using provided MaxWaitMinutes: $MaxWaitMinutes" -ForegroundColor Green
            $MaxWaitMinutes = $MaxWaitMinutesInt
        }
    } catch {
        Write-Host "⚠️ Could not parse MaxWaitMinutes '$MaxWaitMinutes', using default: 60" -ForegroundColor Yellow
        $global:LASTEXITCODE = 1
        throw "Could not parse MaxWaitMinutes '$MaxWaitMinutes', error: $($_.Exception.Message)"
    }
}else{
    Write-Host "🕐 Using default MaxWaitMinutes: 60" -ForegroundColor Gray
    $MaxWaitMinutes = $DefaultMaxWaitMinutes
}

# Special handling for SourceNamespace - if not provided, try to get from ENVIRONMENT variable
if (-not [string]::IsNullOrWhiteSpace($SourceNamespace)) { 
    # $parsedParams['SourceNamespace'] = $SourceNamespace 
    Write-Host "📋 Wrapper: Using provided SourceNamespace = $SourceNamespace" -ForegroundColor Cyan
} else {
    # Try to read ENVIRONMENT variable
    $envVar = $env:SOURCE_NAMESPACE
    if (-not [string]::IsNullOrWhiteSpace($envVar)) {
        $SourceNamespace = $envVar
        Write-Host "📋 Wrapper: Using SOURCE_NAMESPACE variable as SourceNamespace = $SourceNamespace" -ForegroundColor Cyan
    } else {
        Write-Host "⚠️ Wrapper: No SourceNamespace provided and SOURCE_NAMESPACE variable not set" -ForegroundColor Yellow
        Write-Host "   1. Provide -SourceNamespace parameter (e.g., -SourceNamespace 'manufacturo')" -ForegroundColor Gray
        Write-Host "   2. Set SOURCE_NAMESPACE environment variable (e.g., export SOURCE_NAMESPACE='manufacturo')" -ForegroundColor Gray
        $global:LASTEXITCODE = 1
        throw "SourceNamespace is required - provide -SourceNamespace parameter or set SOURCE_NAMESPACE environment variable"
    }
}

# Special handling for Source - if not provided, try to get from ENVIRONMENT variable
if (-not [string]::IsNullOrWhiteSpace($Source)) { 
    # $parsedParams['Source'] = $Source 
    Write-Host "📋 Wrapper: Using provided Source = $Source" -ForegroundColor Cyan
} else {
    # Try to read ENVIRONMENT variable
    $envVar = $env:ENVIRONMENT
    if (-not [string]::IsNullOrWhiteSpace($envVar)) {
        $Source = $envVar
        Write-Host "📋 Wrapper: Using ENVIRONMENT variable as Source = $Source" -ForegroundColor Cyan
    } else {
        Write-Host "⚠️ Wrapper: No Source provided and ENVIRONMENT variable not set" -ForegroundColor Yellow
        Write-Host "   1. Provide -Source parameter (e.g., -Source 'gov001')" -ForegroundColor Gray
        Write-Host "   2. Set ENVIRONMENT environment variable (e.g., export ENVIRONMENT='gov001')" -ForegroundColor Gray
        $global:LASTEXITCODE = 1
        throw "Source is required - provide -Source parameter or set ENVIRONMENT environment variable"
    }
}

# Special handling for DestinationNamespace - if not provided, try to get from ENVIRONMENT variable
if (-not [string]::IsNullOrWhiteSpace($DestinationNamespace)) { 
    # $parsedParams['DestinationNamespace'] = $DestinationNamespace 
    Write-Host "📋 Wrapper: Using provided DestinationNamespace = $DestinationNamespace" -ForegroundColor Cyan
} else {
    # Try to read ENVIRONMENT variable
    $envVar = $env:DESTINATION_NAMESPACE
    if (-not [string]::IsNullOrWhiteSpace($envVar)) {
        $DestinationNamespace = $envVar
        Write-Host "📋 Wrapper: Using DESTINATION_NAMESPACE variable as DestinationNamespace = $DestinationNamespace" -ForegroundColor Cyan
    } else {
        Write-Host "⚠️ Wrapper: No DestinationNamespace provided and DESTINATION_NAMESPACE variable not set" -ForegroundColor Yellow
        Write-Host "   1. Provide -DestinationNamespace parameter (e.g., -DestinationNamespace 'test')" -ForegroundColor Gray
        Write-Host "   2. Set DESTINATION_NAMESPACE environment variable (e.g., export DESTINATION_NAMESPACE='test')" -ForegroundColor Gray
        $global:LASTEXITCODE = 1
        throw "DestinationNamespace is required - provide -DestinationNamespace parameter or set DESTINATION_NAMESPACE environment variable"

    }
}

# Special handling for Destination - if not provided, try to get from ENVIRONMENT variable
if (-not [string]::IsNullOrWhiteSpace($Destination)) { 
    # $parsedParams['Destination'] = $Destination
    Write-Host "📋 Wrapper: Using provided Destination = $Destination" -ForegroundColor Cyan
} else {
    # Try to read ENVIRONMENT variable
    $envVar = $env:ENVIRONMENT
    if (-not [string]::IsNullOrWhiteSpace($envVar)) {
        $Destination = $envVar
        Write-Host "📋 Wrapper: Using DESTINATION variable as Destination = $Destination" -ForegroundColor Cyan
    } else {
        Write-Host "⚠️ Wrapper: No Destination provided and ENVIRONMENT variable not set" -ForegroundColor Yellow
        Write-Host "   1. Provide -Destination parameter (e.g., -Destination 'gov001')" -ForegroundColor Gray
        Write-Host "   2. Set ENVIRONMENT environment variable (e.g., export ENVIRONMENT='gov001')" -ForegroundColor Gray
        $global:LASTEXITCODE = 1
        throw "Destination is required - provide -Destination parameter or set ENVIRONMENT environment variable"
    }
}


# Special handling for InstanceAlias - if not provided, try to get from ENVIRONMENT variable
if (-not [string]::IsNullOrWhiteSpace($InstanceAlias)) { 
    # $parsedParams['InstanceAlias'] = $InstanceAlias 
    Write-Host "📋 Wrapper: Using provided InstanceAlias = $InstanceAlias" -ForegroundColor Cyan
} else {
    # Try to read ENVIRONMENT variable
    $envVar = $env:INSTANCE_ALIAS
    if (-not [string]::IsNullOrWhiteSpace($envVar)) {
        $InstanceAlias = $envVar
        Write-Host "📋 Wrapper: Using INSTANCE_ALIAS variable as InstanceAlias = $InstanceAlias" -ForegroundColor Cyan
    } else {
        Write-Host "⚠️ Wrapper: No InstanceAlias provided and INSTANCE_ALIAS variable not set" -ForegroundColor Yellow
        Write-Host "   1. Provide -InstanceAlias parameter (e.g., -InstanceAlias 'mil-space-dev')" -ForegroundColor Gray
        Write-Host "   2. Set INSTANCE_ALIAS environment variable (e.g., export INSTANCE_ALIAS='mil-space-dev')" -ForegroundColor Gray
        $global:LASTEXITCODE = 1
        throw "InstanceAlias is required - provide -InstanceAlias parameter or set INSTANCE_ALIAS environment variable"
    }
}

# Special handling for InstanceAliasToRemove - if not provided, try to get from AZURE_CLOUD_NAME environment variable
if (-not [string]::IsNullOrWhiteSpace($InstanceAliasToRemove)) { 
    # $parsedParams['InstanceAliasToRemove'] = $InstanceAliasToRemove 
    Write-Host "📋 Wrapper: Using provided InstanceAliasToRemove = $InstanceAliasToRemove" -ForegroundColor Cyan
} else {
    # Try to read ENVIRONMENT variable
    $envVar = $env:INSTANCE_ALIAS_TO_REMOVE
    if (-not [string]::IsNullOrWhiteSpace($envVar)) {
        $InstanceAliasToRemove = $envVar
        Write-Host "📋 Wrapper: Using INSTANCE_ALIAS_TO_REMOVE variable as InstanceAliasToRemove = $InstanceAliasToRemove" -ForegroundColor Cyan
    } else {
        Write-Host "⚠️ Wrapper: No InstanceAliasToRemove provided and INSTANCE_ALIAS_TO_REMOVE variable not set" -ForegroundColor Yellow
        Write-Host "   1. Provide -InstanceAliasToRemove parameter (e.g., -InstanceAliasToRemove 'mil-space-dev')" -ForegroundColor Gray
        Write-Host "   2. Set INSTANCE_ALIAS_TO_REMOVE environment variable (e.g., export INSTANCE_ALIAS_TO_REMOVE='mil-space-dev')" -ForegroundColor Gray
        $global:LASTEXITCODE = 1
        throw "InstanceAliasToRemove is required - provide -InstanceAliasToRemove parameter or set INSTANCE_ALIAS_TO_REMOVE environment variable"
    }
}

# Special handling for Cloud - if not provided, try to get from AZURE_CLOUD_NAME environment variable
if (-not [string]::IsNullOrWhiteSpace($Cloud)) { 
    # $parsedParams['Cloud'] = $Cloud 
    Write-Host "📋 Wrapper: Using provided Cloud = $Cloud" -ForegroundColor Cyan
} else {
    # Try to read ENVIRONMENT variable
    $envVar = $env:AZURE_CLOUD_NAME
    if (-not [string]::IsNullOrWhiteSpace($envVar)) {
        $Cloud = $envVar
        Write-Host "📋 Wrapper: Using AZURE_CLOUD_NAME variable as Cloud = $Cloud" -ForegroundColor Cyan
    } else {
        Write-Host "⚠️ Wrapper: No Cloud provided and AZURE_CLOUD_NAME variable not set" -ForegroundColor Yellow
        Write-Host "   1. Provide -Cloud parameter (e.g., -Cloud 'AzureCloud')" -ForegroundColor Gray
        Write-Host "   2. Set AZURE_CLOUD_NAME environment variable (e.g., export AZURE_CLOUD_NAME='AzureCloud')" -ForegroundColor Gray
        $global:LASTEXITCODE = 1
        throw "Cloud is required - provide -Cloud parameter or set AZURE_CLOUD_NAME environment variable"
    }
}

# SAFETY CHECK: Prevent Source = Destination (would overwrite source!)
if ($SourceNamespace -eq $DestinationNamespace) {
    Write-Host "" -ForegroundColor Red
    Write-Host "🚫 BLOCKED: Source and Destination cannot be the same!" -ForegroundColor Red
    Write-Host "   Source: $Source/$SourceNamespace" -ForegroundColor Yellow
    Write-Host "   Destination: $Destination/$DestinationNamespace" -ForegroundColor Yellow
    Write-Host "   This would overwrite the source environment and cause data loss!" -ForegroundColor Red
    Write-Host "   Please specify a different destination environment." -ForegroundColor Yellow
    $global:LASTEXITCODE = 1
    throw "SAFETY: SourceNamespace and DestinationNamespace must be different to prevent data loss"
}

# SAFETY CHECK: Prevent Source = Destination (would overwrite source!)
if ($Source -ne $Destination) {
    Write-Host "" -ForegroundColor Red
    Write-Host "🚫 BLOCKED: Source and Destination must be the same!" -ForegroundColor Red
    Write-Host "   Source: $Source/$SourceNamespace" -ForegroundColor Yellow
    Write-Host "   Destination: $Destination/$DestinationNamespace" -ForegroundColor Yellow
    Write-Host "   This would prevent the source environment from being restored!" -ForegroundColor Red
    Write-Host "   Please specify the same destination environment as the source environment." -ForegroundColor Yellow
    $global:LASTEXITCODE = 1
    throw "SAFETY: Source and Destination must be the same to prevent data loss"
}

if ($DestinationNamespace -eq "manufacturo") {
    Write-Host "" -ForegroundColor Red
    Write-Host "❌ FATAL ERROR: Destination namespace cannot be 'manufacturo'" -ForegroundColor Red
    Write-Host "   This is a protected namespace and cannot be used as a destination." -ForegroundColor Yellow
    Write-Host "   Please specify a different destination namespace." -ForegroundColor Yellow
    Write-Host "" -ForegroundColor Red
    Write-AutomationLog "❌ FATAL ERROR: Destination namespace 'manufacturo' is not allowed" "ERROR"
    $global:LASTEXITCODE = 1
    throw "Destination namespace 'manufacturo' is not allowed - this is a protected namespace"
}

# Call the main script with splatting - only passes parameters that have values
& $selfServiceScript -RestoreDateTime $RestoreDateTime -Timezone $Timezone -SourceNamespace $SourceNamespace -Source $Source -DestinationNamespace $DestinationNamespace -Destination $Destination -InstanceAlias $InstanceAlias -InstanceAliasToRemove $InstanceAliasToRemove -Cloud $Cloud -DryRun:$DryRun -MaxWaitMinutes $MaxWaitMinutes

Write-Host "✅ Semaphore wrapper completed" -ForegroundColor Green
