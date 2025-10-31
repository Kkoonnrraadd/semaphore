<#
.SYNOPSIS
    Calls Azure Function App to manage permissions for Self-Service operations

.DESCRIPTION
    This script invokes an Azure Function to grant or remove permissions for service accounts.
    It provides detailed feedback on the operation status and waits for the Function to complete.

.PARAMETER Action
    Action to perform: "Grant" or "Remove"

.PARAMETER ServiceAccount
    Service account name (default: "SelfServiceRefresh")

.PARAMETER Environment
    Environment name (e.g., "gov001", "qa2")

.PARAMETER TimeoutSeconds
    HTTP request timeout in seconds (default: 60)

.PARAMETER WaitForPropagation
    Wait time in seconds for permissions to propagate in Azure AD (default: 30)

.EXAMPLE
    .\Invoke-AzureFunctionPermission.ps1 -Action "Grant" -Environment "gov001"

.EXAMPLE
    .\Invoke-AzureFunctionPermission.ps1 -Action "Remove" -Environment "gov001" -WaitForPropagation 45

.NOTES
    Author: DevOps Team
    This script is designed for automation and provides structured output
#>

param(
    [Parameter(Mandatory=$true)]
    [ValidateSet("Grant", "Remove")]
    [string]$Action,
    
    [Parameter(Mandatory=$true)]
    [string]$Environment,
    
    # [string]$ServiceAccount = "SelfServiceRefresh",
    # [string]$ServiceAccount = "semaphore-semaphore-mnfrotest-prod-gov001-virg",
    
    [int]$TimeoutSeconds = 360,
    
    [int]$WaitForPropagation = 60
    # [switch]$NoWait
)

$ServiceAccount = $env:SEMAPHORE_WORKLOAD_IDENTITY_NAME
# Azure Function Configuration
# $functionBaseUrl = "https://triggerimportondemand.azurewebsites.us/api/SelfServiceTest"
$functionBaseUrl = $env:SEMAPHORE_FUNCTION_URL
# $functionBaseUrl = "https://triggerimportondemand.azurewebsites.net/api/SelfServiceTest"
$functionCode = $env:AZURE_FUNCTION_APP_SECRET

# Validate that the Azure Function secret is configured
if ([string]::IsNullOrWhiteSpace($functionCode)) {
    Write-Host "" -ForegroundColor Red
    Write-Host "============================================" -ForegroundColor Red
    Write-Host " ❌ CONFIGURATION ERROR" -ForegroundColor Red
    Write-Host "============================================" -ForegroundColor Red
    Write-Host "" -ForegroundColor Red
    Write-Host "❌ AZURE_FUNCTION_APP_SECRET environment variable is not set!" -ForegroundColor Red
    Write-Host "" -ForegroundColor Yellow
    Write-Host "This environment variable is required to authenticate with the Azure Function." -ForegroundColor Yellow
    Write-Host "" -ForegroundColor Gray
    Write-Host "To fix this, ensure AZURE_FUNCTION_APP_SECRET is set in your environment:" -ForegroundColor Gray
    Write-Host "  • In docker-compose.yaml: Add to environment section" -ForegroundColor Gray
    Write-Host "  • In Kubernetes: Add to pod env vars" -ForegroundColor Gray
    Write-Host "  • In Semaphore: Add to pod environment variables" -ForegroundColor Gray
    Write-Host "" -ForegroundColor Gray
    Write-Host "Example (docker-compose.yaml):" -ForegroundColor Gray
    Write-Host "  environment:" -ForegroundColor Gray
    Write-Host "    AZURE_FUNCTION_APP_SECRET: your-secret-here" -ForegroundColor Gray
    Write-Host "" -ForegroundColor Red
    
    # Return structured error for automation
    return @{
        Success = $false
        Action = $Action
        Environment = $Environment
        ServiceAccount = $ServiceAccount
        Response = $null
        Duration = 0
        Error = "AZURE_FUNCTION_APP_SECRET environment variable is not set"
        StatusCode = $null
    }
}

$functionUrl = "${functionBaseUrl}?code=${functionCode}"

