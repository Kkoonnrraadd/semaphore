<#
.SYNOPSIS
    Self-Service Data Refresh Script for Azure SQL Databases

.DESCRIPTION
    This script performs a complete data refresh operation including database restoration,
    environment management, and resource configuration.

.PARAMETER SourceNamespace
    Source namespace identifier (required, defaults to "manufacturo" if empty)

.PARAMETER Source
    Source environment name (default: "qa2")

.PARAMETER DestinationNamespace
    Destination namespace identifier (required, defaults to "manufacturo" if empty)

.PARAMETER Destination
    Destination environment name (default: "qa2")

.PARAMETER CustomerAlias
    Customer alias for resource configuration (defaults to INSTANCE_ALIAS environment variable if not provided)

.PARAMETER CustomerAliasToRemove
    Customer alias to remove from source environment during cleanup

.PARAMETER Cloud
    Azure cloud environment: AzureCloud or AzureUSGovernment (default: "AzureCloud")


.PARAMETER DryRun
    Run in dry-run mode to preview what would be executed without making changes


.PARAMETER MaxWaitMinutes
    Maximum wait time in minutes for database restoration (default: 30)

.EXAMPLE
    .\self_service.ps1 -Source "qa2" -Destination "dev" -DryRun

.EXAMPLE
    .\self_service.ps1 -Source "qa2" -Destination "dev" -MaxWaitMinutes 15

.EXAMPLE
    .\self_service.ps1 -Source "qa2" -Destination "dev" -CustomerAlias "dev" -CustomerAliasToRemove "qa2" -DryRun

.NOTES
    - Default restore point is 15 minutes ago in the current system timezone
    - Use -DryRun to preview operations without executing them
#>

param (
    [AllowEmptyString()][string]$RestoreDateTime,  # Format: "yyyy-MM-dd HH:mm:ss" - empty uses 15 min ago
    [AllowEmptyString()][string]$Timezone,         # Empty uses system timezone
    [AllowEmptyString()][string]$SourceNamespace,
    [AllowEmptyString()][string]$Source,
    [AllowEmptyString()][string]$DestinationNamespace,
    [AllowEmptyString()][string]$Destination,
    [AllowEmptyString()][string]$CustomerAlias,
    [AllowEmptyString()][string]$CustomerAliasToRemove,
    [AllowEmptyString()][string]$Cloud,
    [switch]$DryRun=$true,
    [switch]$UseSasTokens=$false,  # Use SAS tokens for 3TB+ container copies (8-hour validity)
    [int]$MaxWaitMinutes = 60,
    # 🤖 AUTOMATION PARAMETERS - prevents interactive prompts
    [string]$LogFile = "/tmp/self_service_$(Get-Date -Format 'yyyy-MM-dd_HH-mm-ss').log"           # Custom log file path for automation
)

# ═══════════════════════════════════════════════════════════════════════════
# IMPORT REQUIRED MODULES AND UTILITIES
# ═══════════════════════════════════════════════════════════════════════════

# 📚 Load Automation Utilities (logging, prerequisites, datetime handling)
$automationUtilitiesScript = Join-Path $PSScriptRoot "../common/AutomationUtilities.ps1"
if (-not (Test-Path $automationUtilitiesScript)) {
    Write-Host "❌ FATAL ERROR: Automation utilities script not found at: $automationUtilitiesScript" -ForegroundColor Red
    Write-Host "   This file is required for logging and automation functions." -ForegroundColor Yellow
    $global:LASTEXITCODE = 1
    throw "Automation utilities script not found at: $automationUtilitiesScript"
}
. $automationUtilitiesScript

# ═══════════════════════════════════════════════════════════════════════════
# EARLY PARAMETER VALIDATION (Before Azure Connection)
# ═══════════════════════════════════════════════════════════════════════════

Write-Host "🔧 Validating provided parameters..." -ForegroundColor Yellow

# Store original user-provided values before any auto-detection
$script:OriginalSource = $Source
$script:OriginalDestination = $Destination
$script:OriginalSourceNamespace = $SourceNamespace
$script:OriginalDestinationNamespace = $DestinationNamespace
$script:OriginalCloud = $Cloud
$script:OriginalCustomerAlias = $CustomerAlias
$script:OriginalCustomerAliasToRemove = $CustomerAliasToRemove
$script:OriginalRestoreDateTime = $RestoreDateTime
$script:OriginalTimezone = $Timezone


