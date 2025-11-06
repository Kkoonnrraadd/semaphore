param (
    [string]$Destination,
    [string]$Source,
    [string]$Domain,
    [string]$DestinationNamespace,
    [string]$SourceNamespace,
    [string]$InstanceAliasToRemove,
    [switch]$DryRun
)

function Remove-EnvironmentUrls {
    param (
        [string]$AccessToken,
        [string]$dest_fqdn,
        [string]$dbName,
        [string]$Alias
    )


    $query = @"
        DECLARE @environmentToClean NVARCHAR(255) = '$Alias';
        DECLARE @deletedCors INT = 0;
        DECLARE @deletedRedirects INT = 0;
        DECLARE @deletedPostLogout INT = 0;

        -- Remove all CORS origins containing the environment name
        DELETE FROM dbo.ClientCorsOrigins WHERE Origin LIKE '%' + @environmentToClean + '%';
        SET @deletedCors = @@ROWCOUNT;

        -- Remove all redirect URIs containing the environment name
        DELETE FROM dbo.ClientRedirectUris WHERE RedirectUri LIKE '%' + @environmentToClean + '%';
        SET @deletedRedirects = @@ROWCOUNT;

        -- Remove all post-logout redirect URIs containing the environment name
        DELETE FROM dbo.ClientPostLogoutRedirectUris WHERE PostLogoutRedirectUri LIKE '%' + @environmentToClean + '%';
        SET @deletedPostLogout = @@ROWCOUNT;

        -- Show results
        SELECT 'Cleanup Results' as Status, 
            @deletedCors as CORS_Origins_Removed,
            @deletedRedirects as Redirect_URIs_Removed,
            @deletedPostLogout as PostLogout_URIs_Removed;

;
"@
    try {   
        $cleanupResult = Invoke-Sqlcmd -AccessToken $AccessToken -ServerInstance "$dest_fqdn" -Database $dbName -Query $query
    } catch {
        Write-Host "Error cleaning up $dbName : $_" -ForegroundColor Red
        $global:LASTEXITCODE = 1
        throw "Error cleaning up $dbName : $_"
    }
    return $cleanupResult

}

if ($DryRun) {
    Write-Host "`n🔍 DRY RUN MODE - Cleanup Environment Configuration" -ForegroundColor Yellow
    Write-Host "===============================================" -ForegroundColor Yellow
    Write-Host "No actual cleanup will be performed" -ForegroundColor Yellow
} else {
    Write-Host "`n=========================" -ForegroundColor Cyan
    Write-Host " Cleanup Environment Config" -ForegroundColor Cyan
    Write-Host "===========================`n" -ForegroundColor Cyan
}

Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "📋 CLEANUP ENVIRONMENT CONFIGURATION" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  - Destination: $Destination" -ForegroundColor Gray
Write-Host "  - EnvironmentToClean: $Source" -ForegroundColor Gray
Write-Host "  - Domain: $Domain" -ForegroundColor Gray
Write-Host "  - DestinationNamespace: $DestinationNamespace" -ForegroundColor Gray
Write-Host "  - MultitenantToRemove: $SourceNamespace" -ForegroundColor Gray
Write-Host "  - InstanceAliasToRemove: $InstanceAliasToRemove" -ForegroundColor Gray
Write-Host ""

$Destination_lower = (Get-Culture).TextInfo.ToLower($Destination)

Write-Host "Constructing Azure Resource Graph query..." -ForegroundColor Cyan
$graph_query = "
  resources
  | where type =~ 'microsoft.sql/servers'
  | where tags.Environment == '$Destination_lower' and tags.Type == 'Primary'
  | project name, resourceGroup, subscriptionId, fqdn = properties.fullyQualifiedDomainName
"

$server = az graph query -q $graph_query --query "data" --first 1000 | ConvertFrom-Json

if (-not $server -or $server.Count -eq 0) {
    Write-Host "❌ FATAL ERROR: No primary SQL server found for environment '$Destination_lower' using the graph query." -ForegroundColor Red
    Write-Host "   Please check the 'Environment' and 'Type' tags on your SQL server resources." -ForegroundColor Yellow
    exit 1
}

