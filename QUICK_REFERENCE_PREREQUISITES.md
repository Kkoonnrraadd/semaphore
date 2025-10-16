# Quick Reference: Using Prerequisite Modules

## For Script Developers

### Using in Your Own Scripts

If you're creating a new script that needs Azure authentication and parameter detection, use the prerequisite module:

```powershell
# At the top of your script
$global:ScriptBaseDir = Split-Path -Parent $PSScriptRoot

# Call prerequisites
$prerequisiteScript = Join-Path $global:ScriptBaseDir "common/Invoke-PrerequisiteSteps.ps1"
$result = & $prerequisiteScript `
    -TargetEnvironment "gov001" `
    -Parameters @{Source="gov001"; Destination="dev"}

# Check result
if (-not $result.Success) {
    throw "Prerequisites failed: $($result.Error)"
}

# Use detected parameters
$detectedParams = $result.DetectedParameters
$source = $detectedParams.Source
$cloud = $detectedParams.Cloud
```

## Module Interfaces

### Grant-AzurePermissions.ps1

```powershell
$result = & Grant-AzurePermissions.ps1 -Environment "gov001"

# Returns:
# {
#     Success: Boolean                   # True if successful
#     NeedsPropagationWait: Boolean      # True if should wait for propagation
#     PermissionsAdded: Integer          # Count of permissions added
#     PropagationWaitSeconds: Integer    # Recommended wait time (30)
#     Error: String                      # Error message if failed
#     Duration: Double                   # Operation time in seconds
# }
```

### Invoke-PrerequisiteSteps.ps1

```powershell
$result = & Invoke-PrerequisiteSteps.ps1 `
    -TargetEnvironment "gov001" `
    -Cloud "AzureUSGovernment" `
    -Parameters @{Source="..."; Destination="..."}

# Returns:
# {
#     Success: Boolean                   # True if all steps succeeded
#     DetectedParameters: Hashtable      # Auto-detected parameters
#     PermissionResult: Hashtable        # Result from permission grant
#     AuthenticationResult: Boolean      # True if authenticated
#     NeedsPropagationWait: Boolean      # Internal flag (already handled)
#     PropagationWaitSeconds: Integer    # Internal (already handled)
#     Error: String                      # Error message if failed
# }
```

### Optional Parameters

```powershell
# Skip specific steps if needed
$result = & Invoke-PrerequisiteSteps.ps1 `
    -Parameters @{...} `
    -SkipPermissions        # Skip STEP 0A
    -SkipAuthentication     # Skip STEP 0B
    -SkipParameterDetection # Skip STEP 0C
```

## Common Patterns

### Pattern 1: Use Environment Variable

```powershell
# Set ENVIRONMENT variable
$env:ENVIRONMENT = "gov001"

# Prerequisites will use it automatically
$result = & Invoke-PrerequisiteSteps.ps1 -Parameters @{}
```

### Pattern 2: Explicit Target Environment

```powershell
# Explicitly specify environment
$result = & Invoke-PrerequisiteSteps.ps1 `
    -TargetEnvironment "gov001"
```

### Pattern 3: Merge User and Detected Parameters

```powershell
# User provides some params
$userParams = @{
    Source = "gov001"
    DryRun = $true
}

# Call prerequisites
$result = & Invoke-PrerequisiteSteps.ps1 -Parameters $userParams

# Merge detected params (user params take priority)
foreach ($key in $result.DetectedParameters.Keys) {
    if (-not $userParams.ContainsKey($key)) {
        $userParams[$key] = $result.DetectedParameters[$key]
    }
}

# Now $userParams has both user-provided and auto-detected values
```

## Smart Propagation Wait

The module automatically handles propagation wait intelligently:

```
First Run (permissions added):
  1. Grant permissions ✅
  2. Authenticate ✅
  3. Wait 30 seconds ⏳ (changes were made)
  4. Continue ✅

Subsequent Runs (permissions exist):
  1. Grant permissions ✅ (0 changes)
  2. Authenticate ✅
  3. Skip wait ⚡ (no changes needed)
  4. Continue ✅ (30 seconds faster!)
```

You don't need to do anything - it's automatic!

## Error Handling

### Check for Success

```powershell
$result = & Invoke-PrerequisiteSteps.ps1 -Parameters @{...}

if (-not $result.Success) {
    Write-Error "Prerequisites failed: $($result.Error)"
    exit 1
}

# Continue with your logic
```

### Detailed Error Info

```powershell
if (-not $result.Success) {
    Write-Host "Error: $($result.Error)" -ForegroundColor Red
    
    # Check which step failed
    if ($result.PermissionResult -and -not $result.PermissionResult.Success) {
        Write-Host "Permission grant failed" -ForegroundColor Red
    }
    if (-not $result.AuthenticationResult) {
        Write-Host "Authentication failed" -ForegroundColor Red
    }
}
```

## Environment Variables Used

