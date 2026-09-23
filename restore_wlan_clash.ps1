param(
    [string]$RasEntry, [string]$ProxyUrl, [string]$TunInterfaceAlias,
    [string]$TunIpv4Gateway, [string]$TunIpv6Gateway, [string]$SettingsPath,
    [switch]$SkipProbe, [int]$ProbeAttempts = 1, [int]$ProbeRetryDelaySeconds = 3,
    [ValidateSet('Balanced','Full','Minimal')][string]$ProbeMode = 'Balanced',
    [string]$Reason = 'manual restore'
)
$ErrorActionPreference = 'Stop'
$ScriptDir = $PSScriptRoot
. (Join-Path $ScriptDir 'HitNetClashConfig.ps1')
. (Join-Path $ScriptDir 'HitNetClashRuntime.ps1')
$Config = Resolve-HitNetClashConfig -ScriptDir $ScriptDir -SettingsPath $SettingsPath -RasEntry $RasEntry -ProxyUrl $ProxyUrl -TunInterfaceAlias $TunInterfaceAlias -TunIpv4Gateway $TunIpv4Gateway -TunIpv6Gateway $TunIpv6Gateway
$RasEntry = $Config.RasEntry; $ProxyUrl = $Config.ProxyUrl
$StatePath = Join-Path $ScriptDir '.runtime\state\pppoe_codex_active_state.json'
$LegacyStatePath = Join-Path $ScriptDir 'pppoe_codex_active_state.json'
$LogPath = Join-Path $ScriptDir ('.runtime\logs\restore_wlan_clash_{0}.log' -f (Get-Date -Format yyyyMMdd_HHmmss_fff))
function Write-Log { param([string]$Message) Write-HitNetLog -LogPath $LogPath -Message $Message }

function Invoke-RestoreLocalCleanup {
    param($ActiveState)
    $routes = @($ActiveState.Routes | Where-Object { $null -ne $_ })
    $nrpt = @($ActiveState.NrptRules | Where-Object { $null -ne $_ })
    if ($ActiveState -and -not $nrpt.Count) {
        # Legacy NRPT ownership requires both the recorded name and a project-specific marker.
        $nrpt = @(Get-DnsClientNrptRule -ErrorAction Stop | Where-Object {
            $_.Name -in @($ActiveState.NrptRuleNames) -and (Test-HitNetProjectNrptRule -Rule $_)
        } | ForEach-Object { Get-HitNetNrptRecord -Rule $_ })
    }
    $retained = @($routes | Where-Object { $_.Ownership -ne 'Created' -or $_.PolicyStore -ne 'ActiveStore' }).Count
    if ($retained) { Write-Log "ROUTES_RETAINED: $retained reused/legacy route records were preserved, including any persistent entries." }
    $failures = New-Object System.Collections.Generic.List[string]
    try { Remove-HitNetOwnedResources -Routes $routes -NrptRules $nrpt }
    catch { $failures.Add($_.Exception.Message) }
    try {
        if (Test-HitNetRasConnected -EntryName $RasEntry) {
            $null = & rasdial.exe $RasEntry /disconnect 2>&1
            if ($LASTEXITCODE -ne 0) { throw "RAS disconnect failed: $LASTEXITCODE" }
        }
    }
    catch { $failures.Add($_.Exception.Message) }
    $clean = $false
    for ($attempt=0; $attempt -lt 6; $attempt++) {
        try {
            $clean = (-not (Test-HitNetRasConnected -EntryName $RasEntry)) -and
                (Test-HitNetOwnedResourcesRemoved -Routes $routes -NrptRules $nrpt)
        }
        catch { $failures.Add($_.Exception.Message); break }
        if ($clean) { break }
        if ($attempt -lt 5) { Start-Sleep -Seconds 1 }
    }
    if (-not $clean -or $failures.Count) {
        throw ('RESTORE_LOCAL_CLEANUP_FAILED: active intent remains paused for retry. ' + ($failures -join '; '))
    }
    Write-Log 'RESTORE_LOCAL_CLEANUP_OK: PPPoE disconnected and owned resources removed; reused/unknown resources preserved.'
}

function Write-RestoreExternalProbe {
    if ($SkipProbe -or $ProbeMode -eq 'Minimal') { return }
    $attempts = if ($ProbeMode -eq 'Full') { [Math]::Max(3,$ProbeAttempts) } else { [Math]::Max(1,$ProbeAttempts) }
    try {
        for ($attempt=1; $attempt -le $attempts; $attempt++) {
            $code = [string](& curl.exe --head --silent --connect-timeout 3 --max-time 8 --proxy $ProxyUrl --output NUL --write-out '%{http_code}' 'https://api.openai.com/v1/models')
            Write-Log "RESTORE_HTTP_PROBE: attempt=$attempt code=$code"
            if ($code -match '^[1-5][0-9]{2}$' -and $code -ne '407') { return }
            if ($attempt -lt $attempts) { Start-Sleep -Seconds ([Math]::Max(1,$ProbeRetryDelaySeconds)) }
        }
        Write-Log 'EXTERNAL_CONNECTIVITY_PROBE_WARNING: local cleanup succeeded, but external reachability is unconfirmed.'
    }
    catch { Write-Log 'EXTERNAL_CONNECTIVITY_PROBE_WARNING: probe failed after successful local cleanup.' }
}

$restoreLock = New-HitNetNamedMutexState -Name 'Local\HitCampusPppoeClashEnter'
try {
    if (-not (Acquire-HitNetNamedMutex -State $restoreLock -WaitSeconds 3)) { throw 'RESTORE_BUSY: a connection operation is active.' }
    $active = Get-HitNetJsonObject -Path $StatePath
    if (-not $active) { $active = Get-HitNetJsonObject -Path $LegacyStatePath }
    if ($active -and ($active.RasEntry -ne $RasEntry -or $active.TunInterfaceAlias -ne $Config.TunInterfaceAlias)) {
        throw 'RESTORE_STATE_MISMATCH: the saved PPPoE/TUN binding differs from the requested connection.'
    }
    Write-Log "RESTORE_START: reason=$Reason"
    if ($active) {
        $active | Add-Member -NotePropertyName PausedByUser -NotePropertyValue $true -Force
        Write-HitNetJsonAtomic -Path $StatePath -InputObject $active
    }
    Invoke-RestoreLocalCleanup -ActiveState $active
    foreach ($path in @($StatePath,$LegacyStatePath)) {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -ErrorAction Stop }
    }
    Write-RestoreExternalProbe
    Write-Log 'RESTORE_WLAN_CLASH_DONE: verified local restore completed.'
}
catch { Write-Log ('RESTORE_WLAN_CLASH_FAILED: ' + $_.Exception.Message); throw }
finally { Release-HitNetNamedMutex -State $restoreLock }