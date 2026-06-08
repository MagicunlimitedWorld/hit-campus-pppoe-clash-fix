param(
    [string]$RasEntry = "HITnet",
    [string]$ProxyUrl = "http://127.0.0.1:7897",
    [int]$EthernetIfIndex = 17,
    [int]$WifiIfIndex = 8,
    [switch]$RunDownloadTest,
    [switch]$RunGithubDownloadTest,
    [switch]$RunCodexConnectivityTest,
    [switch]$TrialWinHttpProxy,
    [switch]$TrialRasWinInetProxy,
    [switch]$TrialUserInternetProxy,
    [switch]$TrialClashTun,
    [switch]$TrialNrptCodexDns,
    [switch]$TrialIpv6SplitRoute,
    [string]$GithubDownloadUrl = "https://github.com/microsoft/vscode/archive/refs/heads/main.zip",
    [long]$GithubMaxBytes = 52428800,
    [string]$WinHttpProxyServer = "127.0.0.1:7897",
    [string]$UserProxyBypass = "localhost;127.*;192.168.*;10.*;172.16.*;172.17.*;172.18.*;172.19.*;172.20.*;172.21.*;172.22.*;172.23.*;172.24.*;172.25.*;172.26.*;172.27.*;172.28.*;172.29.*;172.30.*;172.31.*;<local>",
    [string]$ClashHome = (Join-Path $env:APPDATA "io.github.clash-verge-rev.clash-verge-rev"),
    [string]$ClashCoreExe = "D:\clash verge\verge-mihomo.exe"
)

$ErrorActionPreference = "Continue"

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$LogPath = Join-Path $ScriptDir ("pppoe_clash_restore_{0}.log" -f $Timestamp)
$script:OriginalWinHttpProxyText = $null
$script:WinHttpProxyChanged = $false
$script:OriginalRasConnectionSettings = $null
$script:RasWinInetProxyChanged = $false
$script:ConnectionsRegPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings\Connections"
$script:OriginalUserInternetSettings = $null
$script:UserInternetProxyChanged = $false
$script:InternetSettingsRegPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
$script:ClashConfigPath = Join-Path $ClashHome "clash-verge.yaml"
$script:ClashTunBackupPath = Join-Path $ScriptDir ("clash-verge.before-tun.{0}.yaml" -f $Timestamp)
$script:OriginalClashConfigText = $null
$script:ClashTunChanged = $false
$script:NrptTrialNamespaces = @(".openai.com", ".chatgpt.com", ".oaistatic.com", ".oaiusercontent.com", ".github.com")
$script:NrptTrialComment = "CodexClashTrial temporary NRPT rule $Timestamp"
$script:NrptTrialCreatedRuleNames = New-Object System.Collections.Generic.List[string]
$script:SplitRouteTrialAddedRoutes = New-Object System.Collections.Generic.List[object]

function Write-Log {
    param([string]$Message = "")
    $line = "{0} {1}" -f (Get-Date -Format "s"), $Message
    $line | Tee-Object -FilePath $LogPath -Append
}

function Invoke-Logged {
    param(
        [string]$Title,
        [scriptblock]$Script
    )
    Write-Log ("=== {0} ===" -f $Title)
    try {
        $output = & $Script 2>&1 | Out-String -Width 4096
        if ([string]::IsNullOrWhiteSpace($output)) {
            "(no output)" | Tee-Object -FilePath $LogPath -Append
        }
        else {
            $output.TrimEnd() | Tee-Object -FilePath $LogPath -Append
        }
    }
    catch {
        Write-Log ("ERROR: {0}" -f $_.Exception.Message)
    }
}

function Invoke-CurlProbe {
    param(
        [string]$Title,
        [string]$Url,
        [switch]$UseProxy,
        [switch]$Head,
        [int]$MaxTime = 12
    )

    Invoke-Logged $Title {
        $args = @(
            "-L",
            "--max-time", "$MaxTime",
            "-o", "NUL",
            "-s",
            "-w", "code=%{http_code} dns=%{time_namelookup}s connect=%{time_connect}s tls=%{time_appconnect}s starttransfer=%{time_starttransfer}s total=%{time_total}s remote=%{remote_ip} err=%{errormsg}`n"
        )
        if ($UseProxy) {
            $args += @("--proxy", $ProxyUrl)
        }
        else {
            $args += @("--noproxy", "*")
        }
        if ($Head) {
            $args += "-I"
        }
        $args += $Url
        & curl.exe @args
    }
}

function Test-ClashProxyReady {
    param([int]$TimeoutSeconds = 30)

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $ok = $false
        try {
            $result = & curl.exe -I -L --max-time 5 --proxy $ProxyUrl -o NUL -s -w "code=%{http_code}" "https://www.google.com/generate_204"
            if ($result -match "code=204") {
                $ok = $true
            }
        }
        catch {
            $ok = $false
        }

        if ($ok) {
            return $true
        }
        Start-Sleep -Seconds 2
    }

    return $false
}

function Restart-ClashCore {
    param([string]$Reason)

    Invoke-Logged "restart Clash core: $Reason" {
        $procs = Get-Process verge-mihomo -ErrorAction SilentlyContinue
        foreach ($proc in $procs) {
            "Stopping verge-mihomo PID $($proc.Id)"
            Stop-Process -Id $proc.Id -Force
        }

        $deadline = (Get-Date).AddSeconds(20)
        while ((Get-Date) -lt $deadline -and (Get-Process verge-mihomo -ErrorAction SilentlyContinue)) {
            Start-Sleep -Milliseconds 500
        }

        $args = @(
            "-d", $ClashHome,
            "-f", $script:ClashConfigPath,
            "-ext-ctl-pipe", "\\.\pipe\verge-mihomo"
        )
        $newProc = Start-Process -FilePath $ClashCoreExe -ArgumentList $args -WindowStyle Hidden -PassThru
        "Started verge-mihomo PID $($newProc.Id)"
    }

    if (-not (Test-ClashProxyReady -TimeoutSeconds 40)) {
        throw "Clash proxy did not become ready after restart: $Reason"
    }
}

