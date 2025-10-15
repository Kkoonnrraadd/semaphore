# Complete Flow: How ScriptPath Gets Passed

## Step-by-Step Flow

### 1. Template Creation (create-templates-corrected.sh)

```bash
create_template "Task 1: Restore Point in Time" \
    "Restore databases..." \
    "restore/RestorePointInTime.ps1" \     # ← $script_path
    '[
        {"name":"Source",...},
        {"name":"DryRun",...}
    ]'
```

**What happens in `create_template()` function:**

```bash
# Line 747: $script_path = "restore/RestorePointInTime.ps1"
# Line 754: Inject ScriptPath as FIRST parameter
wrapper_survey_vars=$(echo "$survey_vars" | jq --arg path "$script_path" \
    '. = [{"name":"ScriptPath","default_value":$path,"required":true}] + .')
```

**Result - Final survey_vars sent to Semaphore API:**
```json
{
  "survey_vars": [
    {
      "name": "ScriptPath",
      "title": "📁 Script (auto-configured)",
      "description": "✓ Pre-configured script path - no need to modify",
      "default_value": "restore/RestorePointInTime.ps1",  ← Pre-filled!
      "required": true
    },
    {
      "name": "Source",
      "title": "Source Environment (OPTIONAL)",
      ...
    },
    {
      "name": "DryRun",
      ...
    }
  ]
}
```

---

### 2. User Runs Task in Semaphore UI

**User sees form:**
```
┌────────────────────────────────────────────────┐
│ 📁 Script (auto-configured)    [Required]     │
│ ┌──────────────────────────────────────────┐   │
│ │ restore/RestorePointInTime.ps1     ✓    │   │ ← Pre-filled with default_value
│ └──────────────────────────────────────────┘   │
│                                                │
│ Source Environment (OPTIONAL)   [Optional]     │
│ ┌──────────────────────────────────────────┐   │
│ │ gov001                                   │   │ ← User types this
│ └──────────────────────────────────────────┘   │
│                                                │
│ DryRun                         [Required]      │
│ ┌──────────────────────────────────────────┐   │
│ │ true                                     │   │ ← Default
│ └──────────────────────────────────────────┘   │
└────────────────────────────────────────────────┘
```

**User clicks "Run"**

---

### 3. Semaphore Processes Form

Semaphore takes all survey_vars and converts to command-line arguments:

```bash
# Semaphore builds command:
pwsh /tmp/semaphore/.../scripts/step_wrappers/invoke_step.ps1 \
    ScriptPath=restore/RestorePointInTime.ps1 \    ← From default_value
    Source=gov001 \                                 ← From user input
    DryRun=true                                     ← From default/user input
```

---

### 4. invoke_step.ps1 Receives Arguments

```powershell
# $args array contains:
# [0] = "ScriptPath=restore/RestorePointInTime.ps1"
# [1] = "Source=gov001"
# [2] = "DryRun=true"

# Parse arguments
$parsedParams = @{
    "ScriptPath" = "restore/RestorePointInTime.ps1"
    "Source" = "gov001"
    "DryRun" = "true"
}

# Extract ScriptPath
$scriptPath = $parsedParams["ScriptPath"]  # "restore/RestorePointInTime.ps1"
$parsedParams.Remove("ScriptPath")

# Build full path
$fullScriptPath = "/scripts/restore/RestorePointInTime.ps1"

# Convert remaining parameters
$scriptParams = @{
    Source = "gov001"      # String
    DryRun = $true         # Boolean (converted)
}
```

---

### 5. Execute Target Script

```powershell
& /scripts/restore/RestorePointInTime.ps1 @scriptParams

# Equivalent to:
& /scripts/restore/RestorePointInTime.ps1 -Source "gov001" -DryRun:$true
```

---

