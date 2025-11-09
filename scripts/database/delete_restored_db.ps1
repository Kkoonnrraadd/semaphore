param (
    [Parameter(Mandatory)][string]$Source,
    [switch]$DryRun
)

# ============================================================================
# DRY RUN FAILURE TRACKING
# ============================================================================
# Track validation failures in dry run mode to fail at the end
$script:DryRunHasFailures = $false
$script:DryRunFailureReasons = @()

function Get-ServiceFromDatabase {
    param (
        [object]$Database
    )
    return $Database.tags.Service
}

function Test-DeleteDatabaseMatchesPattern {
    param (
        [string]$DatabaseName,
        [string]$Service,
        [string]$SourceNamespace,
        [string]$SourceProduct,
        [string]$SourceType,
        [string]$SourceEnvironment,
        [string]$SourceLocation
    )
    
    if ($SourceNamespace -eq "manufacturo") {
        $expectedPattern = "$SourceProduct-$SourceType-$Service-$SourceEnvironment-$SourceLocation-restored"
        if ($DatabaseName.Contains($expectedPattern)) {
            return $DatabaseName
        } else {
            return $null
        }
    } else {
        Write-Host "❌ Source Namespace $SourceNamespace is not supported. Only 'manufacturo' namespace is supported"
        $global:LASTEXITCODE = 1
        throw "Source Namespace $SourceNamespace is not supported. Only 'manufacturo' namespace is supported"
    }
}

if ($DryRun) {
    Write-Host "`n🔍 DRY RUN MODE - Delete Restored Databases Script"
    Write-Host "================================================="
    Write-Host "No actual database deletion will be performed"
} else {
    Write-Host "`n🗑️  CLEANUP: Delete Restored Databases"
    Write-Host "===================================="
    Write-Host "Cleaning up restored databases after migration...`n"
}

$Source_lower = (Get-Culture).TextInfo.ToLower($Source)

$graph_query = "
  resources
  | where type =~ 'microsoft.sql/servers'
  | where tags.Environment == '$Source_lower' and tags.Type == 'Primary'
  | project name, resourceGroup, subscriptionId
"
$server = az graph query -q $graph_query --query "data" --first 1000 | ConvertFrom-Json

if (-not $server -or $server.Count -eq 0) {
    Write-Host "❌ No SQL server found for environment with tags Environment: $Source and Type: Primary"

    Write-Host "Trying to relogin and try again..."
    az logout
    az login --federated-token "$(cat $env:AZURE_FEDERATED_TOKEN_FILE)" `
             --service-principal -u $env:AZURE_CLIENT_ID -t $env:AZURE_TENANT_ID

    $server = az graph query -q $graph_query --query "data" --first 1000 | ConvertFrom-Json

# ═══════════════════════════════════════════════════════════════
# CRITICAL CHECK: Verify SQL server was found
# ═══════════════════════════════════════════════════════════════
    if (-not $server -or $server.Count -eq 0) {
        Write-Host ""
        Write-Host "═══════════════════════════════════════════════"
        Write-Host "❌ FATAL ERROR: SQL Server Not Found"
        Write-Host "═══════════════════════════════════════════════"
        Write-Host ""
        Write-Host "🔴 PROBLEM: No SQL server found for environment '$Source'"
        Write-Host "   └─ Query returned no results for tags.Environment='$Source_lower' and tags.Type='Primary'"
        Write-Host ""
        Write-Host "💡 SOLUTIONS:"
        Write-Host "   1. Verify environment name is correct (provided: '$Source')"
        Write-Host "   2. Check if SQL server exists in Azure Portal"
        Write-Host "   3. Verify server has required tags:"
        Write-Host "      • Environment = '$Source_lower'"
        Write-Host "      • Type = 'Primary'"
        Write-Host ""
        
        if ($DryRun) {
            Write-Host "⚠️  DRY RUN WARNING: No SQL server found for destination environment" -ForegroundColor Yellow
            Write-Host "⚠️  In production, this would abort the operation" -ForegroundColor Yellow
            Write-Host "⚠️  Skipping remaining steps..." -ForegroundColor Yellow
            Write-Host ""
            # Track this failure for final dry run summary
            $script:DryRunHasFailures = $true
            $script:DryRunFailureReasons += "No SQL server found for destination environment '$Source'"
            # Skip to end for dry run summary
            return
        } else {
            Write-Host "🛑 ABORTING: Cannot cleanup databases without server information"
            Write-Host ""
            $global:LASTEXITCODE = 1
            throw "No SQL server found for destination environment - cannot cleanup databases without server information"
        }
    }
}

$Source_subscription = $server[0].subscriptionId
$Source_server = $server[0].name
$Source_rg = $server[0].resourceGroup

# Parse server name components
$Source_split = $Source_server -split "-"
$Source_product = $Source_split[1]
$Source_location = $Source_split[-1]
$Source_type = $Source_split[2]
$Source_environment = $Source_split[3]

## Get list of DBs from Source SQL Server
$dbs = az sql db list --subscription $Source_subscription --resource-group $Source_rg --server  $Source_server | ConvertFrom-Json

# Wait a moment to ensure all restores are complete
Write-Host "Waiting for any pending restores to complete..."
Start-Sleep -Seconds 10

$databasesToDelete = @()
$restored_dbs_to_delete = @()

# Get fresh list of databases to ensure we catch all restored databases
$dbs = az sql db list --subscription $Source_subscription --resource-group $Source_rg --server  $Source_server | ConvertFrom-Json

$restored_dbs_to_delete = $dbs | Where-Object { $_.name.Contains("restored") }

if ($restored_dbs_to_delete.Count -gt 0) {
    Write-Host "Found $($restored_dbs_to_delete.Count) restored databases to delete:"
    $restored_dbs_to_delete | ForEach-Object { Write-Host "  • $($_.name)" }
} else {
    Write-Host "No restored databases found to delete."
}

foreach ($db in $restored_dbs_to_delete) {

    $service = Get-ServiceFromDatabase -Database $db

    Write-Host "  📋 Found database: $($db.name) with tag Service: $service"
    
    # Check if database matches expected pattern
    $matchesPattern = Test-DeleteDatabaseMatchesPattern `
        -DatabaseName $db.name `
        -Service $service `
        -SourceNamespace $SourceNamespace `
        -SourceProduct $Source_product `
        -SourceType $Source_type `
        -SourceEnvironment $Source_environment `
        -SourceLocation $Source_location

    if ($matchesPattern) {
        Write-Host "    ✅ Will delete: $($db.name) (matches expected pattern $($matchesPattern))"
        $databasesToDelete += $db
    } else {
        Write-Host "    ⏭️  Skipping: Pattern mismatch $($db.name) does not match expected pattern $($matchesPattern)"
    }
}


