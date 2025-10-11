# Bug Fix: Debug Parameter Conflict

## 🐛 Issue

**Error:**
```
❌ FATAL ERROR: A parameter with the name 'Debug' was defined multiple times for the command.
```

**Cause:**
PowerShell has a **built-in common parameter** called `-Debug` that is automatically added to all cmdlets and functions. When we tried to define our own `-Debug` parameter, it conflicted with the built-in one.

---

## ✅ Solution

Renamed the custom parameter from `-Debug` to `-VerboseLogging` to avoid the conflict.

---

## 📝 Files Modified

### 1. **scripts/restore/RestorePointInTime.ps1**

**Before:**
```powershell
param (
    [Parameter(Mandatory)][string]$source,
    ...
    [switch]$Debug  ❌ Conflicts with PowerShell built-in
)
```

**After:**
```powershell
param (
    [Parameter(Mandatory)][string]$source,
    ...
    [switch]$VerboseLogging  ✅ No conflict
)
```

---

### 2. **scripts/database/copy_database.ps1**

**Before:**
```powershell
param (
    [Parameter(Mandatory)] [string]$source,
    ...
    [switch]$Debug  ❌ Conflicts with PowerShell built-in
)

# Usage in code:
if ($Debug) {
    Write-Host "Debug info"
}
```

**After:**
```powershell
param (
    [Parameter(Mandatory)] [string]$source,
    ...
    [switch]$VerboseLogging  ✅ No conflict
)

# Usage in code:
if ($VerboseLogging) {
    Write-Host "Debug info"
}
```

**Changed 2 references:**
- Line 191: `if ($VerboseLogging) { ... }`
- Line 294: `if ($VerboseLogging) { ... }`

---

### 3. **REFACTORING_SUMMARY.md**

Updated usage examples to use `-VerboseLogging` instead of `-Debug`.

---

## 🔍 Why This Happened

PowerShell automatically adds **common parameters** to all advanced functions:

**Built-in Common Parameters:**
- `-Verbose`
- `-Debug` ← **This one conflicted**
- `-ErrorAction`
- `-WarningAction`
- `-InformationAction`
- `-ErrorVariable`
- `-WarningVariable`
- `-InformationVariable`
- `-OutVariable`
- `-OutBuffer`
- `-PipelineVariable`

You **cannot** redefine these parameter names without causing conflicts.

---

## 💡 Best Practice

**Avoid these parameter names:**
- `-Debug`
- `-Verbose`
- `-ErrorAction`
- `-WarningAction`
- Any other PowerShell common parameter

**Use these instead:**
- `-VerboseLogging` ✅
- `-DetailedOutput` ✅
- `-ShowDebugInfo` ✅
- `-EnableTracing` ✅

---

## 🎯 Usage After Fix

### Copy Database

```powershell
# Without verbose logging (default)
./copy_database.ps1 -source "dev" -destination "qa" -SourceNamespace "manufacturo" -DestinationNamespace "test"

# With verbose logging (shows detailed SQL commands, tag operations, etc.)
./copy_database.ps1 -source "dev" -destination "qa" -SourceNamespace "manufacturo" -DestinationNamespace "test" -VerboseLogging
```

### Restore Point in Time

```powershell
# Without verbose logging (default)
./RestorePointInTime.ps1 -source "dev" -SourceNamespace "manufacturo" -RestoreDateTime "2025-10-11 14:30:00" -Timezone "UTC"

# With verbose logging
./RestorePointInTime.ps1 -source "dev" -SourceNamespace "manufacturo" -RestoreDateTime "2025-10-11 14:30:00" -Timezone "UTC" -VerboseLogging
```

---

## 🧪 Testing

The scripts should now work without the parameter conflict error:

```powershell
# Test dry run (should work now)
./semaphore_wrapper.ps1 "RestoreDateTime=2025-10-11 05:34:30" "Timezone=America/New_York" "Source=gov001" "SourceNamespace=manufacturo" "DryRun=true"
```

**Expected output:**
```
✅ No parameter conflict error
✅ Dry run executes successfully
```

---

## 📚 Related Information

### PowerShell Common Parameters Documentation

To see all common parameters:
```powershell
Get-Help about_CommonParameters
```

**Output includes:**
```
-Debug [<SwitchParameter>]
    Displays programmer-level detail about the operation performed by 
    the command.
```

This is why `-Debug` was already taken!

---

## 🔄 Migration Notes

**For users:**
- If you were using `-Debug` parameter (unlikely, as it wasn't working), change to `-VerboseLogging`
- No other changes needed

**For developers:**
- Remember to avoid PowerShell common parameter names
- Use descriptive, unique parameter names

---

## ✅ Resolution Status

- [x] Fixed parameter conflict in RestorePointInTime.ps1
- [x] Fixed parameter conflict in copy_database.ps1
- [x] Updated all references from `$Debug` to `$VerboseLogging`
- [x] Updated documentation (REFACTORING_SUMMARY.md)
- [x] Created this bug fix documentation

**Status:** ✅ **RESOLVED**

---

*Bug Reported: 2025-10-11 09:39:30*  
*Bug Fixed: 2025-10-11 (same day)*  
*Impact: Scripts now run without parameter conflicts*

