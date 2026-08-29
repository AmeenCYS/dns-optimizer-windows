#requires -Version 5.1

<#
    DNS Optimizer - Windows-native DNS benchmarking and safe switching.

    The script intentionally defaults to a read-only benchmark. DNS settings are
    changed only for -Apply, -ForceApply, or -Restore.
#>

[CmdletBinding()]
param(
    [switch]$TestOnly,
    [switch]$Apply,
    [switch]$ForceApply,
    [switch]$Restore,
    [switch]$ShowHistory
)

# ----------------------------- Configuration -----------------------------
$QueriesPerProvider = 40
$BenchmarkRounds = 3
$MinimumImprovementMs = 8
$MinimumImprovementPercent = 15
$MaximumFailurePercent = 5
$ScheduleDays = 7

# Additional safety and performance settings.
$WarmupQueriesPerResolver = 2
$QueryTimeoutSeconds = 4
$VerificationQueries = 3
$MaximumStandardDeviationRatio = 3.0
$HistoryRowsToShow = 20

$DataDirectory = 'C:\ProgramData\DNSOptimizer'
$HistoryCsvPath = Join-Path $DataDirectory 'dns-history.csv'
$HistoryJsonPath = Join-Path $DataDirectory 'dns-history.json'
$LogPath = Join-Path $DataDirectory 'dnsoptimizer.log'
$BackupPath = Join-Path $DataDirectory 'dns-backup.json'
$TaskName = 'DNS Optimizer'

$DnsProviders = @(
    [pscustomobject]@{
        Name = 'OpenDNS'
        IPv4 = @('208.67.222.222', '208.67.220.220')
        IPv6 = @('2620:119:35::35', '2620:119:53::53')
    },
    [pscustomobject]@{
        Name = 'Cloudflare'
        IPv4 = @('1.1.1.1', '1.0.0.1')
        IPv6 = @('2606:4700:4700::1111', '2606:4700:4700::1001')
    },
    [pscustomobject]@{
        Name = 'Google'
        IPv4 = @('8.8.8.8', '8.8.4.4')
        IPv6 = @('2001:4860:4860::8888', '2001:4860:4860::8844')
    },
    [pscustomobject]@{
        Name = 'Quad9'
        IPv4 = @('9.9.9.9', '149.112.112.112')
        IPv6 = @('2620:fe::fe', '2620:fe::9')
    }
)

$BenchmarkDomains = @(
    'google.com', 'microsoft.com', 'github.com', 'cloudflare.com',
    'wikipedia.org', 'amazon.com', 'reddit.com', 'youtube.com',
    'apple.com', 'bing.com'
)

$script:DataDirectoryInUse = $DataDirectory
$script:LogPathInUse = $LogPath
$script:HistoryCsvPathInUse = $HistoryCsvPath
$script:HistoryJsonPathInUse = $HistoryJsonPath
$script:BackupPathInUse = $BackupPath
$script:Mutex = $null

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-DnsLog {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'DEBUG')][string]$Level = 'INFO'
    )

    $timestamp = (Get-Date).ToString('o')
    $line = "{0}`t[{1}]`t{2}" -f $timestamp, $Level, $Message
    try {
        Add-Content -LiteralPath $script:LogPathInUse -Value $line -Encoding UTF8 -ErrorAction Stop
    }
    catch {
        Write-Warning ('Unable to write log file {0}: {1}' -f $script:LogPathInUse, $_.Exception.Message)
    }
    if ($Level -eq 'ERROR') { Write-Error $Message -ErrorAction Continue }
    elseif ($Level -eq 'WARN') { Write-Warning $Message }
    elseif ($VerbosePreference -eq 'Continue') { Write-Verbose $Message }
}

function Initialize-DnsOptimizerStorage {
    param([switch]$ReadOnly)

    try {
        if (-not (Test-Path -LiteralPath $DataDirectory -PathType Container)) {
            New-Item -ItemType Directory -Path $DataDirectory -Force -ErrorAction Stop | Out-Null
        }
        $script:DataDirectoryInUse = $DataDirectory
        $script:LogPathInUse = $LogPath
        $script:HistoryCsvPathInUse = $HistoryCsvPath
        $script:HistoryJsonPathInUse = $HistoryJsonPath
        $script:BackupPathInUse = $BackupPath
        return $true
    }
    catch {
        if ($ReadOnly) {
            $fallback = Join-Path $PSScriptRoot 'DNSOptimizerData'
            try {
                New-Item -ItemType Directory -Path $fallback -Force -ErrorAction Stop | Out-Null
                $script:DataDirectoryInUse = $fallback
                $script:LogPathInUse = Join-Path $fallback 'dnsoptimizer.log'
                $script:HistoryCsvPathInUse = Join-Path $fallback 'dns-history.csv'
                $script:HistoryJsonPathInUse = Join-Path $fallback 'dns-history.json'
                $script:BackupPathInUse = Join-Path $fallback 'dns-backup.json'
                Write-Warning ('ProgramData is not writable; read-only output will be stored in {0}.' -f $fallback)
                return $true
            }
            catch {
                Write-Warning ('Unable to initialize storage: {0}' -f $_.Exception.Message)
                return $false
            }
        }
        Write-DnsLog ('Unable to initialize required storage at {0}: {1}' -f $DataDirectory, $_.Exception.Message) 'ERROR'
        return $false
    }
}

