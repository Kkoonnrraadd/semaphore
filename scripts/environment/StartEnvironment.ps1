param (
    [string]$destination,
    [AllowEmptyString()][string]$destinationNamespace,
    [string]$Cloud,
    [switch]$DryRun
)

if ($DryRun) {
    Write-Host "`n🔍 DRY RUN MODE - Azure Environment Start"
    Write-Host "========================================="
    Write-Host "No actual environment startup operations will be performed"
} else {
    Write-Host "`n🚀 STARTING ENVIRONMENT"
    Write-Host "========================="
    Write-Host "Azure Environment Start Operations`n"
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

    Write-Host "🔄 UPSCALING: Blackbox monitoring deployments..."
    
    # Get list of all deployments in the namespace
    $deployments = Get-PodsInCluster -Namespace $Namespace
    
    # Filter for blackbox monitoring deployments
    $blackboxDeployments = $deployments | Where-Object { 
        $_.metadata.name -like "*blackbox*"
    }
    
    if ($blackboxDeployments.Count -eq 0) {
        Write-Host "⚠️  WARNING: No blackbox monitoring deployments found in namespace: $Namespace"
        return
    }
    
    foreach ($deployment in $blackboxDeployments) {
        $deploymentName = $deployment.metadata.name
        Write-Host "✅ SUCCESS: Upscaled blackbox monitoring deployment: $deploymentName"
        kubectl scale deployment/$deploymentName --replicas=1 -n $Namespace
    }
    
    Write-Host "✅ SUCCESS: Blackbox monitoring deployments upscaled"
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

        Write-Host "✅ SCALING: Deployment $deployment to $count replicas"
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

# ═══════════════════════════════════════════════════════════════
# CRITICAL CHECK: Verify AKS cluster was found
# ═══════════════════════════════════════════════════════════════
if (-not $recources -or $recources.Count -eq 0) {
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════"
    Write-Host "❌ FATAL ERROR: AKS Cluster Not Found"
    Write-Host "═══════════════════════════════════════════════"
    Write-Host ""
    Write-Host "🔴 PROBLEM: No AKS cluster found for environment '$destination'"
    Write-Host "   └─ Query returned no results for tags.Environment='$destination_lower' and tags.Type='Primary'"
    Write-Host ""
    Write-Host "💡 SOLUTIONS:"
    Write-Host "   1. Verify environment name is correct (provided: '$destination')"
    Write-Host "   2. Check if AKS cluster exists in Azure Portal"
    Write-Host "   3. Verify cluster has required tags:"
    Write-Host "      • Environment = '$destination_lower'"
    Write-Host "      • Type = 'Primary'"
    Write-Host ""
    
    if ($DryRun) {
        Write-Host "🔍 DRY RUN: Production run would abort here"
        Write-Host ""
        $global:LASTEXITCODE = 1
        throw "DRY RUN: No AKS cluster found for destination environment"
    } else {
        Write-Host "🛑 ABORTING: Cannot start environment without cluster information"
        Write-Host ""
        $global:LASTEXITCODE = 1
        throw "No AKS cluster found for destination environment - cannot start environment without cluster information"
    }
}

$destination_subscription = $recources[0].subscriptionId
$destination_aks = $recources[0].name
$destination_rg = $recources[0].resourceGroup

if ($DryRun) {
    Write-Host "`n🔍 DRY RUN: DISCOVERING ENVIRONMENT STARTUP OPERATIONS"
    Write-Host "=================================================="
    
    Write-Host "🔍 DRY RUN: Environment: $destination"
    Write-Host "   └─ AKS Cluster: $destination_aks"
    Write-Host "   └─ Resource Group: $destination_rg"
    Write-Host "   └─ Subscription: $destination_subscription"
    
    Write-Host "🔍 DRY RUN: Would set cluster context to: $destination_aks"
    Write-Host "🔍 DRY RUN: Would upscale blackbox monitoring in 'monitoring' namespace"
    Write-Host "🔍 DRY RUN: Would scale up deployments in '$destinationNamespace' namespace"
    
    # Discover what deployments would be scaled
    try {
        Write-Host "🔍 DRY RUN: Would scale these deployments to 1 replica:"
        Write-Host "   • All deployments in namespace '$destinationNamespace'"
        Write-Host "   • Special case: eworkin-plus-nonconformance-backend (3 replicas)"
        Write-Host "   • Special case: eworkin-plus-backend (3 replicas)"
    }
    catch {
        Write-Host "   • Could not discover deployments (cluster may be stopped)"
    }

    
    # Discover web tests that would be enabled
    Write-Host "`n🔍 DRY RUN: Would enable Application Insights web tests:"
    if ($Cloud -eq "AzureCloud") {
        $webtests = az monitor app-insights web-test list `
            --subscription $destination_subscription `
            --only-show-errors `
            --output json | ConvertFrom-Json
        
        if ($webtests.Count -gt 0) {
            Write-Host "🔍 DRY RUN: Would enable $($webtests.Count) web tests:"
            $webtests | ForEach-Object {
                Write-Host "  • $($_.name)"
            }
        } else {
            Write-Host "🔍 DRY RUN: No web tests found to enable"
        }
    } else {
        $webtests = az resource list `
            --subscription $destination_subscription `
            --resource-group $destination_rg `
            --resource-type "Microsoft.Insights/webtests" `
            --output json `
            --only-show-errors | ConvertFrom-Json
        
        if ($webtests.Count -gt 0) {
            Write-Host "🔍 DRY RUN: Would enable $($webtests.Count) web tests:"
            $webtests | ForEach-Object {
                Write-Host "  • $($_.name)"
            }
        } else {
            Write-Host "🔍 DRY RUN: No web tests found to enable"
        }
    }
    
    # Discover alerts that would be enabled
    Write-Host "`n🔍 DRY RUN: Would enable backend health alerts:"
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
        Write-Host "🔍 DRY RUN: Would enable $($hubs_alerts.Count) alerts:"
        foreach ($hub in $hubs_alerts) {
            $alert_name = $hub[0].name
            Write-Host "  • $alert_name"
        }
    } else {
        Write-Host "🔍 DRY RUN: No alerts found to enable"
    }
    
    Write-Host "`n🔍 DRY RUN: Environment startup preview completed."
    exit 0
}



