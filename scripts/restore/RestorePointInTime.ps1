param (
    [Parameter(Mandatory)][string]$source,
    [AllowEmptyString()][string]$SourceNamespace,
    [Parameter(Mandatory)][string]$RestoreDateTime,
    [Parameter(Mandatory)][string]$Timezone,  # Required - provided by wrapper or user
    [switch]$DryRun,
    [int]$MaxWaitMinutes = 60,
    [int]$ThrottleLimit = 10  # Number of databases to restore in parallel
)

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

function Convert-ToUTCRestorePoint {
    param (
        [string]$RestoreDateTime,
        [string]$Timezone
    )
    
    try {
        # Create timezone info
        $timezoneInfo = [System.TimeZoneInfo]::FindSystemTimeZoneById($Timezone)
        Write-Host "Using timezone: $Timezone ($($timezoneInfo.DisplayName))" -ForegroundColor Green
        
        # Parse the datetime
        $restorePoint = [DateTime]::Parse($RestoreDateTime)
        
        # If timezone is UTC, treat input as already UTC
        if ($Timezone -eq "UTC") {
            $restorePointInTimezone = $restorePoint
            $restorePointUtc = $restorePoint
            Write-Host "Input datetime: $($restorePoint.ToString('yyyy-MM-dd HH:mm:ss'))" -ForegroundColor Gray
            Write-Host "In UTC: $($restorePointInTimezone.ToString('yyyy-MM-dd HH:mm:ss'))" -ForegroundColor Green
            Write-Host "UTC restore point: $($restorePointUtc.ToString('yyyy-MM-dd HH:mm:ss')) UTC" -ForegroundColor Gray
        } else {
            # Convert from specified timezone to UTC
            $restorePointInTimezone = [System.TimeZoneInfo]::ConvertTime($restorePoint, $timezoneInfo)
            $restorePointUtc = $restorePointInTimezone.ToUniversalTime()
            
            Write-Host "Input datetime: $($restorePoint.ToString('yyyy-MM-dd HH:mm:ss'))" -ForegroundColor Gray
            Write-Host "In $($Timezone): $($restorePointInTimezone.ToString('yyyy-MM-dd HH:mm:ss'))" -ForegroundColor Green
            Write-Host "UTC restore point: $($restorePointUtc.ToString('yyyy-MM-dd HH:mm:ss')) UTC" -ForegroundColor Gray
        }
        
        return @{
            RestorePointInTimezone = $restorePointInTimezone
            RestorePointUtc = $restorePointUtc
        }
        
    } catch {
        Write-Host "❌ Error processing datetime or timezone:" -ForegroundColor Red
        
        # Check if it's a timezone error
        try {
            [System.TimeZoneInfo]::FindSystemTimeZoneById($Timezone) | Out-Null
        } catch {
            Write-Host "   - Invalid timezone: '$Timezone'" -ForegroundColor Yellow
            Write-Host "   - Common timezone abbreviations like 'PST', 'EST', 'GMT' are not supported" -ForegroundColor Yellow
            Write-Host "   - Use IANA timezone names instead:" -ForegroundColor Yellow
            Write-Host "     • America/Los_Angeles (for PST/PDT)" -ForegroundColor Gray
            Write-Host "     • America/New_York (for EST/EDT)" -ForegroundColor Gray
            Write-Host "     • Europe/London (for GMT/BST)" -ForegroundColor Gray
            Write-Host "     • UTC (for Universal Time)" -ForegroundColor Gray
        }
        
        Write-Host "   - Invalid datetime format. Please use format: 'yyyy-MM-dd HH:mm:ss'" -ForegroundColor Yellow
        Write-Host "Example: '2025-08-06 10:30:00' with timezone 'America/Los_Angeles'" -ForegroundColor Gray
        throw
    }
}

function Get-ServiceFromDatabase {
    param (
        [object]$Database
    )
    return $Database.tags.Service
}

