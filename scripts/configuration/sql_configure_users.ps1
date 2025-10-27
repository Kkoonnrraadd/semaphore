<#
.Description
This script handles initialization of databases and setting SQL Vulnerability Assessment baselines.
It uses Azure CLI as a source of authentication so it is required to be logged in before using this script.

.PARAMETER Environments
List of environment names. By default uses all accessible.

.PARAMETER EnvironmentsExclude
List of environments to exclude.

.PARAMETER Databases
List of database names. By default takes all databases.
It matches databases which contains at least one provided value.

.PARAMETER DatabasesExclude
List of database names to exclude.
It matches databases which contains at least one provided value.

.PARAMETER Clients
List of clients.
It matches databases which are assigned to one of provided clients.

.PARAMETER Type
Wanted type of database. Defaults to both primary and replica databases.
Accepted values: Both, Primary, Replica.

.PARAMETER BaselinesMode
What mode should be applied to baselines. Baselines are always enabled by default.
Accepted values: On, Off, Only.

.PARAMETER FirstRun
Indicates if this should be run in "First Run Mode". It executes required baseline initialization. It is disabled by default.
Accepted values: On, Off, Only.

.PARAMETER AutoApprove
Skips manual approval.

.PARAMETER StopOnFailure
Script will stop if there will be any failure during execution. By default it is allowed for commands to fail.

.PARAMETER ThrottleLimit
Indicates how many databases should be processed in parallel. Defaults to 5.
For processing databases in sequence set this parameter to 1.

.PARAMETER Help
Show this help page.

.EXAMPLE
sql_database_config.ps1 -Environments wus001,wus002 -Databases eworkin-plus,sequencing -ThrottleLimit 10

Runs script on wus001 and wus002 environments only for databases matching either eworkin-plus or sequencing. Processes 10 databases at a time.

.EXAMPLE
sql_database_config.ps1 -EnvironmentsExclude eus001,eus002 -Databases eworkin-plus

Runs script on all environments besides eus001 and eus002 and also filters out all databases matching eworkin-plus.

.EXAMPLE
sql_database_config.ps1 -Type Primary -BaselinesMode Off -AutoApprove

Runs script on all primary databases on all environments but without baselines. Also skips manual approval.

.EXAMPLE
sql_database_config.ps1 -BaselinesMode Only -FirstRun On

Runs only baselines setup including "First Run Mode" steps
#> 
param(
  [Parameter()][object] $Destination = "",
  [Parameter()][object] $EnvironmentsExclude = "",
  [Parameter()][object] $Databases = "All",
  [Parameter()][object] $DatabasesExclude = "",
  [Parameter()][object] $DestinationNamespace = "",
  [Parameter()][ValidateSet("Both", "Primary", "Replica")] $Type = "Both",
  [Parameter()][ValidateSet("On", "Off", "Only")] $BaselinesMode = "On",
  [Parameter()][ValidateSet("On", "Off", "Only")] $FirstRun = "Off",
  [Parameter()][switch] $AutoApprove = $false,
  [Parameter()][switch] $StopOnFailure = $false,
  [Parameter()][switch] $Help = $false,
  [Parameter()][int] $ThrottleLimit = 10,
  [Parameter()][switch] $DryRun = $false,
  [Parameter()][switch] $Revert = $false,
  [AllowEmptyString()][string] $EnvironmentToRevert = "",
  [AllowEmptyString()][string] $SourceNamespace = ""
)

# Helper function for quiet logging (only shows important messages in production)
function Write-ScriptLog {
    param(
        [string]$Message,
        [ValidateSet("Info", "Success", "Warning", "Error", "Progress")]
        [string]$Level = "Info",
        [switch]$Force  # Always show, even in quiet mode
    )
    
    # In production mode (not DryRun), only show Progress, Success, Warning, Error, or Force messages
    if (-not $DryRun -and -not $Force -and $Level -eq "Info") {
        return
    }
    
    $color = switch ($Level) {
        "Info" { "Cyan" }
        "Success" { "Green" }
        "Warning" { "Yellow" }
        "Error" { "Red" }
        "Progress" { "Gray" }
    }
    
    Write-Host $Message -ForegroundColor $color
}

if ($DestinationNamespace -eq "manufacturo") {
    $global:LASTEXITCODE = 1
    throw "DestinationNamespace can not be PROD"
    # $DestinationNamespace = ""
}

if ($Revert) {
    if ($DryRun) {
        Write-Host "`n🔍 DRY RUN - REVERT MODE - SQL Configure Users" -ForegroundColor Yellow
        Write-Host "===============================================" -ForegroundColor Yellow
        Write-Host "Would remove SQL user configurations for environment: $EnvironmentToRevert" -ForegroundColor Yellow
        if (-not [string]::IsNullOrWhiteSpace($SourceNamespace)) {
            Write-Host "Multitenant: $SourceNamespace" -ForegroundColor Yellow
        }
        Write-Host "No actual SQL user removal will be performed" -ForegroundColor Yellow
    } else {
        Write-Host "`n🔄 REVERT MODE - SQL Configure Users" -ForegroundColor Cyan
        Write-Host "Environment: $EnvironmentToRevert$(if ($SourceNamespace) {" | Multitenant: $SourceNamespace"})" -ForegroundColor Cyan
    }
} elseif ($DryRun) {
    Write-Host "`n🔍 DRY RUN MODE - SQL Configure Users" -ForegroundColor Yellow
    Write-Host "=====================================" -ForegroundColor Yellow
    Write-Host "No actual SQL user configuration will be performed" -ForegroundColor Yellow
} else {
    Write-Host "`n🔧 SQL Configure Users" -ForegroundColor Cyan
    Write-Host "Environment: $Destination | Client: $DestinationNamespace" -ForegroundColor Cyan
}

