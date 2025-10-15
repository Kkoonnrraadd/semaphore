<#
.SYNOPSIS
    Test script for dynamic repository path detection

.DESCRIPTION
    Validates that the path detection logic works correctly in the Semaphore environment.
    Can be run manually or as part of CI/CD validation.
#>

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "🧪 TESTING DYNAMIC PATH DETECTION" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

# ═══════════════════════════════════════════════════════════════════════════
# TEST 1: Check if base directory exists
# ═══════════════════════════════════════════════════════════════════════════

Write-Host "📋 TEST 1: Base Directory Existence" -ForegroundColor Yellow
$baseDir = "/tmp/semaphore/project_1"

if (Test-Path $baseDir) {
    Write-Host "   ✅ Base directory exists: $baseDir" -ForegroundColor Green
} else {
    Write-Host "   ⚠️  Base directory not found: $baseDir" -ForegroundColor Yellow
    Write-Host "   ℹ️  This is expected if not running in Semaphore environment" -ForegroundColor Gray
    Write-Host ""
    Write-Host "✅ Test completed (non-Semaphore environment detected)" -ForegroundColor Green
    exit 0
}

# ═══════════════════════════════════════════════════════════════════════════
# TEST 2: List all repository folders
# ═══════════════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "📋 TEST 2: Repository Folder Detection" -ForegroundColor Yellow