if ([string]::IsNullOrWhiteSpace($script:OriginalCustomerAliasToRemove)) {
    if (-not [string]::IsNullOrWhiteSpace($env:INSTANCE_ALIAS_TO_REMOVE)) {
        $script:CustomerAliasToRemove = $env:INSTANCE_ALIAS_TO_REMOVE
        Write-Host "📋 CustomerAliasToRemove: '$($script:CustomerAliasToRemove)' ← From INSTANCE_ALIAS_TO_REMOVE environment variable" -ForegroundColor Yellow
    } else {
        Write-Host "❌ FATAL ERROR: CustomerAliasToRemove is required" -ForegroundColor Red
        Write-Host "   Please either:" -ForegroundColor Yellow
        Write-Host "   1. Provide -CustomerAliasToRemove parameter (e.g., -CustomerAliasToRemove 'mil-space')" -ForegroundColor Gray
        Write-Host "   2. Set INSTANCE_ALIAS_TO_REMOVE environment variable (e.g., export INSTANCE_ALIAS_TO_REMOVE='mil-space')" -ForegroundColor Gray
        $global:LASTEXITCODE = 1
        throw "CustomerAliasToRemove is required - provide -CustomerAliasToRemove parameter or set INSTANCE_ALIAS_TO_REMOVE environment variable"
    }
} else {
    $script:CustomerAliasToRemove = $script:OriginalCustomerAliasToRemove
}

# Apply CustomerAlias with fallback to INSTANCE_ALIAS environment variable
if ([string]::IsNullOrWhiteSpace($script:OriginalCustomerAlias)) {
    if (-not [string]::IsNullOrWhiteSpace($env:INSTANCE_ALIAS)) {
        $script:CustomerAlias = $env:INSTANCE_ALIAS
        Write-Host "📋 CustomerAlias: '$($script:CustomerAlias)' ← From INSTANCE_ALIAS environment variable" -ForegroundColor Yellow
    } else {
        Write-Host "❌ FATAL ERROR: CustomerAlias is required" -ForegroundColor Red
        Write-Host "   Please either:" -ForegroundColor Yellow
        Write-Host "   1. Provide -CustomerAlias parameter (e.g., -CustomerAlias 'mil-space-dev')" -ForegroundColor Gray
        Write-Host "   2. Set INSTANCE_ALIAS environment variable (e.g., export INSTANCE_ALIAS='mil-space-dev')" -ForegroundColor Gray
        $global:LASTEXITCODE = 1
        throw "CustomerAlias is required - provide -CustomerAlias parameter or set INSTANCE_ALIAS environment variable"
    }
} else {
    $script:CustomerAlias = $script:OriginalCustomerAlias
}


    # Determine target environment with correct priority:
    # 1. User-provided Source parameter (highest priority)
    # 2. ENVIRONMENT variable (fallback)
if (-not [string]::IsNullOrWhiteSpace($script:OriginalSource)) {
    $script:OriginalSource = $script:OriginalSource.ToLower()
    Write-Host "📋 Source: $script:OriginalSource (from USER-PROVIDED Source)" -ForegroundColor Gray
} elseif (-not [string]::IsNullOrWhiteSpace($env:ENVIRONMENT)) {
    $script:OriginalSource = $env:ENVIRONMENT.ToLower()
    Write-Host "📋 Source: $script:OriginalSource (from ENVIRONMENT variable)" -ForegroundColor Gray
} else {
    Write-Host "" -ForegroundColor Red
    Write-Host "❌ FATAL ERROR: No environment specified" -ForegroundColor Red
    Write-Host "   Cannot grant permissions without knowing the environment" -ForegroundColor Yellow
    Write-Host "   Please either:" -ForegroundColor Yellow
    Write-Host "   1. Provide -Source parameter (e.g., -Source 'gov001')" -ForegroundColor Gray
    Write-Host "   2. Set ENVIRONMENT variable (e.g., export ENVIRONMENT='gov001')" -ForegroundColor Gray
    Write-Host "" -ForegroundColor Red
    Write-AutomationLog "❌ FATAL ERROR: No environment specified for permission grant" "ERROR"
    $global:LASTEXITCODE = 1
    throw "Cannot proceed without environment specification for permission granting"
    
}

# ═══════════════════════════════════════════════════════════════════════════
# HELPER FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════

# 📁 HELPER FUNCTION: Get absolute script path
# function Get-ScriptPath {
#     param([string]$RelativePath)
#     if ($global:ScriptBaseDir) {
#         return Join-Path $global:ScriptBaseDir $RelativePath
#     } else {
#         # Use current script directory structure (scripts/main -> scripts)
#         $scriptDir = Split-Path $PSScriptRoot -Parent
#         $fullPath = Join-Path $scriptDir $RelativePath
#         return $fullPath
#     }
# }