function Acquire-InstanceMutex {
    try {
        $createdNew = $false
        $script:Mutex = New-Object System.Threading.Mutex($false, 'Global\DNSOptimizer')
        if (-not $script:Mutex.WaitOne(0, $false)) {
            Write-DnsLog 'Another DNS Optimizer instance is already running.' 'WARN'
            return $false
        }
        return $true
    }
    catch {
        Write-DnsLog ('Unable to acquire single-instance lock: {0}' -f $_.Exception.Message) 'ERROR'
        return $false
    }
}

function Release-InstanceMutex {
    if ($null -ne $script:Mutex) {
        try { $script:Mutex.ReleaseMutex() | Out-Null } catch { }
        try { $script:Mutex.Dispose() } catch { }
        $script:Mutex = $null
    }
}

function Ensure-Administrator {
    param([Parameter(Mandatory = $true)][string]$RequestedAction)

    if (Test-IsAdministrator) { return $true }

    $answer = Read-Host ('{0} requires Administrator rights. Relaunch elevated? (Y/N)' -f $RequestedAction)
    if ($answer -notmatch '^(Y|y|Yes|yes)$') {
        Write-DnsLog ('Administrator rights were not granted for {0}; no network changes were made.' -f $RequestedAction) 'WARN'
        return $false
    }

    try {
        $argumentList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath), ('-{0}' -f $RequestedAction))
        if ($VerbosePreference -eq 'Continue') { $argumentList += '-Verbose' }
        $process = Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argumentList -Wait -PassThru -ErrorAction Stop
        exit $process.ExitCode
    }
    catch {
        Write-DnsLog ('Elevation failed or was cancelled: {0}' -f $_.Exception.Message) 'ERROR'
        return $false
    }
}

