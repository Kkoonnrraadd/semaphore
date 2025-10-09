using namespace System.Net

param($Request, $TriggerMetadata)

# Get parameters from request body
$body = $Request.Body
$Environment = $body.Environment ?? "dev"
$ServiceAccount = $body.ServiceAccount ?? "AutomatedAccessRequest"
$Action = $body.Action ?? "Grant"

# Validate Action parameter
if ($Action -notin @("Grant", "Remove")) {
    $Action = "Grant"
}

Write-Host "🔐 Simple Access Request Script" -ForegroundColor Cyan
Write-Host "===============================" -ForegroundColor Cyan
Write-Host "Action: $Action permissions" -ForegroundColor Yellow

# Azure AD Authentication for Azure Function
Write-Host "`n📋 Authenticating to Azure AD..." -ForegroundColor Yellow
try {
    $tenantId = $env:tenantId
    $appId = $env:appIdv2
    $appSecret = $env:appSecretv2
    $securePassword = ConvertTo-SecureString -String $appSecret -AsPlainText -Force
    $credential = New-Object System.Management.Automation.PSCredential($appId, $securePassword)
    Connect-MgGraph -ClientSecretCredential $credential -TenantId $tenantId
    Write-Host "  ✅ Successfully authenticated to Azure AD" -ForegroundColor Green
} catch {
    Write-Host "  ❌ Failed to authenticate: $($_.Exception.Message)" -ForegroundColor Red
    $body = "Failed to authenticate to Azure AD: $($_.Exception.Message)"
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::InternalServerError
        Body = $body
    })
    return
}

# Get the service account (try both user and service principal)
Write-Host "`n👤 Getting account information for: $ServiceAccount" -ForegroundColor Yellow
$account = $null
$accountType = ""

try {
    # Determine search strategy based on account format
    if ($ServiceAccount -match "@") {
        # Email format - search as user first
        Write-Host "  🔍 Email format detected, searching as user first..." -ForegroundColor Gray
        $user = Get-MgUser -Filter "UserPrincipalName eq '$ServiceAccount'"
        if ($user) {
            $account = $user
            $accountType = "User"
            Write-Host "  ✅ Found as User: $($user.DisplayName) (ID: $($user.Id))" -ForegroundColor Green
        } else {
            Write-Host "  ⚠️  User not found, trying as service principal..." -ForegroundColor Yellow
            $sp = Get-MgServicePrincipal -Filter "DisplayName eq '$ServiceAccount'"
            if ($sp) {
                $account = $sp
                $accountType = "Service Principal"
                Write-Host "  ✅ Found as Service Principal: $($sp.DisplayName) (ID: $($sp.Id))" -ForegroundColor Green
            }
        }
    } else {
        # Non-email format - search as service principal first
        Write-Host "  🔍 Non-email format detected, searching as service principal first..." -ForegroundColor Gray
        $sp = Get-MgServicePrincipal -Filter "DisplayName eq '$ServiceAccount'"
        if ($sp) {
            $account = $sp
            $accountType = "Service Principal"
            Write-Host "  ✅ Found as Service Principal: $($sp.DisplayName) (ID: $($sp.Id))" -ForegroundColor Green
        } else {
            Write-Host "  ⚠️  Service Principal not found, trying as user..." -ForegroundColor Yellow
            $user = Get-MgUser -Filter "UserPrincipalName eq '$ServiceAccount'"
            if ($user) {
                $account = $user
                $accountType = "User"
                Write-Host "  ✅ Found as User: $($user.DisplayName) (ID: $($user.Id))" -ForegroundColor Green
            }
        }
    }
    
    if (-not $account) {
        Write-Host "  ❌ Account not found as user or service principal: $ServiceAccount" -ForegroundColor Red
        $body = "Account not found as user or service principal: $ServiceAccount"
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::NotFound
            Body = $body
        })
        return
    }
} catch {
    Write-Host "  ❌ Error getting account: $($_.Exception.Message)" -ForegroundColor Red
    $body = "Error getting account: $($_.Exception.Message)"
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::InternalServerError
        Body = $body
    })
    return
}

# Use single environment
$environment = $Environment.Trim()
Write-Host "`n🌍 Processing environment: $environment" -ForegroundColor Yellow

# Define the single group to add the user to (SelfServiceCopy group)
$groupName = "$environment-SelfServiceCopy"

Write-Host "`n📋 Group to $($Action.ToLower()) user from:" -ForegroundColor Yellow
Write-Host "  • $groupName" -ForegroundColor Gray

