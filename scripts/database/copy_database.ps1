param (
    [Parameter(Mandatory)] [string]$source,
    [Parameter(Mandatory)] [string]$destination,
    [Parameter(Mandatory)][string]$SourceNamespace, 
    [Parameter(Mandatory)][string]$DestinationNamespace,
    [switch]$DryRun
)

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

function Test-CopyPermissions {
    param (
        [string]$SourceServer,
        [string]$SourceDatabase,
        [string]$DestServer,
        [string]$DestDatabase,
        [string]$AccessToken
    )
    
    # Check if same server
    if ($SourceServer -eq $DestServer) {
        Write-Host "  🔍 Same server operation - skipping cross-server copy test..." -ForegroundColor Gray
        return $true
    }
    
    Write-Host "  🔍 Testing cross-server copy permissions..." -ForegroundColor Gray
    
    try {
        # Test if we can query the source database
        $sourceQuery = "SELECT COUNT(*) as table_count FROM sys.tables"
        $sourceResult = Invoke-Sqlcmd -AccessToken $AccessToken -ServerInstance $SourceServer -Database $SourceDatabase -Query $sourceQuery -ConnectionTimeout 15 -QueryTimeout 30
        
        if (-not $sourceResult) {
            Write-Host "    ❌ Cannot access source database $SourceDatabase" -ForegroundColor Red
            return $false
        }
        
        Write-Host "    ✅ Source database access confirmed" -ForegroundColor Green
        
        # Test if we can create a test database (simulate copy operation)
        $testDbName = "test_copy_permissions_$(Get-Random)"
        $createTestQuery = "CREATE DATABASE [$testDbName]"
        
        try {
            Invoke-Sqlcmd -AccessToken $AccessToken -ServerInstance $DestServer -Query $createTestQuery -ConnectionTimeout 15 -QueryTimeout 30
            Write-Host "    ✅ Database creation test successful" -ForegroundColor Green
            
            # Clean up test database
            $dropTestQuery = "DROP DATABASE [$testDbName]"
            Invoke-Sqlcmd -AccessToken $AccessToken -ServerInstance $DestServer -Query $dropTestQuery -ConnectionTimeout 15 -QueryTimeout 30
            Write-Host "    ✅ Test database cleaned up" -ForegroundColor Green
            
            return $true
            
        } catch {
            Write-Host "    ❌ Database creation test failed: $($_.Exception.Message)" -ForegroundColor Red
            return $false
        }
        
    } catch {
        Write-Host "    ❌ Copy permission test failed: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}


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


# Display summary
Write-Host "📋 COPY SUMMARY" -ForegroundColor Cyan
Write-Host "===============" -ForegroundColor Cyan
# Write-Host "Source Subscription: $source_subscription ($source_lower)" -ForegroundColor Yellow
# Write-Host "Destination Subscription: $dest_subscription ($destination_lower)" -ForegroundColor Yellow
Write-Host "Destination SQL Server: $dest_server_fqdn" -ForegroundColor Yellow
Write-Host "Elastic Pool: $dest_elasticpool" -ForegroundColor Yellow
Write-Host ""

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

# Get DBs to copy
$dbs = az sql db list --subscription $source_subscription --resource-group $source_rg --server $source_server | ConvertFrom-Json

if (-not $dbs) {
    Write-Host "❌ No databases found on source server." -ForegroundColor Red
    exit 1
}

# Pre-flight permission validation (runs in both dry-run and normal mode)
Write-Host "🔍 PRE-FLIGHT PERMISSION VALIDATION" -ForegroundColor Cyan
Write-Host "====================================" -ForegroundColor Cyan

# Check if source and destination are the same server
$sameServer = ($source_server -eq $dest_server)
if ($sameServer) {
    Write-Host "🔍 Same server detected: $source_server" -ForegroundColor Gray
    Write-Host "   • No cross-server copy needed" -ForegroundColor Gray
    Write-Host "   • No backup needed (databases will be moved, not copied)" -ForegroundColor Gray
}

# Test server permissions (only need to test once if same server)
if ($sameServer) {
    Write-Host "🔍 Testing server permissions..." -ForegroundColor Gray
    $serverPermissionsOK = Test-DatabasePermissions -ServerFQDN $source_server_fqdn -AccessToken $AccessToken
    if (-not $serverPermissionsOK) {
        Write-Host "❌ Server permission validation failed" -ForegroundColor Red
        Write-Host "💡 Please ensure you have sufficient permissions on server: $source_server_fqdn" -ForegroundColor Yellow
        exit 1
    }
} else {
    # Test source server permissions
    Write-Host "🔍 Testing source server permissions..." -ForegroundColor Gray
    $sourcePermissionsOK = Test-DatabasePermissions -ServerFQDN $source_server_fqdn -AccessToken $AccessToken
    if (-not $sourcePermissionsOK) {
        Write-Host "❌ Source server permission validation failed" -ForegroundColor Red
        Write-Host "💡 Please ensure you have sufficient permissions on source server: $source_server_fqdn" -ForegroundColor Yellow
        exit 1
    }

    # Test destination server permissions
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

if ($DryRun) {
    Write-Host "`n🔍 DRY RUN MODE - Database Copy Preview" -ForegroundColor Yellow
    Write-Host "=======================================" -ForegroundColor Yellow
    
    Write-Host "🔍 Found $($dbs.Count) databases to analyze" -ForegroundColor Gray
    Write-Host "🔍 Database name matching pattern: $source_product-$source_type-{service}-$source_environment-$source_location" -ForegroundColor Gray
    Write-Host "🔍 Source multitenant: '$SourceNamespace', Destination multitenant: '$DestinationNamespace'" -ForegroundColor Gray
    
    # Show what databases would be copied
    $databasesToCopy = @()
    foreach ($db in $dbs) {
        # For restored databases, get service from the corresponding source database
        if ($db.name.Contains("restored")) {
            $sourceDbName = $db.name -replace "-restored$", ""
            $sourceDb = $dbs | Where-Object { $_.name -eq $sourceDbName }
            if ($sourceDb) {
                $service = $sourceDb.tags.Service
            } else {
                $service = ""
            }
        } else {
            # For regular databases, use the service tag
            $service = $db.tags.Service
        }
        
        Write-Host "  📋 Analyzing database: $($db.name) (Service: $service)" -ForegroundColor Gray
        
        # Skip system databases, landlord service, and non-restored databases
        # if ($db.name.Contains("master") -or $service -eq "landlord" -or -not $db.name.Contains("restored")) {
        if ($db.name.Contains("master") -or $service -eq "landlord") {
            if ($db.name.Contains("master")) {
                Write-Host "    ⏭️  Skipping system database: $($db.name)" -ForegroundColor Yellow
            } elseif ($service -eq "landlord") {
                Write-Host "    ⏭️  Skipping landlord service: $($db.name)" -ForegroundColor Yellow
            } else {
                Write-Host "    ⏭️  Skipping non-restored database: $($db.name)" -ForegroundColor Yellow
            }
            continue
        }
        
        # Use the -restored database directly as source
        $sourceDBName = "$($db.name)"
        
        # Get the source database name without -restored for destination name creation
        $sourceDbNameForDest = $db.name -replace "-restored$", ""
        
        # Determine destination name based on namespace settings
        if ($SourceNamespace -eq "manufacturo") {
            $expectedPattern = "$source_product-$source_type-$service-$source_environment-$source_location"
            Write-Host "    🔍 Checking manufacturo pattern: $expectedPattern" -ForegroundColor Gray
            if ($sourceDbNameForDest.Contains("$source_product-$source_type-$service-$source_environment-$source_location"))  {
                Write-Host "    ✅ Database matches manufacturo pattern!" -ForegroundColor Green
                if ($DestinationNamespace -eq "manufacturo") {
                    $dest_dbName = $sourceDbNameForDest `
                        -replace [regex]::Escape($source_environment), $dest_environment `
                        -replace [regex]::Escape($source_location), $dest_location `
                        -replace [regex]::Escape($source_type), $dest_type
                } else {
                    $dest_dbName = $sourceDbNameForDest `
                        -replace [regex]::Escape($source_environment), "$DestinationNamespace-$dest_environment" `
                        -replace [regex]::Escape($source_location), $dest_location `
                        -replace [regex]::Escape($source_type), $dest_type
                }
                $databasesToCopy += @{ Source = $sourceDBName; Destination = $dest_dbName }
            } else {
                Write-Host "    ⏭️  Database does not match manufacturo pattern, skipping" -ForegroundColor Yellow
            }
        } else {
            $expectedPattern = "$source_product-$source_type-$service-$SourceNamespace-$source_environment-$source_location"
            Write-Host "    🔍 Checking namespace pattern: $expectedPattern" -ForegroundColor Gray
            if ($sourceDbNameForDest.Contains("$source_product-$source_type-$service-$SourceNamespace-$source_environment-$source_location"))  {
                Write-Host "    ✅ Database matches namespace pattern!" -ForegroundColor Green
                if ($DestinationNamespace -eq "manufacturo") {
                    $dest_dbName = $sourceDbNameForDest `
                        -replace [regex]::Escape("$SourceNamespace-$source_environment"), $dest_environment `
                        -replace [regex]::Escape($source_location), $dest_location `
                        -replace [regex]::Escape($source_type), $dest_type
                } else {
                    $dest_dbName = $sourceDbNameForDest `
                        -replace [regex]::Escape("$SourceNamespace-$source_environment"), "$DestinationNamespace-$dest_environment" `
                        -replace [regex]::Escape($source_location), $dest_location `
                        -replace [regex]::Escape($source_type), $dest_type
                }
                $databasesToCopy += @{ Source = $sourceDBName; Destination = $dest_dbName }
            } else {
                Write-Host "    ⏭️  Database does not match namespace pattern, skipping" -ForegroundColor Yellow
            }
        }
    }
    
    Write-Host "🔍 DRY RUN: Found $($dbs.Count) databases on source server" -ForegroundColor Cyan
    Write-Host "🔍 DRY RUN: Would copy $($databasesToCopy.Count) databases:" -ForegroundColor Yellow
    foreach ($db in $databasesToCopy) {
        Write-Host "  • $($db.Source) -> $($db.Destination)" -ForegroundColor Gray
    }
    Write-Host "🔍 DRY RUN: Would skip $($dbs.Count - $databasesToCopy.Count) databases (system/landlord/pattern mismatch)" -ForegroundColor Yellow
    Write-Host "🔍 DRY RUN: Would preserve and restore tags from destination databases" -ForegroundColor Yellow
    Write-Host "🔍 DRY RUN: Would fix user logins on copied databases" -ForegroundColor Yellow
    
    # Test tag preservation logic in dry run
    Write-Host "`n🔍 DRY RUN: Testing tag preservation logic..." -ForegroundColor Yellow
    $tagTestResults = @()
    
    foreach ($db in $databasesToCopy) {
        $destDbName = $db.Destination
        Write-Host "  🏷️  Testing tags for: $destDbName" -ForegroundColor Gray
        
        try {
            # Try to get existing tags from destination database
            $existingTags = az sql db show --subscription $dest_subscription --resource-group $dest_rg --server $dest_server --name $destDbName --query "tags" -o json 2>$null | ConvertFrom-Json
            
            if ($existingTags -and $existingTags.PSObject.Properties.Count -gt 0) {
                $tagList = @()
                foreach ($tag in $existingTags.PSObject.Properties) {
                    $tagList += "$($tag.Name)=$($tag.Value)"
                }
                Write-Host "    ✅ Found existing tags: $($tagList -join ', ')" -ForegroundColor Green
                $tagTestResults += @{ Database = $destDbName; Status = "has_tags"; Tags = $tagList -join ', ' }
            } else {
                Write-Host "    ⚠️  No existing tags found (database may not exist yet)" -ForegroundColor Yellow
                $tagTestResults += @{ Database = $destDbName; Status = "no_tags"; Tags = "none" }
            }
        } catch {
            Write-Host "    ⚠️  Could not retrieve tags: $($_.Exception.Message)" -ForegroundColor Yellow
            $tagTestResults += @{ Database = $destDbName; Status = "error"; Tags = "error" }
        }
    }
    
    Write-Host "`n🔍 DRY RUN: Tag preservation test summary:" -ForegroundColor Yellow
    $hasTags = $tagTestResults | Where-Object { $_.Status -eq "has_tags" }
    $noTags = $tagTestResults | Where-Object { $_.Status -eq "no_tags" }
    $errors = $tagTestResults | Where-Object { $_.Status -eq "error" }
    
    if ($hasTags.Count -gt 0) {
        Write-Host "  ✅ $($hasTags.Count) databases have existing tags that will be preserved" -ForegroundColor Green
    }
    if ($noTags.Count -gt 0) {
        Write-Host "  ⚠️  $($noTags.Count) databases have no existing tags" -ForegroundColor Yellow
    }
    if ($errors.Count -gt 0) {
        Write-Host "  ❌ $($errors.Count) databases had errors retrieving tags" -ForegroundColor Red
    }
    
    Write-Host "`n🔍 DRY RUN: Database copy preview completed." -ForegroundColor Yellow
    exit 0
}

# Global variable to store database configurations for tag preservation
$script:DatabaseConfigurations = @()

# Global variable to track failed operations for rollback
$script:FailedOperations = @()

function Save-DatabaseConfiguration {
    param (
        [string]$DestServer,
        [string]$DestResourceGroup,
        [string]$DestSubscriptionId,
        [string]$DestDatabaseName
    )
    
    # Get existing tags from destination database before deletion
    try {
        Write-Host "  🔍 Checking for existing tags on destination database: $DestDatabaseName" -ForegroundColor Gray
        $existingDb = az sql db show --subscription $DestSubscriptionId --resource-group $DestResourceGroup --server $DestServer --name $DestDatabaseName --query "tags" -o json 2>$null | ConvertFrom-Json
        
        if ($existingDb -and $existingDb.PSObject.Properties.Count -gt 0) {
            # Write-Host "  ✅ Found $($existingDb.PSObject.Properties.Count) tags on destination database" -ForegroundColor Green
            $tagList = @()
            foreach ($tag in $existingDb.PSObject.Properties) {
                $tagList += "$($tag.Name)=$($tag.Value)"
            }
            Write-Host "  📋 Destination Tags: $($tagList -join ', ')" -ForegroundColor Gray
        } else {
            Write-Host "  ⚠️  No tags found on destination database $DestDatabaseName" -ForegroundColor Yellow
        }
        
        $config = @{
            DestDatabaseName = $DestDatabaseName
            DestServer = $DestServer
            DestResourceGroup = $DestResourceGroup
            DestSubscriptionId = $DestSubscriptionId
            Tags = $existingDb
        }
        
        $script:DatabaseConfigurations += $config
    }
    catch {
        Write-Host "  ❌ Error retrieving tags for destination database $DestDatabaseName : $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Apply-DatabaseTags {
    param (
        [object]$Config
    )
    
    if (-not $Config.Tags -or $Config.Tags.PSObject.Properties.Count -eq 0) {
        Write-Host "    (no tags to restore)" -ForegroundColor Gray
        return
    }
    
    $tagList = @()
    
    try {
        foreach ($tag in $Config.Tags.PSObject.Properties) {
            $tagList += "$($tag.Name)=$($tag.Value)"
            
            # Apply each tag individually to avoid concatenation issues
            $null = az sql db update `
                --subscription $Config.DestSubscriptionId `
                --resource-group $Config.DestResourceGroup `
                --server $Config.DestServer `
                --name $Config.DestDatabaseName `
                --set "tags.$($tag.Name)=$($tag.Value)" `
                --output none 2>$null
        }
            
        Write-Host "    Tags: $($tagList -join ', ')" -ForegroundColor Gray
    }
    catch {
        Write-Host "    ⚠️  Warning: Failed to apply tags: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

Write-Host "🔍 Found $($dbs.Count) databases on source server" -ForegroundColor Cyan
Write-Host ""

# First pass: Save configurations for all databases that will be copied
Write-Host "📋 Analyzing databases and saving configurations for tag preservation..." -ForegroundColor Cyan

$skippedCount = 0
$processedCount = 0

foreach ($db in $dbs) {
    # For restored databases, get service from the corresponding source database
    if ($db.name.Contains("restored")) {
        $sourceDbName = $db.name -replace "-restored$", ""
        $sourceDb = $dbs | Where-Object { $_.name -eq $sourceDbName }
        if ($sourceDb) {
            $service = $sourceDb.tags.Service
        } else {
            $service = ""
        }
    } else {
        # For regular databases, use the service tag
        $service = $db.tags.Service
    }
    
    # Skip system databases, landlord service, and non-restored databases
    if ($db.name.Contains("master") -or $service -eq "landlord" -or -not $db.name.Contains("restored")) {
        $skippedCount++
        if ($db.name.Contains("master")) {
            Write-Host "  ⏭️  Skipping system database: $($db.name)" -ForegroundColor Gray
        } elseif ($service -eq "landlord") {
            Write-Host "  ⏭️  Skipping landlord service: $($db.name)" -ForegroundColor Gray
        } else {
            Write-Host "  ⏭️  Skipping non-restored database: $($db.name)" -ForegroundColor Gray
        }
        continue
    }

    # Use the -restored database directly as source
    $sourceDBName = "$($db.name)"
    
    # Get the source database name without -restored for destination name creation
    $sourceDbNameForDest = $db.name -replace "-restored$", ""

    # Determine destination database name based on namespace settings
    $dest_dbName = $null
    
    if ($SourceNamespace -eq "manufacturo") {
        if ($sourceDbNameForDest.Contains("$source_product-$source_type-$service-$source_environment-$source_location")) {
            if ($DestinationNamespace -eq "manufacturo") {
                $dest_dbName = $sourceDbNameForDest `
                    -replace [regex]::Escape($source_environment), $dest_environment `
                    -replace [regex]::Escape($source_location), $dest_location `
                    -replace [regex]::Escape($source_type), $dest_type
            } else {
                $dest_dbName = $sourceDbNameForDest `
                    -replace [regex]::Escape($source_environment), "$DestinationNamespace-$dest_environment" `
                    -replace [regex]::Escape($source_location), $dest_location `
                    -replace [regex]::Escape($source_type), $dest_type
            }
        }
    } else {
        if ($sourceDbNameForDest.Contains("$source_product-$source_type-$service-$SourceNamespace-$source_environment-$source_location")) {
            if ($DestinationNamespace -eq "manufacturo") {
                $dest_dbName = $sourceDbNameForDest `
                    -replace [regex]::Escape("$SourceNamespace-$source_environment"), $dest_environment `
                    -replace [regex]::Escape($source_location), $dest_location `
                    -replace [regex]::Escape($source_type), $dest_type
            } else {
                $dest_dbName = $sourceDbNameForDest `
                    -replace [regex]::Escape("$SourceNamespace-$source_environment"), "$DestinationNamespace-$dest_environment" `
                    -replace [regex]::Escape($source_location), $dest_location `
                    -replace [regex]::Escape($source_type), $dest_type
            }
        }
    }
    
    # Save configuration if destination name was determined
    if (-not [string]::IsNullOrWhiteSpace($dest_dbName)) {
        $processedCount++
        Write-Host "  ✅ Will copy: $($db.name) -> $dest_dbName" -ForegroundColor Green
        Save-DatabaseConfiguration -DestServer $dest_server -DestResourceGroup $dest_rg -DestSubscriptionId $dest_subscription -DestDatabaseName $dest_dbName
    } else {
        $skippedCount++
        Write-Host "  ⏭️  Skipping (pattern mismatch): $($db.name)" -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host "📊 Database Analysis Summary:" -ForegroundColor Cyan
Write-Host "  • Total databases found: $($dbs.Count)" -ForegroundColor White
Write-Host "  • Databases to copy: $processedCount" -ForegroundColor Green
Write-Host "  • Databases skipped: $skippedCount" -ForegroundColor Yellow
Write-Host ""
Write-Host ""

# Parallel copy process
Write-Host "🔍 DEBUG: Starting parallel copy process with ThrottleLimit 5" -ForegroundColor Magenta
Write-Host "🔍 DEBUG: Total databases to process: $($dbs.Count)" -ForegroundColor Magenta

$copy_results = $dbs | ForEach-Object -ThrottleLimit 5 -Parallel {
    Write-Host "🔍 DEBUG: Starting parallel processing for database: $($_.name)" -ForegroundColor Magenta
    
    # Define Test-DatabasePermissions function within parallel block
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

    function Test-CopyPermissions {
        param (
            [string]$SourceServer,
            [string]$SourceDatabase,
            [string]$DestServer,
            [string]$DestDatabase,
            [string]$AccessToken
        )
        
        # Check if same server
        if ($SourceServer -eq $DestServer) {
            Write-Host "  🔍 Same server operation - skipping cross-server copy test..." -ForegroundColor Gray
            return $true
        }
        
        Write-Host "  🔍 Testing cross-server copy permissions..." -ForegroundColor Gray
        
        try {
            # Test if we can query the source database
            $sourceQuery = "SELECT COUNT(*) as table_count FROM sys.tables"
            $sourceResult = Invoke-Sqlcmd -AccessToken $AccessToken -ServerInstance $SourceServer -Database $SourceDatabase -Query $sourceQuery -ConnectionTimeout 15 -QueryTimeout 30
            
            if (-not $sourceResult) {
                Write-Host "    ❌ Cannot access source database $SourceDatabase" -ForegroundColor Red
                return $false
            }
            
            Write-Host "    ✅ Source database access confirmed" -ForegroundColor Green
            
            # Test if we can create a test database (simulate copy operation)
            $testDbName = "test_copy_permissions_$(Get-Random)"
            $createTestQuery = "CREATE DATABASE [$testDbName]"
            
            try {
                Invoke-Sqlcmd -AccessToken $AccessToken -ServerInstance $DestServer -Query $createTestQuery -ConnectionTimeout 15 -QueryTimeout 30
                Write-Host "    ✅ Database creation test successful" -ForegroundColor Green
                
                # Clean up test database
                $dropTestQuery = "DROP DATABASE [$testDbName]"
                Invoke-Sqlcmd -AccessToken $AccessToken -ServerInstance $DestServer -Query $dropTestQuery -ConnectionTimeout 15 -QueryTimeout 30
                Write-Host "    ✅ Test database cleaned up" -ForegroundColor Green
                
                return $true
                
            } catch {
                Write-Host "    ❌ Database creation test failed: $($_.Exception.Message)" -ForegroundColor Red
                return $false
            }
            
        } catch {
            Write-Host "    ❌ Copy permission test failed: $($_.Exception.Message)" -ForegroundColor Red
            return $false
        }
    }
    
    $source_environment = $using:source_lower
    $source_server = $using:source_server
    $dest_environment = $using:destination_lower
    $dest_subscription = $using:dest_subscription
    $dest_server = $using:dest_server
    $dest_rg = $using:dest_rg
    $dest_elasticpool = $using:dest_elasticpool
    $dest_server_full = $using:dest_server_fqdn
    $source_server_full = $using:source_server_fqdn
    $AccessToken = $using:AccessToken
    $SourceNamespace = $using:sourceNamespace
    $DestinationNamespace = $using:destinationNamespace
    $source_location = $using:source_location
    $source_type = $using:source_type
    $dest_location = $using:dest_location
    $dest_type = $using:dest_type
    $source_product = $using:source_product
    
    Write-Host "🔍 DEBUG: Loaded variables for $($_.name) - SourceNamespace: $SourceNamespace, DestinationNamespace: $DestinationNamespace" -ForegroundColor Magenta
    
    # For restored databases, get service from the corresponding source database
    if ($_.name.Contains("restored")) {
        $sourceDbName = $_.name -replace "-restored$", ""
        $sourceDb = $using:dbs | Where-Object { $_.name -eq $sourceDbName }
        if ($sourceDb) {
            $service = $sourceDb.tags.Service
        } else {
            $service = ""
        }
    } else {
        # For regular databases, use the service tag
        $service = $_.tags.Service
    }
    
    # Skip system databases, landlord service, and non-restored databases
    if ($_.name.Contains("master") -or $service -eq "landlord" -or -not $_.name.Contains("restored")) {
        return
    }

    # Use the -restored database directly as source
    $sourceDBName = "$($_.name)"
    
    # Get the source database name without -restored for destination name creation
    $sourceDbNameForDest = $_.name -replace "-restored$", ""

    # Determine destination database name based on namespace settings
    $dest_dbName = $null
    
    if ($SourceNamespace -eq "manufacturo") {
        if ($sourceDbNameForDest.Contains("$source_product-$source_type-$service-$source_environment-$source_location")) {
            if ($DestinationNamespace -eq "manufacturo") {
                $dest_dbName = $sourceDbNameForDest `
                    -replace [regex]::Escape($source_environment), $dest_environment `
                    -replace [regex]::Escape($source_location), $dest_location `
                    -replace [regex]::Escape($source_type), $dest_type
            } else {
                $dest_dbName = $sourceDbNameForDest `
                    -replace [regex]::Escape($source_environment), "$DestinationNamespace-$dest_environment" `
                    -replace [regex]::Escape($source_location), $dest_location `
                    -replace [regex]::Escape($source_type), $dest_type
            }
        }
    } else {
        if ($sourceDbNameForDest.Contains("$source_product-$source_type-$service-$SourceNamespace-$source_environment-$source_location")) {
            if ($DestinationNamespace -eq "manufacturo") {
                $dest_dbName = $sourceDbNameForDest `
                    -replace [regex]::Escape("$SourceNamespace-$source_environment"), $dest_environment `
                    -replace [regex]::Escape($source_location), $dest_location `
                    -replace [regex]::Escape($source_type), $dest_type
            } else {
                $dest_dbName = $sourceDbNameForDest `
                    -replace [regex]::Escape("$SourceNamespace-$source_environment"), "$DestinationNamespace-$dest_environment" `
                    -replace [regex]::Escape($source_location), $dest_location `
                    -replace [regex]::Escape($source_type), $dest_type
            }
        }
    }
    
    # Skip if no destination name was determined
    if ([string]::IsNullOrWhiteSpace($dest_dbName)) {
        return
    }

    Write-Host "📋 Copying from $sourceDBName to $dest_dbName" -ForegroundColor Cyan

    # Debug: Check all variables before SQL execution
    Write-Host "🔍 DEBUG: SQL Command Variables:" -ForegroundColor Magenta
    Write-Host "  • dest_dbName: '$dest_dbName'" -ForegroundColor Gray
    Write-Host "  • source_server: '$source_server'" -ForegroundColor Gray
    Write-Host "  • sourceDBName: '$sourceDBName'" -ForegroundColor Gray
    Write-Host "  • dest_elasticpool: '$dest_elasticpool'" -ForegroundColor Gray
    Write-Host "  • dest_server_full: '$dest_server_full'" -ForegroundColor Gray
    Write-Host "  • AccessToken length: $($AccessToken.Length)" -ForegroundColor Gray

    # Validate all required variables
    if ([string]::IsNullOrWhiteSpace($dest_dbName)) {
        Write-Host "❌ ERROR: dest_dbName is empty or null" -ForegroundColor Red
        return @{ db = "unknown"; status = "failed"; error = "dest_dbName is empty" }
    }
    if ([string]::IsNullOrWhiteSpace($source_server)) {
        Write-Host "❌ ERROR: source_server is empty or null" -ForegroundColor Red
        return @{ db = $dest_dbName; status = "failed"; error = "source_server is empty" }
    }
    if ([string]::IsNullOrWhiteSpace($sourceDBName)) {
        Write-Host "❌ ERROR: sourceDBName is empty or null" -ForegroundColor Red
        return @{ db = $dest_dbName; status = "failed"; error = "sourceDBName is empty" }
    }
    if ([string]::IsNullOrWhiteSpace($dest_elasticpool)) {
        Write-Host "❌ ERROR: dest_elasticpool is empty or null" -ForegroundColor Red
        return @{ db = $dest_dbName; status = "failed"; error = "dest_elasticpool is empty" }
    }
    if ([string]::IsNullOrWhiteSpace($dest_server_full)) {
        Write-Host "❌ ERROR: dest_server_full is empty or null" -ForegroundColor Red
        return @{ db = $dest_dbName; status = "failed"; error = "dest_server_full is empty" }
    }
    if ([string]::IsNullOrWhiteSpace($AccessToken)) {
        Write-Host "❌ ERROR: AccessToken is empty or null" -ForegroundColor Red
        return @{ db = $dest_dbName; status = "failed"; error = "AccessToken is empty" }
    }

    # Pre-copy permission validation
    Write-Host "🔍 Validating permissions before copy operation..." -ForegroundColor Cyan
    
    # Check if same server
    $sameServer = ($source_server -eq $dest_server)
    
    if ($sameServer) {
        # Same server - just test basic permissions
        Write-Host "  🔍 Same server operation - testing basic permissions..." -ForegroundColor Gray
        $serverPermissionsOK = Test-DatabasePermissions -ServerFQDN $dest_server_full -AccessToken $AccessToken
        if (-not $serverPermissionsOK) {
            Write-Host "❌ Server permission validation failed for $dest_dbName" -ForegroundColor Red
            return @{ db = $dest_dbName; status = "failed"; error = "Insufficient permissions on server" }
        }
        Write-Host "  ✅ Same server permissions validated for $dest_dbName" -ForegroundColor Green
    } else {
        # Different servers - test both and cross-server copy
        $destPermissionsOK = Test-DatabasePermissions -ServerFQDN $dest_server_full -AccessToken $AccessToken
        if (-not $destPermissionsOK) {
            Write-Host "❌ Destination server permission validation failed for $dest_dbName" -ForegroundColor Red
            return @{ db = $dest_dbName; status = "failed"; error = "Insufficient permissions on destination server" }
        }
        
        $sourcePermissionsOK = Test-DatabasePermissions -ServerFQDN $source_server_full -AccessToken $AccessToken
        if (-not $sourcePermissionsOK) {
            Write-Host "❌ Source server permission validation failed for $sourceDBName" -ForegroundColor Red
            return @{ db = $dest_dbName; status = "failed"; error = "Insufficient permissions on source server" }
        }
        
        # Test cross-server copy permissions
        $copyPermissionsOK = Test-CopyPermissions -SourceServer $source_server_full -SourceDatabase $sourceDBName -DestServer $dest_server_full -DestDatabase $dest_dbName -AccessToken $AccessToken
        if (-not $copyPermissionsOK) {
            Write-Host "❌ Cross-server copy permission validation failed for $dest_dbName" -ForegroundColor Red
            return @{ db = $dest_dbName; status = "failed"; error = "Insufficient permissions for cross-server copy operation" }
        }
        Write-Host "✅ All cross-server permission validations passed for $dest_dbName" -ForegroundColor Green
    }

    Write-Host "🗑️  Deleting $dest_dbName in $dest_server" -ForegroundColor Red

    # Delete existing destination DB
    try {
        $deleteResult = az sql db delete --name $dest_dbName --resource-group $dest_rg --server $dest_server --subscription $dest_subscription --yes --only-show-errors 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Host "⚠️  Warning: Failed to delete existing database ${dest_dbName} (may not exist): $deleteResult" -ForegroundColor Yellow
        }
        Start-Sleep 10
    } catch {
        Write-Host "⚠️  Warning: Error during database deletion: $($_.Exception.Message)" -ForegroundColor Yellow
    }
    
    # Build the SQL command with proper escaping
    $sqlCommand = "CREATE DATABASE [$dest_dbName] AS COPY OF [$source_server].[$sourceDBName] (SERVICE_OBJECTIVE = ELASTIC_POOL(name = [$dest_elasticpool]));"
    Write-Host "🔍 DEBUG: SQL Command: $sqlCommand" -ForegroundColor Magenta

    # Retry logic for connection pool issues
    $maxRetries = 3
    $retryDelay = 5
    
    try {
        for ($retry = 1; $retry -le $maxRetries; $retry++) {
            try {
                # Write-Host "🔍 DEBUG: Attempt $retry of $maxRetries to execute SQL command" -ForegroundColor Magenta
                
                # Clear any existing connections before retry
                if ($retry -gt 1) {
                    Write-Host "🔍 DEBUG: Clearing connection pool before retry $retry" -ForegroundColor Magenta
                    Start-Sleep -Seconds $retryDelay
                }
                
                Invoke-Sqlcmd -AccessToken $AccessToken -ServerInstance $dest_server_full -Query $sqlCommand -ConnectionTimeout 30 -QueryTimeout 300
                Write-Host "✅ SQL command executed successfully on attempt $retry" -ForegroundColor Green
                Start-Sleep -Seconds 10
                break  # Success, exit retry loop
                
            } catch {
                Write-Host "❌ Attempt $retry failed: $($_.Exception.Message)" -ForegroundColor Red
                
                if ($retry -eq $maxRetries) {
                    # Final attempt failed, re-throw the exception
                    throw
                } else {
                    Write-Host "🔄 Retrying in $retryDelay seconds..." -ForegroundColor Yellow
                    Start-Sleep -Seconds $retryDelay
                    $retryDelay = $retryDelay * 2  # Exponential backoff
                }
            }
        }

    } catch {
        Write-Host "❌ Error copying database $sourceDBName to $dest_dbName" -ForegroundColor Red
        Write-Host "Exception Message: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "Stack Trace: $($_.ScriptStackTrace)" -ForegroundColor Red
        return @{ db = $dest_dbName; status = "failed"; error = $_.Exception.Message }
    }

    # Wait for DB to be online
    $start_time = Get-Date
    $max_wait_minutes = 15
    $max_iterations = $max_wait_minutes * 2  # 30 seconds per iteration
    
    for ($i = 1; $i -le $max_iterations; $i++) {
        $elapsed = (Get-Date) - $start_time
        $elapsed_minutes = [math]::Round($elapsed.TotalMinutes, 1)
        
        # Check if we've exceeded the max wait time
        if ($elapsed_minutes -ge $max_wait_minutes) {
            Write-Host "❌ $dest_dbName failed to copy within ${max_wait_minutes} minutes" -ForegroundColor Red
            return @{ db = $dest_dbName; status = "failed"; elapsed = $max_wait_minutes }
        }
        
        try {
            # # Debug: Show connection attempt details
            # Write-Host "🔍 DEBUG: Checking database status for '$dest_dbName' on '$dest_server_full'" -ForegroundColor Magenta
            
            $statusQuery = "SELECT state_desc FROM sys.databases WHERE name = '$dest_dbName'"
            # Write-Host "🔍 DEBUG: Status Query: $statusQuery" -ForegroundColor Magenta
            
            $result = Invoke-Sqlcmd -AccessToken $AccessToken -ServerInstance $dest_server_full -Query $statusQuery -ConnectionTimeout 15 -QueryTimeout 30
            if ($result.state_desc -eq "ONLINE") {
                Write-Host "✅ Database $dest_dbName is ONLINE (${elapsed_minutes}min)" -ForegroundColor Green
                
                return @{ db = $dest_dbName; status = "copied"; elapsed = $elapsed_minutes }
            } else {
                # Show progress every 2 minutes
                if ($i % 4 -eq 0) {
                    Write-Host "⏳ $dest_dbName still copying... (${elapsed_minutes}min elapsed)" -ForegroundColor Yellow
                }
                Start-Sleep -Seconds 30
            }
        } catch {
            # Show progress every 2 minutes even if query fails
            if ($i % 4 -eq 0) {
                Write-Host "⏳ $dest_dbName still copying... (${elapsed_minutes}min elapsed)" -ForegroundColor Yellow
            }
            Start-Sleep -Seconds 30
        }
    }

    # If we reach here, we've exhausted all iterations without success
    $final_elapsed = (Get-Date) - $start_time
    $final_elapsed_minutes = [math]::Round($final_elapsed.TotalMinutes, 1)
    Write-Host "❌ $dest_dbName failed to copy within ${max_wait_minutes} minutes (${final_elapsed_minutes}min elapsed)" -ForegroundColor Red
    return @{ db = $dest_dbName; status = "failed"; elapsed = $final_elapsed_minutes }
}

# Check results and provide summary
Write-Host "`n📊 COPY SUMMARY" -ForegroundColor Cyan
Write-Host "===============" -ForegroundColor Cyan

$successful = $copy_results | Where-Object { $_.status -eq "copied" }
$failed = $copy_results | Where-Object { $_.status -eq "failed" }

if ($successful.Count -gt 0) {
  Write-Host "✅ Successfully copied databases:" -ForegroundColor Green
  $successful | ForEach-Object { 
    Write-Host "   • $($_.db)" -ForegroundColor Green 
  }
}

if ($failed.Count -gt 0) {
  Write-Host "`n❌ Failed to copy databases:" -ForegroundColor Red
  $failed | ForEach-Object { 
    Write-Host "   • $($_.db)" -ForegroundColor Red 
    if ($_.error) {
      Write-Host "     Error: $($_.error)" -ForegroundColor Red
    }
  }
  
  # Check if any databases were deleted but copy failed
  Write-Host "`n🔍 Checking for orphaned databases (deleted but copy failed)..." -ForegroundColor Yellow
  $orphanedDbs = @()
  
  foreach ($failedDb in $failed) {
    try {
      $dbExists = az sql db show --name $failedDb.db --resource-group $dest_rg --server $dest_server --subscription $dest_subscription --query "name" -o tsv 2>$null
      if (-not $dbExists) {
        $orphanedDbs += $failedDb.db
        Write-Host "   ⚠️  Database $($failedDb.db) was deleted but copy failed - database is lost" -ForegroundColor Red
      }
    } catch {
      # Database doesn't exist, which means it was deleted
      $orphanedDbs += $failedDb.db
      Write-Host "   ⚠️  Database $($failedDb.db) was deleted but copy failed - database is lost" -ForegroundColor Red
    }
  }
  
  if ($orphanedDbs.Count -gt 0) {
    Write-Host "`n🚨 CRITICAL: $($orphanedDbs.Count) databases were deleted but copy failed!" -ForegroundColor Red
    Write-Host "   These databases are now lost and need to be restored from backup:" -ForegroundColor Red
    $orphanedDbs | ForEach-Object { Write-Host "     • $_" -ForegroundColor Red }
    Write-Host "`n💡 RECOMMENDED ACTIONS:" -ForegroundColor Yellow
    Write-Host "   1. Check if backups exist for these databases" -ForegroundColor Gray
    Write-Host "   2. Restore from backup if available" -ForegroundColor Gray
    Write-Host "   3. Consider implementing proper backup before deletion" -ForegroundColor Gray
    Write-Host "   4. Review and fix permission issues before retrying" -ForegroundColor Gray
  }
  
  Write-Host "`n💡 Some databases failed to copy. Please check manually." -ForegroundColor Yellow
  exit 1
}

Write-Host "`n🎉 All databases copied successfully!" -ForegroundColor Green

# Apply tags to all successfully copied databases in parallel
if ($script:DatabaseConfigurations.Count -gt 0) {
    Write-Host "`n🏷️  Restoring tags to copied databases in parallel..." -ForegroundColor Cyan
    
    # Filter configurations for successfully copied databases
    $configsToProcess = $script:DatabaseConfigurations | Where-Object { 
        $config = $_
        $successful | Where-Object { $_.db -eq $config.DestDatabaseName }
    }
    
    if ($configsToProcess.Count -gt 0) {
        $configsToProcess | ForEach-Object -ThrottleLimit 5 -Parallel {
            $config = $_
            
            function Apply-DatabaseTags {
                param (
                    [object]$Config
                )
                
                if (-not $Config.Tags -or $Config.Tags.PSObject.Properties.Count -eq 0) {
                    Write-Host "    (no tags to restore)" -ForegroundColor Gray
                    return
                }
                
                $tagList = @()
                
                try {
                    foreach ($tag in $Config.Tags.PSObject.Properties) {
                        $tagList += "$($tag.Name)=$($tag.Value)"
                        
                        # Apply each tag individually to avoid concatenation issues
                        $null = az sql db update `
                            --subscription $Config.DestSubscriptionId `
                            --resource-group $Config.DestResourceGroup `
                            --server $Config.DestServer `
                            --name $Config.DestDatabaseName `
                            --set "tags.$($tag.Name)=$($tag.Value)" `
                            --output none 2>$null
                    }
                        
                    Write-Host "  🏷️  $($Config.DestDatabaseName): $($tagList -join ', ')" -ForegroundColor Gray
                }
                catch {
                    Write-Host "  ⚠️  Warning: Failed to apply tags to $($Config.DestDatabaseName): $($_.Exception.Message)" -ForegroundColor Yellow
                }
            }
            
            Write-Host "  🏷️  $($config.DestDatabaseName):" -ForegroundColor Gray
            Apply-DatabaseTags -Config $config
        }
    }
    
    # Show skipped databases
    $skippedConfigs = $script:DatabaseConfigurations | Where-Object { 
        $config = $_
        -not ($successful | Where-Object { $_.db -eq $config.DestDatabaseName })
    }
    
    foreach ($config in $skippedConfigs) {
        Write-Host "  ⏭️  Skipping $($config.DestDatabaseName) - copy may have failed" -ForegroundColor Yellow
    }
    
    Write-Host "✅ Tag restoration completed" -ForegroundColor Green
    
    # Verify that all databases have the required tags
    Write-Host "`n🔍 Verifying database tags..." -ForegroundColor Cyan
    
    # Determine required tags based on namespace
    if ($DestinationNamespace -eq "manufacturo") {
        $requiredTags = @("Environment", "Owner", "Service", "Type")
        Write-Host "🔍 DEBUG: For manufacturo namespace, ClientName tag is optional (can be empty)" -ForegroundColor Gray
    } else {
        $requiredTags = @("ClientName", "Environment", "Owner", "Service", "Type")
        Write-Host "🔍 DEBUG: For namespace '$DestinationNamespace', ClientName tag is required" -ForegroundColor Gray
    }
    
    $tagVerificationResults = @()
    
    foreach ($config in $configsToProcess) {
        try {
            $currentTags = az sql db show --subscription $config.DestSubscriptionId --resource-group $config.DestResourceGroup --server $config.DestServer --name $config.DestDatabaseName --query "tags" -o json 2>$null | ConvertFrom-Json
            
            $missingTags = @()
            foreach ($requiredTag in $requiredTags) {
                if (-not $currentTags -or -not $currentTags.$requiredTag) {
                    $missingTags += $requiredTag
                }
            }
            
            # Special handling for ClientName when namespace is manufacturo
            if ($DestinationNamespace -eq "manufacturo" -and $currentTags -and $currentTags.ClientName) {
                Write-Host "  ⚠️  $($config.DestDatabaseName): Has ClientName tag but namespace is manufacturo (should be empty)" -ForegroundColor Yellow
            }
            
            if ($missingTags.Count -eq 0) {
                Write-Host "  ✅ $($config.DestDatabaseName): All required tags present" -ForegroundColor Green
                $tagVerificationResults += @{ Database = $config.DestDatabaseName; Status = "Complete"; MissingTags = @() }
            } else {
                Write-Host "  ❌ $($config.DestDatabaseName): Missing tags: $($missingTags -join ', ')" -ForegroundColor Red
                $tagVerificationResults += @{ Database = $config.DestDatabaseName; Status = "Incomplete"; MissingTags = $missingTags }
            }
        } catch {
            Write-Host "  ⚠️  $($config.DestDatabaseName): Failed to verify tags - $($_.Exception.Message)" -ForegroundColor Yellow
            $tagVerificationResults += @{ Database = $config.DestDatabaseName; Status = "Error"; MissingTags = @("Verification failed") }
        }
    }
    
    # Summary
    $completeCount = ($tagVerificationResults | Where-Object { $_.Status -eq "Complete" }).Count
    $incompleteCount = ($tagVerificationResults | Where-Object { $_.Status -eq "Incomplete" }).Count
    $errorCount = ($tagVerificationResults | Where-Object { $_.Status -eq "Error" }).Count
    
    Write-Host "`n📊 TAG VERIFICATION SUMMARY" -ForegroundColor Cyan
    Write-Host "===========================" -ForegroundColor Cyan
    Write-Host "✅ Complete: $completeCount databases" -ForegroundColor Green
    Write-Host "❌ Incomplete: $incompleteCount databases" -ForegroundColor Red
    Write-Host "⚠️  Errors: $errorCount databases" -ForegroundColor Yellow
    
    if ($incompleteCount -gt 0 -or $errorCount -gt 0) {
        Write-Host "`n🔧 Attempting to re-apply missing tags..." -ForegroundColor Yellow
        
        foreach ($result in $tagVerificationResults) {
            if ($result.Status -eq "Incomplete") {
                $config = $configsToProcess | Where-Object { $_.DestDatabaseName -eq $result.Database }
                if ($config) {
                    Write-Host "  🔄 Re-applying tags to $($result.Database)..." -ForegroundColor Gray
                    
                    # Re-apply the original tags from the configuration
                    if ($config.Tags -and $config.Tags.PSObject.Properties.Count -gt 0) {
                        foreach ($tag in $config.Tags.PSObject.Properties) {
                            try {
                                $null = az sql db update `
                                    --subscription $config.DestSubscriptionId `
                                    --resource-group $config.DestResourceGroup `
                                    --server $config.DestServer `
                                    --name $config.DestDatabaseName `
                                    --set "tags.$($tag.Name)=$($tag.Value)" `
                                    --output none 2>$null
                            } catch {
                                Write-Host "    ⚠️  Failed to apply tag $($tag.Name): $($_.Exception.Message)" -ForegroundColor Yellow
                            }
                        }
                        Write-Host "    ✅ Re-applied tags to $($result.Database)" -ForegroundColor Green
                    } else {
                        Write-Host "    ⚠️  No original tags available for $($result.Database)" -ForegroundColor Yellow
                    }
                }
            }
        }
        
        Write-Host "`n💡 Some databases were missing required tags. This may cause issues with:" -ForegroundColor Yellow
        Write-Host "   • Terraform state management" -ForegroundColor Gray
        Write-Host "   • Resource identification and management" -ForegroundColor Gray
        Write-Host "   • Environment-specific configurations" -ForegroundColor Gray
        Write-Host "`n🔧 Tags have been re-applied. Please verify the results." -ForegroundColor Cyan
    }
}