function Set-ClashTunEnabledInText {
    param(
        [string]$Text,
        [bool]$Enable
    )

    $lines = $Text -split "`r?`n", -1
    $inTun = $false
    $changed = $false
    $target = if ($Enable) { "  enable: true" } else { "  enable: false" }

    for ($idx = 0; $idx -lt $lines.Count; $idx++) {
        $line = $lines[$idx]
        if ($line -match "^tun:\s*$") {
            $inTun = $true
            continue
        }
        if ($inTun -and $line -match "^\S") {
            break
        }
        if ($inTun -and $line -match "^\s+enable:\s*(true|false)\s*$") {
            if ($lines[$idx] -ne $target) {
                $lines[$idx] = $target
                $changed = $true
            }
            break
        }
    }

    if (-not $changed -and $Enable) {
        # Treat "already enabled" as a valid no-op, but fail if no tun.enable was found.
        $foundEnabled = $false
        for ($idx = 0; $idx -lt $lines.Count; $idx++) {
            if ($lines[$idx] -match "^tun:\s*$") { $inTun = $true; continue }
            if ($inTun -and $lines[$idx] -match "^\S") { break }
            if ($inTun -and $lines[$idx] -match "^\s+enable:\s*true\s*$") { $foundEnabled = $true; break }
        }
        if (-not $foundEnabled) {
            throw "Could not find tun.enable in Clash config."
        }
    }

    return ($lines -join "`r`n")
}

function Enable-TrialClashTun {
    Invoke-Logged "Clash TUN before trial" {
        if (-not (Test-Path -LiteralPath $script:ClashConfigPath)) {
            throw "Missing Clash config: $($script:ClashConfigPath)"
        }
        "ConfigPath=$($script:ClashConfigPath)"
        "BackupPath=$($script:ClashTunBackupPath)"
        $i = 0
        Get-Content -LiteralPath $script:ClashConfigPath | ForEach-Object {
            $i++
            if ($i -ge 135 -and $i -le 145) { "{0,4}: {1}" -f $i, $_ }
        }
        Get-NetAdapter -IncludeHidden | Where-Object { $_.Name -match "Meta|TUN|Clash|Mihomo" -or $_.InterfaceDescription -match "Meta|TUN|Clash|Mihomo" } |
            Select-Object Name, InterfaceDescription, Status, LinkSpeed, ifIndex |
            Format-Table -AutoSize
    }

    $script:OriginalClashConfigText = Get-Content -LiteralPath $script:ClashConfigPath -Raw
    Set-Content -LiteralPath $script:ClashTunBackupPath -Value $script:OriginalClashConfigText -Encoding UTF8
    $newText = Set-ClashTunEnabledInText -Text $script:OriginalClashConfigText -Enable $true
    Set-Content -LiteralPath $script:ClashConfigPath -Value $newText -Encoding UTF8
    $script:ClashTunChanged = $true

    Restart-ClashCore -Reason "enable temporary TUN"
    Start-Sleep -Seconds 8

    Invoke-Logged "Clash TUN after temporary enable" {
        $i = 0
        Get-Content -LiteralPath $script:ClashConfigPath | ForEach-Object {
            $i++
            if ($i -ge 135 -and $i -le 145) { "{0,4}: {1}" -f $i, $_ }
        }
        Get-NetAdapter -IncludeHidden | Where-Object { $_.Name -match "Meta|TUN|Clash|Mihomo" -or $_.InterfaceDescription -match "Meta|TUN|Clash|Mihomo" } |
            Select-Object Name, InterfaceDescription, Status, LinkSpeed, ifIndex |
            Format-Table -AutoSize
        Get-NetRoute -DestinationPrefix "0.0.0.0/0", "::/0" |
            Sort-Object AddressFamily, RouteMetric, InterfaceMetric |
            Select-Object DestinationPrefix, NextHop, InterfaceAlias, InterfaceIndex, RouteMetric, InterfaceMetric, AddressFamily |
            Format-Table -AutoSize
    }
}

function Restore-TrialClashTun {
    if ($script:ClashTunChanged -and $null -ne $script:OriginalClashConfigText) {
        Invoke-Logged "Clash TUN restore original config" {
            Set-Content -LiteralPath $script:ClashConfigPath -Value $script:OriginalClashConfigText -Encoding UTF8
            "Restored original Clash config from in-memory backup."
        }
        try {
            Restart-ClashCore -Reason "restore original TUN config"
        }
        catch {
            Write-Log ("ERROR restoring Clash core after TUN trial: {0}" -f $_.Exception.Message)
        }
        $script:ClashTunChanged = $false
    }
    else {
        Write-Log "Clash TUN restore skipped: no temporary TUN change was applied."
    }

    Invoke-Logged "Clash TUN final state" {
        $i = 0
        Get-Content -LiteralPath $script:ClashConfigPath | ForEach-Object {
            $i++
            if ($i -ge 135 -and $i -le 145) { "{0,4}: {1}" -f $i, $_ }
        }
        Get-NetAdapter -IncludeHidden | Where-Object { $_.Name -match "Meta|TUN|Clash|Mihomo" -or $_.InterfaceDescription -match "Meta|TUN|Clash|Mihomo" } |
            Select-Object Name, InterfaceDescription, Status, LinkSpeed, ifIndex |
            Format-Table -AutoSize
    }
}

