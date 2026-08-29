#requires -Version 5.1

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$taskName = 'DNS Optimizer'

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdministrator)) {
    throw 'Run this uninstaller from an elevated Windows PowerShell window.'
}

$task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($null -eq $task) {
    Write-Output ('Task "{0}" is not installed.' -f $taskName)
    exit 0
}
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
Write-Output ('Removed task "{0}".' -f $taskName)
Write-Output 'DNSOptimizer.ps1, its logs, history, and backup were left in C:\ProgramData\DNSOptimizer.'

