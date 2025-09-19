param (
  [Parameter(Mandatory)][string]$source,
  [AllowEmptyString()][string]$SourceNamespace,
  [Parameter(Mandatory)][string]$RestoreDateTime,
  [Parameter(Mandatory)][string]$Timezone,
  [switch]$DryRun,
  [int]$MaxWaitMinutes
)

Write-Host "`n=========================" -ForegroundColor Cyan
Write-Host " Restore Point In Time" -ForegroundColor Cyan
Write-Host "===========================`n" -ForegroundColor Cyan

$source = $source.ToLower()
$SourceNamespace = $SourceNamespace.ToLower()

$graph_query = "
  resources
  | where type =~ 'microsoft.sql/servers'
  | where tags.Environment == '$source' and tags.Type == 'Primary'
  | project name, resourceGroup, subscriptionId, fqdn = properties.fullyQualifiedDomainName
"
$server = az graph query -q $graph_query --query "data" --first 1000 | ConvertFrom-Json

$source_subscription = $server[0].subscriptionId
$source_server = $server[0].name
$source_rg = $server[0].resourceGroup
$source_fqdn = $server[0].fqdn

# Parse the user-provided datetime with specified timezone
try {
    # Create timezone info
    $timezoneInfo = [System.TimeZoneInfo]::FindSystemTimeZoneById($Timezone)
    Write-Host "Using timezone: $Timezone ($($timezoneInfo.DisplayName))" -ForegroundColor Green
    
    # Parse the datetime in the specified timezone
    $restore_point = [DateTime]::Parse($RestoreDateTime)
    
    # ✅ FIX: If timezone is UTC, treat input as already UTC
    if ($Timezone -eq "UTC") {
        # Input is already in UTC, no conversion needed
        $restore_point_in_timezone = $restore_point
        $restore_point_utc = $restore_point
        Write-Host "Input datetime: $($restore_point.ToString('yyyy-MM-dd HH:mm:ss'))" -ForegroundColor Gray
        Write-Host "In UTC: $($restore_point_in_timezone.ToString('yyyy-MM-dd HH:mm:ss'))" -ForegroundColor Green
        Write-Host "UTC restore point: $($restore_point_utc.ToString('yyyy-MM-dd HH:mm:ss')) UTC" -ForegroundColor Gray
    } else {
        # Convert from specified timezone to UTC
        $restore_point_in_timezone = [System.TimeZoneInfo]::ConvertTime($restore_point, $timezoneInfo)
        $restore_point_utc = $restore_point_in_timezone.ToUniversalTime()
        
        Write-Host "Input datetime: $($restore_point.ToString('yyyy-MM-dd HH:mm:ss'))" -ForegroundColor Gray
        Write-Host "In $($Timezone): $($restore_point_in_timezone.ToString('yyyy-MM-dd HH:mm:ss'))" -ForegroundColor Green
        Write-Host "UTC restore point: $($restore_point_utc.ToString('yyyy-MM-dd HH:mm:ss')) UTC" -ForegroundColor Gray
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
        Write-Host "   - Or choose from the predefined options (1-5)" -ForegroundColor Yellow
    }
    
    Write-Host "   - Invalid datetime format. Please use format: 'yyyy-MM-dd HH:mm:ss'" -ForegroundColor Yellow
    Write-Host "Example: '2025-08-06 10:30:00' with timezone 'America/Los_Angeles'" -ForegroundColor Gray
    exit 1
}
if ($source_fqdn -match "database.windows.net") {
  $scope = "https://database.windows.net"
} else {
  $scope = "https://database.usgovcloudapi.net"
}

$source_split       = $source_server -split "-"
$source_product     = $source_split[1]
$source_location    = $source_split[-1]
$source_type        = $source_split[2]
$source_environment = $source_split[3]

$AccessToken = (az account get-access-token --resource="$scope" --query accessToken --output tsv)

# Write-Host "Source subscription: $source_subscription" -ForegroundColor Yellow
Write-Host "Source server: $source_server" -ForegroundColor Yellow
# Write-Host "Source resource group: $source_rg" -ForegroundColor Yellow
Write-Host "Source multitenant filter: $SourceNamespace" -ForegroundColor Yellow

# Get list of DBs from Source SQL Server
if ($SourceNamespace -eq "manufacturo") {
    # Special handling for "manufacturo" - get all databases (no ClientName filtering)
    $dbs = az sql db list --subscription $source_subscription --resource-group $source_rg --server $source_server --query "[?tags.ClientName == '']"| ConvertFrom-Json
} else {
    $dbs = az sql db list --subscription $source_subscription --resource-group $source_rg --server $source_server --query "[?tags.ClientName == '$SourceNamespace']" | ConvertFrom-Json
}

if (!$dbs) {
  Write-Host "No database found with provided parameters" -ForegroundColor Red
  exit 1
}
Write-Host "Found $($dbs.Count) databases to process" -ForegroundColor Green

# Filter databases to restore
$databases_to_restore = @()
foreach ($db in $dbs) {
  $service = $db.tags.Service
  if ($SourceNamespace -eq "manufacturo") {
    # Special handling for "manufacturo" - check standard pattern without multitenant
    if (!$db.name.Contains("Copy") -and !$db.name.Contains("master") -and !$db.name.Contains("restored") -and !$db.name.Contains("landlord") -and $db.name.Contains("$source_product-$source_type-$service-$source_environment-$source_location")) {
      $databases_to_restore += $db
    }
  } else {
    if (!$db.name.Contains("Copy") -and !$db.name.Contains("master") -and !$db.name.Contains("restored") -and !$db.name.Contains("landlord") -and $db.name.Contains("$source_product-$source_type-$service-$SourceNamespace-$source_environment-$source_location")) {
      $databases_to_restore += $db
    }
  }
}