# Get current group memberships (works for both users and service principals)
Write-Host "`n🔍 Checking current group memberships..." -ForegroundColor Yellow
try {
    if ($accountType -eq "User") {
        $currentGroups = Get-MgUserMemberOf -UserId $account.Id
    } else {
        # For service principals, use the same method
        $currentGroups = Get-MgServicePrincipalMemberOf -ServicePrincipalId $account.Id
    }
    Write-Host "  ✅ Retrieved current group memberships" -ForegroundColor Green
} catch {
    Write-Host "  ❌ Error getting current groups: $($_.Exception.Message)" -ForegroundColor Red
    $body = "Error getting current groups: $($_.Exception.Message)"
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::InternalServerError
        Body = $body
    })
    return
}

# Process the single group
$successCount = 0
$skipCount = 0
$errorCount = 0

Write-Host "`n📋 Processing group: $groupName" -ForegroundColor Cyan

try {
    # Get the group
    $group = Get-MgGroup -Filter "DisplayName eq '$groupName'"
    if (-not $group) {
        Write-Host "  ❌ Group not found: $groupName" -ForegroundColor Red
        $errorCount++
    } else {
        # Check if user is already a member
        $isMember = $false
        foreach ($currentGroup in $currentGroups) {
            if ($currentGroup.Id -eq $group.Id) {
                $isMember = $true
                break
            }
        }
        
        if ($Action -eq "Grant") {
            if ($isMember) {
                Write-Host "  ⚠️  $accountType is already a member of $groupName - skipping" -ForegroundColor Yellow
                $skipCount++
            } else {
                # Add account to group
                Write-Host "  ➕ Adding $accountType to $groupName..." -ForegroundColor Gray
                New-MgGroupMember -GroupId $group.Id -DirectoryObjectId $account.Id
                Write-Host "  ✅ Successfully added $accountType to $groupName" -ForegroundColor Green
                $successCount++
            }
        } elseif ($Action -eq "Remove") {
            if ($isMember) {
                # Remove account from group
                Write-Host "  ➖ Removing $accountType from $groupName..." -ForegroundColor Gray
                # Remove-MgGroupMemberDirectoryObjectByRef -GroupId $group.Id -DirectoryObjectId $account.Id
                Remove-MgGroupMemberDirectoryObjectByRef -GroupId $group.Id -DirectoryObjectId "c9dddec6-b614-4f6c-8441-2f34a5b77606"
                Write-Host "  ✅ Successfully removed $accountType from $groupName" -ForegroundColor Green
                $successCount++
            } else {
                Write-Host "  ⚠️  $accountType is not a member of $groupName - skipping" -ForegroundColor Yellow
                $skipCount++
            }
        }
    }
    
} catch {
    Write-Host "  ❌ Error processing group $groupName`: $($_.Exception.Message)" -ForegroundColor Red
    $errorCount++
}

# Summary
Write-Host "`n====================================" -ForegroundColor Cyan
Write-Host " 📊 ACCESS REQUEST SUMMARY" -ForegroundColor Cyan
Write-Host "====================================" -ForegroundColor Cyan
Write-Host "👤 Account: $ServiceAccount ($accountType)" -ForegroundColor White
Write-Host "🌍 Environment: $environment" -ForegroundColor White
Write-Host "🔧 Action: $Action" -ForegroundColor White
Write-Host "📋 Group: $groupName" -ForegroundColor White
Write-Host "✅ Successfully $($Action.ToLower())ed: $successCount group(s)" -ForegroundColor Green
Write-Host "⚠️  Skipped: $skipCount group(s)" -ForegroundColor Yellow
Write-Host "❌ Errors: $errorCount group(s)" -ForegroundColor Red

if ($errorCount -eq 0) {
    Write-Host "`n🎉 Access request completed successfully!" -ForegroundColor Green
} else {
    Write-Host "`n⚠️  Access request completed with errors. Please check the output above." -ForegroundColor Yellow
}

# Prepare response body
if ($errorCount -eq 0) {
    $body = "Access request completed successfully. Successfully $($Action.ToLower())ed: $successCount group(s), Skipped: $skipCount group(s)"
} else {
    $body = "Access request completed with errors. Successfully $($Action.ToLower())ed: $successCount group(s), Skipped: $skipCount group(s), Errors: $errorCount group(s)"
}

# Disconnect from Microsoft Graph
Disconnect-MgGraph
Write-Host "`n🔒 Disconnected from Azure AD" -ForegroundColor Gray

# Associate values to output bindings by calling 'Push-OutputBinding'.
Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
    StatusCode = [HttpStatusCode]::OK
    Body = $body
})
