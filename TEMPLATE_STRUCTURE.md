# Semaphore Template Structure

## Visual Overview

```
┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
┃                         PROJEKT (Project)                             ┃
┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛
                                    │
                ┌───────────────────┴───────────────────┐
                │                                       │
                ▼                                       ▼
    ┏━━━━━━━━━━━━━━━━━━━━━━━━┓           ┏━━━━━━━━━━━━━━━━━━━━━━━━┓
    ┃   WIDOK (View 1)       ┃           ┃   TASKI (View 2)       ┃
    ┃   Main Workflows       ┃           ┃   Individual Steps     ┃
    ┗━━━━━━━━━━━━━━━━━━━━━━━━┛           ┗━━━━━━━━━━━━━━━━━━━━━━━━┛
            │                                       │
            │                                       │
    ┌───────┴────────┐                 ┌────────────┼─────────────┐
    │                │                 │            │             │
    ▼                ▼                 ▼            ▼             ▼
┌─────────┐    ┌──────────┐      ┌────────┐  ┌────────┐   ┌────────┐
│DRY RUN  │    │PRODUCTION│      │Task 1  │  │Task 2  │...│Task 12 │
│         │    │          │      │Restore │  │Stop    │   │Remove  │
│DryRun=  │    │DryRun=   │      │Point   │  │Env     │   │Perms   │
│true     │    │false +   │      │in Time │  │        │   │        │
│         │    │CONFIRM   │      │        │  │        │   │        │
└─────────┘    └──────────┘      └────────┘  └────────┘   └────────┘
```

## Parameter Flow Diagram

```
┌────────────────────────────────────────────────────────────────────┐
│                    SEMAPHORE UI (User Input)                       │
│  User fills form with parameters (or leaves empty)                 │
└────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌────────────────────────────────────────────────────────────────────┐
│              semaphore_wrapper.ps1 (Parameter Parser)              │
│  • Parses Semaphore's parameter format (Key=Value)                 │
│  • Normalizes datetime (multiple formats → yyyy-MM-dd HH:mm:ss)    │
│  • Validates timezone (env var or user input)                      │
│  • Converts types (string→boolean, string→integer)                 │
│  • Maps to self_service.ps1 parameter names                        │
└────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌────────────────────────────────────────────────────────────────────┐
│           self_service.ps1 (Auto-Detection & Orchestration)        │
│  • Checks each parameter: provided? → use it ✅                    │
│  •                        empty?    → auto-detect 🔍               │
│  • Queries Azure for missing values                                │
│  • Applies defaults if still empty                                 │
│  • Orchestrates 12 steps in sequence                               │
└────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌────────────────────────────────────────────────────────────────────┐
│                    12 PowerShell Scripts                            │
│  1. RestorePointInTime.ps1                                         │
│  2. StopEnvironment.ps1                                            │
│  3. CopyAttachments.ps1                                            │
│  4. copy_database.ps1                                              │
│  5. cleanup_environment_config.ps1                                 │
│  6. sql_configure_users.ps1 (Revert mode)                          │
│  7. adjust_db.ps1                                                  │
│  8. delete_replicas.ps1                                            │
│  9. sql_configure_users.ps1                                        │
│ 10. StartEnvironment.ps1                                           │
│ 11. delete_restored_db.ps1                                         │
│ 12. Invoke-AzureFunctionPermission.ps1 (Remove)                    │
└────────────────────────────────────────────────────────────────────┘
```

## Template Details

### WIDOK Templates (Main Workflows)

#### 1. Self-Service Data Refresh - DRY RUN

```yaml
Name: "Self-Service Data Refresh - DRY RUN"
Description: "Preview what the data refresh would do (SAFE - no changes made)"
Script: /tmp/semaphore/.../scripts/main/semaphore_wrapper.ps1
App: powershell
DryRun: true (fixed)

Parameters (11 total, all OPTIONAL):
  ┌─────────────────────────────────────────────────────────────────┐
  │ RestoreDateTime     │ OPTIONAL │ Auto: 15 min ago              │
  │ Timezone            │ OPTIONAL │ Auto: system timezone         │
  │ SourceNamespace     │ OPTIONAL │ Auto: "manufacturo"           │
  │ Source              │ OPTIONAL │ Auto: from Azure              │
  │ DestinationNamespace│ OPTIONAL │ Auto: "test"                  │
  │ Destination         │ OPTIONAL │ Auto: same as Source          │
  │ CustomerAlias       │ OPTIONAL │ Auto: INSTANCE_ALIAS env var  │
  │ CustomerAliasToRemove│OPTIONAL │ Auto: calculated              │
  │ Cloud               │ OPTIONAL │ Auto: from Azure CLI          │
  │ DryRun              │ REQUIRED │ Fixed: true                   │
  │ MaxWaitMinutes      │ OPTIONAL │ Auto: 60                      │
  └─────────────────────────────────────────────────────────────────┘
```

