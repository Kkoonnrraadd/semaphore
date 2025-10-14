# Semaphore Template Setup - Documentation

## Overview

This script (`create-templates-corrected.sh`) creates a complete Semaphore project structure with templates for Self-Service Data Refresh automation.

## What Gets Created

### 1. Project Structure

- **Project Name**: `PROJEKT`
- **View 1**: `WIDOK` - Contains main workflow templates
- **View 2**: `TASKI` - Contains 12 individual task templates

### 2. Main Workflow Templates (in WIDOK view)

#### Template 1: Self-Service Data Refresh - DRY RUN
- **Purpose**: Preview what the data refresh would do (SAFE - no changes made)
- **DryRun Flag**: Fixed to `true`
- **Parameters**: 11 parameters (all OPTIONAL)

#### Template 2: Self-Service Data Refresh - PRODUCTION
- **Purpose**: Execute actual data refresh operations (⚠️ PRODUCTION MODE)
- **DryRun Flag**: Set to `false`
- **Parameters**: 12 parameters (all OPTIONAL) + production confirmation
- **Safety**: Requires typing "CONFIRM" to proceed

### 3. Individual Task Templates (in TASKI view)

All 12 steps from `self_service.ps1` are available as individual templates:

1. **Task 1: Restore Point in Time**
   - Script: `restore/RestorePointInTime.ps1`
   - Restores databases to a specific point in time
   
2. **Task 2: Stop Environment**
   - Script: `environment/StopEnvironment.ps1`
   - Stops the destination environment (AKS cluster, monitoring)
   
3. **Task 3: Copy Attachments**
   - Script: `storage/CopyAttachments.ps1`
   - Copies attachments from source to destination storage
   
4. **Task 4: Copy Database**
   - Script: `database/copy_database.ps1`
   - Copies database from source to destination
   
5. **Task 5: Cleanup Environment Configuration**
   - Script: `configuration/cleanup_environment_config.ps1`
   - Cleans up source environment configurations (CORS, redirect URIs)
   
6. **Task 6: Revert SQL Users**
   - Script: `configuration/sql_configure_users.ps1` (with Revert flag)
   - Reverts source environment SQL users and roles
   
7. **Task 7: Adjust Database Resources**
   - Script: `configuration/adjust_db.ps1`
   - Adjusts database resources and configurations
   
8. **Task 8: Delete and Recreate Replicas**
   - Script: `replicas/delete_replicas.ps1`
   - Deletes and recreates replica databases
   
9. **Task 9: Configure SQL Users**
   - Script: `configuration/sql_configure_users.ps1`
   - Configures SQL users and permissions
   
10. **Task 10: Start Environment**
    - Script: `environment/StartEnvironment.ps1`
    - Starts the destination environment (AKS cluster, monitoring)
    
11. **Task 11: Cleanup Restored Databases**
    - Script: `database/delete_restored_db.ps1`
    - Deletes temporary restored databases with '-restored' suffix
    
12. **Task 12: Remove Permissions**
    - Script: `permissions/Invoke-AzureFunctionPermission.ps1`
    - Removes permissions from SelfServiceRefresh service account

## Parameter Auto-Detection

### Key Feature: All Parameters Are OPTIONAL

The scripts have built-in auto-detection capabilities:

- **RestoreDateTime**: If empty, uses "15 minutes ago"
- **Timezone**: If empty, uses system timezone or SEMAPHORE_SCHEDULE_TIMEZONE env var
- **Source**: If empty, auto-detects from Azure subscription or ENVIRONMENT env var
- **Destination**: If empty, defaults to same as Source
- **SourceNamespace**: If empty, defaults to `"manufacturo"`
- **DestinationNamespace**: If empty, defaults to `"test"`
- **CustomerAlias**: If empty, uses INSTANCE_ALIAS environment variable
- **CustomerAliasToRemove**: If empty, auto-calculates from CustomerAlias pattern
- **Cloud**: If empty, auto-detects from Azure CLI configuration
- **MaxWaitMinutes**: If empty, defaults to 60

### How Auto-Detection Works

1. **User provides values** → Script uses them directly ✅
2. **User leaves empty** → Script queries Azure or uses environment variables 🔍
3. **Still empty** → Script uses sensible defaults 📋

