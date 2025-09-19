param (
    [Parameter(Mandatory)][string]$source,
    [switch]$DryRun
)

if ($DryRun) {
    Write-Host "`n🔍 DRY RUN MODE - Delete Restored Databases Script" -ForegroundColor Yellow
    Write-Host "=================================================" -ForegroundColor Yellow
    Write-Host "No actual database deletion will be performed" -ForegroundColor Yellow
} else {
    Write-Host "`n====================================" -ForegroundColor Cyan
    Write-Host " Delete Restored Databases Script" -ForegroundColor Cyan
    Write-Host "====================================`n" -ForegroundColor Cyan
    Write-Host "Cleaning up restored databases after migration..." -ForegroundColor Yellow
}

$source_lower = (Get-Culture).TextInfo.ToLower($source)

$graph_query = "
  resources
  | where type =~ 'microsoft.sql/servers'
  | where tags.Environment == '$source_lower' and tags.Type == 'Primary'
  | project name, resourceGroup, subscriptionId
"
$recources = az graph query -q $graph_query --query "data" --first 1000 | ConvertFrom-Json

$source_subscription = $recources[0].subscriptionId
$source_server = $recources[0].name
$source_rg = $recources[0].resourceGroup

## Get list of DBs from Source SQL Server
$dbs = az sql db list --subscription $source_subscription --resource-group $source_rg --server  $source_server | ConvertFrom-Json

# Wait a moment to ensure all restores are complete
Write-Host "Waiting for any pending restores to complete..." -ForegroundColor Yellow
Start-Sleep -Seconds 10

# Get fresh list of databases to ensure we catch all restored databases
$dbs = az sql db list --subscription $source_subscription --resource-group $source_rg --server  $source_server | ConvertFrom-Json

$restored_dbs_to_delete = $dbs | Where-Object { $_.name.Contains("restored") -and !$_.name.Contains("master") }

if ($DryRun) {
    if ($restored_dbs_to_delete.Count -gt 0) {
        Write-Host "🔍 DRY RUN: Found $($restored_dbs_to_delete.Count) restored databases that would be deleted:" -ForegroundColor Yellow
        $restored_dbs_to_delete | ForEach-Object { Write-Host "  • $($_.name)" -ForegroundColor Gray }
        Write-Host "🔍 DRY RUN: Would delete these databases to free up storage space" -ForegroundColor Yellow
    } else {
        Write-Host "🔍 DRY RUN: No restored databases found to delete." -ForegroundColor Green
    }
} else {
    if ($restored_dbs_to_delete.Count -gt 0) {
        Write-Host "Found $($restored_dbs_to_delete.Count) restored databases to delete:" -ForegroundColor Yellow
        $restored_dbs_to_delete | ForEach-Object { Write-Host "  • $($_.name)" -ForegroundColor Gray }
        
        $restored_dbs_to_delete | ForEach-Object -ThrottleLimit 10 -Parallel {
           $source_server = $using:source_server
           $source_rg = $using:source_rg
           $source_subscription = $using:source_subscription
           $restored_dbName = $_.name
           Write-Host "🗑️  Deleting restored database: $restored_dbName" -ForegroundColor Red
           # delete restored DB
           az sql db delete --name $restored_dbName --resource-group $source_rg --server $source_server --subscription $source_subscription --yes
           Write-Host "✅ Successfully deleted: $restored_dbName" -ForegroundColor Green
        }
    } else {
        Write-Host "No restored databases found to delete." -ForegroundColor Green
    }
}

Write-Host "`n====================================" -ForegroundColor Cyan
Write-Host " Cleanup Completed" -ForegroundColor Cyan
Write-Host "====================================`n" -ForegroundColor Cyan
Write-Host "✅ All restored databases have been cleaned up" -ForegroundColor Green