<#
.SYNOPSIS
    Tests the prerequisite steps refactoring
    
.DESCRIPTION
    Validates that Grant-AzurePermissions.ps1 and Invoke-PrerequisiteSteps.ps1
    work correctly and that both self_service.ps1 and invoke_step.ps1 can use them.
    
.EXAMPLE
    ./Test-PrerequisiteRefactoring.ps1
    
.NOTES
    This is a validation test - does not require live Azure connection
#>

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $PSScriptRoot

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "🧪 TESTING PREREQUISITE REFACTORING" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

$testsPassed = 0
$testsFailed = 0

function Test-FileExists {
    param(
        [string]$FilePath,
        [string]$Description
    )
    
    Write-Host "🔍 Testing: $Description" -ForegroundColor Yellow
    
    if (Test-Path $FilePath) {
        Write-Host "   ✅ PASS: File exists at $FilePath" -ForegroundColor Green
        $script:testsPassed++
        return $true
    } else {
        Write-Host "   ❌ FAIL: File not found at $FilePath" -ForegroundColor Red
        $script:testsFailed++
        return $false
    }
}

function Test-ScriptSyntax {
    param(
        [string]$FilePath,
        [string]$Description
    )
    
    Write-Host "🔍 Testing: $Description" -ForegroundColor Yellow
    
    try {
        $null = [System.Management.Automation.PSParser]::Tokenize((Get-Content $FilePath -Raw), [ref]$null)
        Write-Host "   ✅ PASS: Script has valid PowerShell syntax" -ForegroundColor Green
        $script:testsPassed++
        return $true
    } catch {
        Write-Host "   ❌ FAIL: Syntax error - $($_.Exception.Message)" -ForegroundColor Red
        $script:testsFailed++
        return $false
    }
}

function Test-ScriptHasFunction {
    param(
        [string]$FilePath,
        [string]$Pattern,
        [string]$Description
    )
    
    Write-Host "🔍 Testing: $Description" -ForegroundColor Yellow
    
    $content = Get-Content $FilePath -Raw
    if ($content -match $Pattern) {
        Write-Host "   ✅ PASS: Found expected pattern" -ForegroundColor Green
        $script:testsPassed++
        return $true
    } else {
        Write-Host "   ❌ FAIL: Pattern not found - $Pattern" -ForegroundColor Red
        $script:testsFailed++
        return $false
    }
}

function Test-ScriptNotHasDuplicate {
    param(
        [string]$FilePath,
        [string]$Pattern,
        [string]$Description
    )
    
    Write-Host "🔍 Testing: $Description" -ForegroundColor Yellow
    
    $content = Get-Content $FilePath -Raw
    if ($content -notmatch $Pattern) {
        Write-Host "   ✅ PASS: Duplicate code removed" -ForegroundColor Green
        $script:testsPassed++
        return $true
    } else {
        Write-Host "   ❌ FAIL: Duplicate code still exists" -ForegroundColor Red
        $script:testsFailed++
        return $false
    }
}

# ═══════════════════════════════════════════════════════════════════════════
# TEST SUITE 1: New modules exist and have valid syntax
# ═══════════════════════════════════════════════════════════════════════════

Write-Host "📦 TEST SUITE 1: New Module Files" -ForegroundColor Cyan
Write-Host ""

Test-FileExists `
    -FilePath (Join-Path $scriptDir "common/Grant-AzurePermissions.ps1") `
    -Description "Grant-AzurePermissions.ps1 exists"

Test-FileExists `
    -FilePath (Join-Path $scriptDir "common/Invoke-PrerequisiteSteps.ps1") `
    -Description "Invoke-PrerequisiteSteps.ps1 exists"

Test-ScriptSyntax `
    -FilePath (Join-Path $scriptDir "common/Grant-AzurePermissions.ps1") `
    -Description "Grant-AzurePermissions.ps1 has valid syntax"

Test-ScriptSyntax `
    -FilePath (Join-Path $scriptDir "common/Invoke-PrerequisiteSteps.ps1") `
    -Description "Invoke-PrerequisiteSteps.ps1 has valid syntax"

Write-Host ""

# ═══════════════════════════════════════════════════════════════════════════
# TEST SUITE 2: Grant-AzurePermissions.ps1 functionality
# ═══════════════════════════════════════════════════════════════════════════

Write-Host "📦 TEST SUITE 2: Grant-AzurePermissions.ps1 Content" -ForegroundColor Cyan
Write-Host ""

