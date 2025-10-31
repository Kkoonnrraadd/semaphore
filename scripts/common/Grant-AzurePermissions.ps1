<#
.SYNOPSIS
    Grants Azure permissions with intelligent propagation wait logic
    
.DESCRIPTION
    Wrapper around Invoke-AzureFunctionPermission.ps1 that provides:
    - Smart propagation wait (only waits if permissions were actually added)
    - Consistent error handling
    - Structured output for automation
    
.PARAMETER Environment
    Target environment name (e.g., "gov001", "qa2")
    
.PARAMETER ServiceAccount
    Service account name (default: "SelfServiceRefresh")
    
.PARAMETER TimeoutSeconds
    HTTP request timeout in seconds (default: 60)
    
.PARAMETER PropagationWaitSeconds
    Wait time in seconds for permissions to propagate if changes were made (default: 30)
    
.OUTPUTS
    Hashtable with:
    - Success: Boolean indicating if operation succeeded
    - NeedsPropagationWait: Boolean indicating if caller should wait for propagation
    - PermissionsAdded: Integer count of permissions actually added
    - Error: Error message if failed
    - Duration: Operation duration in seconds
    
.EXAMPLE
    $result = & Grant-AzurePermissions.ps1 -Environment "gov001"
    if ($result.NeedsPropagationWait) {
        Write-Host "Waiting for propagation..."
        Start-Sleep -Seconds 30
    }
    
.NOTES
    This script should be dot-sourced or called by other scripts.
    It uses Invoke-AzureFunctionPermission.ps1 under the hood.
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$Environment,
    
    # [string]$ServiceAccount = "SelfServiceRefresh",
    [string]$ServiceAccount = "semaphore-semaphore-mnfrotest-prod-gov001-virg",
    
    [int]$TimeoutSeconds = 60,
    
    [int]$PropagationWaitSeconds = 30
)

# ═══════════════════════════════════════════════════════════════════════════
# DETERMINE SCRIPT DIRECTORY
# ═══════════════════════════════════════════════════════════════════════════

$scriptDir = if ($global:ScriptBaseDir) {
    $global:ScriptBaseDir
} else {
    Split-Path -Parent $PSScriptRoot
}

# ═══════════════════════════════════════════════════════════════════════════
# MAIN EXECUTION
# ═══════════════════════════════════════════════════════════════════════════

Write-Host "🔐 Granting Azure permissions..." -ForegroundColor Cyan
Write-Host "   Environment: $Environment" -ForegroundColor Gray
Write-Host "   Service Account: $ServiceAccount" -ForegroundColor Gray
Write-Host ""

try {
    # Call the Azure Function permission script with NoWait flag
    # We'll analyze the response to determine if we need to wait
    $permissionScript = Join-Path $scriptDir "permissions/Invoke-AzureFunctionPermission.ps1"
    
    if (-not (Test-Path $permissionScript)) {
        return @{
            Success = $false
            NeedsPropagationWait = $false
            PermissionsAdded = 0
            Error = "Permission script not found at: $permissionScript"
            Duration = 0
        }
    }
    
    # Call with NoWait - we'll handle waiting ourselves based on response
    $permissionResult = & $permissionScript `
        -Action "Grant" `
        -Environment $Environment `
        -ServiceAccount $ServiceAccount `
        -TimeoutSeconds $TimeoutSeconds `
        -NoWait
    
    if (-not $permissionResult.Success) {
        Write-Host "   ❌ Permission grant failed: $($permissionResult.Error)" -ForegroundColor Red
        Write-Host "   ⚠️  Continuing anyway - some operations may fail" -ForegroundColor Yellow
        Write-Host ""
        
        return @{
            Success = $false
            NeedsPropagationWait = $false
            PermissionsAdded = 0
            Error = $permissionResult.Error
            Duration = $permissionResult.Duration
        }
    }
    
    # Parse the response to check if any groups were actually added
    $responseText = if ($permissionResult.Response -is [string]) {
        $permissionResult.Response
    } else {
        $permissionResult.Response | ConvertTo-Json -Compress
    }
    
    Write-Host "   📋 Azure Function Response:" -ForegroundColor Gray
    Write-Host "      $responseText" -ForegroundColor DarkGray
    Write-Host ""
    
    $permissionsAdded = 0
    $needsWait = $false
    
    # Try to extract the count of successfully added permissions
    if ($responseText -match "(\d+) succeeded") {
        $permissionsAdded = [int]$matches[1]
        
        Write-Host "   📊 Parsed result: $permissionsAdded permission(s) successfully added" -ForegroundColor Gray
        
        if ($permissionsAdded -gt 0) {
            Write-Host "   ✅ Permissions granted: $permissionsAdded group(s) added" -ForegroundColor Green
            Write-Host "   ⏳ Propagation wait REQUIRED (changes were made to Azure AD)" -ForegroundColor Yellow
            $needsWait = $true
        } else {
            Write-Host "   ✅ Permissions already configured (no changes needed)" -ForegroundColor Green
            Write-Host "   ⚡ Propagation wait SKIPPED - service principal already has access" -ForegroundColor Cyan
            $needsWait = $false
        }
    } else {
        # Couldn't parse response - be safe and recommend waiting
        Write-Host "   ⚠️  Could not parse response (pattern '(\d+) succeeded' not found)" -ForegroundColor Yellow
        Write-Host "   ✅ Permissions granted successfully" -ForegroundColor Green
        Write-Host "   ⏳ Propagation wait RECOMMENDED (unable to determine if changes were made)" -ForegroundColor Yellow
        $needsWait = $true
    }
    
    Write-Host ""
    
    return @{
        Success = $true
        NeedsPropagationWait = $needsWait
        PermissionsAdded = $permissionsAdded
        PropagationWaitSeconds = $PropagationWaitSeconds
        Error = $null
        Duration = $permissionResult.Duration
        Response = $responseText
    }
    
} catch {
    Write-Host "   ❌ Error during permission grant: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "   ⚠️  Continuing anyway - some operations may fail" -ForegroundColor Yellow
    Write-Host ""
    
    return @{
        Success = $false
        NeedsPropagationWait = $false
        PermissionsAdded = 0
        Error = $_.Exception.Message
        Duration = 0
    }
}

