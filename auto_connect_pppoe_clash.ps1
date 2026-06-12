param(
    [string]$SettingsPath,
    [switch]$ValidateOnly
)

$ErrorActionPreference = "Stop"

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$ConfigScript = Join-Path $ScriptDir "HitNetClashConfig.ps1"
$EnterScript = Join-Path $ScriptDir "enter_pppoe_codex.ps1"
if (-not (Test-Path -LiteralPath $ConfigScript)) {
    throw "Config helper not found: $ConfigScript"
}
if (-not (Test-Path -LiteralPath $EnterScript)) {
    throw "Enter script not found: $EnterScript"
}
. $ConfigScript

if ([string]::IsNullOrWhiteSpace($SettingsPath)) {
    $SettingsPath = Join-Path $ScriptDir ".local\settings.json"
}

$RuntimeDir = Join-Path $ScriptDir ".runtime"
$RuntimeLogDir = Join-Path $RuntimeDir "logs"
if (-not (Test-Path -LiteralPath $RuntimeLogDir)) {
    New-Item -Path $RuntimeLogDir -ItemType Directory -Force | Out-Null
}

$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$LogPath = Join-Path $RuntimeLogDir ("auto_connect_{0}.log" -f $Timestamp)

function Write-AutoLog {
    param([string]$Message = "")
    $line = "{0} {1}" -f (Get-Date -Format "s"), $Message
    $line | Tee-Object -FilePath $LogPath -Append
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
    $status = (& rasdial.exe 2>&1 | Out-String)
    return ($status -match [regex]::Escape($EntryName))
}

function Test-ClashPortListening {
    param([string]$ProxyUrl)
    try {
        $uri = [Uri]$ProxyUrl
        $hostName = if ($uri.Host -in @("0.0.0.0", "::", "[::]")) { "127.0.0.1" } else { $uri.Host }
        $client = [System.Net.Sockets.TcpClient]::new()
        try {
            $async = $client.BeginConnect($hostName, $uri.Port, $null, $null)
            if (-not $async.AsyncWaitHandle.WaitOne(800, $false)) {
                return $false
            }
            $client.EndConnect($async)
            return $true
        }
        finally {
            $client.Close()
        }
    }
    catch {
        return $false
    }
}

function Test-CodexNrptReady {
    $rules = @(Get-DnsClientNrptRule -ErrorAction SilentlyContinue |
        Where-Object { $_.Comment -like "CodexClash*" -or $_.DisplayName -like "CodexClash*" })
    $namespaces = @($rules | ForEach-Object { $_.Namespace })
    return (($namespaces -contains ".openai.com") -and ($namespaces -contains ".github.com"))
}

function Test-SplitRoutesReady {
    param(
        [string]$TunInterfaceAlias,
        [string]$TunIpv4Gateway,
        [string]$TunIpv6Gateway
    )

    $expected = @(
        [pscustomobject]@{ Prefix = "0.0.0.0/1"; NextHop = $TunIpv4Gateway },
        [pscustomobject]@{ Prefix = "128.0.0.0/1"; NextHop = $TunIpv4Gateway },
        [pscustomobject]@{ Prefix = "::/1"; NextHop = $TunIpv6Gateway },
        [pscustomobject]@{ Prefix = "8000::/1"; NextHop = $TunIpv6Gateway }
    )
    foreach ($route in $expected) {
        $found = Get-NetRoute -DestinationPrefix $route.Prefix -InterfaceAlias $TunInterfaceAlias -NextHop $route.NextHop -ErrorAction SilentlyContinue
        if (-not $found) {
            return $false
        }
    }
    return $true
}

function Test-AlreadyConnected {
    param($Config)

    $tun = Get-NetAdapter -Name $Config.TunInterfaceAlias -ErrorAction SilentlyContinue
    return (
        (Test-RasConnected -EntryName $Config.RasEntry) -and
        (Test-ClashPortListening -ProxyUrl $Config.ProxyUrl) -and
        ($tun -and $tun.Status -eq "Up") -and
        (Test-CodexNrptReady) -and
        (Test-SplitRoutesReady -TunInterfaceAlias $Config.TunInterfaceAlias -TunIpv4Gateway $Config.TunIpv4Gateway -TunIpv6Gateway $Config.TunIpv6Gateway)
    )
}

$Config = Resolve-HitNetClashConfig -ScriptDir $ScriptDir -SettingsPath $SettingsPath

Write-AutoLog ("LogPath={0}" -f $LogPath)
Write-AutoLog "Purpose=logon auto-connect for HIT PPPoE plus Clash."
Write-AutoLog ("SettingsPath={0}" -f $SettingsPath)
Write-AutoLog ("EffectiveConfig RasEntry={0} ProxyUrl={1} TunInterfaceAlias={2} ClashPath={3}" -f $Config.RasEntry, $Config.ProxyUrl, $Config.TunInterfaceAlias, $Config.ClashPath)

try {
    $credential = Get-SavedCredential
    if ($ValidateOnly) {
        Write-AutoLog "AUTO_CONNECT_VALIDATE_OK"
        return
    }

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
