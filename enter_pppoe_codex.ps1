param(
    [string]$RasEntry,
    [string]$Username,
    [pscredential]$Credential,
    [string]$ProxyUrl,
    [string]$TunInterfaceAlias,
    [string]$TunIpv4Gateway,
    [string]$TunIpv6Gateway,
    [string]$ClashPath,
    [string]$SettingsPath,
    [int]$WatchdogTimeoutSeconds = 180,
    [int]$ConnectAttempts = 2,
    [int]$ConnectRetryDelaySeconds = 10,
    [int]$LockWaitSeconds = 3,
    [ValidateSet("Balanced", "Full", "Minimal")]
    [string]$ProbeMode = "Balanced",
    [switch]$SkipPreRestore,
    [switch]$ReconcileOnly
)

$ErrorActionPreference = "Stop"

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$ConfigScript = Join-Path $ScriptDir "HitNetClashConfig.ps1"
$RuntimeScript = Join-Path $ScriptDir "HitNetClashRuntime.ps1"
if (-not (Test-Path -LiteralPath $ConfigScript)) {
    throw "Config helper not found: $ConfigScript"
}
if (-not (Test-Path -LiteralPath $RuntimeScript)) {
    throw "Runtime helper not found: $RuntimeScript"
}
. $ConfigScript
. $RuntimeScript
$Config = Resolve-HitNetClashConfig -ScriptDir $ScriptDir -SettingsPath $SettingsPath -RasEntry $RasEntry -ProxyUrl $ProxyUrl -TunInterfaceAlias $TunInterfaceAlias -TunIpv4Gateway $TunIpv4Gateway -TunIpv6Gateway $TunIpv6Gateway -ClashPath $ClashPath
$RasEntry = $Config.RasEntry
$ProxyUrl = $Config.ProxyUrl
$TunInterfaceAlias = $Config.TunInterfaceAlias
$TunIpv4Gateway = $Config.TunIpv4Gateway
$TunIpv6Gateway = $Config.TunIpv6Gateway
$ClashPath = $Config.ClashPath
$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss_fff"
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

$NrptNamespaces = @($Config.NrptNamespaces)
$NrptComment = "CodexClashEnter temporary NRPT rule $Timestamp"
$CreatedNrptRuleNames = New-Object System.Collections.Generic.List[string]
$AddedRoutes = New-Object System.Collections.Generic.List[object]
$ReconcileAddedNrptRuleNames = New-Object System.Collections.Generic.List[string]
$ReconcileAddedRoutes = New-Object System.Collections.Generic.List[object]
$Entered = $false
$EnterMutexName = "Local\HitCampusPppoeClashEnter"
$EnterMutexState = New-HitNetNamedMutexState -Name $EnterMutexName

function Write-Log {
    param([string]$Message = "")
    Write-HitNetLog -LogPath $LogPath -Message $Message
}

function Invoke-Logged {
    param(
        [string]$Title,
        [scriptblock]$Script
    )
    Invoke-HitNetLogged -LogPath $LogPath -Title $Title -Script $Script
}

function Acquire-EnterLock {
    return (Acquire-HitNetNamedMutex -State $script:EnterMutexState -WaitSeconds $LockWaitSeconds -LogPath $LogPath)
}

function Release-EnterLock {
    Release-HitNetNamedMutex -State $script:EnterMutexState -LogPath $LogPath
}

function Assert-WorkspacePath {
    param([string]$Path)
    if (-not (Test-HitNetWorkspacePath -WorkspacePath $ScriptDir -Path $Path)) {
        throw "Path escapes workspace: $([System.IO.Path]::GetFullPath($Path))"
    }
}

