function Initialize-HitNetGuardNative { Initialize-HitNetRasNative }
function Get-HitNetGuardPhonebook { param([string]$RasEntry) Get-HitNetRasPhonebook -RasEntry $RasEntry }

function Get-HitNetGuardCredential {
    param([string]$SettingsPath)
    $settings = Get-Content -LiteralPath $SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $settings.RememberAccount -or -not $settings.RememberPassword -or
        [string]::IsNullOrWhiteSpace($settings.Account) -or [string]::IsNullOrWhiteSpace($settings.PasswordProtected)) {
        throw 'GUARD_CREDENTIAL_UNAVAILABLE: save account/password in the UI first.'
    }
    try { $secure = ConvertTo-SecureString $settings.PasswordProtected -ErrorAction Stop }
    catch { throw 'GUARD_CREDENTIAL_UNAVAILABLE: current user cannot decrypt the saved password.' }
    if ($secure.Length -eq 0) { throw 'GUARD_CREDENTIAL_UNAVAILABLE: saved password is empty.' }
    return [pscredential]::new($settings.Account, $secure)
}

function Get-HitNetGuardDisconnect {
    param([string]$RasEntry)
    $events = @(Get-WinEvent -FilterHashtable @{
        LogName = 'Application'; ProviderName = 'RasClient'; Id = 20226
        StartTime = (Get-Date).AddDays(-3)
    } -MaxEvents 50 -ErrorAction SilentlyContinue)
    foreach ($event in $events) {
        $values = @($event.Properties | ForEach-Object { $_.Value })
        if ($values.Count -ge 4 -and [string]$values[2] -eq $RasEntry) {
            return [pscustomobject]@{ Code = [int]$values[3]; AtUtc = $event.TimeCreated.ToUniversalTime(); RecordId = $event.RecordId }
        }
    }
    return $null
}

