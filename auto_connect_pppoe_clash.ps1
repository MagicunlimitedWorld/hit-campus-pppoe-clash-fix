param(
    [string]$SettingsPath,
    [switch]$ValidateOnly,
    [switch]$HealthCheckOnly
)

$ErrorActionPreference = "Stop"

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$ConfigScript = Join-Path $ScriptDir "HitNetClashConfig.ps1"
$RuntimeScript = Join-Path $ScriptDir "HitNetClashRuntime.ps1"
$EnterScript = Join-Path $ScriptDir "enter_pppoe_codex.ps1"
if (-not (Test-Path -LiteralPath $ConfigScript)) {
    throw "Config helper not found: $ConfigScript"
}
if (-not (Test-Path -LiteralPath $RuntimeScript)) {
    throw "Runtime helper not found: $RuntimeScript"
}
if (-not (Test-Path -LiteralPath $EnterScript)) {
    throw "Enter script not found: $EnterScript"
}
. $ConfigScript
. $RuntimeScript

if ([string]::IsNullOrWhiteSpace($SettingsPath)) {
    $SettingsPath = Join-Path $ScriptDir ".local\settings.json"
}

$RuntimeDir = Join-Path $ScriptDir ".runtime"
$RuntimeLogDir = Join-Path $RuntimeDir "logs"
if (-not (Test-Path -LiteralPath $RuntimeLogDir)) {
    New-Item -Path $RuntimeLogDir -ItemType Directory -Force | Out-Null
}

$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss_fff"
$LogPath = Join-Path $RuntimeLogDir ("auto_connect_{0}.log" -f $Timestamp)

function Write-AutoLog {
    param([string]$Message = "")
    Write-HitNetLog -LogPath $LogPath -Message $Message
}

function Get-SavedCredential {
    if (-not (Test-Path -LiteralPath $SettingsPath)) {
        throw "Settings file not found. Open the UI once and save account/password first: $SettingsPath"
    }

    $settings = Get-Content -LiteralPath $SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not [bool]$settings.RememberAccount -or [string]::IsNullOrWhiteSpace([string]$settings.Account)) {
        throw "Saved account is not available. Enable '记住账号' in the UI first."
    }
    if (-not [bool]$settings.RememberPassword -or [string]::IsNullOrWhiteSpace([string]$settings.PasswordProtected)) {
        throw "Saved password is not available. Enable '记住密码' in the UI first."
    }

    try {
        $securePassword = ConvertTo-SecureString ([string]$settings.PasswordProtected)
    }
    catch {
        throw "Saved password cannot be decrypted by the current Windows user."
    }
    if ($securePassword.Length -le 0) {
        throw "Saved password is empty after decryption."
    }

    return [pscredential]::new(([string]$settings.Account), $securePassword)
}

function Test-RasConnected {
    param([string]$EntryName)
    return (Test-HitNetRasConnected -EntryName $EntryName)
}

function Test-ClashPortListening {
    param([string]$ProxyUrl)
    return (Test-HitNetProxyPortListening -ProxyUrl $ProxyUrl)
}

function Test-CodexNrptReady {
    return (Test-HitNetNrptRulesReady -NrptNamespaces @($Config.NrptNamespaces))
}

function Test-SplitRoutesReady {
    param(
        [string]$TunInterfaceAlias,
        [string]$TunIpv4Gateway,
        [string]$TunIpv6Gateway
    )

    return (Test-HitNetSplitRoutesReady -TunInterfaceAlias $TunInterfaceAlias -TunIpv4Gateway $TunIpv4Gateway -TunIpv6Gateway $TunIpv6Gateway)
}

function Assert-RasEntryConfig {
    $entries = Get-HitNetRasEntries
    Write-AutoLog ("Ras phonebook scan: {0}" -f (Get-HitNetRasEntriesSummary -RasEntries $entries))
    if (-not (Test-HitNetRasEntryExists -RasEntries $entries -RasEntry $Config.RasEntry)) {
        throw ("RAS_ENTRY_NOT_FOUND: no entry named '{0}' in rasphone.pbk. Available: {1}. Recreate/fix via 'rasphone.exe -a' and keep exact name." -f $Config.RasEntry, (Get-HitNetRasEntriesSummary -RasEntries $entries))
    }
}

function Test-AlreadyConnected {
    param($Config)

    return (
        (Test-RasConnected -EntryName $Config.RasEntry) -and
        (Test-ClashPortListening -ProxyUrl $Config.ProxyUrl) -and
        (Test-HitNetTunReady -TunInterfaceAlias $Config.TunInterfaceAlias) -and
        (Test-CodexNrptReady) -and
        (Test-SplitRoutesReady -TunInterfaceAlias $Config.TunInterfaceAlias -TunIpv4Gateway $Config.TunIpv4Gateway -TunIpv6Gateway $Config.TunIpv6Gateway)
    )
}

