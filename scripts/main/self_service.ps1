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

# CENTRAL CONFIGURATION LOADER - Loads defaults from JSON and sanitizes all parameters
Write-Host "🔧 Loading configuration and sanitizing parameters..." -ForegroundColor Yellow

# Load configuration from JSON file
# Handle both local and containerized environments
if ($PSScriptRoot -like "/scripts/*") {
    # Running in container - use absolute path
    $configPath = "/scripts/self_service_defaults.json"
} else {
    # Running locally - use relative path
    $configPath = Join-Path $PSScriptRoot "../../self_service_defaults.json"
}
if (Test-Path $configPath) {
    try {
        $config = Get-Content $configPath -Raw | ConvertFrom-Json
        Write-Host "✅ Configuration loaded from: $configPath" -ForegroundColor Green
    } catch {
        Write-Host "⚠️ Failed to load configuration: $($_.Exception.Message)" -ForegroundColor Yellow
        $config = @{ self_service_defaults = @{} }
    }
} else {
    Write-Host "⚠️ Configuration file not found: $configPath" -ForegroundColor Yellow
    $config = @{ self_service_defaults = @{} }
}

# Create parameter hashtable for sanitization with defaults from config
# Note: RestoreDateTime and Timezone will be handled by Get-AutomationDateTime function
$paramHash = @{
    RestoreDateTime = $RestoreDateTime  # Keep original value, will be processed by Get-AutomationDateTime
    SourceNamespace = if ([string]::IsNullOrWhiteSpace($SourceNamespace)) { $config.self_service_defaults.source_namespace } else { $SourceNamespace }
    Source = if ([string]::IsNullOrWhiteSpace($Source)) { $config.self_service_defaults.source } else { $Source }
    DestinationNamespace = if ([string]::IsNullOrWhiteSpace($DestinationNamespace)) { $config.self_service_defaults.destination_namespace } else { $DestinationNamespace }
    Destination = if ([string]::IsNullOrWhiteSpace($Destination)) { $config.self_service_defaults.destination } else { $Destination }
    CustomerAlias = if ([string]::IsNullOrWhiteSpace($CustomerAlias)) { $config.self_service_defaults.customer_alias } else { $CustomerAlias }
    CustomerAliasToRemove = if ([string]::IsNullOrWhiteSpace($CustomerAliasToRemove)) { $config.self_service_defaults.customer_alias_to_remove } else { $CustomerAliasToRemove }
    Cloud = if ([string]::IsNullOrWhiteSpace($Cloud)) { $config.self_service_defaults.cloud } else { $Cloud }
    MaxWaitMinutes = if ($MaxWaitMinutes -eq 0) { $config.self_service_defaults.max_wait_minutes } else { $MaxWaitMinutes }
    Timezone = $Timezone  # Keep original value, will be processed by Get-AutomationDateTime
}

# Load and use the parameter sanitization function
$sanitizedParams = & "$PSScriptRoot/../common/Initialize-Parameters.ps1" -Parameters $paramHash

# Apply sanitized values
$RestoreDateTime = $sanitizedParams.RestoreDateTime
$SourceNamespace = $sanitizedParams.SourceNamespace
$Source = $sanitizedParams.Source
$DestinationNamespace = $sanitizedParams.DestinationNamespace
$Destination = $sanitizedParams.Destination
$CustomerAlias = $sanitizedParams.CustomerAlias
$CustomerAliasToRemove = $sanitizedParams.CustomerAliasToRemove
$Cloud = $sanitizedParams.Cloud
$MaxWaitMinutes = $sanitizedParams.MaxWaitMinutes
$Timezone = $sanitizedParams.Timezone

Write-Host "✅ Configuration loaded and parameters sanitized" -ForegroundColor Green

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

