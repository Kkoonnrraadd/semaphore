<#
.SYNOPSIS
    Dynamically detects the latest repository path in Semaphore's execution environment.

.DESCRIPTION
    This script finds the most recent repository folder under /tmp/semaphore/project_1/
    by checking modification timestamps. This ensures scripts always run against the
    latest code version, even as Semaphore increments repository folder numbers.

.OUTPUTS
    Returns the full path to the latest repository folder (e.g., /tmp/semaphore/project_1/repository_1_template_6)
#>

function Get-LatestRepositoryPath {
    [CmdletBinding()]
    param()
    
    $baseDir = "/tmp/semaphore/project_1"
    
    Write-Host "🔍 Detecting latest repository path..." -ForegroundColor Cyan
    
    # Check if base directory exists
    if (-not (Test-Path $baseDir)) {
        Write-Host "❌ Base directory not found: $baseDir" -ForegroundColor Red
        Write-Host "   This script must run within Semaphore's execution environment" -ForegroundColor Yellow
        throw "Base directory not found: $baseDir"
    }
    
    # Get all repository folders (pattern: repository_1_template_N)
    $repositories = Get-ChildItem -Path $baseDir -Directory | 
        Where-Object { $_.Name -match '^repository_\d+_template_\d+$' } |
        Sort-Object LastWriteTime -Descending
    
    if ($repositories.Count -eq 0) {
        Write-Host "❌ No repository folders found in $baseDir" -ForegroundColor Red
        throw "No repository folders found"
    }
    
    # Get the latest (most recently modified)
    $latestRepo = $repositories[0]
    $latestPath = $latestRepo.FullName
    
    Write-Host "✅ Latest repository detected: $($latestRepo.Name)" -ForegroundColor Green
    Write-Host "   Path: $latestPath" -ForegroundColor Gray
    Write-Host "   Modified: $($latestRepo.LastWriteTime)" -ForegroundColor Gray
    
    # Show other repositories for reference
    if ($repositories.Count -gt 1) {
        Write-Host "   Other repositories found:" -ForegroundColor Gray
        foreach ($repo in $repositories | Select-Object -Skip 1) {
            Write-Host "     • $($repo.Name) (modified: $($repo.LastWriteTime))" -ForegroundColor DarkGray
        }
    }
    
    return $latestPath
}


# Export the function
Export-ModuleMember -Function Get-LatestRepositoryPath

# If script is run directly (not dot-sourced), execute and output the path
if ($MyInvocation.InvocationName -ne '.') {
    $path = Get-LatestRepositoryPath
    Write-Output $path
}

