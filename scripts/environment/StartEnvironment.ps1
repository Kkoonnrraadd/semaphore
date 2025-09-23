﻿param (
    [string]$destination,
    [AllowEmptyString()][string]$destinationNamespace,
    [string]$Cloud,
    [switch]$DryRun
)

if ($DryRun) {
    Write-Host "`n🔍 DRY RUN MODE - Azure Environment Start" -ForegroundColor Yellow
    Write-Host "=========================================" -ForegroundColor Yellow
    Write-Host "No actual environment startup operations will be performed" -ForegroundColor Yellow
} else {
    Write-Host "`n=========================" -ForegroundColor Cyan
    Write-Host " Azure Environment Start " -ForegroundColor Cyan
    Write-Host "===========================`n" -ForegroundColor Cyan
}

# Function to get the list of all pods in the cluster (in a specific namespace)
function Get-PodsInCluster {
    param(
        [string]$Namespace
    )

    # List all pods in the specified namespace
    $pods = kubectl get deployments -n $Namespace --output json | ConvertFrom-Json
    return $pods.items

}

function Upscale-BlackboxMonitoring {
    param(
        [string]$Namespace
    )

    Write-Host "Upscaling blackbox monitoring deployments..." -ForegroundColor Cyan
    
    # Get list of all deployments in the namespace
    $deployments = Get-PodsInCluster -Namespace $Namespace
    
    # Filter for blackbox monitoring deployments
    $blackboxDeployments = $deployments | Where-Object { 
        $_.metadata.name -like "*blackbox*"
    }
    
    if ($blackboxDeployments.Count -eq 0) {
        Write-Host "No blackbox monitoring deployments found in namespace: $Namespace" -ForegroundColor Yellow
        return
    }
    
    foreach ($deployment in $blackboxDeployments) {
        $deploymentName = $deployment.metadata.name
        Write-Host "Upscaling blackbox monitoring deployment: $deploymentName" -ForegroundColor Green
        kubectl scale deployment/$deploymentName --replicas=1 -n $Namespace
    }
    
    Write-Host "Blackbox monitoring deployments upscaled successfully." -ForegroundColor Green
}

# Function to restart pods in Kubernetes based on labels
function Downscale-Deployments {
    param(
        [string]$Namespace
    )

    # Get list of all pods in the cluster
    $deployments = Get-PodsInCluster -Namespace $Namespace
    foreach ($deployment in $deployments){
        $deployment = $deployment.metadata.name
        $count = 1

        # Check if the deployment is the special one that needs 3 replicas
        if ($deployment -eq "eworkin-plus-nonconformance-backend" -or $deployment -eq "eworkin-plus-backend") {
            $count = 3
        }

        Write-Host "Scaling deployment $deployment to $count replicas" -ForegroundColor Green
        kubectl scale deployment/$deployment --replicas=$count -n $Namespace
    } 
}

function Set-ClusterContext {
    param(
        [string]$ClusterContext
    )

    # Set the Kubernetes context to ensure we are working with the correct cluster
    Write-Host "Setting Kubernetes context to $ClusterContext..."
    kubectl config use-context $ClusterContext | Out-Null
    Write-Host "Cluster context set to $ClusterContext"
}

$destination_lower = (Get-Culture).TextInfo.ToLower($destination)

$graph_query = "
  resources
  | where type =~ 'microsoft.containerservice/managedclusters'
  | where tags.Environment == '$destination_lower' and tags.Type == 'Primary'
  | project name, resourceGroup, subscriptionId
"
$recources = az graph query -q $graph_query --query "data" --first 1000 | ConvertFrom-Json

$destination_subscription = $recources[0].subscriptionId
$destination_aks = $recources[0].name
$destination_rg = $recources[0].resourceGroup

