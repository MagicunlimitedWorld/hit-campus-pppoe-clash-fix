$ErrorActionPreference = 'Stop'
# Load the task constructors before mocking registration: autoload exports can replace a mock.
Import-Module ScheduledTasks -ErrorAction Stop
. (Join-Path $PSScriptRoot 'HitNetClashConfig.ps1')
. (Join-Path $PSScriptRoot 'HitNetClashRuntime.ps1')
. (Join-Path $PSScriptRoot 'HitNetClashGuard.ps1')
$testRoot = Join-Path $PSScriptRoot ('.runtime\guard-selftest-' + [guid]::NewGuid().ToString('N'))
$statePath = Join-Path $testRoot '.runtime\state\connection_guard.json'
$script:checks = 0

# Every network/service operation is replaced before exercising the real controller.
function Resolve-HitNetClashConfig { return [pscustomobject]@{ SettingsPath = 'fixture'; RasEntry = 'HITnet' } }
function Get-HitNetGuardSnapshot {
    $script:calls.Read++
    if ($script:race -and $script:calls.Read -eq 2) { $script:fixture.RasConnected = $true }
    if ($script:intentRace -and $script:calls.Read -eq 2) { $script:fixture.Active = $false }
    if ($script:epochRace -and $script:calls.Read -eq 2) { $script:fixture.Epoch = 'new-epoch' }
    return $script:fixture.PSObject.Copy()
}
function Invoke-HitNetGuardDial {
    $script:calls.Dial++
    if ($script:failDial) { throw 'GUARD_DIAL_FAILED: RAS error 691.' }
    $script:fixture.RasConnected = $true
    $script:fixture.RoutesReady = $false
}
function Start-HitNetGuardRayLink {
    $script:calls.Start++
    if ($script:failServiceStart) { throw 'Fixture service start failed.' }
    $script:fixture.RayLinkStatus = 'Running'
}
function Invoke-HitNetGuardReconcile {
    $script:calls.Reconcile++
    if ($script:failReconcile) { throw 'Fixture route conflict.' }
    $script:fixture.RoutesReady = $true
}
function Acquire-HitNetNamedMutex { return (-not $script:busy) }
function Release-HitNetNamedMutex { }
function Test-HitNetGuardConnectivity {
    $script:calls.Probe++
    # Real probes finish after CheckedAtUtc: this must not skip the next round.
    return [pscustomobject]@{ AtUtc = $script:cycleNowUtc.AddSeconds(4).ToString('o'); SystemHttp = '401'; ProxyHttp = '401'; Reachable = (-not $script:failProbe) }
}
function Register-ScheduledTask {
    param($TaskName, $Action, $Trigger, $Settings, $Principal, $Description, [switch]$Force)
    $script:registered = [pscustomobject]@{
        TaskName = $TaskName; Action = $Action; Trigger = $Trigger
        Settings = $Settings; Principal = $Principal; Description = $Description
    }
}

function Reset-Fixture {
    if (Test-Path -LiteralPath $statePath) { Remove-Item -LiteralPath $statePath }
    $script:fixture = [pscustomobject]@{
        Active = $true; Epoch = 'fixture-epoch'; RasConnected = $true; EthernetReady = $true
        ManualDisconnect = $false; Disconnect = $null; ProxyReady = $true; TunReady = $true
        RoutesReady = $true; RayLinkStatus = 'Running'; RayLinkDisabled = $false
    }
    $script:calls = @{ Dial = 0; Start = 0; Reconcile = 0; Read = 0; Probe = 0 }
    $script:failDial = $false; $script:failReconcile = $false
    $script:race = $false; $script:intentRace = $false; $script:busy = $false; $script:failProbe = $false
    $script:epochRace = $false; $script:failServiceStart = $false
    $script:cycleNowUtc = ([datetime]'2026-09-05T12:00:00Z').ToUniversalTime()
}
function Assert-Guard {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
    $script:checks++
}
function Invoke-Cycle {
    param([int]$Seconds = 0)
    $script:cycleNowUtc = ([datetime]'2026-09-05T12:00:00Z').ToUniversalTime().AddSeconds($Seconds)
    return Invoke-HitNetGuardCycle -ScriptDir $testRoot -SettingsPath fixture -NowUtc $script:cycleNowUtc
}

