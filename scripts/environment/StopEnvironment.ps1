param (
    [string]$Destination,
    [AllowEmptyString()][string]$DestinationNamespace,
    [string]$Cloud,
    [switch]$DryRun
)

# ============================================================================
# DRY RUN FAILURE TRACKING
# ============================================================================
# Track validation failures in dry run mode to fail at the end
$script:DryRunHasFailures = $false
$script:DryRunFailureReasons = @()

# Setup Azure AKS credentials using discovered cluster information
$Destination_lower = (Get-Culture).TextInfo.ToLower($Destination)

$graph_query = "
  resources
  | where type =~ 'microsoft.containerservice/managedclusters'
  | where tags.Environment == '$Destination_lower' and tags.Type == 'Primary'
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
    Write-Host "🔴 PROBLEM: No AKS cluster found for environment '$Destination'"
    Write-Host "   └─ Query returned no results for tags.Environment='$Destination_lower' and tags.Type='Primary'"
    Write-Host ""
    Write-Host "💡 SOLUTIONS:"
    Write-Host "   1. Verify environment name is correct (provided: '$Destination')"
    Write-Host "   2. Check if AKS cluster exists in Azure Portal"
    Write-Host "   3. Verify cluster has required tags:"
    Write-Host "      • Environment = '$Destination_lower'"
    Write-Host "      • Type = 'Primary'"
    Write-Host ""
    
    if ($DryRun) {
        Write-Host "⚠️  DRY RUN WARNING: No AKS cluster found for environment" -ForegroundColor Yellow
        Write-Host "⚠️  In production, this would abort the operation" -ForegroundColor Yellow
        Write-Host "⚠️  Skipping remaining steps..." -ForegroundColor Yellow
        Write-Host ""
        # Track this failure for final dry run summary
        $script:DryRunHasFailures = $true
        $script:DryRunFailureReasons += "No AKS cluster found for environment '$Destination'"
        # Skip to end of script for dry run summary
        return
    } else {
        Write-Host "🛑 ABORTING: Cannot stop environment without cluster information"
        Write-Host ""
        $global:LASTEXITCODE = 1
        throw "No AKS cluster found for environment - cannot stop environment without cluster information"
    }
}

$Destination_subscription = $recources[0].subscriptionId
$Destination_aks = $recources[0].name
$Destination_rg = $recources[0].resourceGroup

Write-Host "🔧 SETUP: Configuring Azure AKS credentials..."
Write-Host "   Cluster: $Destination_aks" -ForegroundColor Gray
Write-Host "   Resource Group: $Destination_rg" -ForegroundColor Gray
Write-Host "   Subscription: $Destination_subscription" -ForegroundColor Gray

