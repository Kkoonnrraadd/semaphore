param (
    [Parameter(Mandatory)][string]$source,
    [switch]$DryRun
)

if ($DryRun) {
    Write-Host "`n🔍 DRY RUN MODE - Delete Restored Databases Script"
    Write-Host "================================================="
    Write-Host "No actual database deletion will be performed"
} else {
    Write-Host "`n🗑️  CLEANUP: Delete Restored Databases"
    Write-Host "===================================="
    Write-Host "Cleaning up restored databases after migration...`n"
}

$source_lower = (Get-Culture).TextInfo.ToLower($source)

$graph_query = "
  resources
  | where type =~ 'microsoft.sql/servers'
  | where tags.Environment == '$source_lower' and tags.Type == 'Primary'
  | project name, resourceGroup, subscriptionId
"
$recources = az graph query -q $graph_query --query "data" --first 1000 | ConvertFrom-Json

# ═══════════════════════════════════════════════════════════════
# CRITICAL CHECK: Verify SQL server was found
# ═══════════════════════════════════════════════════════════════
if (-not $recources -or $recources.Count -eq 0) {
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════"
    Write-Host "❌ FATAL ERROR: SQL Server Not Found"
    Write-Host "═══════════════════════════════════════════════"
    Write-Host ""
    Write-Host "🔴 PROBLEM: No SQL server found for environment '$source'"
    Write-Host "   └─ Query returned no results for tags.Environment='$source_lower' and tags.Type='Primary'"
    Write-Host ""
    Write-Host "💡 SOLUTIONS:"
    Write-Host "   1. Verify environment name is correct (provided: '$source')"
    Write-Host "   2. Check if SQL server exists in Azure Portal"
    Write-Host "   3. Verify server has required tags:"
    Write-Host "      • Environment = '$source_lower'"
    Write-Host "      • Type = 'Primary'"
    Write-Host ""
    
    if ($DryRun) {
        Write-Host "🔍 DRY RUN: Production run would abort here"
        Write-Host ""
        $global:LASTEXITCODE = 1
        throw "DRY RUN: No SQL server found for destination environment"
    } else {
        Write-Host "🛑 ABORTING: Cannot cleanup databases without server information"
        Write-Host ""
        $global:LASTEXITCODE = 1
        throw "No SQL server found for destination environment - cannot cleanup databases without server information"
    }
}

$source_subscription = $recources[0].subscriptionId
$source_server = $recources[0].name
$source_rg = $recources[0].resourceGroup

## Get list of DBs from Source SQL Server
$dbs = az sql db list --subscription $source_subscription --resource-group $source_rg --server  $source_server | ConvertFrom-Json

# Wait a moment to ensure all restores are complete
Write-Host "Waiting for any pending restores to complete..."
Start-Sleep -Seconds 10

# Get fresh list of databases to ensure we catch all restored databases
$dbs = az sql db list --subscription $source_subscription --resource-group $source_rg --server  $source_server | ConvertFrom-Json

$restored_dbs_to_delete = $dbs | Where-Object { $_.name.Contains("restored") -and !$_.name.Contains("master") }

if ($DryRun) {
    if ($restored_dbs_to_delete.Count -gt 0) {
        Write-Host "🔍 DRY RUN: Found $($restored_dbs_to_delete.Count) restored databases that would be deleted:"
        $restored_dbs_to_delete | ForEach-Object { Write-Host "  • $($_.name)" }
        Write-Host "🔍 DRY RUN: Would delete these databases to free up storage space"
    } else {
        Write-Host "🔍 DRY RUN: No restored databases found to delete."
    }
} else {
    if ($restored_dbs_to_delete.Count -gt 0) {
        Write-Host "Found $($restored_dbs_to_delete.Count) restored databases to delete:"
        $restored_dbs_to_delete | ForEach-Object { Write-Host "  • $($_.name)" }
        
        $restored_dbs_to_delete | ForEach-Object -ThrottleLimit 10 -Parallel {
           $source_server = $using:source_server
           $source_rg = $using:source_rg
           $source_subscription = $using:source_subscription
           $restored_dbName = $_.name
           Write-Host "🗑️  Deleting restored database: $restored_dbName"
           # delete restored DB
           az sql db delete --name $restored_dbName --resource-group $source_rg --server $source_server --subscription $source_subscription --yes
           Write-Host "✅ Successfully deleted: $restored_dbName"
        }
    } else {
        Write-Host "No restored databases found to delete."
    }
}

Write-Host "`n===================================="
Write-Host " Cleanup Completed"
Write-Host "====================================`n"
Write-Host "✅ All restored databases have been cleaned up"