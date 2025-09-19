[CmdletBinding()]
param (
	[Parameter(Mandatory = $true)]
	[string]$Cloud,

	[Parameter(Mandatory = $true)]
	[string]$DestinationResourceGroup,

	[Parameter(Mandatory = $true)]
	[string]$DestinationSubscriptionId,

    [Parameter(Mandatory = $true)]
	[string]$SourceResourceGroup,

    [Parameter(Mandatory = $true)]
	[string]$SourceSubscriptionId,

	[switch]$DryRun
)

function Write-MyLog {
    param (
        [string]$Message,
        [string]$Level = "INFO"
    )
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogEntry = "[$Timestamp][$Level] $Message"
    Add-Content -Path /tmp/my_long_script.log -Value $LogEntry
    # You can still use Write-Host for interactive debugging if running manually,
    # but for background execution, Add-Content is key.
    Write-Host $LogEntry
}

if (-not $PSBoundParameters.ContainsKey('DryRun')) {
	$DryRun = $false
}

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

$AzureEndpoint = "https://$AzureDomain"

if ($DryRun) {
	Write-MyLog -Message "🧪 Dry run mode enabled. Skipping actual changes..."
	$AccessToken = "FAKE_ACCESS_TOKEN_TEST"
}
else {
	Write-MyLog -Message "🚀 Running actual operations..."
	# Connect-AzAccount -Environment $Cloud -UseDeviceAuthentication
    # Set-AzContext -SubscriptionId $SourceSubscriptionId
    $SourceSqlServer = az sql server list --subscription $SourceSubscriptionId --query "[?tags.Type == 'Primary'] | [0].name" -o tsv
    $SourceEnvironment = az sql server list --subscription $SourceSubscriptionId --query "[?tags.Type == 'Primary'] | [0].tags.Environment" -o tsv
	# $AccessToken = (Get-AzAccessToken -ResourceUrl $AzureEndpoint).Token
    $AccessToken = (az account get-access-token --resource=$AzureEndpoint --query accessToken --output tsv)
    $PlainTextAccessToken = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($AccessToken))
    Write-Host "DEBUG Token: $PlainTextAccessToken"
    Set-AzContext -SubscriptionId $DestinationSubscriptionId
    $DestSqlServer = az sql server list --subscription $DestinationSubscriptionId --query "[?tags.Type == 'Primary'] | [0].name" -o tsv
    $DestSqlServerFqdn = az sql server list --subscription $DestinationSubscriptionId --query "[?tags.Type == 'Primary'] | [0].fullyQualifiedDomainName" -o tsv
    $DestEnvironment = az sql server list --subscription $DestinationSubscriptionId --query "[?tags.Type == 'Primary'] | [0].tags.Environment" -o tsv
    $DestElasticpool = az sql elastic-pool list --subscription $DestinationSubscriptionId --server $DestSqlServer --resource-group $DestinationResourceGroup --query "[0].name" -o tsv
}

Write-MyLog -Message "🌩️ Cloud: $Cloud"
Write-MyLog -Message "🌩️ AzureEndpoint: $AzureEndpoint"
Write-MyLog -Message "➡️ Source Subscription ID: $SourceSubscriptionId"
Write-MyLog -Message "➡️ Source RG: $SourceResourceGroup"
Write-MyLog -Message "➡️ Source Sql Server: $SourceSqlServer"
Write-MyLog -Message "➡️ Source Environment: $SourceEnvironment"

Write-MyLog -Message "🎯 Dest Subscription ID: $DestinationSubscriptionId"
Write-MyLog -Message "🎯 Dest RG: $DestinationResourceGroup"
Write-MyLog -Message "🎯 Dest Sql Server: $DestSqlServer"
Write-MyLog -Message "🎯 Dest Sql Server FQDN: $DestSqlServerFqdn"
Write-MyLog -Message "🎯 Dest Environment: $DestEnvironment"
Write-MyLog -Message "🎯 Dest Elastic Pool: $DestElasticpool"

