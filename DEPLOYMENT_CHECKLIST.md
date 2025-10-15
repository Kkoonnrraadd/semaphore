# Deployment Checklist - Dynamic Path Resolution

## 📋 Pre-Deployment

- [ ] Review all modified files
- [ ] Understand the solution (read `SOLUTION_SUMMARY.md`)
- [ ] Test locally if possible
- [ ] Backup current Semaphore templates (optional)

## 🚀 Deployment Steps

### Step 1: Commit Changes

```bash
cd /home/kgluza/Manufacturo/semaphore

# Check status
git status

# Add all modified and new files
git add scripts/main/semaphore_wrapper.ps1
git add scripts/step_wrappers/invoke_step.ps1
git add scripts/common/Get-LatestRepositoryPath.ps1
git add scripts/test/Test-DynamicPathDetection.ps1
git add scripts/maintenance/Cleanup-OldRepositories.ps1
git add docs/DYNAMIC_PATH_RESOLUTION.md
git add docs/PATH_DETECTION_FLOW.md
git add SOLUTION_SUMMARY.md
git add README_DYNAMIC_PATHS.md
git add DEPLOYMENT_CHECKLIST.md
git add create-templates-corrected.sh

# Commit with descriptive message
git commit -m "feat: Add dynamic repository path detection for Semaphore

✨ Features:
- Runtime detection of latest repository folder
- Automatic switch to newest code version
- No manual intervention required for code updates

📝 Changes:
- Modified: scripts/main/semaphore_wrapper.ps1
- Modified: scripts/step_wrappers/invoke_step.ps1
- Added: scripts/common/Get-LatestRepositoryPath.ps1
- Added: scripts/test/Test-DynamicPathDetection.ps1
- Added: scripts/maintenance/Cleanup-OldRepositories.ps1
- Added: comprehensive documentation

🔧 Technical Details:
- Scans /tmp/semaphore/project_1/ for repository folders
- Sorts by LastWriteTime (newest first)
- Updates script paths to use latest repository
- Graceful fallback to current directory

✅ Benefits:
- Always executes latest code automatically
- Zero downtime for code updates
- Transparent operation with clear logging
- Easy maintenance and cleanup

📚 Documentation:
- See docs/DYNAMIC_PATH_RESOLUTION.md for details
- See SOLUTION_SUMMARY.md for quick reference
- See README_DYNAMIC_PATHS.md for deployment guide"

# Verify commit
git log -1 --stat
```

- [ ] Changes committed successfully

### Step 2: Push to Git

```bash
# Push to main branch
git push origin main

# Verify push succeeded
git log origin/main -1
```

- [ ] Code pushed to GitHub successfully

### Step 3: Wait for Semaphore Sync

**Automatic Process** - Semaphore will:
1. Detect new commits in Git
2. Clone/pull latest code
3. Create new repository folder (e.g., `repository_1_template_7`)

**Check Semaphore UI:**
- Go to: Repository → View Repository
- Check last sync time
- Verify status is "Success"

**Or check via kubectl:**
```bash
# Get Semaphore pod name
POD_NAME=$(kubectl get pods -n semaphore -l app=semaphore -o jsonpath='{.items[0].metadata.name}')

# Check repository folders
kubectl exec -n semaphore $POD_NAME -- ls -al /tmp/semaphore/project_1/

# You should see a NEW repository folder with recent timestamp
```

- [ ] Semaphore synced successfully
- [ ] New repository folder created
- [ ] Timestamp is recent (within last few minutes)

## 🧪 Testing Phase

### Test 1: Check Repository Detection

```bash
POD_NAME=$(kubectl get pods -n semaphore -l app=semaphore -o jsonpath='{.items[0].metadata.name}')

# List repository folders with timestamps
kubectl exec -n semaphore $POD_NAME -- \
  ls -alh /tmp/semaphore/project_1/ | grep repository
```

**Expected**: Multiple `repository_1_template_N` folders, newest has recent timestamp

- [ ] Multiple repository folders visible
- [ ] Newest folder has recent timestamp

### Test 2: Run Validation Script

```bash
# Run test script
kubectl exec -n semaphore $POD_NAME -- \
  pwsh -File /tmp/semaphore/project_1/repository_1_template_*/scripts/test/Test-DynamicPathDetection.ps1
```

**Expected**: All tests pass ✅

- [ ] TEST 1: Base directory exists ✅
- [ ] TEST 2: Repository folders detected ✅
- [ ] TEST 3: Latest repository selected ✅
- [ ] TEST 4: Directory structure valid ✅
- [ ] TEST 5: Key scripts found ✅
- [ ] TEST 6: Wrapper behavior correct ✅
- [ ] TEST 7: Git repository valid ✅

### Test 3: Run Dry-Run Task

In Semaphore UI:
1. Navigate to: Projects → PROJEKT → REFRESH view
2. Click: "Self-Service Data Refresh - DRY RUN"
3. Leave all parameters empty (test auto-detection)
4. Run the task

