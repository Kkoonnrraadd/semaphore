# 🔒 Security & Safety Audit Report

**Date:** 2025-10-10  
**Purpose:** Identify risks that could "blow up production"

---

## 🚨 CRITICAL FINDINGS - MUST FIX

### 1. ⚠️ **PRODUCTION ENVIRONMENT WARNINGS**

**Risk Level:** 🟡 **MEDIUM** (Was Critical, now mitigated with warnings)  
**Impact:** Could accidentally delete/modify production databases

**Philosophy:**
- **User-provided parameters are ALWAYS respected** (explicit intent)
- **Auto-detected values get warnings** (accidental misconfiguration)

**Implementation:**
```powershell
# In Get-AzureParameters.ps1
if ([string]::IsNullOrWhiteSpace($Source)) {
    # Auto-detected from ENVIRONMENT variable
    $PROTECTED_NAMES = @("prod", "production", "prd", "live")
    if ($Source -in $PROTECTED_NAMES) {
        Write-Host "⚠️  WARNING: Source environment name '$Source' looks like PRODUCTION!"
        Write-Host "   Auto-detected from ENVIRONMENT variable"
        Write-Host "   Please verify this is intentional"
    }
} else {
    # User explicitly provided - RESPECT their choice
    Write-Host "🎯 Using USER-PROVIDED source: $Source"
}
```

**Status:** ✅ **IMPLEMENTED** - Warns on auto-detection, respects explicit user input

---

### 2. ⚠️ **DATABASE DELETION WITHOUT EXPLICIT CONFIRMATION**

**Risk Level:** 🔴 **CRITICAL**  
**Impact:** Permanent data loss

**Files:**
- `scripts/database/copy_database.ps1:779` - Deletes databases with `--yes` flag
- `scripts/database/delete_restored_db.ps1:63` - Deletes databases automatically
- `scripts/replicas/delete_replicas.ps1:169` - Deletes replica databases

**Problem:**
```powershell
# Line 779 in copy_database.ps1
az sql db delete --name $dest_dbName --yes --only-show-errors
# Deletes without asking!
```

**Recommendation:**
Add confirmation requirement for non-dry-run operations:
```powershell
if (-not $DryRun) {
    Write-Host "`n⚠️  WARNING: This will DELETE the following databases:" -ForegroundColor Red
    Write-Host "   $dest_dbName on $dest_server" -ForegroundColor Yellow
    Write-Host "`n   Type 'DELETE' to confirm: " -NoNewline -ForegroundColor Red
    $confirmation = Read-Host
    
    if ($confirmation -ne "DELETE") {
        throw "Operation cancelled - confirmation not received"
    }
}
```

---

### 3. ⚠️ **SOURCE = DESTINATION CAN DELETE PRODUCTION DATA**

**Risk Level:** 🔴 **CRITICAL**  
**Impact:** Overwriting source databases

**Problem:**
```powershell
# In Get-AzureParameters.ps1:110
if ([string]::IsNullOrWhiteSpace($Destination)) {
    $Destination = $Source  # DANGEROUS!
}
```

If Source is accidentally set to production and Destination is empty, operations will TARGET THE SAME ENVIRONMENT, potentially overwriting production data.

**Recommendation:**
```powershell
# Validate Source != Destination
if ($Source -eq $Destination -and $SourceNamespace -eq $DestinationNamespace) {
    Write-Host "" -ForegroundColor Red
    Write-Host "🚫 BLOCKED: Source and Destination cannot be the same!" -ForegroundColor Red
    Write-Host "   Source: $Source/$SourceNamespace" -ForegroundColor Yellow
    Write-Host "   Destination: $Destination/$DestinationNamespace" -ForegroundColor Yellow
    Write-Host "   This would overwrite the source environment!" -ForegroundColor Red
    Write-Host "" -ForegroundColor Red
    throw "Source and Destination must be different"
}
```

---

### 4. ⚠️ **NO BACKUP VERIFICATION BEFORE DELETION**

**Risk Level:** 🟠 **HIGH**  
**Impact:** Data loss if copy fails

**Problem:**
```powershell
# copy_database.ps1:777 - Deletes BEFORE verifying copy succeeded
az sql db delete --name $dest_dbName --yes
# Then tries to copy...
# If copy fails, data is LOST
```

**Current Code (Line 905-925):**
```powershell
# AFTER the fact, checks if databases were orphaned
Write-Host "`n🔍 Checking for orphaned databases (deleted but copy failed)..." 
```

**Recommendation:**
- NEVER delete until AFTER successful copy verification
- Use database renaming instead of deletion
- Keep old database as backup for 24 hours

---

### 5. ⚠️ **SQL DELETE OPERATIONS WITHOUT TRANSACTION SAFETY**

**Risk Level:** 🟠 **HIGH**  
**Impact:** Partial data corruption

**Files:**
- `scripts/configuration/adjust_db.ps1:257-259`
- `scripts/configuration/cleanup_environment_config.ps1:125-134`

**Problem:**
```sql
DELETE FROM engine.parameter;
DELETE FROM api_keys.entity;
DELETE FROM api_keys.challengedlog;
-- No BEGIN TRANSACTION / ROLLBACK / COMMIT!
```

**Recommendation:**
```sql
BEGIN TRANSACTION;
BEGIN TRY
    DELETE FROM engine.parameter;
    DELETE FROM api_keys.entity;
    DELETE FROM api_keys.challengedlog;
    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    ROLLBACK TRANSACTION;
    THROW;
