param(
    [string]$Source,
    [string]$Destination,
    [switch]$DryRun,
    [int]$MaxWaitMinutes = 60
)

Write-Host "✅ Test script executed successfully!" -ForegroundColor Green
Write-Host "Parameters received:" -ForegroundColor Cyan
Write-Host "  Source: '$Source'" -ForegroundColor Gray
Write-Host "  Destination: '$Destination'" -ForegroundColor Gray
Write-Host "  DryRun: $DryRun" -ForegroundColor Gray
Write-Host "  MaxWaitMinutes: $MaxWaitMinutes" -ForegroundColor Gray

exit 0

