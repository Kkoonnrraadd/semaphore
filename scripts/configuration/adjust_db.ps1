param (
    [Parameter(Mandatory)] [string]$Destination,
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

Write-Host "Running with parameters:" -ForegroundColor Cyan
Write-Host "  - Destination: $Destination" -ForegroundColor Gray
Write-Host "  - CustomerAlias: $CustomerAlias" -ForegroundColor Gray
Write-Host "  - domain: $domain" -ForegroundColor Gray
Write-Host "  - DestinationNamespace: $DestinationNamespace" -ForegroundColor Gray
Write-Host ""

$Destination_lower = (Get-Culture).TextInfo.ToLower($Destination)

Write-Host "Constructing Azure Resource Graph query..." -ForegroundColor Cyan
$graph_query = "
  resources
  | where type =~ 'microsoft.sql/servers'
  | where tags.Environment == '$Destination_lower' and tags.Type == 'Primary'
  | project name, resourceGroup, subscriptionId, fqdn = properties.fullyQualifiedDomainName
"
Write-Host "Executing Azure Resource Graph query to find primary SQL server for environment '$Destination_lower'..." -ForegroundColor Cyan
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

Write-Host "Destination: $dest_subscription, $dest_server, $dest_rg, $dest_fqdn"

$dest_split = $dest_rg -split "-"
if ($dest_split.Count -lt 4) {
    Write-Host "❌ FATAL ERROR: Resource group name '$dest_rg' does not follow the expected format '...-environment-location'." -ForegroundColor Red
    exit 1
}
$dest_product     = $dest_split[1]
$dest_location    = $dest_split[-1]
$dest_type        = $dest_split[2]
$dest_environment = $dest_split[3]
Write-Host "Parsed from resource group '$dest_rg':" -ForegroundColor Cyan
Write-Host "  - Product: $dest_product" -ForegroundColor Gray
Write-Host "  - Type: $dest_type" -ForegroundColor Gray
Write-Host "  - Environment: $dest_environment" -ForegroundColor Gray
Write-Host "  - Location: $dest_location" -ForegroundColor Gray


# ═══════════════════════════════════════════════════════════════════════════
# HELPER FUNCTION
# ═══════════════════════════════════════════════════════════════════════════

function Add-DatabaseAlias {
    param (
        [Parameter(Mandatory)] [string]$DbName,
        [Parameter(Mandatory)] [string]$Fqdn,
        [Parameter(Mandatory)] [string]$AccessToken,
        [Parameter(Mandatory)] [string]$Alias,
        [Parameter(Mandatory)] [string]$Domain,
        [Parameter(Mandatory)] [string]$AliasLabel
    )

    Write-Host "Adding alias '$Alias' ($AliasLabel)..." -ForegroundColor Cyan

    $query = @"
        DECLARE @alias NVARCHAR(255) = '$Alias',
        @domain NVARCHAR(255) = '$Domain',
        @CoreId NVARCHAR(255),
        @CoreV2Id NVARCHAR(255),
        @ApiId NVARCHAR(255),
        @insertedCors INT = 0,
        @insertedRedirects INT = 0,
        @insertedPostLogout INT = 0,
        @coreOrigin NVARCHAR(500),
        @coreSilentRefresh NVARCHAR(500),
        @coreV2Origin NVARCHAR(500),
        @coreV2SilentRefresh NVARCHAR(500),
        @apiOrigin NVARCHAR(500),
        @apiSigninRedirect NVARCHAR(500);

        -- Core V1 Client
        SELECT @CoreId = Id FROM dbo.Clients WHERE ClientId = 'AndeaCore';
        IF @CoreId IS NOT NULL
        BEGIN
            SET @coreOrigin = FORMATMESSAGE('https://%s.manufacturo.%s', @alias, @domain);
            SET @coreSilentRefresh = FORMATMESSAGE('https://%s.manufacturo.%s/assets/auth/silent-refresh.html', @alias, @domain);

            IF NOT EXISTS(SELECT 1 FROM dbo.ClientCorsOrigins WHERE Origin = @coreOrigin AND ClientId = @CoreId)
            BEGIN
                INSERT dbo.ClientCorsOrigins(Origin, ClientId) VALUES(@coreOrigin, @CoreId);
                SET @insertedCors = @insertedCors + @@ROWCOUNT;
            END
            IF NOT EXISTS(SELECT 1 FROM dbo.ClientRedirectUris WHERE RedirectUri = @coreOrigin AND ClientId = @CoreId)
            BEGIN
                INSERT dbo.ClientRedirectUris(RedirectUri, ClientId) VALUES(@coreOrigin, @CoreId);
                SET @insertedRedirects = @insertedRedirects + @@ROWCOUNT;
            END
            IF NOT EXISTS(SELECT 1 FROM dbo.ClientRedirectUris WHERE RedirectUri = @coreSilentRefresh AND ClientId = @CoreId)
            BEGIN
                INSERT dbo.ClientRedirectUris(RedirectUri, ClientId) VALUES(@coreSilentRefresh, @CoreId);
                SET @insertedRedirects = @insertedRedirects + @@ROWCOUNT;
            END
            IF NOT EXISTS(SELECT 1 FROM dbo.ClientPostLogoutRedirectUris WHERE PostLogoutRedirectUri = @coreOrigin AND ClientId = @CoreId)
            BEGIN
                INSERT dbo.ClientPostLogoutRedirectUris(PostLogoutRedirectUri, ClientId) VALUES(@coreOrigin, @CoreId);
                SET @insertedPostLogout = @insertedPostLogout + @@ROWCOUNT;
            END
        END

        -- Core V2 Client
        SELECT @CoreV2Id = Id FROM dbo.Clients WHERE ClientId = 'AndeaCore_v2';
        IF @CoreV2Id IS NOT NULL
        BEGIN
            SET @coreV2Origin = FORMATMESSAGE('https://%s.manufacturo.%s', @alias, @domain);
            SET @coreV2SilentRefresh = FORMATMESSAGE('https://%s.manufacturo.%s/assets/auth/silent-refresh.html', @alias, @domain);

            IF NOT EXISTS(SELECT 1 FROM dbo.ClientCorsOrigins WHERE Origin = @coreV2Origin AND ClientId = @CoreV2Id)
            BEGIN
                INSERT dbo.ClientCorsOrigins(Origin, ClientId) VALUES(@coreV2Origin, @CoreV2Id);
                SET @insertedCors = @insertedCors + @@ROWCOUNT;
            END
            IF NOT EXISTS(SELECT 1 FROM dbo.ClientRedirectUris WHERE RedirectUri = @coreV2Origin AND ClientId = @CoreV2Id)
            BEGIN
                INSERT dbo.ClientRedirectUris(RedirectUri, ClientId) VALUES(@coreV2Origin, @CoreV2Id);
                SET @insertedRedirects = @insertedRedirects + @@ROWCOUNT;
            END
            IF NOT EXISTS(SELECT 1 FROM dbo.ClientRedirectUris WHERE RedirectUri = @coreV2SilentRefresh AND ClientId = @CoreV2Id)
            BEGIN
                INSERT dbo.ClientRedirectUris(RedirectUri, ClientId) VALUES(@coreV2SilentRefresh, @CoreV2Id);
                SET @insertedRedirects = @insertedRedirects + @@ROWCOUNT;
            END
            IF NOT EXISTS(SELECT 1 FROM dbo.ClientPostLogoutRedirectUris WHERE PostLogoutRedirectUri = @coreV2Origin AND ClientId = @CoreV2Id)
            BEGIN
                INSERT dbo.ClientPostLogoutRedirectUris(PostLogoutRedirectUri, ClientId) VALUES(@coreV2Origin, @CoreV2Id);
                SET @insertedPostLogout = @insertedPostLogout + @@ROWCOUNT;
            END
        END
        
        -- API Docs Client
        SELECT @ApiId = Id FROM dbo.Clients WHERE ClientId = 'apiDocs';
        IF @ApiId IS NOT NULL
        BEGIN
            SET @apiOrigin = FORMATMESSAGE('https://api.%s.manufacturo.%s', @alias, @domain);
            SET @apiSigninRedirect = FORMATMESSAGE('https://api.%s.manufacturo.%s/signin-oidc', @alias, @domain);

            IF NOT EXISTS(SELECT 1 FROM dbo.ClientCorsOrigins WHERE Origin = @apiOrigin AND ClientId = @ApiId)
            BEGIN
                INSERT dbo.ClientCorsOrigins(Origin, ClientId) VALUES(@apiOrigin, @ApiId);
                SET @insertedCors = @insertedCors + @@ROWCOUNT;
            END
            IF NOT EXISTS(SELECT 1 FROM dbo.ClientRedirectUris WHERE RedirectUri = @apiOrigin AND ClientId = @ApiId)
            BEGIN
                INSERT dbo.ClientRedirectUris(RedirectUri, ClientId) VALUES(@apiOrigin, @ApiId);
                SET @insertedRedirects = @insertedRedirects + @@ROWCOUNT;
            END
            IF NOT EXISTS(SELECT 1 FROM dbo.ClientRedirectUris WHERE RedirectUri = @apiSigninRedirect AND ClientId = @ApiId)
            BEGIN
                INSERT dbo.ClientRedirectUris(RedirectUri, ClientId) VALUES(@apiSigninRedirect, @ApiId);
                SET @insertedRedirects = @insertedRedirects + @@ROWCOUNT;
            END
            IF NOT EXISTS(SELECT 1 FROM dbo.ClientPostLogoutRedirectUris WHERE PostLogoutRedirectUri = @apiOrigin AND ClientId = @ApiId)
            BEGIN
                INSERT dbo.ClientPostLogoutRedirectUris(PostLogoutRedirectUri, ClientId) VALUES(@apiOrigin, @ApiId);
                SET @insertedPostLogout = @insertedPostLogout + @@ROWCOUNT;
            END
        END

        SELECT 'Alias Update Results' as Status, 
                @insertedCors as CORS_Origins_Added,
                @insertedRedirects as Redirect_URIs_Added,
                @insertedPostLogout as PostLogout_URIs_Added;
"@
    
    $result = Invoke-Sqlcmd -AccessToken $AccessToken -ServerInstance $Fqdn -Database $DbName -Query $query
    
    if ($result) {
        Write-Host "  - CORS Origins Added ($AliasLabel): $($result.CORS_Origins_Added)" -ForegroundColor Gray
        Write-Host "  - Redirect URIs Added ($AliasLabel): $($result.Redirect_URIs_Added)" -ForegroundColor Gray
        Write-Host "  - Post-Logout URIs Added ($AliasLabel): $($result.PostLogout_URIs_Added)" -ForegroundColor Gray
    } else {
        Write-Host "  - No results returned from alias update for '$Alias' ($AliasLabel)." -ForegroundColor Yellow
    }
}

# ═══════════════════════════════════════════════════════════════════════════
# MAIN EXECUTION
# ═══════════════════════════════════════════════════════════════════════════

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

if (-not [string]::IsNullOrWhiteSpace($DestinationNamespace)) {
    $expectedName  = "db-$dest_product-$dest_type-core-$DestinationNamespace-$dest_environment-$dest_location"
    $int_expectedName = "db-$dest_product-$dest_type-integratorplus-$DestinationNamespace-$dest_environment-$dest_location"
    $DestinationAlias = "$Destination-$DestinationNamespace"
    Write-Host "Constructed expected database name patterns:" -ForegroundColor Cyan
    Write-Host "  - Core DB: *$expectedName" -ForegroundColor Gray
    Write-Host "  - Integrator Plus DB: *$int_expectedName" -ForegroundColor Gray
}else{
    $global:LASTEXITCODE = 1
    throw "DestinationNamespace was empty"
}

# Default empty CustomerAlias to Destination if not provided
if ([string]::IsNullOrWhiteSpace($CustomerAlias)) {
    $CustomerAlias = $DestinationAlias
    Write-Host "⚠️  CustomerAlias was empty, using Destination '$CustomerAlias' as default" -ForegroundColor Yellow
}
    
if ($DryRun) {
    Write-Host "🔍 DRY RUN: Would adjust databases based on customer prefix..." -ForegroundColor Yellow
    Write-Host "🔍 DRY RUN: Customer Alias: $CustomerAlias" -ForegroundColor Gray
    Write-Host "🔍 DRY RUN: Domain: $domain" -ForegroundColor Gray
    
    $matchingDbs = $dbs | Where-Object { $_.name -like "*$expectedName" -or $_.name -like "*$int_expectedName" }
    Write-Host "🔍 DRY RUN: Would adjust $($matchingDbs.Count) databases:" -ForegroundColor Yellow
    foreach ($db in $matchingDbs) {
        Write-Host "  • $($db.name)" -ForegroundColor Gray
    }
    Write-Host "🔍 DRY RUN: Would add CORS origins and redirect URIs for:" -ForegroundColor Yellow
    Write-Host "  • https://$CustomerAlias.manufacturo.$domain" -ForegroundColor Gray
    Write-Host "  • https://api.$CustomerAlias.manufacturo.$domain" -ForegroundColor Gray
    Write-Host "`n🔍 DRY RUN: Database adjustment preview completed." -ForegroundColor Yellow

    if ($DestinationAlias -ne $CustomerAlias){
        Write-Host "  • https://$DestinationAlias.manufacturo.$domain" -ForegroundColor Gray
        Write-Host "  • https://api.$DestinationAlias.manufacturo.$domain" -ForegroundColor Gray
    }

    Write-Host "🔍 DRY RUN: Would delete from Integrator Plus: " -ForegroundColor Gray
    Write-Host "  • engine.parameter" -ForegroundColor Gray
    Write-Host "  • api_keys.entity" -ForegroundColor Gray
    Write-Host "  • api_keys.challengedlog" -ForegroundColor Gray
    Write-Host "`n🔍 DRY RUN: Database adjustment preview completed." -ForegroundColor Yellow

    exit 0
}

# Filter based on 'core' DB and customer prefix
Write-Host "Filtering databases based on customer prefix..." -ForegroundColor Cyan
$matchingDbs = $dbs | Where-Object { $_.name -eq $expectedName -or $_.name -eq $int_expectedName }

if ($matchingDbs.Count -eq 0) {
    Write-Host "⚠️  No databases found matching the expected names. No adjustments will be performed." -ForegroundColor Yellow
} else {
    Write-Host "Found $($matchingDbs.Count) matching database(s). Proceeding with adjustments..." -ForegroundColor Green
}

foreach ($db in $matchingDbs) {
    $dbName = $db.name

    if ($dbName -eq $expectedName) {
        Write-Host "`nExecuting SQL on DB: $dbName" -ForegroundColor Green
        try {
            # Add the primary customer alias
            Add-DatabaseAlias -DbName $dbName -Fqdn $dest_fqdn -AccessToken $AccessToken -Alias $CustomerAlias -Domain $domain -AliasLabel "CustomerAlias"
            
            # Add the Destination alias if it's different from the customer alias
            if ($DestinationAlias -ne $CustomerAlias) {
                Add-DatabaseAlias -DbName $dbName -Fqdn $dest_fqdn -AccessToken $AccessToken -Alias $DestinationAlias -Domain $domain -AliasLabel "DestinationAlias"
            }

            # Update organization.Site to clear license_customer_name
            Write-Host "Updating organization.Site table..." -ForegroundColor Cyan
            $updateResult = Invoke-Sqlcmd -AccessToken $AccessToken -ServerInstance $dest_fqdn -Database $dbName -Query @"
                UPDATE organization.Site SET license_customer_name = null;
                SELECT @@ROWCOUNT as Sites_Updated;
"@
            if ($updateResult) {
                Write-Host "  - Organization Sites Updated: $($updateResult.Sites_Updated)" -ForegroundColor Gray
            }

        } catch {
            Write-Host "Error on $dbName : $_" -ForegroundColor Red
        }
    }

    if ($dbName -eq $int_expectedName) {
        Write-Host "`nExecuting SQL on DB: $dbName" -ForegroundColor Green
        try {

            $intResult = Invoke-Sqlcmd -AccessToken $AccessToken -ServerInstance "$dest_fqdn" -Database $dbName -Query @"

            DECLARE @deletedParams INT = 0;
            DECLARE @deletedEntities INT = 0;
            DECLARE @deletedLogs INT = 0;

            DELETE FROM engine.parameter;
            SET @deletedParams = @@ROWCOUNT;
            DELETE FROM api_keys.entity;
            SET @deletedEntities = @@ROWCOUNT;
            DELETE FROM api_keys.challengedlog;
            SET @deletedLogs = @@ROWCOUNT;

            SELECT 'Integrator Plus Cleanup Results' as Status, 
                   @deletedParams as Engine_Parameters_Removed,
                   @deletedEntities as API_Key_Entities_Removed,
                   @deletedLogs as API_Key_Logs_Removed;
"@
            if ($intResult) {
                Write-Host "  - Engine Parameters Removed: $($intResult.Engine_Parameters_Removed)" -ForegroundColor Gray
                Write-Host "  - API Key Entities Removed: $($intResult.API_Key_Entities_Removed)" -ForegroundColor Gray
                Write-Host "  - API Key Logs Removed: $($intResult.API_Key_Logs_Removed)" -ForegroundColor Gray
            } else {
                Write-Host "  - No results returned from Integrator Plus cleanup." -ForegroundColor Yellow
            }
        }catch{
            Write-Host "Error on $dbName : $_" -ForegroundColor Red
        }

   }
}
