# Solution Summary: Dynamic Repository Path Resolution

## Problem
Semaphore creates incrementing repository folders (`repository_1_template_1`, `repository_1_template_2`, etc.) each time templates are updated. Hardcoded paths in scripts caused execution of stale code.

## Solution
Implemented **runtime path detection** that automatically finds and uses the latest repository folder based on modification timestamps.

## What Changed

### 1. Main Workflow Wrapper
**File**: `scripts/main/semaphore_wrapper.ps1`

**Change**: Added dynamic path detection at runtime
```powershell
# Detects latest repository and updates script paths
$repositories = Get-ChildItem -Path "/tmp/semaphore/project_1" -Directory | 
    Where-Object { $_.Name -match '^repository_\d+_template_\d+$' } |
    Sort-Object LastWriteTime -Descending
```

### 2. Individual Task Wrapper
**File**: `scripts/step_wrappers/invoke_step.ps1`

**Change**: Same dynamic detection before executing any task

### 3. Helper Utility
**File**: `scripts/common/Get-LatestRepositoryPath.ps1`

**Change**: NEW - Reusable function for path detection

### 4. Documentation
**File**: `docs/DYNAMIC_PATH_RESOLUTION.md`

**Change**: NEW - Comprehensive documentation of the solution

### 5. Test Script
**File**: `scripts/test/Test-DynamicPathDetection.ps1`

**Change**: NEW - Validation script to verify path detection works

## How It Works

1. **At script execution time** (not template creation):
   - Script checks `/tmp/semaphore/project_1/` for all repository folders
   - Filters folders matching pattern `repository_\d+_template_\d+`
   - Sorts by `LastWriteTime` (most recent first)
   - Uses the latest folder for all operations

2. **Graceful fallback**:
   - If detection fails, uses current directory
   - Works in both Semaphore and local environments

## Benefits

✅ **Always uses latest code** - Scripts automatically execute against newest repository
✅ **No manual intervention** - No need to rebuild Docker images or update paths
✅ **Zero downtime** - Works immediately after Git sync
✅ **Transparent** - Clear logging shows which repository is being used
✅ **Safe** - Falls back to current directory if detection fails

## Testing

### Quick Test
Run from within Semaphore pod:
```bash
kubectl exec -n semaphore <pod-name> -- pwsh /tmp/semaphore/project_1/repository_1_template_X/scripts/test/Test-DynamicPathDetection.ps1
```

### What to Look For
In task execution logs:
```
🔍 Detecting latest repository path...
   ✅ Latest repository: repository_1_template_6
   📅 Modified: 10/15/2025 10:53:00
```

## Example Scenario

**Before**:
1. Template created → uses `repository_1_template_1`
2. Code updated in Git
3. New template created → new folder `repository_1_template_6`
4. Old tasks still run from `repository_1_template_1` ❌ (stale code)

**After**:
1. Template created → uses any `repository_1_template_N`
2. Code updated in Git  
3. New template created → new folder `repository_1_template_6`
4. **All tasks automatically detect and use** `repository_1_template_6` ✅ (latest code)

## Files Modified

| File | Change Type | Description |
|------|-------------|-------------|
| `scripts/main/semaphore_wrapper.ps1` | Modified | Added path detection |
| `scripts/step_wrappers/invoke_step.ps1` | Modified | Added path detection |
| `scripts/common/Get-LatestRepositoryPath.ps1` | Created | Reusable utility function |
| `docs/DYNAMIC_PATH_RESOLUTION.md` | Created | Full documentation |
| `scripts/test/Test-DynamicPathDetection.ps1` | Created | Validation script |
| `create-templates-corrected.sh` | Modified | Added clarifying comment |

## Rollout Plan

1. ✅ **Commit changes** to Git repository
2. ✅ **Push to main branch**
3. ⏳ **Wait for Semaphore sync** (automatic)
4. ⏳ **Test with dry-run task** - verify path detection in logs
5. ⏳ **Run test script** - validate with `Test-DynamicPathDetection.ps1`
6. ⏳ **Execute production workflow** - confirm latest code is used

## Troubleshooting

**Q: Script still uses old code?**
- Check logs for "Detecting latest repository path"
- Verify timestamps in logs match newest folder
- Ensure Git sync completed successfully

**Q: Path detection fails?**
- Verify `/tmp/semaphore/project_1/` exists
- Check repository folders follow naming: `repository_\d+_template_\d+`
- Confirm PowerShell has read permissions

## Next Steps

1. **Deploy** - Push changes to Git and let Semaphore sync
2. **Verify** - Run a test task and check logs
3. **Monitor** - Watch first few production runs
4. **Optional Cleanup** - Remove old repository folders if needed

---

**Status**: ✅ Ready for Deployment

**Created**: October 15, 2025

**Impact**: All Semaphore tasks will automatically use latest code

