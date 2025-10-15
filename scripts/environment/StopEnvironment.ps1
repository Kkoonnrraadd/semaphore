param (
    [string]$source,
    [AllowEmptyString()][string]$sourceNamespace,
    [string]$Cloud,
    [switch]$DryRun
)

# Setup Azure AKS credentials using discovered cluster information
$source_lower = (Get-Culture).TextInfo.ToLower($source)

$graph_query = "
  resources
  | where type =~ 'microsoft.containerservice/managedclusters'
  | where tags.Environment == '$source_lower' and tags.Type == 'Primary'
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
    Write-Host "🔴 PROBLEM: No AKS cluster found for environment '$source'"
    Write-Host "   └─ Query returned no results for tags.Environment='$source_lower' and tags.Type='Primary'"
    Write-Host ""
    Write-Host "💡 SOLUTIONS:"
    Write-Host "   1. Verify environment name is correct (provided: '$source')"
    Write-Host "   2. Check if AKS cluster exists in Azure Portal"
    Write-Host "   3. Verify cluster has required tags:"
    Write-Host "      • Environment = '$source_lower'"
    Write-Host "      • Type = 'Primary'"
    Write-Host ""
    
    if ($DryRun) {
        Write-Host "🔍 DRY RUN: Production run would abort here"
        Write-Host ""
        $global:LASTEXITCODE = 1
        throw "DRY RUN: No AKS cluster found for environment"
    } else {
        Write-Host "🛑 ABORTING: Cannot stop environment without cluster information"
        Write-Host ""
        $global:LASTEXITCODE = 1
        throw "No AKS cluster found for environment - cannot stop environment without cluster information"
    }
}

$source_subscription = $recources[0].subscriptionId
$source_aks = $recources[0].name
$source_rg = $recources[0].resourceGroup

Write-Host "🔧 SETUP: Configuring Azure AKS credentials..."
Write-Host "   Cluster: $source_aks" -ForegroundColor Gray
Write-Host "   Resource Group: $source_rg" -ForegroundColor Gray
Write-Host "   Subscription: $source_subscription" -ForegroundColor Gray

try {
    # Build az aks get-credentials command with discovered parameters
    $aks_cmd = "az aks get-credentials --resource-group $source_rg --name $source_aks --subscription $source_subscription --overwrite-existing"
    
    Write-Host "   Executing: $aks_cmd" -ForegroundColor Gray
    Invoke-Expression $aks_cmd
    
    # Convert kubelogin to different login mode
    $kubelogin_cmd = "kubelogin convert-kubeconfig -l azurecli"
    Write-Host "   Executing: $kubelogin_cmd" -ForegroundColor Gray
    Invoke-Expression $kubelogin_cmd

    # Verify the context was set successfully
    $current_context = kubectl config current-context 2>$null
    if ($current_context -eq $source_aks) {
        Write-Host "✅ SUCCESS: Kubernetes context set to $current_context"
    } else {
        Write-Host "⚠️  WARNING: Kubernetes context may not match (Expected: $source_aks, Got: $current_context)"
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
    Write-Host "   4. Verify permissions on cluster: $source_aks"
    Write-Host "   5. Try running manually:"
    Write-Host "      az aks get-credentials --resource-group $source_rg --name $source_aks"
    Write-Host ""
    
    if ($DryRun) {
        Write-Host "🔍 DRY RUN: Production run would abort here"
        Write-Host ""
        $global:LASTEXITCODE = 1
        throw "DRY RUN: Failed to get AKS credentials - cannot access Kubernetes cluster"
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
    Write-Host "🔍 DRY RUN: Would disable Application Insights web tests..." -ForegroundColor Yellow
    Write-Host "Using Azure cloud: $Cloud" -ForegroundColor Gray
    
    if ($Cloud -eq "AzureCloud") {
        Write-Host "🔍 DRY RUN: Would use classic Azure CLI web test commands for Commercial cloud..." -ForegroundColor Yellow
        
        # Retrieve tests once using classic method
        $webtests = az monitor app-insights web-test list `
            --subscription $source_subscription `
            --output json | ConvertFrom-Json

        if ($webtests.Count -eq 0) {
            Write-Host "No web tests found." -ForegroundColor Yellow
            return
        }

        Write-Host "🔍 DRY RUN: Would disable $($webtests.Count) web tests:" -ForegroundColor Yellow
        $webtests | ForEach-Object {
            Write-Host "  • $($_.name)" -ForegroundColor Gray
        }
    } else {
        Write-Host "🔍 DRY RUN: Would use generic Azure resource commands for Government/Other clouds..." -ForegroundColor Yellow
        
        # Use az resource list for government cloud compatibility
        $webtests = az resource list `
            --subscription $source_subscription `
            --resource-group $source_rg `
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
    }
} else {
    Write-Host "Disabling Application Insights web tests..."

    Write-Host "Using Azure cloud: $Cloud" -ForegroundColor Gray

    if ($Cloud -eq "AzureCloud") {
        Write-Host "Using classic Azure CLI web test commands for Commercial cloud..." -ForegroundColor Cyan
        
        # Retrieve tests once using classic method
        $webtests = az monitor app-insights web-test list `
            --subscription $source_subscription `
            --output json | ConvertFrom-Json

        if ($webtests.Count -eq 0) {
            Write-Host "No web tests found." -ForegroundColor Yellow
            return
        }

        # Disable web tests in parallel using classic method
        $webtests | ForEach-Object -Parallel {
            az monitor app-insights web-test update `
                --name $_.name `
                --resource-group $using:source_rg `
                --enabled false `
                --subscription $using:source_subscription `
                --output none `
                --only-show-errors | Out-Null

            Write-Host "Disabled web test: $($_.name)" -ForegroundColor Green
        } -ThrottleLimit 10
    } else {
        Write-Host "Using generic Azure resource commands for Government/Other clouds..." -ForegroundColor Cyan
        
        # Use az resource list for government cloud compatibility
        $webtests = az resource list `
            --subscription $source_subscription `
            --resource-group $source_rg `
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
}


if ($sourceNamespace -eq "manufacturo") {
    $backend_health_alert = "${source_lower}_backend_health"
}else{
    $backend_health_alert = "${source_lower}-${sourceNamespace}_backend_health"
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
        Write-Host "No matching alerts found in Shared subscription." -ForegroundColor Yellow
    }
} else {
    foreach ($hub in $hubs_alerts) {

        $shared_source_subscription = $hub[0].subscriptionId
        $alert_name = $hub[0].name
        $source_hub_rg = $hub[0].resourceGroup

        if ($alert_name) {
            az monitor metrics alert update `
                --enabled "false" `
                --name $alert_name `
                --resource-group $source_hub_rg `
                --subscription $shared_source_subscription `
                --output none `
                --only-show-errors | Out-Null
            Write-Host "Disabled alert: $alert_name" -ForegroundColor Green
        } else {
            Write-Host "No matching alert found in Shared subscription." -ForegroundColor Yellow
        }
    }
} 

if ($DryRun) {
    Write-Host "🔍 DRY RUN: Would set cluster context to: $source_aks" -ForegroundColor Gray
    Write-Host "🔍 DRY RUN: Would downscale blackbox monitoring in 'monitoring' namespace" -ForegroundColor Gray
    Write-Host "🔍 DRY RUN: Would downscale deployments in '$sourceNamespace' namespace" -ForegroundColor Gray
} else {
    Set-ClusterContext -ClusterContext $source_aks
    Downscale-BlackboxMonitoring -Namespace "monitoring"
    Downscale-Deployments -Namespace $sourceNamespace
}

