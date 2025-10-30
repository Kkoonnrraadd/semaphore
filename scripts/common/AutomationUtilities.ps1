<#
.SYNOPSIS
    Common utility functions for automation scripts

.DESCRIPTION
    This module provides reusable functions for logging, prerequisites checking,
    and other common automation tasks.

.NOTES
    Author: DevOps Team
    These functions are designed for automation and non-interactive execution
#>

# Export functions for module usage
$ErrorActionPreference = "Stop"

# 🛡️ LOGGING FUNCTIONS
function Write-AutomationLog {
    <#
    .SYNOPSIS
        Writes structured log messages with timestamp and level
    
    .PARAMETER Message
        Log message content
    
    .PARAMETER Level
        Log level: INFO, WARN, ERROR, SUCCESS
    
    .PARAMETER LogFile
        Optional log file path. If not specified, uses script-level $LogFile variable
    #>
    param(
        [string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR", "SUCCESS")]
        [string]$Level = "INFO",
        [string]$LogFile
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"
    
    # Color coding for console
    switch ($Level) {
        "INFO"    { Write-Host $logMessage -ForegroundColor Cyan }
        "WARN"    { Write-Host $logMessage -ForegroundColor Yellow }
        "ERROR"   { Write-Host $logMessage -ForegroundColor Red }
        "SUCCESS" { Write-Host $logMessage -ForegroundColor Green }
    }
    
    # Write to log file if specified or if script-level variable exists
    $targetLogFile = if ($LogFile) { $LogFile } elseif ($script:LogFile) { $script:LogFile } else { $null }
    
    if (-not [string]::IsNullOrEmpty($targetLogFile)) {
        try {
            # Ensure the directory exists
            $logDir = Split-Path -Parent $targetLogFile
            if ($logDir -and -not (Test-Path $logDir)) {
                New-Item -ItemType Directory -Path $logDir -Force | Out-Null
            }
            Add-Content -Path $targetLogFile -Value $logMessage -Force
        } catch {
            # If logging fails, just continue - don't break the script
            Write-Host "Warning: Could not write to log file: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
}

# 🔍 PREREQUISITES CHECKING
function Test-Prerequisites {
    <#
    .SYNOPSIS
        Validates that all required tools and modules are available
    
    .PARAMETER DryRun
        Skip checks that are not needed in dry-run mode
    #>
    param(
        [switch]$DryRun
    )
    
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
    
    # Check PowerShell modules (SqlServer required for Invoke-SqlCmd)
    $requiredModules = @("SqlServer")
    foreach ($module in $requiredModules) {
        if (-not (Get-Module -ListAvailable -Name $module)) {
            Write-AutomationLog "❌ PowerShell module '$module' not installed - required for SQL operations" "ERROR"
            $errors += "Missing required PowerShell module: $module"
        } else {
            Write-AutomationLog "✅ PowerShell module '$module' available" "SUCCESS"
        }
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
        foreach ($err in $errors) {
            Write-AutomationLog $err "ERROR"
        }
        throw "Prerequisites not met. Please fix the above issues before running."
    }
    
    Write-AutomationLog "✅ All prerequisites validated successfully" "SUCCESS"
}

# 🕐 DATETIME HANDLING
function Get-AutomationDateTime {
    <#
    .SYNOPSIS
        Processes restore datetime and timezone for automation (no prompts)
    
    .PARAMETER RestoreDateTime
        Restore datetime string (format: "yyyy-MM-dd HH:mm:ss"). If empty, uses 15 minutes ago.
    
    .PARAMETER Timezone
        Timezone identifier. If empty, uses system timezone.
    #>
    param(
        [string]$RestoreDateTime,
        [string]$Timezone
    )
    
    Write-AutomationLog "🕐 Processing restore point in time for automation..." "INFO"
    
    # Handle Timezone FIRST (needed to calculate default RestoreDateTime correctly)
    if ([string]::IsNullOrWhiteSpace($Timezone)) {
        # Check for SEMAPHORE_SCHEDULE_TIMEZONE environment variable
        $envTimezone = [System.Environment]::GetEnvironmentVariable("SEMAPHORE_SCHEDULE_TIMEZONE")
        
        if (-not [string]::IsNullOrWhiteSpace($envTimezone)) {
            $Timezone = $envTimezone
            Write-AutomationLog "🌍 Auto-selected timezone from SEMAPHORE_SCHEDULE_TIMEZONE: $Timezone" "INFO"
        } else {
            # FAIL: Timezone is required - do not proceed with incorrect data
            Write-AutomationLog "❌ FATAL ERROR: Timezone parameter is required but not provided" "ERROR"
            Write-AutomationLog "   Please provide timezone via:" "ERROR"
            Write-AutomationLog "   1. -Timezone parameter in the script call" "ERROR"
            Write-AutomationLog "   2. SEMAPHORE_SCHEDULE_TIMEZONE environment variable" "ERROR"
            throw "Timezone is required. Set SEMAPHORE_SCHEDULE_TIMEZONE environment variable or provide -Timezone parameter."
        }
    } else {
        Write-AutomationLog "🌍 Using provided timezone: $Timezone" "INFO"
    }
    
    # Handle RestoreDateTime (now that we know the timezone)
    if ([string]::IsNullOrWhiteSpace($RestoreDateTime)) {
        try {
            # Calculate restore time in the configured timezone
            $timezoneInfo = [System.TimeZoneInfo]::FindSystemTimeZoneById($Timezone)
            $utcNow = [DateTime]::UtcNow
            $currentTimeInTimezone = [System.TimeZoneInfo]::ConvertTimeFromUtc($utcNow, $timezoneInfo)
            $RestoreDateTime = $currentTimeInTimezone.AddMinutes(-15).ToString("yyyy-MM-dd HH:mm:ss")
            Write-AutomationLog "🤖 Auto-selected restore time: $RestoreDateTime (15 minutes ago in $Timezone)" "INFO"
        } catch {
            Write-AutomationLog "❌ ERROR: Invalid timezone '$Timezone': $($_.Exception.Message)" "ERROR"
            throw "Invalid timezone configuration: $Timezone"
        }
    } else {
        Write-AutomationLog "📅 Using provided restore time: $RestoreDateTime" "INFO"
    }
    
    return @{
        RestoreDateTime = $RestoreDateTime
        Timezone = $Timezone
    }
}

# 📁 SCRIPT PATH HELPERS
function Get-ScriptPath {
    <#
    .SYNOPSIS
        Gets absolute path for a script relative to the scripts base directory
    
    .PARAMETER RelativePath
        Relative path from scripts directory (e.g., "restore/RestorePointInTime.ps1")
    #>
    param(
        [string]$RelativePath
    )
    
    if ($global:ScriptBaseDir) {
        return Join-Path $global:ScriptBaseDir $RelativePath
    } else {
        # Use current script directory structure (scripts/main -> scripts)
        $scriptDir = Split-Path $PSScriptRoot -Parent
        $fullPath = Join-Path $scriptDir $RelativePath
        return $fullPath
    }
}

# Export functions if running as module
if ($MyInvocation.InvocationName -eq '&') {
    Export-ModuleMember -Function @(
        'Write-AutomationLog',
        'Test-Prerequisites',
        'Get-AutomationDateTime',
        'Get-ScriptPath'
    )
}

