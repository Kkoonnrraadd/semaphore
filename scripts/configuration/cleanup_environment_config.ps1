param (
    [Parameter(Mandatory)] [string]$destination,
    [Parameter(Mandatory)] [string]$EnvironmentToClean,
    [Parameter(Mandatory)] [string]$domain,
    [AllowEmptyString()][Parameter(Mandatory)][string]$DestinationNamespace,
    [AllowEmptyString()][string]$MultitenantToRemove,
    [AllowEmptyString()][string]$CustomerAliasToRemove,
    [switch]$DryRun
)

if ($DryRun) {
    Write-Host "`n🔍 DRY RUN MODE - Cleanup Environment Configuration" -ForegroundColor Yellow
    Write-Host "===============================================" -ForegroundColor Yellow
    Write-Host "No actual cleanup will be performed" -ForegroundColor Yellow
} else {
    Write-Host "`n=========================" -ForegroundColor Cyan
    Write-Host " Cleanup Environment Config" -ForegroundColor Cyan
    Write-Host "===========================`n" -ForegroundColor Cyan
}

$destination_lower = (Get-Culture).TextInfo.ToLower($destination)

$graph_query = "
  resources
  | where type =~ 'microsoft.sql/servers'
  | where tags.Environment == '$destination_lower' and tags.Type == 'Primary'
  | project name, resourceGroup, subscriptionId, fqdn = properties.fullyQualifiedDomainName
"
$server = az graph query -q $graph_query --query "data" --first 1000 | ConvertFrom-Json

$dest_subscription = $server[0].subscriptionId
$dest_server = $server[0].name
$dest_rg = $server[0].resourceGroup
$dest_fqdn = $server[0].fqdn
if ($dest_fqdn -match "database.windows.net") {
  $resourceUrl = "https://database.windows.net"
} else {
  $resourceUrl = "https://database.usgovcloudapi.net"
}

Write-Host "Destination: $dest_subscription, $dest_server, $dest_rg, $dest_fqdn"

# Construct the full environment name to clean up
$FullEnvironmentToClean = if ($MultitenantToRemove -eq "manufacturo") {
    # Special handling for "manufacturo" - it doesn't include multitenant in the environment name
    $EnvironmentToClean
} else {
    "$EnvironmentToClean-$MultitenantToRemove"
}

Write-Host "Cleaning up configuration for environment: $FullEnvironmentToClean"

$dest_split = $dest_rg -split "-"
$dest_location    = $dest_split[-1]
$dest_environment = $dest_split[3]

# Get access token
$AccessToken = (az account get-access-token --resource="$resourceUrl" --query accessToken --output tsv)

# Get list of SQL DBs
Write-Host "`nRetrieving databases from: $dest_server" -ForegroundColor Cyan
$dbs = az sql db list `
    --subscription $dest_subscription `
    --resource-group $dest_rg `
    --server $dest_server | ConvertFrom-Json

if (-not $dbs) {
    Write-Host "No databases found on server '$dest_server'" -ForegroundColor Red
    exit 1
}

if ($DestinationNamespace -eq "manufacturo") {
    # Special handling for "manufacturo" - it doesn't include multitenant in the database name
    $expectedName  = "core-$dest_environment-$dest_location"
} else {
    $expectedName  = "core-$DestinationNamespace-$dest_environment-$dest_location"
}

if ($DryRun) {
    Write-Host "🔍 DRY RUN: Would clean up environment '$FullEnvironmentToClean' from databases..." -ForegroundColor Yellow
    Write-Host "🔍 DRY RUN: Domain: $domain" -ForegroundColor Gray
    Write-Host "🔍 DRY RUN: Expected database pattern: *$expectedName" -ForegroundColor Gray
    
    $matchingDbs = $dbs | Where-Object { $_.name -like "*$expectedName" }
    Write-Host "🔍 DRY RUN: Would clean up $($matchingDbs.Count) databases:" -ForegroundColor Yellow
    foreach ($db in $matchingDbs) {
        Write-Host "  • $($db.name)" -ForegroundColor Gray
    }
    
    Write-Host "🔍 DRY RUN: Would remove CORS origins and redirect URIs for:" -ForegroundColor Yellow
    Write-Host "  • https://$FullEnvironmentToClean.manufacturo.$domain" -ForegroundColor Gray
    Write-Host "  • https://api.$FullEnvironmentToClean.manufacturo.$domain" -ForegroundColor Gray
    Write-Host "  • Any URLs containing '$FullEnvironmentToClean' (including swagger URLs)" -ForegroundColor Gray
    
    if (-not [string]::IsNullOrWhiteSpace($CustomerAliasToRemove) -and $CustomerAliasToRemove -ne $FullEnvironmentToClean) {
        Write-Host "  • https://$CustomerAliasToRemove.manufacturo.$domain" -ForegroundColor Gray
        Write-Host "  • https://api.$CustomerAliasToRemove.manufacturo.$domain" -ForegroundColor Gray
        Write-Host "  • Any URLs containing '$CustomerAliasToRemove' (including swagger URLs)" -ForegroundColor Gray
    } elseif ($CustomerAliasToRemove -eq $FullEnvironmentToClean) {
        Write-Host "  ⚠️  Skipping customer alias removal - same as environment to clean ($CustomerAliasToRemove)" -ForegroundColor Yellow
    }
    
    Write-Host "`n🔍 DRY RUN: Cleanup preview completed." -ForegroundColor Yellow
    exit 0
}

