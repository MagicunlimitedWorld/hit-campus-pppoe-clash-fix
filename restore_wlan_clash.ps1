param(
    [string]$RasEntry = "HITnet",
    [string]$ProxyUrl = "http://127.0.0.1:7897",
    [switch]$SkipProbe,
    [int]$ProbeAttempts = 3,
    [int]$ProbeRetryDelaySeconds = 3,
    [string]$Reason = "manual restore"
)

$ErrorActionPreference = "Continue"

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
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
            Get-NetRoute -DestinationPrefix $prefix -InterfaceAlias "Meta" -NextHop "198.18.0.2" -ErrorAction SilentlyContinue |
                ForEach-Object {
                    "Removing IPv4 split route: $($_.DestinationPrefix) via $($_.NextHop)"
                    $_ | Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
                }
        }

        foreach ($prefix in @("::/1", "8000::/1")) {
            Get-NetRoute -DestinationPrefix $prefix -InterfaceAlias "Meta" -NextHop "fdfe:dcba:9876::2" -ErrorAction SilentlyContinue |
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

function Write-FinalSnapshot {
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
    if (-not $SkipProbe) {
        Invoke-Logged "final Clash proxy OpenAI probe" {
            $attempts = [Math]::Max(1, $ProbeAttempts)
            for ($attempt = 1; $attempt -le $attempts; $attempt++) {
                $result = & curl.exe -I -L --max-time 12 --proxy $ProxyUrl -o NUL -s -w "code=%{http_code} dns=%{time_namelookup}s connect=%{time_connect}s tls=%{time_appconnect}s total=%{time_total}s remote=%{remote_ip} err=%{errormsg}`n" "https://api.openai.com/v1/models"
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
}

Write-Log ("LogPath={0}" -f $LogPath)
Write-Log ("Reason={0}" -f $Reason)
Write-Log "Purpose=restore WLAN plus Clash by removing Codex PPPoE temporary networking changes."

Remove-CodexNrptRules
Remove-CodexSplitRoutes
Disconnect-RasIfNeeded
Remove-StateFile
Start-Sleep -Seconds 5
Write-FinalSnapshot
Write-Log "RESTORE_WLAN_CLASH_DONE"
