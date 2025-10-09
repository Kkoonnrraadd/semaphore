using namespace System.Net

param($Request, $TriggerMetadata)

# Get parameters from request body
$body = $Request.Body
$Environment = $body.Environment ?? "gov001"
$ServiceAccount = $body.ServiceAccount ?? "SelfServiceRefresh"
$Action = $body.Action ?? "Remove"

# Validate Action parameter
if ($Action -notin @("Grant", "Remove")) {
    $Action = "Grant"
}

Write-Host "🔐 Service Principal Access Management" -ForegroundColor Cyan
Write-Host "======================================" -ForegroundColor Cyan
Write-Host "Service Principal: $ServiceAccount" -ForegroundColor White
Write-Host "Environment: $Environment" -ForegroundColor White
Write-Host "Action: $Action" -ForegroundColor White

# Authenticate to Azure AD
Write-Host "`n📋 Authenticating..." -ForegroundColor Yellow
try {
    $tenantId = $env:tenantId
    $appId = $env:appId
    $appSecret = $env:appSecret
    $securePassword = ConvertTo-SecureString -String $appSecret -AsPlainText -Force
    $credential = New-Object System.Management.Automation.PSCredential($appId, $securePassword)
    Connect-MgGraph -ClientSecretCredential $credential -TenantId $tenantId -Environment USGov
    Write-Host "  ✅ Authenticated" -ForegroundColor Green
} catch {
    Write-Host "  ❌ Authentication failed: $($_.Exception.Message)" -ForegroundColor Red
    $body = "Authentication failed: $($_.Exception.Message)"
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::InternalServerError
        Body = $body
    })
    return
}

# Get the service principal
Write-Host "`n👤 Finding service principal: $ServiceAccount" -ForegroundColor Yellow
try {
    $escapedName = $ServiceAccount -replace "'", "''"
    $sp = Get-MgServicePrincipal -Filter "DisplayName eq '$escapedName'"
    
    if (-not $sp) {
        Write-Host "  ❌ Service principal not found" -ForegroundColor Red
        $body = "Service principal not found: $ServiceAccount"
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::NotFound
            Body = $body
        })
        Disconnect-MgGraph
        return
    }
    
    Write-Host "  ✅ Found: $($sp.DisplayName) (ID: $($sp.Id))" -ForegroundColor Green
} catch {
    Write-Host "  ❌ Error finding service principal: $($_.Exception.Message)" -ForegroundColor Red
    $body = "Error finding service principal: $($_.Exception.Message)"
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::InternalServerError
        Body = $body
    })
    Disconnect-MgGraph
    return
}

# Get the target group
$groupName = "$Environment-SelfServiceCopy"
Write-Host "`n📋 Finding group: $groupName" -ForegroundColor Yellow
try {
    $escapedGroupName = $groupName -replace "'", "''"
    $group = Get-MgGroup -Filter "DisplayName eq '$escapedGroupName'"
    
    if (-not $group) {
        Write-Host "  ❌ Group not found" -ForegroundColor Red
        $body = "Group not found: $groupName"
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::NotFound
            Body = $body
        })
        Disconnect-MgGraph
        return
    }
    
    Write-Host "  ✅ Found: $($group.DisplayName)" -ForegroundColor Green
} catch {
    Write-Host "  ❌ Error finding group: $($_.Exception.Message)" -ForegroundColor Red
    $body = "Error finding group: $($_.Exception.Message)"
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::InternalServerError
        Body = $body
    })
    Disconnect-MgGraph
    return
}

# Check current membership
Write-Host "`n🔍 Checking current membership..." -ForegroundColor Yellow
try {
    $currentGroups = Get-MgServicePrincipalMemberOf -ServicePrincipalId $sp.Id
    $isMember = $currentGroups | Where-Object { $_.Id -eq $group.Id }
    
    if ($isMember) {
        Write-Host "  ✅ Service principal is currently a member" -ForegroundColor Green
    } else {
        Write-Host "  ℹ️  Service principal is not currently a member" -ForegroundColor Gray
    }
} catch {
    Write-Host "  ❌ Error checking membership: $($_.Exception.Message)" -ForegroundColor Red
    $body = "Error checking membership: $($_.Exception.Message)"
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::InternalServerError
        Body = $body
    })
    Disconnect-MgGraph
    return
}

# Perform the action
$result = ""
try {
    if ($Action -eq "Grant") {
        if ($isMember) {
            Write-Host "`n⚠️  Already a member - skipping" -ForegroundColor Yellow
            $result = "Service principal is already a member of $groupName"
        } else {
            Write-Host "`n➕ Adding to group..." -ForegroundColor Yellow
            New-MgGroupMember -GroupId $group.Id -DirectoryObjectId $sp.Id
            Write-Host "  ✅ Successfully added" -ForegroundColor Green
            $result = "Successfully added $ServiceAccount to $groupName"
        }
    } elseif ($Action -eq "Remove") {
        if (-not $isMember) {
            Write-Host "`n⚠️  Not a member - skipping" -ForegroundColor Yellow
            $result = "Service principal is not a member of $groupName"
        } else {
            Write-Host "`n➖ Removing from group..." -ForegroundColor Yellow
            Remove-MgGroupMemberDirectoryObjectByRef -GroupId $group.Id -DirectoryObjectId $sp.Id
            Write-Host "  ✅ Successfully removed" -ForegroundColor Green
            $result = "Successfully removed $ServiceAccount from $groupName"
        }
    }
} catch {
    Write-Host "  ❌ Error performing action: $($_.Exception.Message)" -ForegroundColor Red
    $body = "Error performing action: $($_.Exception.Message)"
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::InternalServerError
        Body = $body
    })
    Disconnect-MgGraph
    return
}

# Success
Write-Host "`n🎉 Operation completed successfully!" -ForegroundColor Green
Disconnect-MgGraph

Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
    StatusCode = [HttpStatusCode]::OK
    Body = $result
})