function Get-PlainPasswordFromCredential {
    param([pscredential]$Cred)

    return (Get-HitNetPlainPasswordFromCredential -Credential $Cred)
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
    $escapedProxyUrl = $ProxyUrl.Replace("'", "''")
    $escapedTunAlias = $TunInterfaceAlias.Replace("'", "''")
    $escapedTunV4 = $TunIpv4Gateway.Replace("'", "''")
    $escapedTunV6 = $TunIpv6Gateway.Replace("'", "''")
    $timeout = [Math]::Max(30, $WatchdogTimeoutSeconds)

    $watchdogScript = @"
`$ErrorActionPreference = 'Continue'
`$done = '$escapedDone'
`$log = '$escapedLog'
`$restore = '$escapedRestore'
`$ras = '$escapedRasEntry'
`$proxy = '$escapedProxyUrl'
`$tun = '$escapedTunAlias'
`$tunV4 = '$escapedTunV4'
`$tunV6 = '$escapedTunV6'
function Add-WatchdogLog([string]`$m) { Add-Content -LiteralPath `$log -Value ((Get-Date -Format 'yyyy-MM-ddTHH:mm:ss') + ' ' + `$m) }
Add-WatchdogLog 'watchdog started; timeout=${timeout}s'
for (`$i = 0; `$i -lt $([Math]::Ceiling($timeout / 5)); `$i++) {
    if (Test-Path -LiteralPath `$done) { Add-WatchdogLog 'done marker found; exiting'; exit 0 }
    Start-Sleep -Seconds 5
}
Add-WatchdogLog 'timeout reached; running restore script'
& `$restore -RasEntry `$ras -ProxyUrl `$proxy -TunInterfaceAlias `$tun -TunIpv4Gateway `$tunV4 -TunIpv6Gateway `$tunV6 -SkipProbe -Reason 'enter watchdog timeout' 2>&1 | Add-Content -LiteralPath `$log
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

    Invoke-Logged "pre-clean stale Codex NRPT rules without disconnecting RAS" {
        Remove-HitNetProjectNrptRules
    }

    Invoke-Logged "pre-clean stale Codex split routes without disconnecting RAS" {
        Remove-HitNetSplitRoutes -TunInterfaceAlias $TunInterfaceAlias -TunIpv4Gateway $TunIpv4Gateway -TunIpv6Gateway $TunIpv6Gateway
    }

    Invoke-Logged "pre-clean active state file" {
        if (Test-Path -LiteralPath $StatePath) {
            Remove-Item -LiteralPath $StatePath -Force -ErrorAction SilentlyContinue
            "Removed $StatePath"
        }
        else {
            "State file not found: $StatePath"
        }
    }
}

function Test-ProxyPortListening {
    return (Test-HitNetProxyPortListening -ProxyUrl $ProxyUrl)
}

function Test-RasConnected {
    return (Test-HitNetRasConnected -EntryName $RasEntry)
}

function Get-KnownRasEntries {
    return (Get-HitNetRasEntries)
}

function Assert-RasEntryExists {
    $entries = Get-KnownRasEntries
    Write-Log ("Ras phonebook scan: {0}" -f (Get-HitNetRasEntriesSummary -RasEntries $entries))

    if (-not (Test-HitNetRasEntryExists -RasEntries $entries -RasEntry $RasEntry)) {
        throw ("RAS_ENTRY_NOT_FOUND: no entry named '{0}' in rasphone.pbk. Output: {1}. Recreate/fix via 'rasphone.exe -a' and keep exact name." -f $RasEntry, (Get-HitNetRasEntriesSummary -RasEntries $entries))
    }

    Write-Log ("Ras phonebook check passed: found '{0}'." -f $RasEntry)
    return $entries
}

function Test-TunInterfaceReady {
    return (Test-HitNetTunReady -TunInterfaceAlias $TunInterfaceAlias)
}

function Test-NrptRulesReady {
    return (Test-HitNetNrptRulesReady -NrptNamespaces $NrptNamespaces)
}

function Test-SplitRoutesReady {
    return (Test-HitNetSplitRoutesReady -TunInterfaceAlias $TunInterfaceAlias -TunIpv4Gateway $TunIpv4Gateway -TunIpv6Gateway $TunIpv6Gateway)
}

function Test-EnterReady {
    return (
        (Test-RasConnected) -and
        (Test-ProxyPortListening) -and
        (Test-TunInterfaceReady) -and
        (Test-NrptRulesReady) -and
        (Test-SplitRoutesReady)
    )
}

function Capture-ExistingEnterState {
    $CreatedNrptRuleNames.Clear()
    $AddedRoutes.Clear()

    foreach ($namespace in $NrptNamespaces) {
        $rule = Get-DnsClientNrptRule -ErrorAction SilentlyContinue |
            Where-Object {
                ($_.Namespace -contains $namespace -or $_.Namespace -eq $namespace) -and
                ($_.NameServers -contains "198.18.0.2" -or $_.NameServers -eq "198.18.0.2")
            } |
            Select-Object -First 1
        if ($rule -and $rule.Name) {
            $CreatedNrptRuleNames.Add($rule.Name) | Out-Null
        }
    }

    foreach ($route in @(
        @{ Prefix = "0.0.0.0/1"; NextHop = $TunIpv4Gateway; Family = "IPv4" },
        @{ Prefix = "128.0.0.0/1"; NextHop = $TunIpv4Gateway; Family = "IPv4" },
        @{ Prefix = "::/1"; NextHop = $TunIpv6Gateway; Family = "IPv6" },
        @{ Prefix = "8000::/1"; NextHop = $TunIpv6Gateway; Family = "IPv6" }
    )) {
        $found = Get-NetRoute -DestinationPrefix $route.Prefix -InterfaceAlias $TunInterfaceAlias -NextHop $route.NextHop -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($found) {
            $AddedRoutes.Add([pscustomobject]@{
                DestinationPrefix = $route.Prefix
                InterfaceIndex = $found.InterfaceIndex
                NextHop = $route.NextHop
                AddressFamily = $route.Family
            }) | Out-Null
        }
    }
}

function Assert-EthernetLinkReady {
    Invoke-Logged "Ethernet link precheck" {
        $adapters = Get-NetAdapter -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Status -eq "Up" -and
                $_.Name -ne $TunInterfaceAlias -and
                $_.Name -notmatch "WLAN|Wi-?Fi|Wireless|Meta|Clash|TUN|Loopback|Bluetooth" -and
                $_.InterfaceDescription -notmatch "Wireless|Wi-?Fi|Meta|Clash|TUN|Loopback|Bluetooth|Virtual"
            } |
            Select-Object Name, InterfaceDescription, Status, LinkSpeed, ifIndex

        if ($adapters) {
            $adapters | Format-Table -AutoSize
        }
        else {
            "No Up Ethernet-like adapter detected."
        }
    }

    $ready = Get-NetAdapter -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Status -eq "Up" -and
            $_.Name -ne $TunInterfaceAlias -and
            $_.Name -notmatch "WLAN|Wi-?Fi|Wireless|Meta|Clash|TUN|Loopback|Bluetooth" -and
            $_.InterfaceDescription -notmatch "Wireless|Wi-?Fi|Meta|Clash|TUN|Loopback|Bluetooth|Virtual"
        } |
        Select-Object -First 1

    if (-not $ready) {
        throw "Ethernet link is not ready. Plug in the cable/fiber uplink and confirm the Ethernet adapter is Up before dialing PPPoE."
    }
}

function Ensure-ClashStarted {
    $existing = Get-Process -Name $Config.ClashProcessName -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($existing) {
        Write-Log ("Clash UI process already running: {0} PID={1}" -f $Config.ClashProcessName, $existing.Id)
        return
    }

    if ([string]::IsNullOrWhiteSpace($ClashPath) -or -not (Test-Path -LiteralPath $ClashPath)) {
        throw "Clash executable not found. Configure ClashPath in the UI or .local/settings.json. Current value: $ClashPath"
    }

    Write-Log ("Starting Clash UI: {0}" -f $ClashPath)
    Start-Process -FilePath $ClashPath -WindowStyle Hidden | Out-Null
}

function Wait-ClashLocalReady {
    param([int]$TimeoutSeconds = 45)

    Ensure-ClashStarted
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-ProxyPortListening) {
            Write-Log ("Clash proxy is listening at {0}." -f $ProxyUrl)
            return
        }
        Start-Sleep -Seconds 2
    }

    throw "Clash proxy did not listen at $ProxyUrl within ${TimeoutSeconds}s. Confirm Clash Verge is running and mixed/http proxy is enabled."
}

function Wait-TunInterfaceReady {
    param([int]$TimeoutSeconds = 45)

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $adapter = Get-NetAdapter -Name $TunInterfaceAlias -ErrorAction SilentlyContinue
        if ($adapter -and $adapter.Status -eq "Up") {
            Write-Log ("TUN interface is ready: {0} ifIndex={1}" -f $adapter.Name, $adapter.ifIndex)
            return
        }
        Start-Sleep -Seconds 2
    }

    throw "TUN interface '$TunInterfaceAlias' is not Up. Enable Clash TUN/Meta in Clash Verge first; this script will not modify Clash config."
}

function Initialize-ColdStartPrerequisites {
    Write-Log "=== cold-start local prerequisites ==="
    Write-Log ("EffectiveConfig RasEntry={0} ProxyUrl={1} TunInterfaceAlias={2} ClashPath={3}" -f $RasEntry, $ProxyUrl, $TunInterfaceAlias, $ClashPath)
    Assert-EthernetLinkReady
    Wait-ClashLocalReady
    Wait-TunInterfaceReady
}

function Connect-Ras {
    param(
        [pscredential]$Cred,
        [string[]]$KnownRasEntries = @()
    )

    if (Test-RasConnected) {
        Write-Log ("RAS entry {0} is already connected; skip dialing." -f $RasEntry)
        return
    }

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

        for ($i = 0; $i -lt 12; $i++) {
            if (Test-RasConnected) {
                Write-Log ("RAS entry {0} connected on attempt {1} after {2}s." -f $RasEntry, $attempt, $i)
                return
            }
            Start-Sleep -Seconds 1
        }

        Write-Log (Get-RasFailureHint -RasOutput $lastOutput -RasEntries $KnownRasEntries -RasEntry $RasEntry)
        if ($attempt -lt $attempts) {
            Write-Log ("RAS entry {0} not connected; retrying after {1}s." -f $RasEntry, $ConnectRetryDelaySeconds)
            Start-Sleep -Seconds ([Math]::Max(1, $ConnectRetryDelaySeconds))
        }
    }

    throw ("RAS entry {0} did not connect after {1} attempt(s). Last hint: {2}" -f $RasEntry, $attempts, (Get-RasFailureHint -RasOutput $lastOutput -RasEntries $KnownRasEntries -RasEntry $RasEntry))
}

function Get-RasFailureHint {
    param([string]$RasOutput)

    return (Get-HitNetRasFailureHint -RasOutput $RasOutput)
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

    $routeState = [pscustomobject]@{
        DestinationPrefix = $DestinationPrefix
        InterfaceIndex = $InterfaceIndex
        NextHop = $NextHop
        AddressFamily = $AddressFamily
    }
    $existing = Get-NetRoute -DestinationPrefix $DestinationPrefix -InterfaceIndex $InterfaceIndex -NextHop $NextHop -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Log "Split route already exists and will be reused: $DestinationPrefix via $NextHop on ifIndex $InterfaceIndex."
        $AddedRoutes.Add($routeState) | Out-Null
        return
    }

    New-NetRoute -DestinationPrefix $DestinationPrefix -InterfaceIndex $InterfaceIndex -NextHop $NextHop -RouteMetric 0 -ErrorAction Stop | Out-Null
    $AddedRoutes.Add($routeState) | Out-Null
}

function Add-EnterSplitRoutes {
    Invoke-Logged "routes before enter split routes" {
        Get-HitNetRoutesByPrefix -DestinationPrefix @("0.0.0.0/0", "0.0.0.0/1", "128.0.0.0/1", "::/0", "::/1", "8000::/1") |
            Sort-Object AddressFamily, DestinationPrefix, RouteMetric, InterfaceMetric |
            Select-Object DestinationPrefix, NextHop, InterfaceAlias, InterfaceIndex, RouteMetric, InterfaceMetric, AddressFamily |
            Format-Table -AutoSize
    }

    $tunAdapter = Get-NetAdapter -Name $TunInterfaceAlias -ErrorAction Stop | Select-Object -First 1
    $metaV4 = Get-NetRoute -DestinationPrefix "0.0.0.0/0" -InterfaceAlias $TunInterfaceAlias -ErrorAction SilentlyContinue | Select-Object -First 1
    $metaV6 = Get-NetRoute -DestinationPrefix "::/0" -InterfaceAlias $TunInterfaceAlias -ErrorAction SilentlyContinue | Select-Object -First 1
    $v4NextHop = if ($metaV4 -and -not [string]::IsNullOrWhiteSpace($metaV4.NextHop)) { $metaV4.NextHop } else { $TunIpv4Gateway }
    $v6NextHop = if ($metaV6 -and -not [string]::IsNullOrWhiteSpace($metaV6.NextHop)) { $metaV6.NextHop } else { $TunIpv6Gateway }

    Add-SplitRoute -DestinationPrefix "0.0.0.0/1" -InterfaceIndex $tunAdapter.ifIndex -NextHop $v4NextHop -AddressFamily "IPv4"
    Add-SplitRoute -DestinationPrefix "128.0.0.0/1" -InterfaceIndex $tunAdapter.ifIndex -NextHop $v4NextHop -AddressFamily "IPv4"
    Add-SplitRoute -DestinationPrefix "::/1" -InterfaceIndex $tunAdapter.ifIndex -NextHop $v6NextHop -AddressFamily "IPv6"
    Add-SplitRoute -DestinationPrefix "8000::/1" -InterfaceIndex $tunAdapter.ifIndex -NextHop $v6NextHop -AddressFamily "IPv6"

    Invoke-Logged "routes after enter split routes" {
        Get-HitNetRoutesByPrefix -DestinationPrefix @("0.0.0.0/0", "0.0.0.0/1", "128.0.0.0/1", "::/0", "::/1", "8000::/1") |
            Sort-Object AddressFamily, DestinationPrefix, RouteMetric, InterfaceMetric |
            Select-Object DestinationPrefix, NextHop, InterfaceAlias, InterfaceIndex, RouteMetric, InterfaceMetric, AddressFamily |
            Format-Table -AutoSize
    }
}

function Save-State {
    param(
        [AllowNull()][string[]]$NrptRuleNamesOverride = $null,
        [AllowNull()][object[]]$RoutesOverride = $null,
        [string]$NrptCommentOverride = "",
        [string]$TunIpv4GatewayOverride = "",
        [string]$TunIpv6GatewayOverride = ""
    )

    Assert-WorkspacePath -Path $StatePath
    $nrptNames = if ($null -ne $NrptRuleNamesOverride) {
        @($NrptRuleNamesOverride)
    }
    else {
        @($CreatedNrptRuleNames | ForEach-Object { $_ })
    }
    $routes = if ($null -ne $RoutesOverride) {
        @($RoutesOverride)
    }
    else {
        @($AddedRoutes | ForEach-Object { $_ })
    }
    $state = [pscustomobject]@{
        Timestamp = $Timestamp
        RasEntry = $RasEntry
        LogPath = $LogPath
        RestoreScript = $RestoreScript
        NrptComment = if ([string]::IsNullOrWhiteSpace($NrptCommentOverride)) { $NrptComment } else { $NrptCommentOverride }
        NrptRuleNames = $nrptNames
        Routes = $routes
        TunInterfaceAlias = $TunInterfaceAlias
        TunIpv4Gateway = if ([string]::IsNullOrWhiteSpace($TunIpv4GatewayOverride)) { $TunIpv4Gateway } else { $TunIpv4GatewayOverride }
        TunIpv6Gateway = if ([string]::IsNullOrWhiteSpace($TunIpv6GatewayOverride)) { $TunIpv6Gateway } else { $TunIpv6GatewayOverride }
        ProxyUrl = $ProxyUrl
    }
    Write-HitNetJsonAtomic -Path $StatePath -InputObject $state -Depth 6
}

function Get-ReconcileActiveState {
    if (-not (Test-Path -LiteralPath $StatePath)) {
        return $null
    }

    try {
        return (Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json)
    }
    catch {
        throw "RECONCILE_BLOCKED: active-state file is invalid JSON: $($_.Exception.Message)"
    }
}

function Get-CurrentTunGateway {
    param(
        [Parameter(Mandatory = $true)][string]$DestinationPrefix,
        [Parameter(Mandatory = $true)][string]$FallbackGateway
    )

    $defaultRoute = Get-NetRoute -DestinationPrefix $DestinationPrefix -InterfaceAlias $TunInterfaceAlias -ErrorAction SilentlyContinue |
        Sort-Object RouteMetric, InterfaceMetric |
        Select-Object -First 1
    $nextHop = if ($defaultRoute) { [string]$defaultRoute.NextHop } else { "" }
    if ([string]::IsNullOrWhiteSpace($nextHop) -or $nextHop -in @("0.0.0.0", "::")) {
        return $FallbackGateway
    }
    return $nextHop
}

function Add-ReconcileNrptRule {
    param([Parameter(Mandatory = $true)][string]$Namespace)

    $displayName = ("CodexClashEnter-{0}-{1}" -f $Timestamp, ($Namespace -replace "[^A-Za-z0-9]", "_"))
    $rule = Add-DnsClientNrptRule -Namespace $Namespace -NameServers "198.18.0.2" -DisplayName $displayName -Comment $NrptComment -PassThru -ErrorAction Stop
    $ruleName = [string]$rule.Name
    if ([string]::IsNullOrWhiteSpace($ruleName)) {
        $ruleName = [string](Get-DnsClientNrptRule -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -eq $displayName } |
            Select-Object -First 1 -ExpandProperty Name)
    }
    if ([string]::IsNullOrWhiteSpace($ruleName)) {
        throw "New project NRPT rule could not be identified for rollback: $Namespace"
    }
    $ReconcileAddedNrptRuleNames.Add($ruleName) | Out-Null
    Write-Log "Reconcile added project NRPT rule for $Namespace."
    return $ruleName
}

function Add-ReconcileSplitRoute {
    param([Parameter(Mandatory = $true)]$Route)

    $existing = Get-NetRoute -DestinationPrefix $Route.DestinationPrefix -InterfaceIndex ([int]$Route.InterfaceIndex) -NextHop ([string]$Route.NextHop) -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($existing) {
        Write-Log ("Reconcile found route already present after planning: {0} via {1} on ifIndex {2}." -f $Route.DestinationPrefix, $Route.NextHop, $Route.InterfaceIndex)
        return
    }

    New-NetRoute -DestinationPrefix $Route.DestinationPrefix -InterfaceIndex ([int]$Route.InterfaceIndex) -NextHop ([string]$Route.NextHop) -RouteMetric 0 -ErrorAction Stop | Out-Null
    $ReconcileAddedRoutes.Add([pscustomobject]@{
        DestinationPrefix = [string]$Route.DestinationPrefix
        InterfaceIndex = [int]$Route.InterfaceIndex
        NextHop = [string]$Route.NextHop
        AddressFamily = [string]$Route.AddressFamily
    }) | Out-Null
    Write-Log ("Reconcile added split route: {0} via {1} on ifIndex {2}." -f $Route.DestinationPrefix, $Route.NextHop, $Route.InterfaceIndex)
}

function Remove-ReconcileRecordedStaleRoute {
    param([Parameter(Mandatory = $true)]$Route)

    $matches = @(Get-NetRoute -DestinationPrefix $Route.DestinationPrefix -InterfaceIndex ([int]$Route.InterfaceIndex) -NextHop ([string]$Route.NextHop) -ErrorAction SilentlyContinue)
    foreach ($match in $matches) {
        $match | Remove-NetRoute -Confirm:$false -ErrorAction Stop
        Write-Log ("Reconcile removed state-recorded stale route: {0} via {1} on ifIndex {2}." -f $Route.DestinationPrefix, $Route.NextHop, $Route.InterfaceIndex)
    }
}

function Undo-ReconcileAdditions {
    foreach ($route in @($ReconcileAddedRoutes | ForEach-Object { $_ })) {
        try {
            Get-NetRoute -DestinationPrefix $route.DestinationPrefix -InterfaceIndex ([int]$route.InterfaceIndex) -NextHop ([string]$route.NextHop) -ErrorAction SilentlyContinue |
                Remove-NetRoute -Confirm:$false -ErrorAction Stop
            Write-Log ("Reconcile rollback removed newly added route: {0}." -f $route.DestinationPrefix)
        }
        catch {
            Write-Log ("Reconcile rollback warning for route {0}: {1}" -f $route.DestinationPrefix, $_.Exception.Message)
        }
    }
    foreach ($ruleName in @($ReconcileAddedNrptRuleNames | ForEach-Object { $_ })) {
        try {
            Remove-DnsClientNrptRule -Name $ruleName -Force -ErrorAction Stop
            Write-Log "Reconcile rollback removed newly added NRPT rule."
        }
        catch {
            Write-Log ("Reconcile rollback warning for NRPT rule: {0}" -f $_.Exception.Message)
        }
    }
}

function Test-ReconcileRoutesReady {
    param([Parameter(Mandatory = $true)][object[]]$ExpectedRoutes)

    foreach ($route in @($ExpectedRoutes)) {
        $found = Get-NetRoute -DestinationPrefix $route.DestinationPrefix -InterfaceIndex ([int]$route.InterfaceIndex) -NextHop ([string]$route.NextHop) -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if (-not $found) {
            return $false
        }
    }
    return $true
}

function Invoke-ReconcileOnly {
    $activeState = Get-ReconcileActiveState
    if ($null -eq $activeState) {
        Write-Log "RECONCILE_SKIPPED_INACTIVE: project active-state file is absent; no network changes were made."
        return
    }
    if (-not (Test-RasConnected)) {
        Write-Log "RECONCILE_SKIPPED_RAS_DISCONNECTED: configured PPPoE session is not connected; no dialing was attempted."
        return
    }
    if (-not (Test-ProxyPortListening)) {
        throw "RECONCILE_BLOCKED: configured proxy port is not listening; no process restart was attempted."
    }

    $tunAdapter = Get-NetAdapter -Name $TunInterfaceAlias -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $tunAdapter -or $tunAdapter.Status -ne "Up") {
        throw "RECONCILE_BLOCKED: configured Meta/TUN adapter is not Up; no Clash restart was attempted."
    }

    $currentV4Gateway = Get-CurrentTunGateway -DestinationPrefix "0.0.0.0/0" -FallbackGateway $TunIpv4Gateway
    $currentV6Gateway = Get-CurrentTunGateway -DestinationPrefix "::/0" -FallbackGateway $TunIpv6Gateway
    $prefixes = @("0.0.0.0/1", "128.0.0.0/1", "::/1", "8000::/1")
    $nrptRules = @(Get-DnsClientNrptRule -ErrorAction SilentlyContinue)
    $routes = @(Get-HitNetRoutesByPrefix -DestinationPrefix $prefixes)
    $plan = New-HitNetReconcilePlan `
        -ActiveState $activeState `
        -RasConnected $true `
        -ProxyListening $true `
        -TunReady $true `
        -RasEntry $RasEntry `
        -TunInterfaceAlias $TunInterfaceAlias `
        -TunInterfaceIndex ([int]$tunAdapter.ifIndex) `
        -TunIpv4Gateway $currentV4Gateway `
        -TunIpv6Gateway $currentV6Gateway `
        -NrptNamespaces $NrptNamespaces `
        -NrptRules $nrptRules `
        -Routes $routes

    if ($plan.Code -eq "ALREADY_OK") {
        Write-Log "RECONCILE_ALREADY_OK: project NRPT, split routes, and active state already match the current Meta/TUN binding."
        return
    }
    if ($plan.Code -like "SKIPPED_*") {
        Write-Log ("RECONCILE_{0}: {1}" -f $plan.Code, $plan.Reason)
        return
    }
    if ($plan.Code -like "BLOCKED_*") {
        throw ("RECONCILE_BLOCKED: {0} ({1})" -f $plan.Reason, $plan.Code)
    }
    if ($plan.Code -ne "REPAIR_NEEDED") {
        throw ("Unexpected reconcile plan code: {0}" -f $plan.Code)
    }

    $finalNrptRuleNames = New-Object System.Collections.Generic.List[string]
    foreach ($ruleName in @($plan.NrptRuleNames)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$ruleName) -and $finalNrptRuleNames -notcontains [string]$ruleName) {
            $finalNrptRuleNames.Add([string]$ruleName) | Out-Null
        }
    }
    foreach ($namespace in @($plan.NrptNamespacesToAdd)) {
        $newRuleName = Add-ReconcileNrptRule -Namespace $namespace
        if ($finalNrptRuleNames -notcontains $newRuleName) {
            $finalNrptRuleNames.Add($newRuleName) | Out-Null
        }
    }
    foreach ($route in @($plan.RoutesToAdd)) {
        Add-ReconcileSplitRoute -Route $route
    }
    foreach ($route in @($plan.RoutesToRemove)) {
        Remove-ReconcileRecordedStaleRoute -Route $route
    }

    if (-not (Test-NrptRulesReady) -or -not (Test-ReconcileRoutesReady -ExpectedRoutes @($plan.ExpectedRoutes))) {
        throw "Reconcile verification failed after project-owned changes."
    }

    $finalRuleNameArray = @($finalNrptRuleNames | ForEach-Object { $_ })
    Save-State -NrptRuleNamesOverride $finalRuleNameArray -RoutesOverride @($plan.ExpectedRoutes) -NrptCommentOverride $NrptComment -TunIpv4GatewayOverride $currentV4Gateway -TunIpv6GatewayOverride $currentV6Gateway
    Write-Log ("RECONCILE_REPAIRED: nrpt_added={0} routes_added={1} stale_recorded_routes_removed={2}; no dialing or process restart was attempted." -f $plan.NrptNamespacesToAdd.Count, $plan.RoutesToAdd.Count, $plan.RoutesToRemove.Count)
}

function Start-OpenAiHeadProbe {
    param(
        [string]$Label,
        [switch]$UseProxy
    )

    return (Start-HitNetOpenAiHeadProbe -Label $Label -ProxyUrl $ProxyUrl -UseProxy:$UseProxy)
}

function Complete-OpenAiHeadProbe {
    param([pscustomobject]$Probe)

    return (Complete-HitNetOpenAiHeadProbe -Probe $Probe)
}

function Write-OpenAiProbeResult {
    param([pscustomobject]$Result)

    Write-HitNetOpenAiProbeResult -LogPath $LogPath -Result $Result
}

function Test-EnterConnectivity {
    param([switch]$AssumeLocalReady)

    if ($AssumeLocalReady) {
        Write-Log "Local state already validated by fast path."
    }
    else {
        Invoke-Logged "local state after enter changes" {
            "ras_connected={0}" -f (Test-RasConnected)
            "proxy_listening={0}" -f (Test-ProxyPortListening)
            "tun_ready={0}" -f (Test-TunInterfaceReady)
            "nrpt_ready={0}" -f (Test-NrptRulesReady)
            "split_routes_ready={0}" -f (Test-SplitRoutesReady)
        }

        if (-not (Test-EnterReady)) {
            throw "Local enter repair failed: ras=$(Test-RasConnected) proxy=$(Test-ProxyPortListening) tun=$(Test-TunInterfaceReady) nrpt=$(Test-NrptRulesReady) routes=$(Test-SplitRoutesReady)"
        }
    }

    Write-Log "LOCAL_ENTER_REPAIR_OK: PPPoE, Clash proxy, TUN, NRPT, and split routes are ready."

    if ($ProbeMode -eq "Minimal") {
        Write-Log "ProbeMode=Minimal; skip OpenAI HTTP probes."
        return
    }

    if ($ProbeMode -eq "Full") {
        Invoke-Logged "RAS status after enter changes" {
            & rasdial.exe
        }
        Invoke-Logged "Clash listen after enter changes" {
            $proc = Get-Process -Name $Config.ClashCoreProcessName -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($proc) {
                $proc | Select-Object Id, ProcessName, Path | Format-List
                Get-NetTCPConnection -OwningProcess $proc.Id -State Listen -ErrorAction SilentlyContinue |
                    Select-Object LocalAddress, LocalPort, State |
                    Sort-Object LocalPort |
                    Format-Table -AutoSize
            }
            else {
                "$($Config.ClashCoreProcessName) not found"
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
    }

    if ($ProbeMode -eq "Balanced") {
        $directProbe = Start-OpenAiHeadProbe -Label "direct"
        $proxyProbe = Start-OpenAiHeadProbe -Label "via Clash" -UseProxy
        $directResult = Complete-OpenAiHeadProbe -Probe $directProbe
        $proxyResult = Complete-OpenAiHeadProbe -Probe $proxyProbe

        Write-OpenAiProbeResult -Result $directResult
        Write-OpenAiProbeResult -Result $proxyResult

        if ($directResult.Code -ne 401 -or $proxyResult.Code -ne 401) {
            Write-Log ("EXTERNAL_CONNECTIVITY_PROBE_WARNING: local enter repair is OK, but OpenAI probe was not 401: direct={0} proxy={1}; keeping PPPoE + Clash state and avoiding rollback on transient upstream failure." -f $directResult.Code, $proxyResult.Code)
        }
        else {
            Write-Log "EXTERNAL_CONNECTIVITY_PROBE_OK: OpenAI direct and via-Clash probes returned 401."
        }
        return
    }

    Write-Log "=== OpenAI direct after enter changes ==="
    $directResult = & curl.exe -I -L --connect-timeout 3 --max-time 8 --noproxy "*" -o NUL -s -w "code=%{http_code} dns=%{time_namelookup}s connect=%{time_connect}s tls=%{time_appconnect}s total=%{time_total}s err=%{errormsg}`n" "https://api.openai.com/v1/models"
    if ([string]::IsNullOrWhiteSpace($directResult)) {
        "(no output)" | Tee-Object -FilePath $LogPath -Append
    }
    else {
        $directResult.TrimEnd() | Tee-Object -FilePath $LogPath -Append
    }

    Write-Log "=== OpenAI via Clash after enter changes ==="
    $proxyResult = & curl.exe -I -L --connect-timeout 3 --max-time 8 --proxy $ProxyUrl -o NUL -s -w "code=%{http_code} dns=%{time_namelookup}s connect=%{time_connect}s tls=%{time_appconnect}s total=%{time_total}s err=%{errormsg}`n" "https://api.openai.com/v1/models"
    if ([string]::IsNullOrWhiteSpace($proxyResult)) {
        "(no output)" | Tee-Object -FilePath $LogPath -Append
    }
    else {
        $proxyResult.TrimEnd() | Tee-Object -FilePath $LogPath -Append
    }

    $direct = if ($directResult -match "code=(\d{3})") { $Matches[1] } else { "000" }
    $proxy = if ($proxyResult -match "code=(\d{3})") { $Matches[1] } else { "000" }
    if ($direct -ne "401" -or $proxy -ne "401") {
        throw "External connectivity probe failed: OpenAI direct=$direct proxy=$proxy"
    }
    Write-Log "EXTERNAL_CONNECTIVITY_PROBE_OK: OpenAI direct and via-Clash probes returned 401."
}

