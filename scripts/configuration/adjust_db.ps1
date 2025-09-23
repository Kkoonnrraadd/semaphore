param (
    [Parameter(Mandatory)] [string]$destination,
    [AllowEmptyString()][Parameter(Mandatory)][string]$CustomerAlias,
    [Parameter(Mandatory)] [string]$domain,
    [AllowEmptyString()][Parameter(Mandatory)][string]$DestinationNamespace,
    [switch]$DryRun
)

if ($DryRun) {
    Write-Host "`n🔍 DRY RUN MODE - Adjust Database" -ForegroundColor Yellow
    Write-Host "=================================" -ForegroundColor Yellow
    Write-Host "No actual database adjustments will be performed" -ForegroundColor Yellow
} else {
    Write-Host "`n=========================" -ForegroundColor Cyan
    Write-Host " Adjust Database" -ForegroundColor Cyan
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

$dest_split = $dest_rg -split "-"
$dest_product     = $dest_split[1]
$dest_location    = $dest_split[-1]
$dest_type        = $dest_split[2]
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
    $destinationAlias = "$destination"
} else {
    $expectedName  = "core-$DestinationNamespace-$dest_environment-$dest_location"
    $destinationAlias = "$destination-$DestinationNamespace"
}

# Default empty CustomerAlias to destination if not provided
if ([string]::IsNullOrWhiteSpace($CustomerAlias)) {
    $CustomerAlias = $destinationAlias
    Write-Host "⚠️  CustomerAlias was empty, using destination '$CustomerAlias' as default" -ForegroundColor Yellow
}

$int_expectedName = if ([string]::IsNullOrWhiteSpace($DestinationNamespace)) {
    # Special handling for "manufacturo" - it doesn't include multitenant in the database name
    "integratorplus-$dest_environment-$dest_location"
} else {
    "ignoreformultitenant"
    # continue
}
    
if ($DryRun) {
    Write-Host "🔍 DRY RUN: Would adjust databases based on customer prefix..." -ForegroundColor Yellow
    Write-Host "🔍 DRY RUN: Customer Alias: $CustomerAlias" -ForegroundColor Gray
    Write-Host "🔍 DRY RUN: Domain: $domain" -ForegroundColor Gray
    Write-Host "🔍 DRY RUN: Expected database pattern: *$expectedName" -ForegroundColor Gray
    
    $matchingDbs = $dbs | Where-Object { $_.name -like "*$expectedName" }
    Write-Host "🔍 DRY RUN: Would adjust $($matchingDbs.Count) databases:" -ForegroundColor Yellow
    foreach ($db in $matchingDbs) {
        Write-Host "  • $($db.name)" -ForegroundColor Gray
    }
    Write-Host "🔍 DRY RUN: Would add CORS origins and redirect URIs for:" -ForegroundColor Yellow
    Write-Host "  • https://$CustomerAlias.manufacturo.$domain" -ForegroundColor Gray
    Write-Host "  • https://api.$CustomerAlias.manufacturo.$domain" -ForegroundColor Gray
    Write-Host "`n🔍 DRY RUN: Database adjustment preview completed." -ForegroundColor Yellow

    if ($destinationAlias -ne $CustomerAlias){
        Write-Host "  • https://$destinationAlias.manufacturo.$domain" -ForegroundColor Gray
        Write-Host "  • https://api.$destinationAlias.manufacturo.$domain" -ForegroundColor Gray
    }

    exit 0
}

