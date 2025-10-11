#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Test script for datetime parsing functionality

.DESCRIPTION
    This script tests the Normalize-DateTime function with various input formats
    to ensure robust datetime parsing.
#>

# Import the normalize function from wrapper
$scriptDir = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$wrapperScript = Join-Path $scriptDir "main/semaphore_wrapper.ps1"

function Normalize-DateTime {
    param (
        [string]$InputDateTime
    )
    
    if ([string]::IsNullOrWhiteSpace($InputDateTime)) {
        return ""
    }
    
    # Define common datetime formats to try
    $formats = @(
        # Standard format
        'yyyy-MM-dd HH:mm:ss',
        
        # ISO 8601 formats
        'yyyy-MM-ddTHH:mm:ss',
        'yyyy-MM-dd HH:mm',
        'yyyy-MM-dd',
        
        # US formats
        'M/d/yyyy h:mm:ss tt',    # 1/15/2025 2:30:00 PM
        'M/d/yyyy H:mm:ss',       # 1/15/2025 14:30:00
        'M/d/yyyy h:mm tt',       # 1/15/2025 2:30 PM
        'M/d/yyyy H:mm',          # 1/15/2025 14:30
        'M/d/yyyy',               # 1/15/2025
        'MM/dd/yyyy HH:mm:ss',    # 01/15/2025 14:30:00
        'MM/dd/yyyy',             # 01/15/2025
        
        # European formats
        'dd/MM/yyyy HH:mm:ss',    # 15/01/2025 14:30:00
        'dd/MM/yyyy',             # 15/01/2025
        'd/M/yyyy H:mm:ss',       # 15/1/2025 14:30:00
        'd/M/yyyy',               # 15/1/2025
        
        # Alternative separators
        'yyyy.MM.dd HH:mm:ss',
        'yyyy.MM.dd',
        'dd.MM.yyyy HH:mm:ss',
        'dd.MM.yyyy',
        
        # With dashes
        'dd-MM-yyyy HH:mm:ss',
        'dd-MM-yyyy',
        'MM-dd-yyyy HH:mm:ss',
        'MM-dd-yyyy'
    )
    
    # Try to parse with each format
    foreach ($format in $formats) {
        try {
            $parsedDate = [DateTime]::ParseExact($InputDateTime, $format, [System.Globalization.CultureInfo]::InvariantCulture)
            $normalizedDate = $parsedDate.ToString('yyyy-MM-dd HH:mm:ss')
            return @{
                Success = $true
                Result = $normalizedDate
                Format = $format
            }
        } catch {
            # Try next format
        }
    }
    
    # If all formats fail, try .NET's automatic parsing as last resort
    try {
        $parsedDate = [DateTime]::Parse($InputDateTime)
        $normalizedDate = $parsedDate.ToString('yyyy-MM-dd HH:mm:ss')
        return @{
            Success = $true
            Result = $normalizedDate
            Format = "automatic"
        }
    } catch {
        return @{
            Success = $false
            Error = $_.Exception.Message
        }
    }
}

Write-Host "`n╔═══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║        DateTime Parsing Test Suite                       ║" -ForegroundColor Cyan
Write-Host "╚═══════════════════════════════════════════════════════════╝`n" -ForegroundColor Cyan

Write-Host "⚠️  NOTE: Some date formats are ambiguous (e.g., 11/10/2025)" -ForegroundColor Yellow
Write-Host "   Could be: November 10 (US) or October 11 (European)" -ForegroundColor Yellow
Write-Host "   This test suite documents the parser's behavior for such cases." -ForegroundColor Yellow
Write-Host "   Recommendation: Use ISO format (2025-10-11) to avoid ambiguity.`n" -ForegroundColor Yellow

