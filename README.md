# DNS Optimizer for Windows 10

Automatic DNS benchmarking and safe DNS switching for Windows 10. The project uses only built-in Windows PowerShell networking commands and does not require third-party software.

The script benchmarks DNS providers from the actual Windows machine and selects the best eligible provider conservatively. Test-only behavior is the default; DNS changes are possible only with `-Apply`, `-ForceApply`, or `-Restore`.

## What it does

- Sends real DNS queries with `Resolve-DnsName -Server`; it does not use ping as a DNS benchmark.
- Performs 40 queries per provider in each of 3 rounds, with a warm-up phase excluded from measurements.
- Cycles through diverse domains and calculates success, failures, timeout percentage, minimum, median, average, p95, maximum, and standard deviation.
- Tests IPv4 primary resolvers and alternates IPv4/IPv6 primary resolvers when usable IPv6 connectivity is detected.
- Detects the active physical adapter, prefers Ethernet, and ignores common Hyper-V, WSL, VPN, VMware, and VirtualBox adapters.
- Changes only DNS server addresses. It does not change IP addresses, routes, gateways, DHCP, MTU, MSS, proxy, firewall, or IPv6 enablement.
- Saves the previous IPv4/IPv6 DNS configuration before applying a change.
- Flushes and verifies DNS after a change; failed verification triggers automatic rollback.

## First installation: command-line steps

### 1. Put the project in a folder

Download the repository ZIP from GitHub, or use the command line if Git is installed.

To clone the repository into your user profile:

```powershell
$projectRoot = Join-Path $env:USERPROFILE 'dns-optimizer-windows'
Set-Location (Split-Path $projectRoot -Parent)
git clone https://github.com/AmeenCYS/dns-optimizer-windows.git $projectRoot
Set-Location $projectRoot
```

This repository is public, so Git authentication is not required for cloning. Never put a password or access token directly in the clone URL. If Git is not installed, download the ZIP from the repository page and extract it instead.

The project folder must contain:

```text
DNSOptimizer.ps1
Install-DNSOptimizerTask.ps1
Uninstall-DNSOptimizerTask.ps1
README.md
.gitignore
SECURITY.md
```

If you downloaded the ZIP instead, extract it and change to the extracted folder before running the commands below.

### 2. Run the first safe test

This command benchmarks DNS and never changes network settings:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\DNSOptimizer.ps1 -TestOnly
```

If no mode is supplied, the script is also test-only:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\DNSOptimizer.ps1
```

Review the displayed table before allowing automatic changes.

### 3. Install automatic operation

Open **Windows PowerShell as Administrator**, move to the project folder, and run:

```powershell
Set-Location $projectRoot
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-DNSOptimizerTask.ps1 -ScheduleDays 7
```

The installer copies `DNSOptimizer.ps1` to `C:\ProgramData\DNSOptimizer` and creates a scheduled task named `DNS Optimizer`. The task runs with highest privileges as SYSTEM, once every 7 days, starts after a missed run, does not wake the computer, and ignores overlapping instances.

For a different interval, pass a positive number of days, for example:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-DNSOptimizerTask.ps1 -ScheduleDays 1
```

### 4. Verify the task

```powershell
Get-ScheduledTask -TaskName 'DNS Optimizer' |
    Select-Object TaskName, State

$task = Get-ScheduledTask -TaskName 'DNS Optimizer'
$task.Actions | Format-List Execute, Arguments

Get-ScheduledTaskInfo -TaskName 'DNS Optimizer' |
    Select-Object LastRunTime, LastTaskResult, NextRunTime
```

The task should be `Ready`. Its action should contain `DNSOptimizer.ps1 -Apply`. A `LastTaskResult` of `0` means the last run completed successfully.

### 5. Test the scheduled task now (optional)

This starts the real `-Apply` workflow and may change DNS if the winner passes all checks:

```powershell
Start-ScheduledTask -TaskName 'DNS Optimizer'
```

The full benchmark may take several minutes. Do not start another copy while it is `Running`.

## Normal commands

Run these from the folder containing the scripts:

```powershell
# Safe benchmark only; never changes DNS.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\DNSOptimizer.ps1 -TestOnly

# Benchmark and apply only when the improvement threshold is exceeded.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\DNSOptimizer.ps1 -Apply

# Apply an eligible winner regardless of the improvement threshold.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\DNSOptimizer.ps1 -ForceApply

# Restore the most recent backup.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\DNSOptimizer.ps1 -Restore

# Show recent benchmark history.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\DNSOptimizer.ps1 -ShowHistory