if ($DryRun) {
    Write-Host "`n🔍 DRY RUN: DISCOVERING ENVIRONMENT STARTUP OPERATIONS" -ForegroundColor Yellow
    Write-Host "==================================================" -ForegroundColor Yellow
    
    Write-Host "🔍 DRY RUN: Environment: $destination" -ForegroundColor Yellow
    Write-Host "🔍 DRY RUN: AKS Cluster: $destination_aks" -ForegroundColor Gray
    Write-Host "🔍 DRY RUN: Resource Group: $destination_rg" -ForegroundColor Gray
    Write-Host "🔍 DRY RUN: Subscription: $destination_subscription" -ForegroundColor Gray
    
    Write-Host "🔍 DRY RUN: Would set cluster context to: $destination_aks" -ForegroundColor Yellow
    Write-Host "🔍 DRY RUN: Would upscale blackbox monitoring in 'monitoring' namespace" -ForegroundColor Yellow
    Write-Host "🔍 DRY RUN: Would scale up deployments in '$destinationNamespace' namespace" -ForegroundColor Yellow
    
    # Discover what deployments would be scaled
    try {
        Write-Host "🔍 DRY RUN: Would scale these deployments to 1 replica:" -ForegroundColor Yellow
        Write-Host "  • All deployments in namespace '$destinationNamespace'" -ForegroundColor Gray
        Write-Host "  • Special case: eworkin-plus-nonconformance-backend (3 replicas)" -ForegroundColor Gray
        Write-Host "  • Special case: eworkin-plus-backend (3 replicas)" -ForegroundColor Gray
    }
    catch {
        Write-Host "  • Could not discover deployments (cluster may be stopped)" -ForegroundColor Gray
    }

    
    # Discover web tests that would be enabled
    Write-Host "`n🔍 DRY RUN: Would enable Application Insights web tests:" -ForegroundColor Yellow
    if ($Cloud -eq "AzureCloud") {
        $webtests = az monitor app-insights web-test list `
            --subscription $destination_subscription `
            --only-show-errors `
            --output json | ConvertFrom-Json
        
        if ($webtests.Count -gt 0) {
            Write-Host "🔍 DRY RUN: Would enable $($webtests.Count) web tests:" -ForegroundColor Yellow
            $webtests | ForEach-Object {
                Write-Host "  • $($_.name)" -ForegroundColor Gray
            }
        } else {
            Write-Host "🔍 DRY RUN: No web tests found to enable" -ForegroundColor Gray
        }
    } else {
        $webtests = az resource list `
            --subscription $destination_subscription `
            --resource-group $destination_rg `
            --resource-type "Microsoft.Insights/webtests" `
            --output json `
            --only-show-errors | ConvertFrom-Json
        
        if ($webtests.Count -gt 0) {
            Write-Host "🔍 DRY RUN: Would enable $($webtests.Count) web tests:" -ForegroundColor Yellow
            $webtests | ForEach-Object {
                Write-Host "  • $($_.name)" -ForegroundColor Gray
            }
        } else {
            Write-Host "🔍 DRY RUN: No web tests found to enable" -ForegroundColor Gray
        }
    }
    
    # Discover alerts that would be enabled
    Write-Host "`n🔍 DRY RUN: Would enable backend health alerts:" -ForegroundColor Yellow
    if ($destinationNamespace -eq "manufacturo") {
        $backend_health_alert = "${destination_lower}_backend_health"
    } else {
        $backend_health_alert = "${destination_lower}-${destinationNamespace}_backend_health"
    }
    
    $graph_query = "
    resources
    | where type == 'microsoft.insights/metricalerts'
    | where name contains '$backend_health_alert'
    | where resourceGroup contains 'hub'
    | project name, resourceGroup, subscriptionId
    "
    $hubs_alerts = az graph query -q $graph_query --query "data" --first 1000 | ConvertFrom-Json
    
    if ($hubs_alerts.Count -gt 0) {
        Write-Host "🔍 DRY RUN: Would enable $($hubs_alerts.Count) alerts:" -ForegroundColor Yellow
        foreach ($hub in $hubs_alerts) {
            $alert_name = $hub[0].name
            Write-Host "  • $alert_name" -ForegroundColor Gray
        }
    } else {
        Write-Host "🔍 DRY RUN: No alerts found to enable" -ForegroundColor Gray
    }
    
    Write-Host "`n🔍 DRY RUN: Environment startup preview completed." -ForegroundColor Yellow
    exit 0
}



