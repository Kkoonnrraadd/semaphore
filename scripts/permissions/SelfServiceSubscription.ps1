using namespace System.Net

param($Request, $TriggerMetadata)

# Get parameters from request body
$body = $Request.Body
$Environment = $body.Environment
$ServiceAccount = $body.ServiceAccount
$Namespace = $body.Namespace
$Action = $body.Action

# Validate Action parameter
if ($Action -notin @("Grant", "Remove", "ProdSecurity")) {
    Write-Host "  ❌ Action not found" -ForegroundColor Red
    $body = "Action not found: $Action"
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::NotFound
        Body = $body
    })
    return
}

Write-Host "🔐 Service Principal Access Management" -ForegroundColor Cyan
Write-Host "======================================" -ForegroundColor Cyan
Write-Host "Service Principal: $ServiceAccount" -ForegroundColor White
Write-Host "Environment: $Environment" -ForegroundColor White
Write-Host "Action: $Action" -ForegroundColor White

# Authenticate to Azure AD (Microsoft Graph)
Write-Host "`n📋 Authenticating to Microsoft Graph..." -ForegroundColor Yellow
try {
    $tenantId = $env:tenantId
    $appId = $env:appId
    $appSecret = $env:appSecret
    $securePassword = ConvertTo-SecureString -String $appSecret -AsPlainText -Force
    $credential = New-Object System.Management.Automation.PSCredential($appId, $securePassword)
    Connect-MgGraph -ClientSecretCredential $credential -TenantId $tenantId -Environment USGov
    Write-Host "  ✅ Authenticated to Microsoft Graph" -ForegroundColor Green
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


# List all subscriptions and find matching subscription
Write-Host "`n🔍 Listing subscriptions and searching for environment: $Environment" -ForegroundColor Yellow
$subscriptionResult = ""
try {
    $allSubscriptions = Get-AzSubscription
    Write-Host "  📋 Found $($allSubscriptions.Count) total subscriptions" -ForegroundColor Gray
    
    # Find subscription matching the environment name
    $matchingSubscription = $allSubscriptions | Where-Object { $_.Name -like "*$Environment*" } | Select-Object -First 1
    
    if (-not $matchingSubscription) {
        Write-Host "  ❌ No subscription found matching environment: $Environment" -ForegroundColor Red
        Write-Host "`n  Available subscriptions:" -ForegroundColor Gray
        $allSubscriptions | ForEach-Object {
            Write-Host "    - $($_.Name) (ID: $($_.Id))" -ForegroundColor Gray
        }
        Write-Host "  ⚠️  Skipping subscription role assignment" -ForegroundColor Yellow
        $subscriptionResult = "; No matching subscription found for environment $Environment"
    } else {
        Write-Host "  ✅ Found matching subscription:" -ForegroundColor Green
        Write-Host "     Name: $($matchingSubscription.Name)" -ForegroundColor White
        Write-Host "     ID: $($matchingSubscription.Id)" -ForegroundColor White
        Write-Host "     State: $($matchingSubscription.State)" -ForegroundColor White
        
        $subscriptionId = $matchingSubscription.Id
        
        # Set context to the target subscription
        Write-Host "`n⚙️  Setting subscription context..." -ForegroundColor Yellow
        Set-AzContext -SubscriptionId $subscriptionId | Out-Null
        Write-Host "  ✅ Subscription context set" -ForegroundColor Green
        
        # Check current role assignments
        Write-Host "`n🔍 Checking current subscription role assignments..." -ForegroundColor Yellow
        $scope = "/subscriptions/$subscriptionId"
        $currentAssignments = Get-AzRoleAssignment -ObjectId $sp.Id -Scope $scope -ErrorAction SilentlyContinue
        $ContributorRole = $currentAssignments | Where-Object { $_.RoleDefinitionName -eq "Contributor" }
        
        if ($ContributorRole) {
            Write-Host "  ✅ Contributor role is currently assigned" -ForegroundColor Green
        } else {
            Write-Host "  ℹ️  Contributor role is not currently assigned" -ForegroundColor Gray
        }
        
        # Perform subscription role action
        if ($Action -eq "Grant") {
            if ($ContributorRole) {
                Write-Host "`n⚠️  Contributor role already assigned - skipping" -ForegroundColor Yellow
                $subscriptionResult = "; Contributor role already assigned to subscription $($matchingSubscription.Name)"
            } else {
                Write-Host "`n➕ Assigning Contributor role to subscription..." -ForegroundColor Yellow
                New-AzRoleAssignment -ObjectId $sp.Id -RoleDefinitionName "Contributor" -Scope $scope | Out-Null
                Write-Host "  ✅ Successfully assigned Contributor role" -ForegroundColor Green
                $subscriptionResult = "; Successfully assigned Contributor role to subscription $($matchingSubscription.Name)"
            }
        } elseif ($Action -eq "Remove") {
            if (-not $ContributorRole) {
                Write-Host "`n⚠️  Contributor role not assigned - skipping" -ForegroundColor Yellow
                $subscriptionResult = "; Contributor role not assigned to subscription $($matchingSubscription.Name)"
            } else {
                Write-Host "`n➖ Removing Contributor role from subscription..." -ForegroundColor Yellow
                Remove-AzRoleAssignment -ObjectId $sp.Id -RoleDefinitionName "Contributor" -Scope $scope | Out-Null
                Write-Host "  ✅ Successfully removed Contributor role" -ForegroundColor Green
                $subscriptionResult = "; Successfully removed Contributor role from subscription $($matchingSubscription.Name)"
            }
        }
    }
} catch {
    Write-Host "  ❌ Error with subscription role assignment: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "  ⚠️  Continuing despite subscription error..." -ForegroundColor Yellow
    $subscriptionResult = "; Error with subscription role: $($_.Exception.Message)"
}

# # Get all groups matching the environment pattern
# Write-Host "`n📋 Finding groups matching environment: $Environment" -ForegroundColor Yellow
# $targetGroups = @()

# if ($Action -eq "ProdSecurity") {
#     $filter =   "$Environment"
#     $preprod_filter =   "prodsecurityonly:)"
#     $groupSuffixes = @("DBContributors", "DBAdmins")
# } else {
#     $filter =   "$Environment"
#     $preprod_filter =   "$Environment-$Namespace"
#     $groupSuffixes = @("DBContributors","DBAdmins", "Self-Service-Refresh")
# }

# try {
#     # Search for all groups starting with the environment prefix
#     Write-Host "  🔍 Searching for groups starting with: $Environment-" -ForegroundColor Gray
    
#     try {
#         $allEnvGroups = Get-MgGroup -Filter "startswith(displayName, '$Environment-')" -CountVariable CountVar -ConsistencyLevel eventual -All
        
#         # Filter groups that end with Contributors or DBAdmin
#         foreach ($group in $allEnvGroups) {
#             $matchesSuffix = $false
#             foreach ($suffix in $groupSuffixes) {
#                 # Check if group name ends with -Contributors or -DBAdmin
#                 if ($group.DisplayName.Contains("$filter-$suffix") -or $group.DisplayName.Contains("$preprod_filter-$suffix")) {
#                     Write-Host "  ✅ Found: $($group.DisplayName)" -ForegroundColor Green
#                     $matchesSuffix = $true
#                     break
#                 }
#             }
            
#             if ($matchesSuffix -and $targetGroups.Id -notcontains $group.Id) {
#                 $targetGroups += $group
#                 Write-Host "  ✅ Found: $($group.DisplayName)" -ForegroundColor Green
#             }
#         }
#     } catch {
#         Write-Host "  ⚠️  Error searching for groups: $($_.Exception.Message)" -ForegroundColor Yellow
#     }
    
#     if ($targetGroups.Count -eq 0) {
#         Write-Host "  ❌ No groups found matching patterns for environment: $Environment" -ForegroundColor Red
#         Write-Host "  Searched prefix: $Environment-" -ForegroundColor Gray
#         Write-Host "  Required suffixes: $($groupSuffixes | ForEach-Object { '-' + $_ }) -join ', ')" -ForegroundColor Gray
#         $body = "No groups found matching environment: $Environment"
#         Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
#             StatusCode = [HttpStatusCode]::NotFound
#             Body = $body
#         })
#         Disconnect-MgGraph
#         return
#     }
    
#     Write-Host "  📊 Total groups found: $($targetGroups.Count)" -ForegroundColor Cyan
# } catch {
#     Write-Host "  ❌ Error finding groups: $($_.Exception.Message)" -ForegroundColor Red
#     $body = "Error finding groups: $($_.Exception.Message)"
#     Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
#         StatusCode = [HttpStatusCode]::InternalServerError
#         Body = $body
#     })
#     Disconnect-MgGraph
#     return
# }

# # Check current membership across all target groups
# Write-Host "`n🔍 Checking current membership..." -ForegroundColor Yellow
# try {
#     $currentGroups = Get-MgServicePrincipalMemberOf -ServicePrincipalId $sp.Id
    
#     foreach ($group in $targetGroups) {
#         $isMember = $currentGroups | Where-Object { $_.Id -eq $group.Id }
#         if ($isMember) {
#             Write-Host "  ✅ Already member of: $($group.DisplayName)" -ForegroundColor Green
#         } else {
#             Write-Host "  ℹ️  Not member of: $($group.DisplayName)" -ForegroundColor Gray
#         }
#     }
# } catch {
#     Write-Host "  ❌ Error checking membership: $($_.Exception.Message)" -ForegroundColor Red
#     $body = "Error checking membership: $($_.Exception.Message)"
#     Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
#         StatusCode = [HttpStatusCode]::InternalServerError
#         Body = $body
#     })
#     Disconnect-MgGraph
#     return
# }

# # Perform the group membership action for all target groups
# $result = @()
# $successCount = 0
# $skipCount = 0
# $errorCount = 0

# try {
#     foreach ($group in $targetGroups) {
#         $isMember = $currentGroups | Where-Object { $_.Id -eq $group.Id }
        
#         if ($Action -eq "Grant") {
#             if ($isMember) {
#                 Write-Host "`n⚠️  [$($group.DisplayName)] Already a member - skipping" -ForegroundColor Yellow
#                 $skipCount++
#             } else {
#                 try {
#                     Write-Host "`n➕ [$($group.DisplayName)] Adding to group..." -ForegroundColor Yellow
#                     New-MgGroupMember -GroupId $group.Id -DirectoryObjectId $sp.Id
#                     Write-Host "  ✅ Successfully added" -ForegroundColor Green
#                     $successCount++
#                 } catch {
#                     Write-Host "  ❌ Error: $($_.Exception.Message)" -ForegroundColor Red
#                     $errorCount++
#                 }
#             }
#         } elseif ($Action -eq "Remove") {
#             if (-not $isMember) {
#                 Write-Host "`n⚠️  [$($group.DisplayName)] Not a member - skipping" -ForegroundColor Yellow
#                 $skipCount++
#             } else {
#                 try {
#                     Write-Host "`n➖ [$($group.DisplayName)] Removing from group..." -ForegroundColor Yellow
#                     Remove-MgGroupMemberDirectoryObjectByRef -GroupId $group.Id -DirectoryObjectId $sp.Id
#                     Write-Host "  ✅ Successfully removed" -ForegroundColor Green
#                     $successCount++
#                 } catch {
#                     Write-Host "  ❌ Error: $($_.Exception.Message)" -ForegroundColor Red
#                     $errorCount++
#                 }
#             }
#         } elseif ($Action -eq "ProdSecurity") {
#             if (-not $isMember) {
#                 Write-Host "`n⚠️  [$($group.DisplayName)] Not a member - skipping" -ForegroundColor Yellow
#                 $skipCount++
#             } else {
#                 try {
#                     Write-Host "`n➖ [$($group.DisplayName)] Removing from PROD group..." -ForegroundColor Yellow
#                     Remove-MgGroupMemberDirectoryObjectByRef -GroupId $group.Id -DirectoryObjectId $sp.Id
#                     Write-Host "  ✅ Successfully removed" -ForegroundColor Green
#                     $successCount++
#                 } catch {
#                     Write-Host "  ❌ Error: $($_.Exception.Message)" -ForegroundColor Red
#                     $errorCount++
#                 }
#             }
#         }
#     }
    
#     # Build result summary
#     $resultSummary = "$Action action completed for $ServiceAccount : $successCount succeeded, $skipCount skipped, $errorCount errors across $($targetGroups.Count) groups"
#     $result = $resultSummary
    
#     if ($errorCount -gt 0) {
#         Write-Host "`n⚠️  Completed with errors" -ForegroundColor Yellow
#     }
# } catch {
#     Write-Host "  ❌ Error performing action: $($_.Exception.Message)" -ForegroundColor Red
#     $body = "Error performing action: $($_.Exception.Message)"
#     Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
#         StatusCode = [HttpStatusCode]::InternalServerError
#         Body = $body
#     })
#     Disconnect-MgGraph
#     return
# }

# Cleanup
Disconnect-AzAccount -ErrorAction SilentlyContinue | Out-Null

# Success
Write-Host "`n🎉 Operation completed successfully!" -ForegroundColor Green
Disconnect-MgGraph

Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
    StatusCode = [HttpStatusCode]::OK
    Body = $result + $subscriptionResult
})