END CATCH
```

---

## 🟡 HIGH PRIORITY WARNINGS

### 6. ⚠️ **Parallel Database Operations Can Cause Race Conditions**

**File:** `scripts/database/delete_restored_db.ps1:56`

```powershell
$restored_dbs_to_delete | ForEach-Object -ThrottleLimit 10 -Parallel {
    az sql db delete --name $restored_dbName --yes
}
```

**Risk:** 10 parallel deletions could overwhelm Azure API or cause conflicts

**Recommendation:** Reduce throttle to 3-5 or add delays

---

### 7. ⚠️ **Environment Variable ENVIRONMENT is Critical but Not Validated**

**File:** `scripts/common/Connect-Azure.ps1:54`

**Problem:**
- `ENVIRONMENT` variable drives everything
- No validation of format (should it be lowercase? match pattern?)
- Could typo "gov001" as "gov01" and target wrong subscription

**Recommendation:**
```powershell
# Validate ENVIRONMENT format
if ($env:ENVIRONMENT) {
    if ($env:ENVIRONMENT -notmatch '^[a-z]{3}\d{3}$') {
        Write-Host "⚠️ WARNING: ENVIRONMENT format unusual: $env:ENVIRONMENT" -ForegroundColor Yellow
        Write-Host "   Expected format: 3 letters + 3 digits (e.g., 'gov001')" -ForegroundColor Yellow
        Write-Host "   Continue anyway? (y/N): " -NoNewline
        $confirm = Read-Host
        if ($confirm -ne 'y') {
            throw "Operation cancelled"
        }
    }
}
```

---

### 8. ⚠️ **DryRun Mode Not Enforced at Script Entry Points**

**Problem:**
- DryRun is optional in most scripts
- Easy to forget `-DryRun` flag and run destructive operations

**Recommendation:**
Make scripts require explicit `-Force` flag for real operations:

```powershell
param(
    [switch]$Force,  # Required for actual operations
    [switch]$DryRun  # Default behavior
)

if (-not $Force -and -not $DryRun) {
    $DryRun = $true  # Default to dry-run
    Write-Host "⚠️ Running in DRY RUN mode (default)" -ForegroundColor Yellow
    Write-Host "   Add -Force flag to execute actual operations" -ForegroundColor Yellow
}
```

---

## ✅ POSITIVE FINDINGS (Good Security Practices)

1. ✅ **DryRun mode exists** - Good safety mechanism when used
2. ✅ **Service Principal authentication** - Not using user credentials
3. ✅ **Subscription context validation** - Checks subscription exists
4. ✅ **Detailed logging** - Good audit trail
5. ✅ **Error handling** - Try/catch blocks in critical sections
6. ✅ **Database name filtering** - `Contains("restored")` prevents accidental deletion
7. ✅ **Cloud detection** - Prevents cross-cloud accidents

---

## 🛠️ RECOMMENDED IMMEDIATE ACTIONS

### Priority 1 (Implement Today):
1. **Add production environment blocklist**
2. **Add Source ≠ Destination validation**
3. **Require explicit confirmation for deletions**

### Priority 2 (This Week):
4. **Never delete before successful copy verification**
5. **Add transaction wrappers to SQL DELETE operations**
6. **Make DryRun the default behavior**

### Priority 3 (This Month):
7. **Add ENVIRONMENT format validation**
8. **Reduce parallel operation throttle limits**
9. **Add database backup verification before operations**
10. **Implement "maintenance window" checks**

---

## 📋 SECURITY CHECKLIST FOR NEW SCRIPTS

When adding new scripts, ensure:

- [ ] DryRun mode implemented
- [ ] Production environment blocked
- [ ] Source ≠ Destination validation
- [ ] Explicit confirmation for destructive operations
- [ ] Transaction safety for SQL operations
- [ ] Proper error handling with rollback
- [ ] Logging of all operations
- [ ] Subscription validation
- [ ] Permission checks before operations
- [ ] Backup verification before deletion

---

## 🎯 RISK SUMMARY

| Risk | Severity | Likelihood | Priority |
|------|----------|------------|----------|
| Accidental production operation | Critical | Medium | **P1** |
| Source = Destination overwrite | Critical | Low | **P1** |
| Delete before copy verification | High | Medium | **P1** |
| SQL operations without transactions | High | Low | **P2** |
| Parallel operation race conditions | Medium | Low | **P2** |
| ENVIRONMENT typo/format | Medium | Medium | **P2** |

---

**Reviewed by:** AI Security Audit  
**Next Review:** After implementing P1 fixes

