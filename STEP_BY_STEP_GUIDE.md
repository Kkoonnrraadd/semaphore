# 🎯 Step-by-Step Guide: How the Script Works

## 📝 What You Need to Understand

**Only ONE parameter is required: `CustomerAlias`**  
Everything else is **optional** and will be auto-detected from your Azure environment.

---

## 🔄 Complete Flow Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│ USER INPUT via Semaphore Wrapper                                │
│ Example: -CustomerAlias "test-customer"                         │
│ (Can also provide: Source, Destination, Cloud, etc.)           │
└─────────────────────────────────────────────────────────────────┘
                             ↓
┌─────────────────────────────────────────────────────────────────┐
│ STEP 1: Wrapper Parses Parameters                               │
│ - Converts Semaphore format to PowerShell format                │
│ - Passes ALL parameters (including empty ones) to self_service  │
└─────────────────────────────────────────────────────────────────┘
                             ↓
┌─────────────────────────────────────────────────────────────────┐
│ STEP 2: self_service.ps1 Receives Parameters                    │
│ - Checks: CustomerAlias provided? ✅ Required!                  │
│ - Stores what user provided in $script:Original* variables      │
│   Example:                                                       │
│   - $script:OriginalSource = "" (empty if not provided)         │
│   - $script:OriginalCloud = "" (empty if not provided)          │
└─────────────────────────────────────────────────────────────────┘
                             ↓
┌─────────────────────────────────────────────────────────────────┐
│ STEP 3: Load AutomationUtilities.ps1                            │
│ - Provides logging functions                                    │
│ - Provides datetime handling                                    │
│ - NO Azure connection needed yet                                │
└─────────────────────────────────────────────────────────────────┘
                             ↓
┌─────────────────────────────────────────────────────────────────┐
│ STEP 4: Early Permission Grant (OPTIONAL)                       │
│ Decision Point: Did user provide Source?                        │
│                                                                  │
│ ✅ YES (Source provided)                                         │
│    → Grant permissions NOW using that Source                    │
│    → Set flag: $script:PermissionsGrantedEarly = $true         │
│                                                                  │
│ ❌ NO (Source empty)                                             │
│    → Skip for now                                               │
│    → Will grant permissions later after detection               │
└─────────────────────────────────────────────────────────────────┘
                             ↓
┌─────────────────────────────────────────────────────────────────┐
│ STEP 5: Azure Authentication                                    │
│ Uses environment variables from your pod:                       │
│ - AZURE_CLIENT_ID                                              │
│ - AZURE_CLIENT_SECRET                                          │
│ - AZURE_TENANT_ID                                              │
│ - AZURE_SUBSCRIPTION_ID                                        │
│                                                                  │
│ Question: Which Azure Cloud?                                    │
│ - If user provided Cloud → use it                              │
│ - If empty → Get from Azure CLI context                        │
│ - If still unknown → FAIL (no hardcoded default)               │
└─────────────────────────────────────────────────────────────────┘
                             ↓
┌─────────────────────────────────────────────────────────────────┐
│ STEP 6: Auto-Detect Parameters from Azure                       │
│ NOW we're authenticated, so we can query Azure resources!       │
│                                                                  │
│ Calls: Get-AzureParameters.ps1                                  │
│ This script queries:                                             │
│ - Azure subscription name → extracts Source                     │
│ - Azure Graph (resource tags) → confirms environment            │
│ - Subscription metadata → gets Cloud info                       │
│                                                                  │
│ Returns:                                                         │
│ - Source (detected from subscription)                            │
│ - SourceNamespace (detected from resources or default)          │
│ - Destination (detected or same as Source)                      │
│ - DestinationNamespace (detected from resources or default)     │
│ - Cloud (detected from Azure context)                           │
│ - DefaultTimezone (from env var SEMAPHORE_SCHEDULE_TIMEZONE)    │
│ - DefaultRestoreDateTime (calculated: 5 min ago in timezone)    │
└─────────────────────────────────────────────────────────────────┘
                             ↓