if ($Help) {
  Get-Help $PSCommandPath -Detailed
  exit 0
}
if ($StopOnFailure) {
  $ErrorActionPreference = "Stop"
}

function run_sql_query() {
  param(
    [Parameter(Mandatory = $true)][string] $Server,
    [Parameter(Mandatory = $true)][string] $Query,
    [Parameter(Mandatory = $true)][string] $Database,
    [Parameter(Mandatory = $true)][string] $Token
  )
  switch (az account show --query "environmentName" -o tsv) {
    "AzureCloud" { $sql_domain = "database.windows.net"; break }
    "AzureUSGovernment" { $sql_domain = "database.usgovcloudapi.net"; break }
    Default { Write-Error "Cloud not found" }
  }
  :inner for ($retry_count = 3; $retry_count -gt 0; $retry_count--) {
    try {
      Invoke-SqlCmd -ServerInstance "$Server.$sql_domain" -Database "$Database" -AccessToken "$Token" -Query "$Query" -ErrorAction SilentlyContinue
      break inner
    }
    catch {
      Write-Host -ForegroundColor Red "$Database on $Server failed, retries left: $retry_count"
    }
  }
  if ($StopOnFailure -and $retry_count -eq 0) {
    throw "Failed to run script on $Server - $Database"
  }
}

function set_baseline() {
  param(
    [Parameter(Mandatory = $true)][string] $SubscriptionId,
    [Parameter(Mandatory = $true)][string] $ResourceGroupName,
    [Parameter(Mandatory = $true)][string] $ServerName,
    [Parameter(Mandatory = $true)][string] $DatabaseName,
    [Parameter()][string] $EndpointSuffix = "",
    [Parameter()][string] $Method = "POST",
    [Parameter()][object] $Body = $null
  )
  switch (az account show --query "environmentName" -o tsv) {
    "AzureCloud" { $api_address = "management.azure.com"; break }
    "AzureUSGovernment" { $api_address = "management.usgovcloudapi.net"; break }
    Default { Write-Error "Cloud not found" }
  }
  $Uri = "https://$api_address/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Sql/servers/$ServerName/databases/$DatabaseName/sqlVulnerabilityAssessments/default${EndpointSuffix}?api-version=2022-08-01-preview"  
  az rest --method "$Method" --uri "$Uri" --body ($Body | ConvertTo-Json -Depth 10) --only-show-errors -o none
}

$Type = [cultureinfo]::GetCultureInfo("en-US").TextInfo.ToTitleCase($Type)
$BaselinesMode = [cultureinfo]::GetCultureInfo("en-US").TextInfo.ToTitleCase($BaselinesMode)
$FirstRun = [cultureinfo]::GetCultureInfo("en-US").TextInfo.ToTitleCase($FirstRun)
if ($Destination -eq "All") { $env_regex = ".*" } else { $env_regex = ".*($($Destination -join "|")).*" }
if ($EnvironmentsExclude -eq "") { $env_exclude_regex = "^$" } else { $env_exclude_regex = ".*($($EnvironmentsExclude -join "|")).*" }
if ($Databases -eq "All") { $db_regex = ".*" } else { $db_regex = "$($Databases -join "|")" }
if ($DatabasesExclude -eq "") { $db_exclude_regex = "^$" } else { $db_exclude_regex = "$($DatabasesExclude -join "|")" }
if ($Type -eq "Replica") { $kind = "inner" } else { $kind = "leftouter" }
# Build ClientName filter based on namespace convention
$client_filter = if ($DestinationNamespace -eq "") {
    "tags.ClientName == ''"
} else {
    "tags.ClientName == '$DestinationNamespace'"
}

