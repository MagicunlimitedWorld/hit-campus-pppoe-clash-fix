param(
    [string]$RasEntry,
    [string]$Username,
    [pscredential]$Credential,
    [string]$SettingsPath,
    [int]$ConnectAttempts = 2,
    [int]$ConnectRetryDelaySeconds = 10
)

$ErrorActionPreference = "Stop"

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$ConfigScript = Join-Path $ScriptDir "HitNetClashConfig.ps1"
if (-not (Test-Path -LiteralPath $ConfigScript)) {
    throw "Config helper not found: $ConfigScript"
}
. $ConfigScript

$Config = Resolve-HitNetClashConfig -ScriptDir $ScriptDir -SettingsPath $SettingsPath -RasEntry $RasEntry
$RasEntry = $Config.RasEntry

$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$RuntimeDir = Join-Path $ScriptDir ".runtime"
$RuntimeLogDir = Join-Path $RuntimeDir "logs"
$RuntimeMarkerDir = Join-Path $RuntimeDir "markers"
foreach ($dir in @($RuntimeLogDir, $RuntimeMarkerDir)) {
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }
}

$LogPath = Join-Path $RuntimeLogDir ("connect_pppoe_only_{0}.log" -f $Timestamp)
$DonePath = Join-Path $RuntimeMarkerDir ("connect_pppoe_only_{0}.done" -f $Timestamp)

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
        if ($null -ne $value -and $value.Length -gt 0) {
            return $value
        }
        Write-Host "Password cannot be empty."
    }
}

function Get-RasCredential {
    if ($Credential) {
        return $Credential
    }

    $account = Read-NonEmptyValue -Prompt "HIT 校园网账号" -DefaultValue $Username
    $password = Read-NonEmptySecureString -Prompt "HIT 校园网密码"
    return [pscredential]::new($account, $password)
}

function Test-RasConnected {
    param([string]$EntryName)

    $status = (& rasdial.exe 2>&1 | Out-String)
    return ($status -match [regex]::Escape($EntryName))
}

function Get-ExistingClashRouteSummary {
    $routes = Get-NetRoute -DestinationPrefix "0.0.0.0/1", "128.0.0.0/1", "::/1", "8000::/1" -ErrorAction SilentlyContinue |
        Where-Object {
            $_.InterfaceAlias -eq $Config.TunInterfaceAlias -or
            $_.NextHop -in @($Config.TunIpv4Gateway, $Config.TunIpv6Gateway)
        } |
        Select-Object DestinationPrefix, InterfaceAlias, NextHop, RouteMetric

    if (-not $routes) {
        return ""
    }
    return ($routes | Format-Table -AutoSize | Out-String -Width 4096).Trim()
}

function Connect-RasOnly {
    param([pscredential]$Cred)

    $plainPassword = Get-PlainPasswordFromCredential -Cred $Cred
    try {
        for ($attempt = 1; $attempt -le $ConnectAttempts; $attempt++) {
            Write-Log ("Dial PPPoE only attempt {0}/{1}: {2}" -f $attempt, $ConnectAttempts, $RasEntry)
            $output = (& rasdial.exe $RasEntry $Cred.UserName $plainPassword 2>&1 | Out-String -Width 4096).TrimEnd()
            if (-not [string]::IsNullOrWhiteSpace($output)) {
                $output | Tee-Object -FilePath $LogPath -Append
            }

            if (Test-RasConnected -EntryName $RasEntry) {
                return
            }

            if ($attempt -lt $ConnectAttempts) {
                Start-Sleep -Seconds $ConnectRetryDelaySeconds
            }
        }
        throw "PPPoE dial did not connect: $RasEntry"
    }
    finally {
        $plainPassword = $null
    }
}

Write-Log "PPPOE_ONLY_START"
Write-Log "Mode: dial PPPoE only. This script does not start Clash, stop Clash, change DNS, change MTU, add NRPT, add routes, or remove routes."
Write-Log ("RasEntry: {0}" -f $RasEntry)
Write-Log ("LogPath: {0}" -f $LogPath)

$routeSummary = Get-ExistingClashRouteSummary
if (-not [string]::IsNullOrWhiteSpace($routeSummary)) {
    Write-Log "WARNING: Existing Clash TUN split routes are present. This mode leaves them untouched, so traffic may still be handled by Clash until you disable TUN or restore routes separately."
    $routeSummary | Tee-Object -FilePath $LogPath -Append
}

Invoke-Logged -Title "rasdial before" -Script { rasdial.exe }

if (Test-RasConnected -EntryName $RasEntry) {
    Write-Log ("PPPoE is already connected: {0}" -f $RasEntry)
}
else {
    $cred = Get-RasCredential
    Connect-RasOnly -Cred $cred
}

Invoke-Logged -Title "rasdial after" -Script { rasdial.exe }
Invoke-Logged -Title "IPv4 default routes" -Script {
    Get-NetRoute -AddressFamily IPv4 -DestinationPrefix "0.0.0.0/0" |
        Select-Object DestinationPrefix, InterfaceAlias, ifIndex, NextHop, RouteMetric |
        Format-Table -AutoSize
}

if (-not (Test-RasConnected -EntryName $RasEntry)) {
    throw "PPPoE is not connected after dial: $RasEntry"
}

"PPPOE_ONLY_DONE {0}" -f (Get-Date -Format "s") | Set-Content -LiteralPath $DonePath -Encoding UTF8
Write-Log "PPPOE_ONLY_OK"
