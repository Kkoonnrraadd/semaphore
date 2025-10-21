# Parameter Flow Diagram: UseSasTokens

## Before Fix (BROKEN) ❌

```
┌─────────────────────────────────────────────────────────────────┐
│ Semaphore UI / Command Line                                     │
│ Command: DryRun=false UseSasTokens=true production_confirm=oki  │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│ semaphore_wrapper.ps1                                           │
│                                                                  │
│ ✅ STEP 1: Parse-Arguments (Line 49-95)                         │
│    Input: "UseSasTokens=true"                                   │
│    Output: $parsedParams["UseSasTokens"] = "true"               │
│    Status: ✅ WORKING                                           │
│                                                                  │
│ ❌ STEP 2: Extract to Variable (Line 104-123)                   │
│    Expected: $UseSasTokens = $true                              │
│    Actual: ❌ MISSING - Variable never created                  │
│    Status: ❌ BROKEN                                            │
│                                                                  │
│ ❌ STEP 3: Add to scriptParams (Line 343-369)                   │
│    Expected: $scriptParams['UseSasTokens'] = $true              │
│    Actual: ❌ MISSING - Never added to hashtable                │
│    Status: ❌ BROKEN                                            │
│                                                                  │
│ Result: & self_service.ps1 @scriptParams                        │
│         (UseSasTokens NOT in hashtable)                         │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│ self_service.ps1                                                │
│                                                                  │
│ param([switch]$UseSasTokens=$false)                             │
│                                                                  │
│ Received: ❌ Nothing (parameter not passed)                     │
│ Default: $UseSasTokens = $false                                 │
│ Status: Uses default value ❌                                   │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│ CopyAttachments.ps1                                             │
│                                                                  │
│ Received: $UseSasTokens = $false ❌                             │
│                                                                  │
│ Output:                                                          │
│   UseSasTokens: False (Type: SwitchParameter)                   │
│   ℹ️  SAS Token mode is DISABLED (default)                     │
│                                                                  │
│ Result: ❌ Uses Azure CLI auth (token expires after 1 hour)    │
│         ⚠️  Token refresh failed                                │
│         ❌ Large blob copies fail                               │
└─────────────────────────────────────────────────────────────────┘
```

---

## After Fix (WORKING) ✅

```
┌─────────────────────────────────────────────────────────────────┐
│ Semaphore UI / Command Line                                     │
│ Command: DryRun=false UseSasTokens=true production_confirm=oki  │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│ semaphore_wrapper.ps1                                           │
│                                                                  │
│ ✅ STEP 1: Parse-Arguments (Line 49-95)                         │
│    Input: "UseSasTokens=true"                                   │
│    Output: $parsedParams["UseSasTokens"] = "true"               │
│    Status: ✅ WORKING                                           │
│                                                                  │
│ ✅ STEP 2: Extract to Variable (Line 123-129) 🆕 FIXED          │
│    Code:                                                         │
│      $UseSasTokens = if ($parsedParams.ContainsKey(...)) {      │
│        $useSasValue = $parsedParams["UseSasTokens"]             │
│        if ($useSasValue -eq "true") { $true } else { $false }   │
│      } else { $false }                                           │
│    Result: $UseSasTokens = $true ✅                             │
│    Status: ✅ FIXED                                             │
│                                                                  │
│ ✅ STEP 3: Add to scriptParams (Line 377) 🆕 FIXED              │
│    Code:                                                         │
│      $scriptParams['UseSasTokens'] = $UseSasTokens              │
│    Result: Hashtable now contains UseSasTokens = $true ✅       │
│    Status: ✅ FIXED                                             │
│                                                                  │
│ Result: & self_service.ps1 @scriptParams                        │
│         (UseSasTokens = $true in hashtable) ✅                  │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│ self_service.ps1                                                │
│                                                                  │
│ param([switch]$UseSasTokens=$false)                             │
│                                                                  │
│ Received: ✅ $UseSasTokens = $true (from splatting)             │
│ Status: Uses passed value ✅                                    │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│ CopyAttachments.ps1                                             │
│                                                                  │
│ Received: $UseSasTokens = $true ✅                              │
│                                                                  │
│ Output:                                                          │
│   UseSasTokens: True (Type: SwitchParameter)                    │
│   ⚠️  SAS Token mode is ENABLED                                │
│   🔐 Generating SAS tokens (valid for 8 hours)...              │
│                                                                  │
│ Result: ✅ Uses SAS tokens (valid for 8 hours)                 │
│         ✅ No token expiration during long copies               │
│         ✅ Large blob copies succeed                            │
└─────────────────────────────────────────────────────────────────┘
```

