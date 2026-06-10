param(
    [string]$RasEntry = "HITnet",
    [string]$Username,
    [pscredential]$Credential,
    [string]$ProxyUrl = "http://127.0.0.1:7897",
    [int]$WatchdogTimeoutSeconds = 180,
    [int]$ConnectAttempts = 2,
    [int]$ConnectRetryDelaySeconds = 10,
    [switch]$SkipPreRestore
)

$ErrorActionPreference = "Stop"

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$RuntimeDir = Join-Path $ScriptDir ".runtime"
$RuntimeLogDir = Join-Path $RuntimeDir "logs"
$RuntimeMarkerDir = Join-Path $RuntimeDir "markers"
$RuntimeStateDir = Join-Path $RuntimeDir "state"
foreach ($dir in @($RuntimeLogDir, $RuntimeMarkerDir, $RuntimeStateDir)) {
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }
}
$LogPath = Join-Path $RuntimeLogDir ("enter_pppoe_codex_{0}.log" -f $Timestamp)
$DonePath = Join-Path $RuntimeMarkerDir ("enter_pppoe_codex_{0}.done" -f $Timestamp)
$WatchdogLogPath = Join-Path $RuntimeLogDir ("enter_pppoe_codex_watchdog_{0}.log" -f $Timestamp)
$StatePath = Join-Path $RuntimeStateDir "pppoe_codex_active_state.json"
$RestoreScript = Join-Path $ScriptDir "restore_wlan_clash.ps1"

$NrptNamespaces = @(".openai.com", ".chatgpt.com", ".oaistatic.com", ".oaiusercontent.com", ".github.com")
$NrptComment = "CodexClashEnter temporary NRPT rule $Timestamp"
$CreatedNrptRuleNames = New-Object System.Collections.Generic.List[string]
$AddedRoutes = New-Object System.Collections.Generic.List[object]
$Entered = $false

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
    $output = & $Script 2>&1 | Out-String -Width 4096
    if ([string]::IsNullOrWhiteSpace($output)) {
        "(no output)" | Tee-Object -FilePath $LogPath -Append
    }
    else {
        $output.TrimEnd() | Tee-Object -FilePath $LogPath -Append
    }
}