function Perform-Migration {
    
    # ═══════════════════════════════════════════════════════════════════════════
    # SET UP SCRIPT BASE DIRECTORY
    # ═══════════════════════════════════════════════════════════════════════════
    
    # Get the current script's directory for all script paths
    $currentScript = $MyInvocation.MyCommand.Path
    if ($currentScript) {
        $scriptDir = Split-Path -Parent $currentScript
        $global:ScriptBaseDir = Split-Path -Parent $scriptDir  # Go up one level from main/ to scripts/
        Write-Host "🔍 Script base directory: $global:ScriptBaseDir" -ForegroundColor Gray
    } elseif ($PSScriptRoot) {
        # Use PSScriptRoot as fallback
        $global:ScriptBaseDir = Split-Path -Parent $PSScriptRoot  # Go up one level from main/ to scripts/
        Write-Host "🔍 Script base directory (from PSScriptRoot): $global:ScriptBaseDir" -ForegroundColor Gray
    } else {
        # Fallback: try new PowerShell-only structure
        $global:ScriptBaseDir = "/scripts"
        Write-Host "🔍 Using fallback paths - Base: $global:ScriptBaseDir" -ForegroundColor Gray
    }
    
    # ═══════════════════════════════════════════════════════════════════════════
    # STEPS 0A, 0B, 0C: RUN PREREQUISITE STEPS (Using unified module)
    # ═══════════════════════════════════════════════════════════════════════════
    
    Write-AutomationLog "🔐 Running prerequisite steps (permissions, authentication, parameter detection)" "INFO"
    
    # Call the unified prerequisite steps script
    # NOTE: This ALWAYS runs, even in dry-run mode, because:
    # 1. Permissions are needed for subsequent Azure operations
    # 2. Azure Function call is safe (idempotent)
    # 3. No actual infrastructure changes
    $prerequisiteScript = Get-ScriptPath "common/Invoke-PrerequisiteSteps.ps1"
    if (-not (Test-Path $prerequisiteScript)) {
        Write-AutomationLog "❌ FATAL ERROR: Prerequisite script not found at $prerequisiteScript" "ERROR"
        throw "Prerequisite script not found at: $prerequisiteScript"
    }
    
    # Build parameters for prerequisite script
    $prereqParams = @{
        Source = $script:OriginalSource
        Destination = $script:OriginalDestination
        SourceNamespace = $script:OriginalSourceNamespace
        DestinationNamespace = $script:OriginalDestinationNamespace
        RestoreDateTime = $script:OriginalRestoreDateTime
        Timezone = $script:OriginalTimezone
        Cloud = $script:OriginalCloud
    }
    
    $prerequisiteResult = & $prerequisiteScript `
        -Parameters $prereqParams
    
    if (-not $prerequisiteResult.Success) {
        Write-AutomationLog "❌ FATAL ERROR: Prerequisite steps failed" "ERROR"
        Write-AutomationLog "📍 Error: $($prerequisiteResult.Error)" "ERROR"
        throw "Prerequisite steps failed: $($prerequisiteResult.Error)"
    }
    
    Write-AutomationLog "✅ Prerequisite steps completed successfully" "SUCCESS"
    
    # Extract detected parameters
    $detectedParams = $prerequisiteResult.DetectedParameters
    
    # ═══════════════════════════════════════════════════════════════════════════
    # MERGE USER-PROVIDED AND AUTO-DETECTED PARAMETERS
    # ═══════════════════════════════════════════════════════════════════════════
    
    # Apply detected values, but allow user-provided values to override
    Write-Host "`n🔀 Merging user-provided values with auto-detected values..." -ForegroundColor Cyan
    
    # Source
    if (-not [string]::IsNullOrWhiteSpace($script:OriginalSource)) {
        $script:Source = $script:OriginalSource
        Write-Host "   Source: '$($script:Source)' ← USER PROVIDED ✅" -ForegroundColor Green
    } else {
        $script:Source = $detectedParams.Source
        Write-Host "   Source: '$($script:Source)' ← Auto-detected from Azure" -ForegroundColor Yellow
    }
    
    # SourceNamespace
    if (-not [string]::IsNullOrWhiteSpace($script:OriginalSourceNamespace)) {
        $script:SourceNamespace = $script:OriginalSourceNamespace
        Write-Host "   SourceNamespace: '$($script:SourceNamespace)' ← USER PROVIDED ✅" -ForegroundColor Green
    } else {
        $script:SourceNamespace = $detectedParams.SourceNamespace
        Write-Host "   SourceNamespace: '$($script:SourceNamespace)' ← Default (org standard)" -ForegroundColor Yellow
    }
    
    # Destination
    if (-not [string]::IsNullOrWhiteSpace($script:OriginalDestination)) {
        $script:Destination = $script:OriginalDestination
        Write-Host "   Destination: '$($script:Destination)' ← USER PROVIDED ✅" -ForegroundColor Green
    } else {
        $script:Destination = $detectedParams.Destination
        Write-Host "   Destination: '$($script:Source)' ← Auto-detected (same as Source)" -ForegroundColor Yellow
    }
    
    # DestinationNamespace
    if (-not [string]::IsNullOrWhiteSpace($script:OriginalDestinationNamespace)) {
        $script:DestinationNamespace = $script:OriginalDestinationNamespace
        Write-Host "   DestinationNamespace: '$($script:DestinationNamespace)' ← USER PROVIDED ✅" -ForegroundColor Green
    } else {
        $script:DestinationNamespace = $detectedParams.DestinationNamespace
        Write-Host "   DestinationNamespace: '$($script:DestinationNamespace)' ← Default (org standard)" -ForegroundColor Yellow
    }
    
    if ($script:DestinationNamespace -eq "manufacturo") {
        Write-Host "" -ForegroundColor Red
        Write-Host "❌ FATAL ERROR: Destination namespace cannot be 'manufacturo'" -ForegroundColor Red
        Write-Host "   This is a protected namespace and cannot be used as a destination." -ForegroundColor Yellow
        Write-Host "   Please specify a different destination namespace." -ForegroundColor Yellow
        Write-Host "" -ForegroundColor Red
        Write-AutomationLog "❌ FATAL ERROR: Destination namespace 'manufacturo' is not allowed" "ERROR"
        $global:LASTEXITCODE = 1
        throw "Destination namespace 'manufacturo' is not allowed - this is a protected namespace"
    }

    # Cloud
    if (-not [string]::IsNullOrWhiteSpace($script:OriginalCloud)) {
        $script:Cloud = $script:OriginalCloud
        Write-Host "   Cloud: '$($script:Cloud)' ← USER PROVIDED ✅" -ForegroundColor Green
    } else {
        $script:Cloud = $detectedParams.Cloud
        Write-Host "   Cloud: '$($script:Cloud)' ← Auto-detected from Azure CLI" -ForegroundColor Yellow
    }
    
    # Apply default values for time-sensitive parameters if not provided by user
    $script:RestoreDateTime = if (-not [string]::IsNullOrWhiteSpace($RestoreDateTime)) { $RestoreDateTime } else { $detectedParams.DefaultRestoreDateTime }
    $script:Timezone = if (-not [string]::IsNullOrWhiteSpace($Timezone)) { $Timezone } else { $detectedParams.DefaultTimezone }
    
    Write-Host "✅ Parameters auto-detected and configured" -ForegroundColor Green
    Write-Host "📋 Final parameters:" -ForegroundColor Cyan
    Write-Host "   Source: $($script:Source) / $($script:SourceNamespace)" -ForegroundColor Gray
    Write-Host "   Destination: $($script:Destination) / $($script:DestinationNamespace)" -ForegroundColor Gray
    Write-Host "   Cloud: $($script:Cloud)" -ForegroundColor Gray
    Write-Host "   Customer Alias: $($script:CustomerAlias)" -ForegroundColor Gray
    Write-Host "   Customer Alias to Remove: $($script:CustomerAliasToRemove)" -ForegroundColor Gray
    Write-Host "   Restore DateTime: $($script:RestoreDateTime) ($($script:Timezone))" -ForegroundColor Gray
    Write-Host "   Max Wait Minutes: $($script:MaxWaitMinutes)" -ForegroundColor Gray
    
    # Log final parameters
    Write-AutomationLog "📋 Final Parameters: Source=$($script:Source)/$($script:SourceNamespace) → Destination=$($script:Destination)/$($script:DestinationNamespace)" "INFO"
    Write-AutomationLog "☁️  Cloud: $($script:Cloud) | DryRun: $DryRun" "INFO"
    
    # ═══════════════════════════════════════════════════════════════════════════
    # STEP 0E: VALIDATE PREREQUISITES
    # ═══════════════════════════════════════════════════════════════════════════
    
    Write-AutomationLog "🔍 DryRun mode: $DryRun" "INFO"
    if (-not $DryRun) {
        Write-AutomationLog "🔍 Running prerequisites check (not in dry-run mode)" "INFO"
        Test-Prerequisites -DryRun:$DryRun
    } else {
        Write-AutomationLog "🔍 Skipping prerequisites check in dry-run mode" "INFO"
    }
    
    # Set domain based on cloud environment for downstream scripts
    switch ($script:Cloud) {
        'AzureCloud' {
            $Domain = 'cloud'
        }
        'AzureUSGovernment' {
            $Domain = 'us'
        }
        default {
            $Domain = ''
        }
    }

    Invoke-Migration `
        -Cloud $script:Cloud `
        -Source $script:Source `
        -Destination $script:Destination `
        -CustomerAlias $script:CustomerAlias `
        -CustomerAliasToRemove $script:CustomerAliasToRemove `
        -SourceNamespace $script:SourceNamespace `
        -DestinationNamespace $script:DestinationNamespace `
        -Domain $Domain `
        -DryRun:($DryRun -eq $true) `
        -MaxWaitMinutes $MaxWaitMinutes `
        -RestoreDateTime $script:RestoreDateTime `
        -Timezone $script:Timezone
}

