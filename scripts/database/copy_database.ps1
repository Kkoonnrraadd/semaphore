param (
    [Parameter(Mandatory)] [string]$source,
    [Parameter(Mandatory)] [string]$destination,
    [Parameter(Mandatory)][string]$SourceNamespace, 
    [Parameter(Mandatory)][string]$DestinationNamespace,
    [switch]$DryRun
)

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

function Test-DatabasePermissions {
    param (
        [string]$ServerFQDN,
        [string]$AccessToken,
        [string]$DatabaseName = "master"
    )
    
    Write-Host "  🔍 Testing database permissions on $ServerFQDN..." -ForegroundColor Gray
    
    try {
        # Test basic connectivity
        $connectivityQuery = "SELECT @@VERSION as version, DB_NAME() as current_db"
        $result = Invoke-Sqlcmd -AccessToken $AccessToken -ServerInstance $ServerFQDN -Database $DatabaseName -Query $connectivityQuery -ConnectionTimeout 15 -QueryTimeout 30
        
        if ($result) {
            Write-Host "    ✅ Basic connectivity successful" -ForegroundColor Green
            Write-Host "    📋 Current Database: $($result.current_db)" -ForegroundColor Gray
            Write-Host "    📋 SQL Server Version: $($result.version.Split("`n")[0])" -ForegroundColor Gray
        } else {
            Write-Host "    ❌ Basic connectivity failed" -ForegroundColor Red
            return $false
        }
        
        # Test if user has permissions to create databases
        $permissionQuery = @"
SELECT 
    HAS_PERMS_BY_NAME('master', 'DATABASE', 'CREATE DATABASE') as can_create_db,
    IS_SRVROLEMEMBER('dbcreator') as is_dbcreator,
    IS_SRVROLEMEMBER('sysadmin') as is_sysadmin
"@
        
        $permissions = Invoke-Sqlcmd -AccessToken $AccessToken -ServerInstance $ServerFQDN -Database "master" -Query $permissionQuery -ConnectionTimeout 15 -QueryTimeout 30
        
        Write-Host "    📋 Permission Query Results:" -ForegroundColor Gray
        Write-Host "      • Can Create Database: $($permissions.can_create_db)" -ForegroundColor Gray
        Write-Host "      • Is dbcreator Role: $($permissions.is_dbcreator)" -ForegroundColor Gray
        Write-Host "      • Is sysadmin Role: $($permissions.is_sysadmin)" -ForegroundColor Gray
        
        if ($permissions.can_create_db -eq 1 -or $permissions.is_dbcreator -eq 1 -or $permissions.is_sysadmin -eq 1) {
            Write-Host "    ✅ Database creation permissions confirmed" -ForegroundColor Green
        } else {
            Write-Host "    ❌ Insufficient permissions to create databases" -ForegroundColor Red
            return $false
        }
        
        # Test if user can query system tables (needed for copy operations)
        $systemQuery = "SELECT COUNT(*) as table_count FROM sys.databases"
        $systemResult = Invoke-Sqlcmd -AccessToken $AccessToken -ServerInstance $ServerFQDN -Database "master" -Query $systemQuery -ConnectionTimeout 15 -QueryTimeout 30
        
        Write-Host "    📋 System Table Query Results:" -ForegroundColor Gray
        Write-Host "      • Database Count: $($systemResult.table_count)" -ForegroundColor Gray
        
        if ($systemResult -and $systemResult.table_count -ge 0) {
            Write-Host "    ✅ System table access confirmed" -ForegroundColor Green
        } else {
            Write-Host "    ❌ Cannot access system tables" -ForegroundColor Red
            return $false
        }
        
        return $true
        
    } catch {
        Write-Host "    ❌ Permission test failed: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

function Get-ServiceFromDatabase {
    param (
        [object]$Database,
        [array]$AllDatabases
    )
    
    # For restored databases, get service from the corresponding source database
    if ($Database.name.Contains("restored")) {
        $sourceDbName = $Database.name -replace "-restored$", ""
        $sourceDb = $AllDatabases | Where-Object { $_.name -eq $sourceDbName }
        if ($sourceDb) {
            return $sourceDb.tags.Service
        }
        return ""
    }
    
    # For regular databases, use the service tag
    return $Database.tags.Service
}

function Should-ProcessDatabase {
    param (
        [object]$Database,
        [string]$Service
    )
    
    # Skip system databases
    if ($Database.name.Contains("master")) {
        return $false
    }
    
    # Skip landlord service
    if ($Service -eq "landlord") {
        return $false
    }
    
    # Skip non-restored databases
    if (-not $Database.name.Contains("restored")) {
        return $false
    }
    
        return $true
    }
    
function Get-DestinationDatabaseName {
    param (
        [string]$SourceDatabaseName,
        [string]$Service,
        [string]$SourceNamespace,
        [string]$DestinationNamespace,
        [string]$SourceProduct,
        [string]$SourceType,
        [string]$SourceEnvironment,
        [string]$SourceLocation,
        [string]$DestType,
        [string]$DestEnvironment,
        [string]$DestLocation
    )
    
    # Remove -restored suffix for pattern matching
    $sourceDbNameClean = $SourceDatabaseName -replace "-restored$", ""
    
    if ($SourceNamespace -eq "manufacturo") {
        $expectedPattern = "$SourceProduct-$SourceType-$Service-$SourceEnvironment-$SourceLocation"
        
        if (-not $sourceDbNameClean.Contains($expectedPattern)) {
            return $null
        }
        
        if ($DestinationNamespace -eq "manufacturo") {
            return $sourceDbNameClean `
                -replace [regex]::Escape($SourceEnvironment), $DestEnvironment `
                -replace [regex]::Escape($SourceLocation), $DestLocation `
                -replace [regex]::Escape($SourceType), $DestType
        } else {
            return $sourceDbNameClean `
                -replace [regex]::Escape($SourceEnvironment), "$DestinationNamespace-$DestEnvironment" `
                -replace [regex]::Escape($SourceLocation), $DestLocation `
                -replace [regex]::Escape($SourceType), $DestType
        }
    } else {
        $expectedPattern = "$SourceProduct-$SourceType-$Service-$SourceNamespace-$SourceEnvironment-$SourceLocation"
        
        if (-not $sourceDbNameClean.Contains($expectedPattern)) {
            return $null
        }
        
        if ($DestinationNamespace -eq "manufacturo") {
            return $sourceDbNameClean `
                -replace [regex]::Escape("$SourceNamespace-$SourceEnvironment"), $DestEnvironment `
                -replace [regex]::Escape($SourceLocation), $DestLocation `
                -replace [regex]::Escape($SourceType), $DestType
        } else {
            return $sourceDbNameClean `
                -replace [regex]::Escape("$SourceNamespace-$SourceEnvironment"), "$DestinationNamespace-$DestEnvironment" `
                -replace [regex]::Escape($SourceLocation), $DestLocation `
                -replace [regex]::Escape($SourceType), $DestType
        }
    }
}

function Save-DatabaseTags {
    param (
        [string]$Server,
        [string]$ResourceGroup,
        [string]$SubscriptionId,
        [string]$DatabaseName
    )
    
    try {
        $existingDb = az sql db show --subscription $SubscriptionId --resource-group $ResourceGroup --server $Server --name $DatabaseName --query "tags" -o json 2>$null | ConvertFrom-Json
        
        if ($existingDb -and $existingDb.PSObject.Properties.Count -gt 0) {
            $tagList = @()
            foreach ($tag in $existingDb.PSObject.Properties) {
                $tagList += "$($tag.Name)=$($tag.Value)"
            }
            Write-Host "  📋 Saved tags from $DatabaseName : $($tagList -join ', ')" -ForegroundColor Gray
            return $existingDb
        } else {
            Write-Host "  ⚠️  No existing tags found on $DatabaseName" -ForegroundColor Yellow
            return $null
        }
    }
    catch {
        Write-Host "  ❌ Error retrieving tags for $DatabaseName : $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }
}

function Apply-DatabaseTags {
    param (
        [string]$Server,
        [string]$ResourceGroup,
        [string]$SubscriptionId,
        [string]$DatabaseName,
        [object]$Tags
    )
    
    if (-not $Tags -or $Tags.PSObject.Properties.Count -eq 0) {
        Write-Host "  ℹ️  No tags to restore for $DatabaseName" -ForegroundColor Gray
        return
    }
    
    $tagList = @()
    
    try {
        foreach ($tag in $Tags.PSObject.Properties) {
            $tagList += "$($tag.Name)=$($tag.Value)"
            
            # Apply each tag individually
            $null = az sql db update `
                --subscription $SubscriptionId `
                --resource-group $ResourceGroup `
                --server $Server `
                --name $DatabaseName `
                --set "tags.$($tag.Name)=$($tag.Value)" `
                --output none 2>$null
        }
            
        Write-Host "  🏷️  Restored tags to $DatabaseName : $($tagList -join ', ')" -ForegroundColor Green
    }
    catch {
        Write-Host "  ⚠️  Warning: Failed to apply tags to $DatabaseName : $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

function Copy-SingleDatabase {
    param (
        [string]$SourceDatabaseName,
        [string]$DestinationDatabaseName,
        [string]$SourceServer,
        [string]$DestServer,
        [string]$DestServerFQDN,
        [string]$DestResourceGroup,
        [string]$DestSubscriptionId,
        [string]$DestElasticPool,
        [string]$AccessToken,
        [object]$SavedTags,
        [object]$ServerSecondary = $null,
        [string]$DestServerSecondary = $null,
        [string]$DestResourceGroupSecondary = $null,
        [string]$DestSubscriptionIdSecondary = $null
    )
    
    Write-Host "`n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
    Write-Host "📋 Copying: $SourceDatabaseName" -ForegroundColor Cyan
    Write-Host "   Target: $DestinationDatabaseName" -ForegroundColor Cyan
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
    
    # Delete existing destination database (secondary first, then primary)
    if ($ServerSecondary -and $DestServerSecondary) {
        Write-Host "  🗑️  Deleting existing database from secondary server: $DestinationDatabaseName" -ForegroundColor Yellow
        try {
            $deleteResultSecondary = az sql db delete `
                --name $DestinationDatabaseName `
                --resource-group $DestResourceGroupSecondary `
                --server $DestServerSecondary `
                --subscription $DestSubscriptionIdSecondary `
                --yes --only-show-errors 2>&1
            
            if ($LASTEXITCODE -ne 0) {
                Write-Host "  ⚠️  Database may not exist on secondary (this is OK): $deleteResultSecondary" -ForegroundColor Gray
            } else {
                Write-Host "  ✅ Deleted existing database from secondary server" -ForegroundColor Green
            }
            Start-Sleep -Seconds 10
        } catch {
            Write-Host "  ⚠️  Warning during secondary deletion: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
    
    Write-Host "  🗑️  Deleting existing database from primary server: $DestinationDatabaseName" -ForegroundColor Yellow
    try {
        $deleteResult = az sql db delete `
            --name $DestinationDatabaseName `
            --resource-group $DestResourceGroup `
            --server $DestServer `
            --subscription $DestSubscriptionId `
            --yes --only-show-errors 2>&1
        
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  ⚠️  Database may not exist on primary (this is OK): $deleteResult" -ForegroundColor Gray
        } else {
            Write-Host "  ✅ Deleted existing database from primary server" -ForegroundColor Green
        }
        Start-Sleep -Seconds 10
        } catch {
        Write-Host "  ⚠️  Warning during primary deletion: $($_.Exception.Message)" -ForegroundColor Yellow
    }
    
    # Build SQL copy command
    $sqlCommand = "CREATE DATABASE [$DestinationDatabaseName] AS COPY OF [$SourceServer].[$SourceDatabaseName] (SERVICE_OBJECTIVE = ELASTIC_POOL(name = [$DestElasticPool]));"
    
    # Execute copy with retry logic
    Write-Host "  🔄 Initiating database copy..." -ForegroundColor Yellow
    $maxRetries = 3
    $retryDelay = 5
    $copyInitiated = $false
    
    for ($retry = 1; $retry -le $maxRetries; $retry++) {
        try {
            if ($retry -gt 1) {
                Write-Host "  🔄 Retry attempt $retry of $maxRetries" -ForegroundColor Yellow
                Start-Sleep -Seconds $retryDelay
            }
            
            Invoke-Sqlcmd -AccessToken $AccessToken -ServerInstance $DestServerFQDN -Query $sqlCommand -ConnectionTimeout 30 -QueryTimeout 300
            Write-Host "  ✅ Copy command executed successfully (attempt $retry)" -ForegroundColor Green
            $copyInitiated = $true
            Start-Sleep -Seconds 10
            break
        
    } catch {
            Write-Host "  ❌ Attempt $retry failed: $($_.Exception.Message)" -ForegroundColor Red
            
            if ($retry -eq $maxRetries) {
                Write-Host "  ❌ All retry attempts exhausted" -ForegroundColor Red
                return @{ 
                    Database = $DestinationDatabaseName
                    Status = "failed"
                    Error = $_.Exception.Message
                    Phase = "copy_initiation"
                }
            } else {
                $retryDelay = $retryDelay * 2  # Exponential backoff
            }
        }
    }
    
    if (-not $copyInitiated) {
        return @{ 
            Database = $DestinationDatabaseName
            Status = "failed"
            Error = "Failed to initiate copy"
            Phase = "copy_initiation"
        }
    }
    
    # Wait for database to come online
    Write-Host "  ⏳ Waiting for database to come online..." -ForegroundColor Yellow
    $startTime = Get-Date
    $maxWaitMinutes = 15
    $maxIterations = $maxWaitMinutes * 2  # Check every 30 seconds
    
    for ($i = 1; $i -le $maxIterations; $i++) {
        $elapsed = (Get-Date) - $startTime
        $elapsedMinutes = [math]::Round($elapsed.TotalMinutes, 1)
        
        if ($elapsedMinutes -ge $maxWaitMinutes) {
            Write-Host "  ❌ Database failed to come online within ${maxWaitMinutes} minutes" -ForegroundColor Red
            return @{ 
                Database = $DestinationDatabaseName
                Status = "failed"
                Error = "Timeout waiting for database to come online"
                Phase = "waiting_online"
                Elapsed = $elapsedMinutes
            }
        }
        
        try {
            $statusQuery = "SELECT state_desc FROM sys.databases WHERE name = '$DestinationDatabaseName'"
            $result = Invoke-Sqlcmd -AccessToken $AccessToken -ServerInstance $DestServerFQDN -Query $statusQuery -ConnectionTimeout 15 -QueryTimeout 30
            
            if ($result.state_desc -eq "ONLINE") {
                Write-Host "  ✅ Database is ONLINE (took ${elapsedMinutes} minutes)" -ForegroundColor Green
                
                # Restore tags
                if ($SavedTags) {
                    Write-Host "  🏷️  Restoring tags..." -ForegroundColor Yellow
                    Apply-DatabaseTags `
                        -Server $DestServer `
                        -ResourceGroup $DestResourceGroup `
                        -SubscriptionId $DestSubscriptionId `
                        -DatabaseName $DestinationDatabaseName `
                        -Tags $SavedTags
                }
                
                return @{ 
                    Database = $DestinationDatabaseName
                    Status = "success"
                    Elapsed = $elapsedMinutes
                }
            } else {
                # Show progress every 2 minutes
                if ($i % 4 -eq 0) {
                    Write-Host "  ⏳ Still copying... (${elapsedMinutes} min elapsed, state: $($result.state_desc))" -ForegroundColor Gray
                }
                Start-Sleep -Seconds 30
            }
        } catch {
            # Show progress even if query fails (database might not be visible yet)
            if ($i % 4 -eq 0) {
                Write-Host "  ⏳ Still copying... (${elapsedMinutes} min elapsed)" -ForegroundColor Gray
            }
            Start-Sleep -Seconds 30
        }
    }
    
    # Timeout reached
    $finalElapsed = (Get-Date) - $startTime
    $finalElapsedMinutes = [math]::Round($finalElapsed.TotalMinutes, 1)
    Write-Host "  ❌ Timeout: Database failed to come online (${finalElapsedMinutes} min)" -ForegroundColor Red
    return @{ 
        Database = $DestinationDatabaseName
        Status = "failed"
        Error = "Timeout"
        Phase = "waiting_online"
        Elapsed = $finalElapsedMinutes
    }
}

# ============================================================================
# MAIN SCRIPT
# ============================================================================

if ($DryRun) {
    Write-Host "`n🔍 DRY RUN MODE - Copy Database Script" -ForegroundColor Yellow
    Write-Host "=====================================" -ForegroundColor Yellow
    Write-Host "No actual copy operations will be performed" -ForegroundColor Yellow
} else {
    Write-Host "`n====================================" -ForegroundColor Cyan
Write-Host " Copy Database Script (RestorePoint)" -ForegroundColor Cyan
Write-Host "====================================`n" -ForegroundColor Cyan
}

$destination_lower = (Get-Culture).TextInfo.ToLower($destination)
$source_lower = (Get-Culture).TextInfo.ToLower($source)

# Query for source SQL server
$graph_query = "
  resources
  | where type =~ 'microsoft.sql/servers'
  | where tags.Environment == '$source_lower' and tags.Type == 'Primary'
  | project name, resourceGroup, subscriptionId, fqdn = properties.fullyQualifiedDomainName
"
$server = az graph query -q $graph_query --query "data" --first 1000 | ConvertFrom-Json

if (-not $server -or $server.Count -eq 0) {
    Write-Host "❌ No source SQL server found for environment: $source_lower" -ForegroundColor Red
    exit 1
}

$source_subscription = $server[0].subscriptionId
$source_server = $server[0].name
$source_rg = $server[0].resourceGroup
$source_fqdn = $server[0].fqdn
$source_server_fqdn = $server[0].fqdn

if ($source_fqdn -match "database.windows.net") {
  $resourceUrl = "https://database.windows.net"
} else {
  $resourceUrl = "https://database.usgovcloudapi.net"
}

# Query for destination SQL server
$graph_query = "
  resources
  | where type =~ 'microsoft.sql/servers'
  | where tags.Environment == '$destination_lower' and tags.Type == 'Primary'
  | project name, resourceGroup, subscriptionId, fqdn = properties.fullyQualifiedDomainName
"
$server = az graph query -q $graph_query --query "data" --first 1000 | ConvertFrom-Json

if (-not $server -or $server.Count -eq 0) {
    Write-Host "❌ No destination SQL server found for environment: $destination_lower" -ForegroundColor Red
    exit 1
}

$dest_subscription = $server[0].subscriptionId
$dest_server = $server[0].name
$dest_rg = $server[0].resourceGroup
$dest_server_fqdn = $server[0].fqdn
$dest_elasticpool = az sql elastic-pool list --subscription $dest_subscription --server $dest_server --resource-group $dest_rg --query "[0].name" -o tsv

if ([string]::IsNullOrWhiteSpace($dest_elasticpool)) {
    Write-Host "❌ No elastic pool found on destination server: $dest_server" -ForegroundColor Red
    exit 1
}

# Query for secondary SQL server (for failover group support)
Write-Host "🔍 Checking for failover group configuration..." -ForegroundColor Cyan
$graph_query_secondary = "
  resources
  | where type =~ 'microsoft.sql/servers'
  | where tags.Environment == '$destination_lower' and tags.Type == 'Secondary'
  | project name, resourceGroup, subscriptionId, fqdn = properties.fullyQualifiedDomainName
"
$server_secondary = az graph query -q $graph_query_secondary --query "data" --first 1000 | ConvertFrom-Json

$dest_subscription_secondary = $null
$dest_server_secondary = $null
$dest_rg_secondary = $null
$dest_server_fqdn_secondary = $null
$failover_group = $null

if ($server_secondary -and $server_secondary.Count -gt 0) {
    $dest_subscription_secondary = $server_secondary[0].subscriptionId
    $dest_server_secondary = $server_secondary[0].name
    $dest_rg_secondary = $server_secondary[0].resourceGroup
    $dest_server_fqdn_secondary = $server_secondary[0].fqdn
    
    Write-Host "  ✅ Secondary server found: $dest_server_secondary" -ForegroundColor Green
    
    # Check for failover group
    $failover_group = az sql failover-group list --resource-group $dest_rg --server $dest_server --subscription $dest_subscription --query "[0].name" -o tsv 2>$null
    
    if ($failover_group -and -not [string]::IsNullOrWhiteSpace($failover_group)) {
        Write-Host "  ✅ Failover group found: $failover_group" -ForegroundColor Green
    } else {
        Write-Host "  ⚠️  No failover group found on primary server" -ForegroundColor Yellow
        $server_secondary = $null
    }
} else {
    Write-Host "  ℹ️  No secondary server found (single server configuration)" -ForegroundColor Gray
}

# Display summary
Write-Host "📋 COPY SUMMARY" -ForegroundColor Cyan
Write-Host "===============" -ForegroundColor Cyan
Write-Host "Source: $source_server_fqdn" -ForegroundColor Yellow
Write-Host "Destination: $dest_server_fqdn" -ForegroundColor Yellow
Write-Host "Elastic Pool: $dest_elasticpool" -ForegroundColor Yellow
Write-Host "Source Namespace: $SourceNamespace" -ForegroundColor Yellow
Write-Host "Destination Namespace: $DestinationNamespace" -ForegroundColor Yellow
if ($server_secondary) {
    Write-Host "Secondary Server: $dest_server_fqdn_secondary" -ForegroundColor Yellow
    Write-Host "Failover Group: $failover_group" -ForegroundColor Yellow
}
Write-Host ""

# Parse server name components
$source_split = $source_server -split "-"
$source_product     = $source_split[1]
$source_location    = $source_split[-1]
$source_type        = $source_split[2]
$source_environment = $source_split[3]

$dest_split = $dest_server -split "-"
$dest_location    = $dest_split[-1]
$dest_type        = $dest_split[2]
$dest_environment = $dest_split[3]

$AccessToken = (az account get-access-token --resource "$resourceUrl" --query accessToken -o tsv)

# Get databases to copy
$dbs = az sql db list --subscription $source_subscription --resource-group $source_rg --server $source_server | ConvertFrom-Json

if (-not $dbs) {
    Write-Host "❌ No databases found on source server." -ForegroundColor Red
    exit 1
}

# Pre-flight permission validation
Write-Host "🔍 PRE-FLIGHT PERMISSION VALIDATION" -ForegroundColor Cyan
Write-Host "====================================" -ForegroundColor Cyan

$sameServer = ($source_server -eq $dest_server)
if ($sameServer) {
    Write-Host "🔍 Same server detected: $source_server" -ForegroundColor Gray
    Write-Host "   • Same-server copy operation" -ForegroundColor Gray
}

if ($sameServer) {
    Write-Host "🔍 Testing server permissions..." -ForegroundColor Gray
    $serverPermissionsOK = Test-DatabasePermissions -ServerFQDN $source_server_fqdn -AccessToken $AccessToken
    if (-not $serverPermissionsOK) {
        Write-Host "❌ Server permission validation failed" -ForegroundColor Red
        Write-Host "💡 Please ensure you have sufficient permissions on server: $source_server_fqdn" -ForegroundColor Yellow
        exit 1
    }
} else {
    Write-Host "🔍 Testing source server permissions..." -ForegroundColor Gray
    $sourcePermissionsOK = Test-DatabasePermissions -ServerFQDN $source_server_fqdn -AccessToken $AccessToken
    if (-not $sourcePermissionsOK) {
        Write-Host "❌ Source server permission validation failed" -ForegroundColor Red
        Write-Host "💡 Please ensure you have sufficient permissions on source server: $source_server_fqdn" -ForegroundColor Yellow
        exit 1
    }

    Write-Host "🔍 Testing destination server permissions..." -ForegroundColor Gray
    $destPermissionsOK = Test-DatabasePermissions -ServerFQDN $dest_server_fqdn -AccessToken $AccessToken
    if (-not $destPermissionsOK) {
        Write-Host "❌ Destination server permission validation failed" -ForegroundColor Red
        Write-Host "💡 Please ensure you have sufficient permissions on destination server: $dest_server_fqdn" -ForegroundColor Yellow
        exit 1
    }
}

Write-Host "✅ All pre-flight permission validations passed" -ForegroundColor Green
Write-Host ""

# ============================================================================
# ANALYZE DATABASES
# ============================================================================

Write-Host "📊 ANALYZING DATABASES" -ForegroundColor Cyan
Write-Host "======================" -ForegroundColor Cyan
Write-Host "Found $($dbs.Count) databases on source server" -ForegroundColor Gray
Write-Host ""

$databasesToProcess = @()

    foreach ($db in $dbs) {
    $service = Get-ServiceFromDatabase -Database $db -AllDatabases $dbs
    
    Write-Host "  📋 Analyzing: $($db.name) (Service: $service)" -ForegroundColor Gray
    
    if (-not (Should-ProcessDatabase -Database $db -Service $service)) {
            if ($db.name.Contains("master")) {
            Write-Host "    ⏭️  Skipping: System database" -ForegroundColor Yellow
            } elseif ($service -eq "landlord") {
            Write-Host "    ⏭️  Skipping: Landlord service" -ForegroundColor Yellow
            } else {
            Write-Host "    ⏭️  Skipping: Non-restored database" -ForegroundColor Yellow
            }
            continue
        }
        
    $dest_dbName = Get-DestinationDatabaseName `
        -SourceDatabaseName $db.name `
        -Service $service `
        -SourceNamespace $SourceNamespace `
        -DestinationNamespace $DestinationNamespace `
        -SourceProduct $source_product `
        -SourceType $source_type `
        -SourceEnvironment $source_environment `
        -SourceLocation $source_location `
        -DestType $dest_type `
        -DestEnvironment $dest_environment `
        -DestLocation $dest_location
    
    if ($dest_dbName) {
        Write-Host "    ✅ Will copy to: $dest_dbName" -ForegroundColor Green
        
        # Save existing tags from destination
        $savedTags = Save-DatabaseTags `
            -Server $dest_server `
            -ResourceGroup $dest_rg `
            -SubscriptionId $dest_subscription `
            -DatabaseName $dest_dbName
        
        $databasesToProcess += @{
            SourceName = $db.name
            DestinationName = $dest_dbName
            SavedTags = $savedTags
        }
            } else {
        Write-Host "    ⏭️  Skipping: Pattern mismatch" -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host "📊 ANALYSIS SUMMARY" -ForegroundColor Cyan
Write-Host "===================" -ForegroundColor Cyan
Write-Host "Total databases found: $($dbs.Count)" -ForegroundColor White
Write-Host "Databases to copy: $($databasesToProcess.Count)" -ForegroundColor Green
Write-Host "Databases skipped: $($dbs.Count - $databasesToProcess.Count)" -ForegroundColor Yellow
Write-Host ""

# ============================================================================
# DRY RUN MODE
# ============================================================================

if ($DryRun) {
    Write-Host "🔍 DRY RUN: Operations that would be performed:" -ForegroundColor Yellow
    Write-Host ""
    foreach ($dbInfo in $databasesToProcess) {
        Write-Host "  • $($dbInfo.SourceName) → $($dbInfo.DestinationName)" -ForegroundColor Gray
        if ($dbInfo.SavedTags) {
                $tagList = @()
            foreach ($tag in $dbInfo.SavedTags.PSObject.Properties) {
                    $tagList += "$($tag.Name)=$($tag.Value)"
                }
            Write-Host "    Tags to restore: $($tagList -join ', ')" -ForegroundColor Gray
        }
    }
    Write-Host ""
    Write-Host "🔍 DRY RUN: No actual operations performed" -ForegroundColor Yellow
    exit 0
}

# ============================================================================
# COPY DATABASES (SEQUENTIAL)
# ============================================================================

Write-Host "🚀 STARTING DATABASE COPY PROCESS" -ForegroundColor Cyan
Write-Host "==================================" -ForegroundColor Cyan
Write-Host "Processing $($databasesToProcess.Count) databases sequentially" -ForegroundColor White
Write-Host ""

$results = @()
$successCount = 0
$failCount = 0

foreach ($dbInfo in $databasesToProcess) {
    $result = Copy-SingleDatabase `
        -SourceDatabaseName $dbInfo.SourceName `
        -DestinationDatabaseName $dbInfo.DestinationName `
        -SourceServer $source_server `
        -DestServer $dest_server `
        -DestServerFQDN $dest_server_fqdn `
        -DestResourceGroup $dest_rg `
        -DestSubscriptionId $dest_subscription `
        -DestElasticPool $dest_elasticpool `
        -AccessToken $AccessToken `
        -SavedTags $dbInfo.SavedTags `
        -ServerSecondary $server_secondary `
        -DestServerSecondary $dest_server_secondary `
        -DestResourceGroupSecondary $dest_rg_secondary `
        -DestSubscriptionIdSecondary $dest_subscription_secondary
    
    $results += $result
    
    if ($result.Status -eq "success") {
        $successCount++
        } else {
        $failCount++
        Write-Host "`n❌ CRITICAL ERROR: Copy failed for $($result.Database)" -ForegroundColor Red
        Write-Host "   Phase: $($result.Phase)" -ForegroundColor Red
        Write-Host "   Error: $($result.Error)" -ForegroundColor Red
        Write-Host "`n🛑 STOPPING EXECUTION - Fix the error and retry" -ForegroundColor Red
        exit 1
    }
}

# ============================================================================
# FINAL SUMMARY
# ============================================================================

Write-Host "`n" 
Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "           FINAL COPY SUMMARY" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

if ($successCount -gt 0) {
    Write-Host "✅ SUCCESSFUL COPIES: $successCount" -ForegroundColor Green
    Write-Host "───────────────────────────────────────────────────" -ForegroundColor Gray
    $results | Where-Object { $_.Status -eq "success" } | ForEach-Object {
        Write-Host "  ✅ $($_.Database) ($($_.Elapsed) min)" -ForegroundColor Green
    }
Write-Host ""
}

if ($failCount -gt 0) {
    Write-Host "❌ FAILED COPIES: $failCount" -ForegroundColor Red
    Write-Host "───────────────────────────────────────────────────" -ForegroundColor Gray
    $results | Where-Object { $_.Status -eq "failed" } | ForEach-Object {
        Write-Host "  ❌ $($_.Database)" -ForegroundColor Red
        Write-Host "     Phase: $($_.Phase)" -ForegroundColor Gray
        Write-Host "     Error: $($_.Error)" -ForegroundColor Gray
    }
    Write-Host ""
    Write-Host "💡 Please investigate failed copies and retry if needed" -ForegroundColor Yellow
  exit 1
}

Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

# ============================================================================
# TAG VERIFICATION
# ============================================================================

Write-Host "🔍 VERIFYING DATABASE TAGS" -ForegroundColor Cyan
Write-Host "===========================" -ForegroundColor Cyan
Write-Host ""

# Determine required tags based on namespace
if ($DestinationNamespace -eq "manufacturo") {
    $requiredTags = @("Environment", "Owner", "Service", "Type")
    Write-Host "📋 Required tags for manufacturo namespace: $($requiredTags -join ', ')" -ForegroundColor Gray
    Write-Host "   (ClientName is optional for manufacturo namespace)" -ForegroundColor Gray
} else {
    $requiredTags = @("ClientName", "Environment", "Owner", "Service", "Type")
    Write-Host "📋 Required tags for namespace '$DestinationNamespace': $($requiredTags -join ', ')" -ForegroundColor Gray
}
Write-Host ""

$tagVerificationResults = @()
$tagsComplete = 0
$tagsIncomplete = 0
$tagsError = 0

foreach ($dbInfo in $databasesToProcess) {
    $dbName = $dbInfo.DestinationName
    
    try {
        $currentTags = az sql db show `
            --subscription $dest_subscription `
            --resource-group $dest_rg `
            --server $dest_server `
            --name $dbName `
            --query "tags" `
            -o json 2>$null | ConvertFrom-Json
        
        $missingTags = @()
        foreach ($requiredTag in $requiredTags) {
            if (-not $currentTags -or -not $currentTags.$requiredTag) {
                $missingTags += $requiredTag
            }
        }
        
        # Special handling for ClientName when namespace is manufacturo
        if ($DestinationNamespace -eq "manufacturo" -and $currentTags -and $currentTags.ClientName) {
            Write-Host "  ⚠️  $dbName : Has ClientName tag but namespace is manufacturo (should be empty)" -ForegroundColor Yellow
        }
        
        if ($missingTags.Count -eq 0) {
            Write-Host "  ✅ $dbName : All required tags present" -ForegroundColor Green
            $tagVerificationResults += @{ 
                Database = $dbName
                Status = "Complete"
                MissingTags = @()
                OriginalTags = $dbInfo.SavedTags
            }
            $tagsComplete++
        } else {
            Write-Host "  ❌ $dbName : Missing tags: $($missingTags -join ', ')" -ForegroundColor Red
            $tagVerificationResults += @{ 
                Database = $dbName
                Status = "Incomplete"
                MissingTags = $missingTags
                OriginalTags = $dbInfo.SavedTags
            }
            $tagsIncomplete++
        }
    } catch {
        Write-Host "  ⚠️  $dbName : Failed to verify tags - $($_.Exception.Message)" -ForegroundColor Yellow
        $tagVerificationResults += @{ 
            Database = $dbName
            Status = "Error"
            MissingTags = @("Verification failed")
            OriginalTags = $dbInfo.SavedTags
        }
        $tagsError++
    }
}

Write-Host ""
Write-Host "📊 TAG VERIFICATION SUMMARY" -ForegroundColor Cyan
Write-Host "===========================" -ForegroundColor Cyan
Write-Host "✅ Complete: $tagsComplete databases" -ForegroundColor Green
Write-Host "❌ Incomplete: $tagsIncomplete databases" -ForegroundColor Red
Write-Host "⚠️  Errors: $tagsError databases" -ForegroundColor Yellow
Write-Host ""

# Re-apply tags if any are missing
if ($tagsIncomplete -gt 0 -or $tagsError -gt 0) {
    Write-Host "🔧 ATTEMPTING TO RE-APPLY MISSING TAGS" -ForegroundColor Yellow
    Write-Host "=======================================" -ForegroundColor Yellow
    Write-Host ""
    
    foreach ($result in $tagVerificationResults) {
        if ($result.Status -eq "Incomplete" -or $result.Status -eq "Error") {
            Write-Host "  🔄 Re-applying tags to $($result.Database)..." -ForegroundColor Gray
            
            if ($result.OriginalTags -and $result.OriginalTags.PSObject.Properties.Count -gt 0) {
                $tagList = @()
                $applySuccess = $true
                
                foreach ($tag in $result.OriginalTags.PSObject.Properties) {
                    $tagList += "$($tag.Name)=$($tag.Value)"
                    
                    try {
                        $null = az sql db update `
                            --subscription $dest_subscription `
                            --resource-group $dest_rg `
                            --server $dest_server `
                            --name $result.Database `
                            --set "tags.$($tag.Name)=$($tag.Value)" `
                            --output none 2>$null
                    } catch {
                        Write-Host "    ⚠️  Failed to apply tag $($tag.Name): $($_.Exception.Message)" -ForegroundColor Yellow
                        $applySuccess = $false
                    }
                }
                
                if ($applySuccess) {
                    Write-Host "    ✅ Successfully re-applied tags: $($tagList -join ', ')" -ForegroundColor Green
                } else {
                    Write-Host "    ⚠️  Partially applied tags: $($tagList -join ', ')" -ForegroundColor Yellow
                }
            } else {
                Write-Host "    ⚠️  No original tags available for $($result.Database)" -ForegroundColor Yellow
            }
        }
    }
    
    Write-Host ""
    Write-Host "🔍 RE-VERIFYING TAGS AFTER RE-APPLICATION" -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host ""
    
    # Re-verify tags after re-application
    $reVerifyComplete = 0
    $reVerifyIncomplete = 0
    
    foreach ($result in $tagVerificationResults) {
        if ($result.Status -eq "Incomplete" -or $result.Status -eq "Error") {
            try {
                $currentTags = az sql db show `
                    --subscription $dest_subscription `
                    --resource-group $dest_rg `
                    --server $dest_server `
                    --name $result.Database `
                    --query "tags" `
                    -o json 2>$null | ConvertFrom-Json
                
                $missingTags = @()
                foreach ($requiredTag in $requiredTags) {
                    if (-not $currentTags -or -not $currentTags.$requiredTag) {
                        $missingTags += $requiredTag
                    }
                }
                
                if ($missingTags.Count -eq 0) {
                    Write-Host "  ✅ $($result.Database) : Tags now complete" -ForegroundColor Green
                    $reVerifyComplete++
                } else {
                    Write-Host "  ❌ $($result.Database) : Still missing: $($missingTags -join ', ')" -ForegroundColor Red
                    $reVerifyIncomplete++
                }
            } catch {
                Write-Host "  ⚠️  $($result.Database) : Re-verification failed" -ForegroundColor Yellow
                $reVerifyIncomplete++
            }
        }
    }
    
    Write-Host ""
    
    if ($reVerifyIncomplete -gt 0) {
        Write-Host "⚠️  WARNING: $reVerifyIncomplete databases still have incomplete tags" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "💡 This may cause issues with:" -ForegroundColor Yellow
        Write-Host "   • Terraform state management" -ForegroundColor Gray
        Write-Host "   • Resource identification and management" -ForegroundColor Gray
        Write-Host "   • Environment-specific configurations" -ForegroundColor Gray
        Write-Host ""
        Write-Host "🔧 Please manually verify and fix tags for the affected databases" -ForegroundColor Yellow
        Write-Host ""
    } else {
        Write-Host "✅ All tags successfully re-applied and verified" -ForegroundColor Green
        Write-Host ""
    }
}

Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

# ============================================================================
# ADD DATABASES TO FAILOVER GROUP
# ============================================================================

if ($failover_group) {
    Write-Host "🔄 ADDING DATABASES TO FAILOVER GROUP" -ForegroundColor Cyan
    Write-Host "======================================" -ForegroundColor Cyan
    Write-Host "Failover Group: $failover_group" -ForegroundColor Gray
    Write-Host ""
    
    $dest_dbs = $databasesToProcess | ForEach-Object { $_.DestinationName }
    $addedCount = 0
    $skippedCount = 0
    $failedCount = 0
    
    foreach ($dbName in $dest_dbs) {
        if (-not [string]::IsNullOrWhiteSpace($dbName)) {
            if (!$dbName.Contains("restored") -and !$dbName.Contains("landlord") -and !$dbName.Contains("master")) {
                Write-Host "  🔄 Adding $dbName to failover group..." -ForegroundColor Gray
                
                try {
                    $addResult = az sql failover-group update `
                        -g $dest_rg `
                        -s $dest_server `
                        --name $failover_group `
                        --add-db $dbName `
                        --subscription $dest_subscription `
                        --only-show-errors 2>&1
                    
                    if ($LASTEXITCODE -eq 0) {
                        Write-Host "    ✅ Successfully added to failover group" -ForegroundColor Green
                        $addedCount++
                    } else {
                        Write-Host "    ❌ Failed to add to failover group: $addResult" -ForegroundColor Red
                        $failedCount++
                    }
                } catch {
                    Write-Host "    ❌ Error adding to failover group: $($_.Exception.Message)" -ForegroundColor Red
                    $failedCount++
                }
            } else {
                Write-Host "  ⏭️  Skipping $dbName (restored or master database)" -ForegroundColor Yellow
                $skippedCount++
            }
        }
    }
    
    Write-Host ""
    Write-Host "📊 FAILOVER GROUP SUMMARY" -ForegroundColor Cyan
    Write-Host "=========================" -ForegroundColor Cyan
    Write-Host "✅ Added: $addedCount databases" -ForegroundColor Green
    Write-Host "⏭️  Skipped: $skippedCount databases" -ForegroundColor Yellow
    
    if ($failedCount -gt 0) {
        Write-Host "❌ Failed: $failedCount databases" -ForegroundColor Red
        Write-Host ""
        Write-Host "⚠️  WARNING: Some databases failed to be added to the failover group" -ForegroundColor Yellow
        Write-Host "   Please manually verify the failover group configuration" -ForegroundColor Yellow
    } else {
        Write-Host ""
        Write-Host "✅ All databases successfully added to failover group: $failover_group" -ForegroundColor Green
    }
    
    Write-Host ""
}

Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "🎉 All database copies completed successfully!" -ForegroundColor Green
Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Cyan