┌─────────────────────────────────────────────────────────────────┐
│ STEP 7: Merge User Input with Auto-Detected Values              │
│ Logic: User input ALWAYS wins if provided                       │
│                                                                  │
│ For each parameter:                                              │
│   IF user provided value (not empty):                           │
│     → Use user's value                                          │
│   ELSE:                                                          │
│     → Use auto-detected value                                   │
│                                                                  │
│ Example:                                                         │
│   User provided: Source="gov001", Destination=""                │
│   Auto-detected: Source="wus018", Destination="wus018"          │
│   Final result: Source="gov001", Destination="wus018"           │
└─────────────────────────────────────────────────────────────────┘
                             ↓
┌─────────────────────────────────────────────────────────────────┐
│ STEP 8: Late Permission Grant (if needed)                       │
│ Decision Point: Were permissions granted early?                 │
│                                                                  │
│ ✅ YES ($script:PermissionsGrantedEarly = $true)                │
│    → Skip, already done                                         │
│                                                                  │
│ ❌ NO (permissions not granted yet)                              │
│    → NOW we know Source (from auto-detection)                   │
│    → Grant permissions using detected Source                    │
└─────────────────────────────────────────────────────────────────┘
                             ↓
┌─────────────────────────────────────────────────────────────────┐
│ STEP 9: Display Final Parameters                                │
│ Shows what will be used for the migration:                      │
│ - Source / SourceNamespace                                      │
│ - Destination / DestinationNamespace                            │
│ - Cloud                                                          │
│ - CustomerAlias                                                  │
│ - CustomerAliasToRemove                                          │
│ - RestoreDateTime / Timezone                                     │
└─────────────────────────────────────────────────────────────────┘
                             ↓