function Get-ActiveNetworkAdapter {
    $excludedPattern = '(?i)(hyper-v|virtual|vmware|vmnet|virtualbox|vbox|vpn|tap|tun|wintun|loopback|teredo|bluetooth|wan miniport)'
    $adapters = @()
    try {
        $adapters = @(Get-NetAdapter -Physical -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' })
    }
    catch {
        $adapters = @(Get-NetAdapter -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' })
    }

    $candidates = foreach ($adapter in $adapters) {
        if (($adapter.Name -match $excludedPattern) -or ($adapter.InterfaceDescription -match $excludedPattern)) { continue }
        try {
            $ipConfig = Get-NetIPConfiguration -InterfaceIndex $adapter.ifIndex -ErrorAction Stop
            $hasGateway = ($null -ne $ipConfig.IPv4DefaultGateway) -or ($null -ne $ipConfig.IPv6DefaultGateway)
            if (-not $hasGateway) { continue }
            [pscustomobject]@{
                Adapter = $adapter
                IPConfiguration = $ipConfig
                EthernetPreference = if (($adapter.Name -match '(?i)ethernet') -or ($adapter.InterfaceDescription -match '(?i)ethernet')) { 0 } else { 1 }
            }
        }
        catch {
            Write-DnsLog ('Could not inspect adapter {0}: {1}' -f $adapter.Name, $_.Exception.Message) 'DEBUG'
        }
    }

    $selected = @($candidates | Sort-Object EthernetPreference, @{Expression = { $_.Adapter.ifIndex }} | Select-Object -First 1)
    if ($selected.Count -eq 0) {
        throw 'No active physical network adapter with a default gateway was found.'
    }
    Write-DnsLog ('Selected adapter: {0} (index {1}, description: {2})' -f $selected[0].Adapter.Name, $selected[0].Adapter.ifIndex, $selected[0].Adapter.InterfaceDescription)
    return $selected[0]
}

function Get-CurrentDnsConfiguration {
    param([Parameter(Mandatory = $true)]$AdapterInfo)

    $index = [int]$AdapterInfo.Adapter.ifIndex
    $v4 = @(Get-DnsClientServerAddress -InterfaceIndex $index -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -ExpandProperty ServerAddresses)
    $v6 = @(Get-DnsClientServerAddress -InterfaceIndex $index -AddressFamily IPv6 -ErrorAction SilentlyContinue | Select-Object -ExpandProperty ServerAddresses)
    return [pscustomobject]@{
        AdapterName = $AdapterInfo.Adapter.Name
        InterfaceIndex = $index
        IPv4 = @($v4 | Where-Object { $_ -and $_ -ne '0.0.0.0' })
        IPv6 = @($v6 | Where-Object { $_ -and $_ -ne '::' })
        CapturedAt = (Get-Date).ToString('o')
    }
}

function Backup-DnsConfiguration {
    param([Parameter(Mandatory = $true)]$Configuration)

    $backup = [pscustomobject]@{
        Version = 1
        SavedAt = (Get-Date).ToString('o')
        AdapterName = $Configuration.AdapterName
        InterfaceIndex = $Configuration.InterfaceIndex
        IPv4 = @($Configuration.IPv4)
        IPv6 = @($Configuration.IPv6)
    }
    $backup | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:BackupPathInUse -Encoding UTF8 -Force
    Write-DnsLog ('Saved DNS backup to {0}.' -f $script:BackupPathInUse)
    return $backup
}

function Restore-DnsConfiguration {
    if (-not (Test-Path -LiteralPath $script:BackupPathInUse -PathType Leaf)) {
        throw ('DNS backup file was not found: {0}' -f $script:BackupPathInUse)
    }
    $backup = Get-Content -LiteralPath $script:BackupPathInUse -Raw -ErrorAction Stop | ConvertFrom-Json
    $adapter = Get-NetAdapter -InterfaceIndex ([int]$backup.InterfaceIndex) -ErrorAction SilentlyContinue
    if ($null -eq $adapter) { $adapter = Get-NetAdapter -Name $backup.AdapterName -ErrorAction Stop }

    if (@($backup.IPv4).Count -gt 0) {
        Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ServerAddresses @($backup.IPv4) -ErrorAction Stop
    }
    else {
        Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ResetServerAddresses -ErrorAction Stop
    }
    if (@($backup.IPv6).Count -gt 0) {
        Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv6 -ServerAddresses @($backup.IPv6) -ErrorAction Stop
    }
    else {
        Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv6 -ResetServerAddresses -ErrorAction Stop
    }
    Clear-DnsCache
    Write-DnsLog ('Restored IPv4 DNS [{0}] and IPv6 DNS [{1}] on {2}.' -f (($backup.IPv4 -join ', ')), (($backup.IPv6 -join ', ')), $adapter.Name)
}

function Clear-DnsCache {
    try { Clear-DnsClientCache -ErrorAction Stop }
    catch { & ipconfig.exe /flushdns | Out-Null }
}

function Invoke-DnsQueryWithTimeout {
    param(
        [Parameter(Mandatory = $true)][string]$Domain,
        [Parameter(Mandatory = $true)][string]$Server,
        [Parameter(Mandatory = $true)][ValidateSet('IPv4', 'IPv6')][string]$Family,
        [int]$TimeoutSeconds = $QueryTimeoutSeconds
    )

    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $powershell = [PowerShell]::Create()
    $asyncResult = $null
    try {
        [void]$powershell.AddCommand('Resolve-DnsName')
        [void]$powershell.AddParameter('Name', $Domain)
        [void]$powershell.AddParameter('Server', $Server)
        [void]$powershell.AddParameter('Type', 'A')
        [void]$powershell.AddParameter('DnsOnly', $true)
        [void]$powershell.AddParameter('QuickTimeout', $true)
        [void]$powershell.AddParameter('ErrorAction', 'Stop')
        $asyncResult = $powershell.BeginInvoke()
        $completed = $asyncResult.AsyncWaitHandle.WaitOne([TimeSpan]::FromSeconds($TimeoutSeconds))
        if (-not $completed) {
            try { $powershell.Stop() } catch { }
            $stopwatch.Stop()
            return [pscustomobject]@{ Success = $false; Timeout = $true; LatencyMs = $null; Error = 'Query timeout.'; Domain = $Domain; Server = $Server; Family = $Family }
        }
        $output = @($powershell.EndInvoke($asyncResult))
        $stopwatch.Stop()
        if ($powershell.HadErrors -or $output.Count -eq 0) {
            return [pscustomobject]@{ Success = $false; Timeout = $false; LatencyMs = $null; Error = 'Resolver returned no valid DNS answer.'; Domain = $Domain; Server = $Server; Family = $Family }
        }
        return [pscustomobject]@{ Success = $true; Timeout = $false; LatencyMs = [math]::Round($stopwatch.Elapsed.TotalMilliseconds, 2); Error = $null; Domain = $Domain; Server = $Server; Family = $Family }
    }
    catch {
        $stopwatch.Stop()
        return [pscustomobject]@{ Success = $false; Timeout = $false; LatencyMs = $null; Error = $_.Exception.Message; Domain = $Domain; Server = $Server; Family = $Family }
    }
    finally {
        if ($null -ne $asyncResult -and $null -ne $asyncResult.AsyncWaitHandle) { $asyncResult.AsyncWaitHandle.Dispose() }
        $powershell.Dispose()
    }
}

function Test-IPv6Connectivity {
    param([Parameter(Mandatory = $true)]$Provider)

    foreach ($server in $Provider.IPv6) {
        $result = Invoke-DnsQueryWithTimeout -Domain 'cloudflare.com' -Server $server -Family IPv6 -TimeoutSeconds $QueryTimeoutSeconds
        if ($result.Success) {
            Write-DnsLog ('IPv6 connectivity is usable through resolver {0}.' -f $server)
            return $true
        }
    }
    Write-DnsLog 'IPv6 DNS connectivity is unavailable; IPv6 DNS settings will not be changed.' 'WARN'
    return $false
}

function Test-InternetConnectivity {
    $cloudflare = $DnsProviders | Where-Object { $_.Name -eq 'Cloudflare' } | Select-Object -First 1
    foreach ($server in $cloudflare.IPv4) {
        $result = Invoke-DnsQueryWithTimeout -Domain 'microsoft.com' -Server $server -Family IPv4 -TimeoutSeconds $QueryTimeoutSeconds
        if ($result.Success) { return $true }
    }
    foreach ($server in $cloudflare.IPv6) {
        $result = Invoke-DnsQueryWithTimeout -Domain 'microsoft.com' -Server $server -Family IPv6 -TimeoutSeconds $QueryTimeoutSeconds
        if ($result.Success) { return $true }
    }
    return $false
}

function Get-Percentile {
    param([double[]]$Values, [double]$Percentile)
    if ($null -eq $Values -or $Values.Count -eq 0) { return $null }
    $sorted = @($Values | Sort-Object)
    $rank = ($Percentile / 100.0) * ($sorted.Count - 1)
    $lower = [math]::Floor($rank)
    $upper = [math]::Ceiling($rank)
    if ($lower -eq $upper) { return [math]::Round($sorted[$lower], 2) }
    return [math]::Round($sorted[$lower] + (($sorted[$upper] - $sorted[$lower]) * ($rank - $lower)), 2)
}

function Get-PerformanceStatistics {
    param(
        [Parameter(Mandatory = $true)][array]$Results,
        [Parameter(Mandatory = $true)][string]$ProviderName,
        [int]$Round = 0
    )

    $successful = @($Results | Where-Object { $_.Success })
    $latencies = @($successful | ForEach-Object { [double]$_.LatencyMs })
    $failed = @($Results | Where-Object { -not $_.Success })
    $total = $Results.Count
    $failurePercent = if ($total -gt 0) { [math]::Round(($failed.Count / $total) * 100, 2) } else { 100 }
    $median = Get-Percentile -Values $latencies -Percentile 50
    $average = if ($latencies.Count -gt 0) { [math]::Round(($latencies | Measure-Object -Average).Average, 2) } else { $null }
    $stdDev = $null
    if ($latencies.Count -gt 1) {
        $mean = ($latencies | Measure-Object -Average).Average
        $variance = (($latencies | ForEach-Object { [math]::Pow(($_ - $mean), 2) } | Measure-Object -Average).Average)
        $stdDev = [math]::Round([math]::Sqrt($variance), 2)
    }
    $stable = ($latencies.Count -gt 0 -and (($null -eq $stdDev) -or ($null -eq $median) -or $stdDev -le ($median * $MaximumStandardDeviationRatio)))
    return [pscustomobject]@{
        Provider = $ProviderName
        Round = $Round
        Total = $total
        Success = $successful.Count
        Failed = $failed.Count
        TimeoutPercent = $failurePercent
        Min = if ($latencies.Count -gt 0) { [math]::Round(($latencies | Measure-Object -Minimum).Minimum, 2) } else { $null }
        Median = $median
        Average = $average
        P95 = Get-Percentile -Values $latencies -Percentile 95
        Max = if ($latencies.Count -gt 0) { [math]::Round(($latencies | Measure-Object -Maximum).Maximum, 2) } else { $null }
        StandardDeviation = $stdDev
        IsStable = $stable
        Results = @($Results)
    }
}

function Measure-DnsResolver {
    param(
        [Parameter(Mandatory = $true)][string]$ProviderName,
        [Parameter(Mandatory = $true)][string]$Server,
        [Parameter(Mandatory = $true)][ValidateSet('IPv4', 'IPv6')][string]$Family,
        [Parameter(Mandatory = $true)][int]$Round,
        [Parameter(Mandatory = $true)][int]$QueryCount
    )

    for ($warmup = 0; $warmup -lt $WarmupQueriesPerResolver; $warmup++) {
        $warmupDomain = $BenchmarkDomains[$warmup % $BenchmarkDomains.Count]
        [void](Invoke-DnsQueryWithTimeout -Domain $warmupDomain -Server $Server -Family $Family)
    }

    $results = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $QueryCount; $i++) {
        $domain = $BenchmarkDomains[$i % $BenchmarkDomains.Count]
        $result = Invoke-DnsQueryWithTimeout -Domain $domain -Server $Server -Family $Family
        $results.Add($result)
        if ($VerbosePreference -eq 'Continue') {
            $status = if ($result.Success) { ('{0} ms' -f $result.LatencyMs) } elseif ($result.Timeout) { 'TIMEOUT' } else { 'FAILED' }
            Write-Verbose ('Round {0} {1} {2} via {3}: {4}' -f $Round, $ProviderName, $domain, $Server, $status)
        }
    }
    return Get-PerformanceStatistics -Results $results.ToArray() -ProviderName $ProviderName -Round $Round
}

function Measure-DnsProvider {
    param(
        [Parameter(Mandatory = $true)]$Provider,
        [Parameter(Mandatory = $true)][int]$Round,
        [Parameter(Mandatory = $true)][bool]$IPv6Available
    )

    # Use the primary address for each usable address family. If IPv6 is not
    # usable, all samples use IPv4 so broken IPv6 cannot penalize a provider.
    $families = @([pscustomobject]@{ Name = 'IPv4'; Server = $Provider.IPv4[0] })
    if ($IPv6Available) { $families += [pscustomobject]@{ Name = 'IPv6'; Server = $Provider.IPv6[0] } }
    $combined = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $QueriesPerProvider; $i++) {
        $family = $families[$i % $families.Count]
        $domain = $BenchmarkDomains[$i % $BenchmarkDomains.Count]
        $result = Invoke-DnsQueryWithTimeout -Domain $domain -Server $family.Server -Family $family.Name -TimeoutSeconds $QueryTimeoutSeconds
        $combined.Add($result)
        if ($VerbosePreference -eq 'Continue') {
            $status = if ($result.Success) { ('{0} ms' -f $result.LatencyMs) } elseif ($result.Timeout) { 'TIMEOUT' } else { 'FAILED' }
            Write-Verbose ('Round {0} {1} {2} via {3}: {4}' -f $Round, $Provider.Name, $domain, $family.Server, $status)
        }
    }
    return Get-PerformanceStatistics -Results $combined.ToArray() -ProviderName $Provider.Name -Round $Round
}