try {
    # Build az aks get-credentials command with discovered parameters
    $aks_cmd = "az aks get-credentials --resource-group $Destination_rg --name $Destination_aks --subscription $Destination_subscription --overwrite-existing"
    
    Write-Host "   Executing: $aks_cmd" -ForegroundColor Gray
    Invoke-Expression $aks_cmd
    
    # Convert kubelogin to different login mode
    $kubelogin_cmd = "kubelogin convert-kubeconfig -l azurecli"
    Write-Host "   Executing: $kubelogin_cmd" -ForegroundColor Gray
    Invoke-Expression $kubelogin_cmd

    # Verify the context was set successfully
    $current_context = kubectl config current-context 2>$null
    if ($current_context -eq $Destination_aks) {
        Write-Host "✅ SUCCESS: Kubernetes context set to $current_context"
    } else {
        Write-Host "⚠️  WARNING: Kubernetes context may not match (Expected: $Destination_aks, Got: $current_context)"
    }
} catch {
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════"
    Write-Host "❌ FATAL ERROR: AKS Credentials Setup Failed"
    Write-Host "═══════════════════════════════════════════════"
    Write-Host ""
    Write-Host "🔴 PROBLEM: Cannot authenticate to Kubernetes cluster"
    Write-Host "   └─ Error: $($_.Exception.Message)"
    Write-Host ""
    Write-Host "💡 SOLUTIONS:"
    Write-Host "   1. Verify Azure CLI is authenticated (run 'az account show')"
    Write-Host "   2. Check if kubectl is installed and accessible"
    Write-Host "   3. Check if kubelogin is installed and accessible"
    Write-Host "   4. Verify permissions on cluster: $Destination_aks"
    Write-Host "   5. Try running manually:"
    Write-Host "      az aks get-credentials --resource-group $Destination_rg --name $Destination_aks"
    Write-Host ""
    
    if ($DryRun) {
        Write-Host "⚠️  DRY RUN WARNING: Failed to get AKS credentials" -ForegroundColor Yellow
        Write-Host "⚠️  In production, this would abort the operation" -ForegroundColor Yellow
        Write-Host "⚠️  Skipping remaining steps..." -ForegroundColor Yellow
        Write-Host ""
        # Track this failure for final dry run summary
        $script:DryRunHasFailures = $true
        $script:DryRunFailureReasons += "Failed to get AKS credentials for cluster '$Destination_aks'"
        # Skip to end of script for dry run summary
        return
    } else {
        Write-Host "🛑 ABORTING: Cannot proceed without Kubernetes cluster access"
        Write-Host ""
        $global:LASTEXITCODE = 1
        throw "Failed to get AKS credentials - cannot proceed without Kubernetes cluster access"
    }
}

if ($DryRun) {
    Write-Host "`n🔍 DRY RUN MODE - Azure Environment Shutdown" -ForegroundColor Yellow
    Write-Host "=============================================" -ForegroundColor Yellow
    Write-Host "No actual shutdown operations will be performed" -ForegroundColor Yellow
} else {
    Write-Host "`n=========================" -ForegroundColor Cyan
    Write-Host " Azure Environment Shutdown" -ForegroundColor Cyan
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

function Downscale-BlackboxMonitoring {
    param(
        [string]$Namespace
    )

    Write-Host "Downscaling blackbox monitoring deployments..." -ForegroundColor Cyan
    
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
        Write-Host "Downscaling blackbox monitoring deployment: $deploymentName" -ForegroundColor Green
        kubectl scale deployment/$deploymentName --replicas=0 -n $Namespace
    }
    
    Write-Host "Blackbox monitoring deployments downscaled successfully." -ForegroundColor Green
}