if ($DryRun) {
  Write-Host "🔍 DRY RUN MODE - No actual restores will be performed" -ForegroundColor Yellow
  Write-Host "Databases that would be restored:" -ForegroundColor Cyan
  $databases_to_restore | ForEach-Object {
    Write-Host "   • $($_.name)-restored" -ForegroundColor Gray
  }
  Write-Host "`nRestore point: $($restore_point_in_timezone.ToString('yyyy-MM-dd HH:mm:ss')) ($($Timezone))" -ForegroundColor Green
  Write-Host "UTC restore point: $($restore_point_utc.ToString('yyyy-MM-dd HH:mm:ss')) UTC" -ForegroundColor Gray
  exit 0
}

  Write-Host "Starting parallel restore of $($databases_to_restore.Count) databases..." -ForegroundColor Cyan

# Run restores in parallel
$restored_dbs = $databases_to_restore | ForEach-Object -ThrottleLimit 10 -Parallel {
  $source_subscription = $using:source_subscription
  $source_rg = $using:source_rg
  $source_server = $using:source_server
  $restore_point_utc = $using:restore_point_utc
  $Timezone = $using:Timezone
  $restore_point_in_timezone = $using:restore_point_in_timezone
  
  $db = $_
  $db_name = "$($db.name)-restored"
  
    Write-Host "🔄 Starting restore: $($db.name)-restored to $($restore_point_in_timezone.ToString('yyyy-MM-dd HH:mm:ss')) ($($Timezone))" -ForegroundColor Yellow
  
  # Start the restore
  az sql db restore --dest-name $db_name --edition Standard --name $db.name --resource-group $source_rg --server $source_server --subscription $source_subscription --service-objective S3 --time $($restore_point_utc.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')) --no-wait
  
  # Return the database name for monitoring
  $db_name
}

  Write-Host "`n⏳ Waiting for databases to restore..." -ForegroundColor Cyan
  Write-Host "This may take several minutes. Progress will be shown below:" -ForegroundColor Gray
  Write-Host ""

$results = $restored_dbs | ForEach-Object -ThrottleLimit 10 -Parallel {
  $source_subscription = $using:source_subscription
  $source_server = $using:source_server
  $source_rg = $using:source_rg
  $restored_dbs = $using:restored_dbs
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
      return @{ db = $db_name; status = "failed"; elapsed = $max_wait_minutes }
    }
    
    try {
      $result = Invoke-Sqlcmd -AccessToken $AccessToken -ServerInstance "$source_fqdn" -Query "SELECT state_desc FROM sys.databases WHERE name = '$db_name'" -ErrorAction SilentlyContinue
      if ($result.state_desc -eq "ONLINE") {
          Write-Host "✅ $db_name restored successfully (${elapsed_minutes}min)" -ForegroundColor Green
        return @{ db = $db_name; status = "restored"; elapsed = $elapsed_minutes }
      } else {
        # Show progress every 2 minutes
        if ($i % 4 -eq 0) {
          Write-Host "⏳ $db_name still restoring... (${elapsed_minutes}min elapsed)" -ForegroundColor Yellow
        }
        Start-Sleep -Seconds 30
      }
    } catch {
      # Show progress every 2 minutes even if query fails
      if ($i % 4 -eq 0) {
        Write-Host "⏳ $db_name still restoring... (${elapsed_minutes}min elapsed)" -ForegroundColor Yellow
      }
      Start-Sleep -Seconds 30
    }
  }
  
  # If we reach here, we've exhausted all iterations without success
  $final_elapsed = (Get-Date) - $start_time
  $final_elapsed_minutes = [math]::Round($final_elapsed.TotalMinutes, 1)
  Write-Host "❌ $db_name failed to restore within ${max_wait_minutes} minutes (${final_elapsed_minutes}min elapsed)" -ForegroundColor Red
  return @{ db = $db_name; status = "failed"; elapsed = $final_elapsed_minutes }
}

# Check results and provide summary
  Write-Host "`n📊 RESTORE SUMMARY" -ForegroundColor Cyan
  Write-Host "==================" -ForegroundColor Cyan

$successful = $results | Where-Object { $_.status -eq "restored" }
$failed = $results | Where-Object { $_.status -eq "failed" }

if ($successful.Count -gt 0) {
  Write-Host "✅ Successfully restored databases:" -ForegroundColor Green
  $successful | ForEach-Object { 
    Write-Host "   • $($_.db) (${$_.elapsed}min)" -ForegroundColor Green 
  }
}

if ($failed.Count -gt 0) {
    Write-Host "`n❌ Failed to restore databases:" -ForegroundColor Red
    $failed | ForEach-Object { 
      Write-Host "   • $($_.db)" -ForegroundColor Red 
    Write-Host "`n💡 Some databases failed to restore. Please check manually." -ForegroundColor Yellow
  }
  exit 1
}

  Write-Host "`n🎉 All databases restored successfully!" -ForegroundColor Green