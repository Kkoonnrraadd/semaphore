<#
.SYNOPSIS
    Universal wrapper for executing individual Semaphore task steps
    
.DESCRIPTION
    This wrapper handles parameter conversion from Semaphore's "Key=Value" format
    to PowerShell's "-Parameter Value" format for any script.
    
    Usage from Semaphore:
    pwsh invoke_step.ps1 ScriptPath=restore/RestorePointInTime.ps1 Source=gov001 DryRun=true
    
.EXAMPLE
    pwsh invoke_step.ps1 ScriptPath=restore/RestorePointInTime.ps1 Source=gov001 SourceNamespace=manufacturo DryRun=true
    
.EXAMPLE
    pwsh invoke_step.ps1 ScriptPath=environment/StopEnvironment.ps1 Destination=gov001 Cloud=AzureUSGovernment DryRun=false
#>

# ═══════════════════════════════════════════════════════════════════════════
# PARAMETER PARSING FUNCTION
# ═══════════════════════════════════════════════════════════════════════════

function Parse-SemaphoreArguments {
    param([string[]]$Arguments)
    
    $parameters = @{}
    
    foreach ($arg in $Arguments) {
        if ([string]::IsNullOrWhiteSpace($arg)) { continue }
        
        # Parse "Key=Value" format
        if ($arg -match "^([^=]+)=(.*)$") {
            $paramName = $matches[1].Trim()
            $paramValue = $matches[2].Trim()
            
            # Remove surrounding quotes if present
            if ($paramValue -match '^"(.*)"$' -or $paramValue -match "^'(.*)'$") {
                $paramValue = $matches[1]
            }
            
            $parameters[$paramName] = $paramValue
            Write-Host "🔧 Parsed: $paramName = $paramValue" -ForegroundColor Gray
        }
        else {
            Write-Host "⚠️  Unrecognized format: $arg" -ForegroundColor Yellow
        }
    }
    
    return $parameters
}

# ═══════════════════════════════════════════════════════════════════════════
# BOOLEAN CONVERSION HELPER
# ═══════════════════════════════════════════════════════════════════════════

function Convert-ToBoolean {
    param([string]$Value)
    
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    
    switch ($Value.ToLower()) {
        "true"  { return $true }
        "false" { return $false }
        "1"     { return $true }
        "0"     { return $false }
        "yes"   { return $true }
        "no"    { return $false }
        default { return $false }
    }
}

# ═══════════════════════════════════════════════════════════════════════════
# MAIN EXECUTION
# ═══════════════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "🔧 UNIVERSAL STEP WRAPPER" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

# Parse all arguments
Write-Host "📋 Raw arguments: $($args -join ' ')" -ForegroundColor Gray
$parsedParams = Parse-SemaphoreArguments -Arguments $args

# Extract and validate ScriptPath (REQUIRED)
if (-not $parsedParams.ContainsKey("ScriptPath")) {
    Write-Host ""
    Write-Host "❌ FATAL ERROR: ScriptPath parameter is required" -ForegroundColor Red
    Write-Host "   Usage: pwsh invoke_step.ps1 ScriptPath=<path/to/script.ps1> [Parameter1=Value1] [Parameter2=Value2] ..." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Examples:" -ForegroundColor Cyan
    Write-Host "  pwsh invoke_step.ps1 ScriptPath=restore/RestorePointInTime.ps1 Source=gov001 DryRun=true" -ForegroundColor Gray
    Write-Host "  pwsh invoke_step.ps1 ScriptPath=environment/StopEnvironment.ps1 Destination=gov001 Cloud=AzureCloud" -ForegroundColor Gray
    Write-Host ""
    exit 1
}

$scriptPath = $parsedParams["ScriptPath"]
$parsedParams.Remove("ScriptPath")  # Remove from params to pass to target script

# ═══════════════════════════════════════════════════════════════════════════
# DYNAMIC PATH DETECTION - Find latest repository folder
# ═══════════════════════════════════════════════════════════════════════════

$baseDir = "/tmp/semaphore/project_1"
$scriptDir = Split-Path -Parent $PSScriptRoot  # Default: go up from step_wrappers/ to scripts/

Write-Host "🔍 Detecting latest repository path..." -ForegroundColor Cyan

