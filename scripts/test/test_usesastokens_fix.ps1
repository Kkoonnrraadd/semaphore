#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Test script to verify UseSasTokens parameter is passed correctly through semaphore_wrapper.ps1
    
.DESCRIPTION
    This script tests that the UseSasTokens parameter flows correctly from command line
    through semaphore_wrapper.ps1 to self_service.ps1 and finally to CopyAttachments.ps1
    
.EXAMPLE
    pwsh scripts/test/test_usesastokens_fix.ps1
#>

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "🧪 TESTING UseSasTokens PARAMETER FLOW" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

$scriptDir = Split-Path -Parent $PSScriptRoot
$wrapperScript = Join-Path $scriptDir "main/semaphore_wrapper.ps1"

if (-not (Test-Path $wrapperScript)) {
    Write-Host "❌ ERROR: Wrapper script not found at: $wrapperScript" -ForegroundColor Red
    exit 1
}

Write-Host "📋 Test 1: UseSasTokens=true" -ForegroundColor Yellow
Write-Host "─────────────────────────────────────────────────────────────────────────────" -ForegroundColor DarkGray

# Capture output
$output1 = & pwsh $wrapperScript "DryRun=true" "UseSasTokens=true" "production_confirm=test" 2>&1

# Check for expected strings in output
$test1_parsed = $output1 | Select-String "Parsed parameter: UseSasTokens = true"
$test1_sanitized = $output1 | Select-String "UseSasTokens: True"
$test1_enabled = $output1 | Select-String "SAS Token mode is ENABLED"

if ($test1_parsed -and $test1_sanitized -and $test1_enabled) {
    Write-Host "✅ Test 1 PASSED: UseSasTokens=true is correctly parsed and passed" -ForegroundColor Green
} else {
    Write-Host "❌ Test 1 FAILED: UseSasTokens=true not correctly handled" -ForegroundColor Red
    if (-not $test1_parsed) { Write-Host "   Missing: 'Parsed parameter: UseSasTokens = true'" -ForegroundColor Red }
    if (-not $test1_sanitized) { Write-Host "   Missing: 'UseSasTokens: True' in sanitized output" -ForegroundColor Red }
    if (-not $test1_enabled) { Write-Host "   Missing: 'SAS Token mode is ENABLED' in CopyAttachments" -ForegroundColor Red }
}

Write-Host ""
Write-Host "📋 Test 2: UseSasTokens=false" -ForegroundColor Yellow
Write-Host "─────────────────────────────────────────────────────────────────────────────" -ForegroundColor DarkGray

$output2 = & pwsh $wrapperScript "DryRun=true" "UseSasTokens=false" "production_confirm=test" 2>&1

$test2_parsed = $output2 | Select-String "Parsed parameter: UseSasTokens = false"
$test2_sanitized = $output2 | Select-String "UseSasTokens: False"
$test2_disabled = $output2 | Select-String "SAS Token mode is DISABLED"

if ($test2_parsed -and $test2_sanitized -and $test2_disabled) {
    Write-Host "✅ Test 2 PASSED: UseSasTokens=false is correctly parsed and passed" -ForegroundColor Green
} else {
    Write-Host "❌ Test 2 FAILED: UseSasTokens=false not correctly handled" -ForegroundColor Red
    if (-not $test2_parsed) { Write-Host "   Missing: 'Parsed parameter: UseSasTokens = false'" -ForegroundColor Red }
    if (-not $test2_sanitized) { Write-Host "   Missing: 'UseSasTokens: False' in sanitized output" -ForegroundColor Red }
    if (-not $test2_disabled) { Write-Host "   Missing: 'SAS Token mode is DISABLED' in CopyAttachments" -ForegroundColor Red }
}

Write-Host ""
Write-Host "📋 Test 3: UseSasTokens not provided (default to false)" -ForegroundColor Yellow
Write-Host "─────────────────────────────────────────────────────────────────────────────" -ForegroundColor DarkGray

$output3 = & pwsh $wrapperScript "DryRun=true" "production_confirm=test" 2>&1

$test3_sanitized = $output3 | Select-String "UseSasTokens: False"
$test3_disabled = $output3 | Select-String "SAS Token mode is DISABLED"

if ($test3_sanitized -and $test3_disabled) {
    Write-Host "✅ Test 3 PASSED: UseSasTokens defaults to false when not provided" -ForegroundColor Green
} else {
    Write-Host "❌ Test 3 FAILED: Default behavior incorrect" -ForegroundColor Red
    if (-not $test3_sanitized) { Write-Host "   Missing: 'UseSasTokens: False' in sanitized output" -ForegroundColor Red }
    if (-not $test3_disabled) { Write-Host "   Missing: 'SAS Token mode is DISABLED' in CopyAttachments" -ForegroundColor Red }
}

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "🎯 TEST SUMMARY" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan

$allPassed = $test1_parsed -and $test1_sanitized -and $test1_enabled -and 
             $test2_parsed -and $test2_sanitized -and $test2_disabled -and
             $test3_sanitized -and $test3_disabled

if ($allPassed) {
    Write-Host "✅ ALL TESTS PASSED - UseSasTokens parameter is working correctly!" -ForegroundColor Green
    exit 0
} else {
    Write-Host "❌ SOME TESTS FAILED - Please review the output above" -ForegroundColor Red
    exit 1
}