$graph_query = "
  resources
  | where type =~ 'microsoft.sql/servers/databases'
  | where tags.Type matches regex 'Primary'
  | join kind=$kind (
      resources 
      | where type =~ 'microsoft.sql/servers/databases'
      | where tags.Type matches regex 'Replica'
  ) on name
  | join kind=leftouter (
      resources
      | where type =~ 'microsoft.sql/servers/databases'
      | where extract('(srv-[^/]*)', 1, id) contains 'secondary'
  ) on name
  | join kind=leftouter (
      resources
      | where type =~ 'microsoft.containerservice/managedclusters'
      | where tags.Type == 'Primary'
  ) on subscriptionId
  | join kind=leftouter (
      resources
      | where type =~ 'microsoft.keyvault/vaults'
      | where tags.Type == 'Primary'
      | where resourceGroup !contains 'secondary'
  ) on subscriptionId
  | where name matches regex '$db_regex' and not(name matches regex '$db_exclude_regex')
  | where tags.Environment matches regex '$env_regex' and not(tags.Environment matches regex '$env_exclude_regex')
  | where $client_filter
  | project name, resourceGroup, secondaryResourceGroup = resourceGroup2, environment = tags.Environment, subscriptionId, main_server = extract('(srv-[^/]*)', 1, id), replica_server = extract('(srv-[^/]*)', 1, id1), secondary_server = extract('(srv-[^/]*)', 1, id2), service = tags.Service, kv_name = name4, client_name = tags.ClientName
"
$dbs = az graph query -q $graph_query --query "data" --first 1000 | ConvertFrom-Json

# Filter out landlord database
$dbs = $dbs | Where-Object { $_.name -notlike "*landlord*" }

$dbs | Format-Table -Property name, main_server, replica_server, secondary_server
$count = $dbs.Count

if ($count -eq 0) {
  Write-Host -ForegroundColor Red "No databases found"
  exit 0
}
else {
  Write-Host "Count: $count`n"
  Write-Host -ForegroundColor Yellow "Mode: $Type`n"
}

if ($DryRun -and !$Revert) {
    Write-Host "`n🔍 DRY RUN: DISCOVERING SQL USER CONFIGURATIONS" -ForegroundColor Yellow
    Write-Host "=============================================" -ForegroundColor Yellow
    
    Write-Host "🔍 DRY RUN: Found $count databases to configure:" -ForegroundColor Yellow
    foreach ($db in $dbs) {
        $env = $db.environment
        $client_name = $db.client_name
        $service = $db.service
        $name = $db.name
        $main_server = $db.main_server
        
        Write-Host "`n  🔍 Database: $name" -ForegroundColor Cyan
        Write-Host "    Server: $main_server" -ForegroundColor Gray
        Write-Host "    Service: $service" -ForegroundColor Gray
        Write-Host "    Environment: $env" -ForegroundColor Gray
        if ($client_name) {
            Write-Host "    Client: $client_name" -ForegroundColor Gray
        }
        
        # Show what groups would be created
        $dbContributorsGroup = if ($client_name) { "$env-$client_name-DBContributors" } else { "$env-DBContributors" }
        $dbReadersGroup = if ($client_name) { "$env-$client_name-DBReaders" } else { "$env-DBReaders" }
        
        Write-Host "    Would create/configure users:" -ForegroundColor Yellow
        Write-Host "      • $dbContributorsGroup (Contributors)" -ForegroundColor Gray
        Write-Host "      • $dbReadersGroup (Readers)" -ForegroundColor Gray
        
        Write-Host "    Would configure roles:" -ForegroundColor Yellow
        Write-Host "      • db_executor (Execute permissions)" -ForegroundColor Gray
        Write-Host "      • db_datareader (Read permissions)" -ForegroundColor Gray
        Write-Host "      • db_datawriter (Write permissions for contributors)" -ForegroundColor Gray
        
        Write-Host "    Would grant permissions:" -ForegroundColor Yellow
        Write-Host "      • VIEW DEFINITION" -ForegroundColor Gray
        Write-Host "      • SHOWPLAN" -ForegroundColor Gray
        Write-Host "      • VIEW DATABASE PERFORMANCE STATE (contributors only)" -ForegroundColor Gray
        
        # Show which MIs would be configured
        Write-Host "    Would configure Managed Identities:" -ForegroundColor Yellow
        $mi_access_map = @{
          'alertwise'           = @('alertwise', 'alert-wise')
          'eworkin-plus'        = @('eworkin-plus', 'correctiveactions', 'corrective-actions', 'integratorplus', 'integrator-plus', 'filehosting', 'report', 'oneview', 'equipment', 'sequencing', 'costing', 'mrp', 'document-management', 'action-boards', 'alertwise', 'alert-wise', 'dispatching', 'text-to-sql')
          'gateway'             = @('gateway')
          'integratorplus'      = @('integratorplus', 'integrator-plus', 'report', 'alertwise', 'alert-wise')
          'integratorplusext'   = @('integratorplus', 'integrator-plus', 'report', 'alertwise', 'alert-wise', 'text-to-sql')
          'oneview'             = @('oneview', 'integratorplus', 'integrator-plus')
          'core'                = @('core', 'platform', 'report', 'alertwise', 'alert-wise', 'integratorplus', 'integrator-plus')
          'report'              = @('report')
          'sequencing'          = @('sequencing')
          'filehosting'         = @('filehosting')
        }
        
        if ($mi_access_map.ContainsKey($service)) {
            $mi_services = $mi_access_map[$service]
            Write-Host "      Service '$service' maps to MI patterns:" -ForegroundColor Gray
            foreach ($mi_service in $mi_services) {
                $mi_pattern = if ($client_name) { "${mi_service}-${client_name}-mnfro*" } else { "${mi_service}-mnfro*" }
                Write-Host "        • $mi_pattern" -ForegroundColor Gray
            }
            Write-Host "      • devops* (always included)" -ForegroundColor Gray
        } else {
            Write-Host "      • No specific MI mapping for service '$service'" -ForegroundColor Gray
            Write-Host "      • devops* (always included)" -ForegroundColor Gray
        }
        
        if ($Type -eq "Replica") {
            Write-Host "    Would configure replica access:" -ForegroundColor Yellow
            $baseUserName = ($service -replace "-", "").ToLower()
            $staticReplicaUserName = "${baseUserName}-replica"
            if ($client_name) {
                $staticReplicaUserName = "${client_name}-${staticReplicaUserName}"
            }
            Write-Host "      • $staticReplicaUserName (Replica access)" -ForegroundColor Gray
        }
    }
    
    Write-Host "`n🔍 DRY RUN: SQL user configuration preview completed." -ForegroundColor Yellow
    exit 0
}

