param (
    [Parameter(Mandatory)]
    [ValidateSet("Add", "Remove")]
    [string]$Action,
    [string]$ServiceAccountId = "devops@mnfro.com",
    [string]$GroupName = "dev-SelfServiceCopy",
    [switch]$IncludeDBAdmins = $false,
    [switch]$DryRun = $false
)

# Get current user identity
$currentUser = az account show --query "user.name" -o tsv
if (!$currentUser) {
    Write-Host "❌ Failed to get current user identity. Please run 'az login' first." -ForegroundColor Red
    exit 1
}

if ($DryRun) {
    Write-Host "`n🔍 DRY RUN MODE - Manage DevOps Group Membership" -ForegroundColor Yellow
    Write-Host "=============================================" -ForegroundColor Yellow
    Write-Host "No actual group membership changes will be performed" -ForegroundColor Yellow
} else {
    Write-Host "`n👥 MANAGE DEVOPS GROUP MEMBERSHIP" -ForegroundColor Cyan
    Write-Host "=================================" -ForegroundColor Cyan
}
Write-Host "Current User: $currentUser" -ForegroundColor Yellow
Write-Host "Service Account: $ServiceAccountId" -ForegroundColor Yellow
Write-Host "Action: $Action" -ForegroundColor Yellow
Write-Host "Primary Group: $GroupName" -ForegroundColor Yellow
if ($IncludeDBAdmins) { Write-Host "Include DB Admins: Yes" -ForegroundColor Yellow }

# Get service account object ID
Write-Host "`n🔍 Getting service account object ID..." -ForegroundColor Cyan
$serviceAccountObjectId = az ad user list --filter "userPrincipalName eq '$ServiceAccountId'" --query "[0].id" -o tsv 2>$null

if (!$serviceAccountObjectId) {
    Write-Host "❌ Service account not found: $ServiceAccountId" -ForegroundColor Red
    exit 1
}

Write-Host "✅ Service account object ID: $serviceAccountObjectId" -ForegroundColor Green

if ($DryRun) {
    Write-Host "`n🔍 DRY RUN: DISCOVERING GROUP MEMBERSHIP CHANGES" -ForegroundColor Yellow
    Write-Host "=============================================" -ForegroundColor Yellow
    
    # Define groups to manage
    $groupsToManage = @($GroupName)
    if ($IncludeDBAdmins) {
        $groupsToManage += "dev-DBAdmins"
    }
    
    Write-Host "🔍 DRY RUN: Would $Action service account '$ServiceAccountId' in these groups:" -ForegroundColor Yellow
    foreach ($groupName in $groupsToManage) {
        # Check if group exists
        $existingGroup = az ad group list --display-name $groupName --query "[0].id" -o tsv 2>$null
        
        if (!$existingGroup) {
            Write-Host "  • $groupName (❌ Group not found)" -ForegroundColor Red
        } else {
            # Check current membership
            $isMember = az ad group member check --group $existingGroup --member-id $serviceAccountObjectId --query "value" -o tsv 2>$null
            
            if ($Action -eq "Add") {
                if ($isMember -eq "true") {
                    Write-Host "  • $groupName (⚠️  Already a member, would skip)" -ForegroundColor Yellow
                } else {
                    Write-Host "  • $groupName (✅ Would add)" -ForegroundColor Green
                }
            } elseif ($Action -eq "Remove") {
                if ($isMember -eq "false") {
                    Write-Host "  • $groupName (⚠️  Not a member, would skip)" -ForegroundColor Yellow
                } else {
                    Write-Host "  • $groupName (✅ Would remove)" -ForegroundColor Green
                }
            }
        }
    }
    
    Write-Host "`n🔍 DRY RUN: Group membership preview completed." -ForegroundColor Yellow
    exit 0
}

# Define groups to manage
$groupsToManage = @($GroupName)
if ($IncludeDBAdmins) {
    $groupsToManage += "dev-DBAdmins"
}

# Process each group
foreach ($groupName in $groupsToManage) {
    Write-Host "`n📋 Processing group: $groupName" -ForegroundColor Cyan
    
    # Check if group exists
    $existingGroup = az ad group list --display-name $groupName --query "[0].id" -o tsv 2>$null
    
    if (!$existingGroup) {
        Write-Host "❌ Group not found: $groupName" -ForegroundColor Red
        continue
    }
    
    Write-Host "✅ Group found: $groupName" -ForegroundColor Green
    
    # Check current membership
    $isMember = az ad group member check --group $existingGroup --member-id $serviceAccountObjectId --query "value" -o tsv 2>$null
    
    if ($Action -eq "Add") {
        if ($isMember -eq "true") {
            Write-Host "⚠️  Service account already in group $groupName, skipping..." -ForegroundColor Yellow
        } else {
            try {
                az ad group member add --group $existingGroup --member-id $serviceAccountObjectId
                Write-Host "✅ Added service account to group $groupName" -ForegroundColor Green
            } catch {
                Write-Host "❌ Failed to add service account to group $groupName" -ForegroundColor Red
            }
        }
    } elseif ($Action -eq "Remove") {
        if ($isMember -eq "false") {
            Write-Host "⚠️  Service account not in group $groupName, skipping..." -ForegroundColor Yellow
        } else {
            try {
                az ad group member remove --group $existingGroup --member-id $serviceAccountObjectId
                Write-Host "✅ Removed service account from group $groupName" -ForegroundColor Green
            } catch {
                Write-Host "❌ Failed to remove service account from group $groupName" -ForegroundColor Red
            }
        }
    }
}

Write-Host "`n📊 SUMMARY" -ForegroundColor Cyan
Write-Host "=========" -ForegroundColor Cyan
Write-Host "Action: $Action" -ForegroundColor Yellow
Write-Host "Service Account: $ServiceAccountId" -ForegroundColor Yellow
Write-Host "Groups Processed: $($groupsToManage.Count)" -ForegroundColor Yellow
foreach ($group in $groupsToManage) {
    Write-Host "  • $group" -ForegroundColor Gray
}
Write-Host "Status: Completed" -ForegroundColor Green 