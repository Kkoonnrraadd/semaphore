# Bug Fix: UseSasTokens Parameter Not Being Passed

## Problem Summary

When running the full production workflow via `semaphore_wrapper.ps1`, the `UseSasTokens=true` parameter was being parsed but **not passed through** to `self_service.ps1`, causing it to default to `false`. This resulted in:

- ❌ Azure CLI authentication being used instead of SAS tokens
- ❌ Token refresh failures during large blob copy operations
- ⚠️ "Token refresh failed, azcopy will use existing authentication" warnings

However, when running via `invoke_step.ps1` directly, the parameter worked correctly because that wrapper properly handles switch parameters.

## Root Cause

In `scripts/main/semaphore_wrapper.ps1`:

1. ✅ The parameter was being **parsed** from command line arguments (line 79)
2. ❌ The parameter was **NOT extracted** into a variable
3. ❌ The parameter was **NOT added** to the `$scriptParams` hashtable passed to `self_service.ps1`

### Evidence from Logs

**Failed run (via semaphore_wrapper.ps1):**
```
5:41:21 PM - 📋 Raw arguments: DryRun=false UseSasTokens=true production_confirm=oki
5:41:21 PM - 🔧 Parsed parameter: UseSasTokens = true
...
5:52:19 PM - UseSasTokens: False (Type: SwitchParameter)  ❌ WRONG!
5:52:19 PM - ℹ️  SAS Token mode is DISABLED (default)
```

**Successful run (via invoke_step.ps1):**
```
1:52:40 PM - UseSasTokens: True (Type: SwitchParameter)  ✅ CORRECT!
1:52:40 PM - ⚠️  SAS Token mode is ENABLED
```

## Solution

Added three fixes to `scripts/main/semaphore_wrapper.ps1`:

### Fix 1: Extract UseSasTokens parameter (after line 122)
```powershell
$UseSasTokens = if ($parsedParams.ContainsKey("UseSasTokens")) { 
    $useSasValue = $parsedParams["UseSasTokens"]
    $useSasBool = if ($useSasValue -eq "true" -or $useSasValue -eq $true) { $true } else { $false }
    $useSasBool
} else { 
    $false 
}
```

### Fix 2: Add to diagnostic output (after line 143)
```powershell
Write-Host "  UseSasTokens: $UseSasTokens" -ForegroundColor Gray
```

### Fix 3: Add to scriptParams hashtable (after line 376)
```powershell
$scriptParams['UseSasTokens'] = $UseSasTokens
```

## Testing

To verify the fix works:

```bash
# Test with UseSasTokens=true
pwsh scripts/main/semaphore_wrapper.ps1 \
  DryRun=true \
  UseSasTokens=true \
  production_confirm=test

# Expected output should show:
#   🔧 Parsed parameter: UseSasTokens = true
#   📋 Sanitized parameters:
#     UseSasTokens: True
#   
#   In CopyAttachments.ps1:
#     UseSasTokens: True (Type: SwitchParameter)
#     ⚠️  SAS Token mode is ENABLED
```

## Impact

- ✅ Large blob copy operations (3TB+) will now use SAS tokens with 8-hour validity
- ✅ No more authentication token refresh failures during long-running copies
- ✅ Consistent behavior between `semaphore_wrapper.ps1` and `invoke_step.ps1`

## Files Modified

- `scripts/main/semaphore_wrapper.ps1` (3 changes)

## Related Scripts

This fix ensures proper parameter passing for:
- `scripts/storage/CopyAttachments.ps1` - Uses `UseSasTokens` switch parameter
- `scripts/main/self_service.ps1` - Accepts and passes through `UseSasTokens`
- `scripts/step_wrappers/invoke_step.ps1` - Already handles switch parameters correctly

