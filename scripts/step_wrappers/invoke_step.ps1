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

# Determine absolute script path
$scriptDir = Split-Path -Parent $PSScriptRoot  # Go up from step_wrappers/ to scripts/
$fullScriptPath = Join-Path $scriptDir $scriptPath

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

