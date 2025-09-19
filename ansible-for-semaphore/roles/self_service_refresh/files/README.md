# Self-Service Refresh Scripts

This repository contains PowerShell scripts for performing self-service data refresh operations on Azure SQL databases.

## Recent Improvements

### ✅ Fixed Issues

1. **Max Wait Time Logic** - Fixed the monitoring loop to properly respect the `MaxWaitMinutes` parameter instead of running for 300 minutes (600 iterations × 30 seconds).

2. **Dry Run Mode** - Added `-DryRun` parameter to preview operations without executing them.


4. **Default Datetime & Timezone** - Improved defaults:
   - Default restore point: 15 minutes ago
   - Default timezone: Current system timezone
   - User confirmation prompts for defaults

### 🆕 New Features

#### Parameters

- `-DryRun`: Preview operations without making changes
- `-MaxWaitMinutes`: Customize maximum wait time for database restoration (default: 10 minutes)

#### Enhanced User Experience

- **Smart Defaults**: Automatically suggests 15 minutes ago as restore point
- **Timezone Detection**: Uses current system timezone as default
- **Confirmation Prompts**: Asks for user approval when using defaults
- **Better Error Handling**: Improved timezone and datetime validation
- **Progress Indicators**: Clear visual feedback during operations

## Usage Examples

### Basic Usage
```powershell
.\self_service.ps1 -Source "qa2" -Destination "dev"
```

### Dry Run Mode (Preview Only)
```powershell
.\self_service.ps1 -Source "qa2" -Destination "dev" -DryRun
```

### Automation Example
```powershell
.\self_service.ps1 -Source "qa2" -Destination "dev" -MaxWaitMinutes 15
```

### Custom Wait Time
```powershell
.\self_service.ps1 -Source "qa2" -Destination "dev" -MaxWaitMinutes 20
```

## Script Structure

```
SelfServiceRefresh/
├── self_service.ps1              # Main orchestration script
├── test_restore.ps1              # Test script for new features
├── 0_restore_point_in_time/      # Database restoration
├── 1_stop_environment/           # Environment shutdown
├── 2_copy_attachments/           # File copy operations
├── 2_copy_database/              # Database copy operations
├── 3_adjust_resources/           # Resource configuration
├── 4_adjust_key_vault/           # Key vault configuration
├── 5_adjust_app_configuration/   # App configuration
├── 6_start_environment/          # Environment startup
├── 7_delete_resources/           # Resource cleanup
└── 8_manage_permissions/         # Permission management
```

## Testing

Run the test script to see the new functionality in action:

```powershell
.\test_restore.ps1
```

## Notes

- The script now properly handles timezone conversions using IANA timezone names
- Default restore point is 15 minutes ago to avoid issues with very recent data
- Dry run mode helps validate configuration before execution
