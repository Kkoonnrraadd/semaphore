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

# Extract parameters with defaults
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
    Write-Host "🔧 Converted DryRun: '$dryRunValue' → $dryRunBool" -ForegroundColor Yellow
    $dryRunBool
} else { 
    Write-Host "🔧 Using default DryRun: true" -ForegroundColor Yellow
    $true 
}
$MaxWaitMinutes = if ($parsedParams.ContainsKey("MaxWaitMinutes")) { $parsedParams["MaxWaitMinutes"] } else { "40" }
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
Write-Host "  MaxWaitMinutes: $MaxWaitMinutes" -ForegroundColor Gray
if ($production_confirm) {
    Write-Host "  production_confirm: $production_confirm" -ForegroundColor Gray
}

# Get the directory of this script
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$selfServiceScript = Join-Path $scriptDir "self_service.ps1"

# Convert MaxWaitMinutes to integer
$MaxWaitMinutesInt = 40  # Default value
if (-not [string]::IsNullOrWhiteSpace($MaxWaitMinutes)) {
    if ([int]::TryParse($MaxWaitMinutes, [ref]$MaxWaitMinutesInt)) {
        Write-Host "🔧 Converted MaxWaitMinutes: '$MaxWaitMinutes' → $MaxWaitMinutesInt" -ForegroundColor Yellow
    } else {
        Write-Host "⚠️ Could not parse MaxWaitMinutes '$MaxWaitMinutes', using default: 40" -ForegroundColor Yellow
        $MaxWaitMinutesInt = 40
    }
}

Write-Host "🚀 Calling self_service.ps1 with converted parameters..." -ForegroundColor Green

# Call the main script with named parameters
& $selfServiceScript `
    -RestoreDateTime $RestoreDateTime `
    -Timezone $Timezone `
    -SourceNamespace $SourceNamespace `
    -Source $Source `
    -DestinationNamespace $DestinationNamespace `
    -Destination $Destination `
    -CustomerAlias $CustomerAlias `
    -CustomerAliasToRemove $CustomerAliasToRemove `
    -Cloud $Cloud `
    -DryRun:$DryRun `
    -MaxWaitMinutes $MaxWaitMinutesInt

Write-Host "✅ Semaphore wrapper completed" -ForegroundColor Green