function Restore-OnFailure {
    if (Test-Path -LiteralPath $RestoreScript) {
        & $RestoreScript -RasEntry $RasEntry -ProxyUrl $ProxyUrl -TunInterfaceAlias $TunInterfaceAlias -TunIpv4Gateway $TunIpv4Gateway -TunIpv6Gateway $TunIpv6Gateway -SkipProbe -Reason "enter failure rollback" 2>&1 | Tee-Object -FilePath $LogPath -Append
    }
}

Write-Log ("LogPath={0}" -f $LogPath)
if ($ReconcileOnly) {
    Write-Log "Purpose=reconcile project-owned NRPT/split routes only; never dial PPPoE or start, stop, or restart Clash/RayLink."
}
else {
    Write-Log "Purpose=enter PPPoE plus Clash plus Codex-compatible NRPT/split-route environment."
}
Write-Log "No credentials are stored by this script."
Write-Log ("LockWaitSeconds={0}" -f $LockWaitSeconds)

if (-not (Acquire-EnterLock)) {
    $message = "Another enter_pppoe_codex instance is already running; skip this run to avoid concurrent NRPT/split-route changes."
    if ($ReconcileOnly) {
        Write-Log ("RECONCILE_SKIPPED_LOCK_BUSY: {0}" -f $message)
        return
    }
    else {
        Write-Log ("ENTER_PPPOE_CODEX_BUSY: {0}" -f $message)
        throw $message
    }
}