Set-ClusterContext -ClusterContext $destination_aks
Upscale-BlackboxMonitoring -Namespace "monitoring"
Downscale-Deployments -Namespace $destinationNamespace


Write-Host "`nEnabling Application Insights web tests..."

Write-Host "Using Azure cloud: $Cloud"

if ($Cloud -eq "AzureCloud") {
    Write-Host "Using classic Azure CLI web test commands for Commercial cloud..."
    
    # Fetch all web tests once using classic method
    $webtests = az monitor app-insights web-test list `
        --subscription $destination_subscription `
        --only-show-errors `
        --output json | ConvertFrom-Json

    if ($webtests.Count -eq 0) {
        Write-Host "No web tests found."
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

        Write-Host "✅ ENABLED: Web test $($_.name)"
    } -ThrottleLimit 10
}
else {
    Write-Host "Using generic Azure resource commands for Government/Other clouds..."
    
    # Use az resource list for government cloud compatibility
    $webtests = az resource list `
        --subscription $destination_subscription `
        --resource-group $destination_rg `
        --resource-type "Microsoft.Insights/webtests" `
        --output json `
        --only-show-errors | ConvertFrom-Json

    if ($webtests.Count -eq 0) {
        Write-Host "No web tests found."
        return
    }

    Write-Host "Found $($webtests.Count) web tests to enable"

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
            Write-Host "Enabled web test: $webtestName"
        } else {
            Write-Host "❌ FAILED: Could not enable web test $webtestName"
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
        Write-Host "✅ ENABLED: Alert $alert_name"
    } else {
        Write-Host "⚠️  WARNING: No matching alert found in Shared subscription"
    }
} 

Write-Host "`n✅ SUCCESS: Environment startup complete"
