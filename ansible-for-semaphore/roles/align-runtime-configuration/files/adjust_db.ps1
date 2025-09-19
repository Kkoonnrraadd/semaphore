[CmdletBinding()]
param (
	[Parameter(Mandatory = $true)]
	[string]$Cloud,

	[Parameter(Mandatory = $true)]
	[string]$DestinationResourceGroup,

	[Parameter(Mandatory = $true)]
	[string]$DestinationSubscriptionId,

	[Parameter(Mandatory = $true)]
	[string]$DestinationCustomerAlias,

	[Parameter(Mandatory = $true)]
	[string]$DestinationRegionAlias,

	[switch]$DryRun
)

if (-not $PSBoundParameters.ContainsKey('DryRun')) {
	$DryRun = $true
}

Write-Output "🌩️  Cloud: $Cloud"
Write-Output "🎯 Destination Subscription ID: $DestinationSubscriptionId"
Write-Output "🎯 Destination RG: $DestinationResourceGroup"
Write-Output "🎯 Dest Environment Alias: $DestinationCustomerAlias"
Write-Output "🎯 Dest Region Alias: $DestinationRegionAlias"
switch ($Cloud) {
	"AzureCloud" {
		$AzureDomain = "database.windows.net"
		$ManufacturoDomain = "manufacturo.cloud"
	}
	"AzureUSGovernment" {
		$AzureDomain = "database.usgovcloudapi.net"
		$ManufacturoDomain = "manufacturo.us"
	}
	default {
		throw "Unsupported cloud environment: $Cloud"
	}
}

Write-Output "🌐 Azure domain is $AzureDomain"
Write-Output "🌐 Manufacturo domain is $ManufacturoDomain"

