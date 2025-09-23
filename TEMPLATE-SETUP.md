# 🚀 Manual Template Setup Guide

Since the JSON template files can't be imported via API, here's how to manually create your templates in Semaphore UI:

## Template 1: Self-Service Data Refresh - DRY RUN

### Basic Settings
- **Name**: `Self-Service Data Refresh - DRY RUN (PowerShell)`
- **Description**: `Preview what the data refresh would do (SAFE - no changes made)`
- **Command**: `pwsh`
- **Arguments**: 
```
/scripts/main/self_service.ps1
-Source
{{ .source_env }}
-Destination
{{ .dest_env }}
-SourceNamespace
{{ .source_ns }}
-DestinationNamespace
{{ .dest_ns }}
-CustomerAlias
{{ .customer }}
-CustomerAliasToRemove
{{ .customer_to_remove }}
-RestoreDateTime
{{ .restore_datetime }}
-Timezone
{{ .timezone }}
-Cloud
{{ .cloud }}
-MaxWaitMinutes
{{ .max_wait }}
-DryRun
-AutoApprove
```

### Environment Variables
Set these in your Variable Group:
- `AZURE_CLIENT_ID`
- `AZURE_CLIENT_SECRET`
- `AZURE_TENANT_ID`
- `AZURE_SUBSCRIPTION_ID`
- `AZURE_USERNAME`
- `AZURE_PASSWORD`

### Survey Questions
Create these survey questions in Semaphore:

1. **source_env** (Text, Required, Default: "gov001")
2. **dest_env** (Text, Required, Default: "gov001") 
3. **source_ns** (Text, Required, Default: "manufacturo")
4. **dest_ns** (Text, Required, Default: "test")
5. **customer** (Text, Required, Default: "gov001-test")
6. **customer_to_remove** (Text, Required, Default: "gov001")
7. **restore_datetime** (Text, Required, Default: "2025-09-23 08:54:01")
8. **timezone** (Select, Required, Default: "UTC", Options: UTC, Europe/Warsaw, America/New_York, America/Los_Angeles, Asia/Tokyo)
9. **cloud** (Select, Required, Default: "AzureUSGovernment", Options: AzureCloud, AzureUSGovernment)
10. **max_wait** (Number, Required, Default: 40)

## Template 2: Self-Service Data Refresh - PRODUCTION

### Basic Settings
- **Name**: `Self-Service Data Refresh - PRODUCTION (PowerShell)`
- **Description**: `Execute actual data refresh operations (⚠️ PRODUCTION MODE)`
- **Command**: `pwsh`
- **Arguments**: 
```
/scripts/main/self_service.ps1
-Source
{{ .source_env }}
-Destination
{{ .dest_env }}
-SourceNamespace
{{ .source_ns }}
-DestinationNamespace
{{ .dest_ns }}
-CustomerAlias
{{ .customer }}
-CustomerAliasToRemove
{{ .customer_to_remove }}
-RestoreDateTime
{{ .restore_datetime }}
-Timezone
{{ .timezone }}
-Cloud
{{ .cloud }}
-MaxWaitMinutes
{{ .max_wait }}
-AutoApprove
```

### Environment Variables & Survey Questions
Same as the DRY RUN template above.

## Steps to Create in Semaphore UI

1. **Go to Semaphore** → Templates → Add Template
2. **Fill in the basic settings** (Name, Description, Command, Arguments)
3. **Set Environment Variables** (link to your Variable Group)
4. **Add Survey Questions** (one by one)
5. **Save the template**
6. **Repeat for the second template**

## Why This Approach Works Better

✅ **Reliable** - No API import issues  
✅ **Flexible** - Easy to modify in UI  
✅ **Visual** - See exactly what you're creating  
✅ **Immediate** - Works right away  

The JSON files were just documentation anyway - this manual approach is actually more practical for your use case.