---

## Comparison: invoke_step.ps1 (Always Worked) ✅

```
┌─────────────────────────────────────────────────────────────────┐
│ Semaphore UI / Command Line                                     │
│ Command: ScriptPath=storage/CopyAttachments.ps1 UseSasTokens=true│
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│ invoke_step.ps1                                                 │
│                                                                  │
│ ✅ STEP 1: Parse-SemaphoreArguments (Line 23-50)                │
│    Input: "UseSasTokens=true"                                   │
│    Output: $parsedParams["UseSasTokens"] = "true"               │
│    Status: ✅ WORKING                                           │
│                                                                  │
│ ✅ STEP 2: Convert-ToBoolean (Line 56-70)                       │
│    Code:                                                         │
│      if ($knownSwitchParams -contains "UseSasTokens") {         │
│        $boolValue = Convert-ToBoolean -Value "true"             │
│        if ($boolValue) {                                         │
│          $scriptParams["UseSasTokens"] = $true                  │
│        }                                                          │
│      }                                                            │
│    Result: $scriptParams["UseSasTokens"] = $true ✅             │
│    Status: ✅ WORKING                                           │
│                                                                  │
│ Result: & CopyAttachments.ps1 @scriptParams                     │
│         (UseSasTokens = $true in hashtable) ✅                  │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│ CopyAttachments.ps1                                             │
│                                                                  │
│ Received: $UseSasTokens = $true ✅                              │
│ Status: ✅ Always worked via invoke_step.ps1                    │
└─────────────────────────────────────────────────────────────────┘
```

---

## Key Differences

### semaphore_wrapper.ps1 (Before Fix)
- ❌ No variable extraction
- ❌ No hashtable addition
- ❌ Parameter lost in translation

### semaphore_wrapper.ps1 (After Fix)
- ✅ Variable extraction (line 123-129)
- ✅ Hashtable addition (line 377)
- ✅ Parameter correctly forwarded

### invoke_step.ps1 (Always Worked)
- ✅ Proper switch parameter handling
- ✅ Convert-ToBoolean helper function
- ✅ Known switch parameters list

---

## PowerShell Splatting Explained

### What is Splatting?

Splatting is passing a hashtable of parameters to a function:

```powershell
# Without splatting (verbose)
& script.ps1 -Param1 "value1" -Param2 "value2" -Switch1

# With splatting (clean)
$params = @{
    Param1 = "value1"
    Param2 = "value2"
    Switch1 = $true
}
& script.ps1 @params  # Note the @ instead of $
```

### Why It Matters

If a parameter is **not in the hashtable**, it's **not passed** to the script:

```powershell
# Before fix
$scriptParams = @{
    DryRun = $true
    # UseSasTokens missing! ❌
}
& self_service.ps1 @scriptParams
# Result: UseSasTokens uses default value ($false)

# After fix
$scriptParams = @{
    DryRun = $true
    UseSasTokens = $true  # ✅ Now included
}
& self_service.ps1 @scriptParams
# Result: UseSasTokens = $true
```

---

## Summary

### The Bug
Parameter was parsed but never forwarded → Script used default value

### The Fix
Added two lines of code to extract and forward the parameter

### The Impact
Large blob copies now work reliably with SAS tokens (8-hour validity)

