<#
.SYNOPSIS
    Orchestrates all prerequisite steps (0A, 0B, 0C) for Azure operations
    
.DESCRIPTION
    This unified function handles:
    - STEP 0A: Grant Azure permissions (with smart propagation wait)
    - STEP 0B: Azure authentication 
    - STEP 0C: Auto-detect missing parameters from Azure
    
    Used by both self_service.ps1 and invoke_step.ps1 to eliminate code duplication.
    
.PARAMETER TargetEnvironment
    Environment name for permission grant (e.g., "gov001", "qa2")
    If not provided, will try to detect from Parameters or ENVIRONMENT variable
    
.PARAMETER Parameters
    Hashtable of existing parameters (for invoke_step.ps1 usage)
    Used to extract environment, cloud, etc.
    
.PARAMETER Cloud
    Azure cloud environment (AzureCloud or AzureUSGovernment)
    If not provided, will auto-detect during authentication
    
.PARAMETER SkipPermissions
    Skip the permission grant step (Step 0A)
    
.PARAMETER SkipAuthentication
    Skip the authentication step (Step 0B) - assumes already authenticated
    
.PARAMETER SkipParameterDetection
    Skip the parameter detection step (Step 0C)
    
.OUTPUTS
    Hashtable with:
    - Success: Boolean indicating if all steps succeeded
    - DetectedParameters: Hashtable of auto-detected parameters
    - PermissionResult: Result from permission grant
    - AuthenticationResult: Result from authentication
    - Error: Error message if failed
    
.EXAMPLE
    # Usage in self_service.ps1
    $result = & Invoke-PrerequisiteSteps.ps1 -TargetEnvironment "gov001" -Cloud "AzureUSGovernment"
    if (-not $result.Success) { throw $result.Error }
    
.EXAMPLE
    # Usage in invoke_step.ps1
    $result = & Invoke-PrerequisiteSteps.ps1 -Parameters $scriptParams
    $scriptParams = Merge-Parameters $scriptParams $result.DetectedParameters
    
.NOTES
    This script consolidates logic previously duplicated between:
    - scripts/main/self_service.ps1 (lines 164-349)
    - scripts/step_wrappers/invoke_step.ps1 (lines 226-459)
#>

