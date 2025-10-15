<#
.SYNOPSIS
    Cleanup old repository folders in Semaphore environment

.DESCRIPTION
    This script removes old repository folders, keeping only the N most recent versions.
    This helps manage disk space and reduce clutter in /tmp/semaphore/project_1/

.PARAMETER KeepCount
    Number of most recent repository folders to keep (default: 3)

.PARAMETER DryRun
    Preview what would be deleted without actually deleting

.EXAMPLE
    # Preview cleanup, keeping 3 most recent
    .\Cleanup-OldRepositories.ps1 -DryRun

.EXAMPLE
    # Actually delete old repositories, keep 2 most recent
    .\Cleanup-OldRepositories.ps1 -KeepCount 2

.EXAMPLE
    # Keep only the latest
    .\Cleanup-OldRepositories.ps1 -KeepCount 1
#>

param(
    [Parameter(Mandatory=$false)]
    [int]$KeepCount = 3,
    
    [Parameter(Mandatory=$false)]
    [switch]$DryRun = $false
)

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "🧹 SEMAPHORE REPOSITORY CLEANUP" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

if ($DryRun) {
    Write-Host "🔍 DRY RUN MODE - No changes will be made" -ForegroundColor Yellow
} else {
    Write-Host "⚠️  LIVE MODE - Repositories will be deleted" -ForegroundColor Yellow
}
Write-Host "📌 Keeping $KeepCount most recent repository folder(s)" -ForegroundColor Cyan
Write-Host ""

# ═══════════════════════════════════════════════════════════════════════════
# VALIDATE ENVIRONMENT
# ═══════════════════════════════════════════════════════════════════════════

$baseDir = "/tmp/semaphore/project_1"

if (-not (Test-Path $baseDir)) {
    Write-Host "❌ Base directory not found: $baseDir" -ForegroundColor Red
    Write-Host "   This script must run within Semaphore's execution environment" -ForegroundColor Yellow
    exit 1
}

# ═══════════════════════════════════════════════════════════════════════════
# FIND REPOSITORY FOLDERS
# ═══════════════════════════════════════════════════════════════════════════

Write-Host "🔍 Scanning for repository folders..." -ForegroundColor Cyan

