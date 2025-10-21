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

.PARAMETER CustomerAlias
    Customer alias for this refresh

.PARAMETER CustomerAliasToRemove
    Customer alias to remove (optional)

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
$CustomerAlias = if ($parsedParams.ContainsKey("CustomerAlias")) { $parsedParams["CustomerAlias"] } else { "" }
$CustomerAliasToRemove = if ($parsedParams.ContainsKey("CustomerAliasToRemove")) { $parsedParams["CustomerAliasToRemove"] } else { "" }
$Cloud = if ($parsedParams.ContainsKey("Cloud")) { $parsedParams["Cloud"] } else { "" }
$DryRun = if ($parsedParams.ContainsKey("DryRun")) { 
    $dryRunValue = $parsedParams["DryRun"]
    $dryRunBool = if ($dryRunValue -eq "true" -or $dryRunValue -eq $true) { $true } else { $false }
    # Write-Host "🔧 Converted DryRun: '$dryRunValue' → $dryRunBool" -ForegroundColor Yellow
    $dryRunBool
} else { 
    Write-Host "🔧 Using default DryRun: true" -ForegroundColor Yellow
    $true 
}
$MaxWaitMinutes = if ($parsedParams.ContainsKey("MaxWaitMinutes")) { $parsedParams["MaxWaitMinutes"] } else { "" }
$UseSasTokens = if ($parsedParams.ContainsKey("UseSasTokens")) { 
    $useSasValue = $parsedParams["UseSasTokens"]
    $useSasBool = if ($useSasValue -eq "true" -or $useSasValue -eq $true) { $true } else { $false }
    $useSasBool
} else { 
    $false 
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
Write-Host "  CustomerAlias: $CustomerAlias" -ForegroundColor Gray
Write-Host "  CustomerAliasToRemove: $CustomerAliasToRemove" -ForegroundColor Gray
Write-Host "  Cloud: $Cloud" -ForegroundColor Gray
Write-Host "  DryRun: $DryRun" -ForegroundColor Gray
Write-Host "  UseSasTokens: $UseSasTokens" -ForegroundColor Gray
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
    throw "self_service.ps1 not found - repository may not be properly initialized"
}

# Convert MaxWaitMinutes to integer
$MaxWaitMinutesInt = 60  # Default value
if (-not [string]::IsNullOrWhiteSpace($MaxWaitMinutes)) {
    try {
        $MaxWaitMinutesInt = [int]::Parse($MaxWaitMinutes)
    } catch {
        Write-Host "⚠️ Could not parse MaxWaitMinutes '$MaxWaitMinutes', using default: 60" -ForegroundColor Yellow
        $MaxWaitMinutesInt = 60
    }
}

Write-Host "🚀 Calling self_service.ps1 with converted parameters..." -ForegroundColor Green

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

# Normalize RestoreDateTime if provided
if (-not [string]::IsNullOrWhiteSpace($RestoreDateTime)) {
    $RestoreDateTime = Normalize-DateTime -InputDateTime $RestoreDateTime
}

# ============================================================================
# TIMEZONE VALIDATION AND DEFAULTING
# ============================================================================

# Get effective timezone (user-provided or from environment)
$effectiveTimezone = ""
if (-not [string]::IsNullOrWhiteSpace($Timezone)) {
    # User provided timezone - use it (user override wins)
    $effectiveTimezone = $Timezone
    Write-Host "🕐 Using user-provided timezone: $effectiveTimezone" -ForegroundColor Yellow
} else {
    # Check for SEMAPHORE_SCHEDULE_TIMEZONE environment variable
    $envTimezone = [System.Environment]::GetEnvironmentVariable("SEMAPHORE_SCHEDULE_TIMEZONE")
    if (-not [string]::IsNullOrWhiteSpace($envTimezone)) {
        $effectiveTimezone = $envTimezone
        Write-Host "🕐 Using timezone from SEMAPHORE_SCHEDULE_TIMEZONE: $effectiveTimezone" -ForegroundColor Green
    } else {
        # Only fail if RestoreDateTime is provided (timezone is needed)
        if (-not [string]::IsNullOrWhiteSpace($RestoreDateTime)) {
            Write-Host "" -ForegroundColor Red
            Write-Host "❌ FATAL ERROR: Timezone not provided and SEMAPHORE_SCHEDULE_TIMEZONE not set" -ForegroundColor Red
            Write-Host "   Restore operations require a timezone to prevent incorrect restore points." -ForegroundColor Yellow
            Write-Host "   Please either:" -ForegroundColor Yellow
            Write-Host "   1. Set SEMAPHORE_SCHEDULE_TIMEZONE environment variable" -ForegroundColor Gray
            Write-Host "   2. Provide Timezone parameter explicitly" -ForegroundColor Gray
            Write-Host "" -ForegroundColor Red
            $global:LASTEXITCODE = 1
            throw "Timezone not provided and SEMAPHORE_SCHEDULE_TIMEZONE not set - restore operations require a timezone"
        }
        # If no RestoreDateTime, timezone not needed
    }
}

# Build parameter hashtable - only include non-empty values
$scriptParams = @{}
if (-not [string]::IsNullOrWhiteSpace($RestoreDateTime)) { $scriptParams['RestoreDateTime'] = $RestoreDateTime }
if (-not [string]::IsNullOrWhiteSpace($effectiveTimezone)) { $scriptParams['Timezone'] = $effectiveTimezone }
if (-not [string]::IsNullOrWhiteSpace($SourceNamespace)) { $scriptParams['SourceNamespace'] = $SourceNamespace }

# Special handling for Source - if not provided, try to get from ENVIRONMENT variable
if (-not [string]::IsNullOrWhiteSpace($Source)) { 
    $scriptParams['Source'] = $Source 
    Write-Host "📋 Wrapper: Using provided Source = $Source" -ForegroundColor Cyan
} else {
    # Try to read ENVIRONMENT variable
    $envVar = [System.Environment]::GetEnvironmentVariable("ENVIRONMENT")
    if (-not [string]::IsNullOrWhiteSpace($envVar)) {
        $scriptParams['Source'] = $envVar
        Write-Host "📋 Wrapper: Using ENVIRONMENT variable as Source = $envVar" -ForegroundColor Cyan
    } else {
        Write-Host "⚠️ Wrapper: No Source provided and ENVIRONMENT variable not set" -ForegroundColor Yellow
    }
}

if (-not [string]::IsNullOrWhiteSpace($DestinationNamespace)) { $scriptParams['DestinationNamespace'] = $DestinationNamespace }
if (-not [string]::IsNullOrWhiteSpace($Destination)) { $scriptParams['Destination'] = $Destination }
if (-not [string]::IsNullOrWhiteSpace($CustomerAlias)) { $scriptParams['CustomerAlias'] = $CustomerAlias }
if (-not [string]::IsNullOrWhiteSpace($CustomerAliasToRemove)) { $scriptParams['CustomerAliasToRemove'] = $CustomerAliasToRemove }
if (-not [string]::IsNullOrWhiteSpace($Cloud)) { $scriptParams['Cloud'] = $Cloud }
$scriptParams['DryRun'] = $DryRun
$scriptParams['UseSasTokens'] = $UseSasTokens
$scriptParams['MaxWaitMinutes'] = $MaxWaitMinutesInt

# Call the main script with splatting - only passes parameters that have values
& $selfServiceScript @scriptParams

Write-Host "✅ Semaphore wrapper completed" -ForegroundColor Green