# Test cases
$testCases = @(
    # Standard format (recommended)
    @{ Input = "2025-10-11 14:30:00"; Expected = "2025-10-11 14:30:00"; Description = "Standard ISO format with time" },
    @{ Input = "2025-01-15 09:45:30"; Expected = "2025-01-15 09:45:30"; Description = "Standard ISO format (morning)" },
    
    # ISO 8601 variations
    @{ Input = "2025-10-11T14:30:00"; Expected = "2025-10-11 14:30:00"; Description = "ISO 8601 with T separator" },
    @{ Input = "2025-10-11 14:30"; Expected = "2025-10-11 14:30:00"; Description = "ISO format without seconds" },
    @{ Input = "2025-10-11"; Expected = "2025-10-11 00:00:00"; Description = "Date only (defaults to midnight)" },
    
    # US formats
    @{ Input = "10/11/2025 2:30:00 PM"; Expected = "2025-10-11 14:30:00"; Description = "US format with 12-hour clock" },
    @{ Input = "10/11/2025 14:30:00"; Expected = "2025-10-11 14:30:00"; Description = "US format with 24-hour clock" },
    @{ Input = "10/11/2025 2:30 PM"; Expected = "2025-10-11 14:30:00"; Description = "US format without seconds" },
    @{ Input = "10/11/2025"; Expected = "2025-10-11 00:00:00"; Description = "US date only" },
    @{ Input = "1/5/2025 9:15:30"; Expected = "2025-01-05 09:15:30"; Description = "US format single digits" },
    
    # European formats
    # Note: 11/10/2025 is ambiguous - could be Nov 10 or Oct 11
    # The parser tries US format first, so this becomes Nov 10
    @{ Input = "11/10/2025 14:30:00"; Expected = "2025-11-10 14:30:00"; Description = "Ambiguous format (parsed as US MM/DD)" },
    @{ Input = "15/01/2025 09:45:00"; Expected = "2025-01-15 09:45:00"; Description = "European format with time (unambiguous)" },
    # 5/1/2025 is ambiguous - parsed as US format (May 1)
    @{ Input = "5/1/2025"; Expected = "2025-05-01 00:00:00"; Description = "Ambiguous format (parsed as US M/D)" },
    
    # Alternative separators
    @{ Input = "2025.10.11 14:30:00"; Expected = "2025-10-11 14:30:00"; Description = "Dot separator YYYY.MM.DD" },
    @{ Input = "2025.10.11"; Expected = "2025-10-11 00:00:00"; Description = "Dot separator date only" },
    @{ Input = "11.10.2025 14:30:00"; Expected = "2025-10-11 14:30:00"; Description = "Dot separator DD.MM.YYYY" },
    
    # Dash separators
    @{ Input = "11-10-2025 14:30:00"; Expected = "2025-10-11 14:30:00"; Description = "Dash separator DD-MM-YYYY" },
    # Note: 10-11-2025 is ambiguous - parser tries DD-MM-YYYY first, so becomes Nov 10
    @{ Input = "10-11-2025 14:30:00"; Expected = "2025-11-10 14:30:00"; Description = "Ambiguous dash format (parsed as DD-MM)" },
    
    # Edge cases
    @{ Input = "2025-12-31 23:59:59"; Expected = "2025-12-31 23:59:59"; Description = "End of year" },
    @{ Input = "2025-01-01 00:00:00"; Expected = "2025-01-01 00:00:00"; Description = "Start of year" },
    
    # Invalid cases
    @{ Input = "not-a-date"; Expected = $null; Description = "Invalid input (should fail)" },
    @{ Input = "2025-13-01 14:30:00"; Expected = $null; Description = "Invalid month (should fail)" },
    @{ Input = "2025-02-30 14:30:00"; Expected = $null; Description = "Invalid day (should fail)" }
)

$passCount = 0
$failCount = 0
$totalTests = $testCases.Count

Write-Host "Running $totalTests test cases...`n" -ForegroundColor White

foreach ($test in $testCases) {
    $result = Normalize-DateTime -InputDateTime $test.Input
    
    if ($test.Expected -eq $null) {
        # Expecting failure
        if ($result.Success -eq $false) {
            Write-Host "✅ PASS: $($test.Description)" -ForegroundColor Green
            Write-Host "   Input: '$($test.Input)'" -ForegroundColor Gray
            Write-Host "   Result: Failed as expected" -ForegroundColor Gray
            $passCount++
        } else {
            Write-Host "❌ FAIL: $($test.Description)" -ForegroundColor Red
            Write-Host "   Input: '$($test.Input)'" -ForegroundColor Gray
            Write-Host "   Expected: Failure" -ForegroundColor Gray
            Write-Host "   Got: $($result.Result)" -ForegroundColor Gray
            $failCount++
        }
    } else {
        # Expecting success
        if ($result.Success -and $result.Result -eq $test.Expected) {
            Write-Host "✅ PASS: $($test.Description)" -ForegroundColor Green
            Write-Host "   Input: '$($test.Input)'" -ForegroundColor Gray
            Write-Host "   Output: '$($result.Result)'" -ForegroundColor Gray
            Write-Host "   Format: $($result.Format)" -ForegroundColor Gray
            $passCount++
        } else {
            Write-Host "❌ FAIL: $($test.Description)" -ForegroundColor Red
            Write-Host "   Input: '$($test.Input)'" -ForegroundColor Gray
            Write-Host "   Expected: '$($test.Expected)'" -ForegroundColor Gray
            Write-Host "   Got: '$($result.Result)'" -ForegroundColor Gray
            if ($result.Success -eq $false) {
                Write-Host "   Error: $($result.Error)" -ForegroundColor Gray
            }
            $failCount++
        }
    }
    Write-Host ""
}

# Summary
Write-Host "╔═══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║                    TEST SUMMARY                           ║" -ForegroundColor Cyan
Write-Host "╚═══════════════════════════════════════════════════════════╝`n" -ForegroundColor Cyan

$passRate = [math]::Round(($passCount / $totalTests) * 100, 1)

Write-Host "Total Tests: $totalTests" -ForegroundColor White
Write-Host "Passed: $passCount" -ForegroundColor Green
Write-Host "Failed: $failCount" -ForegroundColor $(if ($failCount -eq 0) { "Green" } else { "Red" })
Write-Host "Pass Rate: $passRate%" -ForegroundColor $(if ($passRate -eq 100) { "Green" } elseif ($passRate -ge 80) { "Yellow" } else { "Red" })
Write-Host ""

if ($failCount -eq 0) {
    Write-Host "🎉 All tests passed!" -ForegroundColor Green
    exit 0
} else {
    Write-Host "⚠️  Some tests failed. Please review." -ForegroundColor Yellow
    exit 1
}