if (!$AutoApprove) {
  Write-Host -ForegroundColor Yellow "Databases listed above will be processed. Would you like to proceed? (Y/n) " -NoNewline
  $answer = Read-Host
  if ($answer -notmatch "^y$|^Y$") { exit 0 }
}

$mi_access_map = @{
  'alertwise'           = @('alertwise', 'alert-wise')
  'eworkin-plus'        = @('eworkin-plus', 'correctiveactions', 'corrective-actions', 'integratorplus', 'integrator-plus', 'filehosting', 'report', 'oneview', 'equipment', 'sequencing', 'costing', 'mrp', 'document-management', 'action-boards', 'alertwise', 'alert-wise', 'dispatching', 'text-to-sql')
  'gateway'             = @('gateway')
  'integratorplus'      = @('integratorplus', 'integrator-plus', 'report', 'alertwise', 'alert-wise')
  'integratorplusext'   = @('integratorplus', 'integrator-plus', 'report', 'alertwise', 'alert-wise', 'text-to-sql')
  'oneview'             = @('oneview', 'integratorplus', 'integrator-plus')
  'core'                = @('core', 'platform', 'report', 'alertwise', 'alert-wise', 'integratorplus', 'integrator-plus')
  'report'              = @('report')
  'sequencing'          = @('sequencing')
  'filehosting'         = @('filehosting')
}
switch (az account show --query "environmentName" -o tsv) {
  "AzureCloud" { $sql_domain = "database.windows.net"; break }
  "AzureUSGovernment" { $sql_domain = "database.usgovcloudapi.net"; break }
  Default { Write-Error "Cloud not found" }
}
$token = az account get-access-token --resource "https://$sql_domain" --query "accessToken" --output tsv
$run_sql_query = ${function:run_sql_query}.ToString()
$set_baseline = ${function:set_baseline}.ToString()
# For dry run in revert mode, show summary before processing
if ($DryRun -and $Revert) {
  Write-Host "`n🔍 DRY RUN SUMMARY - REVERT OPERATIONS" -ForegroundColor Yellow
  Write-Host "=======================================" -ForegroundColor Yellow
  Write-Host "Environment to revert: $EnvironmentToRevert" -ForegroundColor Gray
  Write-Host "Multitenant: $SourceNamespace" -ForegroundColor Gray
  Write-Host "Databases to process: $count" -ForegroundColor Gray
  Write-Host "`nOperations that would be performed:" -ForegroundColor Yellow
  Write-Host "  • Remove AAD group users: $EnvironmentToRevert-DBContributors, $EnvironmentToRevert-DBReaders" -ForegroundColor Gray
  Write-Host "  • Remove replica user: replicaReader" -ForegroundColor Gray
  Write-Host "  • Remove all users containing '$($EnvironmentToRevert.ToLower())'" -ForegroundColor Gray
  Write-Host "  • Remove static replica users (where applicable)" -ForegroundColor Gray
  Write-Host "`nProcessing databases..." -ForegroundColor Yellow
}