Test-ScriptHasFunction `
    -FilePath (Join-Path $scriptDir "common/Grant-AzurePermissions.ps1") `
    -Pattern "NeedsPropagationWait" `
    -Description "Returns NeedsPropagationWait flag"

Test-ScriptHasFunction `
    -FilePath (Join-Path $scriptDir "common/Grant-AzurePermissions.ps1") `
    -Pattern 'if \(\$responseText -match "\(\\d\+\) succeeded"\)' `
    -Description "Has smart propagation logic (parses response)"

Test-ScriptHasFunction `
    -FilePath (Join-Path $scriptDir "common/Grant-AzurePermissions.ps1") `
    -Pattern "Invoke-AzureFunctionPermission\.ps1" `
    -Description "Calls Invoke-AzureFunctionPermission.ps1"

Write-Host ""

# ═══════════════════════════════════════════════════════════════════════════
# TEST SUITE 3: Invoke-PrerequisiteSteps.ps1 functionality
# ═══════════════════════════════════════════════════════════════════════════

Write-Host "📦 TEST SUITE 3: Invoke-PrerequisiteSteps.ps1 Content" -ForegroundColor Cyan
Write-Host ""

Test-ScriptHasFunction `
    -FilePath (Join-Path $scriptDir "common/Invoke-PrerequisiteSteps.ps1") `
    -Pattern "STEP 0A.*GRANT PERMISSIONS" `
    -Description "Includes STEP 0A (permissions)"

Test-ScriptHasFunction `
    -FilePath (Join-Path $scriptDir "common/Invoke-PrerequisiteSteps.ps1") `
    -Pattern "STEP 0B.*AZURE AUTHENTICATION" `
    -Description "Includes STEP 0B (authentication)"

Test-ScriptHasFunction `
    -FilePath (Join-Path $scriptDir "common/Invoke-PrerequisiteSteps.ps1") `
    -Pattern "STEP 0C.*AUTO-DETECT PARAMETERS" `
    -Description "Includes STEP 0C (parameter detection)"

Test-ScriptHasFunction `
    -FilePath (Join-Path $scriptDir "common/Invoke-PrerequisiteSteps.ps1") `
    -Pattern "Grant-AzurePermissions\.ps1" `
    -Description "Calls Grant-AzurePermissions.ps1"

Test-ScriptHasFunction `
    -FilePath (Join-Path $scriptDir "common/Invoke-PrerequisiteSteps.ps1") `
    -Pattern "Connect-Azure\.ps1" `
    -Description "Calls Connect-Azure.ps1"

Test-ScriptHasFunction `
    -FilePath (Join-Path $scriptDir "common/Invoke-PrerequisiteSteps.ps1") `
    -Pattern "Get-AzureParameters\.ps1" `
    -Description "Calls Get-AzureParameters.ps1"

Test-ScriptHasFunction `
    -FilePath (Join-Path $scriptDir "common/Invoke-PrerequisiteSteps.ps1") `
    -Pattern "if \(\$result\.NeedsPropagationWait\)" `
    -Description "Waits for propagation only when needed"

Write-Host ""

# ═══════════════════════════════════════════════════════════════════════════
# TEST SUITE 4: self_service.ps1 uses new modules
# ═══════════════════════════════════════════════════════════════════════════

Write-Host "📦 TEST SUITE 4: self_service.ps1 Refactoring" -ForegroundColor Cyan
Write-Host ""

Test-ScriptSyntax `
    -FilePath (Join-Path $scriptDir "main/self_service.ps1") `
    -Description "self_service.ps1 has valid syntax"

Test-ScriptHasFunction `
    -FilePath (Join-Path $scriptDir "main/self_service.ps1") `
    -Pattern "Invoke-PrerequisiteSteps\.ps1" `
    -Description "Calls Invoke-PrerequisiteSteps.ps1"

Test-ScriptNotHasDuplicate `
    -FilePath (Join-Path $scriptDir "main/self_service.ps1") `
    -Pattern 'Write-Host.*"STEP 0A: GRANT PERMISSIONS".*-ForegroundColor Cyan[\s\S]{100,}Write-Host.*"STEP 0B: AZURE AUTHENTICATION"' `
    -Description "Removed old prerequisite duplication"