if ($server.Count -gt 1) {
    Write-Host "⚠️  WARNING: Found $($server.Count) primary SQL servers. Using the first one found: $($server[0].name)" -ForegroundColor Yellow
}

Write-Host "✅ Found primary SQL server: $($server[0].name)" -ForegroundColor Green
# Write-Host "Server details (JSON): $($server[0] | ConvertTo-Json -Depth 3)" -ForegroundColor Gray


$dest_subscription = $server[0].subscriptionId
$dest_server = $server[0].name
$dest_rg = $server[0].resourceGroup
$dest_fqdn = $server[0].fqdn

if ([string]::IsNullOrWhiteSpace($dest_subscription) -or [string]::IsNullOrWhiteSpace($dest_server) -or [string]::IsNullOrWhiteSpace($dest_rg) -or [string]::IsNullOrWhiteSpace($dest_fqdn)) {
    Write-Host "❌ FATAL ERROR: The discovered server object is missing required properties (subscriptionId, name, resourceGroup, fqdn)." -ForegroundColor Red
    exit 1
}

if ($dest_fqdn -match "database.windows.net") {
  $resourceUrl = "https://database.windows.net"
} else {
  $resourceUrl = "https://database.usgovcloudapi.net"
}


# # Construct the full environment name to clean up
# $FullEnvironmentToClean = if ($SourceNamespace -eq "manufacturo") {
#     # Special handling for "manufacturo" - it doesn't include multitenant in the environment name
#     $Source
# } else {
#     "$Source-$SourceNamespace"
# }


$dest_split = $dest_rg -split "-"
if ($dest_split.Count -lt 4) {
    Write-Host "❌ FATAL ERROR: Resource group name '$dest_rg' does not follow the expected format '...-environment-location'." -ForegroundColor Red
    exit 1
}

$dest_location    = $dest_split[-1]
$dest_environment = $dest_split[3]
$dest_product = $dest_split[1]
$dest_type = $dest_split[2]

# Get access token
Write-Host "`nRequesting access token for resource '$resourceUrl'..." -ForegroundColor Cyan
$AccessToken = (az account get-access-token --resource="$resourceUrl" --query accessToken --output tsv)
if ([string]::IsNullOrWhiteSpace($AccessToken)) {
    Write-Host "❌ FATAL ERROR: Failed to get access token for resource '$resourceUrl'." -ForegroundColor Red
    exit 1
}
Write-Host "✅ Access token retrieved successfully." -ForegroundColor Green

# Get list of SQL DBs
Write-Host "`nRetrieving databases from: $dest_server" -ForegroundColor Cyan
$dbs = az sql db list `
    --subscription $dest_subscription `
    --resource-group $dest_rg `
    --server $dest_server | ConvertFrom-Json

if (-not $dbs) {
    Write-Host "No databases found on server '$dest_server'" -ForegroundColor Red
    $global:LASTEXITCODE = 1
    throw "No databases found on server '$dest_server'"
}
Write-Host "Found $($dbs.Count) database(s) on server '$dest_server'." -ForegroundColor Green

if (-not [string]::IsNullOrWhiteSpace($DestinationNamespace) -and $DestinationNamespace -ne "manufacturo") {
    $expectedName  = "db-$dest_product-$dest_type-core-$DestinationNamespace-$dest_environment-$dest_location"
    Write-Host "Constructed expected database name pattern: $expectedName" -ForegroundColor Cyan
}else{
    $global:LASTEXITCODE = 1
    throw "DestinationNamespace was empty or Manufacturo namespace is not supported for cleanup"
}

if ($DryRun) {
    Write-Host "🔍 DRY RUN: Would clean up environment '$Source' from databases:" -ForegroundColor Yellow
    Write-Host "🔍 DRY RUN: Domain: $Domain" -ForegroundColor Gray
    Write-Host "🔍 DRY RUN: Expected database pattern: $expectedName" -ForegroundColor Gray
    
    $matchingDbs = $dbs | Where-Object { $_.name -like "$expectedName" }
    Write-Host "🔍 DRY RUN: Would clean up $($matchingDbs.Count) databases:`n" -ForegroundColor Yellow
    foreach ($db in $matchingDbs) {
        Write-Host "  • $($db.name)`n" -ForegroundColor Gray
    }
    
    Write-Host "🔍 DRY RUN: Would remove CORS origins and redirect URIs for:`n" -ForegroundColor Yellow
    Write-Host "  • https://$Source.manufacturo.$Domain`n" -ForegroundColor Gray
    Write-Host "  • https://api.$Source.manufacturo.$Domain`n" -ForegroundColor Gray
    Write-Host "  • Any URLs containing '$Source' (including swagger URLs)`n" -ForegroundColor Gray
    
    if (-not [string]::IsNullOrWhiteSpace($InstanceAliasToRemove) -and $InstanceAliasToRemove -ne $Source) {
        Write-Host "  • https://$InstanceAliasToRemove.manufacturo.$Domain`n" -ForegroundColor Gray
        Write-Host "  • https://api.$InstanceAliasToRemove.manufacturo.$Domain`n" -ForegroundColor Gray
        Write-Host "  • Any URLs containing '$InstanceAliasToRemove' (including swagger URLs)`n" -ForegroundColor Gray
    } elseif ($InstanceAliasToRemove -eq $Source) {
        Write-Host "  ⚠️  Skipping customer alias removal - same as environment to clean ($InstanceAliasToRemove)" -ForegroundColor Yellow
    }
    
    Write-Host "`n🔍 DRY RUN: Cleanup preview completed.`n" -ForegroundColor Yellow
    exit 0
}