function Select-BestDnsProvider {
    param([Parameter(Mandatory = $true)][array]$Results)

    $eligible = @($Results | Where-Object {
        $_.Success -gt 0 -and $_.TimeoutPercent -le $MaximumFailurePercent -and $_.IsStable
    })
    if ($eligible.Count -eq 0) { return $null }
    return $eligible | Sort-Object TimeoutPercent, Median, Average, P95 | Select-Object -First 1
}

function Merge-PerformanceResults {
    param([Parameter(Mandatory = $true)][array]$Results)

    $merged = foreach ($group in ($Results | Group-Object Provider)) {
        $allSamples = @($group.Group | ForEach-Object { $_.Results })
        Get-PerformanceStatistics -Results $allSamples -ProviderName $group.Name -Round 0
    }
    return @($merged)
}

function Get-CurrentDnsProviderName {
    param([Parameter(Mandatory = $true)]$CurrentConfiguration)
    $configured = @($CurrentConfiguration.IPv4) + @($CurrentConfiguration.IPv6)
    foreach ($provider in $DnsProviders) {
        $matches = @($configured | Where-Object { ($provider.IPv4 -contains $_) -or ($provider.IPv6 -contains $_) })
        if ($matches.Count -gt 0 -and $matches.Count -eq $configured.Count) { return $provider.Name }
    }
    if ($configured.Count -eq 0) { return 'Automatic' }
    return 'Mixed/Custom'
}