#### 2. Self-Service Data Refresh - PRODUCTION

```yaml
Name: "Self-Service Data Refresh - PRODUCTION"
Description: "⚠️ PRODUCTION MODE - Execute actual data refresh operations"
Script: /tmp/semaphore/.../scripts/main/semaphore_wrapper.ps1
App: powershell
DryRun: false

Parameters (12 total, all OPTIONAL except production_confirm):
  ┌─────────────────────────────────────────────────────────────────┐
  │ RestoreDateTime     │ OPTIONAL │ Auto: 15 min ago              │
  │ Timezone            │ OPTIONAL │ Auto: system timezone         │
  │ SourceNamespace     │ OPTIONAL │ Auto: "manufacturo"           │
  │ Source              │ OPTIONAL │ Auto: from Azure              │
  │ DestinationNamespace│ OPTIONAL │ Auto: "test"                  │
  │ Destination         │ OPTIONAL │ Auto: same as Source          │
  │ CustomerAlias       │ OPTIONAL │ Auto: INSTANCE_ALIAS env var  │
  │ CustomerAliasToRemove│OPTIONAL │ Auto: calculated              │
  │ Cloud               │ OPTIONAL │ Auto: from Azure CLI          │
  │ DryRun              │ REQUIRED │ Fixed: false                  │
  │ MaxWaitMinutes      │ OPTIONAL │ Auto: 60                      │
  │ production_confirm  │ REQUIRED │ Must type "CONFIRM"           │
  └─────────────────────────────────────────────────────────────────┘
```

### TASKI Templates (Individual Steps)

Each of the 12 steps is available as a standalone template:

```
┌────────────────────────────────────────────────────────────────────┐
│ Task 1: Restore Point in Time                                     │
├────────────────────────────────────────────────────────────────────┤
│ Script: restore/RestorePointInTime.ps1                            │
│ Parameters: RestoreDateTime, Timezone, Source, SourceNamespace,   │
│            MaxWaitMinutes, DryRun                                  │
│ Purpose: Restore databases to specific point in time              │
└────────────────────────────────────────────────────────────────────┘

┌────────────────────────────────────────────────────────────────────┐
│ Task 2: Stop Environment                                          │
├────────────────────────────────────────────────────────────────────┤
│ Script: environment/StopEnvironment.ps1                           │
│ Parameters: Destination, DestinationNamespace, Cloud, DryRun      │
│ Purpose: Stop AKS cluster and monitoring                          │
└────────────────────────────────────────────────────────────────────┘

┌────────────────────────────────────────────────────────────────────┐
│ Task 3: Copy Attachments                                          │
├────────────────────────────────────────────────────────────────────┤
│ Script: storage/CopyAttachments.ps1                               │
│ Parameters: Source, Destination, SourceNamespace,                 │
│            DestinationNamespace, DryRun                            │
│ Purpose: Copy attachments between storage accounts                │
└────────────────────────────────────────────────────────────────────┘

┌────────────────────────────────────────────────────────────────────┐
│ Task 4: Copy Database                                             │
├────────────────────────────────────────────────────────────────────┤
│ Script: database/copy_database.ps1                                │
│ Parameters: Source, Destination, SourceNamespace,                 │
│            DestinationNamespace, DryRun                            │
│ Purpose: Copy database from source to destination                 │
└────────────────────────────────────────────────────────────────────┘

┌────────────────────────────────────────────────────────────────────┐
│ Task 5: Cleanup Environment Configuration                         │
├────────────────────────────────────────────────────────────────────┤
│ Script: configuration/cleanup_environment_config.ps1              │
│ Parameters: Destination, EnvironmentToClean, MultitenantToRemove, │
│            CustomerAliasToRemove, Domain, DestinationNamespace,   │
│            DryRun                                                  │
│ Purpose: Remove CORS origins and redirect URIs                    │
└────────────────────────────────────────────────────────────────────┘

┌────────────────────────────────────────────────────────────────────┐
│ Task 6: Revert SQL Users                                          │
├────────────────────────────────────────────────────────────────────┤
│ Script: configuration/sql_configure_users.ps1 (Revert mode)       │
│ Parameters: Destination, DestinationNamespace, EnvironmentToRevert│
│            MultitenantToRevert, Revert=true, AutoApprove=true,    │
│            StopOnFailure=true, DryRun                              │
│ Purpose: Revert source environment SQL users and roles            │
└────────────────────────────────────────────────────────────────────┘

┌────────────────────────────────────────────────────────────────────┐
│ Task 7: Adjust Database Resources                                 │
├────────────────────────────────────────────────────────────────────┤
│ Script: configuration/adjust_db.ps1                               │
│ Parameters: Domain, CustomerAlias, Destination,                   │
│            DestinationNamespace, DryRun                            │
│ Purpose: Adjust database resources and configurations             │
└────────────────────────────────────────────────────────────────────┘

┌────────────────────────────────────────────────────────────────────┐
│ Task 8: Delete and Recreate Replicas                              │
├────────────────────────────────────────────────────────────────────┤
│ Script: replicas/delete_replicas.ps1                              │
│ Parameters: Destination, Source, SourceNamespace,                 │
│            DestinationNamespace, DryRun                            │
│ Purpose: Delete and recreate replica databases                    │
└────────────────────────────────────────────────────────────────────┘

┌────────────────────────────────────────────────────────────────────┐
│ Task 9: Configure SQL Users                                       │
├────────────────────────────────────────────────────────────────────┤
│ Script: configuration/sql_configure_users.ps1                     │
│ Parameters: Destination, DestinationNamespace, AutoApprove=true,  │
│            StopOnFailure=true, BaselinesMode=Off, DryRun          │
│ Purpose: Configure SQL users and permissions                      │
└────────────────────────────────────────────────────────────────────┘

┌────────────────────────────────────────────────────────────────────┐
│ Task 10: Start Environment                                        │
├────────────────────────────────────────────────────────────────────┤
│ Script: environment/StartEnvironment.ps1                          │
│ Parameters: Destination, DestinationNamespace, DryRun             │
│ Purpose: Start AKS cluster and monitoring                         │
└────────────────────────────────────────────────────────────────────┘

┌────────────────────────────────────────────────────────────────────┐
│ Task 11: Cleanup Restored Databases                               │
├────────────────────────────────────────────────────────────────────┤
│ Script: database/delete_restored_db.ps1                           │
│ Parameters: Source, DryRun                                        │
│ Purpose: Delete temporary restored databases                      │
└────────────────────────────────────────────────────────────────────┘

┌────────────────────────────────────────────────────────────────────┐
│ Task 12: Remove Permissions                                       │
├────────────────────────────────────────────────────────────────────┤
│ Script: permissions/Invoke-AzureFunctionPermission.ps1            │
│ Parameters: Source, Action=Remove, ServiceAccount=SelfServiceRefresh│
│            TimeoutSeconds=60, WaitForPropagation=30               │
│ Purpose: Remove SelfServiceRefresh service account permissions    │
└────────────────────────────────────────────────────────────────────┘
```

