param(
    [string]$RasEntry,
    [string]$ProxyUrl,
    [string]$TunInterfaceAlias,
    [string]$TunIpv4Gateway,
    [string]$TunIpv6Gateway,
    [string]$SettingsPath,
    [switch]$SkipProbe,
    [int]$ProbeAttempts = 1,
    [int]$ProbeRetryDelaySeconds = 3,
    [ValidateSet("Balanced", "Full", "Minimal")]
    [string]$ProbeMode = "Balanced",
    [string]$Reason = "manual restore"
)

$ErrorActionPreference = "Continue"

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$ConfigScript = Join-Path $ScriptDir "HitNetClashConfig.ps1"
if (Test-Path -LiteralPath $ConfigScript) {
    . $ConfigScript
    $Config = Resolve-HitNetClashConfig -ScriptDir $ScriptDir -SettingsPath $SettingsPath -RasEntry $RasEntry -ProxyUrl $ProxyUrl -TunInterfaceAlias $TunInterfaceAlias -TunIpv4Gateway $TunIpv4Gateway -TunIpv6Gateway $TunIpv6Gateway
    $RasEntry = $Config.RasEntry
    $ProxyUrl = $Config.ProxyUrl
    $TunInterfaceAlias = $Config.TunInterfaceAlias
    $TunIpv4Gateway = $Config.TunIpv4Gateway
    $TunIpv6Gateway = $Config.TunIpv6Gateway
    $ClashCoreProcessName = $Config.ClashCoreProcessName
}
else {
    if ([string]::IsNullOrWhiteSpace($RasEntry)) { $RasEntry = "HITnet" }
    if ([string]::IsNullOrWhiteSpace($ProxyUrl)) { $ProxyUrl = "http://127.0.0.1:7897" }
    if ([string]::IsNullOrWhiteSpace($TunInterfaceAlias)) { $TunInterfaceAlias = "Meta" }
    if ([string]::IsNullOrWhiteSpace($TunIpv4Gateway)) { $TunIpv4Gateway = "198.18.0.2" }
    if ([string]::IsNullOrWhiteSpace($TunIpv6Gateway)) { $TunIpv6Gateway = "fdfe:dcba:9876::2" }
    $ClashCoreProcessName = "verge-mihomo"
}
$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$RuntimeDir = Join-Path $ScriptDir ".runtime"
$RuntimeLogDir = Join-Path $RuntimeDir "logs"
$RuntimeStateDir = Join-Path $RuntimeDir "state"
foreach ($dir in @($RuntimeLogDir, $RuntimeStateDir)) {
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }
}
$LogPath = Join-Path $RuntimeLogDir ("restore_wlan_clash_{0}.log" -f $Timestamp)
$StatePath = Join-Path $RuntimeStateDir "pppoe_codex_active_state.json"
$LegacyStatePath = Join-Path $ScriptDir "pppoe_codex_active_state.json"

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

function Remove-CodexNrptRules {
    Invoke-Logged "remove CodexClash NRPT rules" {
        $rules = Get-DnsClientNrptRule -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Comment -like "CodexClashEnter*" -or
                $_.DisplayName -like "CodexClashEnter*" -or
                $_.Comment -like "CodexClashTrial*" -or
                $_.DisplayName -like "CodexClashTrial*"
            }

        foreach ($rule in $rules) {
            "Removing NRPT rule: Name=$($rule.Name) Namespace=$($rule.Namespace -join ',')"
            Remove-DnsClientNrptRule -Name $rule.Name -Force -ErrorAction SilentlyContinue
        }
    }
}

function Remove-CodexSplitRoutes {
    Invoke-Logged "remove CodexClash split routes" {
        foreach ($prefix in @("0.0.0.0/1", "128.0.0.0/1")) {
            Get-NetRoute -DestinationPrefix $prefix -InterfaceAlias $TunInterfaceAlias -NextHop $TunIpv4Gateway -ErrorAction SilentlyContinue |
                ForEach-Object {
                    "Removing IPv4 split route: $($_.DestinationPrefix) via $($_.NextHop)"
                    $_ | Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
                }
        }

        foreach ($prefix in @("::/1", "8000::/1")) {
            Get-NetRoute -DestinationPrefix $prefix -InterfaceAlias $TunInterfaceAlias -NextHop $TunIpv6Gateway -ErrorAction SilentlyContinue |
                ForEach-Object {
                    "Removing IPv6 split route: $($_.DestinationPrefix) via $($_.NextHop)"
                    $_ | Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
                }
        }
    }
}

function Disconnect-RasIfNeeded {
    Invoke-Logged "disconnect RAS entry if connected" {
        $status = (& rasdial.exe 2>&1 | Out-String)
        $status.TrimEnd()
        if ($status -match [regex]::Escape($RasEntry)) {
            & rasdial.exe $RasEntry /disconnect
        }
        else {
            "RAS entry $RasEntry is not connected."
        }
    }
}

function Remove-StateFile {
    Invoke-Logged "remove active state file" {
        foreach ($path in @($StatePath, $LegacyStatePath)) {
            if (Test-Path -LiteralPath $path) {
                Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
                "Removed $path"
            }
            else {
                "State file not found: $path"
            }
        }
    }
}

function Test-CodexNrptRemoved {
    $rules = Get-DnsClientNrptRule -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Comment -like "CodexClashEnter*" -or
            $_.DisplayName -like "CodexClashEnter*" -or
            $_.Comment -like "CodexClashTrial*" -or
            $_.DisplayName -like "CodexClashTrial*"
        }
    return (-not $rules)
}