function Compare-DnsPerformance {
    param(
        [Parameter(Mandatory = $true)]$CurrentResult,
        [Parameter(Mandatory = $true)]$WinnerResult
    )

    if ($null -eq $CurrentResult -or $null -eq $CurrentResult.Median -or $null -eq $WinnerResult.Median) {
        return [pscustomobject]@{ Meaningful = $false; DifferenceMs = $null; DifferencePercent = $null; Reason = 'A comparable current DNS benchmark is unavailable.' }
    }
    $differenceMs = [math]::Round($CurrentResult.Median - $WinnerResult.Median, 2)
    $differencePercent = if ($CurrentResult.Median -gt 0) { [math]::Round(($differenceMs / $CurrentResult.Median) * 100, 2) } else { 0 }
    $meaningful = ($differenceMs -ge $MinimumImprovementMs) -or ($differencePercent -ge $MinimumImprovementPercent)
    return [pscustomobject]@{
        Meaningful = $meaningful
        DifferenceMs = $differenceMs
        DifferencePercent = $differencePercent
        Reason = if ($meaningful) { 'Configured improvement threshold exceeded.' } else { 'Improvement does not exceed configured threshold.' }
    }
}

function Format-Stat {
    param($Value)
    if ($null -eq $Value) { return '-' }
    return ('{0:N0} ms' -f [double]$Value)
}

function Show-BenchmarkTable {
    param([Parameter(Mandatory = $true)][array]$Results)
    $rows = foreach ($r in $Results) {
        [pscustomobject]@{
            Provider = $r.Provider
            Success = ('{0}/{1}' -f $r.Success, $r.Total)
            'Timeout%' = ('{0:N1}%' -f $r.TimeoutPercent)
            Min = Format-Stat $r.Min
            Median = Format-Stat $r.Median
            Avg = Format-Stat $r.Average
            P95 = Format-Stat $r.P95
            Max = Format-Stat $r.Max
        }
    }
    $rows | Format-Table -AutoSize | Out-Host
}

function Export-BenchmarkHistory {
    param(
        [Parameter(Mandatory = $true)][array]$Results,
        [Parameter(Mandatory = $true)][string]$AdapterName,
        [Parameter(Mandatory = $true)][string]$CurrentDns,
        [Parameter(Mandatory = $true)][string]$Winner,
        [string]$Decision = 'TestOnly',
        [string]$Verification = '',
        [bool]$Changed = $false,
        [bool]$RolledBack = $false
    )

    $timestamp = (Get-Date).ToString('o')
    $rows = foreach ($result in $Results) {
        [pscustomobject]@{
            Timestamp = $timestamp
            Adapter = $AdapterName
            Round = $result.Round
            Provider = $result.Provider
            Success = $result.Success
            Total = $result.Total
            Failed = $result.Failed
            TimeoutPercent = $result.TimeoutPercent
            MinMs = $result.Min
            MedianMs = $result.Median
            AverageMs = $result.Average
            P95Ms = $result.P95
            MaxMs = $result.Max
            StandardDeviationMs = $result.StandardDeviation
            CurrentDNS = $CurrentDns
            Winner = $Winner
            Decision = $Decision
            Changed = $Changed
            Verification = $Verification
            RolledBack = $RolledBack
        }
    }
    if ($rows.Count -gt 0) {
        $csv = $rows | ConvertTo-Csv -NoTypeInformation
        if (Test-Path -LiteralPath $script:HistoryCsvPathInUse -PathType Leaf) { $csv | Select-Object -Skip 1 | Add-Content -LiteralPath $script:HistoryCsvPathInUse -Encoding UTF8 }
        else { $csv | Set-Content -LiteralPath $script:HistoryCsvPathInUse -Encoding UTF8 }
    }

    $existing = @()
    if (Test-Path -LiteralPath $script:HistoryJsonPathInUse -PathType Leaf) {
        try { $existing = @(Get-Content -LiteralPath $script:HistoryJsonPathInUse -Raw | ConvertFrom-Json) } catch { $existing = @() }
    }
    $all = @($existing) + @($rows)
    $all | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:HistoryJsonPathInUse -Encoding UTF8 -Force
}

