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
    Customer alias for resource configuration

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
    [int]$MaxWaitMinutes = 40,
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
    exit 1
}
. $automationUtilitiesScript

# ═══════════════════════════════════════════════════════════════════════════
# EARLY PARAMETER VALIDATION (Before Azure Connection)
# ═══════════════════════════════════════════════════════════════════════════

Write-Host "🔧 Validating provided parameters..." -ForegroundColor Yellow

# CustomerAlias and Source are REQUIRED parameters
if ([string]::IsNullOrWhiteSpace($CustomerAlias)) {
    Write-Host "❌ FATAL ERROR: CustomerAlias is required and must be provided by the user" -ForegroundColor Red
    Write-Host "   Please provide CustomerAlias parameter when calling the script" -ForegroundColor Yellow
    exit 1
}

# Store original user-provided values before any auto-detection
$script:OriginalSource = $Source
$script:OriginalDestination = $Destination
$script:OriginalSourceNamespace = $SourceNamespace
$script:OriginalDestinationNamespace = $DestinationNamespace
$script:OriginalCloud = $Cloud

# Show what user provided (for debugging)
Write-Host "📋 User-provided parameters:" -ForegroundColor Cyan
Write-Host "   Source: $(if ([string]::IsNullOrWhiteSpace($Source)) { '<empty - will auto-detect>' } else { $Source + ' ✅' })" -ForegroundColor Gray
Write-Host "   Destination: $(if ([string]::IsNullOrWhiteSpace($Destination)) { '<empty - will auto-detect>' } else { $Destination + ' ✅' })" -ForegroundColor Gray
Write-Host "   SourceNamespace: $(if ([string]::IsNullOrWhiteSpace($SourceNamespace)) { '<empty - will auto-detect>' } else { $SourceNamespace + ' ✅' })" -ForegroundColor Gray
Write-Host "   DestinationNamespace: $(if ([string]::IsNullOrWhiteSpace($DestinationNamespace)) { '<empty - will auto-detect>' } else { $DestinationNamespace + ' ✅' })" -ForegroundColor Gray
Write-Host "   Cloud: $(if ([string]::IsNullOrWhiteSpace($Cloud)) { '<empty - will auto-detect>' } else { $Cloud + ' ✅' })" -ForegroundColor Gray
Write-Host "   CustomerAlias: $CustomerAlias ✅" -ForegroundColor Gray

Write-Host "✅ Basic parameter validation completed" -ForegroundColor Green

# ═══════════════════════════════════════════════════════════════════════════
# HELPER FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════

# 📁 HELPER FUNCTION: Get absolute script path
function Get-ScriptPath {
    param([string]$RelativePath)
    if ($global:ScriptBaseDir) {
        return Join-Path $global:ScriptBaseDir $RelativePath
    } else {
        # Use current script directory structure (scripts/main -> scripts)
        $scriptDir = Split-Path $PSScriptRoot -Parent
        $fullPath = Join-Path $scriptDir $RelativePath
        return $fullPath
    }
}

