# Production-Ready Database Scripts

## 🎯 Philosophy: Zero Tolerance for Errors

These scripts are designed for **production operations** where **there is NO room for errors**.

### Key Principle:
> **Any error = immediate stop with exit code 1**

No warnings. No "continuing with remaining databases". No optional parameters to enable safety.

**Safety is ALWAYS ON.**

---

## ✅ What This Means

### **Restore Operations**
```
Processing 5 databases...

✅ Database 1: Success
✅ Database 2: Success
❌ Database 3: FAILED!

🛑 STOPPING EXECUTION - Fix the error and retry
exit 1  ← STOPS IMMEDIATELY
```

**Remaining databases 4 and 5 are NOT processed.**

---

### **Copy Operations**
```
Processing 5 databases...

✅ Database 1: Success  
❌ Database 2: FAILED!

🛑 STOPPING EXECUTION - Fix the error and retry
exit 1  ← STOPS IMMEDIATELY
```

**Remaining databases 3, 4, and 5 are NOT processed.**

---

## 🚨 Error Handling

When ANY error occurs:

1. **❌ Shows CRITICAL ERROR** with full details
2. **📋 Shows error phase** (initiation, waiting, etc.)
3. **🛑 STOPS IMMEDIATELY** with exit code 1
4. **💡 Tells you to fix and retry**

**No ambiguity. No continuing. Just stop.**

---

## 📋 Available Parameters

### RestorePointInTime.ps1
```powershell
param (
    [Parameter(Mandatory)][string]$source,
    [AllowEmptyString()][string]$SourceNamespace,
    [Parameter(Mandatory)][string]$RestoreDateTime,
    [Parameter(Mandatory)][string]$Timezone,
    [switch]$DryRun,
    [int]$MaxWaitMinutes = 60
)
```

**That's it.** No verbose logging. No fail-fast toggle. Just what you need.

---

### copy_database.ps1
```powershell
param (
    [Parameter(Mandatory)][string]$source,
    [Parameter(Mandatory)][string]$destination,
    [Parameter(Mandatory)][string]$SourceNamespace, 
    [Parameter(Mandatory)][string]$DestinationNamespace,
    [switch]$DryRun
)
```

**That's it.** Clean and simple.

---

## 🎯 Usage Examples

### Restore Databases
```powershell
# Normal execution
./RestorePointInTime.ps1 \
    -source "gov001" \
    -SourceNamespace "manufacturo" \
    -RestoreDateTime "2025-10-11 14:30:00" \
    -Timezone "America/New_York"

# Dry run first (recommended)
./RestorePointInTime.ps1 \
    -source "gov001" \
    -SourceNamespace "manufacturo" \
    -RestoreDateTime "2025-10-11 14:30:00" \
    -Timezone "America/New_York" \
    -DryRun
```

**If ANY database fails:** Script stops immediately with exit code 1.

---

### Copy Databases
```powershell
# Normal execution
./copy_database.ps1 \
    -source "dev" \
    -destination "prod" \
    -SourceNamespace "manufacturo" \
    -DestinationNamespace "test"

# Dry run first (recommended)
./copy_database.ps1 \
    -source "dev" \
    -destination "prod" \
    -SourceNamespace "manufacturo" \
    -DestinationNamespace "test" \
    -DryRun
```

**If ANY database fails:** Script stops immediately with exit code 1.

---

## 💡 Best Practices

### ✅ **ALWAYS Start with Dry Run**

```powershell
# Step 1: Preview what will happen
./copy_database.ps1 ... -DryRun

# Step 2: Review the output
# - How many databases will be copied?
# - Are the names correct?
# - Do tags exist?

# Step 3: Run for real
./copy_database.ps1 ...
```

---

### ✅ **Check Exit Codes in Automation**

```bash
#!/bin/bash

# Run restore
./RestorePointInTime.ps1 -source "dev" ...

# Check result
if [ $? -ne 0 ]; then
    echo "❌ Restore failed - stopping workflow"
    exit 1
fi

# Continue with next step only if successful
./copy_database.ps1 -source "dev" ...
```

---

### ✅ **Monitor the Output**

The scripts show clear progress:

```
📋 Copying from db-source to db-dest
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  🗑️  Deleting existing database: db-dest
  ✅ Deleted existing database
  🔄 Initiating database copy...
  ✅ Copy command executed successfully (attempt 1)
  ⏳ Waiting for database to come online...
  ⏳ Still copying... (2.0 min elapsed)
  ✅ Database is ONLINE (took 3.2 minutes)
  🏷️  Restoring tags...
  🏷️  Restored tags to db-dest: Environment=prod, Service=api
```

**If anything goes wrong, you'll know immediately.**

---

