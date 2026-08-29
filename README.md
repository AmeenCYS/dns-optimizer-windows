# DNS Optimizer for Windows 10

`DNSOptimizer.ps1` is a Windows PowerShell 5.1-compatible, native DNS benchmarker and optional DNS switcher. It uses `Resolve-DnsName -Server` and `System.Diagnostics.Stopwatch` to measure real DNS query latency. It does not use ping and it changes only DNS server addresses.

## Safe first command

Open Windows PowerShell and run this first:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
cd "C:\path\to\DNSOptimizer"
.\DNSOptimizer.ps1 -TestOnly
```

Replace the path with the folder containing these files. If no mode is supplied, the script also behaves as test-only. Test-only mode never calls `Set-DnsClientServerAddress`.

The benchmark performs a small warm-up, then 40 real DNS queries per provider in each of 3 rounds. Domains are cycled through a diverse list. If usable IPv6 connectivity exists, IPv4 and IPv6 primary resolvers are alternated; otherwise only IPv4 is tested and IPv6 settings are left alone.

## Winner selection and anti-flapping

Each round calculates successes, failures, timeout percentage, minimum, median, average, p95, maximum, and standard deviation. Resolvers above the configured failure limit or with excessive instability are rejected. Ranking prioritizes reliability, then median latency, average latency, and p95 latency.

A winner normally must win at least 2 of 3 rounds. If there is no majority, an aggregate winner is used only when it clearly beats the next eligible provider. `-Apply` compares the winner with the current resolver and switches only when the winner is at least 8 ms faster or at least 15% faster. Use `-ForceApply` to bypass that improvement threshold while retaining reliability and stability checks.

## Commands

```powershell
# Benchmark and display results; never change DNS.
.\DNSOptimizer.ps1 -TestOnly

# Benchmark, then apply only when reliability and improvement thresholds pass.
.\DNSOptimizer.ps1 -Apply

# Benchmark and apply an eligible winner regardless of improvement threshold.
.\DNSOptimizer.ps1 -ForceApply

# Restore the most recent backup.
.\DNSOptimizer.ps1 -Restore

# Display recent history.
.\DNSOptimizer.ps1 -ShowHistory

# Include per-query diagnostic output.
.\DNSOptimizer.ps1 -TestOnly -Verbose
```

`-Apply`, `-ForceApply`, and `-Restore` require Administrator rights. The script asks whether to relaunch elevated only for those modes. Test-only mode does not request elevation; if `C:\ProgramData` is not writable, its read-only logs are placed beside the script in `DNSOptimizerData`.

Before a change, the current IPv4 and IPv6 DNS server lists are saved to `dns-backup.json`. After applying, the script flushes the cache, verifies the configured addresses, queries the new resolver several times, and confirms normal system resolution. Any verification failure triggers automatic restoration and another cache flush.

## Scheduled task

Run the installer from an elevated Windows PowerShell window:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
cd "C:\path\to\DNSOptimizer"
.\Install-DNSOptimizerTask.ps1
```

It installs the script into `C:\ProgramData\DNSOptimizer`, creates a task named `DNS Optimizer`, runs it with highest privileges as SYSTEM once every 7 days, starts after a missed run, does not wake the computer, and ignores overlapping runs.

Remove the task with:

```powershell
.\Uninstall-DNSOptimizerTask.ps1
```

The uninstall script removes only the scheduled task. It leaves logs, history, and the last backup intact.

## Files and customization

Runtime files are stored in `C:\ProgramData\DNSOptimizer`:

- `DNSOptimizer.ps1` - installed scheduled-task copy
- `dns-history.csv` and `dns-history.json` - benchmark history
- `dnsoptimizer.log` - execution log
- `dns-backup.json` - most recent pre-change DNS configuration

Edit the configuration section near the top of `DNSOptimizer.ps1` to change `$QueriesPerProvider`, `$BenchmarkRounds`, `$MinimumImprovementMs`, `$MinimumImprovementPercent`, `$MaximumFailurePercent`, `$ScheduleDays`, timeout, warm-up, or stability settings. Edit `$DnsProviders` and `$BenchmarkDomains` to customize the test set. The task installer also accepts `-ScheduleDays`; pass the same value when installing a custom interval. If the scheduled task is already installed, copy the updated script to `C:\ProgramData\DNSOptimizer\DNSOptimizer.ps1` or rerun the installer.

The script ignores disconnected and common virtual/VPN adapters, prefers an active physical Ethernet adapter, does not disable IPv6, and does not modify IP addresses, gateways, routes, MTU, DHCP, proxy, firewall, or unrelated network settings.