function Perform-Migration {
    
    # ═══════════════════════════════════════════════════════════════════════════
    # STEP 0A: SETUP BASE DIRECTORIES
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
    # STEP 0B: AZURE AUTHENTICATION (FIRST - using Service Principal)
    # ═══════════════════════════════════════════════════════════════════════════
    
    Write-Host "`n🔐 STEP 0B: AUTHENTICATE TO AZURE (Service Principal)" -ForegroundColor Cyan
    Write-AutomationLog "🔐 Authenticating using Service Principal from environment variables" "INFO"
    
    # Authenticate using Service Principal (from env vars: AZURE_CLIENT_ID, AZURE_CLIENT_SECRET, AZURE_TENANT_ID)
    # This works WITHOUT needing to know the Cloud first - the Connect-Azure script will handle it
    $commonDir = Join-Path $global:ScriptBaseDir "common"
    $authScript = Join-Path $commonDir "Connect-Azure.ps1"
    
    if (Test-Path $authScript) {
        Write-Host "📝 Using authentication script: $authScript" -ForegroundColor Gray
        Write-Host "🔑 Authenticating with Service Principal (AZURE_CLIENT_ID from env)" -ForegroundColor Gray
        
        # Pass user-provided Cloud parameter if available, otherwise Connect-Azure will auto-detect
        if (-not [string]::IsNullOrWhiteSpace($script:OriginalCloud)) {
            Write-Host "🌐 Using user-provided cloud: $($script:OriginalCloud)" -ForegroundColor Gray
            $authResult = & $authScript -Cloud $script:OriginalCloud
        } else {
            Write-Host "🌐 Cloud not provided, will auto-detect" -ForegroundColor Gray
            $authResult = & $authScript
        }
        if (-not $authResult) {
            Write-AutomationLog "❌ FATAL ERROR: Failed to authenticate to Azure" "ERROR"
            Write-Host "❌ Azure authentication failed. Cannot proceed." -ForegroundColor Red
            Write-Host "   Make sure these environment variables are set:" -ForegroundColor Yellow
            Write-Host "   - AZURE_CLIENT_ID" -ForegroundColor Gray
            Write-Host "   - AZURE_CLIENT_SECRET" -ForegroundColor Gray
            Write-Host "   - AZURE_TENANT_ID" -ForegroundColor Gray
            Write-Host "   - AZURE_SUBSCRIPTION_ID" -ForegroundColor Gray
            exit 1
        }
        Write-Host "✅ Azure authentication successful" -ForegroundColor Green
    } else {
        Write-AutomationLog "❌ FATAL ERROR: Authentication script not found at $authScript" "ERROR"
        Write-Host "❌ Cannot authenticate without Connect-Azure.ps1" -ForegroundColor Red
        exit 1
    }
    
    # ═══════════════════════════════════════════════════════════════════════════
    # STEP 0C: AUTO-DETECT PARAMETERS FROM AZURE (Now that we're authenticated)
    # ═══════════════════════════════════════════════════════════════════════════
    
    Write-Host "`n🔧 STEP 0C: AUTO-DETECT PARAMETERS" -ForegroundColor Cyan
    
    # Load the Azure parameter detection function
    $azureParamsScript = Join-Path $global:ScriptBaseDir "common/Get-AzureParameters.ps1"
    if (-not (Test-Path $azureParamsScript)) {
        Write-Host "❌ FATAL ERROR: Azure parameter detection script not found at: $azureParamsScript" -ForegroundColor Red
        exit 1
    }
    
    # Auto-detect parameters from Azure environment
    $detectedParams = & $azureParamsScript `
        -Source $script:OriginalSource `
        -Destination $script:OriginalDestination `
        -SourceNamespace $script:OriginalSourceNamespace `
        -DestinationNamespace $script:OriginalDestinationNamespace
    
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
        Write-Host "   Destination: '$($script:Destination)' ← Auto-detected (same as Source)" -ForegroundColor Yellow
    }
    
    # DestinationNamespace
    if (-not [string]::IsNullOrWhiteSpace($script:OriginalDestinationNamespace)) {
        $script:DestinationNamespace = $script:OriginalDestinationNamespace
        Write-Host "   DestinationNamespace: '$($script:DestinationNamespace)' ← USER PROVIDED ✅" -ForegroundColor Green
    } else {
        $script:DestinationNamespace = $detectedParams.DestinationNamespace
        Write-Host "   DestinationNamespace: '$($script:DestinationNamespace)' ← Default (org standard)" -ForegroundColor Yellow
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
    
    # Calculate CustomerAliasToRemove based on CustomerAlias pattern
    if ([string]::IsNullOrWhiteSpace($CustomerAliasToRemove)) {
        # Pattern: mil-space-test -> mil-space, mil-space-dev -> mil-space
        if ($CustomerAlias -match "^(.+)-(test|dev)$") {
            $script:CustomerAliasToRemove = $matches[1]
            Write-Host "✅ Extracted customer alias to remove: $($script:CustomerAliasToRemove) (from $CustomerAlias)" -ForegroundColor Green
        } else {
            # Fallback: Customer alias to remove is same as source
            $script:CustomerAliasToRemove = $script:Source
            Write-Host "✅ Using source as customer alias to remove: $($script:CustomerAliasToRemove)" -ForegroundColor Green
        }
    } else {
        $script:CustomerAliasToRemove = $CustomerAliasToRemove
    }
    
    Write-Host "✅ Parameters auto-detected and configured" -ForegroundColor Green
    Write-Host "📋 Final parameters:" -ForegroundColor Cyan
    Write-Host "   Source: $($script:Source) / $($script:SourceNamespace)" -ForegroundColor Gray
    Write-Host "   Destination: $($script:Destination) / $($script:DestinationNamespace)" -ForegroundColor Gray
    Write-Host "   Cloud: $($script:Cloud)" -ForegroundColor Gray
    Write-Host "   Customer Alias: $CustomerAlias" -ForegroundColor Gray
    Write-Host "   Customer Alias to Remove: $($script:CustomerAliasToRemove)" -ForegroundColor Gray
    
    # Log final parameters
    Write-AutomationLog "📋 Final Parameters: Source=$($script:Source)/$($script:SourceNamespace) → Destination=$($script:Destination)/$($script:DestinationNamespace)" "INFO"
    Write-AutomationLog "☁️  Cloud: $($script:Cloud) | DryRun: $DryRun" "INFO"
    
    # ═══════════════════════════════════════════════════════════════════════════
    # STEP 0D: GRANT PERMISSIONS (Now that we know Source)
    # ═══════════════════════════════════════════════════════════════════════════
    
    Write-Host "`n🔄 STEP 0D: GRANT PERMISSIONS (Always - Dry Run or Not)" -ForegroundColor Cyan
    Write-AutomationLog "🔐 Granting permissions for source environment: $($script:Source)" "INFO"
    Write-Host "📋 Environment: $($script:Source)" -ForegroundColor Gray
    Write-Host "📋 Service Account: SelfServiceRefresh" -ForegroundColor Gray
    Write-Host "📋 Action: Grant" -ForegroundColor Gray
    
    # Call the dedicated permission management script
    # NOTE: This ALWAYS runs, even in dry-run mode, because:
    # 1. Permissions are needed for subsequent Azure operations
    # 2. Azure Function call is safe (idempotent)
    # 3. No actual infrastructure changes
    $permissionScript = Get-ScriptPath "permissions/Invoke-AzureFunctionPermission.ps1"
    if (Test-Path $permissionScript) {
        $permissionResult = & $permissionScript -Action "Grant" -Environment $script:Source -ServiceAccount "SelfServiceRefresh" -TimeoutSeconds 60 -WaitForPropagation 30
        
        if (-not $permissionResult.Success) {
            Write-AutomationLog "❌ FATAL ERROR: Failed to grant permissions" "ERROR"
            Write-AutomationLog "📍 Error: $($permissionResult.Error)" "ERROR"
            throw "Permission grant failed: $($permissionResult.Error)"
        }
        
        Write-AutomationLog "✅ Permissions granted successfully" "SUCCESS"
    } else {
        Write-AutomationLog "❌ FATAL ERROR: Permission script not found at $permissionScript" "ERROR"
        throw "Cannot proceed without granting permissions"
    }
    
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
            $Domain = 'cloud'
        }
    }

    Invoke-Migration `
        -Cloud $script:Cloud `
        -Source $script:Source `
        -Destination $script:Destination `
        -CustomerAlias $CustomerAlias `
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
    Write-Host "👤 Customer Alias: $CustomerAlias" -ForegroundColor Gray
    Write-Host "🗑️ Customer Alias to Remove: $CustomerAliasToRemove" -ForegroundColor Gray
    Write-Host "📅 Restore DateTime: $RestoreDateTime ($Timezone)" -ForegroundColor Gray
    Write-Host "⏱️ Max Wait Time: $MaxWaitMinutes minutes" -ForegroundColor Gray
    
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
        & $scriptPath -source $Source -SourceNamespace $SourceNamespace -RestoreDateTime $RestoreDateTime -Timezone $Timezone -DryRun:$DryRun -MaxWaitMinutes $MaxWaitMinutes
    } else {
        $scriptPath = Get-ScriptPath "restore/RestorePointInTime.ps1"
        & $scriptPath -source $Source -SourceNamespace $SourceNamespace -RestoreDateTime $RestoreDateTime -Timezone $Timezone -DryRun:$DryRun -MaxWaitMinutes $MaxWaitMinutes
    }
    
    # Step 2: Stop Environment
    Write-Host "`n🔄 STEP 2: STOP ENVIRONMENT" -ForegroundColor Cyan
    if ($DryRun) {
        Write-Host "🔍 DRY RUN: Would stop environment" -ForegroundColor Yellow
        $scriptPath = Get-ScriptPath "environment/StopEnvironment.ps1"
        & $scriptPath -source $Destination -sourceNamespace $DestinationNamespace -Cloud $Cloud -DryRun:($DryRun -eq $true)
    } else {
        $scriptPath = Get-ScriptPath "environment/StopEnvironment.ps1"
        & $scriptPath -source $Destination -sourceNamespace $DestinationNamespace -Cloud $Cloud 
    }
    
    # Step 3: Copy Attachments
    Write-Host "`n🔄 STEP 3: COPY ATTACHMENTS" -ForegroundColor Cyan
    if ($DryRun) {
        Write-Host "🔍 DRY RUN: Would copy attachments" -ForegroundColor Yellow
        $scriptPath = Get-ScriptPath "storage/CopyAttachments.ps1"
        & $scriptPath -source $Source -destination $Destination -SourceNamespace $SourceNamespace -DestinationNamespace $DestinationNamespace -DryRun:($DryRun -eq $true)
    } else {
        $scriptPath = Get-ScriptPath "storage/CopyAttachments.ps1"
        & $scriptPath -source $Source -destination $Destination -SourceNamespace $SourceNamespace -DestinationNamespace $DestinationNamespace 
    }
    
    # Step 4: Copy Database
    Write-Host "`n🔄 STEP 4: COPY DATABASE" -ForegroundColor Cyan
    if ($DryRun) {
        Write-Host "🔍 DRY RUN: Would copy database" -ForegroundColor Yellow
        $scriptPath = Get-ScriptPath "database/copy_database.ps1"
        & $scriptPath -source $Source -destination $Destination -SourceNamespace $SourceNamespace -DestinationNamespace $DestinationNamespace -DryRun:($DryRun -eq $true)
    } else {
        $scriptPath = Get-ScriptPath "database/copy_database.ps1"
        & $scriptPath -source $Source -destination $Destination -SourceNamespace $SourceNamespace -DestinationNamespace $DestinationNamespace 
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
        & $scriptPath -destination $Destination -EnvironmentToClean $Source -MultitenantToRemove $SourceNamespace -CustomerAliasToRemove $CustomerAliasToRemove -domain $Domain -DestinationNamespace $DestinationNamespace -DryRun:($DryRun -eq $true)
    } else {
        $scriptPath = Get-ScriptPath "configuration/cleanup_environment_config.ps1"
        & $scriptPath -destination $Destination -EnvironmentToClean $Source -MultitenantToRemove $SourceNamespace -CustomerAliasToRemove $CustomerAliasToRemove -domain $Domain -DestinationNamespace $DestinationNamespace
    }
    
    # Step 6: Revert SQL Users
    Write-Host "`n🔄 STEP 6: REVERT SQL USERS" -ForegroundColor Cyan
    if ($DryRun) {
        Write-Host "🔍 DRY RUN: Would revert source environment SQL users" -ForegroundColor Yellow
        Write-Host "🔍 DRY RUN: Removing database users and roles for: $Source" -ForegroundColor Gray
        Write-Host "🔍 DRY RUN: Source multitenant: $SourceNamespace" -ForegroundColor Gray
        $scriptPath = Get-ScriptPath "configuration/sql_configure_users.ps1"
        & $scriptPath -Environments $Destination -Clients $DestinationNamespace -Revert -EnvironmentToRevert $Source -MultitenantToRevert $SourceNamespace -AutoApprove -StopOnFailure -DryRun:($DryRun -eq $true)
    } else {
        $scriptPath = Get-ScriptPath "configuration/sql_configure_users.ps1"
        & $scriptPath -Environments $Destination -Clients $DestinationNamespace -Revert -EnvironmentToRevert $Source -MultitenantToRevert $SourceNamespace -AutoApprove -StopOnFailure
    }
    
    # Step 7: Adjust Resources
    Write-Host "`n🔄 STEP 7: ADJUST RESOURCES" -ForegroundColor Cyan
    if ($DryRun) {
        Write-Host "🔍 DRY RUN: Would adjust database resources" -ForegroundColor Yellow
        $scriptPath = Get-ScriptPath "configuration/adjust_db.ps1"
        & $scriptPath -domain $Domain -CustomerAlias $CustomerAlias -destination $Destination -DestinationNamespace $DestinationNamespace -DryRun:($DryRun -eq $true)
    } else {
        $scriptPath = Get-ScriptPath "configuration/adjust_db.ps1"
        & $scriptPath -domain $Domain -CustomerAlias $CustomerAlias -destination $Destination -DestinationNamespace $DestinationNamespace 
    }
    
    # Step 8: Delete Replicas
    Write-Host "`n🔄 STEP 8: DELETE REPLICAS" -ForegroundColor Cyan
    if ($DryRun) {
        Write-Host "🔍 DRY RUN: Would delete and recreate replicas" -ForegroundColor Yellow
        $scriptPath = Get-ScriptPath "replicas/delete_replicas.ps1"
        & $scriptPath -destination $Destination -source $Source -SourceNamespace $SourceNamespace -DestinationNamespace $DestinationNamespace -DryRun:($DryRun -eq $true)
    } else {
        $scriptPath = Get-ScriptPath "replicas/delete_replicas.ps1"
        & $scriptPath -destination $Destination -source $Source -SourceNamespace $SourceNamespace -DestinationNamespace $DestinationNamespace 
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
        & $scriptPath -Environments $Destination -Clients $DestinationNamespace -AutoApprove -StopOnFailure -DryRun:($DryRun -eq $true) 
    } else {
        $scriptPath = Get-ScriptPath "configuration/sql_configure_users.ps1"
        & $scriptPath -Environments $Destination -Clients $DestinationNamespace -AutoApprove -StopOnFailure -BaselinesMode Off
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
        & $scriptPath -destination $Destination -destinationNamespace $DestinationNamespace -DryRun:($DryRun -eq $true)
    } else {
        $scriptPath = Get-ScriptPath "environment/StartEnvironment.ps1"
        & $scriptPath -destination $Destination -destinationNamespace $DestinationNamespace
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
        & $scriptPath -source $Source -DryRun:($DryRun -eq $true)
    } else {
        $scriptPath = Get-ScriptPath "database/delete_restored_db.ps1"
        & $scriptPath -source $Source 
    }
    
    # Step 12: Remove Permissions
    Write-Host "`n🔄 STEP 12: REMOVE PERMISSIONS" -ForegroundColor Cyan
    if ($DryRun) {
        Write-Host "🔍 DRY RUN: Would remove permissions from SelfServiceRefresh" -ForegroundColor Yellow
        Write-Host "🔍 DRY RUN: Would call Azure Function to remove SelfServiceRefresh for environment: $Source" -ForegroundColor Gray
        Write-Host "🔍 DRY RUN: Would wait for permissions to propagate" -ForegroundColor Gray
        Write-Host "🔍 DRY RUN: Function URL: https://triggerimportondemand.azurewebsites.us/api/SelfServiceTest" -ForegroundColor Gray

        # Call the dedicated permission management script
        $permissionScript = Get-ScriptPath "permissions/Invoke-AzureFunctionPermission.ps1"
        $permissionResult = & $permissionScript -Action "Remove" -Environment $Source -ServiceAccount "SelfServiceRefresh" -TimeoutSeconds 60 -WaitForPropagation 30

        if (-not $permissionResult.Success) {
            Write-AutomationLog "❌ FATAL ERROR: Failed to remove permissions" "ERROR"
            Write-AutomationLog "📍 Error: $($permissionResult.Error)" "ERROR"
            throw "Permission removal failed: $($permissionResult.Error)"
        }
        Write-AutomationLog "✅ Permissions removed successfully" "SUCCESS"

    } else {
        Write-AutomationLog "🔐 Starting permission removal process..." "INFO"
        
        # Call the dedicated permission management script
        $permissionScript = Get-ScriptPath "permissions/Invoke-AzureFunctionPermission.ps1"
        $permissionResult = & $permissionScript -Action "Remove" -Environment $Source -ServiceAccount "SelfServiceRefresh" -TimeoutSeconds 60 -WaitForPropagation 30
        
        if (-not $permissionResult.Success) {
            Write-AutomationLog "⚠️  WARNING: Failed to remove permissions" "WARN"
            Write-AutomationLog "📍 Error: $($permissionResult.Error)" "WARN"
            Write-AutomationLog "💡 Permissions may need to be removed manually" "WARN"
        } else {
            Write-AutomationLog "✅ Permissions removed successfully" "SUCCESS"
        }
    }
    
    # Final summary for dry run mode
    if ($DryRun) {
        Write-Host "`n═══════════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
        Write-Host " DRY RUN COMPLETED" -ForegroundColor Cyan
        Write-Host "═══════════════════════════════════════════════════════════════════════════`n" -ForegroundColor Cyan
        Write-Host "🔍 This was a dry run - no actual changes were made" -ForegroundColor Yellow
        Write-Host "📋 The following operations would have been performed:" -ForegroundColor Cyan
        Write-Host "   STEP 0: Grant permissions to SelfServiceRefresh via Azure Function" -ForegroundColor Gray
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
    exit 1
}