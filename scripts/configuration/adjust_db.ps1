param (
    [Parameter(Mandatory)] [string]$Destination,
    [AllowEmptyString()][Parameter(Mandatory)][string]$InstanceAlias,
    [Parameter(Mandatory)] [string]$Domain,
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

# Write-Host "Running with parameters:" -ForegroundColor Cyan
# Write-Host "  - Destination: $Destination" -ForegroundColor Gray
# Write-Host "  - InstanceAlias: $InstanceAlias" -ForegroundColor Gray
# Write-Host "  - Domain: $Domain" -ForegroundColor Gray
# Write-Host "  - DestinationNamespace: $DestinationNamespace" -ForegroundColor Gray
# Write-Host ""

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
    Write-Host "❌ No SQL server found for environment with tags Environment: $Destination_lower and Type: Primary"

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

# Write-Host "Destination: $dest_subscription, $dest_server, $dest_rg, $dest_fqdn"

$dest_split = $dest_rg -split "-"
if ($dest_split.Count -lt 4) {
    Write-Host "❌ FATAL ERROR: Resource group name '$dest_rg' does not follow the expected format '...-environment-location'." -ForegroundColor Red
    exit 1
}
$dest_product     = $dest_split[1]
$dest_location    = $dest_split[-1]
$dest_type        = $dest_split[2]
$dest_environment = $dest_split[3]


# ═══════════════════════════════════════════════════════════════════════════
# HELPER FUNCTION
# ═══════════════════════════════════════════════════════════════════════════

function Add-DatabaseAlias {
    param (
        [Parameter(Mandatory)] [string]$DbName,
        [Parameter(Mandatory)] [string]$Fqdn,
        [Parameter(Mandatory)] [string]$AccessToken,
        [Parameter(Mandatory)] [string]$Alias,
        [Parameter(Mandatory)] [string]$Domain
    )

    Write-Host "Adding alias '$Alias'..." -ForegroundColor Cyan

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
    
    return $result

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

if (-not [string]::IsNullOrWhiteSpace($DestinationNamespace) -and $DestinationNamespace -ne "manufacturo") {
    $expectedName  = "db-$dest_product-$dest_type-core-$DestinationNamespace-$dest_environment-$dest_location"
    $int_expectedName = "db-$dest_product-$dest_type-integratorplus-$DestinationNamespace-$dest_environment-$dest_location"
    $DestinationAlias = "$Destination-$DestinationNamespace"
    Write-Host "Constructed expected database name patterns:`n" -ForegroundColor Cyan
    Write-Host "  - Core DB: $expectedName`n" -ForegroundColor Gray
    Write-Host "  - Integrator Plus DB: $int_expectedName`n" -ForegroundColor Gray
}else{
    $global:LASTEXITCODE = 1
    throw "DestinationNamespace was empty or manufacturo namespace is not supported"
}

# Default empty InstanceAlias to Destination if not provided
if ([string]::IsNullOrWhiteSpace($InstanceAlias)) {
    $InstanceAlias = $DestinationAlias
    Write-Host "⚠️  InstanceAlias was empty, using Destination '$InstanceAlias' as default" -ForegroundColor Yellow
}
    
if ($DryRun) {
    Write-Host "🔍 DRY RUN: Would adjust databases based on customer prefix:" -ForegroundColor Yellow
    Write-Host "🔍 DRY RUN: Instance Alias: $InstanceAlias" -ForegroundColor Gray
    Write-Host "🔍 DRY RUN: Domain: $Domain" -ForegroundColor Gray
    
    $matchingDbs = $dbs | Where-Object { $_.name -eq $expectedName -or $_.name -eq $int_expectedName }
    Write-Host "🔍 DRY RUN: Would adjust $($matchingDbs.Count) databases:`n" -ForegroundColor Yellow
    foreach ($db in $matchingDbs) {
        Write-Host "  • $($db.name)`n" -ForegroundColor Gray
    }
    Write-Host "`n🔍 DRY RUN: Would add CORS origins and redirect URIs for:`n" -ForegroundColor Yellow
    Write-Host "  • https://$InstanceAlias.manufacturo.$Domain`n" -ForegroundColor Gray
    Write-Host "  • https://api.$InstanceAlias.manufacturo.$Domain`n" -ForegroundColor Gray
    Write-Host "`n🔍 DRY RUN: Database adjustment preview completed.`n" -ForegroundColor Yellow

    if ($DestinationAlias -ne $InstanceAlias){
        Write-Host "  • https://$DestinationAlias.manufacturo.$Domain`n" -ForegroundColor Gray
        Write-Host "  • https://api.$DestinationAlias.manufacturo.$Domain`n" -ForegroundColor Gray
    }

    Write-Host "`n🔍 DRY RUN: Would delete from Integrator Plus:`n" -ForegroundColor Gray
    Write-Host "  • engine.parameter`n" -ForegroundColor Gray
    Write-Host "  • api_keys.entity`n" -ForegroundColor Gray
    Write-Host "  • api_keys.challengedlog`n" -ForegroundColor Gray

    exit 0
}

# Filter based on 'core' DB and customer prefix
Write-Host "Filtering databases based on customer prefix..." -ForegroundColor Cyan
$matchingDbs = $dbs | Where-Object { $_.name -eq $expectedName -or $_.name -eq $int_expectedName }

if ($matchingDbs.Count -eq 0) {
    Write-Host "⚠️  No databases found matching the expected names. No adjustments will be performed.`n" -ForegroundColor Yellow
} else {
    Write-Host "Found $($matchingDbs.Count) matching database(s). Proceeding with adjustments.`n" -ForegroundColor Green
}

foreach ($db in $matchingDbs) {
    $dbName = $db.name

    if ($dbName -eq $expectedName) {
        Write-Host "`nExecuting SQL on DB: $dbName" -ForegroundColor Green
        try {
            # Add the primary customer alias
            $instanceResult = Add-DatabaseAlias -DbName $dbName -Fqdn $dest_fqdn -AccessToken $AccessToken -Alias $InstanceAlias -Domain $Domain
            
            if ($instanceResult) {
                Write-Host "  - CORS Origins Added: $($instanceResult.CORS_Origins_Added)" -ForegroundColor Gray
                Write-Host "  - Redirect URIs Added: $($instanceResult.Redirect_URIs_Added)" -ForegroundColor Gray
                Write-Host "  - Post-Logout URIs Added: $($instanceResult.PostLogout_URIs_Added)" -ForegroundColor Gray
            } else {
                Write-Host "  - No results returned from alias update for '$InstanceAlias'." -ForegroundColor Yellow
            }
        
            # Add the Destination alias if it's different from the customer alias
            if ($DestinationAlias -ne $InstanceAlias) {
                $destinationResult = Add-DatabaseAlias -DbName $dbName -Fqdn $dest_fqdn -AccessToken $AccessToken -Alias $DestinationAlias -Domain $Domain
                if ($destinationResult) {
                    Write-Host "  - CORS Origins Added: $($destinationResult.CORS_Origins_Added)" -ForegroundColor Gray
                    Write-Host "  - Redirect URIs Added: $($destinationResult.Redirect_URIs_Added)" -ForegroundColor Gray
                    Write-Host "  - Post-Logout URIs Added: $($destinationResult.PostLogout_URIs_Added)" -ForegroundColor Gray
                } else {
                    Write-Host "  - No results returned from alias update for '$DestinationAlias'." -ForegroundColor Yellow
                }
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
