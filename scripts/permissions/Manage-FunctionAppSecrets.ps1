<#
.SYNOPSIS
    Manages Azure Function App secrets in Key Vault with Add/Remove/List operations

.DESCRIPTION
    This script manages 4 secrets in an Azure Key Vault for a Function App.
    - Add: Reads environment variables (e.g., semaphore_azure_client_id) and stores them as Key Vault secrets with hyphens (e.g., semaphore-azure-client-id)
    - Remove: Replaces Key Vault secret values with placeholders (1/2/3/4)
    - List: Displays the current values of the secrets in the Key Vault
    Provides detailed feedback on all operations.

.PARAMETER Action
    Action to perform: "Add" or "Remove"
    - Add: Reads from environment variables and updates Key Vault
    - Remove: Replaces values with placeholders

.PARAMETER FunctionAppName
    Name of the Azure Function App (default: from FUNCTION_APP_NAME env var)

.PARAMETER KeyVaultName
    Name of the Azure Key Vault (default: from KEY_VAULT_NAME env var)

.PARAMETER ResourceGroupName
    Name of the Azure Resource Group (default: from RESOURCE_GROUP_NAME env var)

.PARAMETER Cloud
    Azure cloud environment: AzureCloud or AzureUSGovernment (default: "AzureCloud")

.EXAMPLE
    .\Manage-FunctionAppSecrets.ps1 -Action "Add" -FunctionAppName "myFunctionApp" -KeyVaultName "myKeyVault" -ResourceGroupName "myResourceGroup"

.EXAMPLE
    .\Manage-FunctionAppSecrets.ps1 -Action "Remove" -FunctionAppName "myFunctionApp" -KeyVaultName "myKeyVault" -ResourceGroupName "myResourceGroup"

.NOTES
    Author: DevOps Team
    Required secrets in Key Vault: semaphore-azure-client-id, semaphore-azure-client-secret, semaphore-azure-tenant-id, semaphore-azure-function-app-secret
    Required environment variables: semaphore_azure_client_id, semaphore_azure_client_secret, semaphore_azure_tenant_id, semaphore_azure_function_app_secret
#>

param(
    [Parameter(Mandatory=$true)]
    [ValidateSet("Add", "Remove", "List")]
    [string]$Action,

    [Parameter(Mandatory=$false)]
    [string]$KeyVaultName,

    [Parameter(Mandatory=$false)]
    [string]$ResourceGroupName
)

# Define the environment variables and their corresponding Key Vault secret names
$script:envVarNames = @(
    'semaphore_azure_client_id',
    'semaphore_azure_client_secret',
    'semaphore_azure_tenant_id',
    'semaphore_azure_function_app_secret'
)
$script:secretNames = $script:envVarNames | ForEach-Object { $_ -replace '_', '-' }

# ═══════════════════════════════════════════════════════════════════════════
# HELPER FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════