function Enable-TrialNrptCodexDns {
    Invoke-Logged "NRPT before trial" {
        Get-DnsClientNrptRule -ErrorAction SilentlyContinue |
            Select-Object Name, Namespace, NameServers, Comment |
            Format-Table -AutoSize
    }

    foreach ($namespace in $script:NrptTrialNamespaces) {
        $existing = Get-DnsClientNrptRule -ErrorAction SilentlyContinue |
            Where-Object { $_.Namespace -contains $namespace -or $_.Namespace -eq $namespace }
        if ($existing) {
            throw "NRPT rule already exists for namespace $namespace; refusing to overwrite existing policy."
        }

        $displayName = ("CodexClashTrial-{0}-{1}" -f $Timestamp, ($namespace -replace "[^A-Za-z0-9]", "_"))
        $rule = Add-DnsClientNrptRule `
            -Namespace $namespace `
            -NameServers "198.18.0.2" `
            -DisplayName $displayName `
            -Comment $script:NrptTrialComment `
            -PassThru `
            -ErrorAction Stop
        if ($rule.Name) {
            $script:NrptTrialCreatedRuleNames.Add($rule.Name) | Out-Null
        }
    }

    Invoke-Logged "NRPT after temporary rules" {
        Get-DnsClientNrptRule -ErrorAction SilentlyContinue |
            Where-Object { $_.Comment -eq $script:NrptTrialComment -or $_.Name -in $script:NrptTrialCreatedRuleNames } |
            Select-Object Name, Namespace, NameServers, Comment |
            Format-Table -AutoSize
    }
}

function Restore-TrialNrptCodexDns {
    $createdNames = @()
    foreach ($ruleName in $script:NrptTrialCreatedRuleNames) {
        $createdNames += $ruleName
    }
    if ($createdNames.Count -eq 0) {
        Write-Log "NRPT restore skipped: no temporary NRPT rules were created."
    }
    else {
        foreach ($ruleName in $createdNames) {
            Invoke-Logged "NRPT remove temporary rule $ruleName" {
                Remove-DnsClientNrptRule -Name $ruleName -Force -ErrorAction SilentlyContinue
            }
        }
        $script:NrptTrialCreatedRuleNames.Clear()
    }

    Invoke-Logged "NRPT final state" {
        Get-DnsClientNrptRule -ErrorAction SilentlyContinue |
            Where-Object { $_.Comment -like "CodexClashTrial*" -or $_.DisplayName -like "CodexClashTrial*" } |
            Select-Object Name, Namespace, NameServers, Comment |
            Format-Table -AutoSize
    }
}

function Add-TrialSplitRoute {
    param(
        [string]$DestinationPrefix,
        [int]$InterfaceIndex,
        [string]$InterfaceAlias,
        [string]$NextHop,
        [string]$AddressFamily
    )

    $existing = Get-NetRoute -DestinationPrefix $DestinationPrefix -InterfaceIndex $InterfaceIndex -NextHop $NextHop -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Log ("Split route already exists; will not remove it later: {0} via {1}" -f $DestinationPrefix, $NextHop)
        return
    }

    New-NetRoute -DestinationPrefix $DestinationPrefix -InterfaceIndex $InterfaceIndex -NextHop $NextHop -RouteMetric 0 -ErrorAction Stop | Out-Null
    $script:SplitRouteTrialAddedRoutes.Add([pscustomobject]@{
        DestinationPrefix = $DestinationPrefix
        InterfaceIndex = $InterfaceIndex
        InterfaceAlias = $InterfaceAlias
        NextHop = $NextHop
        AddressFamily = $AddressFamily
    }) | Out-Null
}

function Enable-TrialIpv6SplitRoute {
    Invoke-Logged "Split route before trial" {
        Get-NetRoute -DestinationPrefix "0.0.0.0/0", "0.0.0.0/1", "128.0.0.0/1", "::/0", "::/1", "8000::/1" -ErrorAction SilentlyContinue |
            Sort-Object AddressFamily, DestinationPrefix, RouteMetric, InterfaceMetric |
            Select-Object DestinationPrefix, NextHop, InterfaceAlias, InterfaceIndex, RouteMetric, InterfaceMetric, AddressFamily |
            Format-Table -AutoSize
    }

    $metaV4 = Get-NetRoute -DestinationPrefix "0.0.0.0/0" -InterfaceAlias "Meta" -ErrorAction Stop | Select-Object -First 1
    Add-TrialSplitRoute -DestinationPrefix "0.0.0.0/1" -InterfaceIndex $metaV4.ifIndex -InterfaceAlias "Meta" -NextHop $metaV4.NextHop -AddressFamily "IPv4"
    Add-TrialSplitRoute -DestinationPrefix "128.0.0.0/1" -InterfaceIndex $metaV4.ifIndex -InterfaceAlias "Meta" -NextHop $metaV4.NextHop -AddressFamily "IPv4"

    $metaV6 = Get-NetRoute -DestinationPrefix "::/0" -InterfaceAlias "Meta" -ErrorAction Stop | Select-Object -First 1
    Add-TrialSplitRoute -DestinationPrefix "::/1" -InterfaceIndex $metaV6.ifIndex -InterfaceAlias "Meta" -NextHop $metaV6.NextHop -AddressFamily "IPv6"
    Add-TrialSplitRoute -DestinationPrefix "8000::/1" -InterfaceIndex $metaV6.ifIndex -InterfaceAlias "Meta" -NextHop $metaV6.NextHop -AddressFamily "IPv6"

    Invoke-Logged "Split route after temporary rules" {
        Get-NetRoute -DestinationPrefix "0.0.0.0/0", "0.0.0.0/1", "128.0.0.0/1", "::/0", "::/1", "8000::/1" -ErrorAction SilentlyContinue |
            Sort-Object AddressFamily, DestinationPrefix, RouteMetric, InterfaceMetric |
            Select-Object DestinationPrefix, NextHop, InterfaceAlias, InterfaceIndex, RouteMetric, InterfaceMetric, AddressFamily |
            Format-Table -AutoSize
    }
}

