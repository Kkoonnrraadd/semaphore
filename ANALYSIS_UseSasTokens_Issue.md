# Analysis: UseSasTokens Parameter Not Being Passed

## Executive Summary

**Issue**: The `UseSasTokens=true` parameter was being lost when running through `semaphore_wrapper.ps1`, causing large blob copy operations to fail with authentication errors.

**Root Cause**: Missing parameter extraction and forwarding in `semaphore_wrapper.ps1`

**Status**: ✅ **FIXED**

---

## Problem Description

### Symptoms

When running the full production workflow via `semaphore_wrapper.ps1`:

```
5:52:19 PM - UseSasTokens: False (Type: SwitchParameter)  ❌
5:52:19 PM - ℹ️  SAS Token mode is DISABLED (default)
5:52:56 PM - 🔑 Refreshing Azure authentication for storage...
5:52:57 PM - ⚠️  Warning: Token refresh failed, azcopy will use existing authentication
```

When running via `invoke_step.ps1` (single step):

```
1:52:40 PM - UseSasTokens: True (Type: SwitchParameter)  ✅
1:52:40 PM - ⚠️  SAS Token mode is ENABLED
1:53:17 PM - 🔐 Generating SAS tokens (valid for 8 hours)...
```

### Impact

- **Authentication Failures**: Azure CLI token refresh failures during long-running blob copies
- **Copy Failures**: Large container copies (3TB+) timing out due to token expiration
- **Inconsistent Behavior**: Different behavior between full workflow and single-step execution
- **Production Issues**: Failed data refresh operations requiring manual intervention

---

## Root Cause Analysis

### Parameter Flow

The parameter should flow through these components:

```
Semaphore UI (UseSasTokens=true)
    ↓
semaphore_wrapper.ps1 (Parse and forward)
    ↓
self_service.ps1 (Accept and use)
    ↓
CopyAttachments.ps1 (Use SAS tokens)
```

### What Was Broken

In `scripts/main/semaphore_wrapper.ps1`:

1. **Parsing**: ✅ Working (line 79)
   ```powershell
   # Function Parse-Arguments correctly extracted "UseSasTokens=true"
   $parameters[$paramName] = $paramValue
   ```

2. **Extraction**: ❌ **MISSING**
   ```powershell
   # Lines 104-123: All other parameters extracted into variables
   # UseSasTokens was NOT extracted
   ```

3. **Forwarding**: ❌ **MISSING**
   ```powershell
   # Lines 343-369: Building $scriptParams hashtable
   # UseSasTokens was NOT added to hashtable
   ```

### Why invoke_step.ps1 Worked

The `invoke_step.ps1` wrapper has proper switch parameter handling:

```powershell
# Line 212-221: Proper boolean/switch parameter conversion
if ($knownSwitchParams -contains $key) {
    $boolValue = Convert-ToBoolean -Value $value
    if ($boolValue) {
        $scriptParams[$key] = $true  # ✅ Correctly added
    }
}
```

---

## The Fix

### Changes Made to `semaphore_wrapper.ps1`

#### 1. Extract UseSasTokens Parameter (Line 123-129)

```powershell
$UseSasTokens = if ($parsedParams.ContainsKey("UseSasTokens")) { 
    $useSasValue = $parsedParams["UseSasTokens"]
    $useSasBool = if ($useSasValue -eq "true" -or $useSasValue -eq $true) { $true } else { $false }
    $useSasBool
} else { 
    $false 
}
```

**Why**: Converts string "true"/"false" to PowerShell boolean, with safe default to `false`

#### 2. Add Diagnostic Output (Line 144)

```powershell
Write-Host "  UseSasTokens: $UseSasTokens" -ForegroundColor Gray
```

**Why**: Allows verification that parameter is correctly parsed and will be forwarded

#### 3. Add to scriptParams Hashtable (Line 377)

```powershell
$scriptParams['UseSasTokens'] = $UseSasTokens
```

**Why**: Actually passes the parameter to `self_service.ps1` via splatting

---

## Verification

### Before Fix

```bash
# Command
pwsh semaphore_wrapper.ps1 DryRun=false UseSasTokens=true production_confirm=oki

# Output (WRONG)
🔧 Parsed parameter: UseSasTokens = true
📋 Sanitized parameters:
  UseSasTokens: <NOT SHOWN - MISSING>
  
# In CopyAttachments.ps1
UseSasTokens: False (Type: SwitchParameter)  ❌
ℹ️  SAS Token mode is DISABLED (default)
```