This means users can:
- Run with all defaults (fastest for testing)
- Override specific parameters only (flexible)
- Provide all parameters explicitly (full control)

## Script Execution Flow

### Wrapper Layer
All templates use `semaphore_wrapper.ps1` which:
1. Parses Semaphore's parameter format
2. Normalizes datetime inputs (supports multiple formats)
3. Validates timezone requirements
4. Converts parameters to proper types (boolean, integer)
5. Calls `self_service.ps1` with converted parameters

### Script Path Variable

```bash
SCRIPT_PATH="/tmp/semaphore/project_1/repository_3_template_2/scripts/main/semaphore_wrapper.ps1"
```

This is where Semaphore mounts the repository during execution. Individual tasks use similar paths pointing to their specific PowerShell scripts.

## Usage

### Running the Setup Script

```bash
cd /home/kgluza/Manufacturo/semaphore
./create-templates-corrected.sh
```

### Expected Output

```
═══════════════════════════════════════════════════════════════════════════
🚀 SEMAPHORE TEMPLATE CREATION SCRIPT
═══════════════════════════════════════════════════════════════════════════

ℹ️  Configuration:
  Semaphore URL: http://localhost:3000
  Script Path: /tmp/semaphore/project_1/repository_3_template_2/scripts/main/semaphore_wrapper.ps1
  Project Name: PROJEKT
  Main View: WIDOK
  Tasks View: TASKI

═══════════════════════════════════════════════════════════════════════════
STEP 1: CREATE OR GET PROJECT
═══════════════════════════════════════════════════════════════════════════

ℹ️  Checking for existing project 'PROJEKT'...
✅ Project 'PROJEKT' created with ID: X

... (continues with all steps)

═══════════════════════════════════════════════════════════════════════════
🎉 SETUP COMPLETE
═══════════════════════════════════════════════════════════════════════════

✅ All templates created successfully!

ℹ️  Summary:
  📁 Project: PROJEKT (ID: X)
  📋 View 'WIDOK': Contains 2 main workflow templates
     • Self-Service Data Refresh - DRY RUN
     • Self-Service Data Refresh - PRODUCTION
  📋 View 'TASKI': Contains 12 individual task templates
     • Task 1: Restore Point in Time
     • Task 2: Stop Environment
     ... (all 12 tasks)

ℹ️  Key features:
  ✅ All parameters are OPTIONAL - script auto-detects from Azure
  ✅ Default values: Source=Destination, SourceNamespace='manufacturo', DestinationNamespace='test'
  ✅ Script path: /tmp/semaphore/project_1/repository_3_template_2/scripts/main/semaphore_wrapper.ps1
  ✅ Robust parameter handling via semaphore_wrapper.ps1

✅ You can now use these templates in Semaphore UI!
```

## Configuration Variables

Edit these at the top of `create-templates-corrected.sh`:

```bash
# Semaphore API Configuration
SEMAPHORE_URL="http://localhost:3000"
API_TOKEN="your-api-token-here"

# Script path in Semaphore execution environment
SCRIPT_PATH="/tmp/semaphore/project_1/repository_3_template_2/scripts/main/semaphore_wrapper.ps1"

# Project and View names
PROJECT_NAME="PROJEKT"
VIEW_MAIN="WIDOK"
VIEW_TASKS="TASKI"
```

## API Reference

The script uses Semaphore API v2. Reference: https://semaphoreui.com/api-docs/

### Key API Endpoints Used

- `GET /api/projects` - List projects
- `POST /api/projects` - Create project
- `GET /api/project/{id}/repositories` - Get repositories
- `GET /api/project/{id}/inventory` - Get inventories
- `GET /api/project/{id}/environment` - Get environments
- `POST /api/project/{id}/views` - Create view
- `POST /api/project/{id}/templates` - Create template

## Troubleshooting

### Issue: "Failed to get projects"
**Solution**: Check that:
- Semaphore is running at `$SEMAPHORE_URL`
- API token is valid and has admin permissions
- Network connectivity is working

### Issue: "No repository/inventory/environment found"
**Solution**: The script uses default ID "1". If you need specific resources:
1. Create them in Semaphore UI first
2. The script will detect and use them automatically

