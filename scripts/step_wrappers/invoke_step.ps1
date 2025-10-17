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
Write-Host "📋 Number of arguments: $($args.Count)" -ForegroundColor Gray
$parsedParams = Parse-SemaphoreArguments -Arguments $args

Write-Host "" 
Write-Host "🔍 Parsed parameters (before processing):" -ForegroundColor Cyan
foreach ($key in $parsedParams.Keys) {
    Write-Host "   $key = $($parsedParams[$key])" -ForegroundColor Gray
}
Write-Host ""

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
    "Revert", "WaitForCompletion", "SkipValidation", "UseSasTokens"
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
        # Only add switch parameters when they're TRUE
        # PowerShell switches are either present (true) or absent (false)
        if ($boolValue) {
            $scriptParams[$key] = $true
            Write-Host "  ✓ $key = TRUE (switch - will be passed)" -ForegroundColor Yellow
        } else {
            Write-Host "  ✓ $key = FALSE (switch - will be omitted)" -ForegroundColor DarkGray
        }
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
# PREREQUISITE STEPS (Steps 0A, 0B, 0C) - Using unified module
# ═══════════════════════════════════════════════════════════════════════════

try {
    $prerequisiteScript = Join-Path $scriptDir "common/Invoke-PrerequisiteSteps.ps1"
    
    if (-not (Test-Path $prerequisiteScript)) {
        Write-Host ""
        Write-Host "❌ FATAL ERROR: Prerequisite script not found at: $prerequisiteScript" -ForegroundColor Red
        Write-Host "   This script is required to run prerequisite steps" -ForegroundColor Yellow
        Write-Host ""
        exit 1
    }
    
    # Call the unified prerequisite steps script
    $prerequisiteResult = & $prerequisiteScript -Parameters $scriptParams
    
    if (-not $prerequisiteResult.Success) {
        Write-Host ""
        Write-Host "❌ FATAL ERROR: Prerequisite steps failed" -ForegroundColor Red
        Write-Host "   Error: $($prerequisiteResult.Error)" -ForegroundColor Yellow
        Write-Host ""
        exit 1
    }
    
    # Merge detected parameters into scriptParams
    $detectedParams = $prerequisiteResult.DetectedParameters
    
    if ($detectedParams -and $detectedParams.Count -gt 0) {
        Write-Host ""
        Write-Host "🔀 Merging auto-detected parameters..." -ForegroundColor Cyan
        
        # Get target script parameters to validate what we can pass
        $targetScriptInfo = Get-Command $fullScriptPath -ErrorAction SilentlyContinue
        $acceptedParams = @()
        if ($targetScriptInfo -and $targetScriptInfo.Parameters) {
            $acceptedParams = $targetScriptInfo.Parameters.Keys
        }
        
        # Merge detected parameters (only if not already set and target script accepts them)
        $mergedCount = 0
        foreach ($paramName in $detectedParams.Keys) {
            $shouldAdd = (-not $scriptParams.ContainsKey($paramName) -or [string]::IsNullOrWhiteSpace($scriptParams[$paramName])) -and
                         ($acceptedParams.Count -eq 0 -or $acceptedParams -contains $paramName) -and
                         (-not [string]::IsNullOrWhiteSpace($detectedParams[$paramName]))
            
            if ($shouldAdd) {
                # Check if this is a known switch parameter - need to convert to boolean
                if ($knownSwitchParams -contains $paramName) {
                    $boolValue = Convert-ToBoolean -Value $detectedParams[$paramName]
                    if ($boolValue) {
                        $scriptParams[$paramName] = $true
                        Write-Host "   ✅ Added $paramName = TRUE (switch)" -ForegroundColor Green
                        $mergedCount++
                    } else {
                        Write-Host "   ⊘ Skipped $paramName = FALSE (switch - omitted)" -ForegroundColor DarkGray
                    }
                } else {
                    $scriptParams[$paramName] = $detectedParams[$paramName]
                    Write-Host "   ✅ Added $paramName = $($detectedParams[$paramName])" -ForegroundColor Green
                    $mergedCount++
                }
            } else {
                if ($scriptParams.ContainsKey($paramName)) {
                    Write-Host "   ⊘ Skipped $paramName (user-provided value takes priority)" -ForegroundColor DarkGray
                } elseif ($acceptedParams.Count -eq 0 -or $acceptedParams -notcontains $paramName) {
                    Write-Host "   ⊘ Skipped $paramName (target script doesn't accept it)" -ForegroundColor DarkGray
                }
            }
        }
        
        if ($mergedCount -gt 0) {
            Write-Host "   ✅ Merged $mergedCount auto-detected parameter(s)" -ForegroundColor Green
        } else {
            Write-Host "   ℹ️  No additional parameters to merge" -ForegroundColor Gray
        }
        Write-Host ""
    }
    
} catch {
    Write-Host ""
    Write-Host "❌ FATAL ERROR: Prerequisite execution failed" -ForegroundColor Red
    Write-Host "   Error: $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host ""
    exit 1
}

# ═══════════════════════════════════════════════════════════════════════════
# EXECUTE TARGET SCRIPT
# ═══════════════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "🚀 EXECUTING TARGET SCRIPT" -ForegroundColor Green
Write-Host "═══════════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

# DEBUG: Show final parameter hashtable
Write-Host "🔍 DEBUG: Final parameter hashtable contents:" -ForegroundColor Magenta
foreach ($key in $scriptParams.Keys) {
    $value = $scriptParams[$key]
    $type = if ($null -ne $value) { $value.GetType().Name } else { "null" }
    Write-Host "   $key = $value (Type: $type)" -ForegroundColor DarkGray
}
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