function Should-RestoreDatabase {
    param (
        [string]$DatabaseName,
        [string]$Service
    )
    
    # Skip if contains "Copy"
    if ($DatabaseName.Contains("Copy")) {
        return $false
    }
    
    # Skip system databases
    if ($DatabaseName.Contains("master")) {
        return $false
    }
    
    # Skip already restored databases
    if ($DatabaseName.Contains("restored")) {
        return $false
    }
    
    # Skip landlord service
    if ($DatabaseName.Contains("landlord")) {
        return $false
    }
    
    return $true
}

function Test-DatabaseMatchesPattern {
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
        $expectedPattern = "$SourceProduct-$SourceType-$Service-$SourceEnvironment-$SourceLocation"
        return $DatabaseName.Contains($expectedPattern)
    } else {
        $expectedPattern = "$SourceProduct-$SourceType-$Service-$SourceNamespace-$SourceEnvironment-$SourceLocation"
        return $DatabaseName.Contains($expectedPattern)
    }
}

function Restore-SingleDatabase {
    param (
        [string]$DatabaseName,
        [string]$SourceSubscription,
        [string]$SourceResourceGroup,
        [string]$SourceServer,
        [string]$SourceServerFQDN,
        [DateTime]$RestorePointUtc,
        [DateTime]$RestorePointInTimezone,
        [string]$Timezone,
        [string]$AccessToken,
        [int]$MaxWaitMinutes
    )
    
    $restoredDbName = "$DatabaseName-restored"
    
    Write-Host "`n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
    Write-Host "📋 Restoring: $DatabaseName" -ForegroundColor Cyan
    Write-Host "   Target: $restoredDbName" -ForegroundColor Cyan
    Write-Host "   Restore Point: $($RestorePointInTimezone.ToString('yyyy-MM-dd HH:mm:ss')) ($Timezone)" -ForegroundColor Cyan
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
    
    # Start the restore operation
    Write-Host "  🔄 Initiating restore operation..." -ForegroundColor Yellow
    
    try {
        # Capture both stdout and stderr
        $restoreOutput = az sql db restore `
            --dest-name $restoredDbName `
            --edition Standard `
            --name $DatabaseName `
            --resource-group $SourceResourceGroup `
            --server $SourceServer `
            --subscription $SourceSubscription `
            --service-objective S3 `
            --time $($RestorePointUtc.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')) `
            --no-wait 2>&1
        
        # Check for errors in output or exit code
        if ($LASTEXITCODE -ne 0 -or $restoreOutput -match "ERROR:") {
            $errorMessage = if ($restoreOutput -match "ERROR: (.+)") { $matches[1] } else { "Failed to initiate restore operation" }
            Write-Host "  ❌ Failed to initiate restore" -ForegroundColor Red
            return @{
                Database = $restoredDbName
                Status = "failed"
                Error = $errorMessage
                Phase = "initiation"
            }
        }
        
        Write-Host "  ✅ Restore operation initiated" -ForegroundColor Green
        
    } catch {
        Write-Host "  ❌ Error initiating restore: $($_.Exception.Message)" -ForegroundColor Red
        return @{
            Database = $restoredDbName
            Status = "failed"
            Error = $_.Exception.Message
            Phase = "initiation"
        }
    }
    
    # Wait for restore to complete
    Write-Host "  ⏳ Waiting for restore to complete..." -ForegroundColor Yellow
    
    $startTime = Get-Date
    $maxIterations = $MaxWaitMinutes * 2  # Check every 30 seconds
    
    for ($i = 1; $i -le $maxIterations; $i++) {
        $elapsed = (Get-Date) - $startTime
        $elapsedMinutes = [math]::Round($elapsed.TotalMinutes, 1)
        
        # Check if we've exceeded the max wait time
        if ($elapsedMinutes -ge $MaxWaitMinutes) {
            Write-Host "  ❌ Restore failed to complete within ${MaxWaitMinutes} minutes" -ForegroundColor Red
            return @{
                Database = $restoredDbName
                Status = "failed"
                Error = "Timeout waiting for restore to complete"
                Phase = "waiting"
                Elapsed = $MaxWaitMinutes
            }
        }
        
        # Try Azure CLI check first (faster)
        try {
            $azResult = az sql db show `
                --name $restoredDbName `
                --resource-group $SourceResourceGroup `
                --server $SourceServer `
                --subscription $SourceSubscription `
                --query "status" `
                --output tsv 2>$null
            
            if ($azResult -eq "Online") {
                Write-Host "  ✅ Database restored successfully (took ${elapsedMinutes} minutes)" -ForegroundColor Green
                return @{
                    Database = $restoredDbName
                    Status = "success"
                    Elapsed = $elapsedMinutes
                }
            }
        } catch {
            # Azure CLI check failed, will try SQL query
        }
        
        # Try SQL query as backup
        try {
            $statusQuery = "SELECT state_desc FROM sys.databases WHERE name = '$restoredDbName'"
            $result = Invoke-Sqlcmd `
                -AccessToken $AccessToken `
                -ServerInstance $SourceServerFQDN `
                -Query $statusQuery `
                -ConnectionTimeout 15 `
                -QueryTimeout 30 `
                -ErrorAction SilentlyContinue
            
            if ($result -and $result.state_desc -eq "ONLINE") {
                Write-Host "  ✅ Database restored successfully (took ${elapsedMinutes} minutes)" -ForegroundColor Green
                return @{
                    Database = $restoredDbName
                    Status = "success"
                    Elapsed = $elapsedMinutes
                }
            }
        } catch {
            # SQL query also failed, continue waiting
        }
        
        # Show progress every 2 minutes
        if ($i % 4 -eq 0) {
            Write-Host "  ⏳ Still restoring... (${elapsedMinutes} min elapsed)" -ForegroundColor Gray
        }
        
        Start-Sleep -Seconds 30
    }
    
    # Timeout reached
    $finalElapsed = (Get-Date) - $startTime
    $finalElapsedMinutes = [math]::Round($finalElapsed.TotalMinutes, 1)
    Write-Host "  ❌ Timeout: Restore failed to complete (${finalElapsedMinutes} min)" -ForegroundColor Red
    return @{
        Database = $restoredDbName
        Status = "failed"
        Error = "Timeout"
        Phase = "waiting"
        Elapsed = $finalElapsedMinutes
    }
}

# ============================================================================
# MAIN SCRIPT
# ============================================================================

Write-Host "`n============================" -ForegroundColor Cyan
Write-Host " Restore Point In Time" -ForegroundColor Cyan
Write-Host "============================`n" -ForegroundColor Cyan

# Convert datetime to UTC
Write-Host "🕐 Using timezone: $Timezone" -ForegroundColor Green
$timeConversion = Convert-ToUTCRestorePoint -RestoreDateTime $RestoreDateTime -Timezone $Timezone
$restore_point_in_timezone = $timeConversion.RestorePointInTimezone
$restore_point_utc = $timeConversion.RestorePointUtc

# Query for source SQL server
Write-Host "`n🔍 Finding source SQL server..." -ForegroundColor Cyan
$graph_query = "
  resources
  | where type =~ 'microsoft.sql/servers'
  | where tags.Environment == '$source' and tags.Type == 'Primary'
  | project name, resourceGroup, subscriptionId, fqdn = properties.fullyQualifiedDomainName
"
$server = az graph query -q $graph_query --query "data" --first 1000 | ConvertFrom-Json

if (-not $server -or $server.Count -eq 0) {
    Write-Host "❌ No SQL server found for environment: $source" -ForegroundColor Red
    exit 1
}

$source_subscription = $server[0].subscriptionId
$source_server = $server[0].name
$source_rg = $server[0].resourceGroup
$source_fqdn = $server[0].fqdn

# Determine resource URL
if ($source_fqdn -match "database.windows.net") {
    $resourceUrl = "https://database.windows.net"
} else {
    $resourceUrl = "https://database.usgovcloudapi.net"
}

# Parse server name components
$source_split = $source_server -split "-"
$source_product = $source_split[1]
$source_location = $source_split[-1]
$source_type = $source_split[2]
$source_environment = $source_split[3]

# Get access token
$AccessToken = (az account get-access-token --resource="$resourceUrl" --query accessToken --output tsv)

# Display configuration
Write-Host "📋 RESTORE CONFIGURATION" -ForegroundColor Cyan
Write-Host "========================" -ForegroundColor Cyan
Write-Host "Source Server: $source_server" -ForegroundColor Yellow
Write-Host "Source Environment: $source" -ForegroundColor Yellow
Write-Host "Source Namespace: $SourceNamespace" -ForegroundColor Yellow
Write-Host "Restore Point: $($restore_point_in_timezone.ToString('yyyy-MM-dd HH:mm:ss')) ($Timezone)" -ForegroundColor Yellow
Write-Host "UTC Time: $($restore_point_utc.ToString('yyyy-MM-dd HH:mm:ss')) UTC" -ForegroundColor Gray
Write-Host ""

# Get list of databases from source SQL server
Write-Host "🔍 Fetching databases from source server..." -ForegroundColor Cyan

if ($SourceNamespace -eq "manufacturo") {
    # Special handling for "manufacturo" - get all databases (no ClientName filtering)
    $dbs = az sql db list `
        --subscription $source_subscription `
        --resource-group $source_rg `
        --server $source_server `
        --query "[?tags.ClientName == '']" | ConvertFrom-Json
} else {
    $dbs = az sql db list `
        --subscription $source_subscription `
        --resource-group $source_rg `
        --server $source_server `
        --query "[?tags.ClientName == '$SourceNamespace']" | ConvertFrom-Json
}

if (-not $dbs -or $dbs.Count -eq 0) {
    Write-Host "❌ No databases found with provided parameters" -ForegroundColor Red
    exit 1
}

Write-Host "Found $($dbs.Count) databases on source server" -ForegroundColor Green
Write-Host ""

# ============================================================================
# ANALYZE DATABASES
# ============================================================================

Write-Host "📊 ANALYZING DATABASES" -ForegroundColor Cyan
Write-Host "======================" -ForegroundColor Cyan

$databasesToRestore = @()

foreach ($db in $dbs) {
    $service = Get-ServiceFromDatabase -Database $db
    
    Write-Host "  📋 Analyzing: $($db.name) (Service: $service)" -ForegroundColor Gray
    
    if (-not (Should-RestoreDatabase -DatabaseName $db.name -Service $service)) {
        if ($db.name.Contains("master")) {
            Write-Host "    ⏭️  Skipping: System database" -ForegroundColor Yellow
        } elseif ($db.name.Contains("Copy")) {
            Write-Host "    ⏭️  Skipping: Copy database" -ForegroundColor Yellow
        } elseif ($db.name.Contains("restored")) {
            Write-Host "    ⏭️  Skipping: Already restored" -ForegroundColor Yellow
        } elseif ($db.name.Contains("landlord")) {
            Write-Host "    ⏭️  Skipping: Landlord service" -ForegroundColor Yellow
        }
        continue
    }
    
    # Check if database matches expected pattern
    $matchesPattern = Test-DatabaseMatchesPattern `
        -DatabaseName $db.name `
        -Service $service `
        -SourceNamespace $SourceNamespace `
        -SourceProduct $source_product `
        -SourceType $source_type `
        -SourceEnvironment $source_environment `
        -SourceLocation $source_location
    
    if ($matchesPattern) {
        Write-Host "    ✅ Will restore to: $($db.name)-restored" -ForegroundColor Green
        $databasesToRestore += $db
    } else {
        Write-Host "    ⏭️  Skipping: Pattern mismatch" -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host "📊 ANALYSIS SUMMARY" -ForegroundColor Cyan
Write-Host "===================" -ForegroundColor Cyan
Write-Host "Total databases found: $($dbs.Count)" -ForegroundColor White
Write-Host "Databases to restore: $($databasesToRestore.Count)" -ForegroundColor Green
Write-Host "Databases skipped: $($dbs.Count - $databasesToRestore.Count)" -ForegroundColor Yellow
Write-Host ""

if ($databasesToRestore.Count -eq 0) {
    Write-Host "⚠️  No databases to restore" -ForegroundColor Yellow
    exit 0
}

# ============================================================================
# DRY RUN MODE
# ============================================================================

if ($DryRun) {
    Write-Host "🔍 DRY RUN: Databases that would be restored:" -ForegroundColor Yellow
    Write-Host ""
    foreach ($db in $databasesToRestore) {
        Write-Host "  • $($db.name) → $($db.name)-restored" -ForegroundColor Gray
    }
    Write-Host ""
    Write-Host "Restore Point: $($restore_point_in_timezone.ToString('yyyy-MM-dd HH:mm:ss')) ($Timezone)" -ForegroundColor Green
    Write-Host "UTC Time: $($restore_point_utc.ToString('yyyy-MM-dd HH:mm:ss')) UTC" -ForegroundColor Gray
    Write-Host ""
    Write-Host "🔍 DRY RUN: No actual operations performed" -ForegroundColor Yellow
    exit 0
}

# ============================================================================
# RESTORE DATABASES (PARALLEL)
# ============================================================================

Write-Host "🚀 STARTING DATABASE RESTORE PROCESS" -ForegroundColor Cyan
Write-Host "=====================================" -ForegroundColor Cyan
Write-Host "Processing $($databasesToRestore.Count) databases in parallel" -ForegroundColor White
Write-Host "Throttle limit: $ThrottleLimit" -ForegroundColor Gray
Write-Host "Max wait time per database: $MaxWaitMinutes minutes" -ForegroundColor Gray
Write-Host ""

# Start all restore operations in parallel
Write-Host "🔄 Initiating restore operations..." -ForegroundColor Cyan
$restored_dbs = $databasesToRestore | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
    $source_subscription = $using:source_subscription
    $source_rg = $using:source_rg
    $source_server = $using:source_server
    $restore_point_utc = $using:restore_point_utc
    $Timezone = $using:Timezone
    $restore_point_in_timezone = $using:restore_point_in_timezone
    
    $db = $_
    $db_name = "$($db.name)-restored"
    
    Write-Host "🔄 Starting restore: $($db.name) → $db_name to $($restore_point_in_timezone.ToString('yyyy-MM-dd HH:mm:ss')) ($Timezone)" -ForegroundColor Yellow
    
    # Start the restore
    az sql db restore `
        --dest-name $db_name `
        --edition Standard `
        --name $db.name `
        --resource-group $source_rg `
        --server $source_server `
        --subscription $source_subscription `
        --service-objective S3 `
        --time $($restore_point_utc.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')) `
        --no-wait
    
    # Return the database name for monitoring
    $db_name
}

Write-Host "`n⏳ Waiting for databases to restore..." -ForegroundColor Cyan
Write-Host "This may take several minutes. Progress will be shown below:" -ForegroundColor Gray
Write-Host ""

# Monitor all restore operations in parallel
$results = $restored_dbs | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
    $source_subscription = $using:source_subscription
    $source_server = $using:source_server
    $source_rg = $using:source_rg
    $source_fqdn = $using:source_fqdn
    $AccessToken = $using:AccessToken
    $db_name = $_
    $start_time = Get-Date
    $max_wait_minutes = $using:MaxWaitMinutes
    $max_iterations = $max_wait_minutes * 2  # 30 seconds per iteration
    
    for ($i = 1; $i -le $max_iterations; $i++) {
        $elapsed = (Get-Date) - $start_time
        $elapsed_minutes = [math]::Round($elapsed.TotalMinutes, 1)
        
        # Check if we've exceeded the max wait time
        if ($elapsed_minutes -ge $max_wait_minutes) {
            Write-Host "❌ $db_name failed to restore within ${max_wait_minutes} minutes" -ForegroundColor Red
            return @{ Database = $db_name; Status = "failed"; Elapsed = $max_wait_minutes; Error = "Timeout" }
        }
        
        # Quick Azure CLI check first (faster than SQL)
        try {
            $az_result = az sql db show `
                --name $db_name `
                --resource-group $source_rg `
                --server $source_server `
                --subscription $source_subscription `
                --query "status" `
                --output tsv 2>$null
            
            if ($az_result -eq "Online") {
                Write-Host "✅ $db_name restored successfully (${elapsed_minutes} min)" -ForegroundColor Green
                return @{ Database = $db_name; Status = "success"; Elapsed = $elapsed_minutes }
            }
        } catch {
            # Azure CLI check failed, try SQL check
        }
        
        # Try SQL query as fallback
        try {
            $result = Invoke-Sqlcmd `
                -AccessToken $AccessToken `
                -ServerInstance $source_fqdn `
                -Query "SELECT state_desc FROM sys.databases WHERE name = '$db_name'" `
                -ConnectionTimeout 15 `
                -QueryTimeout 30 `
                -ErrorAction SilentlyContinue
            
            if ($result -and $result.state_desc -eq "ONLINE") {
                Write-Host "✅ $db_name restored successfully (${elapsed_minutes} min)" -ForegroundColor Green
                return @{ Database = $db_name; Status = "success"; Elapsed = $elapsed_minutes }
            }
        } catch {
            # SQL query also failed, continue waiting
        }
        
        # Show progress every 2 minutes
        if ($i % 4 -eq 0) {
            Write-Host "⏳ $db_name still restoring... (${elapsed_minutes} min elapsed)" -ForegroundColor Gray
        }
        
        Start-Sleep -Seconds 30
    }
    
    # If we reach here, we've exhausted all iterations without success
    $final_elapsed = (Get-Date) - $start_time
    $final_elapsed_minutes = [math]::Round($final_elapsed.TotalMinutes, 1)
    Write-Host "❌ $db_name failed to restore within ${max_wait_minutes} minutes (${final_elapsed_minutes} min elapsed)" -ForegroundColor Red
    return @{ Database = $db_name; Status = "failed"; Elapsed = $final_elapsed_minutes; Error = "Timeout" }
}

