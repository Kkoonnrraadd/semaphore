param (
    [Parameter(Mandatory)][string]$Source,
    [Parameter(Mandatory)][string]$Destination,
    [Parameter(Mandatory)][string]$DestinationNamespace,
    [Parameter(Mandatory)][string]$SourceNamespace,
    [switch]$DryRun,
    [switch]$UseSasTokens  # Use SAS tokens for long-running operations (3TB+ containers)
)

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

function New-ContainerSasToken {
    param(
        [string]$StorageAccount,
        [string]$ResourceGroup,
        [string]$SubscriptionId,
        [string]$ContainerName,
        [int]$ExpiryHours = 8  # Default 8 hours for very large copies
    )
    
    try {
        # Calculate expiry time
        $expiryTime = (Get-Date).AddHours($ExpiryHours).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        
        # Generate SAS token with read and list permissions for source
        $sasToken = az storage container generate-sas `
            --account-name $StorageAccount `
            --name $ContainerName `
            --subscription $SubscriptionId `
            --permissions rl `
            --expiry $expiryTime `
            --auth-mode login `
            --as-user `
            -o tsv 2>$null
        
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($sasToken)) {
            return $sasToken
        } else {
            Write-Host "    ⚠️  Failed to generate SAS token for container: $ContainerName" -ForegroundColor Yellow
            return $null
        }
    } catch {
        Write-Host "    ⚠️  Error generating SAS token: $($_.Exception.Message)" -ForegroundColor Yellow
        return $null
    }
}

function New-ContainerSasTokenWithWrite {
    param(
        [string]$StorageAccount,
        [string]$ResourceGroup,
        [string]$SubscriptionId,
        [string]$ContainerName,
        [int]$ExpiryHours = 8
    )
    
    try {
        # Calculate expiry time
        $expiryTime = (Get-Date).AddHours($ExpiryHours).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        
        # Generate SAS token with write, list, and create permissions for destination
        $sasToken = az storage container generate-sas `
            --account-name $StorageAccount `
            --name $ContainerName `
            --subscription $SubscriptionId `
            --permissions wlc `
            --expiry $expiryTime `
            --auth-mode login `
            --as-user `
            -o tsv 2>$null
        
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($sasToken)) {
            return $sasToken
        } else {
            Write-Host "    ⚠️  Failed to generate write SAS token for container: $ContainerName" -ForegroundColor Yellow
            return $null
        }
    } catch {
        Write-Host "    ⚠️  Error generating write SAS token: $($_.Exception.Message)" -ForegroundColor Yellow
        return $null
    }
}

# ============================================================================
# MAIN SCRIPT
# ============================================================================

Write-Host ""
Write-Host "═══════════════════════════════════════════════════" -ForegroundColor DarkGray
Write-Host "🔍 PARAMETER DIAGNOSTICS" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════" -ForegroundColor DarkGray
Write-Host "  Source: $Source" -ForegroundColor Gray
Write-Host "  Destination: $Destination" -ForegroundColor Gray
Write-Host "  SourceNamespace: $SourceNamespace" -ForegroundColor Gray
Write-Host "  DestinationNamespace: $DestinationNamespace" -ForegroundColor Gray
Write-Host "  DryRun: $DryRun (Type: $($DryRun.GetType().Name))" -ForegroundColor Gray

if ($UseSasTokens) {
    Write-Host "  🔐 SAS Token mode is ENABLED" -ForegroundColor Magenta
} else {
    $global:LASTEXITCODE = 1
    throw "SAS must be enabled! This is bug, please check current script."
}
Write-Host "═══════════════════════════════════════════════════" -ForegroundColor DarkGray
Write-Host ""

if ($DryRun) {
    Write-Host "`n🔍 DRY RUN MODE - Copy Attachments" -ForegroundColor Yellow
    Write-Host "===================================" -ForegroundColor Yellow
    Write-Host "No actual copy operations will be performed" -ForegroundColor Yellow
    Write-Host "Authentication: SAS Tokens (8-hour expiry)" -ForegroundColor Yellow
} else {
    Write-Host "`n=====================================" -ForegroundColor Cyan
    Write-Host "       Copy Attachments" -ForegroundColor Cyan
    Write-Host "=====================================" -ForegroundColor Cyan
    Write-Host "🔐 Mode: SAS Token Authentication" -ForegroundColor Magenta
    Write-Host "   (Recommended for 3TB+ containers)" -ForegroundColor Gray
    Write-Host ""
}

