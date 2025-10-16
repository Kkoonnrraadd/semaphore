# Bug Fix: Parameter Name Mapping for invoke_step.ps1

## The Problem

When running `invoke_step.ps1` with `RestorePointInTime.ps1`:

```
Error: Cannot process command because of one or more missing mandatory parameters: 
       RestoreDateTime Timezone.
```

Even though `Invoke-PrerequisiteSteps.ps1` was auto-detecting these parameters!

## Root Cause

### Parameter Name Mismatch

**What `Get-AzureParameters.ps1` returns:**
```powershell
@{
    DefaultRestoreDateTime = "2025-10-16 10:22:08"  # ← Has "Default" prefix
    DefaultTimezone = "US/Eastern"                   # ← Has "Default" prefix
    Source = "gov001"
    Cloud = "AzureUSGovernment"
    ...
}
```

**What `RestorePointInTime.ps1` expects:**
```powershell
param(
    [string]$RestoreDateTime,  # ← No "Default" prefix
    [string]$Timezone          # ← No "Default" prefix
    ...
)
```

### The Merge Logic Was Correct, But Names Didn't Match

```powershell
# invoke_step.ps1 was doing:
foreach ($paramName in $detectedParams.Keys) {
    if ($acceptedParams -contains $paramName) {  # ← Looking for "DefaultRestoreDateTime"
        $scriptParams[$paramName] = ...           # But script wants "RestoreDateTime"
    }
}

# Result: Parameters never merged because names didn't match!
```

## The Solution

### Added Parameter Name Normalization

In `Invoke-PrerequisiteSteps.ps1`, we now normalize parameter names by creating **both** versions:

```powershell
# Original from Get-AzureParameters.ps1
$detectedParams = @{
    DefaultRestoreDateTime = "2025-10-16 10:22:08"
    DefaultTimezone = "US/Eastern"
}

# After normalization (what we return now):
$normalizedParams = @{
    DefaultRestoreDateTime = "2025-10-16 10:22:08"  # ← Keep original
    RestoreDateTime = "2025-10-16 10:22:08"         # ← Add normalized
    DefaultTimezone = "US/Eastern"                   # ← Keep original
    Timezone = "US/Eastern"                          # ← Add normalized
}
```

Now when `invoke_step.ps1` checks if `RestoreDateTime` is in detected parameters → **Found!** ✅

## Code Changes

### 1. Invoke-PrerequisiteSteps.ps1 (Lines 312-338)

```powershell
$detectedParams = & $azureParamsScript @detectionParams

if ($detectedParams) {
    # Normalize parameter names (map DefaultX to X for script compatibility)
    $normalizedParams = @{}
    foreach ($key in $detectedParams.Keys) {
        $value = $detectedParams[$key]
        
        # Add with original name
        $normalizedParams[$key] = $value
        
        # Also add without "Default" prefix for script compatibility
        if ($key -like "Default*") {
            $normalizedKey = $key -replace "^Default", ""
            $normalizedParams[$normalizedKey] = $value
            Write-Host "   📋 Mapped $key → $normalizedKey" -ForegroundColor DarkGray
        }
    }
    
    # Store normalized parameters
    $result.DetectedParameters = $normalizedParams
    ...
}
```

### 2. invoke_step.ps1 - Added Debug Output (Lines 245-280)

Now shows exactly what's being merged:

```powershell
🔀 Merging auto-detected parameters...
   ✅ Added RestoreDateTime = 2025-10-16 10:22:08
   ✅ Added Timezone = US/Eastern
   ⊘ Skipped DefaultRestoreDateTime (target script doesn't accept it)
   ⊘ Skipped DefaultTimezone (target script doesn't accept it)
   ✅ Merged 2 auto-detected parameter(s)
```

## What You'll See Now

### Before (Broken)

