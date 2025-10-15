param (
    [Parameter(Mandatory)][string]$source,
    [AllowEmptyString()][string]$SourceNamespace,
    [Parameter(Mandatory)][string]$RestoreDateTime,
    [Parameter(Mandatory)][string]$Timezone,
    [switch]$DryRun,
    [switch]$Force,  # If set, automatically delete conflicting databases before restore
    [int]$MaxWaitMinutes = 60,
    [int]$ThrottleLimit = 10  # Number of databases to restore in parallel
)

# ============================================================================
# DRY RUN FAILURE TRACKING
# ============================================================================
# Track validation failures in dry run mode to fail at the end
$script:DryRunHasFailures = $false
$script:DryRunFailureReasons = @()

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

function Convert-ToUTCRestorePoint {
    param (
        [string]$RestoreDateTime,
        [string]$Timezone
    )
    
    try {
        # Create timezone info
        $timezoneInfo = [System.TimeZoneInfo]::FindSystemTimeZoneById($Timezone)
        Write-Host "✅ Using timezone: $Timezone ($($timezoneInfo.DisplayName))"
        
        # Parse the datetime as Unspecified (not tied to any timezone)
        # This prevents PowerShell from interpreting it based on the system's local timezone
        $restorePoint = [DateTime]::ParseExact($RestoreDateTime, 'yyyy-MM-dd HH:mm:ss', $null, [System.Globalization.DateTimeStyles]::AssumeUniversal)
        $restorePoint = [DateTime]::SpecifyKind($restorePoint, [DateTimeKind]::Unspecified)
        
        # If timezone is UTC, treat input as already UTC
        if ($Timezone -eq "UTC") {
            $restorePointInTimezone = $restorePoint
            $restorePointUtc = [DateTime]::SpecifyKind($restorePoint, [DateTimeKind]::Utc)
            Write-Host "   📅 Input datetime: $($restorePoint.ToString('yyyy-MM-dd HH:mm:ss'))"
            Write-Host "   🌍 In UTC: $($restorePointInTimezone.ToString('yyyy-MM-dd HH:mm:ss'))"
            Write-Host "   ⏰ UTC restore point: $($restorePointUtc.ToString('yyyy-MM-dd HH:mm:ss')) UTC"
        } else {
            # Convert from specified timezone to UTC
            # The datetime is now truly Unspecified, treat it as being in the target timezone
            $restorePointInTimezone = $restorePoint
            $restorePointUtc = [System.TimeZoneInfo]::ConvertTimeToUtc($restorePoint, $timezoneInfo)
            
            Write-Host "   📅 Input datetime: $($restorePoint.ToString('yyyy-MM-dd HH:mm:ss'))"
            Write-Host "   🌍 In $($Timezone): $($restorePointInTimezone.ToString('yyyy-MM-dd HH:mm:ss'))"
            Write-Host "   ⏰ UTC restore point: $($restorePointUtc.ToString('yyyy-MM-dd HH:mm:ss')) UTC"
        }
        
        return @{
            RestorePointInTimezone = $restorePointInTimezone
            RestorePointUtc = $restorePointUtc
        }
        
    } catch {
        Write-Host "❌ Error processing datetime or timezone:"
        
        # Check if it's a timezone error
        try {
            [System.TimeZoneInfo]::FindSystemTimeZoneById($Timezone) | Out-Null
        } catch {
            Write-Host "   ⚠️  Invalid timezone: '$Timezone'"
            Write-Host "   ⚠️  Common timezone abbreviations like 'PST', 'EST', 'GMT' are not supported"
            Write-Host "   💡 Use IANA timezone names instead:"
            Write-Host "      • America/Los_Angeles (for PST/PDT)"
            Write-Host "      • America/New_York (for EST/EDT)"
            Write-Host "      • Europe/London (for GMT/BST)"
            Write-Host "      • UTC (for Universal Time)"
        }
        
        Write-Host "   ⚠️  Invalid datetime format. Please use format: 'yyyy-MM-dd HH:mm:ss'"
        Write-Host "   📝 Example: '2025-08-06 10:30:00' with timezone 'America/Los_Angeles'"
        throw
    }
}

function Get-ServiceFromDatabase {
    param (
        [object]$Database
    )
    return $Database.tags.Service
}

function Should-RestoreDatabase {
    param (
        [string]$DatabaseName,
        [string]$Service
    )
    
    # Skip if contains "Copy"
    if ($DatabaseName.Contains("Copy")) {
        return $false
    }
    
    # Skip system databases
    if ($DatabaseName.Contains("master")) {
        return $false
    }
    
    # Skip already restored databases
    if ($DatabaseName.Contains("restored")) {
        return $false
    }
    
    # Skip landlord service
    if ($DatabaseName.Contains("landlord")) {
        return $false
    }
    
    return $true
}

function Test-DatabaseMatchesPattern {
    param (
        [string]$DatabaseName,
        [string]$Service,
        [string]$SourceNamespace,
        [string]$SourceProduct,
        [string]$SourceType,
        [string]$SourceEnvironment,
        [string]$SourceLocation
    )
    
    if ($SourceNamespace -eq "manufacturo") {
        $expectedPattern = "$SourceProduct-$SourceType-$Service-$SourceEnvironment-$SourceLocation"
        return $DatabaseName.Contains($expectedPattern)
    } else {
        $expectedPattern = "$SourceProduct-$SourceType-$Service-$SourceNamespace-$SourceEnvironment-$SourceLocation"
        return $DatabaseName.Contains($expectedPattern)
    }
}