function Invoke-Migration {
    param (
        [string]$Cloud,
        [string]$Source,
        [string]$Destination,
        [AllowEmptyString()][string]$CustomerAlias,
        [AllowEmptyString()][string]$CustomerAliasToRemove,
        [string]$SourceNamespace,
        [string]$DestinationNamespace,
        [string]$Domain,
        [switch]$DryRun,
        [int]$MaxWaitMinutes,
        [string]$RestoreDateTime,
        [string]$Timezone
    )

    Write-Host "`n═══════════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "🔁 Running self-service data refresh" -ForegroundColor Yellow
    Write-Host "═══════════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "▶️ Source: $Source / $SourceNamespace" -ForegroundColor Gray
    Write-Host "▶️ Destination: $Destination / $DestinationNamespace" -ForegroundColor Gray
    Write-Host "☁️ Cloud: $Cloud" -ForegroundColor Gray
    Write-Host "🌐 Domain: $Domain" -ForegroundColor Gray
    Write-Host "👤 Customer Alias: $CustomerAlias" -ForegroundColor Gray
    Write-Host "🗑️ Customer Alias to Remove: $CustomerAliasToRemove" -ForegroundColor Gray
    Write-Host "📅 Restore DateTime: $RestoreDateTime ($Timezone)" -ForegroundColor Gray
    Write-Host "🕐 Timezone: $Timezone" -ForegroundColor Gray
    Write-Host "⏱️ Max Wait Time: $MaxWaitMinutes minutes" -ForegroundColor Gray
    Write-Host "🔍 UseSasTokens: $UseSasTokens" -ForegroundColor Gray
    
    if ($DryRun) {
        Write-Host "🔍 DRY RUN MODE ENABLED - No actual changes will be made" -ForegroundColor Yellow
    }
    Write-Host "═══════════════════════════════════════════════════════════════════════════`n" -ForegroundColor Cyan
    
    # Step 1: Restore Point in Time
    Write-Host "`n🔄 STEP 1: RESTORE POINT IN TIME" -ForegroundColor Cyan
    if ($DryRun) {
        Write-Host "🔍 DRY RUN: Would execute restore point in time" -ForegroundColor Yellow
        Write-Host "🔍 DRY RUN: Restore DateTime: $RestoreDateTime" -ForegroundColor Gray
        Write-Host "🔍 DRY RUN: Timezone: $Timezone" -ForegroundColor Gray
        Write-Host "🔍 DRY RUN: Source: $Source / $SourceNamespace" -ForegroundColor Gray
        Write-Host "🔍 DRY RUN: Would restore databases to point in time with '-restored' suffix" -ForegroundColor Gray
        Write-Host "🔍 DRY RUN: Would wait up to $MaxWaitMinutes minutes for restoration" -ForegroundColor Gray
        $scriptPath = Get-ScriptPath "restore/RestorePointInTime.ps1"
        & $scriptPath -Source $Source -SourceNamespace $SourceNamespace -RestoreDateTime $RestoreDateTime -Timezone $Timezone -DryRun:$DryRun -MaxWaitMinutes $MaxWaitMinutes
    } else {
        $scriptPath = Get-ScriptPath "restore/RestorePointInTime.ps1"
        & $scriptPath -Source $Source -SourceNamespace $SourceNamespace -RestoreDateTime $RestoreDateTime -Timezone $Timezone -DryRun:$DryRun -MaxWaitMinutes $MaxWaitMinutes
    }
    
    # Step 2: Stop Environment
    Write-Host "`n🔄 STEP 2: STOP ENVIRONMENT" -ForegroundColor Cyan
    if ($DryRun) {
        Write-Host "🔍 DRY RUN: Would stop environment" -ForegroundColor Yellow
        $scriptPath = Get-ScriptPath "environment/StopEnvironment.ps1"
        & $scriptPath  $Destination Namespace $DestinationNamespace -Cloud $Cloud -DryRun:($DryRun -eq $true)
    } else {
        $scriptPath = Get-ScriptPath "environment/StopEnvironment.ps1"
        & $scriptPath  $Destination Namespace $DestinationNamespace -Cloud $Cloud 
    }
    
    # Step 3: Copy Attachments
    Write-Host "`n🔄 STEP 3: COPY ATTACHMENTS" -ForegroundColor Cyan
    
    # Build parameter hashtable for CopyAttachments
    $copyParams = @{
        source = $Source
        Destination = $Destination
        SourceNamespace = $SourceNamespace
        DestinationNamespace = $DestinationNamespace
    }
    
    # Add UseSasTokens if specified (for 3TB+ containers)
    if ($UseSasTokens -eq $true) {
        $copyParams['UseSasTokens'] = $true
        Write-Host "🔐 SAS Token Mode: Enabled (for large containers)" -ForegroundColor Magenta
    }
    
    # Add DryRun if enabled
    if ($DryRun) {
        Write-Host "🔍 DRY RUN: Would copy attachments" -ForegroundColor Yellow
        $copyParams['DryRun'] = $true
    }
    
    $scriptPath = Get-ScriptPath "storage/CopyAttachments.ps1"
    & $scriptPath @copyParams
    
    # Step 4: Copy Database
    Write-Host "`n🔄 STEP 4: COPY DATABASE" -ForegroundColor Cyan
    if ($DryRun) {
        Write-Host "🔍 DRY RUN: Would copy database" -ForegroundColor Yellow
        $scriptPath = Get-ScriptPath "database/copy_database.ps1"
        & $scriptPath -Source $Source  $Destination -SourceNamespace $SourceNamespace -DestinationNamespace $DestinationNamespace -DryRun:($DryRun -eq $true)
    } else {
        $scriptPath = Get-ScriptPath "database/copy_database.ps1"
        & $scriptPath -Source $Source  $Destination -SourceNamespace $SourceNamespace -DestinationNamespace $DestinationNamespace
    }
    
    # Step 5: Cleanup Environment Configuration
    Write-Host "`n🔄 STEP 5: CLEANUP ENVIRONMENT CONFIGURATION" -ForegroundColor Cyan
    if ($DryRun) {
        Write-Host "🔍 DRY RUN: Would cleanup source environment configurations" -ForegroundColor Yellow
        Write-Host "🔍 DRY RUN: Removing CORS origins and redirect URIs for: $Source" -ForegroundColor Gray
        if (-not [string]::IsNullOrWhiteSpace($SourceNamespace)) {
            Write-Host "🔍 DRY RUN: Source multitenant: $SourceNamespace" -ForegroundColor Gray
        }
        if (-not [string]::IsNullOrWhiteSpace($CustomerAliasToRemove)) {
            Write-Host "🔍 DRY RUN: Customer alias to remove: $CustomerAliasToRemove" -ForegroundColor Gray
        } else {
            Write-Host "🔍 DRY RUN: No customer alias specified for removal" -ForegroundColor Gray
        }
        $scriptPath = Get-ScriptPath "configuration/cleanup_environment_config.ps1"
        & $scriptPath  $Destination -Source $Source -SourceNamespace $SourceNamespace -CustomerAliasToRemove $CustomerAliasToRemove -Domain $Domain -DestinationNamespace $DestinationNamespace -DryRun:($DryRun -eq $true)
    } else {
        $scriptPath = Get-ScriptPath "configuration/cleanup_environment_config.ps1"
        & $scriptPath  $Destination -Source $Source -SourceNamespace $SourceNamespace -CustomerAliasToRemove $CustomerAliasToRemove -Domain $Domain -DestinationNamespace $DestinationNamespace
    }
    
    # Step 6: Revert SQL Users
    Write-Host "`n🔄 STEP 6: REVERT SQL USERS" -ForegroundColor Cyan
    if ($DryRun) {
        Write-Host "🔍 DRY RUN: Would revert source environment SQL users" -ForegroundColor Yellow
        Write-Host "🔍 DRY RUN: Removing database users and roles for: $Source" -ForegroundColor Gray
        Write-Host "🔍 DRY RUN: Source multitenant: $SourceNamespace" -ForegroundColor Gray
        $scriptPath = Get-ScriptPath "configuration/sql_configure_users.ps1"
        & $scriptPath  $Destination -DestinationNamespace $DestinationNamespace -Revert -Source $Source -SourceNamespace $SourceNamespace -AutoApprove -StopOnFailure -DryRun:($DryRun -eq $true)
    } else {
        $scriptPath = Get-ScriptPath "configuration/sql_configure_users.ps1"
        & $scriptPath  $Destination -DestinationNamespace $DestinationNamespace -Revert -Source $Source -SourceNamespace $SourceNamespace -AutoApprove -StopOnFailure
    }
    
    # Step 7: Adjust Resources
    Write-Host "`n🔄 STEP 7: ADJUST RESOURCES" -ForegroundColor Cyan
    if ($DryRun) {
        Write-Host "🔍 DRY RUN: Would adjust database resources" -ForegroundColor Yellow
        $scriptPath = Get-ScriptPath "configuration/adjust_db.ps1"
        & $scriptPath -Domain $Domain -CustomerAlias $CustomerAlias  $Destination -DestinationNamespace $DestinationNamespace -DryRun:($DryRun -eq $true)
    } else {
        $scriptPath = Get-ScriptPath "configuration/adjust_db.ps1"
        & $scriptPath -Domain $Domain -CustomerAlias $CustomerAlias  $Destination -DestinationNamespace $DestinationNamespace 
    }
    
    # Step 8: Delete Replicas
    Write-Host "`n🔄 STEP 8: DELETE REPLICAS" -ForegroundColor Cyan
    if ($DryRun) {
        Write-Host "🔍 DRY RUN: Would delete and recreate replicas" -ForegroundColor Yellow
        $scriptPath = Get-ScriptPath "replicas/delete_replicas.ps1"
        & $scriptPath  $Destination -Source $Source -SourceNamespace $SourceNamespace -DestinationNamespace $DestinationNamespace -DryRun:($DryRun -eq $true)
    } else {
        $scriptPath = Get-ScriptPath "replicas/delete_replicas.ps1"
        & $scriptPath  $Destination -Source $Source -SourceNamespace $SourceNamespace -DestinationNamespace $DestinationNamespace 
    }
    
    # Step 9: Configure Users
    Write-Host "`n🔄 STEP 9: CONFIGURE USERS" -ForegroundColor Cyan
    if ($DryRun) {
        Write-Host "🔍 DRY RUN: Would configure SQL users" -ForegroundColor Yellow
        Write-Host "🔍 DRY RUN: Environment: $Destination" -ForegroundColor Gray
        Write-Host "🔍 DRY RUN: Client: $DestinationNamespace" -ForegroundColor Gray
        Write-Host "🔍 DRY RUN: Would configure user permissions and roles" -ForegroundColor Gray
        Write-Host "🔍 DRY RUN: Would set up database access for application users" -ForegroundColor Gray
        Write-Host "🔍 DRY RUN: Would configure authentication and authorization" -ForegroundColor Gray
        $scriptPath = Get-ScriptPath "configuration/sql_configure_users.ps1"
        & $scriptPath  $Destination -DestinationNamespace $DestinationNamespace -AutoApprove -StopOnFailure -DryRun:($DryRun -eq $true) 
    } else {
        $scriptPath = Get-ScriptPath "configuration/sql_configure_users.ps1"
        & $scriptPath  $Destination -DestinationNamespace $DestinationNamespace -AutoApprove -StopOnFailure -BaselinesMode Off
    }
    
    # Step 10: Start Environment
    Write-Host "`n🔄 STEP 10: START ENVIRONMENT" -ForegroundColor Cyan
    if ($DryRun) {
        Write-Host "🔍 DRY RUN: Would start environment (SKIPPED in dry run)" -ForegroundColor Yellow
        Write-Host "🔍 DRY RUN: Environment: $Destination" -ForegroundColor Gray
        Write-Host "🔍 DRY RUN: Client: $DestinationNamespace" -ForegroundColor Gray
        Write-Host "🔍 DRY RUN: Would start AKS cluster and scale up deployments" -ForegroundColor Gray
        Write-Host "🔍 DRY RUN: Would enable Application Insights web tests" -ForegroundColor Gray
        Write-Host "🔍 DRY RUN: Would enable backend health alerts" -ForegroundColor Gray
        Write-Host "🔍 DRY RUN: Would restore monitoring and alerting" -ForegroundColor Gray
        $scriptPath = Get-ScriptPath "environment/StartEnvironment.ps1"
        & $scriptPath  $Destination Namespace $DestinationNamespace -DryRun:($DryRun -eq $true)
    } else {
        $scriptPath = Get-ScriptPath "environment/StartEnvironment.ps1"
        & $scriptPath  $Destination Namespace $DestinationNamespace
    }
    
    # Step 11: Cleanup
    Write-Host "`n🔄 STEP 11: CLEANUP" -ForegroundColor Cyan
    if ($DryRun) {
        Write-Host "🔍 DRY RUN: Would delete restored databases" -ForegroundColor Yellow
        Write-Host "🔍 DRY RUN: Source: $Source" -ForegroundColor Gray
        Write-Host "🔍 DRY RUN: Would delete databases with '-restored' suffix" -ForegroundColor Gray
        Write-Host "🔍 DRY RUN: Would clean up temporary restored databases" -ForegroundColor Gray
        Write-Host "🔍 DRY RUN: Would free up storage space" -ForegroundColor Gray
        $scriptPath = Get-ScriptPath "database/delete_restored_db.ps1"
        & $scriptPath -Source $Source -DryRun:($DryRun -eq $true)
    } else {
        $scriptPath = Get-ScriptPath "database/delete_restored_db.ps1"
        & $scriptPath -Source $Source 
    }
    
    # # Step 12: Remove Permissions
    # Write-Host "`n🔄 STEP 12: REMOVE PERMISSIONS" -ForegroundColor Cyan
    # if ($DryRun) {
    #     Write-Host "🔍 DRY RUN: Would remove permissions from SelfServiceRefresh" -ForegroundColor Yellow
    #     Write-Host "🔍 DRY RUN: Would call Azure Function to remove SelfServiceRefresh for environment: $Source" -ForegroundColor Gray
    #     Write-Host "🔍 DRY RUN: Would wait for permissions to propagate" -ForegroundColor Gray
    #     Write-Host "🔍 DRY RUN: Function URL: https://triggerimportondemand.azurewebsites.us/api/SelfServiceTest" -ForegroundColor Gray

    #     # Call the dedicated permission management script
    #     $permissionScript = Get-ScriptPath "permissions/Invoke-AzureFunctionPermission.ps1"
    #     $permissionResult = & $permissionScript -Action "Remove" -Environment $Source -ServiceAccount "SelfServiceRefresh" -TimeoutSeconds 60 -WaitForPropagation 30

    #     if (-not $permissionResult.Success) {
    #         Write-AutomationLog "❌ FATAL ERROR: Failed to remove permissions" "ERROR"
    #         Write-AutomationLog "📍 Error: $($permissionResult.Error)" "ERROR"
    #         throw "Permission removal failed: $($permissionResult.Error)"
    #     }
    #     Write-AutomationLog "✅ Permissions removed successfully" "SUCCESS"

    # } else {
    #     Write-AutomationLog "🔐 Starting permission removal process..." "INFO"
        
    #     # Call the dedicated permission management script
    #     $permissionScript = Get-ScriptPath "permissions/Invoke-AzureFunctionPermission.ps1"
    #     $permissionResult = & $permissionScript -Action "Remove" -Environment $Source -ServiceAccount "SelfServiceRefresh" -TimeoutSeconds 60 -WaitForPropagation 30
        
    #     if (-not $permissionResult.Success) {
    #         Write-AutomationLog "⚠️  WARNING: Failed to remove permissions" "WARN"
    #         Write-AutomationLog "📍 Error: $($permissionResult.Error)" "WARN"
    #         Write-AutomationLog "💡 Permissions may need to be removed manually" "WARN"
    #     } else {
    #         Write-AutomationLog "✅ Permissions removed successfully" "SUCCESS"
    #     }
    # }
    
    # Final summary for dry run mode
    if ($DryRun) {
        Write-Host "`n═══════════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
        Write-Host " DRY RUN COMPLETED" -ForegroundColor Cyan
        Write-Host "═══════════════════════════════════════════════════════════════════════════`n" -ForegroundColor Cyan
        Write-Host "🔍 This was a dry run - no actual changes were made" -ForegroundColor Yellow
        Write-Host "📋 The following operations would have been performed:" -ForegroundColor Cyan
        Write-Host "   STEP 0: Prerequisites (permissions, authentication, parameter detection)" -ForegroundColor Gray
        Write-Host "   STEP 1: Restore databases to point in time: $RestoreDateTime ($Timezone)" -ForegroundColor Gray
        Write-Host "   STEP 2: Stop environment $Destination" -ForegroundColor Gray
        Write-Host "   STEP 3: Copy attachments from $Source to $Destination" -ForegroundColor Gray
        Write-Host "   STEP 4: Copy databases from $Source to $Destination" -ForegroundColor Gray
        Write-Host "   STEP 5: Clean up source environment configurations (CORS, redirect URIs)" -ForegroundColor Gray
        Write-Host "   STEP 6: Revert source environment SQL users and roles" -ForegroundColor Gray
        Write-Host "   STEP 7: Adjust database resources and configurations" -ForegroundColor Gray
        Write-Host "   STEP 8: Delete and recreate replica databases" -ForegroundColor Gray
        Write-Host "   STEP 9: Configure SQL users and permissions" -ForegroundColor Gray
        Write-Host "   STEP 10: Start environment $Destination" -ForegroundColor Gray
        Write-Host "   STEP 11: Clean up temporary restored databases" -ForegroundColor Gray
        Write-Host "   STEP 12: Remove permissions from SelfServiceRefresh via Azure Function" -ForegroundColor Gray
        Write-Host "`n💡 To execute the actual operations, run without the -DryRun parameter" -ForegroundColor Green
        Write-Host "═══════════════════════════════════════════════════════════════════════════`n" -ForegroundColor Cyan
    } else {
        Write-Host "`n═══════════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
        Write-Host " SELF-SERVICE REFRESH COMPLETED" -ForegroundColor Cyan
        Write-Host "═══════════════════════════════════════════════════════════════════════════`n" -ForegroundColor Cyan
        Write-Host "✅ All operations completed successfully!" -ForegroundColor Green
        Write-Host "═══════════════════════════════════════════════════════════════════════════`n" -ForegroundColor Cyan
    }
}