function Show-History {
    if (-not (Test-Path -LiteralPath $script:HistoryJsonPathInUse -PathType Leaf)) {
        Write-Output ('No history exists yet. Expected file: {0}' -f $script:HistoryJsonPathInUse)
        return
    }
    $rows = @(Get-Content -LiteralPath $script:HistoryJsonPathInUse -Raw | ConvertFrom-Json | Select-Object -Last $HistoryRowsToShow)
    if ($rows.Count -eq 0) { Write-Output 'History is empty.'; return }
    $rows | Select-Object Timestamp, Adapter, Round, Provider, Success, Total, TimeoutPercent, MedianMs, AverageMs, P95Ms, Winner, Decision, Changed, Verification, RolledBack | Format-Table -AutoSize | Out-Host
}

function Set-DnsProvider {
    param(
        [Parameter(Mandatory = $true)]$AdapterInfo,
        [Parameter(Mandatory = $true)]$Provider,
        [Parameter(Mandatory = $true)][bool]$IPv6Available
    )

    $index = [int]$AdapterInfo.Adapter.ifIndex
    Set-DnsClientServerAddress -InterfaceIndex $index -AddressFamily IPv4 -ServerAddresses @($Provider.IPv4) -ErrorAction Stop
    if ($IPv6Available) {
        Set-DnsClientServerAddress -InterfaceIndex $index -AddressFamily IPv6 -ServerAddresses @($Provider.IPv6) -ErrorAction Stop
    }
    Clear-DnsCache
    Write-DnsLog ('Applied {0} IPv4 DNS [{1}]. IPv6 applied: {2}.' -f $Provider.Name, ($Provider.IPv4 -join ', '), $IPv6Available)
}

function Test-DnsAfterChange {
    param(
        [Parameter(Mandatory = $true)]$Provider,
        [Parameter(Mandatory = $true)][bool]$IPv6Available
    )

    $successes = 0
    for ($i = 0; $i -lt $VerificationQueries; $i++) {
        $server = $Provider.IPv4[0]
        $family = 'IPv4'
        if ($IPv6Available -and (($i % 2) -eq 1)) { $server = $Provider.IPv6[0]; $family = 'IPv6' }
        $result = Invoke-DnsQueryWithTimeout -Domain $BenchmarkDomains[$i % $BenchmarkDomains.Count] -Server $server -Family $family -TimeoutSeconds $QueryTimeoutSeconds
        if ($result.Success) { $successes++ }
    }
    try {
        $systemResult = Resolve-DnsName -Name 'microsoft.com' -Type A -DnsOnly -ErrorAction Stop
        if ($null -eq $systemResult) { return $false }
    }
    catch { return $false }
    return ($successes -eq $VerificationQueries)
}

function Get-CurrentBaselineResult {
    param(
        [Parameter(Mandatory = $true)]$CurrentConfiguration,
        [Parameter(Mandatory = $true)][bool]$IPv6Available
    )
    $server = $null
    $family = $null
    if (@($CurrentConfiguration.IPv4).Count -gt 0) { $server = $CurrentConfiguration.IPv4[0]; $family = 'IPv4' }
    elseif ($IPv6Available -and @($CurrentConfiguration.IPv6).Count -gt 0) { $server = $CurrentConfiguration.IPv6[0]; $family = 'IPv6' }
    if ($null -eq $server) { return $null }
    return Measure-DnsResolver -ProviderName (Get-CurrentDnsProviderName $CurrentConfiguration) -Server $server -Family $family -Round 0 -QueryCount $QueriesPerProvider
}

function Invoke-RestoreAction {
    if (-not (Ensure-Administrator -RequestedAction 'Restore')) { return 1 }
    try {
        Restore-DnsConfiguration
        Write-Output 'DNS configuration restored from the last backup.'
        return 0
    }
    catch {
        Write-DnsLog ('Restore failed: {0}' -f $_.Exception.Message) 'ERROR'
        return 1
    }
}

# ------------------------------- Main flow --------------------------------
$requestedModes = @($TestOnly, $Apply, $ForceApply, $Restore, $ShowHistory) | Where-Object { $_ }
if (($requestedModes.Count -gt 1)) {
    throw 'Choose only one of -TestOnly, -Apply, -ForceApply, -Restore, or -ShowHistory.'
}

