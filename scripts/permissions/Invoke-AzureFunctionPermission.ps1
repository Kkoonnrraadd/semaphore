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
    
    [string]$ServiceAccount = "SelfServiceRefresh",
    
    [int]$TimeoutSeconds = 60,
    
    [int]$WaitForPropagation = 30,
    
    [switch]$NoWait
)

# Azure Function Configuration
$functionBaseUrl = "https://triggerimportondemand.azurewebsites.us/api/SelfServiceTest"
$functionCode = $env:AZURE_FUNCTION_APP_SECRET
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
    
    # Wait for permission propagation
    if (-not $NoWait -and $WaitForPropagation -gt 0) {
        Write-StatusMessage "⏳ Waiting $WaitForPropagation seconds for permissions to propagate in Azure AD..." "Info"
        
        # Progress bar for better UX
        for ($i = 0; $i -lt $WaitForPropagation; $i++) {
            $percent = [math]::Round(($i / $WaitForPropagation) * 100)
            Write-Progress -Activity "Permission Propagation Wait" -Status "$i / $WaitForPropagation seconds" -PercentComplete $percent
            Start-Sleep -Seconds 1
        }
        Write-Progress -Activity "Permission Propagation Wait" -Completed
        
        Write-StatusMessage "✅ Permission propagation wait completed" "Success"
        Write-Host ""
    } elseif ($NoWait) {
        Write-StatusMessage "⏭️  Skipped permission propagation wait (-NoWait specified)" "Info"
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
    if ($_.Exception.Response) {
        try {
            $statusCode = [int]$_.Exception.Response.StatusCode
            $statusDescription = $_.Exception.Response.StatusDescription
            Write-Host "   HTTP Status: $statusCode - $statusDescription" -ForegroundColor Red
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