if ($DryRun) {
	Write-MyLog -Message "🧪 Dry run mode enabled. Skipping actual changes..."
}
else {
    ## Get list of DBs from Source SQL Server
    try {
        $dbs = az sql db list --subscription $SourceSubscriptionId --resource-group $SourceResourceGroup --server  $SourceSqlServer | ConvertFrom-Json
        $dbs | ForEach-Object -ThrottleLimit 10 -Parallel {
            $source_environment = $using:SourceEnvironment
            $source_server = $using:SourceSqlServer
            $dest_environment = $using:DestEnvironment
            $dest_server = $using:DestSqlServer
            # $dest_rg = $using:DestinationResourceGroup
            $dest_elasticpool = $using:DestElasticpool
            $dest_server_full = $using:DestSqlServerFqdn 
            $AccessToken = $using:AccessToken
            function Write-MyLogInternal { # Give it a slightly different name to avoid confusion
                param (
                    [string]$Message,
                    [string]$Level = "INFO"
                )
                $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                $LogEntry = "[$Timestamp][$Level] $Message"
                Add-Content -Path /tmp/my_long_script.log -Value $LogEntry # Use the passed-in path
                Write-Host $LogEntry
            }
            # Skip master db
            $DbName = $_.name
            Write-MyLogInternal -Message "Access token: $AccessToken"
            if (!$DbName.Contains("restored") -and !$DbName.Contains("master")) {
                $SourceDbName = "$DbName-restored"
                $DestDbName = $DbName.replace("$source_environment", "$dest_environment")
                # TODO: Enable this if we want to copy instead of delete (limit downtime)
                $DestDbName = "$DestDbName-restored"
                # delete destination DB
                # Write-MyLog -Message "🚮 Deleting $DestDbName($dest_server)"
                # az sql db delete --name $DestDbName --resource-group $dest_rg --server $dest_server --subscription $dest_subscription --yes
                Start-Sleep 10
                if ($SourceDbName.Equals("db-mnfro-intd-oneview-qa2-weu-restored")) {
                    Write-MyLogInternal -Message "🔧 Copying $SourceDbName($source_server) to $DestDbName($dest_server)"
                    # Write-MyLogInternal -Message "🔧 Sleeping $SourceDbName($source_server) to $DestDbName($dest_server)"

                    # Start-Sleep 10
                    Invoke-Sqlcmd -AccessToken "$AccessToken" -ServerInstance "$dest_server_full" -Query "CREATE DATABASE [$dest_dbName] AS COPY OF [$source_server].[$SourceDbName] (SERVICE_OBJECTIVE = ELASTIC_POOL( name = [$dest_elasticpool] ));"
                    for ($i = 1; $i -le 600; $i++) {
                        $result = Invoke-Sqlcmd -AccessToken "$AccessToken" -ServerInstance "$dest_server_full" -Query "SELECT state_desc FROM sys.databases WHERE name = '$dest_dbName'"
                        if ($result.state_desc -eq "ONLINE") {
                            Write-Host "Database $DestDbName copied"
                            break
                        } else {
                            Start-Sleep -Seconds 5
                        }
                    }
                    if ($i -eq 600) {
                        Write-Error "Database $DestDbName was not copied in 10 minutes"
                        exit 1
                    }
                    # get list of users
                    $users = Invoke-Sqlcmd -AccessToken "$AccessToken" -ServerInstance "$dest_server_full" -Database $DestDbName -Query "SET NOCOUNT ON; SELECT name FROM sysusers where islogin=1 and issqluser=1 and sid is not null and name!='guest'"
                    # Write-MyLog -Message $users
                    ForEach ($line in $users) {
                        $username = $line.Item(0)
                        Write-Host $username
                        # alter User
                        Invoke-Sqlcmd -AccessToken "$AccessToken" -ServerInstance "$dest_server_full" -Database $DestDbName -Query "ALTER USER [$username] with LOGIN=[$username]"
                    }
                }
            }
        }
    } catch {
        Write-Error "An unexpected error occurred: $($_.Exception.Message)"
        Write-Error "Script stack trace: $($_.ScriptStackTrace)"
        "$(Get-Date) - Unexpected error: $($_.Exception.Message) - StackTrace: $($_.ScriptStackTrace)" | Out-File -FilePath "C:\ScriptErrorLog.log" -Append
        Write-MyLog -Message "SCRIPT_FAILED_WITH_ERROR"
        exit 1
    }
}

Write-MyLog -Message "SCRIPT_COMPLETED_SUCCESSFULLY"