if ($DryRun) {
	Write-Output "🧪 Dry run mode enabled. Skipping actual changes..."
	$AccessToken = "FAKE_ACCESS_TOKEN_TEST"
	$DestServer = "DEST_TEST_SERVER"
	$DestServerFqdn = "DEST_TEST_SERVER.FQDOMAIN"
}
else {
	Write-Output "🚀 Running actual operations..."
	Connect-AzAccount -Environment $Cloud
	$AccessToken = (Get-AzAccessToken -ResourceUrl https://$AzureDomain).Token

	$DestAPCName = $(az appconfig list --subscription $DestinationSubscriptionId --query "[].name | [0]" --output tsv)
	$DestAPCNameTokens = $DestAPCName -split "-"
	$DestProduct = $DestAPCNameTokens[1]
	$DestLocation = $DestAPCNameTokens[-1]
	$DestType = $DestAPCNameTokens[2]
	$DestEnvironment = $DestAPCNameTokens[3]

	$DestServer = "srv-$DestProduct-$DestType-$DestEnvironment-$DestLocation"
	$DestServerFqdn = "$DestServer.$AzureDomain"
}

Write-Output "Dest Environment Alias: $DestinationCustomerAlias"
Write-Output "Dest Region Alias: $DestinationRegionAlias"

$RegionAliasQuery = @"
DECLARE @alias NVARCHAR(255) = '$DestinationRegionAlias';
DECLARE @CoreClient NVARCHAR(255);
DECLARE @EboxClient NVARCHAR(255);
DECLARE @SwaggerCoreClientId NVARCHAR(255);
DECLARE @ApiDocsClientId NVARCHAR(255);

--@CoreClient
select @CoreClient=Id from dbo.Clients where ClientId='AndeaCore';
insert into dbo.ClientCorsOrigins(Origin,ClientId) values ( FORMATMESSAGE('https://%s.$ManufacturoDomain', @alias),@CoreClient)
insert into dbo.ClientRedirectUris(RedirectUri,ClientId) values ( FORMATMESSAGE('https://%s.$ManufacturoDomain', @alias),@CoreClient)
insert into dbo.ClientRedirectUris(RedirectUri,ClientId) values ( FORMATMESSAGE('https://%s.$ManufacturoDomain/assets/auth/silent-refresh.html', @alias),@CoreClient)
insert into dbo.ClientPostLogoutRedirectUris(PostLogoutRedirectUri,ClientId) values ( FORMATMESSAGE('https://%s.$ManufacturoDomain', @alias),@CoreClient)

select @CoreClient=Id from dbo.Clients where ClientId='AndeaCore_v2';
insert into dbo.ClientCorsOrigins(Origin,ClientId) values ( FORMATMESSAGE('https://%s.$ManufacturoDomain', @alias),@CoreClient)
insert into dbo.ClientRedirectUris(RedirectUri,ClientId) values ( FORMATMESSAGE('https://%s.$ManufacturoDomain', @alias),@CoreClient)
insert into dbo.ClientRedirectUris(RedirectUri,ClientId) values ( FORMATMESSAGE('https://%s.$ManufacturoDomain/assets/auth/silent-refresh.html', @alias),@CoreClient)
insert into dbo.ClientPostLogoutRedirectUris(PostLogoutRedirectUri,ClientId) values ( FORMATMESSAGE('https://%s.$ManufacturoDomain', @alias),@CoreClient)

--@@EboxClient
select @EboxClient=Id from dbo.Clients where ClientId='eboxApp';
insert into dbo.ClientCorsOrigins(Origin,ClientId) values ( FORMATMESSAGE('https://%s.$ManufacturoDomain/ebox', @alias),@EboxClient)
insert into dbo.ClientRedirectUris(RedirectUri,ClientId) values ( FORMATMESSAGE('https://%s.$ManufacturoDomain/ebox', @alias),@EboxClient)
insert into dbo.ClientRedirectUris(RedirectUri,ClientId) values ( FORMATMESSAGE('https://%s.$ManufacturoDomain/ebox/views/silent-refresh.html', @alias),@EboxClient)
insert into dbo.ClientPostLogoutRedirectUris(PostLogoutRedirectUri,ClientId) values ( FORMATMESSAGE('https://%s.$ManufacturoDomain/ebox', @alias),@EboxClient)

--@SwaggerCoreClientId
select @SwaggerCoreClientId=Id from dbo.Clients where ClientId='AndeaCoreSwaggerUi';
insert into dbo.ClientCorsOrigins(Origin,ClientId) values ( FORMATMESSAGE('https://swagger.%s.$ManufacturoDomain/oauth2-redirect.html', @alias),@SwaggerCoreClientId)
insert into dbo.ClientRedirectUris(RedirectUri,ClientId) values ( FORMATMESSAGE('https://swagger.%s.$ManufacturoDomain/oauth2-redirect.html', @alias),@SwaggerCoreClientId)
insert into dbo.ClientPostLogoutRedirectUris(PostLogoutRedirectUri,ClientId) values ( FORMATMESSAGE('https://swagger.%s.$ManufacturoDomain/oauth2-redirect.html', @alias),@SwaggerCoreClientId)

--@ApiDocsClientId
select @ApiDocsClientId=Id from dbo.Clients where ClientId='apiDocs';
insert into dbo.ClientCorsOrigins(Origin,ClientId) values ( FORMATMESSAGE('https://api.%s.$ManufacturoDomain', @alias),@ApiDocsClientId)
insert into dbo.ClientRedirectUris(RedirectUri,ClientId) values ( FORMATMESSAGE('https://api.%s.$ManufacturoDomain', @alias),@ApiDocsClientId)
insert into dbo.ClientRedirectUris(RedirectUri,ClientId) values ( FORMATMESSAGE('https://api.%s.$ManufacturoDomain/signin-oidc', @alias),@ApiDocsClientId)
insert into dbo.ClientPostLogoutRedirectUris(PostLogoutRedirectUri,ClientId) values ( FORMATMESSAGE('https://api.%s.$ManufacturoDomain', @alias),@ApiDocsClientId)
;
"@

$CustomerAliasQuery = @"
DECLARE @alias NVARCHAR(255) = '$DestinationCustomerAlias';
DECLARE @CoreClient NVARCHAR(255);
DECLARE @EboxClient NVARCHAR(255);
DECLARE @SwaggerCoreClientId NVARCHAR(255);
DECLARE @ApiDocsClientId NVARCHAR(255);

--@CoreClient
select @CoreClient=Id from dbo.Clients where ClientId='AndeaCore';
insert into dbo.ClientCorsOrigins(Origin,ClientId) values ( FORMATMESSAGE('https://%s.$ManufacturoDomain', @alias),@CoreClient)
insert into dbo.ClientRedirectUris(RedirectUri,ClientId) values ( FORMATMESSAGE('https://%s.$ManufacturoDomain', @alias),@CoreClient)
insert into dbo.ClientRedirectUris(RedirectUri,ClientId) values ( FORMATMESSAGE('https://%s.$ManufacturoDomain/assets/auth/silent-refresh.html', @alias),@CoreClient)
insert into dbo.ClientPostLogoutRedirectUris(PostLogoutRedirectUri,ClientId) values ( FORMATMESSAGE('https://%s.$ManufacturoDomain', @alias),@CoreClient)

select @CoreClient=Id from dbo.Clients where ClientId='AndeaCore_v2';
insert into dbo.ClientCorsOrigins(Origin,ClientId) values ( FORMATMESSAGE('https://%s.$ManufacturoDomain', @alias),@CoreClient)
insert into dbo.ClientRedirectUris(RedirectUri,ClientId) values ( FORMATMESSAGE('https://%s.$ManufacturoDomain', @alias),@CoreClient)
insert into dbo.ClientRedirectUris(RedirectUri,ClientId) values ( FORMATMESSAGE('https://%s.$ManufacturoDomain/assets/auth/silent-refresh.html', @alias),@CoreClient)
insert into dbo.ClientPostLogoutRedirectUris(PostLogoutRedirectUri,ClientId) values ( FORMATMESSAGE('https://%s.$ManufacturoDomain', @alias),@CoreClient)

--@@EboxClient
select @EboxClient=Id from dbo.Clients where ClientId='eboxApp';
insert into dbo.ClientCorsOrigins(Origin,ClientId) values ( FORMATMESSAGE('https://%s.$ManufacturoDomain/ebox', @alias),@EboxClient)
insert into dbo.ClientRedirectUris(RedirectUri,ClientId) values ( FORMATMESSAGE('https://%s.$ManufacturoDomain/ebox', @alias),@EboxClient)
insert into dbo.ClientRedirectUris(RedirectUri,ClientId) values ( FORMATMESSAGE('https://%s.$ManufacturoDomain/ebox/views/silent-refresh.html', @alias),@EboxClient)
insert into dbo.ClientPostLogoutRedirectUris(PostLogoutRedirectUri,ClientId) values ( FORMATMESSAGE('https://%s.$ManufacturoDomain/ebox', @alias),@EboxClient)

--@SwaggerCoreClientId
select @SwaggerCoreClientId=Id from dbo.Clients where ClientId='AndeaCoreSwaggerUi';
insert into dbo.ClientCorsOrigins(Origin,ClientId) values ( FORMATMESSAGE('https://swagger.%s.$ManufacturoDomain/oauth2-redirect.html', @alias),@SwaggerCoreClientId)
insert into dbo.ClientRedirectUris(RedirectUri,ClientId) values ( FORMATMESSAGE('https://swagger.%s.$ManufacturoDomain/oauth2-redirect.html', @alias),@SwaggerCoreClientId)
insert into dbo.ClientPostLogoutRedirectUris(PostLogoutRedirectUri,ClientId) values ( FORMATMESSAGE('https://swagger.%s.$ManufacturoDomain/oauth2-redirect.html', @alias),@SwaggerCoreClientId)

--@ApiDocsClientId
select @ApiDocsClientId=Id from dbo.Clients where ClientId='apiDocs';
insert into dbo.ClientCorsOrigins(Origin,ClientId) values ( FORMATMESSAGE('https://api.%s.$ManufacturoDomain', @alias),@ApiDocsClientId)
insert into dbo.ClientRedirectUris(RedirectUri,ClientId) values ( FORMATMESSAGE('https://api.%s.$ManufacturoDomain', @alias),@ApiDocsClientId)
insert into dbo.ClientRedirectUris(RedirectUri,ClientId) values ( FORMATMESSAGE('https://api.%s.$ManufacturoDomain/signin-oidc', @alias),@ApiDocsClientId)
insert into dbo.ClientPostLogoutRedirectUris(PostLogoutRedirectUri,ClientId) values ( FORMATMESSAGE('https://api.%s.$ManufacturoDomain', @alias),@ApiDocsClientId)
;
"@

$TruncateQuery = @"
TRUNCATE TABLE engine.parameter;
TRUNCATE TABLE api_keys.entity;
TRUNCATE TABLE api_keys.challengedlog;
"@

if ($DryRun) {
	Write-Output "🧪 Dry run mode enabled. Skipping actual changes..."
	Write-Output "	I would get the dbs for server: '$dbs = az sql db list --subscription $DestinationSubscriptionId --resource-group $DestinationResourceGroup --server  $DestServer | ConvertFrom-Json'"
	Write-Output "	I would run the following commands for the core database:"
	Write-Output "		Invoke-Sqlcmd -AccessToken $AccessToken -ServerInstance "$DestServerFqdn" -Database $db.name -Query $RegionAliasQuery"
	Write-Output "		Invoke-Sqlcmd -AccessToken $AccessToken -ServerInstance "$DestServerFqdn" -Database $db.name -Query $CustomerAliasQuery"
	Write-Output "	I would run the following commands for the integratorplus|integratorplusext database(s):"
	Write-Output "		Invoke-Sqlcmd -AccessToken $AccessToken -ServerInstance "$DestServerFqdn" -Database $db.name -Query $TruncateQuery"
}
else {
	Write-Output "🚀 Running actual operations..."
	# Get list of DBs from Source SQL Server
	$dbs = az sql db list --subscription $DestinationSubscriptionId --resource-group $DestinationResourceGroup --server  $DestServer | ConvertFrom-Json
	foreach ($db in $dbs) {
		if ($db.name.Contains("core")) {
			Write-Output "🚀 Running core operations on $db.name"
			# Invoke-Sqlcmd -AccessToken $AccessToken -ServerInstance "$DestServerFqdn" -Database $db.name -Query $RegionAliasQuery
			# Invoke-Sqlcmd -AccessToken $AccessToken -ServerInstance "$DestServerFqdn" -Database $db.name -Query $CustomerAliasQuery
		}
		if ($db.name.Contains("integratorplus") -And (!$db.name.Contains("integratorplusext"))) {
			Write-Output "🚀 Running integrator operations on $db.name"
			# Invoke-Sqlcmd -AccessToken $AccessToken -ServerInstance "$DestServerFqdn" -Database $db.name -Query $TruncateQuery
		}
	}
}