function Downscale-Deployments {
    param(
        [string]$Namespace
    )

    # Get list of all pods in the cluster
    $deployments = Get-PodsInCluster -Namespace $Namespace
    foreach ($deployment in $deployments){
        $deployment = $deployment.metadata.name
        Write-Host "Downscale deployment: $deployment" -ForegroundColor Green
        kubectl scale deployment/$deployment --replicas=0 -n $Namespace
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

if ($DryRun) {
    # Use az resource list for government cloud compatibility
    $webtests = az resource list `
        --subscription $Destination_subscription `
        --resource-group $Destination_rg `
        --resource-type "Microsoft.Insights/webtests" `
        --output json `
        --only-show-errors | ConvertFrom-Json

    if ($webtests.Count -eq 0) {
        Write-Host "No web tests found." -ForegroundColor Yellow
        return
    }

    Write-Host "🔍 DRY RUN: Would disable $($webtests.Count) web tests:" -ForegroundColor Yellow
    $webtests | ForEach-Object {
        Write-Host "  • $($_.name)" -ForegroundColor Gray
    }
} else {
    # Use az resource list for government cloud compatibility
    $webtests = az resource list `
        --subscription $Destination_subscription `
        --resource-group $Destination_rg `
        --resource-type "Microsoft.Insights/webtests" `
        --output json `
        --only-show-errors | ConvertFrom-Json

    if ($webtests.Count -eq 0) {
        Write-Host "No web tests found." -ForegroundColor Yellow
        return
    }

    Write-Host "Found $($webtests.Count) web tests to disable" -ForegroundColor Yellow

    # Disable using az resource update for government cloud compatibility
    $webtests | ForEach-Object -Parallel {
        $webtest = $_
        $webtestName = $webtest.name
        $webtestId = $webtest.id
        
        az resource update `
            --ids $webtestId `
            --set properties.enabled=false `
            --output none `
            --only-show-errors
        
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Disabled web test: $webtestName" -ForegroundColor Green
        } else {
            Write-Host "Failed to disable web test: $webtestName" -ForegroundColor Red
        }
    } -ThrottleLimit 10
}


if ($DestinationNamespace -eq "manufacturo") {
    $backend_health_alert = "${Destination_lower}_backend_health"
}else{
    $backend_health_alert = "${Destination_lower}-${DestinationNamespace}_backend_health"
}


$graph_query = "
resources
| where type == 'microsoft.insights/metricalerts'
| where name contains '$backend_health_alert'
| where resourceGroup contains 'hub'
| project name, resourceGroup, subscriptionId
"

$hubs_alerts = az graph query -q $graph_query --query "data" --first 1000 | ConvertFrom-Json

if ($DryRun) {
    Write-Host "🔍 DRY RUN: Would disable backend health alerts..." -ForegroundColor Yellow
    if ($hubs_alerts.Count -gt 0) {
        Write-Host "🔍 DRY RUN: Would disable $($hubs_alerts.Count) alerts:" -ForegroundColor Yellow
        foreach ($hub in $hubs_alerts) {
            $alert_name = $hub[0].name
            Write-Host "  • $alert_name" -ForegroundColor Gray
        }
    } else {
        Write-Host "No matching alerts $alert_name found in Shared subscription." -ForegroundColor Yellow
    }
} else {
    foreach ($hub in $hubs_alerts) {

        $shared_Destination_subscription = $hub[0].subscriptionId
        $alert_name = $hub[0].name
        $Destination_hub_rg = $hub[0].resourceGroup

        if ($alert_name) {
            az monitor metrics alert update `
                --enabled "false" `
                --name $alert_name `
                --resource-group $Destination_hub_rg `
                --subscription $shared_Destination_subscription `
                --output none `
                --only-show-errors | Out-Null
            Write-Host "Disabled alert: $alert_name" -ForegroundColor Green
        } else {
            Write-Host "No matching alert $alert_name found in Shared subscription." -ForegroundColor Yellow
        }
    }
} 

if ($DryRun) {
    Write-Host "🔍 DRY RUN: Would set cluster context to: $Destination_aks" -ForegroundColor Gray
    Write-Host "🔍 DRY RUN: Would downscale blackbox monitoring in 'monitoring' namespace" -ForegroundColor Gray
    Write-Host "🔍 DRY RUN: Would downscale deployments in '$DestinationNamespace' namespace" -ForegroundColor Gray
    Write-Host ""
    
    # Check if there were any validation failures during dry run
    if ($script:DryRunHasFailures) {
        Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Red
        Write-Host "❌ DRY RUN COMPLETED WITH WARNINGS" -ForegroundColor Red
        Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Red
        Write-Host ""
        Write-Host "⚠️  The following issues would cause production run to FAIL:" -ForegroundColor Yellow
        Write-Host ""
        foreach ($reason in $script:DryRunFailureReasons) {
            Write-Host "   • $reason" -ForegroundColor Yellow
        }
        Write-Host ""
        Write-Host "🔧 Please resolve these issues before running in production mode" -ForegroundColor Yellow
        Write-Host ""
        $global:LASTEXITCODE = 1
        exit 1
    } else {
        Write-Host "✅ DRY RUN COMPLETED SUCCESSFULLY - No issues detected" -ForegroundColor Green
        exit 0
    }
} else {
    Set-ClusterContext -ClusterContext $Destination_aks
    Downscale-BlackboxMonitoring -Namespace "monitoring"
    Downscale-Deployments -Namespace $DestinationNamespace
}