# Check if we're in Semaphore environment
if (Test-Path $baseDir) {
    try {
        $repositories = Get-ChildItem -Path $baseDir -Directory -ErrorAction SilentlyContinue | 
            Where-Object { $_.Name -match '^repository_\d+_template_\d+$' } |
            Sort-Object LastWriteTime -Descending
        
        if ($repositories -and $repositories.Count -gt 0) {
            $latestRepo = $repositories[0]
            $latestRepoPath = $latestRepo.FullName
            
            Write-Host "   ✅ Latest repository: $($latestRepo.Name)" -ForegroundColor Green
            Write-Host "   📅 Modified: $($latestRepo.LastWriteTime)" -ForegroundColor Gray
            
            # Update script directory to latest repository
            $scriptDir = Join-Path $latestRepoPath "scripts"
            
            # Show other repositories if multiple exist
            if ($repositories.Count -gt 1) {
                Write-Host "   📂 Other repositories:" -ForegroundColor DarkGray
                foreach ($repo in $repositories | Select-Object -Skip 1 | Select-Object -First 3) {
                    Write-Host "      • $($repo.Name) (modified: $($repo.LastWriteTime))" -ForegroundColor DarkGray
                }
                if ($repositories.Count -gt 4) {
                    Write-Host "      ... and $($repositories.Count - 4) more" -ForegroundColor DarkGray
                }
            }
        } else {
            Write-Host "   ⚠️  No repository folders detected, using current directory" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "   ⚠️  Error detecting repository: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "   Using current script directory" -ForegroundColor Gray
    }
} else {
    Write-Host "   ℹ️  Not in Semaphore environment, using current directory" -ForegroundColor Gray
}

# Determine absolute script path
$fullScriptPath = Join-Path $scriptDir $scriptPath

Write-Host ""
Write-Host "🎯 Target script: $scriptPath" -ForegroundColor Green
Write-Host "📁 Full path: $fullScriptPath" -ForegroundColor Gray

# Validate script exists
if (-not (Test-Path $fullScriptPath)) {
    Write-Host ""
    Write-Host "❌ FATAL ERROR: Script not found at: $fullScriptPath" -ForegroundColor Red
    Write-Host "   Please verify the ScriptPath parameter is correct" -ForegroundColor Yellow
    Write-Host ""
    exit 1
}

# ═══════════════════════════════════════════════════════════════════════════
# BUILD POWERSHELL PARAMETERS
# ═══════════════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "🔄 Converting parameters to PowerShell format..." -ForegroundColor Cyan

# List of known boolean/switch parameters (extend as needed)
$knownSwitchParams = @(
    "DryRun", "Force", "AutoApprove", "StopOnFailure", 
    "Revert", "WaitForCompletion", "SkipValidation"
)

# Build splatting hashtable
$scriptParams = @{}

foreach ($key in $parsedParams.Keys) {
    $value = $parsedParams[$key]
    
    # Skip empty values (let script use its defaults)
    if ([string]::IsNullOrWhiteSpace($value)) {
        Write-Host "  ⊘ Skipping empty parameter: $key" -ForegroundColor DarkGray
        continue
    }
    
    # Handle switch/boolean parameters
    if ($knownSwitchParams -contains $key) {
        $boolValue = Convert-ToBoolean -Value $value
        $scriptParams[$key] = $boolValue
        Write-Host "  ✓ $key = $boolValue (switch)" -ForegroundColor Yellow
    }
    # Handle integer parameters
    elseif ($key -match "(Timeout|Wait|Max|Minutes|Seconds|Count|Limit)") {
        try {
            $intValue = [int]::Parse($value)
            $scriptParams[$key] = $intValue
            Write-Host "  ✓ $key = $intValue (integer)" -ForegroundColor Cyan
        }
        catch {
            Write-Host "  ⚠️  Could not parse '$value' as integer for $key, using as string" -ForegroundColor Yellow
            $scriptParams[$key] = $value
        }
    }
    # Handle regular string parameters
    else {
        $scriptParams[$key] = $value
        Write-Host "  ✓ $key = '$value' (string)" -ForegroundColor Green
    }
}

# ═══════════════════════════════════════════════════════════════════════════
# PREREQUISITE STEPS (Steps 0A, 0B, 0C)
# ═══════════════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════════════════" -ForegroundColor Magenta
Write-Host "🔧 RUNNING PREREQUISITE STEPS" -ForegroundColor Magenta
Write-Host "═══════════════════════════════════════════════════════════════════════════" -ForegroundColor Magenta
Write-Host ""

# ───────────────────────────────────────────────────────────────────────────
# STEP 0A: GRANT PERMISSIONS
# ───────────────────────────────────────────────────────────────────────────

Write-Host "🔐 STEP 0A: GRANT PERMISSIONS" -ForegroundColor Cyan
Write-Host ""

# Determine environment for permission grant
$targetEnvironment = $null
if ($scriptParams.ContainsKey("Source") -and -not [string]::IsNullOrWhiteSpace($scriptParams["Source"])) {
    $targetEnvironment = $scriptParams["Source"]
    Write-Host "   📋 Using Source parameter: $targetEnvironment" -ForegroundColor Gray
} elseif ($scriptParams.ContainsKey("Destination") -and -not [string]::IsNullOrWhiteSpace($scriptParams["Destination"])) {
    $targetEnvironment = $scriptParams["Destination"]
    Write-Host "   📋 Using Destination parameter: $targetEnvironment" -ForegroundColor Gray
} elseif ($scriptParams.ContainsKey("Environment") -and -not [string]::IsNullOrWhiteSpace($scriptParams["Environment"])) {
    $targetEnvironment = $scriptParams["Environment"]
    Write-Host "   📋 Using Environment parameter: $targetEnvironment" -ForegroundColor Gray
} elseif (-not [string]::IsNullOrWhiteSpace($env:ENVIRONMENT)) {
    $targetEnvironment = $env:ENVIRONMENT
    Write-Host "   📋 Using ENVIRONMENT variable: $targetEnvironment" -ForegroundColor Gray
} else {
    Write-Host "   ⚠️  No environment specified - skipping permission grant" -ForegroundColor Yellow
    Write-Host "      Set Source, Destination, Environment, or ENVIRONMENT variable for permission management" -ForegroundColor Gray
}

# Track if we need to wait for permission propagation
$needsPropagationWait = $false

if ($targetEnvironment) {
    $permissionScript = Join-Path $scriptDir "permissions/Invoke-AzureFunctionPermission.ps1"
    
    if (Test-Path $permissionScript) {
        Write-Host "   🔑 Calling Azure Function to grant permissions..." -ForegroundColor Gray
        Write-Host ""
        
        try {
            $permissionResult = & $permissionScript `
                -Action "Grant" `
                -Environment $targetEnvironment `
                -ServiceAccount "SelfServiceRefresh" `
                -TimeoutSeconds 60 `
                -NoWait  # Don't wait yet - we'll decide based on response
            
            if (-not $permissionResult.Success) {
                Write-Host ""
                Write-Host "   ❌ Permission grant failed: $($permissionResult.Error)" -ForegroundColor Red
                Write-Host "   ⚠️  Continuing anyway - some operations may fail" -ForegroundColor Yellow
            } else {
                Write-Host ""
                # Parse the response to check if any groups were actually added
                $responseText = $permissionResult.Response
                
                if ($responseText -match "(\d+) succeeded") {
                    $successCount = [int]$matches[1]
                    if ($successCount -gt 0) {
                        Write-Host "   ✅ Permissions granted: $successCount group(s) added" -ForegroundColor Green
                        Write-Host "   ⏳ Will wait for Azure AD propagation (30 seconds)" -ForegroundColor Yellow
                        $needsPropagationWait = $true
                    } else {
                        Write-Host "   ✅ Permissions already configured (no changes needed)" -ForegroundColor Green
                        Write-Host "   ⚡ Skipping propagation wait - service principal already has access" -ForegroundColor Cyan
                        $needsPropagationWait = $false
                    }
                } else {
                    # Couldn't parse response - be safe and wait
                    Write-Host "   ✅ Permissions granted successfully" -ForegroundColor Green
                    Write-Host "   ⏳ Will wait for Azure AD propagation (30 seconds)" -ForegroundColor Yellow
                    $needsPropagationWait = $true
                }
            }
        } catch {
            Write-Host ""
            Write-Host "   ❌ Error during permission grant: $($_.Exception.Message)" -ForegroundColor Red
            Write-Host "   ⚠️  Continuing anyway - some operations may fail" -ForegroundColor Yellow
        }
    } else {
        Write-Host "   ⚠️  Permission script not found: $permissionScript" -ForegroundColor Yellow
    }
}

Write-Host ""

# ───────────────────────────────────────────────────────────────────────────
# STEP 0B: AZURE AUTHENTICATION
# ───────────────────────────────────────────────────────────────────────────

Write-Host "🔐 STEP 0B: AZURE AUTHENTICATION" -ForegroundColor Cyan
Write-Host ""

$authScript = Join-Path $scriptDir "common/Connect-Azure.ps1"

if (Test-Path $authScript) {
    Write-Host "   🔑 Authenticating to Azure..." -ForegroundColor Gray
    
    # Check if Cloud parameter was provided
    if ($scriptParams.ContainsKey("Cloud") -and -not [string]::IsNullOrWhiteSpace($scriptParams["Cloud"])) {
        Write-Host "   🌐 Using specified cloud: $($scriptParams['Cloud'])" -ForegroundColor Gray
        $authResult = & $authScript -Cloud $scriptParams["Cloud"]
    } else {
        Write-Host "   🌐 Auto-detecting cloud..." -ForegroundColor Gray
        $authResult = & $authScript
    }
    
    if ($authResult) {
        Write-Host "   ✅ Azure authentication successful" -ForegroundColor Green
    } else {
        Write-Host ""
        Write-Host "   ❌ FATAL ERROR: Azure authentication failed" -ForegroundColor Red
        Write-Host "   Cannot proceed without authentication" -ForegroundColor Yellow
        Write-Host "" -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host "   ⚠️  Authentication script not found: $authScript" -ForegroundColor Yellow
    Write-Host "   Assuming Azure CLI is already authenticated..." -ForegroundColor Gray
}

# Wait for permission propagation NOW (after authentication, if needed)
if ($needsPropagationWait) {
    Write-Host ""
    Write-Host "   ⏳ Waiting 30 seconds for Azure AD permissions to propagate..." -ForegroundColor Yellow
    
    # Progress bar for better UX
    for ($i = 1; $i -le 30; $i++) {
        $percent = [math]::Round(($i / 30) * 100)
        Write-Progress -Activity "Azure AD Permission Propagation" -Status "$i / 30 seconds" -PercentComplete $percent
        Start-Sleep -Seconds 1
    }
    Write-Progress -Activity "Azure AD Permission Propagation" -Completed
    
    Write-Host "   ✅ Permission propagation wait completed" -ForegroundColor Green
}

Write-Host ""

# ───────────────────────────────────────────────────────────────────────────
# STEP 0C: AUTO-DETECT PARAMETERS
# ───────────────────────────────────────────────────────────────────────────

Write-Host "🔧 STEP 0C: AUTO-DETECT PARAMETERS" -ForegroundColor Cyan
Write-Host ""

$azureParamsScript = Join-Path $scriptDir "common/Get-AzureParameters.ps1"

if (Test-Path $azureParamsScript) {
    Write-Host "   🔍 Detecting missing parameters from Azure..." -ForegroundColor Gray
    
    try {
        # Call parameter detection with whatever parameters we already have
        $detectionParams = @{}
        
        if ($scriptParams.ContainsKey("Source")) {
            $detectionParams["Source"] = $scriptParams["Source"]
        }
        if ($scriptParams.ContainsKey("Destination")) {
            $detectionParams["Destination"] = $scriptParams["Destination"]
        }
        if ($scriptParams.ContainsKey("SourceNamespace")) {
            $detectionParams["SourceNamespace"] = $scriptParams["SourceNamespace"]
        }
        if ($scriptParams.ContainsKey("DestinationNamespace")) {
            $detectionParams["DestinationNamespace"] = $scriptParams["DestinationNamespace"]
        }
        
        $detectedParams = & $azureParamsScript @detectionParams
        
        # Fill in missing parameters with detected values
        if (-not $scriptParams.ContainsKey("Source") -or [string]::IsNullOrWhiteSpace($scriptParams["Source"])) {
            if ($detectedParams.Source) {
                $scriptParams["Source"] = $detectedParams.Source
                Write-Host "   ✅ Auto-detected Source: $($detectedParams.Source)" -ForegroundColor Green
            }
        }
        
        if (-not $scriptParams.ContainsKey("Destination") -or [string]::IsNullOrWhiteSpace($scriptParams["Destination"])) {
            if ($detectedParams.Destination) {
                $scriptParams["Destination"] = $detectedParams.Destination
                Write-Host "   ✅ Auto-detected Destination: $($detectedParams.Destination)" -ForegroundColor Green
            }
        }
        
        if (-not $scriptParams.ContainsKey("SourceNamespace") -or [string]::IsNullOrWhiteSpace($scriptParams["SourceNamespace"])) {
            if ($detectedParams.SourceNamespace) {
                $scriptParams["SourceNamespace"] = $detectedParams.SourceNamespace
                Write-Host "   ✅ Auto-detected SourceNamespace: $($detectedParams.SourceNamespace)" -ForegroundColor Green
            }
        }
        
        if (-not $scriptParams.ContainsKey("DestinationNamespace") -or [string]::IsNullOrWhiteSpace($scriptParams["DestinationNamespace"])) {
            if ($detectedParams.DestinationNamespace) {
                $scriptParams["DestinationNamespace"] = $detectedParams.DestinationNamespace
                Write-Host "   ✅ Auto-detected DestinationNamespace: $($detectedParams.DestinationNamespace)" -ForegroundColor Green
            }
        }
        
        if (-not $scriptParams.ContainsKey("Cloud") -or [string]::IsNullOrWhiteSpace($scriptParams["Cloud"])) {
            if ($detectedParams.Cloud) {
                $scriptParams["Cloud"] = $detectedParams.Cloud
                Write-Host "   ✅ Auto-detected Cloud: $($detectedParams.Cloud)" -ForegroundColor Green
            }
        }
        
        # Auto-detect time parameters if not provided
        if (-not $scriptParams.ContainsKey("RestoreDateTime") -or [string]::IsNullOrWhiteSpace($scriptParams["RestoreDateTime"])) {
            if ($detectedParams.DefaultRestoreDateTime) {
                $scriptParams["RestoreDateTime"] = $detectedParams.DefaultRestoreDateTime
                Write-Host "   ✅ Auto-detected RestoreDateTime: $($detectedParams.DefaultRestoreDateTime)" -ForegroundColor Green
            }
        }
        
        if (-not $scriptParams.ContainsKey("Timezone") -or [string]::IsNullOrWhiteSpace($scriptParams["Timezone"])) {
            if ($detectedParams.DefaultTimezone) {
                $scriptParams["Timezone"] = $detectedParams.DefaultTimezone
                Write-Host "   ✅ Auto-detected Timezone: $($detectedParams.DefaultTimezone)" -ForegroundColor Green
            }
        }
        
        Write-Host "   ✅ Parameter auto-detection completed" -ForegroundColor Green
        
    } catch {
        Write-Host "   ⚠️  Parameter detection failed: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "   Continuing with provided parameters only..." -ForegroundColor Gray
    }
} else {
    Write-Host "   ⚠️  Parameter detection script not found: $azureParamsScript" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════════════════" -ForegroundColor Magenta
Write-Host "✅ PREREQUISITES COMPLETED" -ForegroundColor Magenta
Write-Host "═══════════════════════════════════════════════════════════════════════════" -ForegroundColor Magenta
Write-Host ""

# ═══════════════════════════════════════════════════════════════════════════
# EXECUTE TARGET SCRIPT
# ═══════════════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "🚀 EXECUTING TARGET SCRIPT" -ForegroundColor Green
Write-Host "═══════════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

try {
    # Execute with splatting
    if ($scriptParams.Count -eq 0) {
        Write-Host "📌 No parameters to pass, executing script with defaults..." -ForegroundColor Yellow
        & $fullScriptPath
    }
    else {
        Write-Host "📌 Executing with $($scriptParams.Count) parameter(s)..." -ForegroundColor Yellow
        & $fullScriptPath @scriptParams
    }
    
    $exitCode = $LASTEXITCODE
    
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    
    if ($exitCode -eq 0 -or $null -eq $exitCode) {
        Write-Host "✅ STEP COMPLETED SUCCESSFULLY" -ForegroundColor Green
        Write-Host "═══════════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
        exit 0
    }
    else {
        Write-Host "❌ STEP FAILED (Exit Code: $exitCode)" -ForegroundColor Red
        Write-Host "═══════════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
        exit $exitCode
    }
}
catch {
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "❌ STEP EXECUTION FAILED" -ForegroundColor Red
    Write-Host "═══════════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "At: $($_.InvocationInfo.ScriptLineNumber):$($_.InvocationInfo.OffsetInLine)" -ForegroundColor Gray
    Write-Host ""
    exit 1
}

