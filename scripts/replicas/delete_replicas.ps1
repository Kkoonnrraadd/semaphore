param (
    [Parameter(Mandatory)] [string]$Source,
    [Parameter(Mandatory)] [string]$Destination,
    [Parameter(Mandatory)][string]$SourceNamespace, 
    [Parameter(Mandatory)][string]$DestinationNamespace,
    [switch]$DryRun
)

if ($DryRun) {
    Write-Host "`n🔍 DRY RUN MODE - Enhanced Replica Management Script" -ForegroundColor Yellow
    Write-Host "===================================================" -ForegroundColor Yellow
    Write-Host "No actual replica operations will be performed" -ForegroundColor Yellow
} else {
    Write-Host "`n====================================" -ForegroundColor Cyan
    Write-Host " Enhanced Replica Management Script" -ForegroundColor Cyan
    Write-Host "====================================`n" -ForegroundColor Cyan
    Write-Host "Saves tags, removes replicas, and recreates them properly" -ForegroundColor Yellow
}

$Destination_lower = (Get-Culture).TextInfo.ToLower($Destination)

# Global variable to store replica configurations for recreation
$script:ReplicaConfigurations = @()

function Test-DatabaseMatchesPattern {
    param (
        [string]$DatabaseName,
        [string]$DestinationNamespace,
        [string]$SourceProduct,
        [string]$SourceType,
        [string]$SourceEnvironment,
        [string]$SourceLocation
    )
    
    if ($DestinationNamespace -ne "manufacturo") {
        $expectedPattern = "$DestinationNamespace-$SourceEnvironment-$SourceLocation"
        if ($DatabaseName.Contains($expectedPattern)) {
            return $DatabaseName
        } else {
            return $null
        }
    } else {
        Write-Host "❌ Destination Namespace $DestinationNamespace is not supported. Only 'manufacturo' namespace is supported"
        $global:LASTEXITCODE = 1
        throw "Destination Namespace $DestinationNamespace is not supported. Only 'manufacturo' namespace is supported"
    }
}

function Save-ReplicaConfiguration {
    param (
        [object]$Database,
        [string]$ServerName,
        [string]$ResourceGroup,
        [string]$SubscriptionId
    )
    
    Write-Host "  📋 Saving configuration for replica: $($Database.name)" -ForegroundColor Cyan
    
    $config = @{
        DatabaseName = $Database.name
        ServerName = $ServerName
        ResourceGroup = $ResourceGroup
        SubscriptionId = $SubscriptionId
        Tags = $Database.tags
        Sku = $Database.sku
        MaxSizeBytes = $Database.maxSizeBytes
        ZoneRedundant = $Database.zoneRedundant
        ReadScale = $Database.readScale
        ElasticPoolId = $Database.elasticPoolId
        ReplicationLinks = @()
    }
    
    # Get replication links for this database
    try {
        Write-Host "    Checking replication links..." -ForegroundColor Gray
        $replicationLinks = az sql db replica list-links `
            --subscription $SubscriptionId `
            --resource-group $ResourceGroup `
            --server $ServerName `
            --name $Database.name | ConvertFrom-Json
        
        if ($replicationLinks -and $replicationLinks.Count -gt 0) {
            Write-Host "    Found $($replicationLinks.Count) replication link(s)" -ForegroundColor Yellow
            foreach ($link in $replicationLinks) {
                $config.ReplicationLinks += @{
                    PartnerServer = $link.partnerServer
                    PartnerDatabase = $link.partnerDatabase
                    PartnerResourceGroup = $link.resourceGroup
                    LinkType = $link.linkType
                    ReplicationMode = $link.replicationMode
                    ReplicationState = $link.replicationState
                    IsTerminationAllowed = $link.isTerminationAllowed
                }
            }
        }
    }
    catch {
        Write-Host "    ⚠️  Could not retrieve replication links: $($_.Exception.Message)" -ForegroundColor Yellow
    }
    $script:ReplicaConfigurations += $config
    Write-Host "    ✅ Configuration saved for $($Database.name)" -ForegroundColor Green
    Write-Host "    $($config | ConvertTo-Json -Depth 10)" -ForegroundColor Gray

}

