param (
    [Parameter(Mandatory)] [string]$Source,
    [Parameter(Mandatory)] [string]$Destination,
    [Parameter(Mandatory)][string]$SourceNamespace, 
    [Parameter(Mandatory)][string]$DestinationNamespace,
    [Parameter(Mandatory)][int]$MaxWaitMinutes,
    [switch]$DryRun
)

# ============================================================================
# DRY RUN FAILURE TRACKING
# ============================================================================
# Track validation failures in dry run mode to fail at the end
$script:DryRunHasFailures = $false
$script:DryRunFailureReasons = @()
$requiredTags = @("ClientName", "Environment", "Owner", "Service", "Type")
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
        $SourceDbName = $Database.name -replace "-restored$", ""
        $SourceDb = $AllDatabases | Where-Object { $_.name -eq $SourceDbName }
        if ($SourceDb) {
            return $SourceDb.tags.Service
        }
        return ""
    }
    
    # For regular databases, use the service tag
    return $Database.tags.Service
}

function Should-ProcessDatabase {
    param (
        [object]$Database,
        [string]$Service,
        [bool]$IsDryRun = $false,
        [bool]$HasRestoredDatabases = $false
    )
    
    # Skip system databases
    if ($Database.name.Contains("master")) {
        return $false
    }
    
    # Skip copied databases
    if ($Database.name.Contains("copy")) {
        return $false
    }

    # Skip landlord service
    if ($Service -eq "landlord") {
        return $false
    }
    
    # Production mode: Only process restored databases
    if (-not $IsDryRun) {
        if (-not $Database.name.Contains("restored")) {
            return $false
        }
        return $true
    }
    
    # Dry Run mode logic
    if ($IsDryRun) {
        # If restored databases exist, only show those
        if ($HasRestoredDatabases) {
            if (-not $Database.name.Contains("restored")) {
                return $false
            }
        } else {
            # No restored databases exist, check regular databases
            if ($Database.name.Contains("restored")) {
                return $false
            }
        }
        return $true
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
    $SourceDbNameClean = $SourceDatabaseName -replace "-restored$", ""
    
    if ($SourceNamespace -eq "manufacturo") {
        $expectedPattern = "$SourceProduct-$SourceType-$Service-$SourceEnvironment-$SourceLocation"

        if (-not $SourceDbNameClean.Contains($expectedPattern)) {
            return $null
        }
        
        if ($DestinationNamespace -eq "manufacturo") {
            Write-Host "  ❌ Manufacturo namespace is not supported for destination" -ForegroundColor Red
            $global:LASTEXITCODE = 1
            throw "Manufacturo namespace is not supported for destination"
        } else {
            return $SourceDbNameClean `
                -replace [regex]::Escape($SourceEnvironment), "$DestinationNamespace-$DestEnvironment" `
                -replace [regex]::Escape($SourceLocation), $DestLocation `
                -replace [regex]::Escape($SourceType), $DestType
        }
    } else {
        Write-Host "  ❌ Namespace $SourceNamespace is not supported. Source Namespace can be manufacturo only!" -ForegroundColor Red
        $global:LASTEXITCODE = 1
        throw "Namespace $SourceNamespace is not supported. Source Namespace can be manufacturo only!"
    }
}

function Save-DatabaseTags {
    param (
        [string]$Server,
        [string]$ResourceGroup,
        [string]$SubscriptionId,
        [array]$RequiredTags,
        [string]$DatabaseName
    )
    
    try {
        $existingDb = az sql db show --subscription $SubscriptionId --resource-group $ResourceGroup --server $Server --name $DatabaseName --query "tags" -o json 2>$null | ConvertFrom-Json
        $tagList = @()
        
        if ($existingDb -and $existingDb.PSObject.Properties.Count -gt 0) {
            foreach ($tag in $existingDb.PSObject.Properties) {
                if ($RequiredTags -contains $tag.Name) {
                    $tagList += "$($tag.Name)=$($tag.Value)"
                }else {
                    Write-Host "    ⚠️  Tag $($tag.Name) is not in the required tags list" -ForegroundColor Yellow
                }
            }
            Write-Host "    ✅ Saved tags from $DatabaseName : $($tagList -join ', ')`n" -ForegroundColor Gray
            return $existingDb
        } else {
            Write-Host "    ⚠️  No existing tags found on $DatabaseName`n" -ForegroundColor Yellow
            return $null
        }
    }
    catch {
        Write-Host "  ❌ Error retrieving tags for $DatabaseName : $($_.Exception.Message)`n" -ForegroundColor Red
        return $null
    }
}

function Get-DatabaseSizeGB {
    param (
        [string]$ServerFQDN,
        [string]$DatabaseName,
        [string]$AccessToken
    )
    
    try {
        $sizeQuery = @"
SELECT 
    SUM(CAST(FILEPROPERTY(name, 'SpaceUsed') AS bigint) * 8192.0) / (1024.0 * 1024.0 * 1024.0) as size_gb
FROM sys.database_files
WHERE type_desc = 'ROWS'
"@
        
        $result = Invoke-Sqlcmd -AccessToken $AccessToken -ServerInstance $ServerFQDN -Database $DatabaseName -Query $sizeQuery -ConnectionTimeout 15 -QueryTimeout 60
        
        if ($result -and $result.size_gb) {
            return [math]::Round($result.size_gb, 2)
        }
        return 0
    }
    catch {
        Write-Host "    ⚠️  Warning: Could not get size for $DatabaseName : $($_.Exception.Message)" -ForegroundColor Yellow
        return 0
    }
}

function Test-ElasticPoolCapacity {
    param (
        [string]$Server,
        [string]$ResourceGroup,
        [string]$SubscriptionId,
        [string]$ElasticPoolName,
        [string]$ServerFQDN,
        [string]$AccessToken,
        [array]$SourceDatabases,
        [array]$DestinationDatabases,
        [bool]$IsDryRun
    )
    
    Write-Host "🔍 ELASTIC POOL STORAGE VALIDATION" -ForegroundColor Cyan
    Write-Host "===================================" -ForegroundColor Cyan
    Write-Host ""
    
    # Get elastic pool information
    try {
        $poolInfo = az sql elastic-pool show `
            --subscription $SubscriptionId `
            --resource-group $ResourceGroup `
            --server $Server `
            --name $ElasticPoolName `
            --query "{maxSizeBytes: maxSizeBytes, currentStorageGB: storageGB}" `
            -o json | ConvertFrom-Json
        
        $maxStorageGB = [math]::Round($poolInfo.maxSizeBytes / (1024.0 * 1024.0 * 1024.0), 2)
        
        Write-Host "  📊 Elastic Pool: $ElasticPoolName" -ForegroundColor Gray
        Write-Host "     Maximum Storage: $maxStorageGB GB" -ForegroundColor Gray
        Write-Host ""
        
    }
    catch {
        Write-Host "  ❌ Failed to get elastic pool information: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
    
    # Calculate total size of source databases (the ones we're copying FROM)
    Write-Host "  📊 Calculating source database sizes..." -ForegroundColor Gray
    $totalSourceSizeGB = 0
    
    foreach ($dbName in $SourceDatabases) {
        try {   
            $size = Get-DatabaseSizeGB -ServerFQDN $ServerFQDN -DatabaseName $dbName -AccessToken $AccessToken
            if ($size -gt 0) {
                Write-Host "     • $dbName : $size GB" -ForegroundColor Gray
                $totalSourceSizeGB += $size
            }
        }
        catch {
            Write-Host "     • $dbName : Error getting size: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
    
    Write-Host "     ═══════════════════════════════" -ForegroundColor Gray
    Write-Host "     Total Source Size: $([math]::Round($totalSourceSizeGB, 2)) GB" -ForegroundColor White
    Write-Host ""
    
    # Calculate total size of Destination databases (the ones we're REMOVING)
    Write-Host "  📊 Calculating Destination database sizes (to be removed)..." -ForegroundColor Gray
    $totalDestSizeGB = 0
    
    foreach ($dbName in $DestinationDatabases) {
        # Check if database exists first
        # $checkQuery = "SELECT name FROM sys.databases WHERE name = '$dbName'"
        try {
            # $exists = Invoke-Sqlcmd -AccessToken $AccessToken -ServerInstance $ServerFQDN -Query $checkQuery -ConnectionTimeout 15 -QueryTimeout 30
            # if ($exists) {
            $size = Get-DatabaseSizeGB -ServerFQDN $ServerFQDN -DatabaseName $dbName -AccessToken $AccessToken
            if ($size -gt 0) {
                Write-Host "     • $dbName : $size GB (will be freed)" -ForegroundColor Gray
                $totalDestSizeGB += $size
            }
            # }
            # else {
            #     Write-Host "     • $dbName : Does not exist yet (0 GB)" -ForegroundColor Gray
            # }
        }
        catch {
            Write-Host "     • $dbName : Error getting size: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
    
    Write-Host "     ═══════════════════════════════" -ForegroundColor Gray
    Write-Host "     Total Dest Size to Free: $([math]::Round($totalDestSizeGB, 2)) GB" -ForegroundColor White
    Write-Host ""
    
    # Get current elastic pool usage
    Write-Host "  📊 Calculating current elastic pool usage..." -ForegroundColor Gray
    
    try {
        # Get all databases in the elastic pool
        $poolDbs = az sql db list `
            --subscription $SubscriptionId `
            --resource-group $ResourceGroup `
            --server $Server `
            --query "[?elasticPoolName=='$ElasticPoolName'].name" `
            -o json | ConvertFrom-Json
        
        $currentUsageGB = 0
        foreach ($dbName in $poolDbs) {
            $size = Get-DatabaseSizeGB -ServerFQDN $ServerFQDN -DatabaseName $dbName -AccessToken $AccessToken
            $currentUsageGB += $size
        }
        
        Write-Host "     Current Pool Usage: $([math]::Round($currentUsageGB, 2)) GB" -ForegroundColor Gray
        Write-Host "     Available Space: $([math]::Round($maxStorageGB - $currentUsageGB, 2)) GB" -ForegroundColor Gray
        Write-Host ""
        
    }
    catch {
        Write-Host "  ❌ Error: Could not calculate current pool usage accurately" -ForegroundColor Red
        Write-Host "     Error: $($_.Exception.Message)" -ForegroundColor Red
        # $currentUsageGB = 0
        $global:LASTEXITCODE = 1
        throw "Error: Could not calculate current pool usage accurately: $($_.Exception.Message)"
    }
    
    # Calculate what will happen after the operation
    Write-Host "  📊 STORAGE IMPACT ANALYSIS" -ForegroundColor Cyan
    Write-Host "     ═══════════════════════════════" -ForegroundColor Gray
    
    $spaceToFree = [math]::Round($totalDestSizeGB, 2)
    $spaceToAdd = [math]::Round($totalSourceSizeGB, 2)
    $netChange = [math]::Round($spaceToAdd - $spaceToFree, 2)
    $projectedUsage = [math]::Round($currentUsageGB + $netChange, 2)
    $projectedAvailable = [math]::Round($maxStorageGB - $projectedUsage, 2)
    
    Write-Host "     Current Usage:        $([math]::Round($currentUsageGB, 2)) GB" -ForegroundColor White
    Write-Host "     Space to Free:       -$spaceToFree GB" -ForegroundColor Green
    Write-Host "     Space to Add:        +$spaceToAdd GB" -ForegroundColor Yellow
    Write-Host "     ───────────────────────────────" -ForegroundColor Gray
    Write-Host "     Net Change:           $netChange GB" -ForegroundColor $(if ($netChange -gt 0) { "Yellow" } else { "Green" })
    Write-Host "     ═══════════════════════════════" -ForegroundColor Gray
    Write-Host "     Projected Usage:      $projectedUsage GB" -ForegroundColor White
    Write-Host "     Pool Maximum:         $maxStorageGB GB" -ForegroundColor White
    Write-Host "     Projected Available:  $projectedAvailable GB" -ForegroundColor $(if ($projectedAvailable -lt 0) { "Red" } else { "Green" })
    Write-Host ""
    
    # Safety check: ensure we have enough space with 10% buffer
    $safetyBufferGB = [math]::Round($maxStorageGB * 0.10, 2)
    $requiredFreeSpace = [math]::Round($safetyBufferGB, 2)
    
    Write-Host "  🛡️  SAFETY VALIDATION (10% buffer required)" -ForegroundColor Cyan
    Write-Host "     Required Free Space: $requiredFreeSpace GB" -ForegroundColor Gray
    Write-Host "     Projected Free Space: $projectedAvailable GB" -ForegroundColor Gray
    Write-Host ""
    
    if ($projectedAvailable -lt 0) {
        if ($IsDryRun) {
            Write-Host "  🔴 CRITICAL ERROR: Insufficient storage capacity!" -ForegroundColor Red
            Write-Host "     The operation would EXCEED the elastic pool capacity by $([math]::Abs($projectedAvailable)) GB" -ForegroundColor Red
            Write-Host "     🔴 This would cause the operation to FAIL" -ForegroundColor Red
        }
        else {
            Write-Host "  🔴 CRITICAL ERROR: Insufficient storage capacity!" -ForegroundColor Red
            Write-Host "     The operation would EXCEED the elastic pool capacity by $([math]::Abs($projectedAvailable)) GB" -ForegroundColor Red
            Write-Host "     🛑 ABORTING to prevent failure" -ForegroundColor Red
        }
        Write-Host ""
        Write-Host "  💡 Recommendations:" -ForegroundColor Yellow
        Write-Host "     1. Increase elastic pool storage capacity" -ForegroundColor Gray
        Write-Host "     2. Remove unused databases from the pool" -ForegroundColor Gray
        Write-Host "     3. Reduce the number of databases to copy" -ForegroundColor Gray
        Write-Host ""
        return $false
    }
    elseif ($projectedAvailable -lt $requiredFreeSpace) {
        if ($IsDryRun) {
            Write-Host "  🔴 WARNING: Storage capacity is too tight!" -ForegroundColor Red
            Write-Host "     Projected free space ($projectedAvailable GB) is below the 10% safety buffer ($requiredFreeSpace GB)" -ForegroundColor Red
            Write-Host "     🔴 This is RISKY and may cause issues" -ForegroundColor Red
        }
        else {
            Write-Host "  🔴 CRITICAL WARNING: Storage capacity is too tight!" -ForegroundColor Red
            Write-Host "     Projected free space ($projectedAvailable GB) is below the 10% safety buffer ($requiredFreeSpace GB)" -ForegroundColor Red
            Write-Host "     🛑 ABORTING to prevent potential failure" -ForegroundColor Red
        }
        Write-Host ""
        Write-Host "  💡 Recommendations:" -ForegroundColor Yellow
        Write-Host "     1. Increase elastic pool storage capacity to have at least 10% free space" -ForegroundColor Gray
        Write-Host "     2. Remove unused databases from the pool" -ForegroundColor Gray
        Write-Host ""
        return $false
    }
    else {
        Write-Host "  ✅ Storage validation PASSED" -ForegroundColor Green
        Write-Host "     Sufficient storage capacity available for the operation" -ForegroundColor Green
        Write-Host "     Projected free space: $projectedAvailable GB (above $requiredFreeSpace GB safety threshold)" -ForegroundColor Green
        Write-Host ""
        return $true
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
        [string]$ResourceUrl,
        [int]$MaxWaitMinutes,
        [object]$ServerSecondary = $null,
        [string]$DestServerSecondary = $null,
        [string]$DestResourceGroupSecondary = $null,
        [string]$DestSubscriptionIdSecondary = $null
    )
    
    Write-Host "`n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
    Write-Host "📋 Copying: $SourceDatabaseName" -ForegroundColor Cyan
    Write-Host "   Target: $DestinationDatabaseName" -ForegroundColor Cyan
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
    
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
    
    # Delete existing Destination database (secondary first, then primary)
    if ($DestServerSecondary -and $DestResourceGroupSecondary -and $DestSubscriptionIdSecondary) {
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
                # # Refresh token before retry
                # Write-Host "  🔑 Refreshing access token..." -ForegroundColor Gray
                # $AccessToken = (az account get-access-token --resource "$ResourceUrl" --query accessToken -o tsv)
                # Start-Sleep -Seconds $retryDelay
            }
            
            Write-Host "  🔑 Refreshing access token..." -ForegroundColor Gray
            $AccessToken = (az account get-access-token --resource "$ResourceUrl" --query accessToken -o tsv)
            Start-Sleep -Seconds $retryDelay

            Invoke-Sqlcmd -AccessToken $AccessToken -ServerInstance $DestServerFQDN -Query $sqlCommand -ConnectionTimeout 30 -QueryTimeout 600
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
    $maxWaitMinutes = $MaxWaitMinutes + 30 # Increased 30 minutes for large database copies
    $maxIterations = $maxWaitMinutes * 2  # Check every 30 seconds
    
    for ($i = 1; $i -le $maxIterations; $i++) {
        $elapsed = (Get-Date) - $startTime
        $elapsedMinutes = [math]::Round($elapsed.TotalMinutes, 1)
        
        # Refresh token every 45 minutes to prevent expiration (Azure tokens expire after 1 hour)
        if ($i -gt 1 -and ($i % 90) -eq 0) {  # Every 45 minutes (90 iterations * 30 seconds)
            Write-Host "  🔑 Refreshing access token (${elapsedMinutes} minutes elapsed)..." -ForegroundColor Gray
            try {
                $AccessToken = (az account get-access-token --resource "$ResourceUrl" --query accessToken -o tsv)
            } catch {
                Write-Host "  ⚠️  Warning: Failed to refresh token: $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }
        
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
                
                # # Tags will be applied after all databases are copied (in TAG VERIFICATION phase)
                # if ($SavedTags) {
                #     Write-Host "  📋 Tags will be applied after all copy operations complete" -ForegroundColor Gray
                # }
                
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
    Write-Host "`n=====================================" -ForegroundColor Cyan
    Write-Host "              Copy Database" -ForegroundColor Cyan
    Write-Host "====================================`n" -ForegroundColor Cyan
}

$Destination_lower = (Get-Culture).TextInfo.ToLower($Destination)
$Source_lower = (Get-Culture).TextInfo.ToLower($Source)

# Query for source SQL server
$graph_query = "
  resources
  | where type =~ 'microsoft.sql/servers'
  | where tags.Environment == '$Source_lower' and tags.Type == 'Primary'
  | project name, resourceGroup, subscriptionId, fqdn = properties.fullyQualifiedDomainName
"
$server = az graph query -q $graph_query --query "data" --first 1000 | ConvertFrom-Json

if (-not $server -or $server.Count -eq 0) {
    Write-Host "❌ No source SQL server found for tags.Environment: $Source_lower and tags.Type: Primary" -ForegroundColor Red
    $global:LASTEXITCODE = 1
    throw "No source SQL server found for tags.Environment: $Source_lower and tags.Type: Primary"
}

$Source_subscription = $server[0].subscriptionId
$Source_server = $server[0].name
$Source_rg = $server[0].resourceGroup
$Source_fqdn = $server[0].fqdn
$Source_server_fqdn = $server[0].fqdn

# Parse server name components
$Source_split       = $Source_server -split "-"
$SourceProduct     = $Source_split[1]
$SourceLocation    = $Source_split[-1]
$SourceType        = $Source_split[2]
$SourceEnvironment = $Source_split[3]

if ($Source_fqdn -match "database.windows.net") {
    $resourceUrl = "https://database.windows.net"
  } else {
    $resourceUrl = "https://database.usgovcloudapi.net"
}

# Query for Destination SQL server
$graph_query = "
  resources
  | where type =~ 'microsoft.sql/servers'
  | where tags.Environment == '$Destination_lower' and tags.Type == 'Primary'
  | project name, resourceGroup, subscriptionId, fqdn = properties.fullyQualifiedDomainName
"
$server = az graph query -q $graph_query --query "data" --first 1000 | ConvertFrom-Json

if (-not $server -or $server.Count -eq 0) {
    Write-Host "❌ No Destination SQL server found for tags.Environment: $Destination_lower and tags.Type: Primary" -ForegroundColor Red
    $global:LASTEXITCODE = 1
    throw "No Destination SQL server found for tags.Environment: $Destination_lower and tags.Type: Primary"
}

$dest_subscription = $server[0].subscriptionId
$dest_server = $server[0].name
$dest_rg = $server[0].resourceGroup
$dest_server_fqdn = $server[0].fqdn

# Intelligent elastic pool selection logic
Write-Host "🔍 Searching for appropriate elastic pool..." -ForegroundColor Cyan

# Step 1: Try to find elastic pool with "-test-" that does NOT contain "replica"
$all_pools = az sql elastic-pool list --subscription $dest_subscription --server $dest_server --resource-group $dest_rg --query "[].name" -o tsv

if ([string]::IsNullOrWhiteSpace($all_pools)) {
    $global:LASTEXITCODE = 1
    throw "No elastic pools found on Destination server: $dest_server"
}

$pools_array = @($all_pools -split "`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
Write-Host "  📋 Found $($pools_array.Count) elastic pool(s) on server" -ForegroundColor Gray

# Try to find pool with "-test-" that doesn't contain "replica"
$test_pool = $pools_array | Where-Object { 
    $_ -match "$SourceProduct-$SourceType-test-$SourceEnvironment-$SourceLocation" -and $_ -notmatch "replica" 
} | Select-Object -First 1

if (-not [string]::IsNullOrWhiteSpace($test_pool)) {
    $dest_elasticpool = $test_pool
    Write-Host "  ✅ Selected test elastic pool: $dest_elasticpool" -ForegroundColor Green
} else {
    # Fallback: Use first available pool (original logic)
    Write-Host "  📋 No test elastic pool found (with 'pool-$SourceProduct-$SourceType-test-$SourceEnvironment-$SourceLocation' and without 'replica')" -ForegroundColor Gray
    Write-Host " Fallback to prod elastic pool" -ForegroundColor Gray
    $dest_elasticpool = $pools_array[0]
    if ($dest_elasticpool -match "pool-$SourceProduct-$SourceType-$SourceEnvironment-$SourceLocation") {
        Write-Host "  ✅ Selected prod elastic pool: $dest_elasticpool" -ForegroundColor Green
    } else {
        Write-Host "  ❌ No prod elastic pool found (with 'pool-$SourceProduct-$SourceType-$SourceEnvironment-$SourceLocation')" -ForegroundColor Red
        $global:LASTEXITCODE = 1
        throw "No prod elastic pool found (with 'pool-$SourceProduct-$SourceType-$SourceEnvironment-$SourceLocation')"
    }
}

if ([string]::IsNullOrWhiteSpace($dest_elasticpool)) {
    $global:LASTEXITCODE = 1
    throw "Failed to select an elastic pool on Destination server: $dest_server"
}

# Query for secondary SQL server (for failover group support)
Write-Host "🔍 Checking for failover group configuration..." -ForegroundColor Cyan

$graph_query_secondary = "
  resources
  | where type =~ 'microsoft.sql/servers'
  | where tags.Environment == '$Destination_lower' and tags.Type == 'Secondary'
  | project name, resourceGroup, subscriptionId, fqdn = properties.fullyQualifiedDomainName
"
$server_secondary = az graph query -q $graph_query_secondary --query "data" --first 1000 2>&1 | ConvertFrom-Json
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
    Write-Host "    • Name: $dest_server_secondary" -ForegroundColor Gray
    Write-Host "    • FQDN: $dest_server_fqdn_secondary" -ForegroundColor Gray
    Write-Host "    • Resource Group: $dest_rg_secondary" -ForegroundColor Gray
    Write-Host "    • Subscription: $dest_subscription_secondary" -ForegroundColor Gray
    
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
Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "📋 COPY SUMMARY" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "Source: $Source_server_fqdn" -ForegroundColor Yellow
Write-Host "Destination: $dest_server_fqdn" -ForegroundColor Yellow
Write-Host "Elastic Pool: $dest_elasticpool" -ForegroundColor Yellow
Write-Host "Source Namespace: $SourceNamespace" -ForegroundColor Yellow
Write-Host "Destination Namespace: $DestinationNamespace" -ForegroundColor Yellow

if ($server_secondary) {
    Write-Host "Secondary Server: $dest_server_fqdn_secondary" -ForegroundColor Yellow
    Write-Host "Failover Group: $failover_group" -ForegroundColor Yellow
}
Write-Host ""

$dest_split       = $dest_server -split "-"
$dest_product     = $dest_split[1]
$dest_location    = $dest_split[-1]
$dest_type        = $dest_split[2]
$dest_environment = $dest_split[3]

$AccessToken = (az account get-access-token --resource "$resourceUrl" --query accessToken -o tsv)

# Get databases to copy
$dbs = az sql db list --subscription $Source_subscription --resource-group $Source_rg --server $Source_server | ConvertFrom-Json

if (-not $dbs) {
    Write-Host "❌ No databases found on source server." -ForegroundColor Red
    $global:LASTEXITCODE = 1
    throw "No databases found on source server"
}

# Pre-flight permission validation
Write-Host "🔍 PRE-FLIGHT PERMISSION VALIDATION" -ForegroundColor Cyan
Write-Host "====================================" -ForegroundColor Cyan

$sameServer = ($Source_server -eq $dest_server)
if ($sameServer) {
    Write-Host "🔍 Same server detected: $Source_server" -ForegroundColor Gray
    Write-Host "   • Same-server copy operation" -ForegroundColor Gray
}

if ($sameServer) {
    Write-Host "🔍 Testing server permissions..." -ForegroundColor Gray
    $serverPermissionsOK = Test-DatabasePermissions -ServerFQDN $Source_server_fqdn -AccessToken $AccessToken
    if (-not $serverPermissionsOK) {
        Write-Host "❌ Server permission validation failed" -ForegroundColor Red
        Write-Host "💡 Please ensure you have sufficient permissions on server: $Source_server_fqdn" -ForegroundColor Yellow
        $global:LASTEXITCODE = 1
        throw "Server permission validation failed for: $Source_server_fqdn"
    }
} else {
    Write-Host "🔍 Testing source server permissions..." -ForegroundColor Gray
    $SourcePermissionsOK = Test-DatabasePermissions -ServerFQDN $Source_server_fqdn -AccessToken $AccessToken
    if (-not $SourcePermissionsOK) {
        Write-Host "❌ Source server permission validation failed" -ForegroundColor Red
        Write-Host "💡 Please ensure you have sufficient permissions on source server: $Source_server_fqdn" -ForegroundColor Yellow
        $global:LASTEXITCODE = 1
        throw "Source server permission validation failed for: $Source_server_fqdn"
    }

    Write-Host "🔍 Testing Destination server permissions..." -ForegroundColor Gray
    $destPermissionsOK = Test-DatabasePermissions -ServerFQDN $dest_server_fqdn -AccessToken $AccessToken
    if (-not $destPermissionsOK) {
        Write-Host "❌ Destination server permission validation failed" -ForegroundColor Red
        Write-Host "💡 Please ensure you have sufficient permissions on Destination server: $dest_server_fqdn" -ForegroundColor Yellow
        $global:LASTEXITCODE = 1
        throw "Destination server permission validation failed for: $dest_server_fqdn"
    }
}

Write-Host "✅ All pre-flight permission validations passed" -ForegroundColor Green
Write-Host ""

# ============================================================================
# PRE-ANALYSIS: Check for restored databases (Dry Run)
# ============================================================================

# Initialize variable for restored database check
$hasRestoredDatabases = $false

if ($DryRun) {
    Write-Host "🔍 PRE-ANALYSIS: Checking database restoration status..." -ForegroundColor Cyan
    Write-Host "========================================================" -ForegroundColor Cyan
    Write-Host ""
    
    $restoredDatabases = $dbs | Where-Object { $_.name.Contains("restored") -and -not $_.name.Contains("master") }
    $hasRestoredDatabases = ($restoredDatabases.Count -gt 0)
    
    if ($hasRestoredDatabases) {
        Write-Host "  ✅ Found $($restoredDatabases.Count) RESTORED databases" -ForegroundColor Green
        Write-Host "  📋 Dry run will evaluate: RESTORED databases (-restored suffix)" -ForegroundColor Green
        Write-Host ""
        Write-Host "  Restored databases found:" -ForegroundColor Gray
        foreach ($db in $restoredDatabases) {
            $service = Get-ServiceFromDatabase -Database $db -AllDatabases $dbs
            Write-Host "    • $($db.name) (Service: $service)" -ForegroundColor Gray
        }
    } else {
        Write-Host "  ⚠️  NO RESTORED databases found (-restored suffix)" -ForegroundColor Yellow
        Write-Host "  📋 Dry run will evaluate: REGULAR (non-restored) databases" -ForegroundColor Yellow
        Write-Host "  ℹ️  Note: Production run will NOT process these databases" -ForegroundColor Yellow
        Write-Host "           Production requires databases with '-restored' suffix" -ForegroundColor Yellow
    }
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""
} else {
    # Production mode always expects restored databases
    $hasRestoredDatabases = $true
}

# ============================================================================
# ANALYZE DATABASES
# ============================================================================

Write-Host "📊 ANALYZING DATABASES" -ForegroundColor Cyan
Write-Host "======================" -ForegroundColor Cyan
Write-Host "Found $($dbs.Count) databases on source server" -ForegroundColor Gray
Write-Host ""

$databasesToProcess = @()
# Restored dbs
foreach ($db in $dbs) {
    $service = Get-ServiceFromDatabase -Database $db -AllDatabases $dbs
    
    Write-Host "  📋 Analyzing: $($db.name) (Service: $service)" -ForegroundColor Gray
    
    if (-not (Should-ProcessDatabase -Database $db -Service $service -IsDryRun $DryRun -HasRestoredDatabases $hasRestoredDatabases)) {
            if ($db.name.Contains("master")) {
            Write-Host "    ⏭️  Skipping... System database`n" -ForegroundColor Yellow
            } elseif ($db.name.Contains("copy")) {
            Write-Host "    ⏭️  Skipping... Copied database`n" -ForegroundColor Yellow
            } elseif ($service -eq "landlord") {
            Write-Host "    ⏭️  Skipping... Landlord service`n" -ForegroundColor Yellow
            } else {
                if ($DryRun -and $hasRestoredDatabases) {
                    Write-Host "    ⏭️  Skipping... Non-restored database (restored versions available)`n" -ForegroundColor Yellow
                } elseif ($DryRun -and -not $hasRestoredDatabases) {
                    Write-Host "    ⏭️  Skipping... Restored database (evaluating regular databases)`n" -ForegroundColor Yellow
                } else {
                    Write-Host "    ⏭️  Skipping... Non-restored database`n" -ForegroundColor Yellow
                }
            }
            continue
        }
        
    $dest_dbName = Get-DestinationDatabaseName `
        -SourceDatabaseName $db.name `
        -Service $service `
        -SourceNamespace $SourceNamespace `
        -DestinationNamespace $DestinationNamespace `
        -SourceProduct $SourceProduct `
        -SourceType $SourceType `
        -SourceEnvironment $SourceEnvironment `
        -SourceLocation $SourceLocation `
        -DestType $dest_type `
        -DestEnvironment $dest_environment `
        -DestLocation $dest_location
        
    if ($dest_dbName) {
        Write-Host "    ✅ Will copy to: $dest_dbName`n" -ForegroundColor Green
        
        # Save existing tags from Destination
        $savedTags = Save-DatabaseTags `
            -Server $dest_server `
            -ResourceGroup $dest_rg `
            -SubscriptionId $dest_subscription `
            -DatabaseName $dest_dbName `
            -RequiredTags $requiredTags
        
        # if ($savedTags) {
        #     Write-Host "    ✅ Saved tags from $dest_dbName : $($savedTags -join ', ')`n" -ForegroundColor Green
        # }else {
        #     Write-Host "    ⚠️  No existing tags found on $dest_dbName" -ForegroundColor Yellow
        #     $global:LASTEXITCODE = 1
        #     throw "No existing tags found on $dest_dbName"
        # }

        $databasesToProcess += @{
            SourceName = $db.name
            DestinationName = $dest_dbName
            SavedTags = $savedTags
        }
    } else {
        Write-Host "    ⏭️  Skipping: Pattern mismatch`n" -ForegroundColor Yellow
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
# ELASTIC POOL STORAGE VALIDATION
# ============================================================================

if ($databasesToProcess.Count -gt 0) {
    Write-Host ""
    
    # Prepare arrays of source and Destination database names
    $SourceDatabaseNames = @()
    $DestinationDatabaseNames = @()
    
    foreach ($dbInfo in $databasesToProcess) {
        $SourceDatabaseNames += $dbInfo.SourceName
        $DestinationDatabaseNames += $dbInfo.DestinationName
    }
    
    # # Determine which server to check (source for same-server copy, Destination for cross-server copy)
    # $sameServer = ($Source_server -eq $dest_server)

    
    $storageCheckPassed = Test-ElasticPoolCapacity `
        -Server $Source_server `
        -ResourceGroup $Source_rg `
        -SubscriptionId $Source_subscription `
        -ElasticPoolName $dest_elasticpool `
        -ServerFQDN $Source_server_fqdn `
        -AccessToken $AccessToken `
        -SourceDatabases $SourceDatabaseNames `
        -DestinationDatabases $DestinationDatabaseNames `
        -IsDryRun $DryRun

    if (-not $storageCheckPassed) {
        Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Red
        Write-Host "❌ STORAGE VALIDATION FAILED" -ForegroundColor Red
        Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Red
        
        if ($DryRun) {
            Write-Host "⚠️  DRY RUN WARNING: Storage validation failed" -ForegroundColor Yellow
            Write-Host "⚠️  In production, this would abort the operation" -ForegroundColor Yellow
            Write-Host "⚠️  Continuing dry run to show remaining steps..." -ForegroundColor Yellow
            Write-Host ""
            # Track this failure for final dry run summary
            $script:DryRunHasFailures = $true
            $script:DryRunFailureReasons += "Insufficient storage capacity on Destination elastic pool"
        }
        else {
            Write-Host "🛑 ABORTING: Cannot proceed due to insufficient storage capacity" -ForegroundColor Red
            Write-Host ""
            $global:LASTEXITCODE = 1
            throw "Storage validation failed: Insufficient storage capacity on Destination elastic pool"
        }
    }
    
    Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""
}else {
    if (-not $DryRun) {
    Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Cyan
        Write-Host "❌ NO DATABASES TO PROCESS" -ForegroundColor Red
        Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Red
        Write-Host ""
        Write-Host "🔍 No databases to process" -ForegroundColor Yellow
        Write-Host ""
        $global:LASTEXITCODE = 1
        throw "No databases to process"
    }
}

# ============================================================================
# DRY RUN MODE
# ============================================================================

if ($DryRun) {
    Write-Host "🔍 DRY RUN: Operations that would be performed:" -ForegroundColor Yellow
    Write-Host ""

    foreach ($dbInfo in $databasesToProcess) {
        Write-Host "  • $($dbInfo.SourceName) → $($dbInfo.DestinationName)`n" -ForegroundColor Gray
    }
    Write-Host ""
    Write-Host "🔍 DRY RUN: No actual operations performed" -ForegroundColor Yellow
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
        -MaxWaitMinutes $MaxWaitMinutes `
        -SourceDatabaseName $dbInfo.SourceName `
        -DestinationDatabaseName $dbInfo.DestinationName `
        -SourceServer $Source_server `
        -DestServer $dest_server `
        -DestServerFQDN $dest_server_fqdn `
        -DestResourceGroup $dest_rg `
        -DestSubscriptionId $dest_subscription `
        -DestElasticPool $dest_elasticpool `
        -AccessToken $AccessToken `
        -ResourceUrl $resourceUrl `
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
        $global:LASTEXITCODE = 1
        throw "Database copy failed for $($result.Database) at phase $($result.Phase): $($result.Error)"
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
    $global:LASTEXITCODE = 1
    throw "Database copy workflow failed: $failCount out of $($results.Count) databases failed"
}

Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

# ============================================================================
# TAG VERIFICATION AND APPLICATION
# ============================================================================
# Tags are applied AFTER all database copies complete to ensure databases
# have fully stabilized and are ready to accept tag updates reliably.
# ============================================================================

Write-Host "🔍 APPLYING AND VERIFYING DATABASE TAGS" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "ℹ️  Tags are applied after all copies complete for maximum reliability" -ForegroundColor Gray
Write-Host ""

# Determine required tags based on namespace
if ($DestinationNamespace -eq "manufacturo") {
    Write-Host "  ❌ Manufacturo namespace is not supported for destination" -ForegroundColor Red
    $global:LASTEXITCODE = 1
    throw "Manufacturo namespace is not supported for destination"
    # $requiredTags = @("Environment", "Owner", "Service", "Type")
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
        
        if ($missingTags.Count -eq 0) {
            $tagVerificationResults += @{ 
                Database = $dbName
                Status = "Complete"
                MissingTags = @()
                OriginalTags = $dbInfo.SavedTags
            }
            $tagsComplete++
        } else {
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
Write-Host "⚠️ Errors: $tagsError databases" -ForegroundColor Yellow
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
        Write-Host "❌  WARNING: $reVerifyIncomplete databases still have incomplete tags" -ForegroundColor Red
        Write-Host ""
        Write-Host "💡 This may cause issues with:" -ForegroundColor Red
        Write-Host "   • Terraform state management" -ForegroundColor Gray
        Write-Host "   • Resource identification and management" -ForegroundColor Gray
        Write-Host "   • Environment-specific configurations" -ForegroundColor Gray
        Write-Host ""
        Write-Host "🔧 Please manually verify and fix tags for the affected databases" -ForegroundColor Red
        Write-Host ""
        $global:LASTEXITCODE = 1
        throw "Database tag verification failed: $reVerifyIncomplete databases still have incomplete tags"
    } else {
        Write-Host "✅ All tags successfully re-applied and verified" -ForegroundColor Green
        Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Cyan
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