# 🛡️ AUTOMATION-READY FUNCTIONS
function Write-AutomationLog {
    param(
        [string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR", "SUCCESS")]
        [string]$Level = "INFO"
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"
    
    # Color coding for console
    switch ($Level) {
        "INFO" { Write-Host $logMessage -ForegroundColor Cyan }
        "WARN" { Write-Host $logMessage -ForegroundColor Yellow }
        "ERROR" { Write-Host $logMessage -ForegroundColor Red }
        "SUCCESS" { Write-Host $logMessage -ForegroundColor Green }
    }
    
    # Write to log file if specified
    if (-not [string]::IsNullOrEmpty($LogFile)) {
        try {
            # Ensure the directory exists
            $logDir = Split-Path -Parent $LogFile
            if (-not (Test-Path $logDir)) {
                New-Item -ItemType Directory -Path $logDir -Force | Out-Null
            }
            Add-Content -Path $LogFile -Value $logMessage -Force
        } catch {
            # If logging fails, just continue - don't break the script
            Write-Host "Warning: Could not write to log file: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
}

function Test-Prerequisites {
    param([switch]$DryRun)
    
    Write-AutomationLog "🔍 Validating prerequisites for automation..." "INFO"
    $errors = @()
    
    # Check Azure CLI
    try {
        $azVersion = az version --output json 2>$null | ConvertFrom-Json
        if (-not $azVersion) { throw "Azure CLI not found" }
        Write-AutomationLog "✅ Azure CLI found: $($azVersion.'azure-cli')" "SUCCESS"
    } catch {
        $errors += "❌ Azure CLI not installed or not in PATH"
    }
    
    # Check Azure CLI authentication (informational - will be handled in main flow)
    try {
        $account = az account show 2>$null | ConvertFrom-Json
        if (-not $account) { 
            Write-AutomationLog "ℹ️ Azure CLI not currently authenticated - will authenticate during execution" "INFO"
        } else {
            Write-AutomationLog "✅ Azure CLI pre-authenticated as: $($account.user.name)" "SUCCESS"
        }
    } catch {
        Write-AutomationLog "ℹ️ Azure CLI authentication will be handled during script execution" "INFO"
    }
    
    # Check PowerShell modules (informational - using Azure CLI instead)
    if (-not $DryRun) {
        $requiredModules = @("Az.Accounts", "Az.Resources")
        foreach ($module in $requiredModules) {
            if (-not (Get-Module -ListAvailable -Name $module)) {
                Write-AutomationLog "ℹ️ PowerShell module '$module' not installed - using Azure CLI instead" "INFO"
            } else {
                Write-AutomationLog "✅ PowerShell module '$module' available" "SUCCESS"
            }
        }
    } else {
        Write-AutomationLog "ℹ️ PowerShell module check skipped in dry-run mode - using Azure CLI" "INFO"
    }
    
    # Check kubectl (for environment management)
    try {
        kubectl version --client --output=json 2>$null | Out-Null
        Write-AutomationLog "✅ kubectl found and configured" "SUCCESS"
    } catch {
        Write-AutomationLog "⚠️  kubectl not found - some steps may fail" "WARN"
    }
    
    if ($errors.Count -gt 0) {
        Write-AutomationLog "❌ Prerequisites validation failed:" "ERROR"
        foreach ($error in $errors) {
            Write-AutomationLog $error "ERROR"
        }
        throw "Prerequisites not met. Please fix the above issues before running."
    }
    
    Write-AutomationLog "✅ All prerequisites validated successfully" "SUCCESS"
}

function Get-AutomationDateTime {
    param(
        [string]$RestoreDateTime,
        [string]$Timezone
    )
    
    Write-AutomationLog "🕐 Processing restore point in time for automation..." "INFO"
    
    # Handle RestoreDateTime
    if ([string]::IsNullOrWhiteSpace($RestoreDateTime)) {
        $RestoreDateTime = (Get-Date).AddMinutes(-15).ToString("yyyy-MM-dd HH:mm:ss")
        Write-AutomationLog "🤖 Auto-selected restore time: $RestoreDateTime (15 minutes ago)" "INFO"
    } else {
        Write-AutomationLog "📅 Using provided restore time: $RestoreDateTime" "INFO"
    }
    
    # Handle Timezone
    if ([string]::IsNullOrWhiteSpace($Timezone)) {
        # Use current system timezone as default
        $Timezone = [System.TimeZoneInfo]::Local.Id
        Write-AutomationLog "🌍 Auto-selected timezone: $Timezone (current system timezone)" "INFO"
    } else {
        Write-AutomationLog "🌍 Using provided timezone: $Timezone" "INFO"
    }
    
    return @{
        RestoreDateTime = $RestoreDateTime
        Timezone = $Timezone
    }
}

function Perform-Migration {
    
    # 🛡️ AUTOMATION: Validate prerequisites first
    Write-AutomationLog "🔍 DryRun mode: $DryRun" "INFO"
    if (-not $DryRun) {
        Write-AutomationLog "🔍 Running prerequisites check (not in dry-run mode)" "INFO"
        Test-Prerequisites -DryRun:$DryRun
    } else {
        Write-AutomationLog "🔍 Skipping prerequisites check in dry-run mode" "INFO"
    }

    # 🔐 Azure Authentication using Connect-Azure script
    Write-Host "🔐 Authenticating to Azure..." -ForegroundColor Cyan
    
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
        $commonDir = Join-Path $global:ScriptBaseDir "common"
        $authScript = Join-Path $commonDir "Connect-Azure.ps1"
        Write-Host "🔍 Looking for auth script at: $authScript" -ForegroundColor Gray
    } else {
        # Fallback: try new PowerShell-only structure
        $global:ScriptBaseDir = "/scripts"
        $authScript = "/scripts/common/Connect-Azure.ps1"
        Write-Host "🔍 Using fallback paths - Base: $global:ScriptBaseDir, Auth: $authScript" -ForegroundColor Gray
    }
    
    if (Test-Path $authScript) {
        Write-Host "📝 Using authentication script: $authScript" -ForegroundColor Gray
        $authResult = & $authScript -Cloud $Cloud
        if (-not $authResult) {
            Write-AutomationLog "❌ FATAL ERROR: Failed to authenticate to Azure" "ERROR"
            Write-Host "❌ Azure authentication failed. Cannot proceed." -ForegroundColor Red
            exit 1
        }
        Write-Host "✅ Azure authentication successful" -ForegroundColor Green
    } else {
        Write-AutomationLog "⚠️ Authentication script not found at $authScript, attempting manual Azure CLI setup" "WARN"
        Write-Host "Setting Azure CLI to use cloud: $Cloud" -ForegroundColor Cyan
        az cloud set --name $Cloud
        
        # Check if already authenticated
        $accountCheck = az account show 2>$null
        if (-not $accountCheck) {
            Write-AutomationLog "❌ FATAL ERROR: Not authenticated to Azure and no authentication script found" "ERROR"
            Write-Host "❌ Please run 'az login' or ensure Connect-Azure.ps1 is available" -ForegroundColor Red
            exit 1
        }
        Write-Host "✅ Using existing Azure CLI authentication" -ForegroundColor Green
    }
    
    # Set domain based on cloud environment for downstream scripts
    switch ($Cloud) {
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
        -Cloud $Cloud `
        -Source $Source `
        -Destination $Destination `
        -CustomerAlias $CustomerAlias `
        -CustomerAliasToRemove $CustomerAliasToRemove `
        -SourceNamespace $SourceNamespace `
        -DestinationNamespace $DestinationNamespace `
        -Domain $Domain `
        -DryRun:($DryRun -eq $true) `
        -MaxWaitMinutes $MaxWaitMinutes
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
        [int]$MaxWaitMinutes
    )

    Write-Host "🔁 Running self-service data refresh" -ForegroundColor Yellow
    Write-Host "▶️ Source: $Source $SourceNamespace"
    Write-Host "▶️ Destination: $Destination $DestinationNamespace"
    Write-Host "☁️ Cloud: $Cloud"
    Write-Host "👤 Customer Alias: $CustomerAlias"
    

    if ($DryRun) {
        Write-Host "🔍 DRY RUN MODE ENABLED - No actual changes will be made" -ForegroundColor Yellow
    }
    Write-Host "⏱️ Max Wait Time: $MaxWaitMinutes minutes" -ForegroundColor Cyan

    ### Self-Service data refresh 
    
    # 🤖 AUTOMATION: Handle restore datetime and timezone without prompts
    Write-Host "`n🕐 RESTORE POINT IN TIME" -ForegroundColor Cyan
    Write-Host "=========================" -ForegroundColor Cyan
    
    # Automatic processing - no interactive prompts
    Write-AutomationLog "🤖 AUTOMATION MODE: Processing datetime and timezone automatically" "INFO"
    $dateTimeInfo = Get-AutomationDateTime -RestoreDateTime $RestoreDateTime -Timezone $Timezone
    $RestoreDateTime = $dateTimeInfo.RestoreDateTime
    $timezone = $dateTimeInfo.Timezone
    
    Write-Host "Selected timezone: $timezone" -ForegroundColor Green
    
    # Step 1: Restore Point in Time
    Write-Host "`n🔄 STEP 1: RESTORE POINT IN TIME" -ForegroundColor Cyan
    if ($DryRun) {
        Write-Host "🔍 DRY RUN: Would execute restore point in time" -ForegroundColor Yellow
        Write-Host "🔍 DRY RUN: Restore DateTime: $RestoreDateTime" -ForegroundColor Gray
        Write-Host "🔍 DRY RUN: Timezone: $timezone" -ForegroundColor Gray
        Write-Host "🔍 DRY RUN: Source: $Source $SourceNamespace" -ForegroundColor Gray
        Write-Host "🔍 DRY RUN: Would restore databases to point in time with '-restored' suffix" -ForegroundColor Gray
        Write-Host "🔍 DRY RUN: Would wait up to $MaxWaitMinutes minutes for restoration" -ForegroundColor Gray
        $scriptPath = Get-ScriptPath "restore/RestorePointInTime.ps1"
        & $scriptPath -source $Source -SourceNamespace $SourceNamespace -RestoreDateTime $RestoreDateTime -Timezone $timezone -DryRun:$DryRun  -MaxWaitMinutes $MaxWaitMinutes
    } else {
        $scriptPath = Get-ScriptPath "restore/RestorePointInTime.ps1"
        & $scriptPath -source $Source -SourceNamespace $SourceNamespace -RestoreDateTime $RestoreDateTime -Timezone $timezone -DryRun:$DryRun  -MaxWaitMinutes $MaxWaitMinutes
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
    
    # Final summary for dry run mode
    if ($DryRun) {
        Write-Host "`n====================================" -ForegroundColor Cyan
        Write-Host " DRY RUN COMPLETED" -ForegroundColor Cyan
        Write-Host "====================================`n" -ForegroundColor Cyan
        Write-Host "🔍 This was a dry run - no actual changes were made" -ForegroundColor Yellow
        Write-Host "📋 The following operations would have been performed:" -ForegroundColor Cyan
        Write-Host "   • Restore databases to point in time: $RestoreDateTime ($timezone)" -ForegroundColor Gray
        Write-Host "   • Copy attachments from $Source to $Destination" -ForegroundColor Gray
        Write-Host "   • Copy databases from $Source to $Destination" -ForegroundColor Gray
        Write-Host "   • Clean up source environment configurations (CORS origins, redirect URIs)" -ForegroundColor Gray
        Write-Host "   • Revert source environment SQL users and roles" -ForegroundColor Gray
        Write-Host "   • Adjust database resources and configurations" -ForegroundColor Gray
        Write-Host "   • Delete and recreate replica databases" -ForegroundColor Gray
        Write-Host "   • Configure SQL users and permissions" -ForegroundColor Gray
        Write-Host "   • Clean up temporary restored databases" -ForegroundColor Gray
        Write-Host "`n💡 To execute the actual operations, run without the -DryRun parameter" -ForegroundColor Green
    } else {
        Write-Host "`n====================================" -ForegroundColor Cyan
        Write-Host " SELF-SERVICE REFRESH COMPLETED" -ForegroundColor Cyan
        Write-Host "====================================`n" -ForegroundColor Cyan
        Write-Host "✅ All operations completed successfully!" -ForegroundColor Green
    }
}



# 🚀 MAIN EXECUTION WITH AUTOMATION SUPPORT
Write-AutomationLog "🚀 Starting Self-Service Data Refresh" "INFO"
Write-AutomationLog "📋 Parameters: Source=$Source/$SourceNamespace → Destination=$Destination/$DestinationNamespace" "INFO"
Write-AutomationLog "☁️  Cloud: $Cloud | DryRun: $DryRun" "INFO"
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