┌─────────────────────────────────────────────────────────────────┐
│ STEP 10: Run Migration (Steps 1-12)                             │
│ Now execute the actual data refresh with finalized parameters   │
└─────────────────────────────────────────────────────────────────┘
```

---

## 🎬 Real Examples

### Example 1: User Provides NOTHING (except CustomerAlias)

```powershell
# User input
CustomerAlias = "test-customer"
Source = ""
Destination = ""
Cloud = ""
# ... everything else empty
```

**What Happens:**

1. ✅ **Step 1-3**: Wrapper passes empty strings, script loads utilities
2. ⏭️ **Step 4**: Skip early permissions (no Source)
3. ✅ **Step 5**: Authenticate to Azure
   - Check Cloud: empty → Query Azure CLI → Detects "AzureUSGovernment"
4. ✅ **Step 6**: Auto-detect from Azure
   - Query subscription name: "MyCompany_gov001" → Extract "gov001"
   - Query resources: Find namespace "manufacturo"
   - Set Destination = Source = "gov001" (same)
   - Set DestinationNamespace = "test" (default)
5. ✅ **Step 7**: Merge values
   - Source = "gov001" (detected)
   - Destination = "gov001" (detected)
   - Cloud = "AzureUSGovernment" (detected)
6. ✅ **Step 8**: Grant permissions NOW (using detected Source "gov001")
7. ✅ **Step 9**: Display: gov001/manufacturo → gov001/test
8. ✅ **Step 10**: Run migration!

---

### Example 2: User Provides Source Only

```powershell
# User input
CustomerAlias = "test-customer"
Source = "wus018"
Destination = ""
Cloud = ""
# ... everything else empty
```

**What Happens:**

1. ✅ **Step 1-3**: Wrapper passes values, script loads utilities
2. ✅ **Step 4**: Grant permissions EARLY (Source="wus018" provided)
3. ✅ **Step 5**: Authenticate to Azure
   - Check Cloud: empty → Query Azure CLI → Detects cloud
4. ✅ **Step 6**: Auto-detect from Azure
   - Source already provided, skip detection
   - Query resources: Find namespaces
   - Set Destination = "wus018" (same as Source)
5. ✅ **Step 7**: Merge values
   - Source = "wus018" (user provided - WINS!)
   - Destination = "wus018" (detected)
   - Cloud = detected value
6. ⏭️ **Step 8**: Skip (permissions already granted)
7. ✅ **Step 9**: Display: wus018/manufacturo → wus018/test
8. ✅ **Step 10**: Run migration!

---

### Example 3: User Provides Everything

```powershell
# User input
CustomerAlias = "test-customer"
Source = "gov001"
Destination = "dev"
SourceNamespace = "manufacturo"
DestinationNamespace = "customer-test"
Cloud = "AzureUSGovernment"
```

**What Happens:**

1. ✅ **Step 1-3**: Wrapper passes all values
2. ✅ **Step 4**: Grant permissions EARLY (Source provided)
3. ✅ **Step 5**: Authenticate to Azure (Cloud provided)
4. ✅ **Step 6**: Auto-detect runs but finds all values provided
5. ✅ **Step 7**: Merge values - ALL user values win!
   - Source = "gov001" (user)
   - Destination = "dev" (user)
   - SourceNamespace = "manufacturo" (user)
   - DestinationNamespace = "customer-test" (user)
   - Cloud = "AzureUSGovernment" (user)
6. ⏭️ **Step 8**: Skip (permissions already granted)
7. ✅ **Step 9**: Display: gov001/manufacturo → dev/customer-test
8. ✅ **Step 10**: Run migration!

---

## ⚠️ Current Issue: Hardcoded Default

**Location:** Line 199 in `self_service.ps1`

```powershell
# CURRENT (has hardcoded default):
$authCloud = if (-not [string]::IsNullOrWhiteSpace($script:OriginalCloud)) {
    $script:OriginalCloud
} else {
    "AzureUSGovernment"  # ← HARDCODED!
}
```

**Problem:** If user doesn't provide Cloud, it defaults to "AzureUSGovernment" instead of detecting from Azure.

**Solution:** Query Azure CLI for the current cloud context instead.

---

## ✅ What Should Happen (No Hardcoded Values)

**For Cloud parameter:**
1. User provided Cloud? → Use it
2. User didn't provide? → Query Azure CLI context
3. Still can't determine? → Fail with clear error message

**For Source parameter:**
1. User provided Source? → Use it
2. User didn't provide? → Query Azure subscription name
3. Still can't determine? → Fail with clear error message

**For Namespaces:**
1. User provided? → Use it (always wins)
2. User didn't provide? → Query Azure resource tags
3. Still can't determine? → Use organizational defaults:
   - SourceNamespace: `"manufacturo"` (your standard)
   - DestinationNamespace: `"test"` (your standard)

---

## 🎯 Summary

| Parameter | User Provides | Auto-Detection Method | Fallback |
|-----------|---------------|----------------------|----------|
| CustomerAlias | ✅ REQUIRED | N/A | FAIL if missing |
| Source | Optional | Azure subscription name pattern | FAIL if can't detect |
| Destination | Optional | Same as Source | Same as Source |
| SourceNamespace | Optional | Azure resource tags | "manufacturo" (org standard) |
| DestinationNamespace | Optional | Azure resource tags | "test" (org standard) |
| Cloud | Optional | Azure CLI context | FAIL if can't detect |
| RestoreDateTime | Optional | 5 minutes ago | Calculated |
| Timezone | Optional | SEMAPHORE_SCHEDULE_TIMEZONE env var | FAIL if missing |

**Key Point:** Priority order is:
- ✅ 1st: Use user input (always wins)
- ✅ 2nd: Auto-detect from Azure
- ✅ 3rd: Use organizational defaults (namespaces only: manufacturo/test)
- ❌ 4th: Fail with clear error message (for critical params like Source, Cloud)

---

## 🔧 Next Steps

Remove the hardcoded "AzureUSGovernment" and make it query Azure CLI instead!

