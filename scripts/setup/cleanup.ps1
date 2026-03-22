#!/usr/bin/env pwsh
# Cleanup old redundant files from AzureSOC repo
# These were standalone scripts that are now integrated into master-deploy.ps1

$filesToDelete = @(
    "scripts/setup/configure-ad-part1.ps1",
    "scripts/setup/configure-ad-part2.ps1",
    "scripts/setup/deploy.ps1",
    "scripts/setup/fix-splunk-vm.ps1",
    "scripts/setup/install-splunk-forwarder.ps1",
    "scripts/setup/install-splunk.sh",
    "scripts/setup/install-sysmon.ps1",
    "instructions.txt"
)

foreach ($f in $filesToDelete) {
    $path = Join-Path $PSScriptRoot "..\..\$f"
    if (Test-Path $path) {
        Remove-Item $path -Force
        Write-Host "  Deleted: $f" -ForegroundColor Gray
    }
}

# Remove empty placeholder dirs
$emptyDirs = @(
    "scripts/automation/logic-apps",
    "scripts/automation/power-automate"
)
foreach ($d in $emptyDirs) {
    $path = Join-Path $PSScriptRoot "..\..\$d"
    if (Test-Path $path) {
        Remove-Item $path -Recurse -Force
        Write-Host "  Deleted: $d/" -ForegroundColor Gray
    }
}
# Remove empty automation dir if empty
$autoDir = Join-Path $PSScriptRoot "..\..\scripts\automation"
if ((Test-Path $autoDir) -and (Get-ChildItem $autoDir | Measure-Object).Count -eq 0) {
    Remove-Item $autoDir -Force
    Write-Host "  Deleted: scripts/automation/" -ForegroundColor Gray
}

Write-Host ""
Write-Host "  Cleanup done! Remaining files:" -ForegroundColor Green
Get-ChildItem -Path (Join-Path $PSScriptRoot "..\..") -Recurse -File | Where-Object { $_.FullName -notmatch '\.git\\' } | ForEach-Object { Write-Host "  $($_.FullName.Replace((Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path + '\', ''))" -ForegroundColor White }