function Test-ExistingRestoredDatabases {
    param (
        [array]$DatabasesToRestore,
        [string]$SourceSubscription,
        [string]$SourceResourceGroup,
        [string]$SourceServer,
        [bool]$ForceDelete = $false
    )
    
    Write-Host "`n🔍 CHECKING FOR EXISTING RESTORED DATABASES"
    Write-Host "============================================"
    Write-Host ""
    
    $conflicts = @()
    $targetNames = @()
    
    # Build list of target database names (all end with -restored suffix)
    foreach ($db in $DatabasesToRestore) {
        $targetNames += "$($db.name)-restored"
    }
    
    Write-Host "   🔎 Checking for $($targetNames.Count) potential database conflicts..."
    
    # Get all existing databases on the server
    try {
        $existingDatabases = az sql db list `
            --subscription $SourceSubscription `
            --resource-group $SourceResourceGroup `
            --server $SourceServer `
            --query "[].name" `
            --output json | ConvertFrom-Json
        
        if (-not $existingDatabases) {
            Write-Host "⚠️  Warning: Could not retrieve existing databases list"
            return @{ HasConflicts = $false; Conflicts = @() }
        }
        
        # Check each target name against existing databases
        # SAFETY: Only flag conflicts for databases ending with -restored suffix
        foreach ($targetName in $targetNames) {
            if ($existingDatabases -contains $targetName) {
                # Double-check that the conflicting database has -restored suffix (safety check)
                if ($targetName.EndsWith("-restored")) {
                    $conflicts += $targetName
                    Write-Host "  ⚠️  Found existing: $targetName"
                }
            }
        }
        
    } catch {
        Write-Host "⚠️  Warning: Error checking existing databases: $($_.Exception.Message)"
        return @{ HasConflicts = $false; Conflicts = @() }
    }
    
    # Display results
    Write-Host ""
    if ($conflicts.Count -eq 0) {
        Write-Host "✅ No conflicts detected - all target database names are available"
        Write-Host ""
        return @{ HasConflicts = $false; Conflicts = @() }
    } else {
        Write-Host "⚠️  FOUND $($conflicts.Count) EXISTING RESTORED DATABASE(S)"
        Write-Host "───────────────────────────────────────────────────"
        foreach ($conflict in $conflicts) {
            Write-Host "  • $conflict"
        }
        Write-Host ""
        
        # Handle Force mode - automatically delete previous restore attempts
        if ($ForceDelete) {
            Write-Host "🗑️  Force mode enabled: Deleting previous restore attempts..."
            Write-Host "   ℹ️  Note: Only databases with '-restored' suffix will be deleted (safe)"
            Write-Host ""
            
            $deleteSucceeded = @()
            $deleteFailed = @()
            
            foreach ($conflict in $conflicts) {
                # SAFETY CHECK: Verify -restored suffix before deletion
                if (-not $conflict.EndsWith("-restored")) {
                    Write-Host "  ⚠️  SAFETY SKIP: $conflict (does not end with -restored suffix)"
                    $deleteFailed += $conflict
                    continue
                }
                
                Write-Host "  🗑️  Deleting: $conflict"
                try {
                    $deleteOutput = az sql db delete `
                        --subscription $SourceSubscription `
                        --resource-group $SourceResourceGroup `
                        --server $SourceServer `
                        --name $conflict `
                        --yes `
                        --no-wait 2>&1
                    
                    if ($LASTEXITCODE -eq 0) {
                        Write-Host "    ✅ Deletion initiated successfully"
                        $deleteSucceeded += $conflict
                    } else {
                        Write-Host "    ❌ Failed to delete: $deleteOutput"
                        $deleteFailed += $conflict
                    }
                } catch {
                    Write-Host "    ❌ Error: $($_.Exception.Message)"
                    $deleteFailed += $conflict
                }
            }
            
            Write-Host ""
            if ($deleteSucceeded.Count -gt 0) {
                Write-Host "⏳ Waiting for database deletions to complete..."
                Write-Host "   ℹ️  Verifying each database is fully deleted before proceeding"
                Write-Host ""
                
                # Verify each database is actually deleted (not just deletion initiated)
                $maxWaitSeconds = 120  # Maximum 2 minutes total wait
                $checkIntervalSeconds = 10
                $maxChecks = $maxWaitSeconds / $checkIntervalSeconds
                $allDeleted = $false
                
                for ($checkNum = 1; $checkNum -le $maxChecks; $checkNum++) {
                    Start-Sleep -Seconds $checkIntervalSeconds
                    $elapsedSeconds = $checkNum * $checkIntervalSeconds
                    
                    # Check if all databases are actually gone
                    $stillExist = @()
                    foreach ($dbName in $deleteSucceeded) {
                        try {
                            $dbCheck = az sql db show `
                                --subscription $SourceSubscription `
                                --resource-group $SourceResourceGroup `
                                --server $SourceServer `
                                --name $dbName `
                                --query "name" `
                                --output tsv 2>&1
                            
                            if ($LASTEXITCODE -eq 0 -and $dbCheck -and $dbCheck -notmatch "ERROR" -and $dbCheck -notmatch "not found") {
                                $stillExist += $dbName
                            }
                        } catch {
                            # Database not found - good!
                        }
                    }
                    
                    if ($stillExist.Count -eq 0) {
                        Write-Host "  ✅ All databases confirmed deleted (${elapsedSeconds}s)"
                        $allDeleted = $true
                        break
                    } else {
                        Write-Host "  ⏳ Still waiting for $($stillExist.Count) database(s) to be deleted... (${elapsedSeconds}s)"
                    }
                }
                
                if (-not $allDeleted) {
                    Write-Host ""
                    Write-Host "  ⚠️  WARNING: Some databases may not be fully deleted yet" -ForegroundColor Yellow
                    Write-Host "     Adding additional 30 second buffer..." -ForegroundColor Yellow
                    Start-Sleep -Seconds 30
                }
                
                Write-Host "✅ Database deletion process completed"
                Write-Host ""
            }
            
            if ($deleteFailed.Count -gt 0) {
                Write-Host "❌ Failed to delete $($deleteFailed.Count) database(s):"
                Write-Host "───────────────────────────────────────────────────"
                foreach ($failed in $deleteFailed) {
                    Write-Host "  • $failed"
                }
                Write-Host ""
                Write-Host "💡 These databases may be locked or require manual intervention"
                Write-Host "   ⚠️  The restore process cannot continue with these conflicts"
                return @{ HasConflicts = $true; Conflicts = $deleteFailed }
            }
            
            Write-Host ""
            return @{ HasConflicts = $false; Conflicts = @() }
        } else {
            # No Force mode - CANCEL THE RUN
            Write-Host "❌ OPERATION CANCELED: Restored databases already exist"
            Write-Host "═══════════════════════════════════════════════════"
            Write-Host ""
            Write-Host "⚠️  The following databases already exist and must be removed first:"
            Write-Host ""
            foreach ($conflict in $conflicts) {
                Write-Host "  • $conflict"
            }
            Write-Host ""
            Write-Host "📋 These are previous restore attempts (all have '-restored' suffix)."
            Write-Host ""
            Write-Host "💡 To automatically delete them and proceed, add the -Force flag:"
            Write-Host ""
            Write-Host "   -Force"
            Write-Host ""
            Write-Host "ℹ️  This is safe because:"
            Write-Host "  • Only databases ending with '-restored' will be deleted"
            Write-Host "  • These are previous restore operations, not production data"
            Write-Host "  • The script validates the suffix before any deletion"
            Write-Host ""
            Write-Host "🛑 Canceling restore operation..."
            Write-Host ""
            
            return @{ HasConflicts = $true; Conflicts = $conflicts }
        }
    }
}

function Test-RestorePointValidity {
    param (
        [array]$DatabasesToRestore,
        [DateTime]$RestorePointUtc,
        [DateTime]$RestorePointInTimezone,
        [string]$Timezone,
        [string]$SourceSubscription,
        [string]$SourceResourceGroup,
        [string]$SourceServer
    )
    
    Write-Host "`n🕐 VALIDATING RESTORE POINT"
    Write-Host "==========================="
    Write-Host ""
    
    $currentTimeUtc = (Get-Date).ToUniversalTime()
    $issues = @()
    
    # Check 1: Restore point is not in the future
    if ($RestorePointUtc -gt $currentTimeUtc) {
        Write-Host "❌ ERROR: Restore point is in the future!"
        Write-Host "   ⏰ Current time (UTC): $($currentTimeUtc.ToString('yyyy-MM-dd HH:mm:ss'))"
        Write-Host "   ⏰ Restore point (UTC): $($RestorePointUtc.ToString('yyyy-MM-dd HH:mm:ss'))"
        $issues += "Restore point is in the future"
        return @{ IsValid = $false; InvalidDatabases = @(); Issues = $issues; AdjustedRestorePoint = $null }
    }
    
    # Check 2: Query for latest available restore point (if requested time is too recent)
    # We'll check this during database validation and adjust if needed
    
    # Check 3: Validate each database's restore window
    Write-Host "   🔎 Checking restore point availability for each database..."
    Write-Host "   ⏰ Requested restore point: $($RestorePointUtc.ToString('yyyy-MM-dd HH:mm:ss')) UTC"
    Write-Host ""
    
    $invalidDatabases = @()  # Databases that are too old (ERROR - will fail)
    $databasesNeedingRecentAdjustment = @()  # Databases too recent (will auto-adjust)
    $latestDates = @()
    $validCount = 0
    
    foreach ($db in $DatabasesToRestore) {
        Write-Host "  📋 $($db.name)"
        
        try {
            # Get the database details including earliest restore date
            $dbDetails = az sql db show `
                --subscription $SourceSubscription `
                --resource-group $SourceResourceGroup `
                --server $SourceServer `
                --name $db.name `
                --query "{earliestRestoreDate: earliestRestoreDate, status: status, edition: edition}" `
                --output json | ConvertFrom-Json
            
            if ($dbDetails.earliestRestoreDate) {
                $earliestRestore = [DateTime]::Parse($dbDetails.earliestRestoreDate)
                
                # Calculate latest available restore point (current time minus 10 minutes for safety)
                # Azure SQL continuous backup is typically 5-10 minutes behind
                $latestSafeRestore = $currentTimeUtc.AddMinutes(-10)
                $latestDates += $latestSafeRestore
                
                if ($RestorePointUtc -lt $earliestRestore) {
                    # Too old - FAIL (user error - requested point outside retention window)
                    Write-Host "    ❌ ERROR: Requested time is outside retention window"
                    Write-Host "       📅 Earliest available:  $($earliestRestore.ToString('yyyy-MM-dd HH:mm:ss')) UTC"
                    Write-Host "       📅 Requested restore:   $($RestorePointUtc.ToString('yyyy-MM-dd HH:mm:ss')) UTC"
                    $retentionDays = [math]::Round(($currentTimeUtc - $earliestRestore).TotalDays, 1)
                    Write-Host "       📊 Retention window:    $retentionDays days"
                    $invalidDatabases += @{
                        Name = $db.name
                        EarliestRestore = $earliestRestore
                        RequestedRestore = $RestorePointUtc
                        RetentionDays = $retentionDays
                    }
                } elseif ($RestorePointUtc -gt $latestSafeRestore) {
                    # Too recent - AUTO-ADJUST (Azure backup propagation delay)
                    Write-Host "    ⚠️  Requested time is too recent (will auto-adjust)"
                    Write-Host "       ⏰ Latest safe point:  $($latestSafeRestore.ToString('yyyy-MM-dd HH:mm:ss')) UTC"
                    Write-Host "       ⏰ Requested restore:  $($RestorePointUtc.ToString('yyyy-MM-dd HH:mm:ss')) UTC"
                    $databasesNeedingRecentAdjustment += @{
                        Name = $db.name
                        LatestSafeRestore = $latestSafeRestore
                        RequestedRestore = $RestorePointUtc
                    }
                } else {
                    $retentionDays = [math]::Round(($currentTimeUtc - $earliestRestore).TotalDays, 1)
                    Write-Host "    ✅ Valid (retention: $retentionDays days available)"
                    $validCount++
                }
            } else {
                Write-Host "    ⚠️  WARNING: Could not determine earliest restore date"
                $validCount++  # Assume valid if we can't determine
            }
            
        } catch {
            Write-Host "    ⚠️  WARNING: Error checking restore availability: $($_.Exception.Message)"
            $validCount++  # Assume valid if check fails
        }
    }
    
    Write-Host ""
    
    # Check for databases that are too old (ERROR - will fail)
    if ($invalidDatabases.Count -gt 0) {
        Write-Host "❌ RESTORE POINT VALIDATION FAILED"
        Write-Host "───────────────────────────────────────────────────"
        Write-Host "⚠️  Requested restore point is outside retention window for $($invalidDatabases.Count) database(s)"
        Write-Host ""
        
        foreach ($invalid in $invalidDatabases) {
            Write-Host "  • $($invalid.Name)"
            Write-Host "    📅 Earliest available: $($invalid.EarliestRestore.ToString('yyyy-MM-dd HH:mm:ss')) UTC"
            Write-Host "    📅 Requested restore:  $($invalid.RequestedRestore.ToString('yyyy-MM-dd HH:mm:ss')) UTC"
            Write-Host "    📊 Retention window:   $($invalid.RetentionDays) days"
            Write-Host ""
        }
        
        Write-Host "💡 Solutions:"
        Write-Host "   1️⃣  Choose a more recent restore point within the retention window"
        Write-Host "   2️⃣  Check if long-term backup retention (LTR) is available"
        Write-Host "   3️⃣  Contact Azure support for backup recovery assistance"
        Write-Host ""
        
        return @{ 
            IsValid = $false
            NeedsAdjustment = $false
            AdjustedRestorePointUtc = $null
            AdjustedRestorePointInTimezone = $null
            DatabasesAdjusted = @()
            InvalidDatabases = $invalidDatabases
            Issues = $issues
        }
    }
    
    # Check for databases that are too recent (will auto-adjust)
    if ($databasesNeedingRecentAdjustment.Count -gt 0) {
        Write-Host "⚠️  RESTORE POINT ADJUSTMENT (TOO RECENT)"
        Write-Host "───────────────────────────────────────────────────"
        Write-Host "⚠️  Requested restore point is too recent for $($databasesNeedingRecentAdjustment.Count) database(s)"
        Write-Host "ℹ️  Azure backups typically have a 5-10 minute propagation delay"
        Write-Host ""
        
        # Use the EARLIEST of all latest safe dates (oldest common safe point)
        # This ensures all databases have backups ready
        $adjustedRestorePointUtc = ($latestDates | Measure-Object -Minimum).Minimum
        
        Write-Host "📊 Auto-Adjusting to Latest Safe Restore Point:"
        Write-Host "   ⏰ Original request: $($RestorePointUtc.ToString('yyyy-MM-dd HH:mm:ss')) UTC"
        Write-Host "   ✅ Adjusted to:      $($adjustedRestorePointUtc.ToString('yyyy-MM-dd HH:mm:ss')) UTC"
        Write-Host "   ℹ️  (Safe buffer for backup propagation)"
        Write-Host ""
        
        # Convert adjusted time to timezone
        try {
            $timezoneInfo = [System.TimeZoneInfo]::FindSystemTimeZoneById($Timezone)
            $adjustedRestorePointInTimezone = [System.TimeZoneInfo]::ConvertTimeFromUtc($adjustedRestorePointUtc, $timezoneInfo)
            Write-Host "   🌍 In $($Timezone): $($adjustedRestorePointInTimezone.ToString('yyyy-MM-dd HH:mm:ss'))"
        } catch {
            $adjustedRestorePointInTimezone = $adjustedRestorePointUtc
        }
        
        Write-Host ""
        Write-Host "✅ Will proceed with adjusted restore point"
        Write-Host ""
        
        return @{ 
            IsValid = $true
            NeedsAdjustment = $true
            AdjustedRestorePointUtc = $adjustedRestorePointUtc
            AdjustedRestorePointInTimezone = $adjustedRestorePointInTimezone
            DatabasesAdjusted = $databasesNeedingRecentAdjustment
            InvalidDatabases = @()
            Issues = @()
        }
    }
    
    # All databases are valid for the requested restore point
    Write-Host "📊 Validation Summary:"
    Write-Host "   ✅ All $($DatabasesToRestore.Count) databases can be restored to requested point"
    Write-Host ""
    Write-Host "✅ Restore point validation passed"
    Write-Host ""
    
    return @{ 
        IsValid = $true
        NeedsAdjustment = $false
        AdjustedRestorePointUtc = $null
        AdjustedRestorePointInTimezone = $null
        DatabasesAdjusted = @()
        InvalidDatabases = @()
        Issues = @()
    }
}

function Restore-SingleDatabase {
    param (
        [string]$DatabaseName,
        [string]$SourceSubscription,
        [string]$SourceResourceGroup,
        [string]$SourceServer,
        [string]$SourceServerFQDN,
        [DateTime]$RestorePointUtc,
        [DateTime]$RestorePointInTimezone,
        [string]$Timezone,
        [string]$AccessToken,
        [int]$MaxWaitMinutes
    )
    
    $restoredDbName = "$DatabaseName-restored"
    
    Write-Host "`n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    Write-Host "📋 Restoring: $DatabaseName"
    Write-Host "   🎯 Target: $restoredDbName"
    Write-Host "   ⏰ Restore Point: $($RestorePointInTimezone.ToString('yyyy-MM-dd HH:mm:ss')) ($Timezone)"
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # Start the restore operation
    Write-Host "  🔄 Initiating restore operation..."
    
    try {
        # Capture both stdout and stderr
        $restoreOutput = az sql db restore `
            --dest-name $restoredDbName `
            --edition Standard `
            --name $DatabaseName `
            --resource-group $SourceResourceGroup `
            --server $SourceServer `
            --subscription $SourceSubscription `
            --service-objective S3 `
            --time $($RestorePointUtc.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')) `
            --no-wait 2>&1
        
        # Check for errors in output or exit code
        if ($LASTEXITCODE -ne 0 -or $restoreOutput -match "ERROR:") {
            $errorMessage = if ($restoreOutput -match "ERROR: (.+)") { $matches[1] } else { "Failed to initiate restore operation" }
            Write-Host "  ❌ Failed to initiate restore"
            return @{
                Database = $restoredDbName
                Status = "failed"
                Error = $errorMessage
                Phase = "initiation"
            }
        }
        
        Write-Host "  ✅ Restore operation initiated"
        
    } catch {
        Write-Host "  ❌ Error initiating restore: $($_.Exception.Message)"
        return @{
            Database = $restoredDbName
            Status = "failed"
            Error = $_.Exception.Message
            Phase = "initiation"
        }
    }
    
    # Wait for restore to complete
    Write-Host "  ⏳ Waiting for restore to complete..."
    
    $startTime = Get-Date
    $maxIterations = $MaxWaitMinutes * 2  # Check every 30 seconds
    
    for ($i = 1; $i -le $maxIterations; $i++) {
        $elapsed = (Get-Date) - $startTime
        $elapsedMinutes = [math]::Round($elapsed.TotalMinutes, 1)
        
        # Check if we've exceeded the max wait time
        if ($elapsedMinutes -ge $MaxWaitMinutes) {
            Write-Host "  ❌ Restore failed to complete within ${MaxWaitMinutes} minutes"
            return @{
                Database = $restoredDbName
                Status = "failed"
                Error = "Timeout waiting for restore to complete"
                Phase = "waiting"
                Elapsed = $MaxWaitMinutes
            }
        }
        
        # Try Azure CLI check first (faster)
        try {
            $azResult = az sql db show `
                --name $restoredDbName `
                --resource-group $SourceResourceGroup `
                --server $SourceServer `
                --subscription $SourceSubscription `
                --query "status" `
                --output tsv 2>$null
            
            if ($azResult -eq "Online") {
                Write-Host "  ✅ Database restored successfully (took ${elapsedMinutes} minutes)"
                return @{
                    Database = $restoredDbName
                    Status = "success"
                    Elapsed = $elapsedMinutes
                }
            }
        } catch {
            # Azure CLI check failed, will try SQL query
        }
        
        # Try SQL query as backup
        try {
            $statusQuery = "SELECT state_desc FROM sys.databases WHERE name = '$restoredDbName'"
            $result = Invoke-Sqlcmd `
                -AccessToken $AccessToken `
                -ServerInstance $SourceServerFQDN `
                -Query $statusQuery `
                -ConnectionTimeout 15 `
                -QueryTimeout 30 `
                -ErrorAction SilentlyContinue
            
            if ($result -and $result.state_desc -eq "ONLINE") {
                Write-Host "  ✅ Database restored successfully (took ${elapsedMinutes} minutes)"
                return @{
                    Database = $restoredDbName
                    Status = "success"
                    Elapsed = $elapsedMinutes
                }
            }
        } catch {
            # SQL query also failed, continue waiting
        }
        
        # Show progress every 2 minutes
        if ($i % 4 -eq 0) {
            Write-Host "  ⏳ Still restoring... (${elapsedMinutes} min elapsed)"
        }
        
        Start-Sleep -Seconds 30
    }
    
    # Timeout reached
    $finalElapsed = (Get-Date) - $startTime
    $finalElapsedMinutes = [math]::Round($finalElapsed.TotalMinutes, 1)
    Write-Host "  ❌ Timeout: Restore failed to complete (${finalElapsedMinutes} min)"
    return @{
        Database = $restoredDbName
        Status = "failed"
        Error = "Timeout"
        Phase = "waiting"
        Elapsed = $finalElapsedMinutes
    }
}

# ============================================================================
# MAIN SCRIPT
# ============================================================================

Write-Host "`n============================"
Write-Host "🔄 Restore Point In Time"
Write-Host "============================`n"

# Convert datetime to UTC
Write-Host "🕐 Using timezone: $Timezone"
$timeConversion = Convert-ToUTCRestorePoint -RestoreDateTime $RestoreDateTime -Timezone $Timezone
$restore_point_in_timezone = $timeConversion.RestorePointInTimezone
$restore_point_utc = $timeConversion.RestorePointUtc

# Query for source SQL server
Write-Host "`n🔍 Finding source SQL server..."
$graph_query = "
  resources
  | where type =~ 'microsoft.sql/servers'
  | where tags.Environment == '$source' and tags.Type == 'Primary'
  | project name, resourceGroup, subscriptionId, fqdn = properties.fullyQualifiedDomainName
"
$server = az graph query -q $graph_query --query "data" --first 1000 | ConvertFrom-Json

if (-not $server -or $server.Count -eq 0) {
    Write-Host "❌ No SQL server found for environment: $source"
    $global:LASTEXITCODE = 1
    throw "No SQL server found for environment: $source"
}

$source_subscription = $server[0].subscriptionId
$source_server = $server[0].name
$source_rg = $server[0].resourceGroup
$source_fqdn = $server[0].fqdn

# Determine resource URL
if ($source_fqdn -match "database.windows.net") {
    $resourceUrl = "https://database.windows.net"
} else {
    $resourceUrl = "https://database.usgovcloudapi.net"
}

# Parse server name components
$source_split = $source_server -split "-"
$source_product = $source_split[1]
$source_location = $source_split[-1]
$source_type = $source_split[2]
$source_environment = $source_split[3]

# Get access token
$AccessToken = (az account get-access-token --resource="$resourceUrl" --query accessToken --output tsv)

# Display configuration
Write-Host "📋 RESTORE CONFIGURATION"
Write-Host "========================"
Write-Host "🖥️  Source Server: $source_server"
Write-Host "🌍 Source Environment: $source"
Write-Host "📦 Source Namespace: $SourceNamespace"
Write-Host "⏰ Restore Point: $($restore_point_in_timezone.ToString('yyyy-MM-dd HH:mm:ss')) ($Timezone)"
Write-Host "   UTC Time: $($restore_point_utc.ToString('yyyy-MM-dd HH:mm:ss')) UTC"
Write-Host ""

# Get list of databases from source SQL server
Write-Host "🔍 Fetching databases from source server..."

if ($SourceNamespace -eq "manufacturo") {
    # Special handling for "manufacturo" - get all databases (no ClientName filtering)
    $dbs = az sql db list `
        --subscription $source_subscription `
        --resource-group $source_rg `
        --server $source_server `
        --query "[?tags.ClientName == '']" | ConvertFrom-Json
} else {
    $dbs = az sql db list `
        --subscription $source_subscription `
        --resource-group $source_rg `
        --server $source_server `
        --query "[?tags.ClientName == '$SourceNamespace']" | ConvertFrom-Json
}

if (-not $dbs -or $dbs.Count -eq 0) {
    Write-Host "❌ No databases found with provided parameters"
    $global:LASTEXITCODE = 1
    throw "No databases found with provided parameters"
}

Write-Host "✅ Found $($dbs.Count) databases on source server"
Write-Host ""

# ============================================================================
# ANALYZE DATABASES
# ============================================================================

Write-Host "📊 ANALYZING DATABASES"
Write-Host "======================"

$databasesToRestore = @()

foreach ($db in $dbs) {
    $service = Get-ServiceFromDatabase -Database $db
    
    Write-Host "  📋 Analyzing: $($db.name) (Service: $service)"
    
    if (-not (Should-RestoreDatabase -DatabaseName $db.name -Service $service)) {
        if ($db.name.Contains("master")) {
            Write-Host "    ⏭️  Skipping: System database"
        } elseif ($db.name.Contains("Copy")) {
            Write-Host "    ⏭️  Skipping: Copy database"
        } elseif ($db.name.Contains("restored")) {
            Write-Host "    ⏭️  Skipping: Already restored"
        } elseif ($db.name.Contains("landlord")) {
            Write-Host "    ⏭️  Skipping: Landlord service"
        }
        continue
    }
    
    # Check if database matches expected pattern
    $matchesPattern = Test-DatabaseMatchesPattern `
        -DatabaseName $db.name `
        -Service $service `
        -SourceNamespace $SourceNamespace `
        -SourceProduct $source_product `
        -SourceType $source_type `
        -SourceEnvironment $source_environment `
        -SourceLocation $source_location
    
    if ($matchesPattern) {
        Write-Host "    ✅ Will restore to: $($db.name)-restored"
        $databasesToRestore += $db
    } else {
        Write-Host "    ⏭️  Skipping: Pattern mismatch"
    }
}

Write-Host ""
Write-Host "📊 ANALYSIS SUMMARY"
Write-Host "==================="
Write-Host "📦 Total databases found: $($dbs.Count)"
Write-Host "✅ Databases to restore: $($databasesToRestore.Count)"
Write-Host "⏭️  Databases skipped: $($dbs.Count - $databasesToRestore.Count)"
Write-Host ""

if ($databasesToRestore.Count -eq 0) {
    Write-Host "⚠️  No databases to restore"
    exit 0
}

# ============================================================================
# VALIDATE AND ADJUST RESTORE POINT IF NEEDED
# ============================================================================

$validationResult = Test-RestorePointValidity `
    -DatabasesToRestore $databasesToRestore `
    -RestorePointUtc $restore_point_utc `
    -RestorePointInTimezone $restore_point_in_timezone `
    -Timezone $Timezone `
    -SourceSubscription $source_subscription `
    -SourceResourceGroup $source_rg `
    -SourceServer $source_server

if (-not $validationResult.IsValid) {
    Write-Host "❌ Cannot proceed: Restore point validation failed"
    Write-Host "   ⚠️  The requested restore point is invalid (too recent or in the future)"
    $global:LASTEXITCODE = 1
    throw "Restore point validation failed: The requested restore point is invalid (too recent or in the future)"
}

# If the restore point was adjusted (too old), use the adjusted value
if ($validationResult.NeedsAdjustment) {
    Write-Host "📝 Using adjusted restore point for all operations"
    $restore_point_utc = $validationResult.AdjustedRestorePointUtc
    $restore_point_in_timezone = $validationResult.AdjustedRestorePointInTimezone
}

# ============================================================================
# CHECK FOR EXISTING DATABASES
# ============================================================================

$conflictCheck = Test-ExistingRestoredDatabases `
    -DatabasesToRestore $databasesToRestore `
    -SourceSubscription $source_subscription `
    -SourceResourceGroup $source_rg `
    -SourceServer $source_server `
    -ForceDelete $Force

if ($conflictCheck.HasConflicts) {
    if ($DryRun) {
        Write-Host "⚠️  DRY RUN WARNING: Conflicts detected with existing databases" -ForegroundColor Yellow
        Write-Host "⚠️  In production, this would fail unless -Force is used" -ForegroundColor Yellow
        Write-Host "⚠️  Continuing dry run to show what would happen..." -ForegroundColor Yellow
        Write-Host ""
        # Track this failure for final dry run summary
        $script:DryRunHasFailures = $true
        $script:DryRunFailureReasons += "Conflicts detected with existing databases (use -Force to override)"
    } else {
        Write-Host "❌ Cannot proceed: Conflicts detected with existing databases"
        Write-Host "⚠️  Please resolve conflicts before running restore operation"
        $global:LASTEXITCODE = 1
        throw "Conflicts detected with existing databases - please resolve conflicts before running restore operation"
    }
}

# ============================================================================
# DRY RUN MODE
# ============================================================================

if ($DryRun) {
    Write-Host "🔍 DRY RUN: Databases that would be restored:"
    Write-Host ""
    foreach ($db in $databasesToRestore) {
        Write-Host "  • $($db.name) → $($db.name)-restored"
    }
    Write-Host ""
    Write-Host "⏰ Restore Point: $($restore_point_in_timezone.ToString('yyyy-MM-dd HH:mm:ss')) ($Timezone)"
    Write-Host "   UTC Time: $($restore_point_utc.ToString('yyyy-MM-dd HH:mm:ss')) UTC"
    Write-Host ""
    Write-Host "🔍 DRY RUN: No actual operations performed"
    Write-Host ""
    
    # Check if there were any validation failures during dry run
    if ($script:DryRunHasFailures) {
        Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Red
        Write-Host "❌ DRY RUN COMPLETED WITH WARNINGS" -ForegroundColor Red
        Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Red
        Write-Host ""
        Write-Host "⚠️  The following issues would cause production run to FAIL:" -ForegroundColor Yellow
        Write-Host ""
        foreach ($reason in $script:DryRunFailureReasons) {
            Write-Host "   • $reason" -ForegroundColor Yellow
        }
        Write-Host ""
        Write-Host "🔧 Please resolve these issues before running in production mode" -ForegroundColor Yellow
        Write-Host ""
        $global:LASTEXITCODE = 1
        exit 1
    } else {
        Write-Host "✅ DRY RUN COMPLETED SUCCESSFULLY - No issues detected" -ForegroundColor Green
        exit 0
    }
}

# ============================================================================
# RESTORE DATABASES (PARALLEL)
# ============================================================================

Write-Host "🚀 STARTING DATABASE RESTORE PROCESS"
Write-Host "====================================="
Write-Host "📦 Processing $($databasesToRestore.Count) databases in parallel"
Write-Host "⚙️  Throttle limit: $ThrottleLimit"
Write-Host "⏰ Max wait time per database: $MaxWaitMinutes minutes"
Write-Host ""

# Start all restore operations in parallel
Write-Host "🔄 Initiating restore operations..."
$restored_dbs = $databasesToRestore | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
    $source_subscription = $using:source_subscription
    $source_rg = $using:source_rg
    $source_server = $using:source_server
    $restore_point_utc = $using:restore_point_utc
    $Timezone = $using:Timezone
    $restore_point_in_timezone = $using:restore_point_in_timezone
    
    $db = $_
    $db_name = "$($db.name)-restored"
    
    Write-Host "🔄 Starting restore: $($db.name) → $db_name to $($restore_point_in_timezone.ToString('yyyy-MM-dd HH:mm:ss')) ($Timezone)"
    
    # Start the restore
    az sql db restore `
        --dest-name $db_name `
        --edition Standard `
        --name $db.name `
        --resource-group $source_rg `
        --server $source_server `
        --subscription $source_subscription `
        --service-objective S3 `
        --time $($restore_point_utc.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')) `
        --no-wait
    
    # Return the database name for monitoring
    $db_name
}

Write-Host "`n⏳ Waiting for databases to restore..."
Write-Host "ℹ️  This may take several minutes. Progress will be shown below:"
Write-Host ""

# Monitor all restore operations in parallel
$results = $restored_dbs | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
    $source_subscription = $using:source_subscription
    $source_server = $using:source_server
    $source_rg = $using:source_rg
    $source_fqdn = $using:source_fqdn
    $AccessToken = $using:AccessToken
    $db_name = $_
    $start_time = Get-Date
    $max_wait_minutes = $using:MaxWaitMinutes
    $max_iterations = $max_wait_minutes * 2  # 30 seconds per iteration
    
    for ($i = 1; $i -le $max_iterations; $i++) {
        $elapsed = (Get-Date) - $start_time
        $elapsed_minutes = [math]::Round($elapsed.TotalMinutes, 1)
        
        # Check if we've exceeded the max wait time
        if ($elapsed_minutes -ge $max_wait_minutes) {
            Write-Host "❌ $db_name failed to restore within ${max_wait_minutes} minutes"
            return @{ Database = $db_name; Status = "failed"; Elapsed = $max_wait_minutes; Error = "Timeout" }
        }
        
        # Quick Azure CLI check first (faster than SQL)
        try {
            $az_result = az sql db show `
                --name $db_name `
                --resource-group $source_rg `
                --server $source_server `
                --subscription $source_subscription `
                --query "status" `
                --output tsv 2>$null
            
            if ($az_result -eq "Online") {
                Write-Host "✅ $db_name restored successfully (${elapsed_minutes} min)"
                return @{ Database = $db_name; Status = "success"; Elapsed = $elapsed_minutes }
            }
        } catch {
            # Azure CLI check failed, try SQL check
        }
        
        # Try SQL query as fallback
        try {
            $result = Invoke-Sqlcmd `
                -AccessToken $AccessToken `
                -ServerInstance $source_fqdn `
                -Query "SELECT state_desc FROM sys.databases WHERE name = '$db_name'" `
                -ConnectionTimeout 15 `
                -QueryTimeout 30 `
                -ErrorAction SilentlyContinue
            
            if ($result -and $result.state_desc -eq "ONLINE") {
                Write-Host "✅ $db_name restored successfully (${elapsed_minutes} min)"
                return @{ Database = $db_name; Status = "success"; Elapsed = $elapsed_minutes }
            }
        } catch {
            # SQL query also failed, continue waiting
        }
        
        # Show progress every 2 minutes
        if ($i % 4 -eq 0) {
            Write-Host "⏳ $db_name still restoring... (${elapsed_minutes} min elapsed)"
        }
        
        Start-Sleep -Seconds 30
    }
    
    # If we reach here, we've exhausted all iterations without success
    $final_elapsed = (Get-Date) - $start_time
    $final_elapsed_minutes = [math]::Round($final_elapsed.TotalMinutes, 1)
    Write-Host "❌ $db_name failed to restore within ${max_wait_minutes} minutes (${final_elapsed_minutes} min elapsed)"
    return @{ Database = $db_name; Status = "failed"; Elapsed = $final_elapsed_minutes; Error = "Timeout" }
}

# Calculate success/failure counts
$successCount = ($results | Where-Object { $_.Status -eq "success" }).Count
$failCount = ($results | Where-Object { $_.Status -eq "failed" }).Count

# ============================================================================
# FINAL SUMMARY
# ============================================================================

Write-Host "`n"
Write-Host "═══════════════════════════════════════════════════"
Write-Host "           📊 FINAL RESTORE SUMMARY"
Write-Host "═══════════════════════════════════════════════════"
Write-Host ""

if ($successCount -gt 0) {
    Write-Host "✅ SUCCESSFUL RESTORES: $successCount"
    Write-Host "───────────────────────────────────────────────────"
    $results | Where-Object { $_.Status -eq "success" } | ForEach-Object {
        Write-Host "  ✅ $($_.Database) ($($_.Elapsed) min)"
    }
    Write-Host ""
}

if ($failCount -gt 0) {
    Write-Host "❌ FAILED RESTORES: $failCount"
    Write-Host "───────────────────────────────────────────────────"
    $results | Where-Object { $_.Status -eq "failed" } | ForEach-Object {
        Write-Host "  ❌ $($_.Database)"
        Write-Host "     ⚠️  Phase: $($_.Phase)"
        Write-Host "     ⚠️  Error: $($_.Error)"
    }
    Write-Host ""
    Write-Host "💡 Please investigate failed restores and retry if needed"
    $global:LASTEXITCODE = 1
    throw "Database restore workflow failed: $failCount out of $($results.Count) databases failed"
}

Write-Host "═══════════════════════════════════════════════════"
Write-Host "🎉 All database restores completed successfully!"
Write-Host "═══════════════════════════════════════════════════"