```
🔧 STEP 0C: AUTO-DETECT PARAMETERS
   ✅ Auto-detected DefaultRestoreDateTime: 2025-10-16 10:22:08
   ✅ Auto-detected DefaultTimezone: US/Eastern
   
═══════════════════════════════════════════════════════════════════════════
🚀 EXECUTING TARGET SCRIPT
═══════════════════════════════════════════════════════════════════════════

📌 Executing with 3 parameter(s)...

Error: Cannot process command because of one or more missing mandatory parameters: 
       RestoreDateTime Timezone.
```

### After (Fixed) ✅

```
🔧 STEP 0C: AUTO-DETECT PARAMETERS
   📋 Mapped DefaultRestoreDateTime → RestoreDateTime
   📋 Mapped DefaultTimezone → Timezone
   ✅ Auto-detected RestoreDateTime: 2025-10-16 10:22:08
   ✅ Auto-detected Timezone: US/Eastern
   ✅ Parameter auto-detection completed (2 parameter(s))

═══════════════════════════════════════════════════════════════════════════
✅ PREREQUISITES COMPLETED
═══════════════════════════════════════════════════════════════════════════

🔀 Merging auto-detected parameters...
   ✅ Added RestoreDateTime = 2025-10-16 10:22:08
   ✅ Added Timezone = US/Eastern
   ✅ Merged 2 auto-detected parameter(s)

═══════════════════════════════════════════════════════════════════════════
🚀 EXECUTING TARGET SCRIPT
═══════════════════════════════════════════════════════════════════════════

📌 Executing with 5 parameter(s)...
[Script executes successfully!]
```

## Why This Design?

### Question: Why does Get-AzureParameters.ps1 return "Default" prefix?

**Answer**: To avoid accidentally overriding user-provided values!

If `Get-AzureParameters.ps1` returned `RestoreDateTime`, and the user also provided `RestoreDateTime`, we'd have a conflict. By using `DefaultRestoreDateTime`, it's clear these are **fallback values**.

### Question: Why not just fix Get-AzureParameters.ps1?

**Answer**: Backward compatibility!

Other scripts (like `self_service.ps1`) expect the "Default" prefix and handle the mapping themselves:

```powershell
# self_service.ps1 does:
$script:RestoreDateTime = if (-not [string]::IsNullOrWhiteSpace($RestoreDateTime)) {
    $RestoreDateTime  # User-provided
} else {
    $detectedParams.DefaultRestoreDateTime  # Auto-detected fallback
}
```

### Our Solution: Make the Unified Module Handle It

Instead of changing the parameter detection or requiring every script to do mapping, we made `Invoke-PrerequisiteSteps.ps1` normalize the names automatically. This way:

✅ `Get-AzureParameters.ps1` keeps its existing interface (backward compatible)  
✅ `self_service.ps1` continues to work (it handles mapping manually)  
✅ `invoke_step.ps1` now works automatically (normalization happens in the module)  

## Testing

Run this command to verify the fix:

```bash
pwsh scripts/step_wrappers/invoke_step.ps1 \
  ScriptPath=restore/RestorePointInTime.ps1 \
  Source=gov001 \
  DryRun=true
```

You should now see:
1. Parameters auto-detected with mapping
2. Parameters successfully merged
3. Script executes without "missing mandatory parameters" error

## Related Files

- `scripts/common/Invoke-PrerequisiteSteps.ps1` - Added normalization logic
- `scripts/step_wrappers/invoke_step.ps1` - Added debug output
- `scripts/common/Get-AzureParameters.ps1` - Unchanged (returns `DefaultX` names)
- `scripts/main/self_service.ps1` - Unchanged (handles mapping manually)

## Summary

✅ **Fixed**: `invoke_step.ps1` now correctly passes `RestoreDateTime` and `Timezone` to target scripts  
✅ **Added**: Clear debug output showing parameter mapping and merging  
✅ **Maintained**: Backward compatibility with existing scripts  
✅ **Improved**: User experience with better logging  

**Root cause**: Parameter name mismatch between detection and consumption  
**Solution**: Automatic normalization of `DefaultX` → `X` in prerequisite module  
**Impact**: invoke_step.ps1 can now call any script that needs time parameters!