function Write-StatusMessage {
    param(
        [string]$Message,
        [ValidateSet("Info", "Success", "Warning", "Error")]
        [string]$Level = "Info"
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $prefix = "[$timestamp]"
    
    switch ($Level) {
        "Info"    { Write-Host "$prefix [INFO]    $Message" -ForegroundColor Cyan }
        "Success" { Write-Host "$prefix [SUCCESS] $Message" -ForegroundColor Green }
        "Warning" { Write-Host "$prefix [WARNING] $Message" -ForegroundColor Yellow }
        "Error"   { Write-Host "$prefix [ERROR]   $Message" -ForegroundColor Red }
    }
}
function Get-KeyVaultSecrets {
    param(
        [string]$KeyVaultName
    )
    
    try {
        Write-StatusMessage "🔐 Retrieving secrets from Key Vault: $KeyVaultName" "Info"
        
        $secrets = @{}
        
        foreach ($secretName in $script:secretNames) {
            try {
                $secret = Get-AzKeyVaultSecret -VaultName $KeyVaultName -Name $secretName -ErrorAction Stop
                $secrets[$secretName] = $secret.SecretValue | ConvertFrom-SecureString -AsPlainText
                Write-StatusMessage "   ✓ Retrieved secret: $secretName" "Info"
            } catch {
                Write-StatusMessage "   ⚠️  Secret not found or inaccessible: $secretName" "Warning"
                $secrets[$secretName] = $null
            }
        }
        
        Write-StatusMessage "✅ Retrieved secrets from Key Vault" "Success"
        return $secrets
        
    } catch {
        Write-StatusMessage "❌ Failed to retrieve secrets: $($_.Exception.Message)" "Error"
        throw
    }
}

function Set-KeyVaultSecrets {
    param(
        [string]$KeyVaultName,
        [hashtable]$Secrets
    )
    
    try {
        Write-StatusMessage "📝 Updating secrets in Key Vault: $KeyVaultName" "Info"
        
        $successCount = 0
        $failureCount = 0
        
        foreach ($secretName in $script:secretNames) {
            try {
                $secretValue = $Secrets[$secretName]
                if ([string]::IsNullOrWhiteSpace($secretValue)) {
                    Write-StatusMessage "   ⚠️  Skipping empty value for: $secretName" "Warning"
                    continue
                }
                
                $secureValue = ConvertTo-SecureString -String $secretValue -AsPlainText -Force
                Set-AzKeyVaultSecret -VaultName $KeyVaultName -Name $secretName -SecretValue $secureValue -ErrorAction Stop | Out-Null
                Write-StatusMessage "   ✓ Updated secret: $secretName" "Success"
                $successCount++
            } catch {
                Write-StatusMessage "   ❌ Failed to update secret: $secretName - $($_.Exception.Message)" "Error"
                $failureCount++
            }
        }
        
        if ($failureCount -eq 0) {
            Write-StatusMessage "✅ All secrets updated successfully ($successCount/4)" "Success"
            return @{ Success = $true; Updated = $successCount; Failed = $failureCount }
        } else {
            Write-StatusMessage "⚠️  Partial update completed: $successCount updated, $failureCount failed" "Warning"
            return @{ Success = $false; Updated = $successCount; Failed = $failureCount }
        }
        
    } catch {
        Write-StatusMessage "❌ Failed to update secrets: $($_.Exception.Message)" "Error"
        throw
    }
}

# ═══════════════════════════════════════════════════════════════════════════
# PARAMETER VALIDATION
# ═══════════════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host " Azure Function App Secrets Management" -ForegroundColor Cyan
Write-Host "════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

Write-StatusMessage "🔧 Validating parameters..." "Info"

if (-not $KeyVaultName) { $KeyVaultName = $env:KEY_VAULT_NAME }
if (-not $ResourceGroupName) { $ResourceGroupName = $env:RESOURCE_GROUP_NAME }

# Validate Key Vault Name
if ([string]::IsNullOrWhiteSpace($KeyVaultName)) {
    Write-StatusMessage "❌ FATAL ERROR: KeyVaultName is required" "Error"
    Write-Host "   Please provide -KeyVaultName parameter or set KEY_VAULT_NAME environment variable" -ForegroundColor Red
    exit 1
}

# Validate Resource Group Name
if ([string]::IsNullOrWhiteSpace($ResourceGroupName)) {
    Write-StatusMessage "❌ FATAL ERROR: ResourceGroupName is required" "Error"
    Write-Host "   Please provide -ResourceGroupName parameter or set RESOURCE_GROUP_NAME environment variable" -ForegroundColor Red
    exit 1
}

Write-StatusMessage "✅ All required parameters validated" "Success"

Write-Host ""
Write-StatusMessage "📋 Configuration:" "Info"
Write-Host "   • Action              : $Action" -ForegroundColor Gray
Write-Host "   • Key Vault           : $KeyVaultName" -ForegroundColor Gray
Write-Host "   • Resource Group      : $ResourceGroupName" -ForegroundColor Gray
Write-Host ""

# ═══════════════════════════════════════════════════════════════════════════
# MAIN OPERATION
# ═══════════════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan

$operationResult = @{
    Action = $Action
    KeyVaultName = $KeyVaultName
    ResourceGroupName = $ResourceGroupName
    Timestamp = Get-Date
    Success = $false
    Secrets = @{}
    Message = ""
}

try {
    
    if ($Action -eq "Add") {
        Write-StatusMessage "➕ OPERATION: ADD - Reading from environment variables and updating Key Vault" "Info"
        Write-Host ""
        
        # Step 1: Read environment variables
        Write-StatusMessage "🔎 Reading environment variables: $($script:envVarNames -join ', ')" "Info"
        $envVariables = @{}
        foreach ($envVar in $script:envVarNames) {
            $envVariables[$envVar] = [System.Environment]::GetEnvironmentVariable($envVar)
        }

        # Validate that environment variables are not empty
        $missingEnvs = @()
        foreach ($key in $envVariables.Keys) {
            if ([string]::IsNullOrWhiteSpace($envVariables[$key])) {
                $missingEnvs += $key
            }
        }

        if ($missingEnvs.Count -gt 0) {
            $missingEnvsStr = $missingEnvs -join ", "
            Write-StatusMessage "❌ FATAL ERROR: Required environment variables are not set: $missingEnvsStr" "Error"
            throw "Required environment variables not set: $missingEnvsStr"
        }

        Write-StatusMessage "✅ All required environment variables are present." "Success"
        
        Write-Host ""
        Write-StatusMessage "📊 Environment Variables Read:" "Info"
        foreach ($key in $envVariables.Keys) {
            $value = $envVariables[$key]
            $displayValue = if ($value.Length -gt 20) { "$($value.Substring(0, 20))..." } else { $value }
            Write-Host "   • $key : $displayValue ($($value.Length) chars)" -ForegroundColor Gray
        }
        
        # Step 2: Update Key Vault with environment variables
        Write-Host ""
        $secretsToUpdate = @{}
        for ($i = 0; $i -lt $script:envVarNames.Count; $i++) {
            $envVarName = $script:envVarNames[$i]
            $secretName = $script:secretNames[$i]
            $secretsToUpdate[$secretName] = $envVariables[$envVarName]
        }
        
        $updateResult = Set-KeyVaultSecrets -KeyVaultName $KeyVaultName -Secrets $secretsToUpdate
        
        $operationResult.Success = $updateResult.Success
        $operationResult.Secrets = $secretsToUpdate
        $operationResult.Message = "Successfully added $($updateResult.Updated) secrets to Key Vault"
        
    } elseif ($Action -eq "List") {
        Write-StatusMessage "📄 OPERATION: LIST - Retrieving secrets from Key Vault" "Info"
        Write-Host ""
        
        $currentSecrets = Get-KeyVaultSecrets -KeyVaultName $KeyVaultName
        
        $operationResult.Success = $true
        $operationResult.Secrets = $currentSecrets
        $operationResult.Message = "Successfully listed secrets from Key Vault"

    } elseif ($Action -eq "Remove") {
        Write-StatusMessage "➖ OPERATION: REMOVE - Resetting secrets to placeholders" "Info"
        Write-Host ""
        
        # Step 1: List current secrets
        $currentSecrets = Get-KeyVaultSecrets -KeyVaultName $KeyVaultName
        
        # Step 2: Create placeholder values
        Write-Host ""
        $placeholders = @{}
        for ($i = 0; $i -lt $script:secretNames.Count; $i++) {
            $placeholders[$script:secretNames[$i]] = ($i + 1).ToString()
        }
        
        Write-StatusMessage "📊 Replacing with Placeholders:" "Info"
        foreach ($key in $script:secretNames) {
            Write-Host "   • $key : $($placeholders[$key])" -ForegroundColor Gray
        }
        
        # Step 3: Update Key Vault with placeholders
        Write-Host ""
        $updateResult = Set-KeyVaultSecrets -KeyVaultName $KeyVaultName -Secrets $placeholders
        
        $operationResult.Success = $updateResult.Success
        $operationResult.Secrets = $placeholders
        $operationResult.Message = "Successfully removed $($updateResult.Updated) secrets (replaced with placeholders)"
    }
    
    # List final secrets
    Write-Host ""
    Write-StatusMessage "🔐 Final Secrets in Key Vault:" "Info"
    $finalSecrets = if ($Action -eq "List") { $operationResult.Secrets } else { Get-KeyVaultSecrets -KeyVaultName $KeyVaultName }
    foreach ($key in $script:secretNames) {
        $value = $finalSecrets[$key]
        $displayValue = if ($null -ne $value -and $value.Length -gt 20) { "$($value.Substring(0, 20))..." } else { $value }
        Write-Host "   • $key : $displayValue" -ForegroundColor Gray
    }
    
    # Success summary
    Write-Host ""
    Write-Host "════════════════════════════════════════════════════════════════════" -ForegroundColor Green
    Write-Host " ✅ OPERATION COMPLETED SUCCESSFULLY" -ForegroundColor Green
    Write-Host "════════════════════════════════════════════════════════════════════" -ForegroundColor Green
    Write-Host ""
    
    Write-StatusMessage "📋 Operation Summary:" "Success"
    Write-Host "   • Action    : $($operationResult.Action)" -ForegroundColor Green
    Write-Host "   • Status    : SUCCESS" -ForegroundColor Green
    Write-Host "   • Message   : $($operationResult.Message)" -ForegroundColor Green
    Write-Host "   • Timestamp : $($operationResult.Timestamp)" -ForegroundColor Green
    Write-Host ""
    
    # Return structured result
    return $operationResult

} catch {
    $errorMessage = $_.Exception.Message
    
    Write-Host ""
    Write-Host "════════════════════════════════════════════════════════════════════" -ForegroundColor Red
    Write-Host " ❌ OPERATION FAILED" -ForegroundColor Red
    Write-Host "════════════════════════════════════════════════════════════════════" -ForegroundColor Red
    Write-Host ""
    
    Write-StatusMessage "❌ Error Details:" "Error"
    Write-Host "   • Action    : $($operationResult.Action)" -ForegroundColor Red
    Write-Host "   • Status    : FAILED" -ForegroundColor Red
    Write-Host "   • Message   : $errorMessage" -ForegroundColor Red
    Write-Host "   • Timestamp : $($operationResult.Timestamp)" -ForegroundColor Red
    Write-Host ""
    
    $operationResult.Success = $false
    $operationResult.Message = $errorMessage
    
    # Return error result
    Write-Error $errorMessage
    return $operationResult
}
