[CmdletBinding()]
param (
	[Parameter(Mandatory = $true)]
	[string]$Cloud,

	[Parameter(Mandatory = $true)]
	[string]$DestinationResourceGroup,

	[Parameter(Mandatory = $true)]
	[string]$DestinationSubscriptionId,

	[Parameter(Mandatory = $true)]
	[string]$SourceSubscriptionId,

	[switch]$DryRun
)

if (-not $PSBoundParameters.ContainsKey('DryRun')) {
	$DryRun = $true
}

Write-Output "🌩️  Cloud: $Cloud"
Write-Output "🎯 Source Subscription ID: $SourceSubscriptionId"
Write-Output "🎯 Destination Subscription ID: $DestinationSubscriptionId"
Write-Output "🎯 Destination RG: $DestinationResourceGroup"
switch ($Cloud) {
	"AzureCloud" {
		$AzureDomain = "database.windows.net"
	}
	"AzureUSGovernment" {
		$AzureDomain = "database.usgovcloudapi.net"
	}
	default {
		throw "Unsupported cloud environment: $Cloud"
	}
}

Write-Output "🌐 Azure domain is $AzureDomain"

if ($DryRun) {
	Write-Output "🧪 Dry run mode enabled. Skipping actual changes..."
	$SourceEnvironment = "SOURCE_ENVIRONMENT_TEST"
	$DestLocation = "DEST_LOCATION_TEST"
	$DestEnvironment = "DEST_ENVIRONMENT_TEST"
	$DestServer = "DEST_TEST_SERVER"
	$DestServerFqdn = "DEST_TEST_SERVER.FQDOMAIN"
}
else {
	Write-Output "🚀 Running actual operations..."
	Connect-AzAccount -Environment $Cloud
	$AccessToken = (Get-AzAccessToken -ResourceUrl https://$AzureDomain).Token

	$SourceAPCName = $(az appconfig list --subscription $SourceSubscriptionId --query "[].name | [0]" --output tsv)
	$SourceAPCNameTokens = $SourceAPCName -split "-"
	$SourceEnvironment = $SourceAPCNameTokens[3]

	$DestAPCName = $(az appconfig list --subscription $DestinationSubscriptionId --query "[].name | [0]" --output tsv)
	$DestAPCNameTokens = $DestAPCName -split "-"
	$DestLocation = $DestAPCNameTokens[-1]
	$DestEnvironment = $DestAPCNameTokens[3]

	$DestServer = $(az sql server list --subscription "$DestinationSubscriptionId" --query "[?tags.Type == 'Primary'] | [0].name" --output tsv)
	$DestServerFqdn = $(az sql server list --subscription "$DestinationSubscriptionId" --query "[?tags.Type == 'Primary'] | [0].fullyQualifiedDomainName" -o tsv)
}

$QueryString = @"
DECLARE
@source_env_name NVARCHAR(255) = '$SourceEnvironment',
@destination_env_name NVARCHAR(255) = '$DestEnvironment',
@location NVARCHAR(100) = '$DestLocation',
@COMMAND NVARCHAR(4000),
@roleName NVARCHAR(100),
@DatabaseUserName NVARCHAR(100),
@sourceUser NVARCHAR(100),
@destUser NVARCHAR(100),
@getid2 CURSOR,
@getid CURSOR;
DECLARE @users TABLE(sourceName NVARCHAR(100),dest NVARCHAR(100))
BEGIN


INSERT INTO @users
VALUES
(FORMATMESSAGE('%s-DBContributors', @source_env_name),FORMATMESSAGE('%s-DBContributors', @destination_env_name))  ,
(FORMATMESSAGE('%s-DBReaders', @source_env_name),FORMATMESSAGE('%s-DBReaders', @destination_env_name));

SET @getid = CURSOR FOR
SELECT * FROM @users;
OPEN @getid
FETCH NEXT
	FROM @getid INTO @sourceUser, @destUser
	WHILE @@FETCH_STATUS = 0
	BEGIN

		SET @COMMAND = FORMATMESSAGE('CREATE USER [%s] FROM EXTERNAL PROVIDER',@destUser);
		SELECT @COMMAND;
		EXEC (@COMMAND);

		SET @getid2 = CURSOR FOR
		SELECT DP1.name AS DatabaseRoleName,
		   isnull (DP2.name, 'No members') AS DatabaseUserName
		 FROM sys.database_role_members AS DRM
		 RIGHT OUTER JOIN sys.database_principals AS DP1
		   ON DRM.role_principal_id = DP1.principal_id
		 LEFT OUTER JOIN sys.database_principals AS DP2
		   ON DRM.member_principal_id = DP2.principal_id
		WHERE DP1.type = 'R'
		and DP2.name = @sourceUSer
		ORDER BY DP1.name;

		OPEN @getid2
		FETCH NEXT
		FROM @getid2 INTO @roleName, @DatabaseUserName
		WHILE @@FETCH_STATUS = 0
		BEGIN
			SELECT @roleName;
			SET @COMMAND = FORMATMESSAGE('EXEC sp_addrolemember [%s], [%s]', @roleName, @destUser);
			SELECT @COMMAND;
			EXEC (@COMMAND);
			FETCH NEXT
			FROM @getid2 INTO @roleName, @DatabaseUserName
		END
		select @destUser
		IF EXISTS (
		  select top 1 1
			FROM    sys.schemas s
			INNER JOIN sys.sysusers u
			ON u.uid = s.principal_id
		where u.name=@sourceUser and s.name='ext'
		) BEGIN
			SET @COMMAND = FORMATMESSAGE('ALTER AUTHORIZATION ON SCHEMA::ext TO [%s]', @destUser);
			SELECT @COMMAND;
			EXEC (@COMMAND);
		END

		SET @COMMAND = FORMATMESSAGE('DROP USER [%s]',@sourceUser);
		SELECT @COMMAND;
		EXEC (@COMMAND);

	FETCH NEXT
	FROM @getid INTO  @sourceUser, @destUser
	END
END;
"@

if ($DryRun) {
	Write-Output "🧪 Dry run mode enabled. Skipping actual changes..."
	Write-Output "	I would get the dbs for server: '$dbs = az sql db list --subscription $DestinationSubscriptionId --resource-group $DestinationResourceGroup --server  $DestServer | ConvertFrom-Json'"
	Write-Output "	I would run the following commands for any database except master:"
	Write-Output "		Invoke-Sqlcmd -AccessToken $AccessToken -ServerInstance "$DestServerFqdn" -Database $db.name -Query $QueryString"
}
else {
	Write-Output "🚀 Running actual operations..."
	Connect-AzAccount -Environment $Cloud
	$AccessToken = (Get-AzAccessToken -ResourceUrl https://$AzureDomain).Token
	# Get list of DBs from Destination SQL Server
	$dbs = az sql db list --subscription $DestSubscriptionId --resource-group $DestinationResourceGroup --server  $DestServer | ConvertFrom-Json
	foreach ($db in $dbs) {
		# Skip master db
		if (!$db.name.Contains("master")) {
			Write-Output "🚀 Running user permission operations on $db.name"
			# Invoke-Sqlcmd -AccessToken $AccessToken -ServerInstance "$DestServerFqdn" -Database $db.name -Query $QueryString
		}
	}
}