function Test-CodexSplitRoutesRemoved {
    $routes = @(
        @{ Prefix = "0.0.0.0/1"; NextHop = $TunIpv4Gateway },
        @{ Prefix = "128.0.0.0/1"; NextHop = $TunIpv4Gateway },
        @{ Prefix = "::/1"; NextHop = $TunIpv6Gateway },
        @{ Prefix = "8000::/1"; NextHop = $TunIpv6Gateway }
    )
    $routeTable = @(Get-NetRoute -DestinationPrefix ($routes.Prefix) -ErrorAction SilentlyContinue |
        Where-Object { $_.InterfaceAlias -eq $TunInterfaceAlias })

    foreach ($route in $routes) {
        $found = $routeTable |
            Where-Object { $_.DestinationPrefix -eq $route.Prefix -and $_.NextHop -eq $route.NextHop } |
            Select-Object -First 1
        if ($found) {
            return $false
        }
    }
    return $true
}

function Test-RasDisconnected {
    $status = (& rasdial.exe 2>&1 | Out-String)
    return ($status -notmatch [regex]::Escape($RasEntry))
}

function Wait-RestoreSettled {
    Invoke-Logged "wait restore state settled" {
        for ($i = 0; $i -lt 6; $i++) {
            $nrptRemoved = Test-CodexNrptRemoved
            $routesRemoved = Test-CodexSplitRoutesRemoved
            $rasDisconnected = Test-RasDisconnected
            "attempt=$i nrpt_removed=$nrptRemoved split_routes_removed=$routesRemoved ras_disconnected=$rasDisconnected"
            if ($nrptRemoved -and $routesRemoved -and $rasDisconnected) {
                return
            }
            Start-Sleep -Seconds 1
        }
    }
}

function Write-FinalSnapshot {
    Invoke-Logged "final restore status" {
        "ras_disconnected={0}" -f (Test-RasDisconnected)
        "nrpt_removed={0}" -f (Test-CodexNrptRemoved)
        "split_routes_removed={0}" -f (Test-CodexSplitRoutesRemoved)
    }

    if ($ProbeMode -eq "Full") {
        Invoke-Logged "final RAS status" {
            & rasdial.exe
        }
        Invoke-Logged "final default and split routes" {
            Get-NetRoute -DestinationPrefix "0.0.0.0/0", "0.0.0.0/1", "128.0.0.0/1", "::/0", "::/1", "8000::/1" -ErrorAction SilentlyContinue |
                Sort-Object AddressFamily, DestinationPrefix, RouteMetric, InterfaceMetric |
                Select-Object DestinationPrefix, NextHop, InterfaceAlias, InterfaceIndex, RouteMetric, InterfaceMetric, AddressFamily |
                Format-Table -AutoSize
        }
        Invoke-Logged "final NRPT rules" {
            Get-DnsClientNrptRule -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.Comment -like "CodexClashEnter*" -or
                    $_.DisplayName -like "CodexClashEnter*" -or
                    $_.Comment -like "CodexClashTrial*" -or
                    $_.DisplayName -like "CodexClashTrial*"
                } |
                Select-Object Name, Namespace, NameServers, Comment |
                Format-Table -AutoSize
        }
        Invoke-Logged "final Clash listen" {
            $proc = Get-Process -Name $ClashCoreProcessName -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($proc) {
                $proc | Select-Object Id, ProcessName, Path | Format-List
                Get-NetTCPConnection -OwningProcess $proc.Id -State Listen -ErrorAction SilentlyContinue |
                    Select-Object LocalAddress, LocalPort, State |
                    Sort-Object LocalPort |
                    Format-Table -AutoSize
            }
            else {
                "$ClashCoreProcessName not found"
            }
        }
    }

    if (-not $SkipProbe -and $ProbeMode -ne "Minimal") {
        Invoke-Logged "final Clash proxy OpenAI probe" {
            $attempts = if ($ProbeMode -eq "Full") { [Math]::Max(3, $ProbeAttempts) } else { [Math]::Max(1, $ProbeAttempts) }
            for ($attempt = 1; $attempt -le $attempts; $attempt++) {
                $result = & curl.exe -I -L --connect-timeout 3 --max-time 8 --proxy $ProxyUrl -o NUL -s -w "code=%{http_code} dns=%{time_namelookup}s connect=%{time_connect}s tls=%{time_appconnect}s total=%{time_total}s remote=%{remote_ip} err=%{errormsg}`n" "https://api.openai.com/v1/models"
                "attempt $attempt/$attempts $result"
                if ($result -match "code=(?!000)\d{3}") {
                    "PROXY_PROBE_OK"
                    return
                }
                if ($attempt -lt $attempts) {
                    Start-Sleep -Seconds ([Math]::Max(1, $ProbeRetryDelaySeconds))
                }
            }
            "PROXY_PROBE_FAILED_AFTER_${attempts}_ATTEMPTS"
        }
    }
    elseif ($ProbeMode -eq "Minimal") {
        Write-Log "ProbeMode=Minimal; skip OpenAI proxy probe."
    }
}

Write-Log ("LogPath={0}" -f $LogPath)
Write-Log ("Reason={0}" -f $Reason)
Write-Log ("EffectiveConfig RasEntry={0} ProxyUrl={1} TunInterfaceAlias={2}" -f $RasEntry, $ProxyUrl, $TunInterfaceAlias)
Write-Log ("ProbeMode={0}" -f $ProbeMode)
Write-Log "Purpose=restore WLAN plus Clash by removing Codex PPPoE temporary networking changes."

Remove-CodexNrptRules
Remove-CodexSplitRoutes
Disconnect-RasIfNeeded
Remove-StateFile
Wait-RestoreSettled
Write-FinalSnapshot
Write-Log "RESTORE_WLAN_CLASH_DONE"