# Color-coded output for better visibility
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

# Main execution
Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host " Azure Function Permission Management" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

Write-StatusMessage "🚀 Starting permission management operation..." "Info"
Write-StatusMessage "📋 Configuration:" "Info"
Write-Host "   • Action          : $Action" -ForegroundColor Gray
Write-Host "   • Service Account : $ServiceAccount" -ForegroundColor Gray
Write-Host "   • Environment     : $Environment" -ForegroundColor Gray
Write-Host "   • Timeout         : $TimeoutSeconds seconds" -ForegroundColor Gray
Write-Host "   • Propagation Wait: $WaitForPropagation seconds" -ForegroundColor Gray
Write-Host ""

try {
    # Prepare request body
    $requestBody = @{
        Action = $Action
        ServiceAccount = $ServiceAccount
        Environment = $Environment
    }
    
    $requestBodyJson = $requestBody | ConvertTo-Json -Depth 3 -Compress
    
    Write-StatusMessage "📤 Sending HTTP POST request to Azure Function..." "Info"
    Write-Host "   Request Body: $requestBodyJson" -ForegroundColor Gray
    Write-Host ""
    
    # Prepare HTTP headers
    $headers = @{
        "Content-Type" = "application/json"
    }
    
    # Call Azure Function
    $startTime = Get-Date
    Write-StatusMessage "⏱️  Waiting for Azure Function response..." "Info"
    
    $response = Invoke-RestMethod `
        -Uri $functionUrl `
        -Method Post `
        -Body $requestBodyJson `
        -Headers $headers `
        -TimeoutSec $TimeoutSeconds `
        -ErrorAction Stop
    
    $duration = ((Get-Date) - $startTime).TotalSeconds
    
    Write-Host ""
    Write-StatusMessage "✅ Azure Function responded successfully!" "Success"
    Write-Host "   • Response Time: $([math]::Round($duration, 2)) seconds" -ForegroundColor Gray
    Write-Host ""
    
    # Display response details
    Write-StatusMessage "📥 Function Response:" "Info"
    if ($response -is [string]) {
        Write-Host "   $response" -ForegroundColor Gray
    } else {
        $response | ConvertTo-Json -Depth 10 | Write-Host -ForegroundColor Gray
    }
    Write-Host ""

    $permissionsAdded = 0
    $needsWait = $false

    if ($response -match "(\d+) succeeded") {
        $permissionsAdded = [int]$matches[1]
        
        Write-Host "   📊 Parsed result: $permissionsAdded permission(s) successfully added" -ForegroundColor Gray
        
        if ($permissionsAdded -gt 0) {
            Write-Host "   ✅ Permissions granted: $permissionsAdded group(s) added" -ForegroundColor Green
            Write-Host "   ⏳ Propagation wait REQUIRED (changes were made to Azure AD)" -ForegroundColor Yellow
            $needsWait = $true
        } else {
            Write-Host "   ✅ Permissions already configured (no changes needed)" -ForegroundColor Green
            Write-Host "   ⚡ Propagation wait SKIPPED - service principal already has access" -ForegroundColor Cyan
            $needsWait = $false
        }
    }else{
        Write-Host "   ⚠️  Could not parse response (pattern '(\d+) succeeded' not found)" -ForegroundColor Yellow
        Write-Host "   ✅ Permissions granted successfully" -ForegroundColor Green
        Write-Host "   ⏳ Propagation wait RECOMMENDED (unable to determine if changes were made)" -ForegroundColor Yellow
        $needsWait = $true
    }

    # NOW perform propagation wait if needed (after successful authentication)
    if ($needsWait) {
        $waitSeconds = $WaitForPropagation
        Write-Host ""
        Write-Host "   ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Yellow
        Write-Host "   ⏳ AZURE AD PERMISSION PROPAGATION WAIT" -ForegroundColor Yellow
        Write-Host "   ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "   📌 Why are we waiting?" -ForegroundColor Cyan
        Write-Host "      • Permissions were just added to Azure AD groups" -ForegroundColor Gray
        Write-Host "      • Azure AD needs time to propagate changes globally" -ForegroundColor Gray
        Write-Host "      • This ensures your authenticated session can use new permissions" -ForegroundColor Gray
        Write-Host ""
        Write-Host "   ⏳ Waiting $waitSeconds seconds for propagation..." -ForegroundColor Yellow
        
        # Progress bar for better UX
        for ($i = 1; $i -le $waitSeconds; $i++) {
            $percent = [math]::Round(($i / $waitSeconds) * 100)
            Write-Progress -Activity "Azure AD Permission Propagation" -Status "$i / $waitSeconds seconds" -PercentComplete $percent
            Start-Sleep -Seconds 1
        }
        Write-Progress -Activity "Azure AD Permission Propagation" -Completed
        
        Write-Host "   ✅ Permission propagation wait completed" -ForegroundColor Green
        Write-Host ""
    }

    Write-Host "============================================" -ForegroundColor Green
    Write-Host " ✅ OPERATION COMPLETED SUCCESSFULLY" -ForegroundColor Green
    Write-Host "============================================" -ForegroundColor Green
    Write-Host ""
    
    # Return structured result for automation
    return @{
        Success = $true
        Action = $Action
        Environment = $Environment
        ServiceAccount = $ServiceAccount
        Response = $response
        Duration = $duration
        Error = $null
    }
    
} catch {
    $errorMessage = $_.Exception.Message
    
    Write-Host ""
    Write-StatusMessage "❌ Azure Function call failed!" "Error"
    Write-Host ""
    Write-StatusMessage "Error Details:" "Error"
    Write-Host "   Message: $errorMessage" -ForegroundColor Red
    Write-Host ""
    
    # Try to get HTTP status code if available
    $statusCode = $null
    if ($_.Exception.Response) {
        try {
            $statusCode = [int]$_.Exception.Response.StatusCode
            $statusDescription = $_.Exception.Response.StatusDescription
            Write-Host "   HTTP Status: $statusCode - $statusDescription" -ForegroundColor Red
            
            # Provide specific guidance for common errors
            if ($statusCode -eq 401) {
                Write-Host "" -ForegroundColor Yellow
                Write-Host "   ⚠️  401 Unauthorized - This usually means:" -ForegroundColor Yellow
                Write-Host "      1. AZURE_FUNCTION_APP_SECRET is missing or incorrect" -ForegroundColor Yellow
                Write-Host "      2. The Azure Function key has expired or changed" -ForegroundColor Yellow
                Write-Host "" -ForegroundColor Gray
                Write-Host "   🔧 To fix:" -ForegroundColor Gray
                Write-Host "      • Check that AZURE_FUNCTION_APP_SECRET is set in your pod" -ForegroundColor Gray
                Write-Host "      • Verify the secret value matches the Azure Function's key" -ForegroundColor Gray
                Write-Host "      • Check: kubectl get pods -n semaphore" -ForegroundColor Gray
                Write-Host "      • Verify: kubectl exec -n semaphore <pod> -- env | grep AZURE_FUNCTION" -ForegroundColor Gray
            }
        } catch {
            Write-Host "   HTTP Status: Unable to retrieve" -ForegroundColor Red
        }
    }
    
    # Additional error details
    if ($_.ErrorDetails.Message) {
        Write-Host "   Response: $($_.ErrorDetails.Message)" -ForegroundColor Red
    }
    
    Write-Host ""
    Write-Host "============================================" -ForegroundColor Red
    Write-Host " ❌ OPERATION FAILED" -ForegroundColor Red
    Write-Host "============================================" -ForegroundColor Red
    Write-Host ""
    
    # Return structured error result
    $errorResult = @{
        Success = $false
        Action = $Action
        Environment = $Environment
        ServiceAccount = $ServiceAccount
        Response = $null
        Duration = 0
        Error = $errorMessage
        StatusCode = if ($_.Exception.Response.StatusCode) { [int]$_.Exception.Response.StatusCode } else { $null }
    }
    
    # For automation: exit with error code
    Write-Error "Azure Function call failed: $errorMessage"
    return $errorResult
}

