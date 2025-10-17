#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Test script to verify UseSasTokens parameter passing

.DESCRIPTION
    This script tests the complete parameter flow from invoke_step.ps1 to CopyAttachments.ps1
#>

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "🧪 TESTING USESASTOKENS PARAMETER FLOW" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

$scriptDir = Split-Path -Parent $PSScriptRoot
$invokeStepPath = Join-Path $scriptDir "step_wrappers/invoke_step.ps1"
$copyAttachmentsPath = Join-Path $scriptDir "storage/CopyAttachments.ps1"

Write-Host "📁 Script directory: $scriptDir" -ForegroundColor Gray
Write-Host "📁 invoke_step.ps1: $invokeStepPath" -ForegroundColor Gray
Write-Host "📁 CopyAttachments.ps1: $copyAttachmentsPath" -ForegroundColor Gray
Write-Host ""

# Verify files exist
if (-not (Test-Path $invokeStepPath)) {
    Write-Host "❌ ERROR: invoke_step.ps1 not found!" -ForegroundColor Red
    exit 1
}

if (-not (Test-Path $copyAttachmentsPath)) {
    Write-Host "❌ ERROR: CopyAttachments.ps1 not found!" -ForegroundColor Red
    exit 1
}

Write-Host "✅ All required files found" -ForegroundColor Green
Write-Host ""

# =============================================================================
# TEST 1: UseSasTokens=true with DryRun=true
# =============================================================================

Write-Host "═══════════════════════════════════════════════════════════════════════════" -ForegroundColor Yellow
Write-Host "TEST 1: UseSasTokens=true with DryRun=true" -ForegroundColor Yellow
Write-Host "═══════════════════════════════════════════════════════════════════════════" -ForegroundColor Yellow
Write-Host ""

Write-Host "🚀 Running: pwsh invoke_step.ps1 ScriptPath=storage/CopyAttachments.ps1 UseSasTokens=true DryRun=true" -ForegroundColor Cyan
Write-Host ""

try {
    & pwsh $invokeStepPath `
        "ScriptPath=storage/CopyAttachments.ps1" `
        "Source=gov001" `
        "Destination=gov001" `
        "SourceNamespace=manufacturo" `
        "DestinationNamespace=test" `
        "UseSasTokens=true" `
        "DryRun=true"
    
    $exitCode1 = $LASTEXITCODE
    
    if ($exitCode1 -eq 0) {
        Write-Host ""
        Write-Host "✅ TEST 1 PASSED - UseSasTokens=true with DryRun=true" -ForegroundColor Green
    } else {
        Write-Host ""
        Write-Host "❌ TEST 1 FAILED - Exit code: $exitCode1" -ForegroundColor Red
    }
} catch {
    Write-Host ""
    Write-Host "❌ TEST 1 FAILED - Exception: $($_.Exception.Message)" -ForegroundColor Red
    $exitCode1 = 1
}

Write-Host ""
Write-Host "Press Enter to continue to TEST 2..."
Read-Host

# =============================================================================
# TEST 2: UseSasTokens=false with DryRun=true
# =============================================================================

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════════════════" -ForegroundColor Yellow
Write-Host "TEST 2: UseSasTokens=false with DryRun=true" -ForegroundColor Yellow
Write-Host "═══════════════════════════════════════════════════════════════════════════" -ForegroundColor Yellow
Write-Host ""

Write-Host "🚀 Running: pwsh invoke_step.ps1 ScriptPath=storage/CopyAttachments.ps1 UseSasTokens=false DryRun=true" -ForegroundColor Cyan
Write-Host ""

try {
    & pwsh $invokeStepPath `
        "ScriptPath=storage/CopyAttachments.ps1" `
        "Source=gov001" `
        "Destination=gov001" `
        "SourceNamespace=manufacturo" `
        "DestinationNamespace=test" `
        "UseSasTokens=false" `
        "DryRun=true"
    
    $exitCode2 = $LASTEXITCODE
    
    if ($exitCode2 -eq 0) {
        Write-Host ""
        Write-Host "✅ TEST 2 PASSED - UseSasTokens=false with DryRun=true" -ForegroundColor Green
    } else {
        Write-Host ""
        Write-Host "❌ TEST 2 FAILED - Exit code: $exitCode2" -ForegroundColor Red
    }
} catch {
    Write-Host ""
    Write-Host "❌ TEST 2 FAILED - Exception: $($_.Exception.Message)" -ForegroundColor Red
    $exitCode2 = 1
}

Write-Host ""
Write-Host "Press Enter to continue to TEST 3..."
Read-Host

# =============================================================================
# TEST 3: No UseSasTokens parameter (default behavior)
# =============================================================================

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════════════════" -ForegroundColor Yellow
Write-Host "TEST 3: No UseSasTokens parameter (default behavior)" -ForegroundColor Yellow
Write-Host "═══════════════════════════════════════════════════════════════════════════" -ForegroundColor Yellow
Write-Host ""

Write-Host "🚀 Running: pwsh invoke_step.ps1 ScriptPath=storage/CopyAttachments.ps1 DryRun=true (no UseSasTokens)" -ForegroundColor Cyan
Write-Host ""

try {
    & pwsh $invokeStepPath `
        "ScriptPath=storage/CopyAttachments.ps1" `
        "Source=gov001" `
        "Destination=gov001" `
        "SourceNamespace=manufacturo" `
        "DestinationNamespace=test" `
        "DryRun=true"
    
    $exitCode3 = $LASTEXITCODE
    
    if ($exitCode3 -eq 0) {
        Write-Host ""
        Write-Host "✅ TEST 3 PASSED - Default behavior (no UseSasTokens)" -ForegroundColor Green
    } else {
        Write-Host ""
        Write-Host "❌ TEST 3 FAILED - Exit code: $exitCode3" -ForegroundColor Red
    }
} catch {
    Write-Host ""
    Write-Host "❌ TEST 3 FAILED - Exception: $($_.Exception.Message)" -ForegroundColor Red
    $exitCode3 = 1
}

# =============================================================================
# TEST SUMMARY
# =============================================================================

Write-Host ""
Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "📊 TEST SUMMARY" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

$passCount = 0
$failCount = 0

if ($exitCode1 -eq 0) {
    Write-Host "  ✅ TEST 1: UseSasTokens=true with DryRun=true - PASSED" -ForegroundColor Green
    $passCount++
} else {
    Write-Host "  ❌ TEST 1: UseSasTokens=true with DryRun=true - FAILED" -ForegroundColor Red
    $failCount++
}

if ($exitCode2 -eq 0) {
    Write-Host "  ✅ TEST 2: UseSasTokens=false with DryRun=true - PASSED" -ForegroundColor Green
    $passCount++
} else {
    Write-Host "  ❌ TEST 2: UseSasTokens=false with DryRun=true - FAILED" -ForegroundColor Red
    $failCount++
}

if ($exitCode3 -eq 0) {
    Write-Host "  ✅ TEST 3: No UseSasTokens parameter - PASSED" -ForegroundColor Green
    $passCount++
} else {
    Write-Host "  ❌ TEST 3: No UseSasTokens parameter - FAILED" -ForegroundColor Red
    $failCount++
}

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan

if ($failCount -eq 0) {
    Write-Host "🎉 ALL TESTS PASSED ($passCount/3)" -ForegroundColor Green
    Write-Host "═══════════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    exit 0
} else {
    Write-Host "❌ SOME TESTS FAILED ($passCount/$($passCount + $failCount) passed)" -ForegroundColor Red
    Write-Host "═══════════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    exit 1
}