# Calculate success/failure counts
$successCount = ($results | Where-Object { $_.Status -eq "success" }).Count
$failCount = ($results | Where-Object { $_.Status -eq "failed" }).Count

# ============================================================================
# FINAL SUMMARY
# ============================================================================

Write-Host "`n"
Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "           FINAL RESTORE SUMMARY" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

if ($successCount -gt 0) {
    Write-Host "✅ SUCCESSFUL RESTORES: $successCount" -ForegroundColor Green
    Write-Host "───────────────────────────────────────────────────" -ForegroundColor Gray
    $results | Where-Object { $_.Status -eq "success" } | ForEach-Object {
        Write-Host "  ✅ $($_.Database) ($($_.Elapsed) min)" -ForegroundColor Green
    }
    Write-Host ""
}

if ($failCount -gt 0) {
    Write-Host "❌ FAILED RESTORES: $failCount" -ForegroundColor Red
    Write-Host "───────────────────────────────────────────────────" -ForegroundColor Gray
    $results | Where-Object { $_.Status -eq "failed" } | ForEach-Object {
        Write-Host "  ❌ $($_.Database)" -ForegroundColor Red
        Write-Host "     Phase: $($_.Phase)" -ForegroundColor Gray
        Write-Host "     Error: $($_.Error)" -ForegroundColor Gray
    }
    Write-Host ""
    Write-Host "💡 Please investigate failed restores and retry if needed" -ForegroundColor Yellow
    exit 1
}

Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "🎉 All database restores completed successfully!" -ForegroundColor Green
Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Cyan