## Auto-Detection Logic

```
┌─────────────────────────────────────────────────────────────────────┐
│                      Parameter Decision Tree                        │
└─────────────────────────────────────────────────────────────────────┘

For each parameter:

    User provided value?
           │
           ├─ YES ──→ ✅ Use user value (highest priority)
           │
           └─ NO ──→ Check environment variable?
                      │
                      ├─ Found ──→ ✅ Use env var value
                      │
                      └─ Not found ──→ Query Azure?
                                        │
                                        ├─ Found ──→ ✅ Use Azure value
                                        │
                                        └─ Not found ──→ 📋 Use default

Example for "Source" parameter:
    1. User provided "gov001"? → Use "gov001" ✅
    2. User empty → Check ENVIRONMENT var → "gov001"? → Use "gov001" ✅
    3. Still empty → Query Azure subscription → found "gov001"? → Use "gov001" ✅
    4. Still empty → Use default (null or error)

Example for "SourceNamespace" parameter:
    1. User provided "manufacturo"? → Use "manufacturo" ✅
    2. User empty → Use default "manufacturo" 📋
```

## Script Execution Timeline

```
Time →
│
├─ 0:00 ┤ User clicks "Run" in Semaphore UI
│
├─ 0:01 ┤ Semaphore starts container
│       │ Mounts repository to /tmp/semaphore/...
│       │ Passes parameters as command line arguments
│
├─ 0:02 ┤ semaphore_wrapper.ps1 starts
│       │ • Parses all arguments
│       │ • Normalizes RestoreDateTime
│       │ • Validates Timezone
│       │ • Converts DryRun to boolean
│       │ • Converts MaxWaitMinutes to integer
│
├─ 0:03 ┤ self_service.ps1 starts
│       │ • Loads AutomationUtilities.ps1
│       │ • Validates provided parameters
│       │ • Stores original values
│
├─ 0:04 ┤ STEP 0B: Azure Authentication
│       │ • Authenticates using Service Principal
│       │ • Connects to Azure cloud
│
├─ 0:05 ┤ STEP 0C: Grant Permissions
│       │ • Calls Azure Function to grant permissions
│       │ • Waits for propagation (30 seconds)
│
├─ 0:35 ┤ STEP 0D: Auto-Detect Parameters
│       │ • Queries Azure for missing values
│       │ • Applies defaults where needed
│       │ • Validates final parameter set
│
├─ 0:60 ┤ STEP 1: Restore Point in Time
│       │ • Restores databases with "-restored" suffix
│       │ • Waits up to MaxWaitMinutes for completion
│
├─ 60:00┤ STEP 2: Stop Environment
│       │ • Stops AKS cluster
│       │ • Disables monitoring
│
├─ 50:00┤ STEP 3: Copy Attachments
│       │ • Copies files from source to dest storage
│
├─ 60:00┤ STEP 4: Copy Database
│       │ • Copies database from -restored to destination
│
├─ 80:00┤ STEP 5: Cleanup Environment Configuration
│       │ • Removes CORS origins
│       │ • Removes redirect URIs
│
├─ 85:00┤ STEP 6: Revert SQL Users
│       │ • Removes source environment users
│
├─ 90:00┤ STEP 7: Adjust Resources
│       │ • Adjusts database tier/size
│
├─ 95:00┤ STEP 8: Delete Replicas
│       │ • Deletes old replicas
│       │ • Creates new replicas
│
├─100:00┤ STEP 9: Configure Users
│       │ • Creates destination users
│       │ • Configures permissions
│
├─105:00┤ STEP 10: Start Environment
│       │ • Starts AKS cluster
│       │ • Enables monitoring
│
├─115:00┤ STEP 11: Cleanup
│       │ • Deletes "-restored" databases
│
├─120:00┤ STEP 12: Remove Permissions
│       │ • Revokes SelfServiceRefresh permissions
│
├─122:00┤ ✅ COMPLETE
│
└───────

Total time: ~2 hours (varies based on database size and MaxWaitMinutes)
```