**Check the task logs for:**
```
🔍 Detecting latest repository path...
   ✅ Latest repository: repository_1_template_X
   📅 Modified: [recent timestamp]
```

- [ ] Task started successfully
- [ ] Path detection message visible in logs
- [ ] Latest repository name matches newest folder
- [ ] Task completed successfully

### Test 4: Verify Code Update Flow

**This validates the end-to-end workflow:**

1. Make a small, harmless change (e.g., add a comment to `semaphore_wrapper.ps1`)
2. Commit and push
3. Wait for Semaphore sync
4. Run a task
5. Verify it uses the NEW repository folder

```bash
# After pushing change, check for new repository
kubectl exec -n semaphore $POD_NAME -- \
  ls -alht /tmp/semaphore/project_1/ | grep repository | head -1
```

- [ ] New repository folder created after code update
- [ ] Task automatically uses new repository
- [ ] Code change visible in execution

## ✅ Post-Deployment Verification

### Check 1: Templates Work
- [ ] DRY RUN template executes successfully
- [ ] Individual task templates execute successfully
- [ ] Step 0A (Grant Permissions) works
- [ ] Step 0B (Connect to Azure) works

### Check 2: Path Detection in Logs
For the next few task executions, verify logs show:
- [ ] "🔍 Detecting latest repository path..." appears
- [ ] Correct repository name displayed
- [ ] Timestamp matches expectations

### Check 3: Parameters Work
- [ ] Auto-detection parameters work
- [ ] Manual parameters work
- [ ] Optional parameters handled correctly

## 🔧 Maintenance Tasks

### Immediate (Within 24 Hours)
- [ ] Monitor first 5-10 task executions
- [ ] Check for any unexpected errors
- [ ] Verify no regression in functionality

### Short-term (Within 1 Week)
- [ ] Review disk usage in `/tmp/semaphore/project_1/`
- [ ] Count repository folders (should accumulate with each Git sync)
- [ ] Plan first cleanup if > 5 folders exist

### Long-term (Monthly)
- [ ] Run cleanup script to remove old repositories
- [ ] Review solution effectiveness
- [ ] Check for any edge cases or improvements needed

## 🚨 Rollback Plan (If Needed)

If issues arise, you can rollback:

### Option 1: Git Revert
```bash
# Find the commit hash before this change
git log --oneline

# Revert to previous commit
git revert <commit-hash>
git push origin main

# Wait for Semaphore sync
```

### Option 2: Manual Path Override
In scripts, temporarily hardcode paths while you investigate:
```powershell
# In semaphore_wrapper.ps1, replace detection with:
$scriptDir = "/tmp/semaphore/project_1/repository_1_template_X/scripts/main"
```

### Option 3: Use Older Repository
If newer code has issues, you can manually select an older repository:
- Edit template in Semaphore UI
- Change playbook path to older repository folder
- This is temporary while you fix the issue

## 📊 Success Metrics

After 1 week of operation:
- [ ] 100% of tasks show path detection in logs
- [ ] Zero path-related errors
- [ ] Code updates apply within minutes (not hours/days)
- [ ] No manual intervention required for updates
- [ ] Team confidence in the solution

## 📞 Support Resources

If issues arise:
- **Documentation**: `docs/DYNAMIC_PATH_RESOLUTION.md`
- **Quick Reference**: `SOLUTION_SUMMARY.md`
- **Visual Guide**: `docs/PATH_DETECTION_FLOW.md`
- **Test Script**: `scripts/test/Test-DynamicPathDetection.ps1`
- **Troubleshooting**: See `README_DYNAMIC_PATHS.md`

## ✅ Final Sign-off

- [ ] All deployment steps completed
- [ ] All tests passed
- [ ] Production task executed successfully
- [ ] Team notified of change
- [ ] Documentation reviewed and accessible
- [ ] Monitoring in place

---

**Deployment Date**: _______________

**Deployed By**: _______________

**Status**: _______________

**Notes**: 
_____________________________________________________________________
_____________________________________________________________________
_____________________________________________________________________

---

## Quick Command Reference

```bash
# Get pod name
POD=$(kubectl get pods -n semaphore -l app=semaphore -o jsonpath='{.items[0].metadata.name}')

# List repositories
kubectl exec -n semaphore $POD -- ls -alht /tmp/semaphore/project_1/ | grep repository

# Run test
kubectl exec -n semaphore $POD -- pwsh /tmp/semaphore/project_1/repository_1_template_*/scripts/test/Test-DynamicPathDetection.ps1

# Cleanup old repositories (dry run)
kubectl exec -n semaphore $POD -- pwsh /tmp/semaphore/project_1/repository_1_template_*/scripts/maintenance/Cleanup-OldRepositories.ps1 -DryRun

# View task logs
kubectl logs -n semaphore $POD --tail=100 -f
```

---

**Good luck with deployment! 🚀**

