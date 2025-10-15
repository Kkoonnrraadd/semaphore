<#
.SYNOPSIS
    Test script for invoke_step.ps1 wrapper
    
.DESCRIPTION
    This script tests the universal step wrapper with various parameter scenarios
#>

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "🧪 TESTING INVOKE_STEP.PS1 WRAPPER" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

$testsPassed = 0
$testsFailed = 0

function Test-WrapperCall {
    param(
        [string]$TestName,
        [string[]]$Arguments,
        [bool]$ShouldSucceed = $true
    )
    
    Write-Host "🔬 Test: $TestName" -ForegroundColor Yellow
    Write-Host "   Arguments: $($Arguments -join ' ')" -ForegroundColor Gray
    
    $wrapperScript = Join-Path $PSScriptRoot "invoke_step.ps1"
    
    try {
        # Execute wrapper
        $output = & $wrapperScript @Arguments 2>&1
        $exitCode = $LASTEXITCODE
        
        if ($ShouldSucceed) {
            if ($exitCode -eq 0 -or $null -eq $exitCode) {
                Write-Host "   ✅ PASS - Wrapper executed successfully" -ForegroundColor Green
                $script:testsPassed++
            }
            else {
                Write-Host "   ❌ FAIL - Expected success but got exit code: $exitCode" -ForegroundColor Red
                $script:testsFailed++
            }
        }
        else {
            if ($exitCode -ne 0) {
                Write-Host "   ✅ PASS - Wrapper failed as expected" -ForegroundColor Green
                $script:testsPassed++
            }
            else {
                Write-Host "   ❌ FAIL - Expected failure but succeeded" -ForegroundColor Red
                $script:testsFailed++
            }
        }
    }
    catch {
        if ($ShouldSucceed) {
            Write-Host "   ❌ FAIL - Exception thrown: $($_.Exception.Message)" -ForegroundColor Red
            $script:testsFailed++
        }
        else {
            Write-Host "   ✅ PASS - Exception thrown as expected" -ForegroundColor Green
            $script:testsPassed++
        }
    }
    
    Write-Host ""
}

# ═══════════════════════════════════════════════════════════════════════════
# TEST CASES
# ═══════════════════════════════════════════════════════════════════════════

# Create a dummy test script
$dummyScriptPath = Join-Path $PSScriptRoot "../tests/dummy_test_script.ps1"
$dummyScriptDir = Split-Path $dummyScriptPath -Parent

if (-not (Test-Path $dummyScriptDir)) {
    New-Item -ItemType Directory -Path $dummyScriptDir -Force | Out-Null
}

$dummyScriptContent = @'
param(
    [string]$Source,
    [string]$Destination,
    [switch]$DryRun,
    [switch]$Force,
    [int]$MaxWaitMinutes = 60
)

Write-Host "✅ Dummy script executed with parameters:" -ForegroundColor Green
Write-Host "   Source: $Source" -ForegroundColor Gray
Write-Host "   Destination: $Destination" -ForegroundColor Gray
Write-Host "   DryRun: $DryRun" -ForegroundColor Gray
Write-Host "   Force: $Force" -ForegroundColor Gray
Write-Host "   MaxWaitMinutes: $MaxWaitMinutes" -ForegroundColor Gray
exit 0
'@

Set-Content -Path $dummyScriptPath -Value $dummyScriptContent -Force

Write-Host "📝 Created dummy test script: $dummyScriptPath" -ForegroundColor Cyan
Write-Host ""

# Test 1: Basic parameter passing
Test-WrapperCall `
    -TestName "Basic string parameters" `
    -Arguments @("ScriptPath=tests/dummy_test_script.ps1", "Source=gov001", "Destination=gov002") `
    -ShouldSucceed $true

# Test 2: Boolean parameters (true)
Test-WrapperCall `
    -TestName "Boolean parameter (true)" `
    -Arguments @("ScriptPath=tests/dummy_test_script.ps1", "Source=gov001", "DryRun=true") `
    -ShouldSucceed $true

# Test 3: Boolean parameters (false)
Test-WrapperCall `
    -TestName "Boolean parameter (false)" `
    -Arguments @("ScriptPath=tests/dummy_test_script.ps1", "Source=gov001", "DryRun=false") `
    -ShouldSucceed $true

# Test 4: Integer parameters
Test-WrapperCall `
    -TestName "Integer parameter" `
    -Arguments @("ScriptPath=tests/dummy_test_script.ps1", "Source=gov001", "MaxWaitMinutes=120") `
    -ShouldSucceed $true

# Test 5: Mixed parameters
Test-WrapperCall `
    -TestName "Mixed parameter types" `
    -Arguments @("ScriptPath=tests/dummy_test_script.ps1", "Source=gov001", "Destination=gov002", "DryRun=true", "Force=false", "MaxWaitMinutes=90") `
    -ShouldSucceed $true

# Test 6: Empty parameters (should be skipped)
Test-WrapperCall `
    -TestName "Empty parameters (should skip)" `
    -Arguments @("ScriptPath=tests/dummy_test_script.ps1", "Source=gov001", "Destination=") `
    -ShouldSucceed $true

# Test 7: Missing ScriptPath (should fail)
Test-WrapperCall `
    -TestName "Missing ScriptPath (should fail)" `
    -Arguments @("Source=gov001", "Destination=gov002") `
    -ShouldSucceed $false

# Test 8: Non-existent script (should fail)
Test-WrapperCall `
    -TestName "Non-existent script (should fail)" `
    -Arguments @("ScriptPath=nonexistent/fake_script.ps1", "Source=gov001") `
    -ShouldSucceed $false

# Test 9: Quoted values
Test-WrapperCall `
    -TestName "Quoted string values" `
    -Arguments @("ScriptPath=tests/dummy_test_script.ps1", 'Source="gov 001"', 'Destination="gov 002"') `
    -ShouldSucceed $true

# ═══════════════════════════════════════════════════════════════════════════
# CLEANUP
# ═══════════════════════════════════════════════════════════════════════════

Write-Host "🧹 Cleaning up test artifacts..." -ForegroundColor Cyan
Remove-Item -Path $dummyScriptPath -Force -ErrorAction SilentlyContinue

# ═══════════════════════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "📊 TEST SUMMARY" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

$totalTests = $testsPassed + $testsFailed
$passRate = if ($totalTests -gt 0) { [math]::Round(($testsPassed / $totalTests) * 100, 2) } else { 0 }

Write-Host "Total Tests: $totalTests" -ForegroundColor White
Write-Host "Passed: $testsPassed" -ForegroundColor Green
Write-Host "Failed: $testsFailed" -ForegroundColor Red
Write-Host "Pass Rate: $passRate%" -ForegroundColor $(if ($passRate -eq 100) { "Green" } elseif ($passRate -ge 70) { "Yellow" } else { "Red" })
Write-Host ""

if ($testsFailed -eq 0) {
    Write-Host "✅ ALL TESTS PASSED!" -ForegroundColor Green
    Write-Host "   The invoke_step.ps1 wrapper is working correctly." -ForegroundColor Gray
    exit 0
}
else {
    Write-Host "❌ SOME TESTS FAILED" -ForegroundColor Red
    Write-Host "   Please review the failed tests above." -ForegroundColor Yellow
    exit 1
}

