# Dynamic Repository Path Resolution for Semaphore

## 🎯 Quick Start

**Problem Solved**: Scripts now automatically use the latest code version, even as Semaphore creates new repository folders (`repository_1_template_1`, `repository_1_template_2`, etc.).

**What Changed**: Added runtime path detection to wrapper scripts.

**Action Required**: 
1. Push these changes to Git
2. Let Semaphore sync
3. Done! ✅

---

## 📋 Table of Contents

- [Overview](#overview)
- [The Problem](#the-problem)
- [The Solution](#the-solution)
- [Files Changed](#files-changed)
- [How to Deploy](#how-to-deploy)
- [How to Test](#how-to-test)
- [Troubleshooting](#troubleshooting)
- [Maintenance](#maintenance)

---

## 🔍 Overview

Semaphore stores Git repositories in directories like:
```
/tmp/semaphore/project_1/
  ├── repository_1_template_1/  (Oct 14 10:37)
  ├── repository_1_template_2/  (Oct 15 10:16)
  └── repository_1_template_6/  (Oct 15 10:53)  ← Latest
```

Each time a template is created/updated, Semaphore increments the folder number. This solution ensures scripts **always execute from the latest folder**.

---

## ❌ The Problem

### Before This Fix

1. Templates registered with hardcoded path: `/tmp/semaphore/project_1/repository_1_template_1/...`
2. Code updated in Git → Semaphore syncs to new folder `repository_1_template_6`
3. Tasks still execute from `repository_1_template_1` (old code!) ❌
4. Required manual intervention or Docker rebuild

### Impact

- Scripts ran against stale code
- Bug fixes weren't applied immediately
- Parameter changes didn't take effect
- Confusion about which version was running

---

## ✅ The Solution

### Runtime Path Detection

At execution time, scripts:
1. Scan `/tmp/semaphore/project_1/` for all repository folders
2. Filter by pattern: `repository_\d+_template_\d+`
3. Sort by modification timestamp (newest first)
4. Use the latest folder for execution

### Example Output

```
🔍 Detecting latest repository path...
   ✅ Latest repository: repository_1_template_6
   📅 Modified: 10/15/2025 10:53:00
   📂 Other repositories:
      • repository_1_template_2 (modified: 10/15/2025 10:16:00)
      • repository_1_template_1 (modified: 10/14/2025 10:37:00)

📂 Self-service script path: /tmp/semaphore/.../repository_1_template_6/scripts/main/self_service.ps1
```

---

## 📁 Files Changed

### Modified Files

| File | Purpose | Change |
|------|---------|--------|
| `scripts/main/semaphore_wrapper.ps1` | Main workflow wrapper | Added path detection logic |
| `scripts/step_wrappers/invoke_step.ps1` | Individual task wrapper | Added path detection logic |
| `create-templates-corrected.sh` | Template creation | Added clarifying comment |

### New Files

| File | Purpose |
|------|---------|
| `scripts/common/Get-LatestRepositoryPath.ps1` | Reusable path detection utility |
| `scripts/test/Test-DynamicPathDetection.ps1` | Validation and testing script |
| `scripts/maintenance/Cleanup-OldRepositories.ps1` | Cleanup old repository folders |
| `docs/DYNAMIC_PATH_RESOLUTION.md` | Detailed technical documentation |
| `SOLUTION_SUMMARY.md` | Quick reference guide |
| `README_DYNAMIC_PATHS.md` | This file |

---

## 🚀 How to Deploy

### Step 1: Commit and Push

```bash
cd /home/kgluza/Manufacturo/semaphore

# Stage all changes
git add scripts/main/semaphore_wrapper.ps1
git add scripts/step_wrappers/invoke_step.ps1
git add scripts/common/Get-LatestRepositoryPath.ps1
git add scripts/test/Test-DynamicPathDetection.ps1
git add scripts/maintenance/Cleanup-OldRepositories.ps1
git add docs/DYNAMIC_PATH_RESOLUTION.md
git add SOLUTION_SUMMARY.md
git add README_DYNAMIC_PATHS.md
git add create-templates-corrected.sh

# Commit
git commit -m "feat: Add dynamic repository path detection for Semaphore

- Automatically detect and use latest repository folder
- Prevents execution of stale code as Semaphore increments folders
- Add path detection to semaphore_wrapper.ps1 and invoke_step.ps1
- Include validation and cleanup utilities
- Add comprehensive documentation"

# Push
git push origin main
```

### Step 2: Wait for Semaphore Sync

Semaphore will automatically:
1. Pull the latest code from Git
2. Create a new repository folder (e.g., `repository_1_template_7`)
3. Extract the code there

**This happens automatically** - no action required.

### Step 3: Verify Deployment

```bash
# Connect to Semaphore pod
kubectl exec -n semaphore <pod-name> -it -- bash

# Check repository folders
ls -al /tmp/semaphore/project_1/

# You should see multiple repository_1_template_N folders
```

---

## 🧪 How to Test

### Quick Verification

Run any Semaphore task and check the logs. You should see:

```
🔍 Detecting latest repository path...
   ✅ Latest repository: repository_1_template_X
```

### Comprehensive Test

Run the validation script inside the Semaphore pod:

```bash
# Get pod name
POD_NAME=$(kubectl get pods -n semaphore -l app=semaphore -o jsonpath='{.items[0].metadata.name}')

# Run test script
kubectl exec -n semaphore $POD_NAME -- \
  pwsh -File /tmp/semaphore/project_1/repository_1_template_*/scripts/test/Test-DynamicPathDetection.ps1
```

**Expected Output**: All tests pass ✅

### Manual Testing Scenario

1. **Run a task** - note which repository it uses (check logs)
2. **Update code in Git** and push
3. **Wait for Semaphore sync** (creates new repository folder)
4. **Run the same task again** - verify it uses the NEW repository

---

## 🔧 Troubleshooting

### Issue: Script still uses old code

**Symptoms**: Tasks execute with outdated logic

**Solution**:
1. Check task logs for "Detecting latest repository path"
2. Verify the repository name matches the newest folder timestamp
3. Ensure Git sync completed (check Semaphore UI)

```bash
# Check repository folders and timestamps
kubectl exec -n semaphore <pod> -- ls -alh /tmp/semaphore/project_1/
```

### Issue: Path detection fails

**Symptoms**: Script falls back to current directory

**Solution**:
1. Verify `/tmp/semaphore/project_1/` exists
2. Check folder naming matches `repository_\d+_template_\d+`
3. Verify PowerShell has read permissions

```bash
# Check permissions
kubectl exec -n semaphore <pod> -- ls -ld /tmp/semaphore/project_1/
```

### Issue: Multiple repositories consuming disk space

**Solution**: Use the cleanup script

```bash
# Dry run - preview what would be deleted
kubectl exec -n semaphore <pod> -- \
  pwsh -File /tmp/semaphore/project_1/repository_1_template_*/scripts/maintenance/Cleanup-OldRepositories.ps1 \
  -DryRun

# Actually delete old repositories (keep 3 most recent)
kubectl exec -n semaphore <pod> -- \
  pwsh -File /tmp/semaphore/project_1/repository_1_template_*/scripts/maintenance/Cleanup-OldRepositories.ps1 \
  -KeepCount 3
```

---

## 🧹 Maintenance

### Cleanup Old Repositories

Over time, you may accumulate many repository folders. Clean them up:

```bash
# From inside Semaphore pod
pwsh /tmp/semaphore/project_1/repository_1_template_*/scripts/maintenance/Cleanup-OldRepositories.ps1 -DryRun

# If satisfied, run for real
pwsh /tmp/semaphore/project_1/repository_1_template_*/scripts/maintenance/Cleanup-OldRepositories.ps1 -KeepCount 3
```

### Monitoring

Add this to your monitoring/alerting:

```bash
# Count repository folders
REPO_COUNT=$(kubectl exec -n semaphore <pod> -- \
  sh -c "ls -1 /tmp/semaphore/project_1/ | grep -c 'repository_.*_template_'" || echo 0)

if [ "$REPO_COUNT" -gt 5 ]; then
  echo "WARNING: $REPO_COUNT repository folders exist. Consider cleanup."
fi
```

### Regular Checks

Weekly:
- ✅ Verify tasks show correct repository in logs
- ✅ Check disk usage in `/tmp/semaphore/`
- ✅ Review if cleanup is needed

Monthly:
- ✅ Run comprehensive test suite
- ✅ Archive or delete very old repository folders

---

## 📚 Additional Documentation

- **Technical Details**: See [`docs/DYNAMIC_PATH_RESOLUTION.md`](docs/DYNAMIC_PATH_RESOLUTION.md)
- **Quick Reference**: See [`SOLUTION_SUMMARY.md`](SOLUTION_SUMMARY.md)
- **Complete Flow**: See [`docs/COMPLETE_FLOW.md`](docs/COMPLETE_FLOW.md)

---

## ✅ Success Criteria

Your deployment is successful when:

1. ✅ Task logs show "Detecting latest repository path"
2. ✅ Repository name matches newest folder
3. ✅ Code changes appear in next execution
4. ✅ Test script passes all checks
5. ✅ No errors in task execution

---

## 🎉 Benefits Achieved

- ✅ **Always latest code**: Scripts execute against newest version automatically
- ✅ **Zero manual intervention**: No Docker rebuilds or path updates needed
- ✅ **Immediate effect**: Code changes apply on next Git sync
- ✅ **Transparent**: Clear visibility into which version is running
- ✅ **Robust**: Graceful fallback if detection fails
- ✅ **Maintainable**: Easy cleanup of old versions

---

## 📞 Support

**Questions?**
- Review `docs/DYNAMIC_PATH_RESOLUTION.md` for technical details
- Check troubleshooting section above
- Run `Test-DynamicPathDetection.ps1` for diagnostics

**Found an issue?**
- Check Semaphore task logs for error messages
- Verify Git sync completed successfully
- Ensure repository structure is intact

---

**Last Updated**: October 15, 2025  
**Status**: ✅ Ready for Production  
**Impact**: All Semaphore tasks automatically use latest code