## Visual Flow Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│  TEMPLATE CREATION (create-templates-corrected.sh)              │
├─────────────────────────────────────────────────────────────────┤
│  create_template(                                               │
│    name = "Task 1: Restore Point in Time"                       │
│    script_path = "restore/RestorePointInTime.ps1"  ← IMPORTANT  │
│    survey_vars = [{"name":"Source",...}]                        │
│  )                                                               │
│                                                                  │
│  Function injects ScriptPath:                                   │
│  survey_vars = [                                                │
│    {"name":"ScriptPath",                                        │
│     "default_value":"restore/RestorePointInTime.ps1"},  ← HERE  │
│    {"name":"Source",...}                                        │
│  ]                                                               │
└──────────────────────────┬──────────────────────────────────────┘
                           │ API POST
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│  SEMAPHORE DATABASE (stores template)                           │
├─────────────────────────────────────────────────────────────────┤
│  Template {                                                     │
│    name: "Task 1: Restore Point in Time"                        │
│    playbook: ".../invoke_step.ps1"                              │
│    survey_vars: [                                               │
│      {                                                           │
│        name: "ScriptPath",                                      │
│        default_value: "restore/RestorePointInTime.ps1"  ← SAVED │
│      },                                                          │
│      { name: "Source", ... },                                   │
│      { name: "DryRun", ... }                                    │
│    ]                                                             │
│  }                                                               │
└──────────────────────────┬──────────────────────────────────────┘
                           │ User clicks task
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│  SEMAPHORE UI (renders form)                                    │
├─────────────────────────────────────────────────────────────────┤
│  FOR EACH survey_var:                                           │
│    Create input field                                           │
│    Pre-fill with default_value                                  │
│                                                                  │
│  ScriptPath field shows: "restore/RestorePointInTime.ps1" ✓     │
│  Source field shows: [empty]                                    │
│  DryRun field shows: "true"                                     │
└──────────────────────────┬──────────────────────────────────────┘
                           │ User fills form, clicks Run
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│  SEMAPHORE EXECUTOR (builds command)                            │
├─────────────────────────────────────────────────────────────────┤
│  command = "pwsh invoke_step.ps1 "                              │
│                                                                  │
│  FOR EACH survey_var WITH value:                                │
│    command += "VarName=Value "                                  │
│                                                                  │
│  Final command:                                                 │
│  pwsh invoke_step.ps1 \                                         │
│    ScriptPath=restore/RestorePointInTime.ps1 \  ← From form     │
│    Source=gov001 \                               ← From form     │
│    DryRun=true                                   ← From form     │
└──────────────────────────┬──────────────────────────────────────┘
                           │ Execute command
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│  invoke_step.ps1 (receives $args)                               │
├─────────────────────────────────────────────────────────────────┤
│  $args = @(                                                     │
│    "ScriptPath=restore/RestorePointInTime.ps1",                 │
│    "Source=gov001",                                             │
│    "DryRun=true"                                                │
│  )                                                               │
│                                                                  │
│  Parse → Extract ScriptPath → Build full path → Execute        │
└──────────────────────────┬──────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│  RestorePointInTime.ps1 (target script)                         │
├─────────────────────────────────────────────────────────────────┤
│  Receives: -Source "gov001" -DryRun:$true                       │
│  Executes business logic                                        │
│  Returns exit code                                              │
└─────────────────────────────────────────────────────────────────┘
```

---

## Key Points

1. **ScriptPath is ALWAYS provided** - It's in the template's survey_vars with a default_value
2. **User sees it pre-filled** - They don't need to type anything
3. **Semaphore sends it automatically** - Even if user doesn't touch it
4. **Wrapper receives it** - As first argument: `ScriptPath=...`
5. **Wrapper uses it** - To find and execute the target script

---

## Testing the Flow

You can verify this works by checking what Semaphore actually sends:

### Method 1: Add debug logging to wrapper

```powershell
# At top of invoke_step.ps1
Write-Host "DEBUG: All arguments received:" -ForegroundColor Magenta
foreach ($arg in $args) {
    Write-Host "  - $arg" -ForegroundColor Magenta
}
```

### Method 2: Check Semaphore task logs

When task runs, Semaphore shows the command it executed:
```
Running: pwsh /tmp/semaphore/.../invoke_step.ps1 ScriptPath=restore/RestorePointInTime.ps1 Source=gov001 ...
```

---

## Summary

**Q: How does ScriptPath get provided if it's not in the original survey_vars?**

**A: The `create_template()` function ADDS it automatically:**

```bash
# Original survey_vars (line 590-597 in create-templates-corrected.sh)
'[
    {"name":"Source",...},
    {"name":"DryRun",...}
]'

# After wrapper_survey_vars transformation (line 754)
[
    {"name":"ScriptPath","default_value":"restore/RestorePointInTime.ps1",...},  ← ADDED
    {"name":"Source",...},
    {"name":"DryRun",...}
]
```

**The jq command on line 754 prepends ScriptPath to the array:**
```bash
'. = [{"name":"ScriptPath",...}] + .'
#    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^   prepend this
#                                  + append original array
```

This is why it works! 🎯