# ═══════════════════════════════════════════════════════════════════════════
# MAIN SCRIPT EXECUTION
# ═══════════════════════════════════════════════════════════════════════════
Write-AutomationLog "🚀 Starting Self-Service Data Refresh" "INFO"
Write-AutomationLog "📋 Initial Parameters: Source=$Source/$SourceNamespace → Destination=$Destination/$DestinationNamespace" "INFO"
Write-AutomationLog "☁️  Cloud: $(if ([string]::IsNullOrWhiteSpace($Cloud)) { '<will auto-detect>' } else { $Cloud }) | DryRun: $DryRun" "INFO"

if (-not [string]::IsNullOrEmpty($LogFile)) {
    Write-AutomationLog "📝 Logging to file: $LogFile" "INFO"
}

try {
    Write-AutomationLog "✅ Input validation passed" "SUCCESS"
    
    # Execute migration
    Perform-Migration
    
    Write-AutomationLog "🎉 Self-Service Data Refresh completed successfully!" "SUCCESS"
    
} catch {
    $errorMessage = $_.Exception.Message
    Write-AutomationLog "❌ FATAL ERROR: $errorMessage" "ERROR"
    Write-AutomationLog "📍 Error occurred at: $($_.InvocationInfo.ScriptLineNumber):$($_.InvocationInfo.OffsetInLine)" "ERROR"
    
    if (-not [string]::IsNullOrEmpty($LogFile)) {
        Write-AutomationLog "📝 Full error details saved to log file: $LogFile" "ERROR"
        Add-Content -Path $LogFile -Value "FULL ERROR DETAILS:`n$($_ | Out-String)" -Force
    }
    
    # Standard exit code for errors
    $global:LASTEXITCODE = 1
    throw
}