## 🔧 Error Messages

### Example: Restore Initiation Failure

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
📋 Restoring: db-api-service-dev
   Target: db-api-service-dev-restored
   Restore Point: 2025-10-11 14:30:00 (America/New_York)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  🔄 Initiating restore operation...
  ❌ Failed to initiate restore

❌ CRITICAL ERROR: Restore failed for db-api-service-dev-restored
   Phase: initiation
   Error: Failed to initiate restore operation

🛑 STOPPING EXECUTION - Fix the error and retry
```

**Script exits with code 1. No more processing.**

---

### Example: Copy Timeout Failure

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
📋 Copying from db-source to db-dest
   Target: db-dest
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  🗑️  Deleting existing database: db-dest
  ✅ Deleted existing database
  🔄 Initiating database copy...
  ✅ Copy command executed successfully (attempt 1)
  ⏳ Waiting for database to come online...
  ⏳ Still copying... (2.0 min elapsed)
  ⏳ Still copying... (4.0 min elapsed)
  ...
  ❌ Timeout: Database failed to come online (15.0 min)

❌ CRITICAL ERROR: Copy failed for db-dest
   Phase: waiting_online
   Error: Timeout

🛑 STOPPING EXECUTION - Fix the error and retry
```

**Script exits with code 1. No more processing.**

---

## 🚀 Exit Codes for Automation

| Scenario | Exit Code | Automation Action |
|----------|-----------|-------------------|
| **All operations successful** | `0` | ✅ Continue to next step |
| **Any operation failed** | `1` | ❌ Stop workflow immediately |
| **Pre-flight check failed** | `1` | ❌ Don't even start |
| **Permission error** | `1` | ❌ Fix permissions |

**Simple rule:** Exit code 0 = success, anything else = failure.

---

## 📊 Real-World Workflow

### Complete Database Refresh

```bash
#!/bin/bash
set -e  # Stop on any error

echo "Step 1: Restore databases to point in time"
./RestorePointInTime.ps1 \
    -source "gov001" \
    -SourceNamespace "manufacturo" \
    -RestoreDateTime "2025-10-11 14:30:00" \
    -Timezone "America/New_York"
# Exits with 1 if ANY database fails to restore

echo "Step 2: Copy databases to destination"
./copy_database.ps1 \
    -source "gov001" \
    -destination "gov001" \
    -SourceNamespace "manufacturo" \
    -DestinationNamespace "test"
# Exits with 1 if ANY database fails to copy

echo "Step 3: Start environment"
./StartEnvironment.ps1 -source "gov001" -sourceNamespace "test"

echo "✅ All steps completed successfully!"
```

**If ANY step fails at ANY point, the entire workflow stops immediately.**

---

## 🎯 Why This Approach?

### ❌ **What We Don't Want:**
```
Processing 10 databases...
✅ Success: 8
❌ Failed: 2

exit 1  ← But 8 databases were modified!
```

**Problem:** Partial success creates inconsistent state. Which databases were copied? Which failed? Do you retry all or just the failed ones?

### ✅ **What We Have Now:**
```
Processing 10 databases...
✅ Success: 3
❌ Failed: 1

🛑 STOPPING - Fix and retry
exit 1  ← Clear state: 3 succeeded, need to retry
```

**Solution:** All-or-nothing. Either everything succeeds, or you fix the error and retry the whole operation.

---

## 🔐 Security & Reliability

### **Pre-Flight Checks**
Before starting ANY operations:
- ✅ Check Azure authentication
- ✅ Check database permissions
- ✅ Check server connectivity
- ✅ Validate parameters

**If ANY check fails: exit 1 before touching any databases.**

### **Fail-Fast by Default**
- ✅ No "continue on error" mode
- ✅ No "best effort" mode
- ✅ No optional safety toggles

**Production operations require 100% success rate.**

---

## 📝 Summary

| Aspect | Implementation |
|--------|----------------|
| **Error Tolerance** | ❌ **ZERO** |
| **Stop on First Error** | ✅ **ALWAYS** |
| **Continue on Error** | ❌ **NEVER** |
| **Exit Code on Error** | **1** (immediately) |
| **Exit Code on Success** | **0** |
| **Optional Safety Flags** | ❌ **NONE** |
| **Verbose Logging** | ❌ **REMOVED** |
| **Fail-Fast Parameter** | ❌ **REMOVED** (always on) |

---

## 🎉 Result

**Simple. Secure. Reliable.**

- No confusing parameters
- No optional safety modes
- No ambiguous behavior
- Just: **Success (0)** or **Failure (1)**

**If it fails, it stops. Period.**

---

*Last Updated: 2025-10-11*  
*Philosophy: Production-grade operations require zero error tolerance*

