#requires -Version 5.1

[CmdletBinding()]
param(
    [int]$ScheduleDays = 7
)

$ErrorActionPreference = 'Stop'
$taskName = 'DNS Optimizer'
$installDirectory = 'C:\ProgramData\DNSOptimizer'
$sourceScript = Join-Path $PSScriptRoot 'DNSOptimizer.ps1'
$installedScript = Join-Path $installDirectory 'DNSOptimizer.ps1'

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdministrator)) {
    throw 'Run this installer from an elevated Windows PowerShell window.'
}
if (-not (Test-Path -LiteralPath $sourceScript -PathType Leaf)) {
    throw ('Could not find {0}.' -f $sourceScript)
}
if ($ScheduleDays -lt 1) { throw 'ScheduleDays must be at least 1.' }

New-Item -ItemType Directory -Path $installDirectory -Force | Out-Null
Copy-Item -LiteralPath $sourceScript -Destination $installedScript -Force

$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -ExecutionPolicy Bypass -File "{0}" -Apply' -f $installedScript)
$startAt = (Get-Date).AddMinutes(10)
$weeks = [int]($ScheduleDays / 7)
if (($ScheduleDays % 7) -eq 0 -and $weeks -ge 1) {
    $trigger = New-ScheduledTaskTrigger -Weekly -WeeksInterval $weeks -DaysOfWeek $startAt.DayOfWeek -At $startAt
}
else {
    # Task Scheduler's weekly trigger only represents whole weeks. A repeating
    # one-time trigger preserves arbitrary day intervals when customized.
    $trigger = New-ScheduledTaskTrigger -Once -At $startAt -RepetitionInterval (New-TimeSpan -Days $ScheduleDays)
}
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -WakeToRun:$false

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -User 'SYSTEM' -RunLevel Highest -Force | Out-Null
Write-Output ('Installed task "{0}".' -f $taskName)
Write-Output ('Script: {0}' -f $installedScript)
Write-Output ('Schedule: every {0} day(s), first run around {1}.' -f $ScheduleDays, $startAt.ToString('yyyy-MM-dd HH:mm'))
Write-Output 'The task runs with highest privileges, starts after a missed run, does not wake the computer, and ignores overlapping instances.'