# Filter based on 'core' DB and customer prefix
Write-Host "Filtering databases based on customer prefix..." -ForegroundColor Cyan
foreach ($db in $dbs) {
    $dbName = $db.name

    if ($dbName -like "*$expectedName") {
        Write-Host "`nCleaning up DB: $dbName" -ForegroundColor Green
        try {
            Write-Host "Removing all CORS origins and redirect URIs containing '$FullEnvironmentToClean'"

            Invoke-Sqlcmd -AccessToken $AccessToken -ServerInstance "$dest_fqdn" -Database $dbName -Query @"

            DECLARE @environmentToClean NVARCHAR(255) = '$FullEnvironmentToClean';
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

            # Also remove customer alias if specified (but not if it's the same as environment to clean)
            if (-not [string]::IsNullOrWhiteSpace($CustomerAliasToRemove) -and $CustomerAliasToRemove -ne $FullEnvironmentToClean) {
                Write-Host "Removing all CORS origins and redirect URIs containing customer alias: $CustomerAliasToRemove"

                Invoke-Sqlcmd -AccessToken $AccessToken -ServerInstance "$dest_fqdn" -Database $dbName -Query @"

                DECLARE @customerAliasToRemove NVARCHAR(255) = '$CustomerAliasToRemove';
                DECLARE @deletedCorsAlias INT = 0;
                DECLARE @deletedRedirectsAlias INT = 0;
                DECLARE @deletedPostLogoutAlias INT = 0;

                -- Remove all CORS origins containing the customer alias
                DELETE FROM dbo.ClientCorsOrigins WHERE Origin LIKE '%' + @customerAliasToRemove + '%';
                SET @deletedCorsAlias = @@ROWCOUNT;

                -- Remove all redirect URIs containing the customer alias
                DELETE FROM dbo.ClientRedirectUris WHERE RedirectUri LIKE '%' + @customerAliasToRemove + '%';
                SET @deletedRedirectsAlias = @@ROWCOUNT;

                -- Remove all post-logout redirect URIs containing the customer alias
                DELETE FROM dbo.ClientPostLogoutRedirectUris WHERE PostLogoutRedirectUri LIKE '%' + @customerAliasToRemove + '%';
                SET @deletedPostLogoutAlias = @@ROWCOUNT;

                -- Show results for customer alias
                SELECT 'Customer Alias Cleanup Results' as Status, 
                       @deletedCorsAlias as CORS_Origins_Removed,
                       @deletedRedirectsAlias as Redirect_URIs_Removed,
                       @deletedPostLogoutAlias as PostLogout_URIs_Removed;

;
"@
            } elseif (-not [string]::IsNullOrWhiteSpace($CustomerAliasToRemove) -and $CustomerAliasToRemove -eq $FullEnvironmentToClean) {
                Write-Host "⚠️  Skipping customer alias cleanup - same as environment to clean ($CustomerAliasToRemove)" -ForegroundColor Yellow
            }


        } catch {
            Write-Host "Error cleaning up $dbName : $_" -ForegroundColor Red
        }
    }
}

Write-Host "`nCORS origins and redirect URIs cleanup completed for environment: $FullEnvironmentToClean" -ForegroundColor Green