try {
    $repositories = Get-ChildItem -Path $baseDir -Directory -ErrorAction Stop | 
        Where-Object { $_.Name -match '^repository_\d+_template_\d+$' } |
        Sort-Object LastWriteTime -Descending
    
    if ($repositories.Count -eq 0) {
        Write-Host "   ❌ No repository folders found!" -ForegroundColor Red
        Write-Host "   Expected pattern: repository_<N>_template_<N>" -ForegroundColor Gray
        exit 1
    }
    
    Write-Host "   ✅ Found $($repositories.Count) repository folder(s):" -ForegroundColor Green
    
    foreach ($repo in $repositories) {
        $age = (Get-Date) - $repo.LastWriteTime
        $ageStr = if ($age.TotalHours -lt 1) {
            "$([math]::Round($age.TotalMinutes)) minutes ago"
        } elseif ($age.TotalDays -lt 1) {
            "$([math]::Round($age.TotalHours)) hours ago"
        } else {
            "$([math]::Round($age.TotalDays)) days ago"
        }
        
        Write-Host "      • $($repo.Name)" -ForegroundColor Cyan
        Write-Host "        Modified: $($repo.LastWriteTime) ($ageStr)" -ForegroundColor Gray
    }
    
} catch {
    Write-Host "   ❌ Error reading directory: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# ═══════════════════════════════════════════════════════════════════════════
# TEST 3: Select latest repository
# ═══════════════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "📋 TEST 3: Latest Repository Selection" -ForegroundColor Yellow

$latestRepo = $repositories[0]
$latestRepoPath = $latestRepo.FullName

Write-Host "   ✅ Latest repository: $($latestRepo.Name)" -ForegroundColor Green
Write-Host "   📁 Full path: $latestRepoPath" -ForegroundColor Gray
Write-Host "   📅 Modified: $($latestRepo.LastWriteTime)" -ForegroundColor Gray

# ═══════════════════════════════════════════════════════════════════════════
# TEST 4: Verify expected directory structure
# ═══════════════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "📋 TEST 4: Directory Structure Validation" -ForegroundColor Yellow

$expectedDirs = @(
    "scripts",
    "scripts/main",
    "scripts/step_wrappers",
    "scripts/common",
    "scripts/restore",
    "scripts/database",
    "scripts/environment"
)

$allValid = $true

foreach ($dir in $expectedDirs) {
    $fullPath = Join-Path $latestRepoPath $dir
    if (Test-Path $fullPath) {
        Write-Host "   ✅ $dir" -ForegroundColor Green
    } else {
        Write-Host "   ❌ $dir (NOT FOUND)" -ForegroundColor Red
        $allValid = $false
    }
}

if (-not $allValid) {
    Write-Host ""
    Write-Host "   ⚠️  Some expected directories are missing!" -ForegroundColor Yellow
}

# ═══════════════════════════════════════════════════════════════════════════
# TEST 5: Verify key scripts exist
# ═══════════════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "📋 TEST 5: Key Script Validation" -ForegroundColor Yellow

$keyScripts = @(
    "scripts/main/semaphore_wrapper.ps1",
    "scripts/main/self_service.ps1",
    "scripts/step_wrappers/invoke_step.ps1",
    "scripts/common/Connect-Azure.ps1"
)

$allScriptsFound = $true

foreach ($script in $keyScripts) {
    $fullPath = Join-Path $latestRepoPath $script
    if (Test-Path $fullPath) {
        # Get file size
        $size = (Get-Item $fullPath).Length
        $sizeKB = [math]::Round($size / 1KB, 1)
        Write-Host "   ✅ $script ($sizeKB KB)" -ForegroundColor Green
    } else {
        Write-Host "   ❌ $script (NOT FOUND)" -ForegroundColor Red
        $allScriptsFound = $false
    }
}

# ═══════════════════════════════════════════════════════════════════════════
# TEST 6: Simulate wrapper behavior
# ═══════════════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "📋 TEST 6: Wrapper Behavior Simulation" -ForegroundColor Yellow

# Simulate what semaphore_wrapper.ps1 does
$scriptDir = Join-Path $latestRepoPath "scripts/main"
$selfServiceScript = Join-Path $scriptDir "self_service.ps1"

Write-Host "   🔧 Simulated wrapper logic:" -ForegroundColor Gray
Write-Host "      \$scriptDir = $scriptDir" -ForegroundColor Gray
Write-Host "      \$selfServiceScript = $selfServiceScript" -ForegroundColor Gray

if (Test-Path $selfServiceScript) {
    Write-Host "   ✅ self_service.ps1 would be found and executed" -ForegroundColor Green
} else {
    Write-Host "   ❌ self_service.ps1 would NOT be found!" -ForegroundColor Red
    $allScriptsFound = $false
}

# ═══════════════════════════════════════════════════════════════════════════
# TEST 7: Verify Git repository is up to date
# ═══════════════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "📋 TEST 7: Git Repository Status" -ForegroundColor Yellow

$gitDir = Join-Path $latestRepoPath ".git"

if (Test-Path $gitDir) {
    Write-Host "   ✅ Git repository exists" -ForegroundColor Green
    
    # Try to get git info
    try {
        Push-Location $latestRepoPath
        
        $branch = git branch --show-current 2>$null
        $commit = git rev-parse --short HEAD 2>$null
        $remoteUrl = git config --get remote.origin.url 2>$null
        
        if ($branch) {
            Write-Host "   📌 Branch: $branch" -ForegroundColor Gray
        }
        if ($commit) {
            Write-Host "   📌 Commit: $commit" -ForegroundColor Gray
        }
        if ($remoteUrl) {
            Write-Host "   📌 Remote: $remoteUrl" -ForegroundColor Gray
        }
        
        Pop-Location
    } catch {
        Write-Host "   ⚠️  Could not read git information" -ForegroundColor Yellow
        Pop-Location
    }
} else {
    Write-Host "   ⚠️  Not a git repository" -ForegroundColor Yellow
}

# ═══════════════════════════════════════════════════════════════════════════
# FINAL RESULT
# ═══════════════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan

if ($allScriptsFound -and $allValid -and $repositories.Count -gt 0) {
    Write-Host "✅ ALL TESTS PASSED" -ForegroundColor Green
    Write-Host "═══════════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Summary:" -ForegroundColor Cyan
    Write-Host "  • Latest repository: $($latestRepo.Name)" -ForegroundColor Gray
    Write-Host "  • Repository path: $latestRepoPath" -ForegroundColor Gray
    Write-Host "  • All key scripts found: ✅" -ForegroundColor Gray
    Write-Host "  • Directory structure valid: ✅" -ForegroundColor Gray
    Write-Host ""
    Write-Host "🎉 Dynamic path detection is working correctly!" -ForegroundColor Green
    exit 0
} else {
    Write-Host "❌ SOME TESTS FAILED" -ForegroundColor Red
    Write-Host "═══════════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Please review the errors above and:" -ForegroundColor Yellow
    Write-Host "  1. Ensure the repository was synced correctly" -ForegroundColor Gray
    Write-Host "  2. Check that all required scripts are present" -ForegroundColor Gray
    Write-Host "  3. Verify directory permissions" -ForegroundColor Gray
    Write-Host ""
    exit 1
}