function Get-HitNetGuardSnapshot {
    param($Config, [string]$ScriptDir)
    $activePath = Join-Path $ScriptDir '.runtime\state\pppoe_codex_active_state.json'
    $active = $null
    if (Test-Path -LiteralPath $activePath) {
        $active = Get-Content -LiteralPath $activePath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    $status = @(& rasdial.exe 2>&1)
    if ($LASTEXITCODE -ne 0) { throw 'GUARD_RAS_STATUS_UNAVAILABLE: no recovery was attempted.' }
    $connected = @($status | Where-Object { $_.ToString().Trim() -eq $Config.RasEntry }).Count -gt 0
    $disconnect = if (-not $connected) { Get-HitNetGuardDisconnect -RasEntry $Config.RasEntry } else { $null }
    $manual = [bool]$active.PausedByUser
    if (-not $manual -and $active -and $disconnect -and $disconnect.Code -in @(631, 830)) {
        $started = [datetime]::MinValue
        if ([datetime]::TryParseExact([string]$active.Timestamp, 'yyyyMMdd_HHmmss_fff',
                [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeLocal, [ref]$started)) {
            $manual = $disconnect.AtUtc -gt $started.ToUniversalTime()
        }
        else { $manual = $true }
    }
    $proxy = Test-HitNetProxyPortListening -ProxyUrl $Config.ProxyUrl
    $tun = Test-HitNetTunReady -TunInterfaceAlias $Config.TunInterfaceAlias
    $routesReady = $false
    if ($active -and $connected -and $proxy -and $tun) {
        $routesReady = (Test-HitNetNrptRulesReady -NrptNamespaces @($Config.NrptNamespaces)) -and
            (Test-HitNetSplitRoutesReady -TunInterfaceAlias $Config.TunInterfaceAlias -TunIpv4Gateway $Config.TunIpv4Gateway -TunIpv6Gateway $Config.TunIpv6Gateway)
    }
    $service = Get-Service -Name RayLinkService -ErrorAction SilentlyContinue
    return [pscustomobject]@{
        Active = [bool]($active -and $active.RasEntry -eq $Config.RasEntry -and $active.TunInterfaceAlias -eq $Config.TunInterfaceAlias -and $active.ProxyUrl -eq $Config.ProxyUrl)
        Epoch = [string]$active.Timestamp
        RasConnected = $connected
        EthernetReady = Test-HitNetEthernetReady -EthernetNamePatterns @($Config.EthernetNamePatterns) -TunInterfaceAlias $Config.TunInterfaceAlias
        ManualDisconnect = $manual
        Disconnect = $disconnect
        ProxyReady = $proxy
        TunReady = $tun
        RoutesReady = $routesReady
        RayLinkStatus = if ($service) { [string]$service.Status } else { 'NotInstalled' }
        RayLinkDisabled = [bool]($service -and [string]$service.StartType -eq 'Disabled')
    }
}

function Get-HitNetGuardDecision {
    param($Snapshot, $Previous, [datetime]$NowUtc = [datetime]::UtcNow)
    $NowUtc = $NowUtc.ToUniversalTime()
    if (-not $Snapshot.Active) { return 'INACTIVE' }
    if ($Snapshot.ManualDisconnect -or ($Previous -and $Previous.Epoch -eq $Snapshot.Epoch -and
            ($Previous.PausedByUser -or $Previous.Code -eq 'GUARD_MANUAL_DISCONNECT'))) { return 'MANUAL_DISCONNECT' }
    if (-not $Snapshot.RasConnected) {
        if (-not $Snapshot.EthernetReady) { return 'LINK_DOWN' }
        if (-not $Previous -or $Previous.Epoch -ne $Snapshot.Epoch -or $Previous.RasConnected -or -not $Previous.CheckedAtUtc) { return 'CONFIRM_DISCONNECT' }
        $age = ($NowUtc - ([datetime]$Previous.CheckedAtUtc).ToUniversalTime()).TotalSeconds
        # Accept adjacent 15-minute rounds with scheduler jitter, but not a missed round.
        if ($age -lt 720 -or $age -gt 1200) { return 'CONFIRM_DISCONNECT' }
        if ($Previous.NextDialUtc -and $NowUtc -lt ([datetime]$Previous.NextDialUtc).ToUniversalTime()) { return 'DIAL_BACKOFF' }
        return 'DIAL'
    }
    return 'CHECK_SERVICES_AND_ROUTES'
}

function Invoke-HitNetGuardDial {
    param($Config)
    $credential = Get-HitNetGuardCredential -SettingsPath $Config.SettingsPath
    try { $null = Invoke-HitNetRasDial -RasEntry $Config.RasEntry -Credential $credential }
    finally { if ($credential) { $credential.Password.Dispose() } }
}

function Start-HitNetGuardRayLink {
    # The caller has already confirmed Stopped; a running service is never restarted.
    $service = Get-Service -Name RayLinkService -ErrorAction Stop
    if ($service.Status -eq 'Stopped' -and $service.StartType -ne 'Disabled') {
        Start-Service -Name RayLinkService -ErrorAction Stop
        (Get-Service -Name RayLinkService).WaitForStatus('Running', [timespan]::FromSeconds(20))
    }
}

function Invoke-HitNetGuardReconcile {
    param($Config, [string]$ScriptDir)
    $output = & (Join-Path $ScriptDir 'enter_pppoe_codex.ps1') -SettingsPath $Config.SettingsPath -ReconcileOnly -ProbeMode Minimal 2>&1
    if (($output -join "`n") -notmatch 'RECONCILE_(ALREADY_OK|REPAIRED)') {
        throw 'GUARD_RECONCILE_INCOMPLETE: inspect the corresponding enter log.'
    }
}

function Test-HitNetGuardConnectivity {
    param($Config)
    $url = 'https://api.openai.com/v1/models'
    $systemCode = [string](& curl.exe --head --silent --noproxy '*' --connect-timeout 3 --max-time 8 --output NUL --write-out '%{http_code}' $url)
    $proxyCode = [string](& curl.exe --head --silent --proxy $Config.ProxyUrl --connect-timeout 3 --max-time 8 --output NUL --write-out '%{http_code}' $url)
    return [pscustomobject]@{
        AtUtc = [datetime]::UtcNow.ToString('o')
        SystemHttp = $systemCode; ProxyHttp = $proxyCode
        Reachable = [bool]($systemCode -match '^[1-5][0-9]{2}$' -and $proxyCode -match '^[1-5][0-9]{2}$' -and $proxyCode -ne '407')
    }
}

function Invoke-HitNetGuardCycle {
    param([string]$ScriptDir, [string]$SettingsPath, [switch]$ObserveOnly, [datetime]$NowUtc = [datetime]::UtcNow)
    $NowUtc = $NowUtc.ToUniversalTime()
    $config = Resolve-HitNetClashConfig -ScriptDir $ScriptDir -SettingsPath $SettingsPath
    $snapshot = Get-HitNetGuardSnapshot -Config $config -ScriptDir $ScriptDir
    $statePath = Join-Path $ScriptDir '.runtime\state\connection_guard.json'
    $previous = Get-HitNetJsonObject -Path $statePath
    $decision = Get-HitNetGuardDecision -Snapshot $snapshot -Previous $previous -NowUtc $NowUtc
    if ($ObserveOnly) { return [pscustomobject]@{ Code = "GUARD_OBSERVE_$decision"; ExitCode = 0; Snapshot = $snapshot } }
    $state = [ordered]@{
        CheckedAtUtc = $NowUtc.ToString('o'); Epoch = $snapshot.Epoch; RasConnected = $snapshot.RasConnected
        NextDialUtc = $null; DialFailures = 0; NextServiceStartUtc = $null
        PausedByUser = ($decision -eq 'MANUAL_DISCONNECT')
        Code = "GUARD_$decision"; Actions = @(); Disconnect = $snapshot.Disconnect; Probe = $null
    }
    if ($previous -and $previous.Epoch -eq $snapshot.Epoch) {
        $state.PausedByUser = $state.PausedByUser -or $previous.PausedByUser -or $previous.Code -eq 'GUARD_MANUAL_DISCONNECT'
        $state.NextDialUtc = $previous.NextDialUtc
        $state.DialFailures = [int]$previous.DialFailures
        $state.NextServiceStartUtc = $previous.NextServiceStartUtc
        $state.Probe = $previous.Probe
    }
    $exitCode = if ($decision -in @('INACTIVE', 'MANUAL_DISCONNECT')) { 0 } else { 2 }
    $lock = New-HitNetNamedMutexState -Name 'Local\HitCampusPppoeClashEnter'
    try {
        if ($decision -in @('DIAL', 'CHECK_SERVICES_AND_ROUTES')) {
            if (-not (Acquire-HitNetNamedMutex -State $lock -WaitSeconds 0)) {
                $state.Code = 'GUARD_BUSY'
            }
            else {
                # Re-read intent and connectivity under the same lock used by enter/restore.
                $snapshot = Get-HitNetGuardSnapshot -Config $config -ScriptDir $ScriptDir
                if (-not $snapshot.Active -or $snapshot.ManualDisconnect -or $snapshot.Epoch -ne $state.Epoch) {
                    $state.PausedByUser = [bool]$snapshot.ManualDisconnect
                    $state.Code = 'GUARD_INTENT_CHANGED'; $exitCode = 0
                }
                else {
                    if ($decision -eq 'DIAL' -and -not $snapshot.RasConnected -and $snapshot.EthernetReady) {
                        $state.DialFailures++
                        $state.NextDialUtc = $NowUtc.AddMinutes(15).ToString('o')
                        $state.Code = 'GUARD_DIAL_STARTED'
                        Write-HitNetJsonAtomic -Path $statePath -InputObject $state
                        Invoke-HitNetGuardDial -Config $config
                        $state.Actions += 'DIAL'
                        $snapshot = Get-HitNetGuardSnapshot -Config $config -ScriptDir $ScriptDir
                    }
                    if ($snapshot.RasConnected) {
                        $state.DialFailures = 0; $state.NextDialUtc = $null
                        if ($snapshot.RayLinkStatus -eq 'Stopped' -and -not $snapshot.RayLinkDisabled -and
                            (-not $state.NextServiceStartUtc -or $NowUtc -ge ([datetime]$state.NextServiceStartUtc).ToUniversalTime())) {
                            $state.NextServiceStartUtc = $NowUtc.AddMinutes(15).ToString('o')
                            Write-HitNetJsonAtomic -Path $statePath -InputObject $state
                            Start-HitNetGuardRayLink
                            $state.Actions += 'START_RAYLINK'
                        }
                        if ($snapshot.ProxyReady -and $snapshot.TunReady -and -not $snapshot.RoutesReady) {
                            Invoke-HitNetGuardReconcile -Config $config -ScriptDir $ScriptDir
                            $state.Actions += 'RECONCILE'
                        }
                        $snapshot = Get-HitNetGuardSnapshot -Config $config -ScriptDir $ScriptDir
                        if ($snapshot.RasConnected -and $snapshot.ProxyReady -and $snapshot.TunReady -and $snapshot.RoutesReady -and $snapshot.RayLinkStatus -in @('Running', 'NotInstalled')) {
                            $state.Code = if ($state.Actions.Count) { 'GUARD_RECOVERED' } else { 'GUARD_LOCAL_OK' }
                            $exitCode = 0
                        }
                        else { $state.Code = 'GUARD_DEGRADED_SERVICE_OR_ROUTE' }
                    }
                    else { $state.Code = 'GUARD_DEGRADED_RAS_DISCONNECTED' }
                }
            }
        }
    }
    catch {
        $state.Code = 'GUARD_RECOVERY_FAILED'
        # Keep exception detail separate from credential objects or dial parameters.
        $state.Error = $_.Exception.Message
        $exitCode = 2
    }
    finally { Release-HitNetNamedMutex -State $lock }
    # HTTP failure is diagnostic only and must never disconnect a working RAS/TUN path.
    if ($snapshot.Active -and $snapshot.RasConnected -and $snapshot.ProxyReady -and $snapshot.TunReady) {
        # One pair per eligible round, including recovery; no separate probe timer.
        $state.Probe = Test-HitNetGuardConnectivity -Config $config
        if ($exitCode -eq 0 -and -not $state.Probe.Reachable) { $state.Code = 'GUARD_HTTP_WARNING'; $exitCode = 2 }
    }
    $state.RasConnected = $snapshot.RasConnected
    $state.ProxyReady = $snapshot.ProxyReady; $state.TunReady = $snapshot.TunReady
    $state.RayLinkStatus = $snapshot.RayLinkStatus; $state.RoutesReady = $snapshot.RoutesReady
    Write-HitNetJsonAtomic -Path $statePath -InputObject $state
    return [pscustomobject]@{ Code = $state.Code; ExitCode = $exitCode; State = $state }
}

function Register-HitNetGuardTask {
    param([string]$ScriptDir, [string]$SettingsPath)
    $powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $guardScript = Join-Path $ScriptDir 'guard_pppoe_clash.ps1'
    $arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -SettingsPath "{1}"' -f $guardScript, $SettingsPath
    $action = New-ScheduledTaskAction -Execute $powershellExe -Argument $arguments -WorkingDirectory $ScriptDir
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(15) -RepetitionInterval (New-TimeSpan -Minutes 15)
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 3)
    $principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Highest
    Register-ScheduledTask -TaskName 'HitCampusPppoeClashHealthCheck' -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description 'Every 15 minutes: confirm unexpected PPPoE loss across two rounds, retry no sooner than 15 minutes, start stopped RayLink, reconcile project routes, and probe HTTP once. Never reset a healthy network.' -Force | Out-Null
}