### After Fix

```bash
# Command
pwsh semaphore_wrapper.ps1 DryRun=false UseSasTokens=true production_confirm=oki

# Output (CORRECT)
🔧 Parsed parameter: UseSasTokens = true
📋 Sanitized parameters:
  UseSasTokens: True  ✅
  
# In CopyAttachments.ps1
UseSasTokens: True (Type: SwitchParameter)  ✅
⚠️  SAS Token mode is ENABLED
🔐 Generating SAS tokens (valid for 8 hours)...
```

---

## Testing

### Automated Test

Run the test script:

```bash
pwsh scripts/test/test_usesastokens_fix.ps1
```

Expected output:
```
✅ Test 1 PASSED: UseSasTokens=true is correctly parsed and passed
✅ Test 2 PASSED: UseSasTokens=false is correctly parsed and passed
✅ Test 3 PASSED: UseSasTokens defaults to false when not provided
✅ ALL TESTS PASSED - UseSasTokens parameter is working correctly!
```

### Manual Test

```bash
# Test with UseSasTokens=true (for large containers)
pwsh scripts/main/semaphore_wrapper.ps1 \
  DryRun=true \
  UseSasTokens=true \
  production_confirm=test

# Verify output shows:
# 1. "🔧 Parsed parameter: UseSasTokens = true"
# 2. "  UseSasTokens: True" in sanitized parameters
# 3. "⚠️  SAS Token mode is ENABLED" in CopyAttachments
```

---

## Related Components

### Files Modified

- ✅ `scripts/main/semaphore_wrapper.ps1` (3 changes)

### Files Analyzed (No Changes Needed)

- ✅ `scripts/main/self_service.ps1` - Already accepts `UseSasTokens` parameter
- ✅ `scripts/storage/CopyAttachments.ps1` - Already uses `UseSasTokens` parameter
- ✅ `scripts/step_wrappers/invoke_step.ps1` - Already handles switch parameters correctly

---

## Lessons Learned

### Why This Bug Occurred

1. **Inconsistent Parameter Handling**: `semaphore_wrapper.ps1` and `invoke_step.ps1` had different parameter handling logic
2. **Missing Parameter Registration**: New parameters need to be registered in THREE places in the wrapper
3. **Insufficient Testing**: No automated tests for parameter flow through wrappers

### Prevention Strategies

1. **Standardize Parameter Handling**: Consider refactoring both wrappers to use the same parameter parsing logic
2. **Parameter Checklist**: When adding new parameters, ensure they're added to:
   - Parse function ✅
   - Extraction section ✅
   - scriptParams hashtable ✅
   - Diagnostic output ✅
3. **Automated Testing**: Add tests for parameter flow (see `test_usesastokens_fix.ps1`)

---

## Technical Details

### PowerShell Switch Parameters

Switch parameters in PowerShell are special:

```powershell
# Declaration
param([switch]$UseSasTokens)

# Usage
& script.ps1 -UseSasTokens        # Sets to $true
& script.ps1                       # Sets to $false (absent)
& script.ps1 -UseSasTokens:$false  # Explicitly sets to $false
```

### Semaphore's Key=Value Format

Semaphore passes parameters as strings:

```bash
UseSasTokens=true   # String "true", not boolean
```

### Conversion Required

```powershell
# String to Boolean conversion
$useSasValue = "true"  # From Semaphore
$useSasBool = if ($useSasValue -eq "true" -or $useSasValue -eq $true) { 
    $true 
} else { 
    $false 
}
```

### Splatting

```powershell
# Build hashtable
$scriptParams = @{
    UseSasTokens = $true  # Boolean value
}

# Call with splatting
& script.ps1 @scriptParams  # Equivalent to: script.ps1 -UseSasTokens
```

---

## References

### Related Documentation

- [CopyAttachments.ps1 Usage](scripts/storage/CopyAttachments.ps1) - SAS token mode for 3TB+ containers
- [PowerShell Switch Parameters](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_functions_advanced_parameters#switch-parameters)
- [PowerShell Splatting](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_splatting)

### Related Issues

- None (first occurrence)

---

## Conclusion

The `UseSasTokens` parameter is now correctly passed through all wrapper layers, enabling SAS token authentication for large blob copy operations (3TB+). This prevents token expiration issues during long-running copies and ensures consistent behavior across all execution paths.

**Status**: ✅ Fixed and tested
**Priority**: High (Production blocker)
**Complexity**: Low (Simple parameter forwarding)

