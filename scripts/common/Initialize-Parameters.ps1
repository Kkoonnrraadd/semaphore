<#
.SYNOPSIS
    Initializes and sanitizes all parameters for Semaphore execution

.DESCRIPTION
    This script handles parameter sanitization for all common parameters
    that might be passed from Semaphore in the format: $ParamName= 'ParamName=value'

.PARAMETER Parameters
    Hashtable of parameters to sanitize

.EXAMPLE
    $params = @{
        RestoreDateTime = "RestoreDateTime=2025-09-23 00:00:00"
        Source = "Source=prod"
        Timezone = "UTC"
    }
    $cleanParams = Initialize-Parameters -Parameters $params
#>

param(
    [hashtable]$Parameters = @{}
)

function Get-SanitizedParameter {
    param(
        [string]$Value,
        [string]$Name
    )
    
    # If the value is null or empty, return as is
    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $Value
    }
    
    # Check if the value starts with the parameter name followed by equals
    $prefixPattern = "^$Name\s*=\s*['`"]?(.*?)['`"]?\s*$"
    
    if ($Value -match $prefixPattern) {
        # Extract the value after the equals sign
        $cleanValue = $matches[1]
        Write-Host "🔧 Sanitized parameter '$Name': '$Value' → '$cleanValue'" -ForegroundColor Gray
        return $cleanValue
    }
    
    # If no prefix found, return the original value
    return $Value
}

function Initialize-Parameters {
    param([hashtable]$InputParameters)
    
    Write-Host "🔧 Initializing and sanitizing parameters..." -ForegroundColor Cyan
    
    $sanitizedParams = @{}
    
    # List of parameters that might need sanitization
    $parameterNames = @(
        "RestoreDateTime",
        "Source", 
        "Destination",
        "SourceNamespace",
        "DestinationNamespace",
        "CustomerAlias",
        "CustomerAliasToRemove",
        "Timezone",
        "Cloud",
        "MaxWaitMinutes",
        "DryRun",
        "AutoApprove"
    )
    
    # Process each parameter
    foreach ($paramName in $parameterNames) {
        if ($InputParameters.ContainsKey($paramName)) {
            $originalValue = $InputParameters[$paramName]
            $sanitizedValue = Get-SanitizedParameter -Value $originalValue -Name $paramName
            $sanitizedParams[$paramName] = $sanitizedValue
        }
    }
    
    # Add any other parameters that weren't in our list
    foreach ($key in $InputParameters.Keys) {
        if (-not $sanitizedParams.ContainsKey($key)) {
            $sanitizedParams[$key] = $InputParameters[$key]
        }
    }
    
    Write-Host "✅ Parameter sanitization completed" -ForegroundColor Green
    return $sanitizedParams
}

# Main execution
return Initialize-Parameters -InputParameters $Parameters