## Security & Safety Features

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Safety Mechanisms                            │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  1. DRY RUN Mode (Default: true)                                   │
│     • No actual changes made                                       │
│     • Shows preview of all operations                              │
│     • Safe to run multiple times                                   │
│                                                                     │
│  2. Production Confirmation                                        │
│     • Requires typing "CONFIRM"                                    │
│     • Prevents accidental production runs                          │
│                                                                     │
│  3. Namespace Protection                                           │
│     • Cannot use "manufacturo" as destination                      │
│     • Prevents overwriting production data                         │
│                                                                     │
│  4. Service Principal Authentication                               │
│     • Limited permissions                                          │
│     • Temporary permissions granted/revoked                        │
│     • Audit trail in Azure                                         │
│                                                                     │
│  5. Comprehensive Logging                                          │
│     • All operations logged                                        │
│     • Log file saved to /tmp/self_service_*.log                    │
│     • Visible in Semaphore UI                                      │
│                                                                     │
│  6. Error Handling                                                 │
│     • Script stops on critical errors                              │
│     • Rollback where possible                                      │
│     • Clear error messages                                         │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

## File Paths Reference

```
Repository Structure:
/home/kgluza/Manufacturo/semaphore/
│
├── create-templates-corrected.sh     ← Setup script (creates templates)
├── SEMAPHORE_SETUP_README.md         ← Full documentation (English)
├── INSTRUKCJA_PL.md                  ← Quick guide (Polish)
├── TEMPLATE_STRUCTURE.md             ← This file
│
└── scripts/
    ├── main/
    │   ├── semaphore_wrapper.ps1     ← Parameter parser & validator
    │   └── self_service.ps1          ← Main orchestration script
    │
    ├── common/
    │   ├── AutomationUtilities.ps1   ← Logging & utilities
    │   ├── Connect-Azure.ps1         ← Azure authentication
    │   └── Get-AzureParameters.ps1   ← Auto-detection logic
    │
    ├── restore/
    │   └── RestorePointInTime.ps1    ← Step 1
    │
    ├── environment/
    │   ├── StopEnvironment.ps1       ← Step 2
    │   └── StartEnvironment.ps1      ← Step 10
    │
    ├── storage/
    │   └── CopyAttachments.ps1       ← Step 3
    │
    ├── database/
    │   ├── copy_database.ps1         ← Step 4
    │   └── delete_restored_db.ps1    ← Step 11
    │
    ├── configuration/
    │   ├── cleanup_environment_config.ps1  ← Step 5
    │   ├── sql_configure_users.ps1         ← Steps 6 & 9
    │   └── adjust_db.ps1                   ← Step 7
    │
    ├── replicas/
    │   └── delete_replicas.ps1       ← Step 8
    │
    └── permissions/
        └── Invoke-AzureFunctionPermission.ps1  ← Step 12

Semaphore Runtime Paths:
/tmp/semaphore/project_1/repository_3_template_2/
└── scripts/
    └── (same structure as above)
```

---

**Generated by**: `create-templates-corrected.sh`  
**Last Updated**: 2025-10-13  
**Version**: 2.0

