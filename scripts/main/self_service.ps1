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

.PARAMETER InstanceAlias
    Instance alias for resource configuration (defaults to INSTANCE_ALIAS environment variable if not provided)

.PARAMETER InstanceAliasToRemove
    Instance alias to remove from source environment during cleanup

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
    .\self_service.ps1 -Source "qa2" -Destination "dev" -InstanceAlias "dev" -InstanceAliasToRemove "qa2" -DryRun

.NOTES
    - Default restore point is 15 minutes ago in the current system timezone
    - Use -DryRun to preview operations without executing them
#>

param (
    [string]$RestoreDateTime,  # Format: "yyyy-MM-dd HH:mm:ss" - empty uses 15 min ago
    [string]$Timezone,         # Empty uses system timezone
    [string]$SourceNamespace,
    [string]$Source,
    [string]$DestinationNamespace,
    [string]$Destination,
    [string]$InstanceAlias,
    [string]$InstanceAliasToRemove,
    [string]$Cloud,
    [switch]$DryRun,
    [switch]$UseSasTokens,  # Use SAS tokens for 3TB+ container copies (8-hour validity)
    [int]$MaxWaitMinutes
    # 🤖 AUTOMATION PARAMETERS - prevents interactive prompts
    # [string]$LogFile = "/tmp/self_service_$(Get-Date -Format 'yyyy-MM-dd_HH-mm-ss').log"           # Custom log file path for automation
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
    
    Write-AutomationLog "🔍 Running prerequisites check" "INFO"
    Test-Prerequisites

    Write-Host "✅ Parameters auto-detected and configured" -ForegroundColor Green
    Write-Host "📋 Final parameters:" -ForegroundColor Cyan
    Write-Host "   Source: $Source / $SourceNamespace" -ForegroundColor Gray
    Write-Host "   Destination: $Destination / $DestinationNamespace" -ForegroundColor Gray
    Write-Host "   Cloud: $Cloud" -ForegroundColor Gray
    Write-Host "   Instance Alias: $InstanceAlias" -ForegroundColor Gray
    Write-Host "   Instance Alias to Remove: $InstanceAliasToRemove" -ForegroundColor Gray
    Write-Host "   Restore DateTime: $RestoreDateTime ($Timezone)" -ForegroundColor Gray
    Write-Host "   Max Wait Minutes: $MaxWaitMinutes" -ForegroundColor Gray
    Write-Host "   DryRun: $DryRun" -ForegroundColor Gray
    Write-Host "   Max Wait Minutes: $MaxWaitMinutes" -ForegroundColor Gray
    Write-Host "   UseSasTokens: $UseSasTokens" -ForegroundColor Gray
    
    # Set domain based on cloud environment for downstream scripts
    switch ($Cloud) {
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
    Write-Host "🔍 Domain: $Domain" -ForegroundColor Gray

    Invoke-Migration `
        -Cloud $Cloud `
        -Source $Source `
        -Destination $Destination `
        -InstanceAlias $InstanceAlias `
        -InstanceAliasToRemove $InstanceAliasToRemove `
        -SourceNamespace $SourceNamespace `
        -DestinationNamespace $DestinationNamespace `
        -Domain $Domain `
        -DryRun:$DryRun `
        -UseSasTokens:$UseSasTokens `
        -MaxWaitMinutes $MaxWaitMinutes `
        -RestoreDateTime $RestoreDateTime `
        -Timezone $Timezone
}

function Invoke-Migration {
    param (
        [string]$Cloud,
        [string]$Source,
        [string]$Destination,
        [AllowEmptyString()][string]$InstanceAlias,
        [AllowEmptyString()][string]$InstanceAliasToRemove,
        [string]$SourceNamespace,
        [string]$DestinationNamespace,
        [string]$Domain,
        [switch]$DryRun,
        [switch]$UseSasTokens,
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
    Write-Host "👤 Instance Alias: $InstanceAlias" -ForegroundColor Gray
    Write-Host "🗑️ Instance Alias to Remove: $InstanceAliasToRemove" -ForegroundColor Gray
    Write-Host "📅 Restore DateTime: $RestoreDateTime ($Timezone)" -ForegroundColor Gray
    Write-Host "🕐 Timezone: $Timezone" -ForegroundColor Gray
    Write-Host "⏱️ Max Wait Time: $MaxWaitMinutes minutes" -ForegroundColor Gray
    Write-Host "🔍 UseSasTokens: $UseSasTokens" -ForegroundColor Gray
    
    if ($DryRun) {
        Write-Host "🔍 DRY RUN MODE ENABLED - No actual changes will be made" -ForegroundColor Yellow
    }
    Write-Host "═══════════════════════════════════════════════════════════════════════════`n" -ForegroundColor Cyan
    
    # ═══════════════════════════════════════════════════════════════════════════
    # STEP 0A: GRANT PERMISSIONS
    # ═══════════════════════════════════════════════════════════════════════════
    
    Write-Host "🔐 STEP 0A: GRANT PERMISSIONS" -ForegroundColor Cyan
    Write-Host ""
    if ($DryRun) {
        Write-Host "🔍 DRY RUN: Would grant permissions to SelfServiceRefresh" -ForegroundColor Yellow
        Write-Host "🔍 DRY RUN: Would call Azure Function to remove SelfServiceRefresh for environment: $Source" -ForegroundColor Gray
        Write-Host "🔍 DRY RUN: Would wait for permissions to propagate" -ForegroundColor Gray
        Write-Host "🔍 DRY RUN: Function URL: $env:SEMAPHORE_FUNCTION_URL" -ForegroundColor Gray

        # Call the dedicated permission management script
        $permissionScript = Get-ScriptPath "permissions/Invoke-AzureFunctionPermission.ps1"
        $permissionResult = & $permissionScript -Action "Grant" -Environment $Source -TimeoutSeconds 60 -WaitForPropagation 30

        if (-not $permissionResult.Success) {
            Write-AutomationLog "❌ FATAL ERROR: Failed to grant permissions" "ERROR"
            Write-AutomationLog "📍 Error: $($permissionResult.Error)" "ERROR"
            throw "Permission grant failed: $($permissionResult.Error)"
        }
        Write-AutomationLog "✅ Permissions granted successfully" "SUCCESS"

    } else {
        Write-AutomationLog "🔐 Starting permission grant process..." "INFO"
        
        # Call the dedicated permission management script
        $permissionScript = Get-ScriptPath "permissions/Invoke-AzureFunctionPermission.ps1"
        $permissionResult = & $permissionScript -Action "Grant" -Environment $Source  -TimeoutSeconds 60 -WaitForPropagation 30
        # -ServiceAccount $env:SEMAPHORE_WORKLOAD_IDENTITY_NAME
        if (-not $permissionResult.Success) {
            Write-AutomationLog "⚠️  WARNING: Failed to grant permissions" "WARN"
            Write-AutomationLog "📍 Error: $($permissionResult.Error)" "WARN"
            Write-AutomationLog "💡 Permissions may need to be granted manually" "WARN"
        } else {
            Write-AutomationLog "✅ Permissions granted successfully" "SUCCESS"
        }
    }

    $result = @{
        Success = $true
        DetectedParameters = @{}
        PermissionResult = $null
        AuthenticationResult = $false
        NeedsPropagationWait = $false
        PropagationWaitSeconds = 0
        Error = $null
    }

    # ═══════════════════════════════════════════════════════════════════════════
    # STEP 0B: AZURE AUTHENTICATION
    # ═══════════════════════════════════════════════════════════════════════════

    Write-Host "🔐 STEP 0B: AZURE AUTHENTICATION" -ForegroundColor Cyan
    Write-Host ""

    try {
        $authScript = Join-Path $scriptDir "../common/Connect-Azure.ps1"
        
        if (Test-Path $authScript) {
            Write-Host "   🔑 Authenticating to Azure..." -ForegroundColor Gray
            
            Write-Host "   🌐 Using specified cloud: $Cloud" -ForegroundColor Gray
            $authResult = & $authScript -Cloud $Cloud
            
            if ($authResult) {
                Write-Host "   ✅ Azure authentication successful" -ForegroundColor Green
                $result.AuthenticationResult = $true
            } else {
                Write-Host ""
                Write-Host "   ❌ FATAL ERROR: Azure authentication failed" -ForegroundColor Red
                Write-Host "   Cannot proceed without authentication" -ForegroundColor Yellow
                
                $result.Success = $false
                $result.Error = "Azure authentication failed"
                return $result
            }
        } else {
            Write-Host "   ⚠️  Authentication script not found: $authScript" -ForegroundColor Yellow
            Write-Host "   Assuming Azure CLI is already authenticated..." -ForegroundColor Gray
        }
    } catch {
        Write-Host ""
        Write-Host "   ❌ FATAL ERROR: Authentication exception: $($_.Exception.Message)" -ForegroundColor Red
        
        $result.Success = $false
        $result.Error = "Azure authentication exception: $($_.Exception.Message)"
        return $result
    }

    Write-Host ""


    # Step 1: Restore Point in Time
    Write-Host "`n🔄 STEP 1: RESTORE POINT IN TIME" -ForegroundColor Cyan
    if ($DryRun) {
        Write-Host "🔍 DRY RUN: Would execute restore point in time" -ForegroundColor Yellow
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
        & $scriptPath -Destination $Destination -DestinationNamespace $DestinationNamespace -Cloud $Cloud -DryRun:($DryRun -eq $true)
    } else {
        $scriptPath = Get-ScriptPath "environment/StopEnvironment.ps1"
        & $scriptPath -Destination $Destination -DestinationNamespace $DestinationNamespace -Cloud $Cloud 
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
    if ($UseSasTokens) {
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
        & $scriptPath -Source $Source -Destination $Destination -SourceNamespace $SourceNamespace -DestinationNamespace $DestinationNamespace -DryRun:($DryRun -eq $true)
    } else {
        $scriptPath = Get-ScriptPath "database/copy_database.ps1"
        & $scriptPath -Source $Source -Destination $Destination -SourceNamespace $SourceNamespace -DestinationNamespace $DestinationNamespace
    }
    
    # Step 5: Cleanup Environment Configuration
    Write-Host "`n🔄 STEP 5: CLEANUP ENVIRONMENT CONFIGURATION" -ForegroundColor Cyan
    if ($DryRun) {
        Write-Host "🔍 DRY RUN: Would cleanup source environment configurations" -ForegroundColor Yellow
        Write-Host "🔍 DRY RUN: Removing CORS origins and redirect URIs for: $Source" -ForegroundColor Gray
        $scriptPath = Get-ScriptPath "configuration/cleanup_environment_config.ps1"
        & $scriptPath -Destination $Destination -Source $Source -SourceNamespace $SourceNamespace -InstanceAliasToRemove $InstanceAliasToRemove -Domain $Domain -DestinationNamespace $DestinationNamespace -DryRun:($DryRun -eq $true)
    } else {
        $scriptPath = Get-ScriptPath "configuration/cleanup_environment_config.ps1"
        & $scriptPath -Destination $Destination -Source $Source -SourceNamespace $SourceNamespace -InstanceAliasToRemove $InstanceAliasToRemove -Domain $Domain -DestinationNamespace $DestinationNamespace
    }
    
    # Step 6: Revert SQL Users
    Write-Host "`n🔄 STEP 6: REVERT SQL USERS" -ForegroundColor Cyan
    if ($DryRun) {
        Write-Host "🔍 DRY RUN: Would revert source environment SQL users" -ForegroundColor Yellow
        Write-Host "🔍 DRY RUN: Removing database users and roles for: $Source" -ForegroundColor Gray
        Write-Host "🔍 DRY RUN: Source multitenant: $SourceNamespace" -ForegroundColor Gray
        $scriptPath = Get-ScriptPath "configuration/sql_configure_users.ps1"
        & $scriptPath -Destination $Destination -DestinationNamespace $DestinationNamespace -Revert -Source $Source -SourceNamespace $SourceNamespace -AutoApprove -StopOnFailure -DryRun:($DryRun -eq $true)
    } else {
        $scriptPath = Get-ScriptPath "configuration/sql_configure_users.ps1"
        & $scriptPath -Destination $Destination -DestinationNamespace $DestinationNamespace -Revert -Source $Source -SourceNamespace $SourceNamespace -AutoApprove -StopOnFailure
    }
    
    # Step 7: Adjust Resources
    Write-Host "`n🔄 STEP 7: ADJUST RESOURCES" -ForegroundColor Cyan
    if ($DryRun) {
        Write-Host "🔍 DRY RUN: Would adjust database resources" -ForegroundColor Yellow
        $scriptPath = Get-ScriptPath "configuration/adjust_db.ps1"
        & $scriptPath -Domain $Domain -InstanceAlias $InstanceAlias -Destination $Destination -DestinationNamespace $DestinationNamespace -DryRun:($DryRun -eq $true)
    } else {
        $scriptPath = Get-ScriptPath "configuration/adjust_db.ps1"
        & $scriptPath -Domain $Domain -InstanceAlias $InstanceAlias -Destination $Destination -DestinationNamespace $DestinationNamespace 
    }
    
    # Step 8: Delete Replicas
    Write-Host "`n🔄 STEP 8: DELETE REPLICAS" -ForegroundColor Cyan
    if ($DryRun) {
        Write-Host "🔍 DRY RUN: Would delete and recreate replicas" -ForegroundColor Yellow
        $scriptPath = Get-ScriptPath "replicas/delete_replicas.ps1"
        & $scriptPath -Destination $Destination -Source $Source -SourceNamespace $SourceNamespace -DestinationNamespace $DestinationNamespace -DryRun:($DryRun -eq $true)
    } else {
        $scriptPath = Get-ScriptPath "replicas/delete_replicas.ps1"
        & $scriptPath -Destination $Destination -Source $Source -SourceNamespace $SourceNamespace -DestinationNamespace $DestinationNamespace 
    }
    
    # Step 9: Configure Users
    Write-Host "`n🔄 STEP 9: CONFIGURE USERS" -ForegroundColor Cyan
    if ($DryRun) {
        Write-Host "🔍 DRY RUN: Would configure SQL users" -ForegroundColor Yellow
        # Write-Host "🔍 DRY RUN: Environment: $Destination" -ForegroundColor Gray
        # Write-Host "🔍 DRY RUN: Client: $DestinationNamespace" -ForegroundColor Gray
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
    
    # Step 12: Remove Permissions
    Write-Host "`n🔄 STEP 12: REMOVE PERMISSIONS" -ForegroundColor Cyan
    if ($DryRun) {
        Write-Host "🔍 DRY RUN: Would remove permissions from SelfServiceRefresh" -ForegroundColor Yellow
        Write-Host "🔍 DRY RUN: Would call Azure Function to remove SelfServiceRefresh for environment: $Source" -ForegroundColor Gray
        Write-Host "🔍 DRY RUN: Would wait for permissions to propagate" -ForegroundColor Gray
        Write-Host "🔍 DRY RUN: Function URL: $env:SEMAPHORE_FUNCTION_URL" -ForegroundColor Gray

        # Call the dedicated permission management script
        $permissionScript = Get-ScriptPath "permissions/Invoke-AzureFunctionPermission.ps1"
        $permissionResult = & $permissionScript -Action "Remove" -Environment $Source -TimeoutSeconds 60 -WaitForPropagation 30

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
        $permissionResult = & $permissionScript -Action "Remove" -Environment $Source  -TimeoutSeconds 60 -WaitForPropagation 30
        # -ServiceAccount $env:SEMAPHORE_WORKLOAD_IDENTITY_NAME
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

try {
    Write-AutomationLog "✅ Input validation passed" "SUCCESS"
    
    # Execute migration
    Perform-Migration
    
    Write-AutomationLog "🎉 Self-Service Data Refresh completed successfully!" "SUCCESS"
    
} catch {
    $errorMessage = $_.Exception.Message
    Write-AutomationLog "❌ FATAL ERROR: $errorMessage" "ERROR"
    Write-AutomationLog "📍 Error occurred at: $($_.InvocationInfo.ScriptLineNumber):$($_.InvocationInfo.OffsetInLine)" "ERROR"
    
    # if (-not [string]::IsNullOrEmpty($LogFile)) {
        # Write-AutomationLog "📝 Full error details saved to log file: $LogFile" "ERROR"
        # Add-Content -Path $LogFile -Value "FULL ERROR DETAILS:`n$($_ | Out-String)" -Force
    # }
    
    # Standard exit code for errors
    $global:LASTEXITCODE = 1
    throw
}