param(
    [string]$TargetEnvironment = "",
    
    [hashtable]$Parameters = @{},
    
    [string]$Cloud = "",
    
    [switch]$SkipPermissions,
    
    [switch]$SkipAuthentication,
    
    [switch]$SkipParameterDetection
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
# HELPER FUNCTION: Determine Target Environment
# ═══════════════════════════════════════════════════════════════════════════

function Get-TargetEnvironment {
    param([hashtable]$Params)
    
    # Priority order:
    # 1. Explicit TargetEnvironment parameter
    # 2. Source from Parameters
    # 3. Destination from Parameters
    # 4. Environment from Parameters
    # 5. ENVIRONMENT variable
    
    if (-not [string]::IsNullOrWhiteSpace($TargetEnvironment)) {
        return $TargetEnvironment
    }
    
    if ($Params.ContainsKey("Source") -and -not [string]::IsNullOrWhiteSpace($Params["Source"])) {
        return $Params["Source"]
    }
    
    if ($Params.ContainsKey("Destination") -and -not [string]::IsNullOrWhiteSpace($Params["Destination"])) {
        return $Params["Destination"]
    }
    
    if ($Params.ContainsKey("Environment") -and -not [string]::IsNullOrWhiteSpace($Params["Environment"])) {
        return $Params["Environment"]
    }
    
    if (-not [string]::IsNullOrWhiteSpace($env:ENVIRONMENT)) {
        return $env:ENVIRONMENT
    }
    
    return $null
}

# ═══════════════════════════════════════════════════════════════════════════
# INITIALIZE RESULT OBJECT
# ═══════════════════════════════════════════════════════════════════════════

$result = @{
    Success = $true
    DetectedParameters = @{}
    PermissionResult = $null
    AuthenticationResult = $false
    NeedsPropagationWait = $false
    PropagationWaitSeconds = 0
    Error = $null
}

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════════════════" -ForegroundColor Magenta
Write-Host "🔧 RUNNING PREREQUISITE STEPS" -ForegroundColor Magenta
Write-Host "═══════════════════════════════════════════════════════════════════════════" -ForegroundColor Magenta
Write-Host ""

# ═══════════════════════════════════════════════════════════════════════════
# STEP 0A: GRANT PERMISSIONS
# ═══════════════════════════════════════════════════════════════════════════

if (-not $SkipPermissions) {
    Write-Host "🔐 STEP 0A: GRANT PERMISSIONS" -ForegroundColor Cyan
    Write-Host ""
    
    $targetEnv = Get-TargetEnvironment -Params $Parameters
    
    if ($targetEnv) {
        Write-Host "   📋 Target Environment: $targetEnv" -ForegroundColor Gray
        
        try {
            $grantScript = Join-Path $scriptDir "common/Grant-AzurePermissions.ps1"
            
            if (Test-Path $grantScript) {
                $permResult = & $grantScript -Environment $targetEnv
                $result.PermissionResult = $permResult
                
                if ($permResult.Success) {
                    # Store propagation wait info for later (after authentication)
                    $result.NeedsPropagationWait = $permResult.NeedsPropagationWait
                    $result.PropagationWaitSeconds = $permResult.PropagationWaitSeconds
                } else {
                    Write-Host "   ⚠️  Permission grant had issues, but continuing..." -ForegroundColor Yellow
                }
            } else {
                Write-Host "   ⚠️  Permission script not found: $grantScript" -ForegroundColor Yellow
            }
        } catch {
            Write-Host "   ⚠️  Permission grant error: $($_.Exception.Message)" -ForegroundColor Yellow
            Write-Host "   Continuing anyway..." -ForegroundColor Gray
        }
    } else {
        Write-Host "   ⚠️  No environment specified - skipping permission grant" -ForegroundColor Yellow
        Write-Host "      Set Source, Destination, Environment, or ENVIRONMENT variable" -ForegroundColor Gray
    }
    
    Write-Host ""
} else {
    Write-Host "🔐 STEP 0A: GRANT PERMISSIONS (SKIPPED)" -ForegroundColor DarkGray
    Write-Host ""
}

# ═══════════════════════════════════════════════════════════════════════════
# STEP 0B: AZURE AUTHENTICATION
# ═══════════════════════════════════════════════════════════════════════════

if (-not $SkipAuthentication) {
    Write-Host "🔐 STEP 0B: AZURE AUTHENTICATION" -ForegroundColor Cyan
    Write-Host ""
    
    try {
        $authScript = Join-Path $scriptDir "common/Connect-Azure.ps1"
        
        if (Test-Path $authScript) {
            Write-Host "   🔑 Authenticating to Azure..." -ForegroundColor Gray
            
            # Use Cloud parameter if provided (either directly or from Parameters hashtable)
            $cloudParam = if (-not [string]::IsNullOrWhiteSpace($Cloud)) {
                $Cloud
            } elseif ($Parameters.ContainsKey("Cloud") -and -not [string]::IsNullOrWhiteSpace($Parameters["Cloud"])) {
                $Parameters["Cloud"]
            } else {
                ""
            }
            
            if (-not [string]::IsNullOrWhiteSpace($cloudParam)) {
                Write-Host "   🌐 Using specified cloud: $cloudParam" -ForegroundColor Gray
                $authResult = & $authScript -Cloud $cloudParam
            } else {
                Write-Host "   🌐 Auto-detecting cloud..." -ForegroundColor Gray
                $authResult = & $authScript
            }
            
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
    
    # NOW perform propagation wait if needed (after successful authentication)
    if ($result.NeedsPropagationWait) {
        $waitSeconds = $result.PropagationWaitSeconds
        Write-Host ""
        Write-Host "   ⏳ Waiting $waitSeconds seconds for Azure AD permissions to propagate..." -ForegroundColor Yellow
        
        # Progress bar for better UX
        for ($i = 1; $i -le $waitSeconds; $i++) {
            $percent = [math]::Round(($i / $waitSeconds) * 100)
            Write-Progress -Activity "Azure AD Permission Propagation" -Status "$i / $waitSeconds seconds" -PercentComplete $percent
            Start-Sleep -Seconds 1
        }
        Write-Progress -Activity "Azure AD Permission Propagation" -Completed
        
        Write-Host "   ✅ Permission propagation wait completed" -ForegroundColor Green
    }
    
    Write-Host ""
} else {
    Write-Host "🔐 STEP 0B: AZURE AUTHENTICATION (SKIPPED)" -ForegroundColor DarkGray
    Write-Host ""
}

# ═══════════════════════════════════════════════════════════════════════════
# STEP 0C: AUTO-DETECT PARAMETERS
# ═══════════════════════════════════════════════════════════════════════════

if (-not $SkipParameterDetection) {
    Write-Host "🔧 STEP 0C: AUTO-DETECT PARAMETERS" -ForegroundColor Cyan
    Write-Host ""
    
    try {
        $azureParamsScript = Join-Path $scriptDir "common/Get-AzureParameters.ps1"
        
        if (Test-Path $azureParamsScript) {
            Write-Host "   🔍 Detecting missing parameters from Azure..." -ForegroundColor Gray
            
            # Build parameters for detection script
            $detectionParams = @{}
            
            if ($Parameters.ContainsKey("Source")) {
                $detectionParams["Source"] = $Parameters["Source"]
            }
            if ($Parameters.ContainsKey("Destination")) {
                $detectionParams["Destination"] = $Parameters["Destination"]
            }
            if ($Parameters.ContainsKey("SourceNamespace")) {
                $detectionParams["SourceNamespace"] = $Parameters["SourceNamespace"]
            }
            if ($Parameters.ContainsKey("DestinationNamespace")) {
                $detectionParams["DestinationNamespace"] = $Parameters["DestinationNamespace"]
            }
            
            $detectedParams = & $azureParamsScript @detectionParams
            
            if ($detectedParams) {
                # Store all detected parameters
                $result.DetectedParameters = $detectedParams
                
                # Show what was detected
                $detectedCount = 0
                foreach ($key in $detectedParams.Keys) {
                    if (-not [string]::IsNullOrWhiteSpace($detectedParams[$key])) {
                        Write-Host "   ✅ Auto-detected $key`: $($detectedParams[$key])" -ForegroundColor Green
                        $detectedCount++
                    }
                }
                
                if ($detectedCount -gt 0) {
                    Write-Host "   ✅ Parameter auto-detection completed ($detectedCount parameter(s))" -ForegroundColor Green
                } else {
                    Write-Host "   ℹ️  No additional parameters detected" -ForegroundColor Gray
                }
            }
        } else {
            Write-Host "   ⚠️  Parameter detection script not found: $azureParamsScript" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "   ⚠️  Parameter detection failed: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "   Continuing with provided parameters only..." -ForegroundColor Gray
    }
    
    Write-Host ""
} else {
    Write-Host "🔧 STEP 0C: AUTO-DETECT PARAMETERS (SKIPPED)" -ForegroundColor DarkGray
    Write-Host ""
}

# ═══════════════════════════════════════════════════════════════════════════
# COMPLETION
# ═══════════════════════════════════════════════════════════════════════════

Write-Host "═══════════════════════════════════════════════════════════════════════════" -ForegroundColor Magenta
Write-Host "✅ PREREQUISITES COMPLETED" -ForegroundColor Magenta
Write-Host "═══════════════════════════════════════════════════════════════════════════" -ForegroundColor Magenta
Write-Host ""

return $result