try {
    if ($ReconcileOnly) {
        Invoke-ReconcileOnly
        return
    }

    $watchdog = Start-RestoreWatchdog
    Write-Log ("WatchdogPid={0}" -f $watchdog.Id)
    Write-Log ("WatchdogLogPath={0}" -f $WatchdogLogPath)

    if (Test-EnterReady) {
        Write-Log "FAST_PATH_ALREADY_READY: HITnet, Clash, TUN, NRPT, and split routes are already ready."
        Test-EnterConnectivity -AssumeLocalReady
        if (-not (Test-Path -LiteralPath $StatePath)) {
            Capture-ExistingEnterState
            Save-State
        }
        New-Item -Path $DonePath -ItemType File -Force | Out-Null
        $Entered = $true
        Write-Log ("ENTER_PPPOE_CODEX_OK. Restore with: {0} -RasEntry {1}" -f $RestoreScript, $RasEntry)
        return
    }

    $knownRasEntries = Assert-RasEntryExists
    PreRestore
    Initialize-ColdStartPrerequisites
    if (-not (Test-RasConnected)) {
        $cred = Get-CredentialForRas
        Connect-Ras -Cred $cred -KnownRasEntries $knownRasEntries
    }
    else {
        Write-Log ("RAS entry {0} is already connected after pre-clean; skip credential prompt and dialing." -f $RasEntry)
    }
    Add-EnterNrptRules
    Add-EnterSplitRoutes
    for ($i = 0; $i -lt 5; $i++) {
        if ((Test-NrptRulesReady) -and (Test-SplitRoutesReady)) {
            break
        }
        Start-Sleep -Seconds 1
    }
    Test-EnterConnectivity
    Save-State
    New-Item -Path $DonePath -ItemType File -Force | Out-Null
    $Entered = $true
    Write-Log ("ENTER_PPPOE_CODEX_OK. Restore with: {0} -RasEntry {1}" -f $RestoreScript, $RasEntry)
}
catch {
    $failureMessage = $_.Exception.Message
    if ($ReconcileOnly) {
        Undo-ReconcileAdditions
        if ($failureMessage -like "RECONCILE_BLOCKED:*") {
            Write-Log $failureMessage
        }
        else {
            Write-Log ("RECONCILE_FAILED: {0}" -f $failureMessage)
        }
        throw
    }
    elseif ($failureMessage -like "RAS_ENTRY_NOT_FOUND:*") {
        Write-Log ("RAS_ENTRY_NOT_FOUND: {0}" -f $failureMessage)
        Write-Log "ENTER_PPPOE_CODEX_FAILED: RasEntry precheck failed before NRPT/split-route changes; rollback skipped."
    }
    elseif ($failureMessage -like "External connectivity probe failed:*") {
        Write-Log ("EXTERNAL_CONNECTIVITY_PROBE_FAILED: {0}" -f $failureMessage)
        Write-Log "ENTER_PPPOE_CODEX_FAILED: external connectivity probe failed in strict probe mode; rollback will run."
        Restore-OnFailure
    }
    else {
        Write-Log ("LOCAL_ENTER_REPAIR_FAILED: {0}" -f $failureMessage)
        Write-Log "ENTER_PPPOE_CODEX_FAILED: local PPPoE/Clash/NRPT/split-route repair failed; rollback will run."
        Restore-OnFailure
    }
    New-Item -Path $DonePath -ItemType File -Force | Out-Null
    throw
}
finally {
    if (-not $ReconcileOnly -and -not $Entered -and -not (Test-Path -LiteralPath $DonePath)) {
        New-Item -Path $DonePath -ItemType File -Force | Out-Null
    }
    Release-EnterLock
}