# Filter based on 'core' DB and customer prefix
Write-Host "Filtering databases based on customer prefix..." -ForegroundColor Cyan
foreach ($db in $dbs) {
    $dbName = $db.name

    if ($dbName -like "*$expectedName") {
        Write-Host "`nExecuting SQL on DB: $dbName" -ForegroundColor Green
        try {

            Write-Host "Adding alias $CustomerAlias..."

			Invoke-Sqlcmd -AccessToken $AccessToken -ServerInstance "$dest_fqdn" -Database $dbName -Query @"

            DECLARE @alias NVARCHAR(255) = '$CustomerAlias',
            @domain NVARCHAR(255) = '$domain',
            @CoreId NVARCHAR(255),
            @CoreV2Id NVARCHAR(255),
            @ApiId NVARCHAR(255);

            SELECT @CoreId = Id FROM dbo.Clients WHERE ClientId = 'AndeaCore';

            DECLARE @coreOrigin NVARCHAR(500) = FORMATMESSAGE('https://%s.manufacturo.%s', @alias, @domain),
            @coreSilentRefresh NVARCHAR(500) = FORMATMESSAGE('https://%s.manufacturo.%s/assets/auth/silent-refresh.html', @alias, @domain);

            IF NOT EXISTS(SELECT 1 FROM dbo.ClientCorsOrigins WHERE Origin = @coreOrigin AND ClientId = @CoreId)
            INSERT dbo.ClientCorsOrigins(Origin, ClientId) VALUES(@coreOrigin, @CoreId);

            IF NOT EXISTS(SELECT 1 FROM dbo.ClientRedirectUris WHERE RedirectUri = @coreOrigin AND ClientId = @CoreId)
            INSERT dbo.ClientRedirectUris(RedirectUri, ClientId) VALUES(@coreOrigin, @CoreId);

            IF NOT EXISTS(SELECT 1 FROM dbo.ClientRedirectUris WHERE RedirectUri = @coreSilentRefresh AND ClientId = @CoreId)
            INSERT dbo.ClientRedirectUris(RedirectUri, ClientId) VALUES(@coreSilentRefresh, @CoreId);

            IF NOT EXISTS(SELECT 1 FROM dbo.ClientPostLogoutRedirectUris WHERE PostLogoutRedirectUri = @coreOrigin AND ClientId = @CoreId)
            INSERT dbo.ClientPostLogoutRedirectUris(PostLogoutRedirectUri, ClientId) VALUES(@coreOrigin, @CoreId);

            SELECT @CoreV2Id = Id FROM dbo.Clients WHERE ClientId = 'AndeaCore_v2';

            IF NOT EXISTS(SELECT 1 FROM dbo.ClientCorsOrigins WHERE Origin = @coreOrigin AND ClientId = @CoreV2Id)
            INSERT dbo.ClientCorsOrigins(Origin, ClientId) VALUES(@coreOrigin, @CoreV2Id);

            IF NOT EXISTS(SELECT 1 FROM dbo.ClientRedirectUris WHERE RedirectUri = @coreOrigin AND ClientId = @CoreV2Id)
            INSERT dbo.ClientRedirectUris(RedirectUri, ClientId) VALUES(@coreOrigin, @CoreV2Id);

            IF NOT EXISTS(SELECT 1 FROM dbo.ClientRedirectUris WHERE RedirectUri = @coreSilentRefresh AND ClientId = @CoreV2Id)
            INSERT dbo.ClientRedirectUris(RedirectUri, ClientId) VALUES(@coreSilentRefresh, @CoreV2Id);

            IF NOT EXISTS(SELECT 1 FROM dbo.ClientPostLogoutRedirectUris WHERE PostLogoutRedirectUri = @coreOrigin AND ClientId = @CoreV2Id)
            INSERT dbo.ClientPostLogoutRedirectUris(PostLogoutRedirectUri, ClientId) VALUES(@coreOrigin, @CoreV2Id);

            SELECT @ApiId = Id FROM dbo.Clients WHERE ClientId = 'apiDocs';

            DECLARE @apiOrigin NVARCHAR(500) = FORMATMESSAGE('https://api.%s.manufacturo.%s', @alias, @domain),
            @apiSigninRedirect NVARCHAR(500) = FORMATMESSAGE('https://api.%s.manufacturo.%s/signin-oidc', @alias, @domain);

            IF NOT EXISTS(SELECT 1 FROM dbo.ClientCorsOrigins WHERE Origin = @apiOrigin AND ClientId = @ApiId)
            INSERT dbo.ClientCorsOrigins(Origin, ClientId) VALUES(@apiOrigin, @ApiId);

            IF NOT EXISTS(SELECT 1 FROM dbo.ClientRedirectUris WHERE RedirectUri = @apiOrigin AND ClientId = @ApiId)
            INSERT dbo.ClientRedirectUris(RedirectUri, ClientId) VALUES(@apiOrigin, @ApiId);

            IF NOT EXISTS(SELECT 1 FROM dbo.ClientRedirectUris WHERE RedirectUri = @apiSigninRedirect AND ClientId = @ApiId)
            INSERT dbo.ClientRedirectUris(RedirectUri, ClientId) VALUES(@apiSigninRedirect, @ApiId);

            IF NOT EXISTS(SELECT 1 FROM dbo.ClientPostLogoutRedirectUris WHERE PostLogoutRedirectUri = @apiOrigin AND ClientId = @ApiId)
            INSERT dbo.ClientPostLogoutRedirectUris(PostLogoutRedirectUri, ClientId) VALUES(@apiOrigin, @ApiId);

            -- Update organization.Site to clear license_customer_name
            UPDATE organization.Site
            SET license_customer_name = null;
;
"@

            if ($destinationAlias -ne $CustomerAlias){
            Write-Host "Adding alias $destinationAlias..."

            Invoke-Sqlcmd -AccessToken $AccessToken -ServerInstance "$dest_fqdn" -Database $dbName -Query @"

            DECLARE @alias NVARCHAR(255) = '$destinationAlias',
            @domain NVARCHAR(255) = '$domain',
            @CoreId NVARCHAR(255),
            @CoreV2Id NVARCHAR(255),
            @ApiId NVARCHAR(255);

            SELECT @CoreId = Id FROM dbo.Clients WHERE ClientId = 'AndeaCore';

            DECLARE @coreOrigin NVARCHAR(500) = FORMATMESSAGE('https://%s.manufacturo.%s', @alias, @domain),
            @coreSilentRefresh NVARCHAR(500) = FORMATMESSAGE('https://%s.manufacturo.%s/assets/auth/silent-refresh.html', @alias, @domain);

            IF NOT EXISTS(SELECT 1 FROM dbo.ClientCorsOrigins WHERE Origin = @coreOrigin AND ClientId = @CoreId)
            INSERT dbo.ClientCorsOrigins(Origin, ClientId) VALUES(@coreOrigin, @CoreId);

            IF NOT EXISTS(SELECT 1 FROM dbo.ClientRedirectUris WHERE RedirectUri = @coreOrigin AND ClientId = @CoreId)
            INSERT dbo.ClientRedirectUris(RedirectUri, ClientId) VALUES(@coreOrigin, @CoreId);

            IF NOT EXISTS(SELECT 1 FROM dbo.ClientRedirectUris WHERE RedirectUri = @coreSilentRefresh AND ClientId = @CoreId)
            INSERT dbo.ClientRedirectUris(RedirectUri, ClientId) VALUES(@coreSilentRefresh, @CoreId);

            IF NOT EXISTS(SELECT 1 FROM dbo.ClientPostLogoutRedirectUris WHERE PostLogoutRedirectUri = @coreOrigin AND ClientId = @CoreId)
            INSERT dbo.ClientPostLogoutRedirectUris(PostLogoutRedirectUri, ClientId) VALUES(@coreOrigin, @CoreId);

            SELECT @CoreV2Id = Id FROM dbo.Clients WHERE ClientId = 'AndeaCore_v2';

            IF NOT EXISTS(SELECT 1 FROM dbo.ClientCorsOrigins WHERE Origin = @coreOrigin AND ClientId = @CoreV2Id)
            INSERT dbo.ClientCorsOrigins(Origin, ClientId) VALUES(@coreOrigin, @CoreV2Id);

            IF NOT EXISTS(SELECT 1 FROM dbo.ClientRedirectUris WHERE RedirectUri = @coreOrigin AND ClientId = @CoreV2Id)
            INSERT dbo.ClientRedirectUris(RedirectUri, ClientId) VALUES(@coreOrigin, @CoreV2Id);

            IF NOT EXISTS(SELECT 1 FROM dbo.ClientRedirectUris WHERE RedirectUri = @coreSilentRefresh AND ClientId = @CoreV2Id)
            INSERT dbo.ClientRedirectUris(RedirectUri, ClientId) VALUES(@coreSilentRefresh, @CoreV2Id);

            IF NOT EXISTS(SELECT 1 FROM dbo.ClientPostLogoutRedirectUris WHERE PostLogoutRedirectUri = @coreOrigin AND ClientId = @CoreV2Id)
            INSERT dbo.ClientPostLogoutRedirectUris(PostLogoutRedirectUri, ClientId) VALUES(@coreOrigin, @CoreV2Id);

            SELECT @ApiId = Id FROM dbo.Clients WHERE ClientId = 'apiDocs';

            DECLARE @apiOrigin NVARCHAR(500) = FORMATMESSAGE('https://api.%s.manufacturo.%s', @alias, @domain),
            @apiSigninRedirect NVARCHAR(500) = FORMATMESSAGE('https://api.%s.manufacturo.%s/signin-oidc', @alias, @domain);

            IF NOT EXISTS(SELECT 1 FROM dbo.ClientCorsOrigins WHERE Origin = @apiOrigin AND ClientId = @ApiId)
            INSERT dbo.ClientCorsOrigins(Origin, ClientId) VALUES(@apiOrigin, @ApiId);

            IF NOT EXISTS(SELECT 1 FROM dbo.ClientRedirectUris WHERE RedirectUri = @apiOrigin AND ClientId = @ApiId)
            INSERT dbo.ClientRedirectUris(RedirectUri, ClientId) VALUES(@apiOrigin, @ApiId);

            IF NOT EXISTS(SELECT 1 FROM dbo.ClientRedirectUris WHERE RedirectUri = @apiSigninRedirect AND ClientId = @ApiId)
            INSERT dbo.ClientRedirectUris(RedirectUri, ClientId) VALUES(@apiSigninRedirect, @ApiId);

            IF NOT EXISTS(SELECT 1 FROM dbo.ClientPostLogoutRedirectUris WHERE PostLogoutRedirectUri = @apiOrigin AND ClientId = @ApiId)
            INSERT dbo.ClientPostLogoutRedirectUris(PostLogoutRedirectUri, ClientId) VALUES(@apiOrigin, @ApiId);


;
"@
            }

        }catch{
            
            Write-Host "Error on $dbName : $_" -ForegroundColor Red
            
        }
    }

    if (($dbName -like "*$int_expectedName") -and (!$db.name.Contains("integratorplusext"))) {
        Write-Host "`nExecuting SQL on DB: $dbName" -ForegroundColor Green
        try {

            Invoke-Sqlcmd -AccessToken $AccessToken -ServerInstance "$dest_fqdn" -Database $dbName -Query @"

            DELETE FROM engine.parameter;
            DELETE FROM api_keys.entity;
            DELETE FROM api_keys.challengedlog;
"@
        }catch{
            Write-Host "Error on $dbName : $_" -ForegroundColor Red
        }

   }
}