Set-ClusterContext -ClusterContext $destination_aks
Upscale-BlackboxMonitoring -Namespace "monitoring"
Downscale-Deployments -Namespace $destinationNamespace


Write-Host "`nEnabling Application Insights web tests..."

Write-Host "Using Azure cloud: $Cloud" -ForegroundColor Gray

if ($Cloud -eq "AzureCloud") {
    Write-Host "Using classic Azure CLI web test commands for Commercial cloud..." -ForegroundColor Cyan
    
    # Fetch all web tests once using classic method
    $webtests = az monitor app-insights web-test list `
        --subscription $destination_subscription `
        --only-show-errors `
        --output json | ConvertFrom-Json

    if ($webtests.Count -eq 0) {
        Write-Host "No web tests found." -ForegroundColor Yellow
        return
    }

    # Enable in parallel with a throttle limit of 10 using classic method
    $webtests | ForEach-Object -Parallel {
        az monitor app-insights web-test update `
            --name $_.name `
            --resource-group $using:destination_rg `
            --enabled true `
            --subscription $using:destination_subscription `
            --output none `
            --only-show-errors | Out-Null

        Write-Host "Enabled web test: $($_.name)" -ForegroundColor Green
    } -ThrottleLimit 10
}
else {
    Write-Host "Using generic Azure resource commands for Government/Other clouds..." -ForegroundColor Cyan
    
    # Use az resource list for government cloud compatibility
    $webtests = az resource list `
        --subscription $destination_subscription `
        --resource-group $destination_rg `
        --resource-type "Microsoft.Insights/webtests" `
        --output json `
        --only-show-errors | ConvertFrom-Json

    if ($webtests.Count -eq 0) {
        Write-Host "No web tests found." -ForegroundColor Yellow
        return
    }

    Write-Host "Found $($webtests.Count) web tests to enable" -ForegroundColor Yellow

    # Enable using az resource update for government cloud compatibility
    $webtests | ForEach-Object -Parallel {
        $webtest = $_
        $webtestName = $webtest.name
        $webtestId = $webtest.id
        
        az resource update `
            --ids $webtestId `
            --set properties.enabled=true `
            --output none `
            --only-show-errors | Out-Null
        
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Enabled web test: $webtestName" -ForegroundColor Green
        } else {
            Write-Host "Failed to enable web test: $webtestName" -ForegroundColor Red
        }
    } -ThrottleLimit 10
}


if ($destinationNamespace -eq "manufacturo") {
    $backend_health_alert = "${destination_lower}_backend_health"
}else{
    $backend_health_alert = "${destination_lower}-${destinationNamespace}_backend_health"
}

$graph_query = "
resources
| where type == 'microsoft.insights/metricalerts'
| where name contains '$backend_health_alert'
| where resourceGroup contains 'hub'
| project name, resourceGroup, subscriptionId
"

$hubs_alerts = az graph query -q $graph_query --query "data" --first 1000 | ConvertFrom-Json

foreach ($hub in $hubs_alerts) {

    $shared_source_subscription = $hub[0].subscriptionId
    $alert_name = $hub[0].name
    $destination_hub_rg = $hub[0].resourceGroup

    if ($alert_name) {
        az monitor metrics alert update `
            --enabled "true" `
            --name $alert_name `
            --resource-group $destination_hub_rg `
            --subscription $shared_source_subscription `
            --only-show-errors
        Write-Host "Enabled alert: $alert_name" -ForegroundColor Green
    } else {
        Write-Host "No matching alert found in Shared subscription." -ForegroundColor Yellow
    }
} 

Write-Host "`nEnvironment startup complete." -ForegroundColor Cyan