function Assert-WorkspacePath {
    param([string]$Path)
    $workspace = (Resolve-Path -LiteralPath $ScriptDir).Path
    $full = [System.IO.Path]::GetFullPath($Path)
    if (-not $full.StartsWith($workspace, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Path escapes workspace: $full"
    }
}

function Get-PlainPasswordFromCredential {
    param([pscredential]$Cred)

    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Cred.Password)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

function Read-NonEmptyValue {
    param(
        [string]$Prompt,
        [string]$DefaultValue
    )

    while ($true) {
        if ([string]::IsNullOrWhiteSpace($DefaultValue)) {
            $value = Read-Host $Prompt
        }
        else {
            $value = Read-Host ("{0} [{1}]" -f $Prompt, $DefaultValue)
            if ([string]::IsNullOrWhiteSpace($value)) {
                $value = $DefaultValue
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return $value.Trim()
        }
        Write-Host "Account cannot be empty."
    }
}

function Read-NonEmptySecureString {
    param([string]$Prompt)

    while ($true) {
        $value = Read-Host $Prompt -AsSecureString
        if ($value.Length -gt 0) {
            return $value
        }
        Write-Host "Password cannot be empty."
    }
}

function Get-CredentialForRas {
    if ($Credential) {
        return $Credential
    }

    $enteredUsername = Read-NonEmptyValue -Prompt "HIT 校园网账号" -DefaultValue $Username
    $securePassword = Read-NonEmptySecureString -Prompt "HIT 校园网密码"
    return [pscredential]::new($enteredUsername, $securePassword)
}

function Start-RestoreWatchdog {
    $escapedDone = $DonePath.Replace("'", "''")
    $escapedLog = $WatchdogLogPath.Replace("'", "''")
    $escapedRestore = $RestoreScript.Replace("'", "''")
    $escapedRasEntry = $RasEntry.Replace("'", "''")
    $timeout = [Math]::Max(30, $WatchdogTimeoutSeconds)

    $watchdogScript = @"
`$ErrorActionPreference = 'Continue'
`$done = '$escapedDone'
`$log = '$escapedLog'
`$restore = '$escapedRestore'
`$ras = '$escapedRasEntry'
function Add-WatchdogLog([string]`$m) { Add-Content -LiteralPath `$log -Value ((Get-Date -Format 'yyyy-MM-ddTHH:mm:ss') + ' ' + `$m) }
Add-WatchdogLog 'watchdog started; timeout=${timeout}s'
for (`$i = 0; `$i -lt $([Math]::Ceiling($timeout / 5)); `$i++) {
    if (Test-Path -LiteralPath `$done) { Add-WatchdogLog 'done marker found; exiting'; exit 0 }
    Start-Sleep -Seconds 5
}
Add-WatchdogLog 'timeout reached; running restore script'
& `$restore -RasEntry `$ras -SkipProbe -Reason 'enter watchdog timeout' 2>&1 | Add-Content -LiteralPath `$log
"@

    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($watchdogScript))
    $powershellExe = Join-Path $PSHOME "powershell.exe"
    return Start-Process -FilePath $powershellExe -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-EncodedCommand", $encoded) -WindowStyle Hidden -PassThru
}

function PreRestore {
    if ($SkipPreRestore) {
        Write-Log "Pre-restore skipped by parameter."
        return
    }

    if (-not (Test-Path -LiteralPath $RestoreScript)) {
        throw "Restore script not found: $RestoreScript"
    }

    Invoke-Logged "pre-restore stale Codex networking changes" {
        & $RestoreScript -RasEntry $RasEntry -SkipProbe -Reason "enter pre-clean"
    }
}

function Connect-Ras {
    param([pscredential]$Cred)

    $attempts = [Math]::Max(1, $ConnectAttempts)
    $lastOutput = ""
    for ($attempt = 1; $attempt -le $attempts; $attempt++) {
        Write-Log ("=== connect RAS entry {0}, attempt {1}/{2} ===" -f $RasEntry, $attempt, $attempts)
        $plainPassword = $null
        try {
            $plainPassword = Get-PlainPasswordFromCredential -Cred $Cred
            $lastOutput = (& rasdial.exe $RasEntry $Cred.UserName $plainPassword 2>&1 | Out-String -Width 4096)
            if ([string]::IsNullOrWhiteSpace($lastOutput)) {
                "(no output)" | Tee-Object -FilePath $LogPath -Append
            }
            else {
                $lastOutput.TrimEnd() | Tee-Object -FilePath $LogPath -Append
            }
        }
        finally {
            $plainPassword = $null
        }

        Start-Sleep -Seconds 8
        $status = (& rasdial.exe 2>&1 | Out-String)
        if ($status -match [regex]::Escape($RasEntry)) {
            Write-Log ("RAS entry {0} connected on attempt {1}." -f $RasEntry, $attempt)
            return
        }

        Write-Log (Get-RasFailureHint -RasOutput $lastOutput)
        if ($attempt -lt $attempts) {
            Write-Log ("RAS entry {0} not connected; retrying after {1}s." -f $RasEntry, $ConnectRetryDelaySeconds)
            Start-Sleep -Seconds ([Math]::Max(1, $ConnectRetryDelaySeconds))
        }
    }

    throw ("RAS entry {0} did not connect after {1} attempt(s). Last hint: {2}" -f $RasEntry, $attempts, (Get-RasFailureHint -RasOutput $lastOutput))
}

function Get-RasFailureHint {
    param([string]$RasOutput)

    if ($RasOutput -match "(?i)(error|错误)\s*629| 629 ") {
        return "RAS_ERROR_629: remote side terminated PPPoE during authentication/registration. Common causes: wrong password, campus account/session restriction, PPPoE server/port/VLAN rejecting the session, or retrying too soon after a previous session."
    }
    if ($RasOutput -match "(?i)(error|错误)\s*691| 691 ") {
        return "RAS_ERROR_691: authentication failed. Re-enter the campus account password carefully."
    }
    if ($RasOutput -match "(?i)(error|错误)\s*651| 651 ") {
        return "RAS_ERROR_651: PPPoE server or physical link did not respond. Check Ethernet link, wall port, VLAN, and campus PPPoE availability."
    }
    if ($RasOutput -match "(?i)(error|错误)\s*633| 633 ") {
        return "RAS_ERROR_633: modem/PPPoE device is already in use. Disconnect stale PPPoE sessions and retry."
    }
    return "RAS_ERROR_UNKNOWN: PPPoE did not connect; inspect the preceding rasdial output."
}

function Add-EnterNrptRules {
    Invoke-Logged "NRPT before enter" {
        Get-DnsClientNrptRule -ErrorAction SilentlyContinue |
            Select-Object Name, Namespace, NameServers, Comment |
            Format-Table -AutoSize
    }

    foreach ($namespace in $NrptNamespaces) {
        $existing = Get-DnsClientNrptRule -ErrorAction SilentlyContinue |
            Where-Object { $_.Namespace -contains $namespace -or $_.Namespace -eq $namespace }
        if ($existing) {
            throw "NRPT rule already exists for namespace $namespace; refusing to overwrite existing policy."
        }

        $displayName = ("CodexClashEnter-{0}-{1}" -f $Timestamp, ($namespace -replace "[^A-Za-z0-9]", "_"))
        $rule = Add-DnsClientNrptRule -Namespace $namespace -NameServers "198.18.0.2" -DisplayName $displayName -Comment $NrptComment -PassThru -ErrorAction Stop
        if ($rule.Name) {
            $CreatedNrptRuleNames.Add($rule.Name) | Out-Null
        }
    }

    Invoke-Logged "NRPT after enter" {
        Get-DnsClientNrptRule -ErrorAction SilentlyContinue |
            Where-Object { $_.Comment -eq $NrptComment -or $_.Name -in $CreatedNrptRuleNames } |
            Select-Object Name, Namespace, NameServers, Comment |
            Format-Table -AutoSize
    }
}

function Add-SplitRoute {
    param(
        [string]$DestinationPrefix,
        [int]$InterfaceIndex,
        [string]$NextHop,
        [string]$AddressFamily
    )

    $existing = Get-NetRoute -DestinationPrefix $DestinationPrefix -InterfaceIndex $InterfaceIndex -NextHop $NextHop -ErrorAction SilentlyContinue
    if ($existing) {
        throw "Split route already exists: $DestinationPrefix via $NextHop on ifIndex $InterfaceIndex."
    }

    New-NetRoute -DestinationPrefix $DestinationPrefix -InterfaceIndex $InterfaceIndex -NextHop $NextHop -RouteMetric 0 -ErrorAction Stop | Out-Null
    $AddedRoutes.Add([pscustomobject]@{
        DestinationPrefix = $DestinationPrefix
        InterfaceIndex = $InterfaceIndex
        NextHop = $NextHop
        AddressFamily = $AddressFamily
    }) | Out-Null
}

function Add-EnterSplitRoutes {
    Invoke-Logged "routes before enter split routes" {
        Get-NetRoute -DestinationPrefix "0.0.0.0/0", "0.0.0.0/1", "128.0.0.0/1", "::/0", "::/1", "8000::/1" -ErrorAction SilentlyContinue |
            Sort-Object AddressFamily, DestinationPrefix, RouteMetric, InterfaceMetric |
            Select-Object DestinationPrefix, NextHop, InterfaceAlias, InterfaceIndex, RouteMetric, InterfaceMetric, AddressFamily |
            Format-Table -AutoSize
    }

    $metaV4 = Get-NetRoute -DestinationPrefix "0.0.0.0/0" -InterfaceAlias "Meta" -ErrorAction Stop | Select-Object -First 1
    $metaV6 = Get-NetRoute -DestinationPrefix "::/0" -InterfaceAlias "Meta" -ErrorAction Stop | Select-Object -First 1

    Add-SplitRoute -DestinationPrefix "0.0.0.0/1" -InterfaceIndex $metaV4.ifIndex -NextHop $metaV4.NextHop -AddressFamily "IPv4"
    Add-SplitRoute -DestinationPrefix "128.0.0.0/1" -InterfaceIndex $metaV4.ifIndex -NextHop $metaV4.NextHop -AddressFamily "IPv4"
    Add-SplitRoute -DestinationPrefix "::/1" -InterfaceIndex $metaV6.ifIndex -NextHop $metaV6.NextHop -AddressFamily "IPv6"
    Add-SplitRoute -DestinationPrefix "8000::/1" -InterfaceIndex $metaV6.ifIndex -NextHop $metaV6.NextHop -AddressFamily "IPv6"

    Invoke-Logged "routes after enter split routes" {
        Get-NetRoute -DestinationPrefix "0.0.0.0/0", "0.0.0.0/1", "128.0.0.0/1", "::/0", "::/1", "8000::/1" -ErrorAction SilentlyContinue |
            Sort-Object AddressFamily, DestinationPrefix, RouteMetric, InterfaceMetric |
            Select-Object DestinationPrefix, NextHop, InterfaceAlias, InterfaceIndex, RouteMetric, InterfaceMetric, AddressFamily |
            Format-Table -AutoSize
    }
}

function Save-State {
    Assert-WorkspacePath -Path $StatePath
    $nrptNames = @()
    foreach ($ruleName in $CreatedNrptRuleNames) {
        $nrptNames += $ruleName
    }
    $routes = @()
    foreach ($route in $AddedRoutes) {
        $routes += $route
    }
    $state = [pscustomobject]@{
        Timestamp = $Timestamp
        RasEntry = $RasEntry
        LogPath = $LogPath
        RestoreScript = $RestoreScript
        NrptComment = $NrptComment
        NrptRuleNames = $nrptNames
        Routes = $routes
    }
    $state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $StatePath -Encoding UTF8
}

function Test-EnterConnectivity {
    Invoke-Logged "RAS status after enter changes" {
        & rasdial.exe
    }
    Invoke-Logged "Clash listen after enter changes" {
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
    Invoke-Logged "targeted DNS after enter changes" {
        foreach ($name in @("api.openai.com", "chatgpt.com", "github.com")) {
            "--- default resolver: $name ---"
            Resolve-DnsName -Name $name -Type A -DnsOnly -ErrorAction SilentlyContinue |
                Select-Object Name, IPAddress, Type, Section |
                Format-Table -AutoSize
        }
    }
    Invoke-Logged "OpenAI direct after enter changes" {
        & curl.exe -I -L --max-time 15 --noproxy "*" -o NUL -s -w "code=%{http_code} dns=%{time_namelookup}s connect=%{time_connect}s tls=%{time_appconnect}s total=%{time_total}s remote=%{remote_ip} err=%{errormsg}`n" "https://api.openai.com/v1/models"
    }
    Invoke-Logged "OpenAI via Clash after enter changes" {
        & curl.exe -I -L --max-time 15 --proxy $ProxyUrl -o NUL -s -w "code=%{http_code} dns=%{time_namelookup}s connect=%{time_connect}s tls=%{time_appconnect}s total=%{time_total}s remote=%{remote_ip} err=%{errormsg}`n" "https://api.openai.com/v1/models"
    }
    Invoke-Logged "Codex TCP summary after enter changes" {
        $ids = Get-Process |
            Where-Object { $_.ProcessName -match "Codex|codex" } |
            Select-Object -ExpandProperty Id
        if ($ids) {
            Get-NetTCPConnection -OwningProcess $ids -ErrorAction SilentlyContinue |
                Group-Object State, RemoteAddress, RemotePort |
                Sort-Object Count -Descending |
                Select-Object Count, Name |
                Format-Table -AutoSize
        }
    }

    $direct = & curl.exe -I -L --max-time 15 --noproxy "*" -o NUL -s -w "%{http_code}" "https://api.openai.com/v1/models"
    $proxy = & curl.exe -I -L --max-time 15 --proxy $ProxyUrl -o NUL -s -w "%{http_code}" "https://api.openai.com/v1/models"
    if ($direct -ne "401" -or $proxy -ne "401") {
        throw "Connectivity validation failed: direct=$direct proxy=$proxy"
    }
}