# Include detailed per-query diagnostic output.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\DNSOptimizer.ps1 -TestOnly -Verbose
```

`-TestOnly` is the default behavior. Only `-Apply`, `-ForceApply`, and `-Restore` can change DNS. Apply and restore modes require Administrator rights; the script can ask to relaunch itself elevated. Test-only mode does not request elevation. If `C:\ProgramData` is not writable during a read-only run, logs fall back to a local `DNSOptimizerData` folder beside the script.

## How the benchmark works

Each provider receives a small warm-up, followed by 40 timed DNS requests per round. The domains are rotated through Google, Microsoft, GitHub, Cloudflare, Wikipedia, Amazon, Reddit, YouTube, Apple, and Bing. Each query is sent directly to the provider's primary resolver with a bounded timeout. A failed query is recorded and does not crash the benchmark.

The script runs 3 complete rounds. Results are ranked by reliability first, then median latency, average latency, and p95 latency. Providers over the configured failure percentage or with excessive latency instability are rejected. A normal winner must win at least 2 of 3 rounds; an aggregate result is accepted without a majority only when it clearly beats the next eligible provider.

### Why DNS query latency instead of ping?

Ping measures ICMP/network path latency to an IP address. It does not measure whether a DNS resolver can receive, process, and return a DNS answer. This project times actual DNS lookups using `Resolve-DnsName -Server`, so the result reflects the operation that matters to web browsing and applications.

## Anti-flapping behavior

Before applying a winner, the script identifies the current DNS configuration and benchmarks its first configured resolver when possible. With `-Apply`, the winner must be at least:

- `$MinimumImprovementMs` milliseconds faster by median; or
- `$MinimumImprovementPercent` percent faster by median.

The defaults are 8 ms and 15%. If neither threshold is met, the script logs and displays `NO_CHANGE_BELOW_THRESHOLD`. Use `-ForceApply` only when you intentionally want to bypass this improvement test; reliability and stability checks still apply.

## IPv4, IPv6, and adapter safety

The script first checks whether IPv6 DNS connectivity is usable. If it is not, IPv6 DNS settings are not changed. It does not disable IPv6. IPv4 and IPv6 DNS lists are backed up independently.

The selected adapter is an active physical adapter with a default gateway. Ethernet is preferred when several candidates exist. Common virtual and VPN adapter names are ignored, including Hyper-V and WSL. The `vEthernet (WSL)` adapter is therefore not modified.

## Backup, verification, and rollback

Before a DNS change, the current IPv4 and IPv6 server lists are saved to `dns-backup.json`. After applying the winner, the script flushes the DNS cache, verifies the configured server addresses, sends several direct DNS queries, and confirms normal system resolution. Any verification failure triggers automatic restoration and another cache flush.

To manually restore the last saved configuration:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\DNSOptimizer.ps1 -Restore
```

## Logs and history

Runtime files are stored in:

```text
C:\ProgramData\DNSOptimizer\
```

Files:

- `DNSOptimizer.ps1` - copy used by the scheduled task
- `dns-history.csv` - one row per provider and round for spreadsheet analysis
- `dns-history.json` - structured history
- `dnsoptimizer.log` - execution and error log
- `dns-backup.json` - latest pre-change IPv4/IPv6 DNS backup

View recent logs:

```powershell
Get-Content -LiteralPath 'C:\ProgramData\DNSOptimizer\dnsoptimizer.log' -Tail 50
```

View recent history:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\DNSOptimizer.ps1 -ShowHistory
```

## Updating the installed version

After downloading a newer version, open PowerShell as Administrator and rerun the installer from the new project folder:

```powershell
Set-Location 'C:\path\to\dns-optimizer-windows'
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-DNSOptimizerTask.ps1 -ScheduleDays 7
```

This refreshes `C:\ProgramData\DNSOptimizer\DNSOptimizer.ps1` while preserving runtime history and backup files.

## Uninstalling the scheduled task

Run from an elevated PowerShell window:

```powershell
Set-Location 'C:\path\to\dns-optimizer-windows'
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Uninstall-DNSOptimizerTask.ps1
```

The uninstaller removes only the `DNS Optimizer` scheduled task. It leaves the logs, history, backup, and installed script in `C:\ProgramData\DNSOptimizer`.

## Customization

Edit the configuration section near the beginning of `DNSOptimizer.ps1`:

```powershell
$QueriesPerProvider = 40
$BenchmarkRounds = 3
$MinimumImprovementMs = 8
$MinimumImprovementPercent = 15
$MaximumFailurePercent = 5
$ScheduleDays = 7
```

Additional settings control warm-up queries, query timeout, verification queries, and instability rejection. The `$DnsProviders` and `$BenchmarkDomains` lists can also be edited. If the scheduled task is installed, rerun the installer after changing the script so the copy in `C:\ProgramData\DNSOptimizer` is updated.

## Repository files

- `DNSOptimizer.ps1` - main benchmark, selection, apply, verify, rollback, logging, and history logic
- `Install-DNSOptimizerTask.ps1` - elevated scheduled-task installer
- `Uninstall-DNSOptimizerTask.ps1` - scheduled-task removal script
- `README.md` - this guide
- `.gitignore` - prevents runtime data and local artifacts from being committed
- `SECURITY.md` - security reporting guidance

## Requirements and limitations

- Windows 10 with Windows PowerShell 5.1.
- Administrator rights are required only for scheduled-task installation, DNS application, and restore.
- An active Internet connection is required for benchmarking.
- The script tests public DNS endpoints from the current machine; results can vary by ISP, router, firewall, and time of day.