try {
    $repositories = Get-ChildItem -Path $baseDir -Directory -ErrorAction Stop | 
        Where-Object { $_.Name -match '^repository_\d+_template_\d+$' } |
        Sort-Object LastWriteTime -Descending
    
    if ($repositories.Count -eq 0) {
        Write-Host "   ℹ️  No repository folders found" -ForegroundColor Gray
        exit 0
    }
    
    Write-Host "   ✅ Found $($repositories.Count) repository folder(s)" -ForegroundColor Green
    Write-Host ""
    
} catch {
    Write-Host "   ❌ Error scanning directory: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# ═══════════════════════════════════════════════════════════════════════════
# DETERMINE WHICH TO KEEP AND DELETE
# ═══════════════════════════════════════════════════════════════════════════

$toKeep = $repositories | Select-Object -First $KeepCount
$toDelete = $repositories | Select-Object -Skip $KeepCount

# ═══════════════════════════════════════════════════════════════════════════
# DISPLAY SUMMARY
# ═══════════════════════════════════════════════════════════════════════════

Write-Host "📋 KEEP (most recent $KeepCount):" -ForegroundColor Green
if ($toKeep.Count -eq 0) {
    Write-Host "   (none)" -ForegroundColor Gray
} else {
    foreach ($repo in $toKeep) {
        $size = if (Test-Path $repo.FullName) {
            $folderSize = (Get-ChildItem -Path $repo.FullName -Recurse -Force -ErrorAction SilentlyContinue | 
                Measure-Object -Property Length -Sum).Sum
            if ($folderSize) {
                "$([math]::Round($folderSize / 1MB, 1)) MB"
            } else {
                "? MB"
            }
        } else {
            "? MB"
        }
        
        Write-Host "   ✅ $($repo.Name) - $($repo.LastWriteTime) - $size" -ForegroundColor Green
    }
}

Write-Host ""
Write-Host "📋 DELETE (older repositories):" -ForegroundColor $(if ($DryRun) { "Yellow" } else { "Red" })
if ($toDelete.Count -eq 0) {
    Write-Host "   (none - all repositories will be kept)" -ForegroundColor Gray
} else {
    $totalSize = 0
    foreach ($repo in $toDelete) {
        $folderSize = 0
        if (Test-Path $repo.FullName) {
            $folderSize = (Get-ChildItem -Path $repo.FullName -Recurse -Force -ErrorAction SilentlyContinue | 
                Measure-Object -Property Length -Sum).Sum
            $totalSize += $folderSize
        }
        
        $sizeMB = if ($folderSize -gt 0) {
            "$([math]::Round($folderSize / 1MB, 1)) MB"
        } else {
            "? MB"
        }
        
        $age = (Get-Date) - $repo.LastWriteTime
        $ageStr = if ($age.TotalHours -lt 1) {
            "$([math]::Round($age.TotalMinutes)) min ago"
        } elseif ($age.TotalDays -lt 1) {
            "$([math]::Round($age.TotalHours)) hours ago"
        } else {
            "$([math]::Round($age.TotalDays)) days ago"
        }
        
        Write-Host "   ❌ $($repo.Name) - $($repo.LastWriteTime) ($ageStr) - $sizeMB" -ForegroundColor $(if ($DryRun) { "Yellow" } else { "Red" })
    }
    
    if ($totalSize -gt 0) {
        Write-Host ""
        Write-Host "   💾 Total space to reclaim: $([math]::Round($totalSize / 1MB, 1)) MB" -ForegroundColor Cyan
    }
}

Write-Host ""

# ═══════════════════════════════════════════════════════════════════════════
# CONFIRMATION (if not dry run)
# ═══════════════════════════════════════════════════════════════════════════

if (-not $DryRun -and $toDelete.Count -gt 0) {
    Write-Host "⚠️  WARNING: This will permanently delete $($toDelete.Count) repository folder(s)" -ForegroundColor Yellow
    Write-Host ""
    
    # In automated/non-interactive environments, skip confirmation
    # In interactive environments, require confirmation
    if ([Environment]::UserInteractive) {
        $confirmation = Read-Host "Type 'DELETE' to confirm deletion"
        if ($confirmation -ne "DELETE") {
            Write-Host ""
            Write-Host "❌ Deletion cancelled by user" -ForegroundColor Red
            exit 0
        }
    } else {
        Write-Host "ℹ️  Running in non-interactive mode, proceeding with deletion..." -ForegroundColor Gray
    }
}

# ═══════════════════════════════════════════════════════════════════════════
# PERFORM DELETION
# ═══════════════════════════════════════════════════════════════════════════

if ($DryRun) {
    Write-Host ""
    Write-Host "✅ DRY RUN COMPLETE - No changes were made" -ForegroundColor Green
    Write-Host ""
    Write-Host "To actually delete these folders, run:" -ForegroundColor Cyan
    Write-Host "   .\Cleanup-OldRepositories.ps1 -KeepCount $KeepCount" -ForegroundColor Gray
    exit 0
}

if ($toDelete.Count -eq 0) {
    Write-Host ""
    Write-Host "✅ CLEANUP COMPLETE - Nothing to delete" -ForegroundColor Green
    exit 0
}

Write-Host ""
Write-Host "🗑️  Deleting old repositories..." -ForegroundColor Yellow
Write-Host ""

$successCount = 0
$failCount = 0

foreach ($repo in $toDelete) {
    try {
        Write-Host "   Deleting $($repo.Name)..." -ForegroundColor Gray
        Remove-Item -Path $repo.FullName -Recurse -Force -ErrorAction Stop
        Write-Host "   ✅ Deleted $($repo.Name)" -ForegroundColor Green
        $successCount++
    } catch {
        Write-Host "   ❌ Failed to delete $($repo.Name): $($_.Exception.Message)" -ForegroundColor Red
        $failCount++
    }
}

# ═══════════════════════════════════════════════════════════════════════════
# FINAL SUMMARY
# ═══════════════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan

if ($failCount -eq 0) {
    Write-Host "✅ CLEANUP COMPLETE" -ForegroundColor Green
} else {
    Write-Host "⚠️  CLEANUP COMPLETED WITH ERRORS" -ForegroundColor Yellow
}

Write-Host "═══════════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""
Write-Host "Summary:" -ForegroundColor Cyan
Write-Host "  • Repositories kept: $($toKeep.Count)" -ForegroundColor Green
Write-Host "  • Repositories deleted: $successCount" -ForegroundColor $(if ($successCount -gt 0) { "Green" } else { "Gray" })
if ($failCount -gt 0) {
    Write-Host "  • Deletion failures: $failCount" -ForegroundColor Red
}
Write-Host ""

if ($failCount -gt 0) {
    exit 1
} else {
    exit 0
}