function Restore-OnFailure {
    if (Test-Path -LiteralPath $RestoreScript) {
        & $RestoreScript -RasEntry $RasEntry -Reason "enter failure rollback" 2>&1 | Tee-Object -FilePath $LogPath -Append
    }
}

Write-Log ("LogPath={0}" -f $LogPath)
Write-Log "Purpose=enter PPPoE plus Clash plus Codex-compatible NRPT/split-route environment."
Write-Log "No credentials are stored by this script."

try {
    $watchdog = Start-RestoreWatchdog
    Write-Log ("WatchdogPid={0}" -f $watchdog.Id)
    Write-Log ("WatchdogLogPath={0}" -f $WatchdogLogPath)

    PreRestore
    $cred = Get-CredentialForRas
    Connect-Ras -Cred $cred
    Add-EnterNrptRules
    Add-EnterSplitRoutes
    Start-Sleep -Seconds 3
    Test-EnterConnectivity
    Save-State
    New-Item -Path $DonePath -ItemType File -Force | Out-Null
    $Entered = $true
    Write-Log ("ENTER_PPPOE_CODEX_OK. Restore with: {0} -RasEntry {1}" -f $RestoreScript, $RasEntry)
}
catch {
    Write-Log ("ENTER_PPPOE_CODEX_FAILED: {0}" -f $_.Exception.Message)
    Restore-OnFailure
    New-Item -Path $DonePath -ItemType File -Force | Out-Null
    throw
}
finally {
    if (-not $Entered -and -not (Test-Path -LiteralPath $DonePath)) {
        New-Item -Path $DonePath -ItemType File -Force | Out-Null
    }
}