$Source_lower = (Get-Culture).TextInfo.ToLower($Source)
$Destination_lower = (Get-Culture).TextInfo.ToLower($Destination)

# Detect source context
if ($SourceNamespace -eq "manufacturo") {
    # Special handling for "manufacturo" - use standard storage account names
    $graph_query = "
        resources
        | where type == 'microsoft.storage/storageaccounts'
        | where tags.Environment == '$Source_lower' and tags.Type == 'Primary' and name contains 'samnfro'
        | project name, resourceGroup, subscriptionId
    "
} else {
    Write-Host "❌ Source Namespace $SourceNamespace is not supported. Only 'manufacturo' namespace is supported"
    $global:LASTEXITCODE = 1
    throw "Source Namespace $SourceNamespace is not supported. Only 'manufacturo' namespace is supported"
}
    # Write-Host "Detecting SOURCE as Multitenant..."
    # $graph_query = "
    #     resources
    #     | where type == 'microsoft.storage/storageaccounts'
    #     | where tags.Environment == '$Source_lower' and tags.Type == 'Primary' and name contains 'sa$SourceNamespace'
    #     | project name, resourceGroup, subscriptionId
    # "

$src_sa = az graph query -q $graph_query --query "data" --first 1000 | ConvertFrom-Json

# Check if we got any results
if (-not $src_sa -or $src_sa.Count -eq 0) {
    Write-Host "❌ Error: No storage accounts found for source environment '$Source' with multitenant '$SourceNamespace'" -ForegroundColor Red
    Write-Host "Graph query: $graph_query" -ForegroundColor Gray
    $global:LASTEXITCODE = 1
    throw "No storage accounts found for source environment '$Source' with multitenant '$SourceNamespace'"
}

$Source_subscription = $src_sa[0].subscriptionId
$Source_account = $src_sa[0].name
$Source_rg = $src_sa[0].resourceGroup

# # Detect Destination context
# if ($DestinationNamespace -eq "manufacturo") {
#     # Write-Host "Detecting DESTINATION as Subscription..."
#     $graph_query = "
#         resources
#         | where type == 'microsoft.storage/storageaccounts'
#         | where tags.Environment == '$Destination_lower' and tags.Type == 'Primary' and name contains 'samnfro'
#         | project name, resourceGroup, subscriptionId
#     "
if ($DestinationNamespace -eq "manufacturo") {
    Write-Host "❌ FATAL ERROR: Destination Namespace $DestinationNamespace = manufacturo is not supported!" -ForegroundColor Red
    Write-Host "   This is a protected namespace and cannot be used as a destination." -ForegroundColor Yellow
    Write-Host "   Please specify a different destination namespace." -ForegroundColor Yellow
    Write-Host "" -ForegroundColor Red
} else {
    # Write-Host " Detecting DESTINATION as Multitenant..."
    $graph_query = "
        resources
        | where type == 'microsoft.storage/storageaccounts'
        | where tags.Environment == '$Destination_lower' and tags.Type == 'Primary' and name contains 'sa$DestinationNamespace'
        | project name, resourceGroup, subscriptionId
    "
}

$dst_sa = az graph query -q $graph_query --query "data" --first 1000 | ConvertFrom-Json

