# Self-Service Script Flow Summary

## New Execution Flow

The script has been reorganized to follow this sequence:

```
1. Wrapper (semaphore_wrapper.ps1)
   ↓
2. Self-Service Main (self_service.ps1)
   ↓
3. AutomationUtilities.ps1 (loaded)
   ↓
4. Grant Permissions (Invoke-AzureFunctionPermission.ps1) - EARLY if Source known
   ↓
5. Connect to Azure (Connect-Azure.ps1)
   ↓
6. Get Azure Parameters (Get-AzureParameters.ps1) - NOW with auth
   ↓
7. Grant Permissions (if not done in step 4)
   ↓
8. Continue with migration steps (1-12)
```

## Key Changes

### ✅ Correct Order Now
- **Permission Grant**: Happens BEFORE Azure authentication (uses Azure Function App, not Azure CLI)
- **Azure Authentication**: Connects to Azure cloud
- **Parameter Detection**: NOW happens AFTER authentication (can query Azure resources)

### ✅ Handles Missing User Data

#### Scenario 1: User Provides All Data
```powershell
# Wrapper receives: Source=gov001, Destination=dev, etc.
semaphore_wrapper.ps1 -Source "gov001" -Destination "dev" -CustomerAlias "test"
```
**Flow:**
1. ✅ Step 0B: Grant permissions for "gov001" (early)
2. ✅ Step 0C: Connect to Azure
3. ✅ Step 0D: Detect/confirm parameters from Azure
4. ✅ Skip Step 0D2 (permissions already granted)
5. ✅ Continue with migration

#### Scenario 2: User Provides NO Data (except CustomerAlias)
```powershell
# Wrapper receives: CustomerAlias=test (only required parameter)
semaphore_wrapper.ps1 -CustomerAlias "test"
```
**Flow:**
1. ⏭️ Step 0B: SKIP early permission grant (source unknown)
2. ✅ Step 0C: Connect to Azure (uses default cloud or env var)
3. ✅ Step 0D: Detect ALL parameters from Azure subscription
4. ✅ Step 0D2: Grant permissions with detected source
5. ✅ Continue with migration

#### Scenario 3: User Provides Partial Data
```powershell
# Wrapper receives: Source=gov001, CustomerAlias=test
semaphore_wrapper.ps1 -Source "gov001" -CustomerAlias "test"
```
**Flow:**
1. ✅ Step 0B: Grant permissions for "gov001" (early)
2. ✅ Step 0C: Connect to Azure
3. ✅ Step 0D: Detect missing parameters (Destination, Namespaces, etc.)
4. ✅ Skip Step 0D2 (permissions already granted)
5. ✅ Continue with migration

## Environment Variables

The script uses these environment variables:

### Required for Azure Authentication:
- `AZURE_CLIENT_ID` - Service Principal client ID
- `AZURE_CLIENT_SECRET` - Service Principal secret
- `AZURE_TENANT_ID` - Azure AD tenant ID
- `AZURE_SUBSCRIPTION_ID` - Azure subscription ID

### Required for Azure Function (Permissions):
- `AZURE_FUNCTION_APP_SECRET` - Secret for calling permission management function

### Required for DateTime Calculations:
- `SEMAPHORE_SCHEDULE_TIMEZONE` - Timezone for restore point calculations (e.g., "UTC", "Eastern Standard Time")

### Optional:
- `AZURE_EXTENSION_DIR` - Azure CLI extensions directory (default: `/opt/azure-cli-extensions`)

## Parameter Auto-Detection

When parameters are not provided, the script auto-detects them from:

1. **Cloud**: Azure CLI context or default to AzureUSGovernment
2. **Source**: 
   - Subscription name pattern (e.g., `*_gov001` → `gov001`)
   - Azure Graph query (tags on SQL servers)
3. **SourceNamespace**: Defaults to "manufacturo"
4. **Destination**: Defaults to same as Source
5. **DestinationNamespace**: Defaults to "test"
6. **RestoreDateTime**: Auto-calculated (5 minutes ago in configured timezone)
7. **Timezone**: From SEMAPHORE_SCHEDULE_TIMEZONE environment variable

## Required Parameters

Only **CustomerAlias** is strictly required. All other parameters can be auto-detected.

## Migration Steps (After Setup)

After Step 0 (setup, auth, params, permissions), the migration runs these steps:

```
STEP 1:  Restore Point in Time
STEP 2:  Stop Environment
STEP 3:  Copy Attachments
STEP 4:  Copy Database
STEP 5:  Cleanup Environment Configuration
STEP 6:  Revert SQL Users
STEP 7:  Adjust Resources
STEP 8:  Delete Replicas
STEP 9:  Configure Users
STEP 10: Start Environment
STEP 11: Cleanup (delete restored DBs)
STEP 12: Remove Permissions
```

## Testing Recommendations

### Test 1: Full Parameters
```bash
./semaphore_wrapper.ps1 \
  -Source "gov001" \
  -Destination "dev" \
  -SourceNamespace "manufacturo" \
  -DestinationNamespace "test" \
  -CustomerAlias "test-customer" \
  -Cloud "AzureUSGovernment" \
  -DryRun true
```

### Test 2: Minimal Parameters (CustomerAlias only)
```bash
./semaphore_wrapper.ps1 \
  -CustomerAlias "test-customer" \
  -DryRun true
```

### Test 3: Partial Parameters
```bash
./semaphore_wrapper.ps1 \
  -Source "gov001" \
  -CustomerAlias "test-customer" \
  -DryRun true
```

## Dry Run Mode

Always test with `-DryRun true` first to verify:
- ✅ Parameters are correctly detected
- ✅ Permission grant works
- ✅ Azure authentication succeeds
- ✅ All steps would execute in correct order

## Error Handling

The script will fail fast if:
- ❌ CustomerAlias is not provided
- ❌ Azure authentication fails
- ❌ Permission grant fails (when Source is known)
- ❌ Required Azure resources are not found
- ❌ SEMAPHORE_SCHEDULE_TIMEZONE is not set

All failures provide detailed error messages and guidance.