The prerequisite modules respect these environment variables:

```bash
# Azure Authentication
export AZURE_CLIENT_ID="..."           # Service Principal client ID
export AZURE_CLIENT_SECRET="..."       # Service Principal secret
export AZURE_TENANT_ID="..."           # Azure tenant ID

# Azure Function (for permissions)
export AZURE_FUNCTION_APP_SECRET="..." # Function app authorization key

# Environment Detection
export ENVIRONMENT="gov001"            # Target environment name
export INSTANCE_ALIAS="mil-space-dev"  # Customer alias
```

## Troubleshooting

### Issue: Permission grant fails

**Check**:
1. Is `AZURE_FUNCTION_APP_SECRET` set?
2. Is the environment name correct?
3. Does the service account exist in the function?

```bash
echo $AZURE_FUNCTION_APP_SECRET  # Should not be empty
```

### Issue: Authentication fails

**Check**:
1. Are Azure credentials set?
2. Is the service principal valid?
3. Does it have access to the subscription?

```bash
az login --service-principal \
  --username $AZURE_CLIENT_ID \
  --password $AZURE_CLIENT_SECRET \
  --tenant $AZURE_TENANT_ID
```

### Issue: Parameter detection returns empty

**Check**:
1. Are you authenticated first?
2. Does the environment exist in Azure?
3. Are resources tagged correctly?

```bash
# Verify resources exist
az resource list --tag Environment=gov001
```

## Performance Tips

### Tip 1: Reuse Authentication
If running multiple operations, authenticate once:

```powershell
# First operation
$result1 = & Invoke-PrerequisiteSteps.ps1 -Parameters @{...}

# Subsequent operations can skip auth
$result2 = & Invoke-PrerequisiteSteps.ps1 `
    -Parameters @{...} `
    -SkipAuthentication
```

### Tip 2: Cache Detected Parameters
Save detected parameters for reuse:

```powershell
# First call
$result = & Invoke-PrerequisiteSteps.ps1 -Parameters @{...}
$global:CachedParams = $result.DetectedParameters

# Later calls can use cached values
$params = $global:CachedParams
```

### Tip 3: Skip Unnecessary Steps
If you don't need permissions:

```powershell
$result = & Invoke-PrerequisiteSteps.ps1 `
    -Parameters @{...} `
    -SkipPermissions  # Saves ~2-5 seconds
```

## Testing Your Integration

### Test Prerequisites Standalone

```powershell
# Test with your parameters
$result = & scripts/common/Invoke-PrerequisiteSteps.ps1 `
    -TargetEnvironment "test" `
    -Parameters @{Source="test"}

# Verify result
Write-Host "Success: $($result.Success)"
Write-Host "Detected: $($result.DetectedParameters | ConvertTo-Json)"
```

### Test in Dry-Run Mode

```powershell
# Your script with dry-run
./your-script.ps1 -Source "test" -DryRun
```

## Examples from Existing Scripts

### Example 1: self_service.ps1

```powershell
# Determine target environment
$targetEnvironment = if ($script:OriginalSource) {
    $script:OriginalSource
} else {
    $env:ENVIRONMENT
}

# Build parameters
$prereqParams = @{
    Source = $script:OriginalSource
    Destination = $script:OriginalDestination
    SourceNamespace = $script:OriginalSourceNamespace
    DestinationNamespace = $script:OriginalDestinationNamespace
}

# Call prerequisites
$prerequisiteResult = & $prerequisiteScript `
    -TargetEnvironment $targetEnvironment `
    -Cloud $script:OriginalCloud `
    -Parameters $prereqParams

# Check success
if (-not $prerequisiteResult.Success) {
    throw "Prerequisite steps failed: $($prerequisiteResult.Error)"
}

# Use detected parameters
$detectedParams = $prerequisiteResult.DetectedParameters
```

### Example 2: invoke_step.ps1

```powershell
# Call prerequisites with parsed parameters
$prerequisiteResult = & $prerequisiteScript -Parameters $scriptParams

# Check success
if (-not $prerequisiteResult.Success) {
    Write-Host "❌ FATAL ERROR: Prerequisite steps failed"
    exit 1
}

# Merge detected parameters into script params
$detectedParams = $prerequisiteResult.DetectedParameters
foreach ($paramName in $detectedParams.Keys) {
    if (-not $scriptParams.ContainsKey($paramName)) {
        $scriptParams[$paramName] = $detectedParams[$paramName]
    }
}
```

## Summary

✅ **Always call** `Invoke-PrerequisiteSteps.ps1` for Azure operations  
✅ **Check result** `.Success` before continuing  
✅ **Use detected parameters** from `.DetectedParameters`  
✅ **Skip steps** if not needed (performance)  
✅ **Let it handle** propagation wait automatically  

---

**Need Help?** Check the full documentation in `REFACTORING_PREREQUISITE_STEPS.md`