function Restore-TrialIpv6SplitRoute {
    $routes = @()
    foreach ($route in $script:SplitRouteTrialAddedRoutes) {
        $routes += $route
    }
    if ($routes.Count -eq 0) {
        Write-Log "Split route restore skipped: no temporary split routes were created."
    }
    else {
        foreach ($route in $routes) {
            Invoke-Logged ("Split route remove temporary route {0}" -f $route.DestinationPrefix) {
                Get-NetRoute -DestinationPrefix $route.DestinationPrefix -InterfaceIndex $route.InterfaceIndex -NextHop $route.NextHop -ErrorAction SilentlyContinue |
                    Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
            }
        }
        $script:SplitRouteTrialAddedRoutes.Clear()
    }

    Invoke-Logged "Split route final state" {
        Get-NetRoute -DestinationPrefix "0.0.0.0/1", "128.0.0.0/1", "::/1", "8000::/1" -ErrorAction SilentlyContinue |
            Where-Object { $_.InterfaceAlias -eq "Meta" } |
            Select-Object DestinationPrefix, NextHop, InterfaceAlias, InterfaceIndex, RouteMetric, InterfaceMetric, AddressFamily |
            Format-Table -AutoSize
    }
}

function Write-NrptCodexDnsValidation {
    param([string]$Label)

    Invoke-Logged "$Label NRPT targeted DNS resolution" {
        foreach ($name in @("api.openai.com", "chatgpt.com", "github.com")) {
            "--- default resolver: $name ---"
            Resolve-DnsName -Name $name -Type A -DnsOnly -ErrorAction SilentlyContinue |
                Select-Object Name, IPAddress, Type, Section |
                Format-Table -AutoSize
            "--- Clash DNS 198.18.0.2: $name ---"
            Resolve-DnsName -Name $name -Type A -DnsOnly -Server "198.18.0.2" -ErrorAction SilentlyContinue |
                Select-Object Name, IPAddress, Type, Section |
                Format-Table -AutoSize
        }
    }

    Invoke-CurlProbe -Title "$Label direct OpenAI API reachability" -Url "https://api.openai.com/v1/models" -MaxTime 15
    Invoke-CurlProbe -Title "$Label clash proxy OpenAI API reachability" -Url "https://api.openai.com/v1/models" -UseProxy -MaxTime 15
}

function Invoke-BoundedProxyDownload {
    param(
        [string]$Title,
        [string]$Url,
        [long]$MaxBytes,
        [int]$TimeoutSeconds = 120
    )

    Invoke-Logged $Title {
        $handler = New-Object System.Net.Http.HttpClientHandler
        $handler.AllowAutoRedirect = $true
        $handler.MaxAutomaticRedirections = 10
        $handler.Proxy = New-Object System.Net.WebProxy($ProxyUrl)
        $handler.UseProxy = $true

        $client = New-Object System.Net.Http.HttpClient($handler)
        $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)

        $buffer = New-Object byte[] 65536
        $totalBytes = [Int64]0
        $firstByteSeconds = $null
        $sw = [Diagnostics.Stopwatch]::StartNew()

        try {
            $response = $client.GetAsync($Url, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
            $statusCode = [int]$response.StatusCode
            $contentLength = $response.Content.Headers.ContentLength
            $finalUrl = $response.RequestMessage.RequestUri.AbsoluteUri
            $stream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()

            while ($totalBytes -lt $MaxBytes) {
                $remaining = $MaxBytes - $totalBytes
                $readSize = [Math]::Min($buffer.Length, $remaining)
                $read = $stream.Read($buffer, 0, [int]$readSize)
                if ($read -le 0) {
                    break
                }
                if ($null -eq $firstByteSeconds) {
                    $firstByteSeconds = $sw.Elapsed.TotalSeconds
                }
                $totalBytes += $read
            }

            $sw.Stop()
            $elapsed = [Math]::Max($sw.Elapsed.TotalSeconds, 0.001)
            $mib = $totalBytes / 1MB
            $mibps = $mib / $elapsed
            $mbps = ($totalBytes * 8 / 1000000) / $elapsed
            $completedLimit = $totalBytes -ge $MaxBytes

            [pscustomobject]@{
                Result = "OK"
                StatusCode = $statusCode
                RequestedUrl = $Url
                FinalUrl = $finalUrl
                ContentLength = $contentLength
                BytesRead = $totalBytes
                MiBRead = [Math]::Round($mib, 2)
                Seconds = [Math]::Round($elapsed, 3)
                FirstByteSeconds = if ($null -eq $firstByteSeconds) { $null } else { [Math]::Round($firstByteSeconds, 3) }
                MiBps = [Math]::Round($mibps, 3)
                Mbps = [Math]::Round($mbps, 3)
                HitByteLimit = $completedLimit
                Error = ""
            } | Format-List
        }
        catch {
            $sw.Stop()
            [pscustomobject]@{
                Result = "FAIL"
                RequestedUrl = $Url
                BytesRead = $totalBytes
                MiBRead = [Math]::Round(($totalBytes / 1MB), 2)
                Seconds = [Math]::Round($sw.Elapsed.TotalSeconds, 3)
                Error = $_.Exception.Message
            } | Format-List
        }
        finally {
            if ($stream) { $stream.Dispose() }
            if ($response) { $response.Dispose() }
            $client.Dispose()
            $handler.Dispose()
        }
    }
}

function Test-WinHttpProxyIsDirect {
    param([string]$Text)
    return ($Text -match "Direct access" -or $Text -match "直接访问" -or $Text -match "no proxy server")
}