$requiresAdmin = $Apply -or $ForceApply -or $Restore
$requestedActionName = if ($ForceApply) { 'ForceApply' } elseif ($Restore) { 'Restore' } else { 'Apply' }
if ($requiresAdmin -and -not (Ensure-Administrator -RequestedAction $requestedActionName)) { exit 1 }
$readOnlyStorage = -not $requiresAdmin
if (-not (Initialize-DnsOptimizerStorage -ReadOnly:$readOnlyStorage)) { exit 1 }
if (-not (Acquire-InstanceMutex)) { exit 2 }

try {
    if ($Restore) { exit (Invoke-RestoreAction) }
    if ($ShowHistory) { Show-History; exit 0 }
    if (-not $TestOnly -and -not $Apply -and -not $ForceApply) { $TestOnly = $true }
    try { $adapterInfo = Get-ActiveNetworkAdapter }
    catch {
        Write-DnsLog ('No active Internet adapter: {0}' -f $_.Exception.Message) 'ERROR'
        exit 1
    }
    Write-Output ('Selected adapter: {0} (InterfaceIndex {1})' -f $adapterInfo.Adapter.Name, $adapterInfo.Adapter.ifIndex)

    if (-not (Test-InternetConnectivity)) {
        Write-DnsLog 'No Internet/DNS connectivity detected. No DNS changes were made.' 'ERROR'
        Write-Output 'No active Internet connectivity detected; exiting safely without DNS changes.'
        exit 1
    }

    $currentConfiguration = Get-CurrentDnsConfiguration -AdapterInfo $adapterInfo
    $currentDnsName = Get-CurrentDnsProviderName -CurrentConfiguration $currentConfiguration
    $ipv6Available = Test-IPv6Connectivity -Provider ($DnsProviders | Select-Object -First 1)
    Write-Output ('Current DNS: {0} (IPv4: {1}; IPv6: {2})' -f $currentDnsName, (($currentConfiguration.IPv4 -join ', ') -replace '^$', 'automatic'), (($currentConfiguration.IPv6 -join ', ') -replace '^$', 'automatic'))
    Write-DnsLog ('Current DNS provider: {0}; IPv4 [{1}]; IPv6 [{2}]' -f $currentDnsName, ($currentConfiguration.IPv4 -join ', '), ($currentConfiguration.IPv6 -join ', '))

    $roundResults = New-Object System.Collections.Generic.List[object]
    $roundWinners = New-Object System.Collections.Generic.List[string]
    for ($round = 1; $round -le $BenchmarkRounds; $round++) {
        Write-Output ('Benchmark round {0}/{1}...' -f $round, $BenchmarkRounds)
        Write-DnsLog ('Starting benchmark round {0}/{1}.' -f $round, $BenchmarkRounds)
        foreach ($provider in $DnsProviders) {
            $measurement = Measure-DnsProvider -Provider $provider -Round $round -IPv6Available $ipv6Available
            $roundResults.Add($measurement)
            Write-DnsLog ('Round {0} {1}: {2}/{3} success, timeout/failure {4}%, median {5} ms, p95 {6} ms.' -f $round, $measurement.Provider, $measurement.Success, $measurement.Total, $measurement.TimeoutPercent, $measurement.Median, $measurement.P95)
        }
        $roundWinner = Select-BestDnsProvider -Results @($roundResults.ToArray() | Where-Object { $_.Round -eq $round })
        if ($null -ne $roundWinner) {
            $roundWinners.Add($roundWinner.Provider)
            Write-DnsLog ('Round {0} winner: {1}.' -f $round, $roundWinner.Provider)
        }
        else { Write-DnsLog ('Round {0} had no eligible winner.' -f $round) 'WARN' }
    }

    $aggregateResults = Merge-PerformanceResults -Results $roundResults.ToArray()
    $aggregateWinner = Select-BestDnsProvider -Results $aggregateResults
    $winner = $null
    if ($roundWinners.Count -gt 0) {
        $majority = @($roundWinners | Group-Object | Sort-Object Count -Descending | Select-Object -First 1)
        if ($majority.Count -gt 0 -and $majority[0].Count -ge [math]::Ceiling($BenchmarkRounds / 2.0)) {
            $winner = $aggregateResults | Where-Object { $_.Provider -eq $majority[0].Name } | Select-Object -First 1
        }
    }
    if ($null -eq $winner -and $null -ne $aggregateWinner) {
        $sortedEligible = @($aggregateResults | Where-Object { $_.Success -gt 0 -and $_.TimeoutPercent -le $MaximumFailurePercent -and $_.IsStable } | Sort-Object TimeoutPercent, Median, Average, P95)
        if ($sortedEligible.Count -eq 1) { $winner = $sortedEligible[0] }
        elseif ($sortedEligible.Count -gt 1) {
            $aggregateGap = $sortedEligible[1].Median - $sortedEligible[0].Median
            if (($aggregateGap -ge $MinimumImprovementMs) -or (($sortedEligible[1].Median -gt 0) -and (($aggregateGap / $sortedEligible[1].Median) * 100 -ge $MinimumImprovementPercent))) { $winner = $sortedEligible[0] }
        }
    }

    Show-BenchmarkTable -Results $aggregateResults
    if ($null -eq $winner) {
        Write-DnsLog 'No provider passed the reliability, stability, and multi-round selection rules.' 'WARN'
        Write-Output 'Best DNS: none - no provider passed the reliability/stability checks.'
        Export-BenchmarkHistory -Results $roundResults.ToArray() -AdapterName $adapterInfo.Adapter.Name -CurrentDns $currentDnsName -Winner 'None' -Decision 'NO_CHANGE_NO_ELIGIBLE_WINNER'
        exit 0
    }

    $currentBaseline = Get-CurrentBaselineResult -CurrentConfiguration $currentConfiguration -IPv6Available $ipv6Available
    $comparison = Compare-DnsPerformance -CurrentResult $currentBaseline -WinnerResult $winner
    Write-Output ('Current DNS: {0}' -f $currentDnsName)
    Write-Output ('Best DNS: {0}' -f $winner.Provider)
    Write-Output ('Current median: {0}' -f (Format-Stat $(if ($null -ne $currentBaseline) { $currentBaseline.Median } else { $null })))
    Write-Output ('Winner median: {0}' -f (Format-Stat $winner.Median))
    Write-Output ('Difference: {0} ms / {1}%' -f $(if ($null -ne $comparison.DifferenceMs) { $comparison.DifferenceMs } else { '-' }), $(if ($null -ne $comparison.DifferencePercent) { $comparison.DifferencePercent } else { '-' }))

    $decision = 'NO_CHANGE'
    $changed = $false
    $rolledBack = $false
    $verification = 'Not requested'
    $currentProvider = $DnsProviders | Where-Object { $_.Name -eq $currentDnsName } | Select-Object -First 1
    if ($TestOnly) {
        $decision = 'TEST_ONLY_NO_CHANGE'
        Write-Output 'Decision: TEST ONLY - no DNS settings were changed.'
    }
    elseif ($currentDnsName -eq $winner.Provider -and -not $ForceApply) {
        $decision = 'NO_CHANGE_ALREADY_WINNER'
        Write-Output 'Decision: NO CHANGE - the selected DNS provider is already configured.'
    }
    elseif (-not $ForceApply -and -not $comparison.Meaningful) {
        $decision = 'NO_CHANGE_BELOW_THRESHOLD'
        Write-Output 'Decision: NO CHANGE - improvement does not exceed configured threshold.'
    }
    else {
        if (-not (Ensure-Administrator -RequestedAction $requestedActionName)) { exit 1 }
        try {
            $backup = Backup-DnsConfiguration -Configuration $currentConfiguration
            Write-Output ('Decision: CHANGING DNS: {0} -> {1}' -f $currentDnsName, $winner.Provider)
            Set-DnsProvider -AdapterInfo $adapterInfo -Provider ($DnsProviders | Where-Object { $_.Name -eq $winner.Provider } | Select-Object -First 1) -IPv6Available $ipv6Available
            $verification = if (Test-DnsAfterChange -Provider ($DnsProviders | Where-Object { $_.Name -eq $winner.Provider } | Select-Object -First 1) -IPv6Available $ipv6Available) { 'PASS' } else { 'FAIL' }
            if ($verification -ne 'PASS') { throw 'DNS verification failed after applying the new configuration.' }
            $changed = $true
            $decision = if ($ForceApply) { 'CHANGED_FORCE_APPLY' } else { 'CHANGED_APPLY' }
            Write-DnsLog ('DNS change verified successfully: {0}.' -f $winner.Provider)
            Write-Output 'Verification: PASS - DNS settings and resolution are working.'
        }
        catch {
            Write-DnsLog ('DNS change failed: {0}. Starting automatic rollback.' -f $_.Exception.Message) 'ERROR'
            try {
                Restore-DnsConfiguration
                $rolledBack = $true
                $verification = 'FAIL; ROLLBACK COMPLETED'
                $decision = 'ROLLBACK'
                Write-Output 'Verification: FAIL - rollback completed and previous DNS configuration was restored.'
                Write-DnsLog 'Automatic rollback completed.' 'WARN'
            }
            catch {
                $verification = 'FAIL; ROLLBACK FAILED'
                $decision = 'ROLLBACK_FAILED'
                Write-DnsLog ('CRITICAL: automatic rollback failed: {0}' -f $_.Exception.Message) 'ERROR'
                Write-Output 'CRITICAL: DNS change and automatic rollback both failed. Inspect the backup and log immediately.'
            }
        }
    }

    Export-BenchmarkHistory -Results $roundResults.ToArray() -AdapterName $adapterInfo.Adapter.Name -CurrentDns $currentDnsName -Winner $winner.Provider -Decision $decision -Verification $verification -Changed $changed -RolledBack $rolledBack
    Write-DnsLog ('Execution complete. Winner: {0}; decision: {1}; changed: {2}; rollback: {3}.' -f $winner.Provider, $decision, $changed, $rolledBack)
    exit 0
}
catch {
    Write-DnsLog ('Unhandled execution error: {0}' -f $_.Exception.ToString()) 'ERROR'
    exit 1
}
finally {
    Release-InstanceMutex
}

