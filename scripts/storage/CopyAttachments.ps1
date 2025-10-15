param (
    [Parameter(Mandatory)][string]$source,
    [Parameter(Mandatory)][string]$destination,
    [Parameter(Mandatory)][string]$DestinationNamespace,
    [Parameter(Mandatory)][string]$SourceNamespace,
    [switch]$DryRun
)

if ($DryRun) {
    Write-Host "`n🔍 DRY RUN MODE - Copy Attachments" -ForegroundColor Yellow
    Write-Host "===================================" -ForegroundColor Yellow
    Write-Host "No actual copy operations will be performed" -ForegroundColor Yellow
} else {
    Write-Host "`n=========================" -ForegroundColor Cyan
    Write-Host " Copy Attachments" -ForegroundColor Cyan
    Write-Host "===========================`n" -ForegroundColor Cyan
}

$source_lower = (Get-Culture).TextInfo.ToLower($source)
$destination_lower = (Get-Culture).TextInfo.ToLower($destination)

# Detect source context
if ($SourceNamespace -eq "manufacturo") {
    # Special handling for "manufacturo" - use standard storage account names
    $graph_query = "
        resources
        | where type == 'microsoft.storage/storageaccounts'
        | where tags.Environment == '$source_lower' and tags.Type == 'Primary' and name contains 'samnfro'
        | project name, resourceGroup, subscriptionId
    "
} else {
    # Write-Host "Detecting SOURCE as Multitenant..."
    $graph_query = "
        resources
        | where type == 'microsoft.storage/storageaccounts'
        | where tags.Environment == '$source_lower' and tags.Type == 'Primary' and name contains 'sa$SourceNamespace'
        | project name, resourceGroup, subscriptionId
    "
}

$src_sa = az graph query -q $graph_query --query "data" --first 1000 | ConvertFrom-Json

# Check if we got any results
if (-not $src_sa -or $src_sa.Count -eq 0) {
    Write-Host "❌ Error: No storage accounts found for source environment '$source' with multitenant '$SourceNamespace'" -ForegroundColor Red
    Write-Host "Graph query: $graph_query" -ForegroundColor Gray
    $global:LASTEXITCODE = 1
    throw "No storage accounts found for source environment '$source' with multitenant '$SourceNamespace'"
}

$source_subscription = $src_sa[0].subscriptionId
$source_account = $src_sa[0].name
$source_rg = $src_sa[0].resourceGroup

# Detect destination context
if ($DestinationNamespace -eq "manufacturo") {
    Write-Host "Detecting DESTINATION as Subscription..."
    $graph_query = "
        resources
        | where type == 'microsoft.storage/storageaccounts'
        | where tags.Environment == '$destination_lower' and tags.Type == 'Primary' and name contains 'samnfro'
        | project name, resourceGroup, subscriptionId
    "
} else {
    Write-Host " Detecting DESTINATION as Multitenant..."
    $graph_query = "
        resources
        | where type == 'microsoft.storage/storageaccounts'
        | where tags.Environment == '$destination_lower' and tags.Type == 'Primary' and name contains 'sa$DestinationNamespace'
        | project name, resourceGroup, subscriptionId
    "
}

$dst_sa = az graph query -q $graph_query --query "data" --first 1000 | ConvertFrom-Json

# Check if we got any results
if (-not $dst_sa -or $dst_sa.Count -eq 0) {
    Write-Host "❌ Error: No storage accounts found for destination environment '$destination' with multitenant '$DestinationNamespace'" -ForegroundColor Red
    Write-Host "Graph query: $graph_query" -ForegroundColor Gray
    $global:LASTEXITCODE = 1
    throw "No storage accounts found for destination environment '$destination' with multitenant '$DestinationNamespace'"
}

$dest_subscription = $dst_sa[0].subscriptionId
$dest_account = $dst_sa[0].name
$dest_rg = $dst_sa[0].resourceGroup

$containers = @(
    "reports",
    "ewp-attachments",
    "core-attachments",
    "nc-attachments",
    "integrator-plus-site-files",
    "file-storage"
)

# Use azcopy with azcli login
$env:AZCOPY_AUTO_LOGIN_TYPE = "AZCLI"

Write-Host "Source Storage Account: $($source_account) (Resource Group: $($source_rg))" -ForegroundColor Green
Write-Host "Destination Storage Account: $($dest_account) (Resource Group: $($dest_rg))" -ForegroundColor Green

if ($DryRun) {
    Write-Host "🔍 DRY RUN: Would open firewall rules for storage accounts..." -ForegroundColor Yellow
    Write-Host "🔍 DRY RUN: Would copy the following containers:" -ForegroundColor Yellow
    foreach ($containerName in $containers) {
        Write-Host "  • $containerName" -ForegroundColor Gray
    }
    Write-Host "🔍 DRY RUN: Would close firewall rules after copy..." -ForegroundColor Yellow
    Write-Host "`n🔍 DRY RUN: Copy attachments preview completed." -ForegroundColor Yellow
} else {
    # Open firewall rules
    az storage account update `
        --resource-group $dest_rg `
        --name $dest_account `
        --subscription $dest_subscription `
        --default-action Allow -o none

    if ($LASTEXITCODE -eq 0) {
        Write-Host "Opening firewall rules for storage accounts... $dest_account" -ForegroundColor Cyan
    } else {
        Write-Host "Opening firewall rules failed" -ForegroundColor Red
    }

    az storage account update `
        --resource-group $source_rg `
        --name $source_account `
        --subscription $source_subscription `
        --default-action Allow -o none

    if ($LASTEXITCODE -eq 0) {
        Write-Host "Opening firewall rules for storage accounts... $source_account" -ForegroundColor Cyan
    } else {
        Write-Host "Opening firewall rules failed" -ForegroundColor Red
    }

    Write-Host "Waiting 30 seconds for firewall rules to take effect..." -ForegroundColor Yellow
    Start-Sleep -Seconds 30

    $source_blob_endpoint = az storage account show --name "$source_account" --subscription "$source_subscription" --query "primaryEndpoints.blob" -o tsv
    $dest_blob_endpoint = az storage account show --name "$dest_account" --subscription "$dest_subscription" --query "primaryEndpoints.blob" -o tsv 

    Write-Host "`nStarting Blob copy..." -ForegroundColor Cyan

    foreach ($containerName in $containers) {
        $sourceUrl = "${source_blob_endpoint}${containerName}"
        $destUrl = "${dest_blob_endpoint}${containerName}"

        Write-Host "Copying container '$containerName'..." -ForegroundColor Green
        Write-Host "From: $sourceUrl"
        Write-Host "To:   $destUrl"

        # Start azcopy with progress info and error handling
        azcopy copy $sourceUrl $destUrl --recursive --log-level DEBUG
    }

    # Close firewall rules (disable public network access)
    az storage account update `
        --resource-group $dest_rg `
        --name $dest_account `
        --subscription $dest_subscription `
        --default-action Deny -o none

    if ($LASTEXITCODE -eq 0) {
        Write-Host "Closing firewall rules for storage accounts... $dest_account" -ForegroundColor Cyan
    } else {
        Write-Host "Closing firewall rules failed" -ForegroundColor Red
    }

    az storage account update `
        --resource-group $source_rg `
        --name $source_account `
        --subscription $source_subscription `
        --default-action Deny -o none

    if ($LASTEXITCODE -eq 0) {
        Write-Host "Closing firewall rules for storage accounts... $source_account" -ForegroundColor Cyan
    } else {
        Write-Host "Closing firewall rules failed" -ForegroundColor Red
    }
    Write-Host "`nCopy attachments completed." -ForegroundColor Cyan
}