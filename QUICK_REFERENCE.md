# Quick Reference Card - Dynamic Path Resolution

## 🎯 One-Line Summary
Scripts now automatically detect and use the latest repository folder in Semaphore, eliminating stale code execution.

---

## 📂 What Changed

| File | What Changed |
|------|--------------|
| `scripts/main/semaphore_wrapper.ps1` | Added path detection at startup |
| `scripts/step_wrappers/invoke_step.ps1` | Added path detection at startup |
| + 6 new utility/doc files | Tests, cleanup, documentation |

---

## 🔍 How It Works

```
1. Script starts execution
2. Scans /tmp/semaphore/project_1/ for repository_*_template_* folders
3. Sorts by modification time (newest first)
4. Uses latest folder for execution
```

---

## ✅ Expected Log Output

```
🔍 Detecting latest repository path...
   ✅ Latest repository: repository_1_template_6
   📅 Modified: 10/15/2025 10:53:00
```

---

## 🧪 Quick Test

```bash
# Get pod name
POD=$(kubectl get pods -n semaphore -l app=semaphore -o jsonpath='{.items[0].metadata.name}')

# Run validation
kubectl exec -n semaphore $POD -- \
  pwsh /tmp/semaphore/project_1/repository_1_template_*/scripts/test/Test-DynamicPathDetection.ps1
```

**Expected**: All tests pass ✅

---

## 📋 Deployment Commands

```bash
# 1. Commit
git add -A
git commit -m "feat: Add dynamic repository path detection"

# 2. Push
git push origin main

# 3. Wait for Semaphore sync (automatic)
# Check: Semaphore UI → Repository → Last Sync Time

# 4. Verify
kubectl exec -n semaphore $POD -- \
  ls -alht /tmp/semaphore/project_1/ | grep repository
```

---

## 🔧 Common Commands

### List Repository Folders
```bash
POD=$(kubectl get pods -n semaphore -l app=semaphore -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n semaphore $POD -- \
  ls -alht /tmp/semaphore/project_1/ | grep repository
```

### Run Test Script
```bash
kubectl exec -n semaphore $POD -- \
  pwsh /tmp/semaphore/project_1/repository_1_template_*/scripts/test/Test-DynamicPathDetection.ps1
```

### Cleanup Old Repositories (Dry Run)
```bash
kubectl exec -n semaphore $POD -- \
  pwsh /tmp/semaphore/project_1/repository_1_template_*/scripts/maintenance/Cleanup-OldRepositories.ps1 -DryRun
```

### Cleanup Old Repositories (For Real)
```bash
kubectl exec -n semaphore $POD -- \
  pwsh /tmp/semaphore/project_1/repository_1_template_*/scripts/maintenance/Cleanup-OldRepositories.ps1 -KeepCount 3
```

---

## 🚨 Troubleshooting

### Issue: Script uses old code
**Check**: Task logs for "Detecting latest repository path"  
**Verify**: Repository name matches newest folder  
**Fix**: Ensure Semaphore sync completed successfully

### Issue: Path detection fails
**Check**: `/tmp/semaphore/project_1/` exists  
**Check**: Folder names match `repository_\d+_template_\d+`  
**Fix**: Run test script for diagnostics

### Issue: Too many repository folders
**Fix**: Run cleanup script (see commands above)

---

## 📚 Documentation Links

| Document | Purpose |
|----------|---------|
| `README_DYNAMIC_PATHS.md` | Complete deployment guide |
| `SOLUTION_SUMMARY.md` | Quick overview |
| `DEPLOYMENT_CHECKLIST.md` | Step-by-step checklist |
| `docs/DYNAMIC_PATH_RESOLUTION.md` | Technical details |
| `docs/PATH_DETECTION_FLOW.md` | Visual diagrams |
| `CHANGES_SUMMARY.txt` | All changes listed |

---

## 📊 Success Indicators

✅ **Logs show**: "🔍 Detecting latest repository path..."  
✅ **Repository name**: Matches newest folder  
✅ **Test script**: All tests pass  
✅ **Code updates**: Apply within minutes  
✅ **Zero errors**: No path-related failures  

---

## 🎯 Key Benefits

| Before | After |
|--------|-------|
| ❌ Manual path updates | ✅ Automatic detection |
| ❌ Stale code execution | ✅ Always latest code |
| ❌ Hours to deploy | ✅ Minutes to deploy |
| ❌ Docker rebuilds | ✅ Git push only |

---

## 💡 Tips

1. **Monitor first few executions** - Check logs to ensure detection works
2. **Cleanup regularly** - Remove old repositories when > 5 exist
3. **Check timestamps** - Verify repository dates match expectations
4. **Use dry-run first** - Test tasks with DRY RUN before production

---

## 🔗 Quick Links

```
Project Root: /home/kgluza/Manufacturo/semaphore
Scripts:      scripts/
Tests:        scripts/test/
Maintenance:  scripts/maintenance/
Docs:         docs/
```

---

## 📞 Getting Help

**Step 1**: Check this quick reference  
**Step 2**: Read `README_DYNAMIC_PATHS.md`  
**Step 3**: Review troubleshooting in documentation  
**Step 4**: Run test script for diagnostics  
**Step 5**: Check Semaphore task logs  

---

## ⚡ Emergency Rollback

If something goes wrong:

```bash
# Option 1: Git revert
git log --oneline
git revert <commit-hash>
git push origin main

# Option 2: Hardcode path temporarily
# Edit scripts/main/semaphore_wrapper.ps1
# Replace detection with:
# $scriptDir = "/tmp/semaphore/project_1/repository_1_template_X/scripts/main"
```

---

**Last Updated**: October 15, 2025  
**Status**: Ready for Deployment ✅  
**Print This**: Keep handy during deployment!