if ($DryRun) {
    if ($databasesToDelete.Count -gt 0) {
        Write-Host "🔍 DRY RUN: Found $($restored_dbs_to_delete.Count) restored databases that would be deleted:"
        $databasesToDelete | ForEach-Object { Write-Host "  • $($_.name)" }
        Write-Host "🔍 DRY RUN: Would delete these databases to free up storage space"
    } else {
        Write-Host "🔍 DRY RUN: No restored databases found to delete."
    }
} else {
    if ($databasesToDelete.Count -gt 0) {
        Write-Host "Found $($databasesToDelete.Count) restored databases to delete:"
        $databasesToDelete | ForEach-Object { Write-Host "  • $($_.name)" }
        
        $databasesToDelete | ForEach-Object -ThrottleLimit 10 -Parallel {
           $Source_server = $using:source_server
           $Source_rg = $using:source_rg
           $Source_subscription = $using:source_subscription
           $restored_dbName = $_.name
           Write-Host "🗑️  Deleting restored database: $restored_dbName"
           # delete restored DB
           az sql db delete --name $restored_dbName --resource-group $Source_rg --server $Source_server --subscription $Source_subscription --yes
           Write-Host "✅ Successfully deleted: $restored_dbName"
        }
    } else {
        Write-Host "No restored databases found to delete."
    }
}

if ($DryRun) {
    Write-Host ""
    # Check if there were any validation failures during dry run
    if ($script:DryRunHasFailures) {
        Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Red
        Write-Host "❌ DRY RUN COMPLETED WITH WARNINGS" -ForegroundColor Red
        Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Red
        Write-Host ""
        Write-Host "⚠️  The following issues would cause production run to FAIL:" -ForegroundColor Yellow
        Write-Host ""
        foreach ($reason in $script:DryRunFailureReasons) {
            Write-Host "   • $reason" -ForegroundColor Yellow
        }
        Write-Host ""
        Write-Host "🔧 Please resolve these issues before running in production mode" -ForegroundColor Yellow
        Write-Host ""
        $global:LASTEXITCODE = 1
        exit 1
    } else {
        Write-Host "✅ DRY RUN COMPLETED SUCCESSFULLY - No issues detected" -ForegroundColor Green
        exit 0
    }
}

Write-Host "`n===================================="
Write-Host " Cleanup Completed"
Write-Host "====================================`n"
Write-Host "✅ All restored databases have been cleaned up"