# Check if we got any results
if (-not $dst_sa -or $dst_sa.Count -eq 0) {
    Write-Host "❌ Error: No storage accounts found for Destination environment '$Destination' with multitenant '$DestinationNamespace'" -ForegroundColor Red
    Write-Host "Graph query: $graph_query" -ForegroundColor Gray
    $global:LASTEXITCODE = 1
    throw "No storage accounts found for Destination environment '$Destination' with multitenant '$DestinationNamespace'"
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
# $env:AZCOPY_AUTO_LOGIN_TYPE = "AZCLI"

Write-Host "Source Storage Account: $($Source_account) (Resource Group: $($Source_rg))" -ForegroundColor Green
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
        Write-Host "Retrying in 30 seconds..." -ForegroundColor Yellow
        Start-Sleep -Seconds 30
        az storage account update `
            --resource-group $dest_rg `
            --name $dest_account `
            --subscription $dest_subscription `
            --default-action Allow -o none
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Opening firewall rules for storage accounts... $dest_account" -ForegroundColor Cyan
        } else {
            Write-Host "Opening firewall rules failed" -ForegroundColor Red
            $global:LASTEXITCODE = 1
            throw "Opening firewall rules failed"
        }
    }

    az storage account update `
        --resource-group $Source_rg `
        --name $Source_account `
        --subscription $Source_subscription `
        --default-action Allow -o none

    if ($LASTEXITCODE -eq 0) {
        Write-Host "Opening firewall rules for storage accounts... $Source_account" -ForegroundColor Cyan
    } else {
        Write-Host "Opening firewall rules failed" -ForegroundColor Red
        Write-Host "Retrying in 30 seconds..." -ForegroundColor Yellow
        Start-Sleep -Seconds 30
        az storage account update `
            --resource-group $Source_rg `
            --name $Source_account `
            --subscription $Source_subscription `
            --default-action Allow -o none
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Opening firewall rules for storage accounts... $Source_account" -ForegroundColor Cyan
        } else {
            Write-Host "Opening firewall rules failed" -ForegroundColor Red
            $global:LASTEXITCODE = 1
            throw "Opening firewall rules failed"
        }
    }

    Write-Host "Waiting 30 seconds for firewall rules to take effect..." -ForegroundColor Yellow
    Start-Sleep -Seconds 30

    $Source_blob_endpoint = az storage account show --name "$Source_account" --subscription "$Source_subscription" --query "primaryEndpoints.blob" -o tsv
    
    if (-not $Source_blob_endpoint) {
        Write-Host "❌ Error: No source blob endpoint found for storage account: $Source_account" -ForegroundColor Red
        $global:LASTEXITCODE = 1
        throw "No source blob endpoint found for storage account: $Source_account"
    }
    $dest_blob_endpoint = az storage account show --name "$dest_account" --subscription "$dest_subscription" --query "primaryEndpoints.blob" -o tsv 

    if (-not $dest_blob_endpoint) {
        Write-Host "❌ Error: No destination blob endpoint found for storage account: $dest_account" -ForegroundColor Red
        $global:LASTEXITCODE = 1
        throw "No destination blob endpoint found for storage account: $dest_account"
    }

    Write-Host "🚀 STARTING BLOB COPY PROCESS" -ForegroundColor Cyan
    Write-Host "==============================" -ForegroundColor Cyan
    Write-Host "Processing $($containers.Count) containers sequentially" -ForegroundColor White

    
    $copyResults = @()
    $successCount = 0
    $failCount = 0
    $totalStartTime = Get-Date

    foreach ($containerName in $containers) {
        Write-Host "`n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
        Write-Host "📦 Copying container: $containerName" -ForegroundColor Cyan
        Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
        
        $sourceUrl = ""
        $destUrl = ""
             
        $sourceSas = New-ContainerSasToken `
            -StorageAccount $Source_account `
            -ResourceGroup $Source_rg `
            -SubscriptionId $Source_subscription `
            -ContainerName $containerName `
            -ExpiryHours 8

        if (-not $sourceSas) {
            Write-Host "❌ Error: Failed to generate source SAS token for container: $containerName" -ForegroundColor Red
            $global:LASTEXITCODE = 1
            throw "Failed to generate source SAS token for container: $containerName"
        }
        
        $destSas = New-ContainerSasTokenWithWrite `
            -StorageAccount $dest_account `
            -ResourceGroup $dest_rg `
            -SubscriptionId $dest_subscription `
            -ContainerName $containerName `
            -ExpiryHours 8
        
        if (-not $destSas) {
            Write-Host "❌ Error: Failed to generate destination SAS token for container: $containerName" -ForegroundColor Red
            $global:LASTEXITCODE = 1
            throw "Failed to generate destination SAS token for container: $containerName"
        }

        if ($sourceSas -and $destSas) {
            $sourceUrl = "${source_blob_endpoint}${containerName}?${sourceSas}"
            $destUrl = "${dest_blob_endpoint}${containerName}?${destSas}"
            Write-Host "  ✅ SAS tokens generated successfully (valid for 8 hours)" -ForegroundColor Green
        } else {
            Write-Host "  ❌ Failed to generate SAS tokens, falling back to Azure CLI auth" -ForegroundColor Red
            # $UseSasTokens = $false  # Fallback for this container
            $global:LASTEXITCODE = 1
            throw "Failed to generate SAS tokens"
        }


        Write-Host "  From: ${source_blob_endpoint}${containerName}?SOURCE_SAS_TOKEN" -ForegroundColor Gray
        Write-Host "  To:   ${dest_blob_endpoint}${containerName}?DEST_SAS_TOKEN" -ForegroundColor Gray
        Write-Host ""

        
        # Start azcopy with progress info and error handling
        Write-Host "  🔄 Starting copy operation..." -ForegroundColor Yellow
        $copyStartTime = Get-Date
        
        azcopy copy $sourceUrl $destUrl --recursive -log-level INFO
        
        if ($LASTEXITCODE -eq 0) {
            $copyElapsed = (Get-Date) - $copyStartTime
            $copyMinutes = [math]::Round($copyElapsed.TotalMinutes, 1)
            Write-Host ""
            Write-Host "  ✅ Container '$containerName' copied successfully (took $copyMinutes min)" -ForegroundColor Green
            $successCount++
            $copyResults += @{
                Container = $containerName
                Status = "Success"
                Duration = $copyMinutes
            }
            
        } else {
            $copyElapsed = (Get-Date) - $copyStartTime
            $copyMinutes = [math]::Round($copyElapsed.TotalMinutes, 1)
            Write-Host ""
            Write-Host "  ❌ Container '$containerName' copy failed!" -ForegroundColor Red
            Write-Host "  💡 Check azcopy logs for details" -ForegroundColor Yellow
            $failCount++
            $copyResults += @{
                Container = $containerName
                Status = "Failed"
                Duration = $copyMinutes
            }
            
            # Don't stop on failure, continue with other containers
            Write-Host "  ⚠️  Continuing with remaining containers..." -ForegroundColor Yellow
        }
    }
    
    # Summary
    $totalElapsed = (Get-Date) - $totalStartTime
    $totalMinutes = [math]::Round($totalElapsed.TotalMinutes, 1)
    
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "           BLOB COPY SUMMARY" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Total time: $totalMinutes minutes" -ForegroundColor White
    Write-Host "✅ Successful: $successCount containers" -ForegroundColor Green
    Write-Host "❌ Failed: $failCount containers" -ForegroundColor $(if ($failCount -gt 0) { "Red" } else { "Gray" })
    Write-Host ""
    
    # Detailed results
    foreach ($result in $copyResults) {
        $icon = if ($result.Status -eq "Success") { "✅" } else { "❌" }
        $color = if ($result.Status -eq "Success") { "Green" } else { "Red" }
        Write-Host "  $icon $($result.Container) - $($result.Duration) min" -ForegroundColor $color
    }
    Write-Host ""
    
    if ($failCount -gt 0) {
        Write-Host "⚠️  Some containers failed to copy. Please review the errors above." -ForegroundColor Yellow
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
        Write-Host "  ❌ Closing firewall rules failed" -ForegroundColor Red
        Write-Host "  💡 Retrying in 30 seconds..." -ForegroundColor Yellow
        Start-Sleep -Seconds 30
        az storage account update `
            --resource-group $dest_rg `
            --name $dest_account `
            --subscription $dest_subscription `
            --default-action Deny -o none
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  ✅ Closing firewall rules for storage accounts... $dest_account" -ForegroundColor Cyan
        } else {
            Write-Host "  ❌ Closing firewall rules failed" -ForegroundColor Red
            $global:LASTEXITCODE = 1
            throw "Closing firewall rules failed"
        }
    }

    az storage account update `
        --resource-group $Source_rg `
        --name $Source_account `
        --subscription $Source_subscription `
        --default-action Deny -o none

    if ($LASTEXITCODE -eq 0) {
        Write-Host "Closing firewall rules for storage accounts... $Source_account" -ForegroundColor Cyan
    } else {
        Write-Host "Closing firewall rules failed" -ForegroundColor Red
        Write-Host "  💡 Retrying in 30 seconds..." -ForegroundColor Yellow
        Start-Sleep -Seconds 30
        az storage account update `
            --resource-group $Source_rg `
            --name $Source_account `
            --subscription $Source_subscription `
            --default-action Deny -o none
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  ✅ Closing firewall rules for storage accounts... $Source_account" -ForegroundColor Cyan
        } else {
            Write-Host "  ❌ Closing firewall rules failed" -ForegroundColor Red
            $global:LASTEXITCODE = 1
            throw "Closing firewall rules failed"
        }
    }
    
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Cyan
    if ($failCount -eq 0) {
        Write-Host "🎉 All containers copied successfully!" -ForegroundColor Green
    } else {
        Write-Host "⚠️  Copy completed with $failCount failure(s)" -ForegroundColor Yellow
        $global:LASTEXITCODE = 1
    }
    Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Cyan
}