0..$($count - 1) | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
  ${function:run_sql_query} = $using:run_sql_query
  ${function:set_baseline} = $using:set_baseline
  $dbs = $using:dbs
  $token = $using:token
  $Type = $using:Type
  $BaselinesMode = $using:BaselinesMode
  $FirstRun = $using:FirstRun
  $StopOnFailure = $using:StopOnFailure
  $count = $using:count
  $mi_access_map = $using:mi_access_map
  $Revert = $using:Revert
  $EnvironmentToRevert = $using:EnvironmentToRevert
  $SourceNamespace = $using:SourceNamespace
  $DryRun = $using:DryRun
  $sub = $dbs[$_].subscriptionId
  $name = $dbs[$_].name
  $resourceGroup = $dbs[$_].resourceGroup
  $secondaryResourceGroup = $dbs[$_].secondaryResourceGroup
  $service = $dbs[$_].service
  $main_server = $dbs[$_].main_server
  $replica_server = $dbs[$_].replica_server
  $secondary_server = $dbs[$_].secondary_server
  $env = $dbs[$_].environment
  $key_vault_name = $dbs[$_].kv_name
  $client_name = $dbs[$_].client_name
  $baseUserName = ($service -replace "-", "").ToLower()
  $staticReplicaUserName = "${baseUserName}-replica"
  $kv_keys_prefix = [cultureinfo]::GetCultureInfo("en-US").TextInfo.ToTitleCase($baseUserName)
  if ($client_name) {
    $kv_keys_prefix = "${client_name}-${kv_keys_prefix}"
    $staticReplicaUserName = "${client_name}-${staticReplicaUserName}"
  }

  # Only show progress indicator for production runs (not every detail)
  if (-not $DryRun) {
    Write-Host "[$($_+1)/$count] $name" -ForegroundColor Gray
  }

  # REVERT MODE: Remove SQL user configurations
  if ($Revert) {
    # Construct the full environment name to revert
    $FullEnvironmentToRevert = if ($SourceNamespace -eq "manufacturo") {
        # Special handling for "manufacturo" - it doesn't include multitenant in the environment name
        $EnvironmentToRevert
    } else {
        "$EnvironmentToRevert-$SourceNamespace"
    }
    
    # For revert mode, construct static replica user name based on the environment being reverted
    # This ensures we remove the old configuration, not the new one being configured
    $revertStaticReplicaUserName = "${baseUserName}-replica"
    if ($SourceNamespace -ne "manufacturo") {
        $revertStaticReplicaUserName = "${MultitenantToRevert}-${revertStaticReplicaUserName}"
    }

    if ($DryRun) {
      # In dry run mode, just show a simple progress indicator
      Write-Host "🔍 Processing: $name" -ForegroundColor Gray
    } else {
      # Remove AAD group users (DBContributors and DBReaders)
      $query = "
        -- Remove users from roles first
        IF EXISTS (SELECT * FROM sys.database_principals WHERE type = 'X' and name = '$FullEnvironmentToRevert-DBContributors')
        BEGIN
          EXEC sp_droprolemember [db_executor], [$FullEnvironmentToRevert-DBContributors];
          EXEC sp_droprolemember [db_datareader], [$FullEnvironmentToRevert-DBContributors];
          EXEC sp_droprolemember [db_datawriter], [$FullEnvironmentToRevert-DBContributors];
          EXEC sp_droprolemember [db_owner], [$FullEnvironmentToRevert-DBContributors];
        END

        IF EXISTS (SELECT * FROM sys.database_principals WHERE type = 'X' and name = '$FullEnvironmentToRevert-DBReaders')
        BEGIN
          EXEC sp_droprolemember [db_executor], [$FullEnvironmentToRevert-DBReaders];
          EXEC sp_droprolemember [db_datareader], [$FullEnvironmentToRevert-DBReaders];
        END

        -- Drop users
        IF EXISTS (SELECT * FROM sys.database_principals WHERE type = 'X' and name = '$FullEnvironmentToRevert-DBContributors')
          DROP USER [$FullEnvironmentToRevert-DBContributors];

        IF EXISTS (SELECT * FROM sys.database_principals WHERE type = 'X' and name = '$FullEnvironmentToRevert-DBReaders')
          DROP USER [$FullEnvironmentToRevert-DBReaders];

        -- Remove replica users
        IF EXISTS (SELECT * FROM sys.database_principals WHERE type = 'S' and name = 'replicaReader')
        BEGIN
          EXEC sp_droprolemember [db_datareader], [replicaReader];
          DROP USER [replicaReader];
        END
      "
      # Quiet mode: no verbose output
      run_sql_query -Server $main_server -Query $query -Database $name -Token $token
      
      # Remove static replica users if they exist
      if ($replica_server) {
        $replicaUserQuery = "
          -- Remove static replica user from database
          IF EXISTS (SELECT * FROM sys.database_principals WHERE type = 'S' and name = '$revertStaticReplicaUserName')
          BEGIN
            EXEC sp_droprolemember [db_datareader], [$revertStaticReplicaUserName];
            DROP USER [$revertStaticReplicaUserName];
          END
          
          -- Remove static replica user login from master database
          IF EXISTS (SELECT * FROM master.sys.sql_logins WHERE name = '$revertStaticReplicaUserName')
          BEGIN
            DROP LOGIN [$revertStaticReplicaUserName];
          END
        "
        run_sql_query -Server $main_server -Query $replicaUserQuery -Database $name -Token $token
        
        # Also remove from replica server if it exists
        if ($replica_server) {
          $replicaServerQuery = "
            -- Remove static replica user login from replica master database
            IF EXISTS (SELECT * FROM master.sys.sql_logins WHERE name = '$revertStaticReplicaUserName')
            BEGIN
              DROP LOGIN [$revertStaticReplicaUserName];
            END
          "
          run_sql_query -Server $replica_server -Query $replicaServerQuery -Database "master" -Token $token
        }
      }
    }

     # DYNAMIC: Get all users containing the environment name from database and remove them
     $environmentPattern = $EnvironmentToRevert.ToLower()
     if (-not $DryRun) {
       
       # Get all users containing the environment name from database
       $getUsersQuery = "SELECT name FROM sys.database_principals WHERE name LIKE '%$environmentPattern%'"
       $usersToRemove = run_sql_query -Server $main_server -Query $getUsersQuery -Database $name -Token $token
       
       if ($usersToRemove) {
         # Remove each user (quiet mode - no verbose output)
         foreach ($user in $usersToRemove) {
           $userName = $user.name
           
           $removeUserQuery = "
             -- Remove user from all roles first (ignore errors if not in role)
             BEGIN TRY
               EXEC sp_droprolemember 'db_executor', [$userName];
             END TRY
             BEGIN CATCH
             END CATCH
             
             BEGIN TRY
               EXEC sp_droprolemember 'db_datareader', [$userName];
             END TRY
             BEGIN CATCH
             END CATCH
             
             BEGIN TRY
               EXEC sp_droprolemember 'db_datawriter', [$userName];
             END TRY
             BEGIN CATCH
             END CATCH
             
             BEGIN TRY
               EXEC sp_droprolemember 'db_ddladmin', [$userName];
             END TRY
             BEGIN CATCH
             END CATCH
             
             BEGIN TRY
               EXEC sp_droprolemember 'db_owner', [$userName];
             END TRY
             BEGIN CATCH
             END CATCH
             
             -- Drop the user
             IF EXISTS (SELECT * FROM sys.database_principals WHERE name = '$userName')
             BEGIN
               DROP USER [$userName];
               PRINT 'Successfully removed user: $userName';
             END
             ELSE
             BEGIN
               PRINT 'User not found: $userName';
             END
           "
           
           run_sql_query -Server $main_server -Query $removeUserQuery -Database $name -Token $token
         }
       } else {
         Write-Host "No users containing '$environmentPattern' found to remove" -ForegroundColor Yellow
       }
     }

    if (-not $DryRun) {
      Write-Host "✅ Revert completed for database: $name" -ForegroundColor Green
    }
    return  # Skip the normal configuration logic in revert mode
  }

  $mi_local_services = @()
  $all_mis = az identity list --subscription $sub --query "[].name" -o tsv
  foreach ($mi_service in $mi_access_map."$service") {
    $mi_pattern = if ($client_name) { "${mi_service}-${client_name}-mnfro*" } else { "${mi_service}-mnfro*" }
    $mi_name = $all_mis | Where-Object { $_ -like "$mi_pattern" }
    $mi_local_services += $mi_name
  }
  $mi_local_services += $all_mis | Where-Object { $_ -like "devops*" }

  if (("Both", "Primary") -contains $Type -and $BaselinesMode -ne "Only") {
    
    # Determine group names based on client_name
    $dbContributorsGroup = if ($client_name) { "$env-$client_name-DBContributors" } else { "$env-DBContributors" }
    $dbReadersGroup = if ($client_name) { "$env-$client_name-DBReaders" } else { "$env-DBReaders" }

    $query = "
      IF NOT EXISTS (SELECT * FROM sys.database_principals WHERE type = 'X' and name = '$dbContributorsGroup')
      BEGIN
        CREATE USER [$dbContributorsGroup] FROM EXTERNAL PROVIDER
      END
      IF NOT EXISTS (SELECT * FROM sys.database_principals WHERE type = 'X' and name = '$dbReadersGroup')
      BEGIN
        CREATE USER [$dbReadersGroup] FROM EXTERNAL PROVIDER
      END
      IF NOT EXISTS (SELECT * FROM sysusers WHERE issqlrole = 1 and name = 'db_executor')
      BEGIN
        CREATE ROLE db_executor
      END
      GRANT EXECUTE TO db_executor
      EXEC sp_addrolemember [db_executor], [$dbReadersGroup];
      EXEC sp_addrolemember [db_executor], [$dbContributorsGroup];
      EXEC sp_addrolemember [db_datareader], [$dbReadersGroup];
      EXEC sp_addrolemember [db_datareader], [$dbContributorsGroup];
      EXEC sp_addrolemember [db_datawriter], [$dbContributorsGroup];
      GRANT VIEW DEFINITION TO [$dbReadersGroup];
      GRANT VIEW DEFINITION TO [$dbContributorsGroup];
      GRANT SHOWPLAN TO [$dbReadersGroup];
      GRANT SHOWPLAN TO [$dbContributorsGroup];
      GRANT VIEW DATABASE PERFORMANCE STATE TO [$dbContributorsGroup];
      IF EXISTS (SELECT * FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = 'user_management' AND TABLE_NAME = 'Person' AND TABLE_CATALOG LIKE '%core%')
      BEGIN
        DENY UPDATE (password) ON OBJECT::user_management.Person TO [$dbContributorsGroup] CASCADE
        DENY DELETE ON OBJECT::user_management.Person TO [$dbContributorsGroup] CASCADE
      END
    "
    # Create users (quiet mode - no verbose output)
    run_sql_query -Server $main_server -Query $query -Database $name -Token $token

    if ($name -like "*integratorplusext*") {
      $query = "
        EXEC sp_addrolemember [db_owner], [$dbContributorsGroup];
      "
      run_sql_query -Server $main_server -Query $query -Database $name -Token $token
    }
    
    foreach ($mi_name in $mi_local_services) {
      $query = "
        IF NOT EXISTS (SELECT * FROM sys.database_principals WHERE type = 'E' and name = '$mi_name')
        BEGIN
          CREATE USER [$mi_name] FROM EXTERNAL PROVIDER
        END
        EXEC sp_addrolemember [db_executor], [$mi_name]
        EXEC sp_addrolemember [db_datareader], [$mi_name]
        EXEC sp_addrolemember [db_datawriter], [$mi_name]
        EXEC sp_addrolemember [db_ddladmin], [$mi_name]
        GRANT VIEW DEFINITION TO [$mi_name]
        GRANT ALTER ANY SENSITIVITY CLASSIFICATION TO [$mi_name]
        GRANT ALTER TO [$mi_name]
        GRANT VIEW DATABASE STATE TO [$mi_name]
      "
      if (-not (($name -like "*core*") -and (($mi_name -notlike "*core*") -and ($mi_name -notlike "*platform*") -and ($mi_name -notlike "*devops*"))) ) {
        $query += "GRANT CONTROL ON SCHEMA::dbo TO [$mi_name]"
      }
      run_sql_query -Server $main_server -Query $query -Database $name -Token $token
    }
  }
  if (("Both", "Replica") -contains $Type -and $replica_server -and $BaselinesMode -ne "Only") {
    $query = "
      IF NOT EXISTS (SELECT * FROM sys.database_principals WHERE type = 'S' and name = 'replicaReader')
      BEGIN
        CREATE USER [replicaReader] FOR LOGIN replicaReader
      END
      EXEC sp_addrolemember N'db_datareader', N'replicaReader'
    "
    # Create replica users (quiet mode)
    run_sql_query -Server $main_server -Query $query -Database $name -Token $token

    $staticReplicaUserPassword = (az keyvault secret show --subscription $sub --vault-name $key_vault_name -n "$kv_keys_prefix-ConnectionStrings-ReplicaStaticConnection" --query "value" -o tsv | Select-String -Pattern "(?<=password=)[^;]*").Matches.Value
    $query = "
      IF NOT EXISTS (SELECT * FROM master.sys.sql_logins WHERE name = '$staticReplicaUserName')
      BEGIN
        CREATE LOGIN [$staticReplicaUserName] WITH PASSWORD = '$staticReplicaUserPassword'
      END
      ALTER LOGIN [$staticReplicaUserName] DISABLE
      SELECT convert(varchar(172), sid, 1) as sid FROM master.sys.sql_logins WHERE name = '$staticReplicaUserName'
    "
    $SID = (run_sql_query -Server $main_server -Query $query -Database "master" -Token $token).sid

    $query = "
      IF NOT EXISTS (SELECT * FROM sys.database_principals WHERE type = 'S' and name = '$staticReplicaUserName')
      BEGIN
        CREATE USER [$staticReplicaUserName] FOR LOGIN [$staticReplicaUserName]
      END
      EXEC sp_addrolemember N'db_datareader', N'$staticReplicaUserName'
      GRANT EXEC TO [$staticReplicaUserName]
    "
    run_sql_query -Server $main_server -Query $query -Database $name -Token $token

    $query = "
      IF NOT EXISTS (SELECT * FROM master.sys.sql_logins WHERE name = '$staticReplicaUserName')
      BEGIN
        CREATE LOGIN [$staticReplicaUserName] WITH PASSWORD = '$staticReplicaUserPassword', SID = $SID
      END
    "
    run_sql_query -Server $replica_server -Query $query -Database "master" -Token $token
  }

  ### BASELINES
  if ($BaselinesMode -ne "Off" -and ("dev", "qa2") -notcontains $env) {
    $servers = switch ($Type) {
      "Both" { @{ "name" = $main_server; "resourceGroup" = $resourceGroup }, @{ "name" = $secondary_server; "resourceGroup" = $secondaryResourceGroup }, @{ "name" = $replica_server; "resourceGroup" = $resourceGroup } }
      "Primary" { @{ "name" = $main_server; "resourceGroup" = $resourceGroup }, @{ "name" = $secondary_server; "resourceGroup" = $secondaryResourceGroup } }
      "Replica" { @{ "name" = $replica_server; "resourceGroup" = $resourceGroup } }
    }
    if ($FirstRun -ne "Off") {
      foreach ($server in $servers) {
        if (-not $server.name) { continue }
        # Initiating scan (quiet mode)
        set_baseline -Method POST -EndpointSuffix "/initiateScan" -SubscriptionId $sub -ResourceGroupName $($server.resourceGroup) -ServerName $($server.name) -DatabaseName $name
      }
      Start-Sleep -Seconds 180
      foreach ($server in $servers) {
        if (-not $server.name) { continue }
        # Setting baselines (quiet mode)
        $body = @{properties = @{latestScan = $true; results = @{} } }
        set_baseline -Method PUT -Body $body -EndpointSuffix "/baselines/default" -SubscriptionId $sub -ResourceGroupName $($server.resourceGroup) -ServerName $($server.name) -DatabaseName $name
      }
    }
    if ($FirstRun -ne "Only") {
      foreach ($server in $servers) {
        if (-not $server.name) { continue }

        # Configuring baselines (quiet mode)
        if ($name -like "*integratorplusext*") {
          $body = @{properties = @{latestScan = $false; results = , @("$env-DBContributors") } }
          set_baseline -Method PUT -Body $body -EndpointSuffix "/baselines/default/rules/VA1258" -SubscriptionId $sub -ResourceGroupName $($server.resourceGroup) -ServerName $($server.name) -DatabaseName $name
        }
        else {
          set_baseline -Method DELETE -EndpointSuffix "/baselines/default/rules/VA1258" -SubscriptionId $sub -ResourceGroupName $($server.resourceGroup) -ServerName $($server.name) -DatabaseName $name
        }

        $body = @{properties = @{latestScan = $false; results = , @("False") } }
        set_baseline -Method PUT -Body $body -EndpointSuffix "/baselines/default/rules/VA1143" -SubscriptionId $sub -ResourceGroupName $($server.resourceGroup) -ServerName $($server.name) -DatabaseName $name
        $permissions = @(
          @("$env-DBContributors", "db_datareader", "EXTERNAL_GROUP", "EXTERNAL"),
          @("$env-DBContributors", "db_datawriter", "EXTERNAL_GROUP", "EXTERNAL"),
          @("$env-DBReaders", "db_datareader", "EXTERNAL_GROUP", "EXTERNAL"))
        $mi_local_services | ForEach-Object { $permissions += @($_, "db_datawriter", "EXTERNAL_USER", "EXTERNAL"), @($_, "db_datareader", "EXTERNAL_USER", "EXTERNAL") }
        if ($replica_server) {
          $permissions += , @("replicaReader", "db_datareader", "SQL_USER", "INSTANCE")
          $permissions += , @($staticReplicaUserName, "db_datareader", "SQL_USER", "INSTANCE")
        }
        $sorted_permissions = @()
        $permissions | Sort-Object -Property { $_[0] }, { $_[1] } | ForEach-Object { $sorted_permissions += , @($_[0], $_[1]) }
        $body = @{properties = @{latestScan = $false; results = $permissions } }
        set_baseline -Method PUT -Body $body -EndpointSuffix "/baselines/default/rules/VA2109" -SubscriptionId $sub -ResourceGroupName $($server.resourceGroup) -ServerName $($server.name) -DatabaseName $name
        $body = @{properties = @{latestScan = $false; results = @(
              @("db_executor", "$env-DBReaders"),
              @("db_executor", "$env-DBContributors")
            ) 
          } 
        }
        $mi_local_services | ForEach-Object { $body.properties.results += , @("db_executor", $_) }
        set_baseline -Method PUT -Body $body -EndpointSuffix "/baselines/default/rules/VA1281" -SubscriptionId $sub -ResourceGroupName $($server.resourceGroup) -ServerName $($server.name) -DatabaseName $name
        $users = @("$env-DBContributors", "$env-DBReaders")
        $mi_local_services | ForEach-Object { $users += $_ }
        if ($replica_server) {
          $users += "replicaReader"
          $users += $staticReplicaUserName
        }
        $query = "
          SELECT name, convert(varchar(172), sid, 1) as sid FROM sys.sysusers
        "
        $sids = run_sql_query -Server $($server.name) -Query $query -Database $name -Token $token
        $users_with_sid = @()
        ForEach ($user in $users) {
          $sid = ($sids | Where-Object { $_.name -eq $user }).sid
          $users_with_sid += , @($user, $sid.ToLower())
        }
        $body = @{properties = @{latestScan = $false; results = $users_with_sid } }
        set_baseline -Method PUT -Body $body -EndpointSuffix "/baselines/default/rules/VA2130" -SubscriptionId $sub -ResourceGroupName $($server.resourceGroup) -ServerName $($server.name) -DatabaseName $name

        set_baseline -Method POST -EndpointSuffix "/initiateScan" -SubscriptionId $sub -ResourceGroupName $($server.resourceGroup) -ServerName $($server.name) -DatabaseName $name
      }
    }
  }
}

# Show completion summary
if ($DryRun -and $Revert) {
  Write-Host "`n✅ DRY RUN COMPLETED - REVERT OPERATIONS" -ForegroundColor Green
  Write-Host "Processed $count databases (no actual changes made)" -ForegroundColor Gray
} elseif ($DryRun) {
  Write-Host "`n✅ DRY RUN COMPLETED - SQL CONFIGURATION" -ForegroundColor Green
  Write-Host "Would process $count databases (no actual changes made)" -ForegroundColor Gray
} elseif ($Revert) {
  Write-Host "`n✅ SQL USER REVERT COMPLETED" -ForegroundColor Green
  Write-Host "Reverted $count databases" -ForegroundColor Gray
} else {
  Write-Host "`n✅ SQL CONFIGURATION COMPLETED" -ForegroundColor Green
  Write-Host "Configured $count databases" -ForegroundColor Gray
}