function Initialize-WinInetPerConnApi {
    try {
        [WinInetPerConn.Native] | Out-Null
        return
    }
    catch {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

namespace WinInetPerConn {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct INTERNET_PER_CONN_OPTION_LIST {
        public int dwSize;
        public string pszConnection;
        public int dwOptionCount;
        public int dwOptionError;
        public IntPtr pOptions;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct INTERNET_PER_CONN_OPTION {
        public int dwOption;
        public INTERNET_PER_CONN_OPTION_VALUE Value;
    }

    [StructLayout(LayoutKind.Explicit, CharSet = CharSet.Unicode)]
    public struct INTERNET_PER_CONN_OPTION_VALUE {
        [FieldOffset(0)] public int dwValue;
        [FieldOffset(0)] public IntPtr pszValue;
    }

    public static class Native {
        public const int INTERNET_OPTION_REFRESH = 37;
        public const int INTERNET_OPTION_SETTINGS_CHANGED = 39;
        public const int INTERNET_OPTION_PER_CONNECTION_OPTION = 75;

        public const int INTERNET_PER_CONN_FLAGS = 1;
        public const int INTERNET_PER_CONN_PROXY_SERVER = 2;
        public const int INTERNET_PER_CONN_PROXY_BYPASS = 3;

        public const int PROXY_TYPE_DIRECT = 0x00000001;
        public const int PROXY_TYPE_PROXY = 0x00000002;

        [DllImport("wininet.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        public static extern bool InternetSetOption(IntPtr hInternet, int dwOption, IntPtr lpBuffer, int dwBufferLength);
    }
}
"@
    }
}

function Set-RasWinInetProxy {
    param(
        [string]$ConnectionName,
        [string]$ProxyServer,
        [string]$ProxyBypass = "localhost;127.*;::1;<local>"
    )

    Initialize-WinInetPerConnApi

    $optionSize = [Runtime.InteropServices.Marshal]::SizeOf((New-Object WinInetPerConn.INTERNET_PER_CONN_OPTION))
    $listSize = [Runtime.InteropServices.Marshal]::SizeOf((New-Object WinInetPerConn.INTERNET_PER_CONN_OPTION_LIST))

    $optionsPtr = [Runtime.InteropServices.Marshal]::AllocCoTaskMem($optionSize * 3)
    $serverPtr = [Runtime.InteropServices.Marshal]::StringToCoTaskMemUni($ProxyServer)
    $bypassPtr = [Runtime.InteropServices.Marshal]::StringToCoTaskMemUni($ProxyBypass)
    $listPtr = [IntPtr]::Zero

    try {
        $opt0 = New-Object WinInetPerConn.INTERNET_PER_CONN_OPTION
        $opt0.dwOption = [WinInetPerConn.Native]::INTERNET_PER_CONN_FLAGS
        $opt0.Value.dwValue = [WinInetPerConn.Native]::PROXY_TYPE_DIRECT -bor [WinInetPerConn.Native]::PROXY_TYPE_PROXY

        $opt1 = New-Object WinInetPerConn.INTERNET_PER_CONN_OPTION
        $opt1.dwOption = [WinInetPerConn.Native]::INTERNET_PER_CONN_PROXY_SERVER
        $opt1.Value.pszValue = $serverPtr

        $opt2 = New-Object WinInetPerConn.INTERNET_PER_CONN_OPTION
        $opt2.dwOption = [WinInetPerConn.Native]::INTERNET_PER_CONN_PROXY_BYPASS
        $opt2.Value.pszValue = $bypassPtr

        [Runtime.InteropServices.Marshal]::StructureToPtr($opt0, [IntPtr]($optionsPtr.ToInt64() + 0 * $optionSize), $false)
        [Runtime.InteropServices.Marshal]::StructureToPtr($opt1, [IntPtr]($optionsPtr.ToInt64() + 1 * $optionSize), $false)
        [Runtime.InteropServices.Marshal]::StructureToPtr($opt2, [IntPtr]($optionsPtr.ToInt64() + 2 * $optionSize), $false)

        $list = New-Object WinInetPerConn.INTERNET_PER_CONN_OPTION_LIST
        $list.dwSize = $listSize
        $list.pszConnection = $ConnectionName
        $list.dwOptionCount = 3
        $list.dwOptionError = 0
        $list.pOptions = $optionsPtr

        $listPtr = [Runtime.InteropServices.Marshal]::AllocCoTaskMem($listSize)
        [Runtime.InteropServices.Marshal]::StructureToPtr($list, $listPtr, $false)

        $ok = [WinInetPerConn.Native]::InternetSetOption([IntPtr]::Zero, [WinInetPerConn.Native]::INTERNET_OPTION_PER_CONNECTION_OPTION, $listPtr, $listSize)
        if (-not $ok) {
            $err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
            throw "InternetSetOption PER_CONNECTION_OPTION failed, GetLastError=$err"
        }

        [WinInetPerConn.Native]::InternetSetOption([IntPtr]::Zero, [WinInetPerConn.Native]::INTERNET_OPTION_SETTINGS_CHANGED, [IntPtr]::Zero, 0) | Out-Null
        [WinInetPerConn.Native]::InternetSetOption([IntPtr]::Zero, [WinInetPerConn.Native]::INTERNET_OPTION_REFRESH, [IntPtr]::Zero, 0) | Out-Null
    }
    finally {
        if ($listPtr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::FreeCoTaskMem($listPtr) }
        if ($optionsPtr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::FreeCoTaskMem($optionsPtr) }
        if ($serverPtr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::FreeCoTaskMem($serverPtr) }
        if ($bypassPtr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::FreeCoTaskMem($bypassPtr) }
    }
}

function Invoke-WinInetRefresh {
    Initialize-WinInetPerConnApi
    [WinInetPerConn.Native]::InternetSetOption([IntPtr]::Zero, [WinInetPerConn.Native]::INTERNET_OPTION_SETTINGS_CHANGED, [IntPtr]::Zero, 0) | Out-Null
    [WinInetPerConn.Native]::InternetSetOption([IntPtr]::Zero, [WinInetPerConn.Native]::INTERNET_OPTION_REFRESH, [IntPtr]::Zero, 0) | Out-Null
}

function Enable-TrialRasWinInetProxy {
    Invoke-Logged "RAS WinINet before trial proxy" {
        Get-ItemProperty -LiteralPath $script:ConnectionsRegPath |
            Select-Object -Property $RasEntry |
            Format-List
        Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings" |
            Select-Object ProxyEnable, ProxyServer, ProxyOverride, AutoConfigURL |
            Format-List
    }

    $connectionProps = Get-ItemProperty -LiteralPath $script:ConnectionsRegPath -ErrorAction Stop
    $existingValue = $connectionProps.$RasEntry
    if ($null -eq $existingValue) {
        Write-Log "RAS_WININET_TRIAL_SKIPPED: no per-connection WinINet settings value found for $RasEntry."
        return
    }

    $script:OriginalRasConnectionSettings = [byte[]]$existingValue.Clone()
    Set-RasWinInetProxy -ConnectionName $RasEntry -ProxyServer $WinHttpProxyServer
    $script:RasWinInetProxyChanged = $true

    Invoke-Logged "RAS WinINet after temporary proxy" {
        Get-ItemProperty -LiteralPath $script:ConnectionsRegPath |
            Select-Object -Property $RasEntry |
            Format-List
        Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings" |
            Select-Object ProxyEnable, ProxyServer, ProxyOverride, AutoConfigURL |
            Format-List
    }
}

function Restore-TrialRasWinInetProxy {
    if ($script:RasWinInetProxyChanged -and $null -ne $script:OriginalRasConnectionSettings) {
        Invoke-Logged "RAS WinINet restore original settings" {
            Set-ItemProperty -LiteralPath $script:ConnectionsRegPath -Name $RasEntry -Value $script:OriginalRasConnectionSettings
            Invoke-WinInetRefresh
            "Restored per-connection WinINet settings for $RasEntry."
        }
        $script:RasWinInetProxyChanged = $false
    }
    else {
        Write-Log "RAS WinINet restore skipped: no temporary RAS WinINet change was applied."
    }

    Invoke-Logged "RAS WinINet final state" {
        Get-ItemProperty -LiteralPath $script:ConnectionsRegPath |
            Select-Object -Property $RasEntry |
            Format-List
    }
}

function Get-UserInternetProxySnapshot {
    $props = Get-ItemProperty -LiteralPath $script:InternetSettingsRegPath -ErrorAction Stop
    return [ordered]@{
        ProxyEnable = $props.ProxyEnable
        ProxyServer = $props.ProxyServer
        ProxyOverride = $props.ProxyOverride
        AutoConfigURL = $props.AutoConfigURL
    }
}

function Set-NullableRegString {
    param(
        [string]$Path,
        [string]$Name,
        $Value
    )

    if ($null -eq $Value) {
        Remove-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction SilentlyContinue
    }
    else {
        Set-ItemProperty -LiteralPath $Path -Name $Name -Value ([string]$Value)
    }
}

function Enable-TrialUserInternetProxy {
    Invoke-Logged "USER Internet proxy before trial" {
        Get-ItemProperty -LiteralPath $script:InternetSettingsRegPath |
            Select-Object ProxyEnable, ProxyServer, ProxyOverride, AutoConfigURL |
            Format-List
    }

    $script:OriginalUserInternetSettings = Get-UserInternetProxySnapshot
    Set-ItemProperty -LiteralPath $script:InternetSettingsRegPath -Name ProxyEnable -Type DWord -Value 1
    Set-NullableRegString -Path $script:InternetSettingsRegPath -Name ProxyServer -Value $WinHttpProxyServer
    Set-NullableRegString -Path $script:InternetSettingsRegPath -Name ProxyOverride -Value $UserProxyBypass
    Set-NullableRegString -Path $script:InternetSettingsRegPath -Name AutoConfigURL -Value ""
    Invoke-WinInetRefresh
    $script:UserInternetProxyChanged = $true

    Invoke-Logged "USER Internet proxy after temporary trial setting" {
        Get-ItemProperty -LiteralPath $script:InternetSettingsRegPath |
            Select-Object ProxyEnable, ProxyServer, ProxyOverride, AutoConfigURL |
            Format-List
    }

    Start-Sleep -Seconds 5
}

function Restore-TrialUserInternetProxy {
    if ($script:UserInternetProxyChanged -and $null -ne $script:OriginalUserInternetSettings) {
        Invoke-Logged "USER Internet proxy restore original active settings" {
            if ($null -eq $script:OriginalUserInternetSettings.ProxyEnable) {
                Remove-ItemProperty -LiteralPath $script:InternetSettingsRegPath -Name ProxyEnable -ErrorAction SilentlyContinue
            }
            else {
                Set-ItemProperty -LiteralPath $script:InternetSettingsRegPath -Name ProxyEnable -Type DWord -Value ([int]$script:OriginalUserInternetSettings.ProxyEnable)
            }
            Set-NullableRegString -Path $script:InternetSettingsRegPath -Name ProxyServer -Value $script:OriginalUserInternetSettings.ProxyServer
            Set-NullableRegString -Path $script:InternetSettingsRegPath -Name ProxyOverride -Value $script:OriginalUserInternetSettings.ProxyOverride
            Set-NullableRegString -Path $script:InternetSettingsRegPath -Name AutoConfigURL -Value $script:OriginalUserInternetSettings.AutoConfigURL
            Invoke-WinInetRefresh
            "Restored active user Internet proxy settings."
        }
        $script:UserInternetProxyChanged = $false
    }
    else {
        Write-Log "USER Internet proxy restore skipped: no temporary user proxy change was applied."
    }

    Invoke-Logged "USER Internet proxy final active state" {
        Get-ItemProperty -LiteralPath $script:InternetSettingsRegPath |
            Select-Object ProxyEnable, ProxyServer, ProxyOverride, AutoConfigURL |
            Format-List
    }
}

function Enable-TrialWinHttpProxy {
    Invoke-Logged "WINHTTP before trial proxy" {
        & netsh.exe winhttp show proxy
    }

    $script:OriginalWinHttpProxyText = (& netsh.exe winhttp show proxy 2>&1 | Out-String)
    if (-not (Test-WinHttpProxyIsDirect -Text $script:OriginalWinHttpProxyText)) {
        Write-Log "WINHTTP_TRIAL_SKIPPED: existing WinHTTP proxy is not direct, so this script will not overwrite it."
        return
    }

    Invoke-Logged "WINHTTP set temporary proxy" {
        & netsh.exe winhttp set proxy proxy-server=$WinHttpProxyServer bypass-list="localhost;127.*;::1;<local>"
    }
    $script:WinHttpProxyChanged = $true

    Invoke-Logged "WINHTTP after temporary proxy" {
        & netsh.exe winhttp show proxy
    }
}

function Restore-TrialWinHttpProxy {
    if ($script:WinHttpProxyChanged) {
        Invoke-Logged "WINHTTP restore original direct proxy" {
            & netsh.exe winhttp reset proxy
        }
        $script:WinHttpProxyChanged = $false
    }
    else {
        Write-Log "WINHTTP restore skipped: no temporary WinHTTP change was applied."
    }

    Invoke-Logged "WINHTTP final state" {
        & netsh.exe winhttp show proxy
    }
}

function Write-CodexConnectivitySnapshot {
    param([string]$Label)

    Invoke-Logged "$Label Codex process command lines" {
        Get-CimInstance Win32_Process |
            Where-Object { $_.Name -match "Codex|codex" } |
            Select-Object ProcessId, Name, CommandLine |
            Format-List
    }

    Invoke-Logged "$Label Codex TCP connections" {
        $codexPids = Get-Process |
            Where-Object { $_.ProcessName -match "Codex|codex" } |
            Select-Object -ExpandProperty Id

        $rows = foreach ($codexPid in $codexPids) {
            Get-NetTCPConnection -OwningProcess $codexPid -ErrorAction SilentlyContinue |
                ForEach-Object {
                    [pscustomobject]@{
                        PID = $codexPid
                        State = $_.State
                        LocalAddress = $_.LocalAddress
                        LocalPort = $_.LocalPort
                        RemoteAddress = $_.RemoteAddress
                        RemotePort = $_.RemotePort
                        ViaClash = ($_.RemoteAddress -eq "127.0.0.1" -and $_.RemotePort -eq 7897)
                    }
                }
        }

        $rows | Sort-Object PID, State, RemoteAddress, RemotePort | Format-Table -AutoSize
        ""
        "Connection counts:"
        $rows | Group-Object State, ViaClash | Sort-Object Count -Descending | Select-Object Count, Name | Format-Table -AutoSize
    }

    Invoke-Logged "$Label proxy settings" {
        "WinHTTP:"
        & netsh.exe winhttp show proxy
        ""
        "User Internet Settings:"
        Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings" |
            Select-Object ProxyEnable, ProxyServer, ProxyOverride, AutoConfigURL |
            Format-List
    }

    Invoke-Logged "$Label OpenAI/Codex endpoints via Clash" {
        $urls = @(
            "https://api.openai.com/v1/models",
            "https://chatgpt.com/",
            "https://chat.openai.com/",
            "https://auth.openai.com/"
        )
        foreach ($url in $urls) {
            "--- $url ---"
            & curl.exe -I -L --max-time 15 --proxy $ProxyUrl -o NUL -s -w "code=%{http_code} dns=%{time_namelookup}s connect=%{time_connect}s tls=%{time_appconnect}s starttransfer=%{time_starttransfer}s total=%{time_total}s remote=%{remote_ip} err=%{errormsg}`n" $url
        }
    }

    Invoke-Logged "$Label OpenAI/Codex endpoints direct" {
        $urls = @(
            "https://api.openai.com/v1/models",
            "https://chatgpt.com/",
            "https://chat.openai.com/"
        )
        foreach ($url in $urls) {
            "--- $url ---"
            & curl.exe -I -L --max-time 8 --noproxy "*" -o NUL -s -w "code=%{http_code} dns=%{time_namelookup}s connect=%{time_connect}s tls=%{time_appconnect}s starttransfer=%{time_starttransfer}s total=%{time_total}s remote=%{remote_ip} err=%{errormsg}`n" $url
        }
    }
}

function Test-RasEntryConnected {
    param([string]$EntryName)
    $status = (& rasdial.exe 2>&1 | Out-String)
    return ($status -match [regex]::Escape($EntryName))
}

function Write-NetworkSnapshot {
    param([string]$Label)

    Invoke-Logged "$Label RAS status" {
        & rasdial.exe
    }
    Invoke-Logged "$Label default routes" {
        Get-NetRoute -DestinationPrefix "0.0.0.0/0", "0.0.0.0/1", "128.0.0.0/1", "::/0", "::/1", "8000::/1" -ErrorAction SilentlyContinue |
            Sort-Object AddressFamily, RouteMetric, InterfaceMetric |
            Select-Object DestinationPrefix, NextHop, InterfaceAlias, InterfaceIndex, RouteMetric, InterfaceMetric, AddressFamily |
            Format-Table -AutoSize
    }
    Invoke-Logged "$Label DNS server addresses" {
        Get-DnsClientServerAddress |
            Sort-Object InterfaceIndex, AddressFamily |
            Select-Object InterfaceIndex, InterfaceAlias, AddressFamily, ServerAddresses |
            Format-Table -AutoSize
    }
    Invoke-Logged "$Label NRPT rules" {
        Get-DnsClientNrptRule -ErrorAction SilentlyContinue |
            Select-Object Name, Namespace, NameServers, Comment |
            Format-Table -AutoSize
    }
    Invoke-Logged "$Label adapters" {
        Get-NetAdapter |
            Sort-Object ifIndex |
            Select-Object Name, InterfaceDescription, Status, MacAddress, LinkSpeed, ifIndex, MediaType |
            Format-Table -AutoSize
    }
    Invoke-Logged "$Label ethernet IP" {
        Get-NetIPAddress -InterfaceIndex $EthernetIfIndex -ErrorAction SilentlyContinue |
            Select-Object InterfaceAlias, IPAddress, AddressFamily, PrefixLength, PrefixOrigin, SuffixOrigin, AddressState |
            Format-Table -AutoSize
    }
}

function Write-ClashSnapshot {
    param([string]$Label)

    Invoke-Logged "$Label clash process/listen" {
        $proc = Get-Process verge-mihomo -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($proc) {
            $proc | Select-Object Id, ProcessName, Path | Format-List
            Get-NetTCPConnection -OwningProcess $proc.Id -State Listen -ErrorAction SilentlyContinue |
                Select-Object LocalAddress, LocalPort, State |
                Sort-Object LocalPort |
                Format-Table -AutoSize
        }
        else {
            "verge-mihomo not found"
        }
    }

    Invoke-CurlProbe -Title "$Label clash proxy google generate_204" -Url "https://www.google.com/generate_204" -UseProxy
    Invoke-CurlProbe -Title "$Label clash proxy OpenAI API reachability" -Url "https://api.openai.com/v1/models" -UseProxy
}

Write-Log ("LogPath={0}" -f $LogPath)
Write-Log "Purpose=test current PPPoE plus Clash, then restore by disconnecting PPPoE."
Write-Log "No credentials are stored by this script."

try {
    Write-NetworkSnapshot -Label "BEFORE_TEST"
    Write-ClashSnapshot -Label "BEFORE_TEST"

    if ($TrialWinHttpProxy) {
        Enable-TrialWinHttpProxy
    }
    if ($TrialRasWinInetProxy) {
        Enable-TrialRasWinInetProxy
    }
    if ($TrialUserInternetProxy) {
        Enable-TrialUserInternetProxy
    }
    if ($TrialClashTun) {
        Enable-TrialClashTun
    }
    if ($TrialNrptCodexDns) {
        Enable-TrialNrptCodexDns
    }
    if ($TrialIpv6SplitRoute) {
        Enable-TrialIpv6SplitRoute
    }

    Invoke-CurlProbe -Title "BEFORE_TEST direct Microsoft" -Url "https://www.microsoft.com/" -MaxTime 12
    Invoke-Logged "BEFORE_TEST ping public 119.29.29.29" {
        ping.exe -n 10 -w 1000 119.29.29.29
    }
    Invoke-Logged "BEFORE_TEST DNS resolve" {
        $targets = @("www.microsoft.com", "www.baidu.com", "www.github.com", "api.openai.com")
        $rows = foreach ($name in $targets) {
            $sw = [Diagnostics.Stopwatch]::StartNew()
            try {
                Resolve-DnsName -Name $name -Type A -DnsOnly -ErrorAction Stop | Out-Null
                $sw.Stop()
                [pscustomobject]@{ Name = $name; Ms = [math]::Round($sw.Elapsed.TotalMilliseconds, 1); Result = "OK" }
            }
            catch {
                $sw.Stop()
                [pscustomobject]@{ Name = $name; Ms = [math]::Round($sw.Elapsed.TotalMilliseconds, 1); Result = "FAIL" }
            }
        }
        $rows | Format-Table -AutoSize
    }

    if ($RunDownloadTest) {
        Invoke-CurlProbe -Title "BEFORE_TEST 25MB direct download" -Url "https://speed.cloudflare.com/__down?bytes=25000000" -MaxTime 60
        Invoke-CurlProbe -Title "BEFORE_TEST 25MB proxy download" -Url "https://speed.cloudflare.com/__down?bytes=25000000" -UseProxy -MaxTime 60
    }

    if ($RunGithubDownloadTest) {
        Invoke-CurlProbe -Title "BEFORE_TEST GitHub archive HEAD via Clash" -Url $GithubDownloadUrl -UseProxy -Head -MaxTime 20
        Invoke-BoundedProxyDownload -Title "BEFORE_TEST GitHub archive bounded download via Clash" -Url $GithubDownloadUrl -MaxBytes $GithubMaxBytes -TimeoutSeconds 120
    }

    if ($RunCodexConnectivityTest) {
        if ($TrialNrptCodexDns -or $TrialIpv6SplitRoute) {
            Write-NrptCodexDnsValidation -Label "BEFORE_TEST"
        }
        Write-CodexConnectivitySnapshot -Label "BEFORE_TEST"
    }
}
finally {
    Write-Log "=== RESTORE_BEGIN ==="
    Restore-TrialIpv6SplitRoute
    Restore-TrialNrptCodexDns
    Restore-TrialClashTun
    Restore-TrialUserInternetProxy
    Restore-TrialRasWinInetProxy
    Restore-TrialWinHttpProxy

    if (Test-RasEntryConnected -EntryName $RasEntry) {
        Invoke-Logged "disconnect RAS entry $RasEntry" {
            & rasdial.exe $RasEntry /disconnect
        }
    }
    else {
        Write-Log ("RAS entry {0} is not connected; no disconnect needed." -f $RasEntry)
    }

    Start-Sleep -Seconds 5
    Write-NetworkSnapshot -Label "AFTER_RESTORE"
    Write-ClashSnapshot -Label "AFTER_RESTORE"
    if ($RunCodexConnectivityTest) {
        Write-CodexConnectivitySnapshot -Label "AFTER_RESTORE"
    }
    Invoke-CurlProbe -Title "AFTER_RESTORE direct Microsoft" -Url "https://www.microsoft.com/" -MaxTime 12

    Invoke-Logged "AFTER_RESTORE final route decision" {
        $defaultRoutes = Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue
        $wifiDefault = $defaultRoutes | Where-Object { $_.InterfaceIndex -eq $WifiIfIndex }
        if ($wifiDefault) {
            "RESTORE_OK: IPv4 default route includes Wi-Fi interface index $WifiIfIndex."
        }
        else {
            "RESTORE_WARNING: IPv4 default route does not include Wi-Fi interface index $WifiIfIndex."
        }
    }
    Write-Log "=== RESTORE_END ==="
}
