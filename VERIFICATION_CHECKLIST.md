# Verification Checklist: UseSasTokens Fix

## Pre-Deployment Checks

### ✅ Code Review
- [x] Fix applied to `scripts/main/semaphore_wrapper.ps1`
- [x] Three changes made (extract, diagnostic, forward)
- [x] No linter errors introduced
- [x] Code follows existing patterns

### ✅ Documentation
- [x] `FIX_SUMMARY.md` - Quick reference
- [x] `ANALYSIS_UseSasTokens_Issue.md` - Detailed analysis
- [x] `DIAGRAM_Parameter_Flow.md` - Visual diagrams
- [x] `BUGFIX_UseSasTokens.md` - Technical details

### ✅ Testing
- [x] Automated test script created: `scripts/test/test_usesastokens_fix.ps1`
- [ ] **TODO**: Run automated test
- [ ] **TODO**: Manual test with DryRun=true
- [ ] **TODO**: Integration test with actual blob copy

---

## Deployment Steps

### 1. Commit Changes
```bash
cd /home/kgluza/Manufacturo/semaphore
git status
git add scripts/main/semaphore_wrapper.ps1
git add scripts/test/test_usesastokens_fix.ps1
git add *.md
git commit -m "Fix: UseSasTokens parameter not being passed through semaphore_wrapper.ps1

- Added parameter extraction (line 123-129)
- Added diagnostic output (line 144)
- Added parameter forwarding (line 377)
- Added automated test script
- Added comprehensive documentation

Fixes issue where UseSasTokens=true was being ignored, causing
authentication failures during large blob copy operations."
```

### 2. Push to Repository
```bash
git push origin main
```

### 3. Verify Semaphore Picks Up Changes
- [ ] Check Semaphore pulls latest code
- [ ] Verify repository timestamp in logs
- [ ] Confirm wrapper script version

---

## Post-Deployment Verification

### Test 1: Dry Run with UseSasTokens=true
```bash
# In Semaphore, run with parameters:
DryRun=true
UseSasTokens=true
production_confirm=test
```

**Expected Output:**
```
🔧 Parsed parameter: UseSasTokens = true
📋 Sanitized parameters:
  UseSasTokens: True

# In CopyAttachments.ps1:
UseSasTokens: True (Type: SwitchParameter)
⚠️  SAS Token mode is ENABLED
```

**Checklist:**
- [ ] Parameter parsed correctly
- [ ] Parameter shown in diagnostics
- [ ] CopyAttachments receives UseSasTokens=True
- [ ] SAS token mode enabled message shown

### Test 2: Dry Run with UseSasTokens=false
```bash
# In Semaphore, run with parameters:
DryRun=true
UseSasTokens=false
production_confirm=test
```

**Expected Output:**
```
🔧 Parsed parameter: UseSasTokens = false
📋 Sanitized parameters:
  UseSasTokens: False

# In CopyAttachments.ps1:
UseSasTokens: False (Type: SwitchParameter)
ℹ️  SAS Token mode is DISABLED (default)
```

**Checklist:**
- [ ] Parameter parsed correctly
- [ ] Parameter shown in diagnostics
- [ ] CopyAttachments receives UseSasTokens=False
- [ ] SAS token mode disabled message shown

### Test 3: Production Run with UseSasTokens=true
```bash
# In Semaphore, run ACTUAL production refresh with:
DryRun=false
UseSasTokens=true
production_confirm=<actual_confirmation>
```

**Expected Behavior:**
```
# In CopyAttachments.ps1:
🔐 Generating SAS tokens (valid for 8 hours)...
🔄 Starting copy operation...
✅ Container copied successfully
```

**Checklist:**
- [ ] SAS tokens generated (not Azure CLI auth)
- [ ] No "Token refresh failed" warnings
- [ ] Blob copy operations complete successfully
- [ ] Large containers (3TB+) copy without timeout

---

## Rollback Plan

If issues occur after deployment:

### Option 1: Quick Revert
```bash
git revert HEAD
git push origin main
```

### Option 2: Manual Fix
Remove lines from `scripts/main/semaphore_wrapper.ps1`:
- Line 123-129 (UseSasTokens extraction)
- Line 144 (diagnostic output)
- Line 377 (parameter forwarding)

### Option 3: Use invoke_step.ps1
As a workaround, use `invoke_step.ps1` which already handles switch parameters correctly:
```bash
pwsh invoke_step.ps1 \
  ScriptPath=storage/CopyAttachments.ps1 \
  Source=gov001 \
  Destination=gov001 \
  SourceNamespace=manufacturo \
  DestinationNamespace=test \
  UseSasTokens=true \
  DryRun=false
```

---

## Success Criteria

### ✅ Fix is Successful If:
- [ ] UseSasTokens=true is correctly parsed
- [ ] Parameter appears in diagnostic output
- [ ] CopyAttachments.ps1 receives correct value
- [ ] SAS tokens are generated (not Azure CLI auth)
- [ ] Large blob copies complete without timeout
- [ ] No authentication errors in logs

### ❌ Fix Failed If:
- [ ] Parameter still shows as False when True is passed
- [ ] "Token refresh failed" warnings still appear
- [ ] Blob copy operations timeout
- [ ] Authentication errors persist

---

## Monitoring

### Key Log Messages to Watch

**Success Indicators:**
```
✅ "🔧 Parsed parameter: UseSasTokens = true"
✅ "UseSasTokens: True" in sanitized parameters
✅ "⚠️  SAS Token mode is ENABLED"
✅ "🔐 Generating SAS tokens (valid for 8 hours)"
✅ "✅ Container copied successfully"
```

**Failure Indicators:**
```
❌ "UseSasTokens: False" when True was passed
❌ "ℹ️  SAS Token mode is DISABLED (default)"
❌ "⚠️  Warning: Token refresh failed"
❌ "❌ Container copy failed"
```

---

## Contact & Support

### If Issues Occur:
1. Check Semaphore task logs for parameter values
2. Verify repository version in logs
3. Compare with expected output in this checklist
4. Review documentation in `ANALYSIS_UseSasTokens_Issue.md`
5. Run automated test: `scripts/test/test_usesastokens_fix.ps1`

### Files to Review:
- `scripts/main/semaphore_wrapper.ps1` (lines 123-129, 144, 377)
- `scripts/main/self_service.ps1` (line 63, 433-436)
- `scripts/storage/CopyAttachments.ps1` (line 7, 138-143, 322-348)

---

## Final Sign-Off

- [ ] Code reviewed and approved
- [ ] Documentation complete
- [ ] Tests passing
- [ ] Deployment successful
- [ ] Post-deployment verification complete
- [ ] Production run successful
- [ ] No rollback needed

**Date:** _________________
**Verified By:** _________________
**Notes:** _________________