function Invoke-HealthCheckOnly {
    $reconcileLines = New-Object System.Collections.Generic.List[string]
    try {
        & $EnterScript `
            -RasEntry $Config.RasEntry `
            -ProxyUrl $Config.ProxyUrl `
            -TunInterfaceAlias $Config.TunInterfaceAlias `
            -TunIpv4Gateway $Config.TunIpv4Gateway `
            -TunIpv6Gateway $Config.TunIpv6Gateway `
            -ClashPath $Config.ClashPath `
            -SettingsPath $SettingsPath `
            -ProbeMode Minimal `
            -ReconcileOnly 2>&1 |
            ForEach-Object {
                $line = $_.ToString()
                $reconcileLines.Add($line) | Out-Null
                Write-AutoLog $line
            }
    }
    catch {
        $failure = $_.Exception.Message
        if ($failure -match "RECONCILE_BLOCKED") {
            Write-AutoLog ("HEALTH_CHECK_BLOCKED: {0}" -f $failure)
        }
        else {
            Write-AutoLog ("HEALTH_CHECK_FAILED: {0}" -f $failure)
        }
        throw
    }

    $reconcileText = $reconcileLines -join [Environment]::NewLine
    if ($reconcileText -match "RECONCILE_REPAIRED") {
        Write-AutoLog "HEALTH_CHECK_REPAIRED"
        return
    }
    if ($reconcileText -match "RECONCILE_ALREADY_OK") {
        Write-AutoLog "HEALTH_CHECK_ALREADY_OK"
        return
    }
    if ($reconcileText -match "RECONCILE_SKIPPED_([A-Z0-9_]+)") {
        Write-AutoLog ("HEALTH_CHECK_SKIPPED_{0}" -f $Matches[1])
        return
    }

    Write-AutoLog "HEALTH_CHECK_FAILED: reconcile script returned no recognized terminal status."
    throw "Health check reconcile script returned no recognized terminal status."
}

$Config = Resolve-HitNetClashConfig -ScriptDir $ScriptDir -SettingsPath $SettingsPath

Write-AutoLog ("LogPath={0}" -f $LogPath)
if ($HealthCheckOnly) {
    Write-AutoLog "Purpose=low-frequency health reconciliation; never dial PPPoE or start, stop, or restart Clash/RayLink."
}
else {
    Write-AutoLog "Purpose=logon auto-connect for HIT PPPoE plus Clash."
}
Write-AutoLog ("SettingsPath={0}" -f $SettingsPath)
Write-AutoLog ("EffectiveConfig RasEntry={0} ProxyUrl={1} TunInterfaceAlias={2} ClashPath={3}" -f $Config.RasEntry, $Config.ProxyUrl, $Config.TunInterfaceAlias, $Config.ClashPath)

if ($ValidateOnly -and $HealthCheckOnly) {
    Write-AutoLog "HEALTH_CHECK_FAILED: ValidateOnly and HealthCheckOnly cannot be combined."
    throw "ValidateOnly and HealthCheckOnly cannot be combined."
}
if ($HealthCheckOnly) {
    Invoke-HealthCheckOnly
    return
}

try {
    Assert-RasEntryConfig
    if ($ValidateOnly) {
        Write-AutoLog "AUTO_CONNECT_VALIDATE_OK"
        return
    }

    $credential = Get-SavedCredential
    if (Test-AlreadyConnected -Config $Config) {
        Write-AutoLog "AUTO_CONNECT_ALREADY_OK"
        return
    }

    Write-AutoLog "AUTO_CONNECT_START_ENTER"
    & $EnterScript `
        -RasEntry $Config.RasEntry `
        -ProxyUrl $Config.ProxyUrl `
        -TunInterfaceAlias $Config.TunInterfaceAlias `
        -TunIpv4Gateway $Config.TunIpv4Gateway `
        -TunIpv6Gateway $Config.TunIpv6Gateway `
        -ClashPath $Config.ClashPath `
        -SettingsPath $SettingsPath `
        -Credential $credential `
        -ProbeMode Balanced 2>&1 |
        ForEach-Object { Write-AutoLog $_.ToString() }

    Write-AutoLog "AUTO_CONNECT_DONE"
}
catch {
    Write-AutoLog ("AUTO_CONNECT_FAILED: {0}" -f $_.Exception.Message)
    throw
}