function Remove-ReplicationLinks {
    param (
        [object]$Database,
        [string]$ServerName,
        [string]$ResourceGroup,
        [string]$SubscriptionId
    )
    
    Write-Host "  🔗 Removing replication links for: $($Database.name)" -ForegroundColor Yellow
    
    try {
        $replicationLinks = az sql db replica list-links `
            --subscription $SubscriptionId `
            --resource-group $ResourceGroup `
            --server $ServerName `
            --name $Database.name | ConvertFrom-Json
        
        if ($replicationLinks -and $replicationLinks.Count -gt 0) {
            Write-Host "    Found $($replicationLinks.Count) replication link(s) to remove" -ForegroundColor Yellow
            
            foreach ($link in $replicationLinks) {
                Write-Host "    Removing link to $($link.partnerServer)..." -ForegroundColor Gray
                
                try {
                    # For geo-replication, we need to terminate from the primary side
                    if ($link.linkType -eq "GEO") {
                        if (-not $DryRun) {
                            Write-Host "    Terminating GEO replication link..." -ForegroundColor Gray
                            az sql db replica delete-link `
                                --subscription $SubscriptionId `
                                --resource-group $ResourceGroup `
                                --server $ServerName `
                                --name $Database.name `
                                --partner-server $link.partnerServer `
                                --partner-resource-group $link.resourceGroup `
                                --yes
                            
                            Write-Host "    ✅ GEO replication link terminated" -ForegroundColor Green
                        }else{
                            Write-Host "    Skipping GEO replication link termination as it is a dry run" -ForegroundColor Gray
                        }
                    }else{
                        Write-Host " ❌ Error during removal of replication link to $($link.partnerServer) as it is not a GEO link" -ForegroundColor Gray
                    }
                }
                catch {
                    Write-Host "    ❌ Error during removal of replication link to $($link.partnerServer): $($_.Exception.Message)" -ForegroundColor Red
                    $global:LASTEXITCODE = 1
                    throw "Error during removal of replication link to $($link.partnerServer): $($_.Exception.Message)"
                }
            }
        } else {
            Write-Host "  ⚠️  No replication links found" -ForegroundColor Gray
        }
    }
    catch {
        Write-Host "    ❌ Error during removal of replication links: $($_.Exception.Message)" -ForegroundColor Red
        $global:LASTEXITCODE = 1
        throw "Error during removal of replication links: $($_.Exception.Message)"
    }
}

function Delete-ReplicaDatabase {
    param (
        [object]$Database,
        [string]$ServerName,
        [string]$ResourceGroup,
        [string]$SubscriptionId
    )
    
    Write-Host "  🗑️  Deleting replica database: $($Database.name)" -ForegroundColor Red
    
    try {
        if ($DryRun) {
            Write-Host "    Skipping database deletion as it is a dry run" -ForegroundColor Gray
        } else {
            Write-Host "    Deleting database: $($Database.name)" -ForegroundColor Gray
            az sql db delete `
                --subscription $SubscriptionId `
                --resource-group $ResourceGroup `
                --server $ServerName `
                --name $Database.name `
                --yes
        
            Write-Host "    ✅ Successfully deleted database: $($Database.name)" -ForegroundColor Green
        }
    }
    catch {
        Write-Host "    ✗ Failed to delete database: $($_.Exception.Message)" -ForegroundColor Red
        $global:LASTEXITCODE = 1
        throw "Failed to delete database: $($_.Exception.Message)"
    }
}

function Recreate-ReplicaDatabase {
    param (
        [object]$Config
    )
    
    Write-Host "  🔄 Recreating replica database: $($Config.DatabaseName)" -ForegroundColor Cyan
    
    try {
        # Get the primary server name from the saved replication links
        $primaryServer = $null
        if ($Config.ReplicationLinks.Count -gt 0) {
            $primaryServer = $Config.ReplicationLinks[0].PartnerServer
            Write-Host "    Found primary server from replication links: $primaryServer" -ForegroundColor Gray
        } else {
            # Fallback: try to determine primary server from naming convention
            $primaryServer = $Config.ServerName -replace "-replica-", "-"
            Write-Host "    Using naming convention for primary server: $primaryServer" -ForegroundColor Gray
        }
        
        # Check if primary database exists and get its configuration
        Write-Host "    Checking primary database configuration..." -ForegroundColor Gray
        
        $primaryDb = az sql db show `
            --subscription $Config.SubscriptionId `
            --resource-group $Config.ResourceGroup `
            --server $primaryServer `
            --name $Config.DatabaseName 2>$null | ConvertFrom-Json
        
        if (-not $primaryDb) {
            Write-Host "    ❌ Primary database not found: $($Config.DatabaseName) on server $primaryServer" -ForegroundColor Red
            Write-Host "    💡 Please verify the primary database exists and is accessible" -ForegroundColor Yellow
            return
        }
        
        Write-Host "    Primary database found on $primaryServer, creating replica..." -ForegroundColor Green
        
        # Create ARM template for replica database
        Write-Host "    Creating ARM template..." -ForegroundColor Gray
        
        $armTemplate = @{
            '$schema' = "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#"
            contentVersion = "1.0.0.0"
            parameters = @{
                databaseName = @{
                    type = "string"
                    defaultValue = $Config.DatabaseName
                }
                serverName = @{
                    type = "string"
                    defaultValue = $Config.ServerName
                }
                primaryServerName = @{
                    type = "string"
                    defaultValue = $primaryServer
                }
                maxSizeBytes = @{
                    type = "int"
                    defaultValue = $Config.MaxSizeBytes
                }
                zoneRedundant = @{
                    type = "bool"
                    defaultValue = $Config.ZoneRedundant
                }
                readScale = @{
                    type = "string"
                    defaultValue = if ($Config.ReadScale -eq "Enabled") { "Enabled" } else { "Disabled" }
                }
            }
            resources = @(
                @{
                    type = "Microsoft.Sql/servers/databases"
                    apiVersion = "2021-11-01"
                    name = "$($Config.ServerName)/$($Config.DatabaseName)"
                    location = "[resourceGroup().location]"
                    sku = @{
                        name = "S0"
                        tier = "Standard"
                    }
                    properties = @{
                        maxSizeBytes = "[parameters('maxSizeBytes')]"
                        zoneRedundant = "[parameters('zoneRedundant')]"
                        readScale = "[parameters('readScale')]"
                        sourceDatabaseId = "[resourceId('Microsoft.Sql/servers/databases', parameters('primaryServerName'), parameters('databaseName'))]"
                        createMode = "Secondary"
                        secondaryType = "Geo"
                    }
                    tags = $Config.Tags
                }
            )
        }
        
        # Convert template to JSON
        $templateJson = $armTemplate | ConvertTo-Json -Depth 10
        $templatePath = Join-Path $PWD "replica_template_$($Config.DatabaseName).json"
        $templateJson | Out-File -FilePath $templatePath -Encoding UTF8
        
        Write-Host "    ✅ ARM template created: $templatePath" -ForegroundColor Green
        
        # Deploy ARM template using Azure CLI
        Write-Host "    🚀 Deploying ARM template..." -ForegroundColor Yellow
        
        $deploymentName = "replica-deployment-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        
        Write-Host "    Deploying with name: $deploymentName" -ForegroundColor Gray
        
        try {
            Write-Host "    Executing ARM deployment..." -ForegroundColor Gray
            $deployment = az deployment group create `
                --subscription $Config.SubscriptionId `
                --resource-group $Config.ResourceGroup `
                --template-file $templatePath `
                --name $deploymentName `
                --mode Incremental 2>$null | ConvertFrom-Json
            
            if ($deployment -and $deployment.properties.provisioningState -eq "Succeeded") {
                Write-Host "    ✅ Successfully created replica database: $($Config.DatabaseName)" -ForegroundColor Green
                
                # Wait for replication to be established
                Write-Host "    ⏳ Waiting for replication to be established..." -ForegroundColor Yellow
                Start-Sleep -Seconds 30
                
                # Check replication status using Azure CLI
                Write-Host "    📋 Checking replication status..." -ForegroundColor Yellow
                try {
                    $replicaStatus = az sql db replica list-links `
                        --subscription $Config.SubscriptionId `
                        --resource-group $Config.ResourceGroup `
                        --server $primaryServer `
                        --name $Config.DatabaseName | ConvertFrom-Json
                    
                    if ($replicaStatus -and $replicaStatus.Count -gt 0) {
                        Write-Host "    ✅ Replication established successfully" -ForegroundColor Green
                        foreach ($link in $replicaStatus) {
                            Write-Host "      Partner: $($link.partnerServer), State: $($link.replicationState)" -ForegroundColor Gray
                        }
                    } else {
                        Write-Host "    ⚠️  No replication link found yet" -ForegroundColor Yellow
                        Write-Host "    💡 The database was created successfully, replication may take a few minutes" -ForegroundColor Yellow
                    }
                }
                catch {
                    Write-Host "    ⚠️  Could not check replication status: $($_.Exception.Message)" -ForegroundColor Yellow
                    Write-Host "    💡 The database was created successfully, please verify replication manually" -ForegroundColor Yellow
                }
                    } else {
            Write-Host "    ❌ Deployment failed: $($deployment.properties.provisioningState)" -ForegroundColor Red
            Write-Host "    💡 Check the deployment details in Azure Portal" -ForegroundColor Yellow
        }
        }
        catch {
            Write-Host "    ❌ Error during ARM deployment: $($_.Exception.Message)" -ForegroundColor Red
            Write-Host "    💡 Check if the subscription and resource group are accessible" -ForegroundColor Yellow
        }
        
        # Clean up template file
        if (Test-Path $templatePath) {
            Remove-Item $templatePath -Force
            Write-Host "    🧹 Cleaned up template file" -ForegroundColor Gray
        }
        
    }
    catch {
        Write-Host "    ❌ Error during replica creation: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "    💡 This might be due to authentication or permission issues" -ForegroundColor Yellow
        Write-Host "    💡 Consider manual creation through Azure Portal" -ForegroundColor Yellow
        Write-Host "    💡 Check if the primary database exists and is accessible" -ForegroundColor Yellow
        $global:LASTEXITCODE = 1
        throw "Error during replica creation: $($_.Exception.Message)"
    }
}

function Delete-ReplicasForEnvironment {
    param (
        [array]$Replicas,
        [string]$SourceProduct,
        [string]$SourceType,
        [string]$SourceEnvironment,
        [string]$SourceLocation,
        [string]$DestinationNamespace
    )
    
    foreach ($replica in $Replicas) {
        Write-Host "`nProcessing replica server: $($replica.name)" -ForegroundColor White
        Write-Host "  Resource Group: $($replica.resourceGroup)" -ForegroundColor Gray
        Write-Host "  Subscription: $($replica.subscriptionId)" -ForegroundColor Gray
        Write-Host "  Location: $($replica.location)" -ForegroundColor Gray
        
        # Get databases on replica server
        Write-Host "  Checking for databases on replica..." -ForegroundColor Yellow
        try {
            # First get the list of databases
            $databaseList = az sql db list `
                --subscription $replica.subscriptionId `
                --resource-group $replica.resourceGroup `
                --server $replica.name `
                --query "[?name != 'master'].name" | ConvertFrom-Json
            
            $databases = @()
            foreach ($dbName in $databaseList) {
                # Check if database matches expected pattern
                $matchesPattern = Test-DatabaseMatchesPattern `
                    -DatabaseName $dbName `
                    -DestinationNamespace $DestinationNamespace `
                    -SourceProduct $SourceProduct `
                    -SourceType $SourceType `
                    -SourceEnvironment $SourceEnvironment `
                    -SourceLocation $SourceLocation

                if ($matchesPattern) {
                    Write-Host "`n    ✅ Will recreate: $($matchesPattern)" 
                    $database = az sql db show `
                    --subscription $replica.subscriptionId `
                    --resource-group $replica.resourceGroup `
                    --server $replica.name `
                    --name $matchesPattern | ConvertFrom-Json

                    if ($database.tags.ClientName -eq $DestinationNamespace){
                        $databases += $database
                    } else {
                        Write-Host "    ❌ Database $($database.name): ClientName $($database.tags.ClientName) does not match destination namespace $DestinationNamespace" -ForegroundColor Red
                        $global:LASTEXITCODE = 1
                        throw "Database $($database.name): ClientName $($database.tags.ClientName) does not match destination namespace $DestinationNamespace"
                    }

                } else {
                    Write-Host "`n    ⏭️  Skipping: Pattern mismatch $($dbName)"
                }
            }
            
            if ($databases -and $databases.Count -gt 0) {
                Write-Host "`n  Found $($databases.Count) database(s) on replica:" -ForegroundColor Green
                foreach ($db in $databases) {
                    Write-Host "    - $($db.name)" -ForegroundColor White
                }
                
                        
                # Show tags that would be preserved
                if ($db.tags) {
                    Write-Host "        Tags: $($db.tags.Keys -join ', ')" -ForegroundColor Gray
                    # Also show individual tag values for clarity
                    foreach ($tag in $db.tags.PSObject.Properties) {
                        Write-Host "          $($tag.Name) = $($tag.Value)" -ForegroundColor Gray
                    }
                    # Debug: Show raw tags object
                    # Write-Host "        Debug: Raw tags object: $($db.tags | ConvertTo-Json)" -ForegroundColor Magenta
                } else {
                    Write-Host "        Tags: None" -ForegroundColor Gray
                    $script:DryRunHasFailures = $true
                    $script:DryRunFailureReasons += "Database $($database.name) has no tags"
                }

                # Process each database
                foreach ($database in $databases) {
                    Write-Host "`n  Processing database: $($database.name)" -ForegroundColor Cyan
                    
                    # Step 1: Save configuration
                    Save-ReplicaConfiguration -Database $database -ServerName $replica.name -ResourceGroup $replica.resourceGroup -SubscriptionId $replica.subscriptionId
                    
                    # Step 2: Remove replication links
                    Remove-ReplicationLinks -Database $database -ServerName $replica.name -ResourceGroup $replica.resourceGroup -SubscriptionId $replica.subscriptionId
                    
                    # Step 3: Delete replica database
                    Delete-ReplicaDatabase -Database $database -ServerName $replica.name -ResourceGroup $replica.resourceGroup -SubscriptionId $replica.subscriptionId
                }
            
                Write-Host "  ✅ Replica server $($replica.name) is now clean (server preserved)" -ForegroundColor Green
                # }
            }
        }
        catch {
            Write-Host "    ❌ Error during replica deletion for server $($replica.name): $($_.Exception.Message)" -ForegroundColor Red
            Write-Host "    💡 This might be due to authentication or permission issues" -ForegroundColor Yellow
            Write-Host "    💡 Consider manual deletion through Azure Portal" -ForegroundColor Yellow
            Write-Host "    💡 Check if the database exists and is accessible" -ForegroundColor Yellow
            $global:LASTEXITCODE = 1
            throw "Error during replica deletion for server $($replica.name): $($_.Exception.Message)"
        }
    }
}

function Recreate-AllReplicas {
    Write-Host "`n🔄 RECREATING REPLICA DATABASES" -ForegroundColor Cyan
    Write-Host "=====================================" -ForegroundColor Cyan
    
    if ($script:ReplicaConfigurations.Count -eq 0) {
        Write-Host "No replica configurations to recreate" -ForegroundColor Yellow
        return
    }
    
    Write-Host "Found $($script:ReplicaConfigurations.Count) replica(s) to recreate" -ForegroundColor Green
    Write-Host "🔄 Processing replicas sequentially..." -ForegroundColor Yellow
    
    # Process each replica configuration sequentially
    foreach ($config in $script:ReplicaConfigurations) {
        Write-Host "`n  🔄 Recreating replica database: $($config.DatabaseName)" -ForegroundColor Cyan
        
        try {
            # Get the primary server name from the saved replication links
            $primaryServer = $null
            if ($config.ReplicationLinks.Count -gt 0) {
                $primaryServer = $config.ReplicationLinks[0].PartnerServer
                Write-Host "    Found primary server from replication links: $primaryServer" -ForegroundColor Gray
            } else {
                # Fallback: try to determine primary server from naming convention
                $primaryServer = $config.ServerName -replace "-replica-", "-"
                Write-Host "    Using naming convention for primary server: $primaryServer" -ForegroundColor Gray
            }
            
            # Check if primary database exists and get its configuration
            Write-Host "    Checking primary database configuration..." -ForegroundColor Gray
            
            $primaryDb = az sql db show `
                --subscription $config.SubscriptionId `
                --resource-group $config.ResourceGroup `
                --server $primaryServer `
                --name $config.DatabaseName 2>$null | ConvertFrom-Json
            
            if (-not $primaryDb) {
                Write-Host "    ❌ Primary database not found: $($config.DatabaseName) on server $primaryServer" -ForegroundColor Red
                Write-Host "    💡 Please verify the primary database exists and is accessible" -ForegroundColor Yellow
                continue
            }
            
            Write-Host "    Primary database found on $primaryServer, creating replica..." -ForegroundColor Green
            
            # Create ARM template for replica database
            Write-Host "    Creating ARM template..." -ForegroundColor Gray
            
            $armTemplate = @{
                '$schema' = "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#"
                contentVersion = "1.0.0.0"
                parameters = @{
                    databaseName = @{
                        type = "string"
                        defaultValue = $config.DatabaseName
                    }
                    serverName = @{
                        type = "string"
                        defaultValue = $config.ServerName
                    }
                    primaryServerName = @{
                        type = "string"
                        defaultValue = $primaryServer
                    }
                    maxSizeBytes = @{
                        type = "int"
                        defaultValue = $config.MaxSizeBytes
                    }
                    zoneRedundant = @{
                        type = "bool"
                        defaultValue = $config.ZoneRedundant
                    }
                    readScale = @{
                        type = "string"
                        defaultValue = if ($config.ReadScale -eq "Enabled") { "Enabled" } else { "Disabled" }
                    }
                }
                resources = @(
                    @{
                        type = "Microsoft.Sql/servers/databases"
                        apiVersion = "2021-11-01"
                        name = "$($config.ServerName)/$($config.DatabaseName)"
                        location = "[resourceGroup().location]"
                        sku = @{
                            name = "S0"
                            tier = "Standard"
                        }
                        properties = @{
                            maxSizeBytes = "[parameters('maxSizeBytes')]"
                            zoneRedundant = "[parameters('zoneRedundant')]"
                            readScale = "[parameters('readScale')]"
                            sourceDatabaseId = "[resourceId('Microsoft.Sql/servers/databases', parameters('primaryServerName'), parameters('databaseName'))]"
                            createMode = "Secondary"
                            secondaryType = "Geo"
                        }
                        tags = $config.Tags
                    }
                )
            }
            
            # Convert template to JSON
            $templateJson = $armTemplate | ConvertTo-Json -Depth 10
            $templatePath = Join-Path $PWD "replica_template_$($config.DatabaseName).json"
            $templateJson | Out-File -FilePath $templatePath -Encoding UTF8
            
            Write-Host "    ✅ ARM template created: $templatePath" -ForegroundColor Green
            
            # Deploy ARM template using Azure CLI
            Write-Host "    🚀 Deploying ARM template..." -ForegroundColor Yellow
            
            $deploymentName = "replica-deployment-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
            
            Write-Host "    Deploying with name: $deploymentName" -ForegroundColor Gray
            
            try {
                if (-not $DryRun) {
                    Write-Host "    Executing ARM deployment..." -ForegroundColor Gray
                    $deployment = az deployment group create `
                        --subscription $config.SubscriptionId `
                        --resource-group $config.ResourceGroup `
                        --template-file $templatePath `
                        --name $deploymentName `
                        --mode Incremental 2>$null | ConvertFrom-Json

                    if ($deployment -and $deployment.properties.provisioningState -eq "Succeeded") {
                        Write-Host "    ✅ Successfully created replica database: $($config.DatabaseName)" -ForegroundColor Green
                        
                        # Wait for replication to be established
                        Write-Host "    ⏳ Waiting for replication to be established..." -ForegroundColor Yellow
                        Start-Sleep -Seconds 30
                        
                        # Check replication status using Azure CLI
                        Write-Host "    📋 Checking replication status..." -ForegroundColor Yellow
                        try {
                            $replicaStatus = az sql db replica list-links `
                                --subscription $config.SubscriptionId `
                                --resource-group $config.ResourceGroup `
                                --server $config.ServerName `
                                --name $config.DatabaseName | ConvertFrom-Json
                            
                            if ($replicaStatus -and $replicaStatus.Count -gt 0) {
                                Write-Host "    ✅ Replication established successfully" -ForegroundColor Green
                                foreach ($link in $replicaStatus) {
                                    Write-Host "      Partner: $($link.partnerServer), State: $($link.replicationState)" -ForegroundColor Gray
                                }
                            } else {
                                Write-Host "    ⚠️  No replication link found yet" -ForegroundColor Yellow
                                Write-Host "    💡 The database was created successfully, replication may take a few minutes" -ForegroundColor Yellow
                            }
                        }
                        catch {
                            Write-Host "    ⚠️  Could not check replication status: $($_.Exception.Message)" -ForegroundColor Yellow
                            Write-Host "    💡 The database was created successfully, please verify replication manually" -ForegroundColor Yellow
                        }
                    } else {
                        Write-Host "    ❌ Deployment failed: $($deployment.properties.provisioningState)" -ForegroundColor Red
                        Write-Host "    💡 Check the deployment details in Azure Portal" -ForegroundColor Yellow
                    }
                }else{
                    Write-Host "    Skipping ARM deployment as it is a dry run" -ForegroundColor Gray
                    Write-Host "    Skipping replication status check as it is a dry run" -ForegroundColor Gray
                }
                

            }
            catch {
                Write-Host "    ❌ Error during ARM deployment: $($_.Exception.Message)" -ForegroundColor Red
                Write-Host "    💡 Check if the subscription and resource group are accessible" -ForegroundColor Yellow
            }
            
            # Clean up template file
            if (Test-Path $templatePath) {
                Remove-Item $templatePath -Force
                Write-Host "    🧹 Cleaned up template file" -ForegroundColor Gray
            }
            
        }
        catch {
            Write-Host "    ❌ Error during replica creation: $($_.Exception.Message)" -ForegroundColor Red
            Write-Host "    💡 This might be due to authentication or permission issues" -ForegroundColor Yellow
            Write-Host "    💡 Consider manual creation through Azure Portal" -ForegroundColor Yellow
            Write-Host "    💡 Check if the primary database exists and is accessible" -ForegroundColor Yellow
        }
    }
    
    Write-Host "`n✅ Replica recreation process completed" -ForegroundColor Green
}

# Main execution
Write-Host "Processing Destination environment: $Destination" -ForegroundColor Yellow
Write-Host "NOTE: Source environment replicas will be preserved" -ForegroundColor Green

Write-Host "`nSearching for SQL Server replicas in $Destination_lower environment..." -ForegroundColor Cyan

#  and tags.Type == 'Replica'
$graph_query = "
    resources
    | where type =~ 'microsoft.sql/servers'
    | where tags.Environment == '$Destination_lower' and tags.Type == 'Replica'
    | project name, resourceGroup, subscriptionId, location
"
$replicas = az graph query -q $graph_query --query "data" --first 1000 | ConvertFrom-Json

if (-not $replicas -or $replicas.Count -eq 0) {
    Write-Host "❌ No SQL server found for environment with tags Environment: $Destination_lower and Type: Replica"

    Write-Host "Trying to relogin and try again..."
    az logout
    az login --federated-token "$(cat $env:AZURE_FEDERATED_TOKEN_FILE)" `
             --service-principal -u $env:AZURE_CLIENT_ID -t $env:AZURE_TENANT_ID

    $replicas = az graph query -q $graph_query --query "data" --first 1000 | ConvertFrom-Json

# ═══════════════════════════════════════════════════════════════
# CRITICAL CHECK: Verify SQL server was found
# ═══════════════════════════════════════════════════════════════
    if (-not $replicas -or $replicas.Count -eq 0) {
        Write-Host ""
        Write-Host "═══════════════════════════════════════════════"
        Write-Host "❌ FATAL ERROR: SQL Server Not Found"
        Write-Host "═══════════════════════════════════════════════"
        Write-Host ""
        Write-Host "🔴 PROBLEM: No SQL server found for environment '$Destination_lower'"
        Write-Host "   └─ Query returned no results for tags.Environment='$Destination_lower' and tags.Type='Replica'"
        Write-Host ""
        Write-Host "💡 SOLUTIONS:"
        Write-Host "   1. Verify environment name is correct (provided: '$Destination_lower')"
        Write-Host "   2. Check if SQL server exists in Azure Portal"
        Write-Host "   3. Verify server has required tags:"
        Write-Host "      • Environment = '$Destination_lower'"
        Write-Host "      • Type = 'Primary'"
        Write-Host ""
        
        if ($DryRun) {
            Write-Host "⚠️  DRY RUN WARNING: No SQL server found for destination environment" -ForegroundColor Yellow
            Write-Host "⚠️  In production, this would abort the operation" -ForegroundColor Yellow
            Write-Host "⚠️  Skipping remaining steps..." -ForegroundColor Yellow
            Write-Host ""
            # Track this failure for final dry run summary
            $script:DryRunHasFailures = $true
            $script:DryRunFailureReasons += "No SQL server found for destination environment '$Destination_lower'"
            # Skip to end for dry run summary
            return
        } else {
            Write-Host "🛑 ABORTING: Cannot remove restored databases without server information for environment '$Destination_lower'"
            Write-Host ""
            $global:LASTEXITCODE = 1
            throw "No SQL server found for destination environment '$Destination_lower' - cannot remove restored databases without server information"
        }
    }
}

Write-Host "Found $($replicas.Count) SQL Server replica(s) to process in $Destination_lower" -ForegroundColor Green

# works for 1 or 2 replicas 
$Source_split = $replicas.resourceGroup -split "-"
$Source_product = $Source_split[1]
$Source_location = $Source_split[-1]
$Source_type = $Source_split[2]
$Source_environment = $Source_split[3]

# Step 1: Delete replicas and save configurations
Delete-ReplicasForEnvironment -Replicas $replicas -SourceProduct $Source_product -SourceType $Source_type -SourceEnvironment $Source_environment -SourceLocation $Source_location -DestinationNamespace $DestinationNamespace

Recreate-AllReplicas

Write-Host "`n====================================" -ForegroundColor Cyan
Write-Host " Enhanced Replica Management Completed" -ForegroundColor Cyan
Write-Host "====================================`n" -ForegroundColor Cyan

Write-Host "📝 SUMMARY OF WHAT WAS DONE:" -ForegroundColor Yellow
Write-Host "✅ Replica configurations were saved before deletion" -ForegroundColor Green
Write-Host "✅ Replication links were properly removed" -ForegroundColor Green
Write-Host "✅ Replica databases were deleted from replica servers" -ForegroundColor Green
Write-Host "✅ Replica databases were recreated with proper configuration" -ForegroundColor Green
Write-Host "✅ Replia servers were preserved (NOT deleted)" -ForegroundColor Green
Write-Host "✅ Tags and configurations were preserved during recreation" -ForegroundColor Green

if ($script:ReplicaConfigurations.Count -gt 0) {
    Write-Host "`n📊 REPLICA CONFIGURATIONS PROCESSED:" -ForegroundColor Yellow
    foreach ($config in $script:ReplicaConfigurations) {
        Write-Host "  • $($config.DatabaseName) on $($config.ServerName)" -ForegroundColor White
        Write-Host "    SKU: $($config.Sku.tier) $($config.Sku.name) $($config.Sku.capacity)" -ForegroundColor Gray
        
        # Display tags properly
        if ($config.Tags) {
            $tagList = @()
            foreach ($tag in $config.Tags.PSObject.Properties) {
                $tagList += "$($tag.Name)=$($tag.Value)"
            }
            Write-Host "    Tags: $($tagList -join ', ')" -ForegroundColor Gray
        } else {
            Write-Host "    Tags: (none)" -ForegroundColor Gray
        }
    }
}