try {
    Reset-Fixture
    $result = Invoke-HitNetGuardCycle -ScriptDir $testRoot -SettingsPath fixture -ObserveOnly
    Assert-Guard (-not (Test-Path -LiteralPath $statePath)) 'ObserveOnly changed persisted guard state.'
    Assert-Guard (($calls.Dial + $calls.Start + $calls.Reconcile) -eq 0) 'ObserveOnly changed networking.'
    Assert-Guard ($calls.Probe -eq 0) 'ObserveOnly performed an external probe.'

    $result = Invoke-Cycle
    Assert-Guard ($result.Code -eq 'GUARD_LOCAL_OK' -and $result.ExitCode -eq 0) 'Healthy connection was not accepted.'
    Assert-Guard (($calls.Dial + $calls.Start + $calls.Reconcile) -eq 0) 'Healthy connection was modified.'
    Assert-Guard ($calls.Probe -eq 1) 'Healthy round did not perform exactly one probe pair.'
    $null = Invoke-Cycle 900
    Assert-Guard ($calls.Probe -eq 2) 'Probe completion timestamp skipped the next 15-minute round.'
    $null = Invoke-Cycle 1800
    Assert-Guard ($calls.Probe -eq 3) 'A healthy round skipped or repeated its probe pair.'

    Reset-Fixture
    $fixture.RasConnected = $false; $fixture.RayLinkStatus = 'Stopped'
    $result = Invoke-Cycle
    Assert-Guard ($result.Code -eq 'GUARD_CONFIRM_DISCONNECT' -and $result.ExitCode -eq 2 -and $calls.Dial -eq 0) 'First drop was not confirmed before dialing.'
    $result = Invoke-Cycle 900
    Assert-Guard ($result.Code -eq 'GUARD_RECOVERED' -and $result.ExitCode -eq 0) ('Confirmed outage was not recovered: ' + ($result | ConvertTo-Json -Depth 5 -Compress))
    Assert-Guard ($calls.Dial -eq 1 -and $calls.Start -eq 1 -and $calls.Reconcile -eq 1) 'Recovery did not perform exactly the needed actions.'
    Assert-Guard ($calls.Probe -eq 1) 'Recovery round skipped or duplicated its probe pair.'
    $result = Invoke-Cycle 1800
    Assert-Guard ($calls.Dial -eq 1 -and $calls.Start -eq 1 -and $calls.Reconcile -eq 1) 'Recovery repeated on a healthy connection.'

    Reset-Fixture
    $fixture.RasConnected = $false; $script:failDial = $true
    $null = Invoke-Cycle
    $result = Invoke-Cycle 900
    Assert-Guard ($result.ExitCode -eq 2 -and $result.State.DialFailures -eq 1) 'Failed dial was marked successful.'
    Assert-Guard (([datetime]$result.State.NextDialUtc - [datetime]$result.State.CheckedAtUtc).TotalSeconds -eq 900) 'First dial failure did not set a 15-minute cooldown.'
    $decision = Get-HitNetGuardDecision -Snapshot $fixture -Previous $result.State -NowUtc $cycleNowUtc.AddSeconds(720)
    Assert-Guard ($decision -eq 'DIAL_BACKOFF' -and $calls.Dial -eq 1) 'Cooldown did not prevent repeated dialing.'
    $result = Invoke-Cycle 1800
    Assert-Guard ($result.State.DialFailures -eq 2 -and $calls.Dial -eq 2) 'Retry did not resume after cooldown.'
    Assert-Guard (([datetime]$result.State.NextDialUtc - [datetime]$result.State.CheckedAtUtc).TotalSeconds -eq 900) 'Repeated dial failure changed the 15-minute cooldown.'

    foreach ($kind in @('Inactive', 'Manual', 'EthernetDown', 'ClashDown', 'DisabledService', 'Busy')) {
        Reset-Fixture
        switch ($kind) {
            Inactive { $fixture.Active = $false; $fixture.RasConnected = $false }
            Manual { $fixture.ManualDisconnect = $true; $fixture.RasConnected = $false }
            EthernetDown { $fixture.EthernetReady = $false; $fixture.RasConnected = $false }
            ClashDown { $fixture.ProxyReady = $false; $fixture.TunReady = $false }
            DisabledService { $fixture.RayLinkStatus = 'Stopped'; $fixture.RayLinkDisabled = $true }
            Busy { $script:busy = $true }
        }
        $null = Invoke-Cycle
        $result = Invoke-Cycle 900
        Assert-Guard (($calls.Dial + $calls.Start + $calls.Reconcile) -eq 0) "$kind caused an unsafe recovery action."
    }

    Reset-Fixture
    $fixture.RayLinkStatus = 'Stopped'
    $result = Invoke-Cycle
    Assert-Guard ($calls.Start -eq 1 -and $calls.Dial -eq 0 -and $result.Code -eq 'GUARD_RECOVERED') 'Stopped RayLink did not recover independently of PPPoE.'

    Reset-Fixture
    $fixture.RayLinkStatus = 'Stopped'; $script:failServiceStart = $true
    $result = Invoke-Cycle
    Assert-Guard ($calls.Start -eq 1 -and $result.ExitCode -eq 2) 'Service start failure was not recorded.'
    Assert-Guard (([datetime]$result.State.NextServiceStartUtc - [datetime]$result.State.CheckedAtUtc).TotalSeconds -eq 900) 'Service start did not set a 15-minute cooldown.'
    $null = Invoke-Cycle 899
    Assert-Guard ($calls.Start -eq 1) 'Stopped service retried before its cooldown.'
    $null = Invoke-Cycle 900
    Assert-Guard ($calls.Start -eq 2) 'Stopped service did not retry at the next 15-minute round.'

    foreach ($kind in @('ConnectedDuringRead', 'IntentChanged', 'EpochChangedDuringRead')) {
        Reset-Fixture
        $fixture.RasConnected = $false
        $null = Invoke-Cycle
        $calls.Read = 0
        switch ($kind) {
            ConnectedDuringRead { $script:race = $true }
            IntentChanged { $script:intentRace = $true }
            EpochChangedDuringRead { $script:epochRace = $true }
        }
        $result = Invoke-Cycle 900
        Assert-Guard ($calls.Dial -eq 0) "$kind caused an unnecessary dial."
    }

    Reset-Fixture
    $fixture.RasConnected = $false; $script:failReconcile = $true
    $null = Invoke-Cycle
    $result = Invoke-Cycle 900
    Assert-Guard ($fixture.RasConnected -and $calls.Dial -eq 1 -and $result.ExitCode -eq 2) 'Route failure lost the recovered PPPoE connection.'

    foreach ($seconds in @(0, 10, 60, 719, 720, 900, 1200, 1201, 1800)) {
        Reset-Fixture
        $fixture.RasConnected = $false
        $null = Invoke-Cycle
        $result = Invoke-Cycle $seconds
        $expectedDials = if ($seconds -ge 720 -and $seconds -le 1200) { 1 } else { 0 }
        Assert-Guard ($calls.Dial -eq $expectedDials) "Incorrect disconnect confirmation at $seconds seconds."
    }

    Reset-Fixture
    $fixture.RasConnected = $false
    $null = Invoke-Cycle
    $result = Invoke-Cycle 1201
    Assert-Guard ($result.Code -eq 'GUARD_CONFIRM_DISCONNECT') 'Stale observation was not reconfirmed.'
    $result = Invoke-Cycle 2101
    Assert-Guard ($calls.Dial -eq 1) 'Next round did not recover after stale-state reconfirmation.'

    Reset-Fixture
    $fixture.RasConnected = $false
    $null = Invoke-Cycle
    $fixture.Epoch = 'new-epoch'
    $result = Invoke-Cycle 900
    Assert-Guard ($calls.Dial -eq 0 -and $result.Code -eq 'GUARD_CONFIRM_DISCONNECT') 'Different activity epochs were combined to authorize a dial.'

    Reset-Fixture
    $script:failProbe = $true
    $result = Invoke-Cycle
    Assert-Guard ($result.Code -eq 'GUARD_HTTP_WARNING' -and $result.ExitCode -eq 2) 'Unreachable HTTP path was reported healthy.'
    Assert-Guard (($calls.Dial + $calls.Start + $calls.Reconcile) -eq 0) 'HTTP failure reset a healthy local network.'
    Assert-Guard ($calls.Probe -eq 1) 'HTTP failure caused an extra probe pair.'

    $beforeRegistration = Get-Date
    Register-HitNetGuardTask -ScriptDir $PSScriptRoot -SettingsPath fixture
    $afterRegistration = Get-Date
    Assert-Guard ($registered.TaskName -eq 'HitCampusPppoeClashHealthCheck') 'Task registration changed the existing task name.'
    Assert-Guard ([string]$registered.Trigger.Repetition.Interval -eq 'PT15M') 'Real registrar did not request a 15-minute repetition.'
    $firstRun = [datetime]$registered.Trigger.StartBoundary
    Assert-Guard ($firstRun -ge $beforeRegistration.AddSeconds(899) -and $firstRun -le $afterRegistration.AddMinutes(15)) 'First run was not scheduled 15 minutes after registration.'
    Assert-Guard ([string]$registered.Settings.ExecutionTimeLimit -eq 'PT3M' -and $registered.Settings.MultipleInstances -eq 2) 'Task runtime or overlap settings changed.'
    Assert-Guard ($registered.Action.Arguments -match '-WindowStyle Hidden' -and $registered.Action.Arguments -match 'guard_pppoe_clash.ps1') 'Task action is not the hidden guard entrypoint.'

    "HITNET_GUARD_TEST_OK assertions=$script:checks (mocked network and services; no disconnections)"
}
finally {
    $full = [IO.Path]::GetFullPath($testRoot)
    $boundary = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '.runtime')) + [IO.Path]::DirectorySeparatorChar
    if ($full.StartsWith($boundary, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $full)) {
        Remove-Item -LiteralPath $full -Recurse -Force
    }
}