# Filter based on 'core' DB and customer prefix
Write-Host "Filtering databases based on customer prefix..." -ForegroundColor Cyan
$matchingDbs = $dbs | Where-Object { $_.name -like "$expectedName" }

if ($matchingDbs.Count -eq 0) {
    Write-Host "⚠️  No databases found matching the pattern '$expectedName'. No cleanup will be performed." -ForegroundColor Yellow
} else {
    Write-Host "Found $($matchingDbs.Count) database(s) matching the pattern. Now checking for exact core DB names..." -ForegroundColor Green
}

foreach ($db in $matchingDbs) {
    $dbName = $db.name

    if ($dbName -eq "$expectedName") {
        Write-Host "`nCleaning up DB: $dbName" -ForegroundColor Green
        try {
            Write-Host "Removing all CORS origins and redirect URIs containing '$Source'"
            $cleanupResult = Remove-EnvironmentUrls -AccessToken $AccessToken -dest_fqdn $dest_fqdn -dbName $dbName -Alias $Source

#             $cleanupResult = Invoke-Sqlcmd -AccessToken $AccessToken -ServerInstance "$dest_fqdn" -Database $dbName -Query @"

#             DECLARE @environmentToClean NVARCHAR(255) = '$Source';
#             DECLARE @deletedCors INT = 0;
#             DECLARE @deletedRedirects INT = 0;
#             DECLARE @deletedPostLogout INT = 0;

#             -- Remove all CORS origins containing the environment name
#             DELETE FROM dbo.ClientCorsOrigins WHERE Origin LIKE '%' + @environmentToClean + '%';
#             SET @deletedCors = @@ROWCOUNT;

#             -- Remove all redirect URIs containing the environment name
#             DELETE FROM dbo.ClientRedirectUris WHERE RedirectUri LIKE '%' + @environmentToClean + '%';
#             SET @deletedRedirects = @@ROWCOUNT;

#             -- Remove all post-logout redirect URIs containing the environment name
#             DELETE FROM dbo.ClientPostLogoutRedirectUris WHERE PostLogoutRedirectUri LIKE '%' + @environmentToClean + '%';
#             SET @deletedPostLogout = @@ROWCOUNT;

#             -- Show results
#             SELECT 'Cleanup Results' as Status, 
#                    @deletedCors as CORS_Origins_Removed,
#                    @deletedRedirects as Redirect_URIs_Removed,
#                    @deletedPostLogout as PostLogout_URIs_Removed;

# ;
# "@
            if ($cleanupResult) {
                Write-Host "  - CORS Origins Removed: $($cleanupResult.CORS_Origins_Removed)" -ForegroundColor Gray
                Write-Host "  - Redirect URIs Removed: $($cleanupResult.Redirect_URIs_Removed)" -ForegroundColor Gray
                Write-Host "  - Post-Logout URIs Removed: $($cleanupResult.PostLogout_URIs_Removed)" -ForegroundColor Gray
            } else {
                Write-Host "⚠️ WARNING: No results returned from cleanup query for '$Source'." -ForegroundColor Yellow
            }

            # Also remove customer alias if specified (but not if it's the same as environment to clean)
            if (-not [string]::IsNullOrWhiteSpace($InstanceAliasToRemove) -and $InstanceAliasToRemove -ne $Source) {
                Write-Host "Removing all CORS origins and redirect URIs containing customer alias: $InstanceAliasToRemove"
                $aliasCleanupResult = Remove-EnvironmentUrls -AccessToken $AccessToken -dest_fqdn $dest_fqdn -dbName $dbName -Alias $InstanceAliasToRemove
#                 $aliasCleanupResult = Invoke-Sqlcmd -AccessToken $AccessToken -ServerInstance "$dest_fqdn" -Database $dbName -Query @"

#                 DECLARE @customerAliasToRemove NVARCHAR(255) = '$InstanceAliasToRemove';
#                 DECLARE @deletedCorsAlias INT = 0;
#                 DECLARE @deletedRedirectsAlias INT = 0;
#                 DECLARE @deletedPostLogoutAlias INT = 0;

#                 -- Remove all CORS origins containing the customer alias
#                 DELETE FROM dbo.ClientCorsOrigins WHERE Origin LIKE '%' + @customerAliasToRemove + '%';
#                 SET @deletedCorsAlias = @@ROWCOUNT;

#                 -- Remove all redirect URIs containing the customer alias
#                 DELETE FROM dbo.ClientRedirectUris WHERE RedirectUri LIKE '%' + @customerAliasToRemove + '%';
#                 SET @deletedRedirectsAlias = @@ROWCOUNT;

#                 -- Remove all post-logout redirect URIs containing the customer alias
#                 DELETE FROM dbo.ClientPostLogoutRedirectUris WHERE PostLogoutRedirectUri LIKE '%' + @customerAliasToRemove + '%';
#                 SET @deletedPostLogoutAlias = @@ROWCOUNT;

#                 -- Show results for customer alias
#                 SELECT 'Instance Alias Cleanup Results' as Status, 
#                        @deletedCorsAlias as CORS_Origins_Removed,
#                        @deletedRedirectsAlias as Redirect_URIs_Removed,
#                        @deletedPostLogoutAlias as PostLogout_URIs_Removed;

# ;
# "@
                if ($aliasCleanupResult) {
                    Write-Host "  - CORS Origins Removed (Alias): $($aliasCleanupResult.CORS_Origins_Removed)" -ForegroundColor Gray
                    Write-Host "  - Redirect URIs Removed (Alias): $($aliasCleanupResult.Redirect_URIs_Removed)" -ForegroundColor Gray
                    Write-Host "  - Post-Logout URIs Removed (Alias): $($aliasCleanupResult.PostLogout_URIs_Removed)" -ForegroundColor Gray
                } else {
                    Write-Host "⚠️ WARNING: No results returned from alias cleanup query for '$InstanceAliasToRemove'." -ForegroundColor Yellow
                }
            } elseif (-not [string]::IsNullOrWhiteSpace($InstanceAliasToRemove) -and $InstanceAliasToRemove -eq $Source) {
                Write-Host "⚠️  Skipping customer alias cleanup - same as environment to clean ($InstanceAliasToRemove)" -ForegroundColor Yellow
            }


        } catch {
            Write-Host "Error cleaning up $dbName : $_" -ForegroundColor Red
            $global:LASTEXITCODE = 1
            throw "Error cleaning up $dbName : $_"
        }
    } else {
        Write-Host "  - Skipping DB '$dbName' as it does not match the exact core database names '$expectedName'." -ForegroundColor DarkGray
    }
}

Write-Host "`nCORS origins and redirect URIs cleanup completed for environment: $Source" -ForegroundColor Green