### Issue: Templates not showing in UI
**Solution**: 
- Refresh the Semaphore UI
- Check that the view IDs are correct
- Verify project ID matches

## Differences from Previous Version

### Removed
- ❌ `CONFIG_FILE` - No longer uses `self_service_defaults.json`
- ❌ Hard-coded default parameter values
- ❌ User is forced to provide specific values

### Added
- ✅ Project creation (`PROJEKT`)
- ✅ Two views (`WIDOK` and `TASKI`)
- ✅ 12 individual task templates
- ✅ All parameters marked as OPTIONAL
- ✅ Script path as variable (`SCRIPT_PATH`)
- ✅ Comprehensive parameter descriptions explaining auto-detection
- ✅ Better error handling and logging

### Changed
- 🔄 Parameter descriptions now explain they are OPTIONAL
- 🔄 Default values are empty (script auto-detects)
- 🔄 Script structure is modular with functions per step

## Best Practices

### For Testing
1. Use **DRY RUN** template first
2. Leave parameters empty to test auto-detection
3. Verify the preview output before running production

### For Production
1. Test with DRY RUN first
2. Use **PRODUCTION** template only when ready
3. Type "CONFIRM" carefully
4. Monitor the execution logs

### For Individual Tasks
1. Useful for debugging specific steps
2. Can run tasks in different order if needed
3. Allows partial workflow execution
4. Good for development and testing

## Support

For issues or questions:
1. Check Semaphore logs: `docker logs semaphore`
2. Review script output for error messages
3. Verify Azure authentication is working
4. Check that all required environment variables are set

## Next Steps

After running this script:

1. **Access Semaphore UI**: http://localhost:3000
2. **Navigate to Project**: `PROJEKT`
3. **Select View**: 
   - `WIDOK` for full workflows
   - `TASKI` for individual steps
4. **Run a Template**:
   - Click on template name
   - Fill in parameters (or leave empty for auto-detection)
   - Click "Run"
5. **Monitor Execution**: Watch the task log in real-time

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                        SEMAPHORE UI                              │
│                                                                   │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │                    PROJECT: PROJEKT                       │   │
│  │                                                            │   │
│  │  ┌─────────────────────┐  ┌──────────────────────────┐   │   │
│  │  │   VIEW: WIDOK       │  │     VIEW: TASKI          │   │   │
│  │  │                     │  │                          │   │   │
│  │  │  • DRY RUN          │  │  • Task 1: Restore       │   │   │
│  │  │  • PRODUCTION       │  │  • Task 2: Stop Env      │   │   │
│  │  │                     │  │  • Task 3: Copy Attach   │   │   │
│  │  │                     │  │  • Task 4: Copy DB       │   │   │
│  │  │                     │  │  • Task 5: Cleanup Cfg   │   │   │
│  │  │                     │  │  • Task 6: Revert Users  │   │   │
│  │  │                     │  │  • Task 7: Adjust DB     │   │   │
│  │  │                     │  │  • Task 8: Delete Reps   │   │   │
│  │  │                     │  │  • Task 9: Config Users  │   │   │
│  │  │                     │  │  • Task 10: Start Env    │   │   │
│  │  │                     │  │  • Task 11: Cleanup      │   │   │
│  │  │                     │  │  • Task 12: Remove Perms │   │   │
│  │  └─────────────────────┘  └──────────────────────────┘   │   │
│  └────────────────────────────────────────────────────────────┘   │
└───────────────────────────────────────────────────────────────────┘
                              ▼
                  semaphore_wrapper.ps1
                              ▼
                    self_service.ps1
                              ▼
              ┌───────────────────────────────┐
              │  12 PowerShell Scripts        │
              │  (in scripts/ directory)      │
              └───────────────────────────────┘
```

## Maintenance

### Adding New Parameters
1. Edit `create-templates-corrected.sh`
2. Add parameter to `survey_vars` array
3. Update `semaphore_wrapper.ps1` to parse new parameter
4. Rerun the script to update templates

### Modifying Existing Templates
1. Delete old templates in Semaphore UI (or let script recreate)
2. Edit `create-templates-corrected.sh`
3. Rerun the script

### Updating Script Paths
If Semaphore changes the repository mount path:
1. Update `SCRIPT_PATH` variable
2. Rerun the script