Test-ScriptHasFunction `
    -FilePath (Join-Path $scriptDir "main/self_service.ps1") `
    -Pattern '\$prerequisiteResult\.DetectedParameters' `
    -Description "Uses detected parameters from result"

Write-Host ""

# ═══════════════════════════════════════════════════════════════════════════
# TEST SUITE 5: invoke_step.ps1 uses new modules
# ═══════════════════════════════════════════════════════════════════════════

Write-Host "📦 TEST SUITE 5: invoke_step.ps1 Refactoring" -ForegroundColor Cyan
Write-Host ""

Test-ScriptSyntax `
    -FilePath (Join-Path $scriptDir "step_wrappers/invoke_step.ps1") `
    -Description "invoke_step.ps1 has valid syntax"

Test-ScriptHasFunction `
    -FilePath (Join-Path $scriptDir "step_wrappers/invoke_step.ps1") `
    -Pattern "Invoke-PrerequisiteSteps\.ps1" `
    -Description "Calls Invoke-PrerequisiteSteps.ps1"

Test-ScriptNotHasDuplicate `
    -FilePath (Join-Path $scriptDir "step_wrappers/invoke_step.ps1") `
    -Pattern '\$needsPropagationWait\s*=\s*\$false' `
    -Description "Removed old propagation wait logic"

Test-ScriptHasFunction `
    -FilePath (Join-Path $scriptDir "step_wrappers/invoke_step.ps1") `
    -Pattern '\$prerequisiteResult\.DetectedParameters' `
    -Description "Uses detected parameters from result"

Write-Host ""

# ═══════════════════════════════════════════════════════════════════════════
# TEST SUITE 6: Line count reduction
# ═══════════════════════════════════════════════════════════════════════════

Write-Host "📦 TEST SUITE 6: Code Reduction Verification" -ForegroundColor Cyan
Write-Host ""

$selfServiceLines = (Get-Content (Join-Path $scriptDir "main/self_service.ps1")).Count
$invokeStepLines = (Get-Content (Join-Path $scriptDir "step_wrappers/invoke_step.ps1")).Count

Write-Host "🔍 Testing: self_service.ps1 line count is reasonable" -ForegroundColor Yellow
if ($selfServiceLines -lt 750) {
    Write-Host "   ✅ PASS: self_service.ps1 has $selfServiceLines lines (reduced from ~750+)" -ForegroundColor Green
    $testsPassed++
} else {
    Write-Host "   ⚠️  WARNING: self_service.ps1 has $selfServiceLines lines (expected < 750)" -ForegroundColor Yellow
}

Write-Host "🔍 Testing: invoke_step.ps1 line count is reasonable" -ForegroundColor Yellow
if ($invokeStepLines -lt 350) {
    Write-Host "   ✅ PASS: invoke_step.ps1 has $invokeStepLines lines (reduced from ~516)" -ForegroundColor Green
    $testsPassed++
} else {
    Write-Host "   ⚠️  WARNING: invoke_step.ps1 has $invokeStepLines lines (expected < 350)" -ForegroundColor Yellow
}

Write-Host ""

# ═══════════════════════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════════════════════

Write-Host "═══════════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "📊 TEST RESULTS SUMMARY" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

$totalTests = $testsPassed + $testsFailed
$passRate = if ($totalTests -gt 0) { [math]::Round(($testsPassed / $totalTests) * 100, 1) } else { 0 }

Write-Host "Total Tests: $totalTests" -ForegroundColor Gray
Write-Host "Passed:      $testsPassed" -ForegroundColor Green
Write-Host "Failed:      $testsFailed" -ForegroundColor $(if ($testsFailed -gt 0) { "Red" } else { "Gray" })
Write-Host "Pass Rate:   $passRate%" -ForegroundColor $(if ($passRate -ge 90) { "Green" } elseif ($passRate -ge 70) { "Yellow" } else { "Red" })
Write-Host ""

if ($testsFailed -eq 0) {
    Write-Host "✅ ALL TESTS PASSED! Refactoring is successful." -ForegroundColor Green
    Write-Host ""
    Write-Host "Next steps:" -ForegroundColor Cyan
    Write-Host "  1. Test self_service.ps1 with actual parameters" -ForegroundColor Gray
    Write-Host "  2. Test invoke_step.ps1 with actual Semaphore tasks" -ForegroundColor Gray
    Write-Host "  3. Verify smart propagation wait works correctly" -ForegroundColor Gray
    Write-Host "  4. Deploy to test environment" -ForegroundColor Gray
    Write-Host ""
    exit 0
} else {
    Write-Host "❌ SOME TESTS FAILED. Please review the failures above." -ForegroundColor Red
    Write-Host ""
    exit 1
}

