param (
    [Parameter(Mandatory)][string]$source,
    [Parameter(Mandatory)][string]$destination,
    [Parameter(Mandatory)][string]$DestinationNamespace,
    [Parameter(Mandatory)][string]$SourceNamespace,
    [switch]$DryRun,
    [switch]$UseSasTokens  # Use SAS tokens for long-running operations (3TB+ containers)
)

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

function Get-StorageResourceUrl {
    param([string]$BlobEndpoint)
    
    # Determine Azure cloud type based on blob endpoint
    if ($BlobEndpoint -match "blob.core.windows.net") {
        return "https://storage.azure.com/"
    } elseif ($BlobEndpoint -match "blob.core.usgovcloudapi.net") {
        return "https://storage.azure.us/"
    } else {
        Write-Host "  ⚠️  Unknown cloud type, defaulting to Azure Commercial" -ForegroundColor Yellow
        return "https://storage.azure.com/"
    }
}

function Refresh-AzCopyAuth {
    param([string]$ResourceUrl)
    
    Write-Host "  🔑 Refreshing Azure authentication for storage..." -ForegroundColor Gray
    
    try {
        # Clear existing azcopy auth cache to force refresh
        azcopy logout 2>$null | Out-Null
        
        # Force az CLI to get fresh token for storage
        $token = az account get-access-token --resource "$ResourceUrl" --query accessToken -o tsv 2>$null
        
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($token)) {
            Write-Host "  ⚠️  Warning: Token refresh failed, azcopy will use existing authentication" -ForegroundColor Yellow
            return $false
        } else {
            Write-Host "  ✅ Authentication token refreshed successfully" -ForegroundColor Green
            return $true
        }
    } catch {
        Write-Host "  ⚠️  Warning: Authentication refresh encountered an error: $($_.Exception.Message)" -ForegroundColor Yellow
        return $false
    }
}

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

if ($DryRun) {
    Write-Host "`n🔍 DRY RUN MODE - Copy Attachments" -ForegroundColor Yellow
    Write-Host "===================================" -ForegroundColor Yellow
    Write-Host "No actual copy operations will be performed" -ForegroundColor Yellow
    if ($UseSasTokens) {
        Write-Host "Authentication: SAS Tokens (8-hour expiry)" -ForegroundColor Yellow
    } else {
        Write-Host "Authentication: Azure CLI with refresh" -ForegroundColor Yellow
    }
} else {
    Write-Host "`n=====================================" -ForegroundColor Cyan
    Write-Host "       Copy Attachments" -ForegroundColor Cyan
    Write-Host "=====================================" -ForegroundColor Cyan
    if ($UseSasTokens) {
        Write-Host "🔐 Mode: SAS Token Authentication" -ForegroundColor Magenta
        Write-Host "   (Recommended for 3TB+ containers)" -ForegroundColor Gray
    } else {
        Write-Host "🔐 Mode: Azure CLI Authentication" -ForegroundColor Magenta
        Write-Host "   (With automatic token refresh)" -ForegroundColor Gray
    }
    Write-Host ""
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

    # Determine storage resource URL for token refresh
    $storageResourceUrl = Get-StorageResourceUrl -BlobEndpoint $source_blob_endpoint
    Write-Host "Detected Azure Cloud: $storageResourceUrl" -ForegroundColor Gray
    Write-Host ""

    Write-Host "🚀 STARTING BLOB COPY PROCESS" -ForegroundColor Cyan
    Write-Host "==============================" -ForegroundColor Cyan
    Write-Host "Processing $($containers.Count) containers sequentially" -ForegroundColor White
    
    if ($UseSasTokens) {
        Write-Host "🔐 Generating SAS tokens (valid for 8 hours)..." -ForegroundColor Magenta
        Write-Host "   This ensures no token expiration during large copies" -ForegroundColor Gray
    }
    Write-Host ""
    
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
        
        if ($UseSasTokens) {
            # Generate SAS tokens for source and destination
            Write-Host "  🔑 Generating SAS tokens for container..." -ForegroundColor Gray
            
            $sourceSas = New-ContainerSasToken `
                -StorageAccount $source_account `
                -ResourceGroup $source_rg `
                -SubscriptionId $source_subscription `
                -ContainerName $containerName `
                -ExpiryHours 8
            
            $destSas = New-ContainerSasTokenWithWrite `
                -StorageAccount $dest_account `
                -ResourceGroup $dest_rg `
                -SubscriptionId $dest_subscription `
                -ContainerName $containerName `
                -ExpiryHours 8
            
            if ($sourceSas -and $destSas) {
                $sourceUrl = "${source_blob_endpoint}${containerName}?${sourceSas}"
                $destUrl = "${dest_blob_endpoint}${containerName}?${destSas}"
                Write-Host "  ✅ SAS tokens generated successfully (valid for 8 hours)" -ForegroundColor Green
            } else {
                Write-Host "  ❌ Failed to generate SAS tokens, falling back to Azure CLI auth" -ForegroundColor Red
                $UseSasTokens = $false  # Fallback for this container
            }
        }
        
        if (-not $UseSasTokens) {
            # Use Azure CLI authentication with token refresh
            Refresh-AzCopyAuth -ResourceUrl $storageResourceUrl | Out-Null
            $sourceUrl = "${source_blob_endpoint}${containerName}"
            $destUrl = "${dest_blob_endpoint}${containerName}"
        }

        Write-Host "  From: ${source_blob_endpoint}${containerName}" -ForegroundColor Gray
        Write-Host "  To:   ${dest_blob_endpoint}${containerName}" -ForegroundColor Gray
        Write-Host ""

        $copyStartTime = Get-Date
        
        # Start azcopy with progress info and error handling
        Write-Host "  🔄 Starting copy operation..." -ForegroundColor Yellow
        
        if ($UseSasTokens) {
            # When using SAS tokens, don't use AZCLI auto-login
            $env:AZCOPY_AUTO_LOGIN_TYPE = ""
            azcopy copy $sourceUrl $destUrl --recursive --log-level INFO
            $env:AZCOPY_AUTO_LOGIN_TYPE = "AZCLI"  # Restore for potential fallback
        } else {
            azcopy copy $sourceUrl $destUrl --recursive --log-level INFO
        }
        
        $copyElapsed = (Get-Date) - $copyStartTime
        $copyMinutes = [math]::Round($copyElapsed.TotalMinutes, 1)
        
        if ($LASTEXITCODE -eq 0) {
            Write-Host ""
            Write-Host "  ✅ Container '$containerName' copied successfully (took $copyMinutes min)" -ForegroundColor Green
            $successCount++
            $copyResults += @{
                Container = $containerName
                Status = "Success"
                Duration = $copyMinutes
            }
            
            # Warn about long copies when using Azure CLI auth
            if (-not $UseSasTokens -and $copyMinutes -gt 40) {
                Write-Host "  ⚠️  Long copy detected ($copyMinutes min) - authentication will be refreshed for next container" -ForegroundColor Yellow
                Write-Host "  💡 Consider using -UseSasTokens for containers that take >60 minutes" -ForegroundColor Gray
            }
            
            # Info for very long copies with SAS tokens
            if ($UseSasTokens -and $copyMinutes -gt 60) {
                Write-Host "  ℹ️  Long copy ($copyMinutes min) - SAS token still valid for up to 8 hours" -ForegroundColor Cyan
            }
        } else {
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