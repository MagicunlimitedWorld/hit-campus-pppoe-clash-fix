$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'HitNetClashConfig.ps1')
. (Join-Path $PSScriptRoot 'HitNetClashRuntime.ps1')
. (Join-Path $PSScriptRoot 'HitNetClashGuard.ps1')
$script:checks = 0
function Assert-Stability([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:checks++
}
function Import-FixtureFunction([string]$File, [string]$Name) {
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $File),[ref]$tokens,[ref]$errors)
    $fn=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name},$true)
    if (-not $fn) { throw "Missing fixture function $Name" }
    Set-Item -Path ("function:script:"+$Name) -Value $fn.Body.GetScriptBlock()
}
$testRoot = Join-Path $PSScriptRoot ('.runtime\stability-selftest-'+[guid]::NewGuid().ToString('N'))
$script:routes=@(); $script:rules=@(); $script:removed=@(); $script:createdStores=@()
$script:failRead=$false; $script:failDelete=$false; $script:rasConnected=$false; $script:nativeCalls=0
function Get-NetRoute {
    [CmdletBinding()]param($PolicyStore,$DestinationPrefix,$InterfaceIndex,$InterfaceAlias,$NextHop)
    if ($script:failRead) { throw 'Fixture route provider failed.' }
    @($script:routes | Where-Object {
        (-not $DestinationPrefix -or $_.DestinationPrefix -eq $DestinationPrefix) -and
        (-not $InterfaceIndex -or $_.InterfaceIndex -eq $InterfaceIndex) -and
        (-not $NextHop -or $_.NextHop -eq $NextHop)
    })
}
function New-NetRoute {
    [CmdletBinding()]param($PolicyStore,$DestinationPrefix,$InterfaceIndex,$NextHop,$RouteMetric)
    $script:createdStores += $PolicyStore
    $script:routes += [pscustomobject]@{DestinationPrefix=$DestinationPrefix;InterfaceIndex=$InterfaceIndex;NextHop=$NextHop;RouteMetric=$RouteMetric;AddressFamily='IPv4'}
}
function Remove-NetRoute {
    [CmdletBinding()]param($PolicyStore,$DestinationPrefix,$InterfaceIndex,$NextHop,[switch]$Confirm)
    if ($script:failDelete) { throw 'Fixture deletion denied.' }
    Assert-Stability ($PolicyStore -eq 'ActiveStore') 'Cleanup attempted to change PersistentStore.'
    $script:removed += $DestinationPrefix
    $script:routes = @($script:routes | Where-Object { -not ($_.DestinationPrefix -eq $DestinationPrefix -and $_.InterfaceIndex -eq $InterfaceIndex -and $_.NextHop -eq $NextHop) })
}
function Get-DnsClientNrptRule { [CmdletBinding()]param() $script:rules }
function Remove-DnsClientNrptRule {
    [CmdletBinding()]param($Name,[switch]$Force)
    $script:rules=@($script:rules | Where-Object { $_.Name -ne $Name })
}
function Test-HitNetRasConnected { param($EntryName) return $script:rasConnected }
function Get-HitNetRasPhonebook { param($RasEntry) return 'fixture.pbk' }
function Invoke-HitNetNativeRasDial {
    param($Phonebook,$RasEntry,$Credential)
    $script:nativeCalls++
    Assert-Stability ($Credential.GetNetworkCredential().Password -ceq $script:fixturePassword) 'Credential changed at the native bridge.'
    [pscustomobject]@{ErrorCode=$script:nativeError;ConnectionHandle=[IntPtr]42}
}
function Write-Log { param($Message) $script:messages += [string]$Message }
function Save-OperationJournal { }
function Start-Sleep { param($Seconds) }

try {
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    # All system/network mutators above are mocks. Parsing never executes an entrypoint.
    $files=@(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1' -File)
    $files+=@(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'diagnostics') -Filter '*.ps1' -File)
    foreach ($file in $files) {
        $tokens=$null; $errors=$null
        $null=[Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
        Assert-Stability (-not $errors.Count) ("Parser errors: "+$file.Name)
    }
    Initialize-HitNetRasNative # Compile the real bridge, without calling RasDial or RasHangUp.
    Assert-Stability ([bool]('HitNet.GuardRas' -as [type])) 'Native RAS bridge did not compile.'

    $journal=[pscustomobject]@{OperationId='20260923_170000_000'}
    Assert-Stability (Test-HitNetOperationRollbackAllowed $journal $null) 'Uncommitted operation cannot roll back its additions.'
    Assert-Stability (-not (Test-HitNetOperationRollbackAllowed $journal ([pscustomobject]@{Timestamp=$journal.OperationId}))) 'Watchdog would undo a committed connection.'
    Assert-Stability (-not (Test-HitNetOperationRollbackAllowed $journal ([pscustomobject]@{Timestamp='20260923_171500_000'}))) 'Watchdog would interfere with a newer connection.'
    Assert-Stability (-not (Test-HitNetOperationRollbackAllowed $journal ([pscustomobject]@{Timestamp='invalid'}))) 'Watchdog acted on invalid activity state.'

    $base=[pscustomobject]@{DestinationPrefix='0.0.0.0/1';InterfaceIndex=9;NextHop='198.18.0.2';AddressFamily='IPv4';RouteMetric=0}
    $legacy=New-HitNetRouteRecord -Route $base -PreviousRoutes @($base)
    $reused=New-HitNetRouteRecord -Route $base
    $owned=New-HitNetRouteRecord -Route $base -Created
    Assert-Stability ($legacy.Ownership -eq 'Unknown' -and $legacy.PolicyStore -eq 'Unknown') 'Legacy route ownership was invented.'
    Assert-Stability ($reused.Ownership -eq 'Reused') 'An existing route was claimed.'
    $script:routes=@($base)
    Remove-HitNetOwnedResources -Routes @($legacy,$reused)
    Assert-Stability ($script:removed.Count -eq 0 -and $script:routes.Count -eq 1) 'Reused or legacy route was removed.'
    Remove-HitNetOwnedResources -Routes @($owned)
    Assert-Stability ($script:removed.Count -eq 1 -and $script:routes.Count -eq 0) 'Owned route was not removed.'
    Assert-Stability (Test-HitNetOwnedResourcesRemoved -Routes @($owned)) 'Absent owned route was not considered clean.'
    $changed=$base.PSObject.Copy(); $changed.RouteMetric=50; $script:routes=@($changed)
    $failed=$false
    try { Remove-HitNetOwnedResources -Routes @($owned) } catch { $failed=$true }
    Assert-Stability ($failed -and $script:routes.Count -eq 1) 'A changed route was deleted or reported clean.'
    $script:failRead=$true; $failed=$false
    try { Test-HitNetOwnedResourcesRemoved -Routes @($owned) | Out-Null } catch { $failed=$true }
    Assert-Stability $failed 'Provider failure was treated as an empty route table.'
    $script:failRead=$false

    # Exercise the real add function, including its record of an already-existing route.
    Import-FixtureFunction 'enter_pppoe_codex.ps1' 'Add-SplitRoute'
    $AddedRoutes=New-Object 'System.Collections.Generic.List[object]'
    $OperationCreatedRoutes=New-Object 'System.Collections.Generic.List[object]'
    $script:PreviousActiveState=$null; $script:messages=@(); $script:routes=@($base)
    Add-SplitRoute -DestinationPrefix '0.0.0.0/1' -InterfaceIndex 9 -NextHop '198.18.0.2' -AddressFamily IPv4
    Assert-Stability ($AddedRoutes[0].Ownership -eq 'Reused' -and $OperationCreatedRoutes.Count -eq 0) 'Reuse was recorded as a new operation resource.'
    Add-SplitRoute -DestinationPrefix '128.0.0.0/1' -InterfaceIndex 9 -NextHop '198.18.0.2' -AddressFamily IPv4
    Assert-Stability ($script:createdStores.Count -eq 1 -and $script:createdStores[0] -eq 'ActiveStore') 'New route was not confined to ActiveStore.'
    Assert-Stability ($OperationCreatedRoutes.Count -eq 1 -and $OperationCreatedRoutes[0].Ownership -eq 'Created') 'New route has no ownership record.'

    # The real state writer renews explicit connection intent, but a route reconcile preserves its epoch.
    Import-FixtureFunction 'enter_pppoe_codex.ps1' 'Save-State'
    Import-FixtureFunction 'enter_pppoe_codex.ps1' 'Assert-WorkspacePath'
    $ScriptDir=$testRoot; $StatePath=Join-Path $testRoot 'active.json'; $RestoreScript='fixture-restore'
    $Timestamp='20260923_170000_000'; $RasEntry='HITnet'; $ProxyUrl='http://127.0.0.1:7897'
    $TunInterfaceAlias='Meta'; $TunIpv4Gateway='198.18.0.2'; $TunIpv6Gateway='fdfe:dcba:9876::2'
    $NrptComment='fixture'; $LogPath='fixture'; $script:DesiredNrptRules=@()
    $ReconcileAddedRoutes=New-Object 'System.Collections.Generic.List[object]'
    $script:PreviousActiveState=[pscustomobject]@{Timestamp='20260901_000000_000';Routes=@($base);NrptRules=@();PausedByUser=$true}
    $ReconcileOnly=$false
    Save-State
    $saved=Get-HitNetJsonObject -Path $StatePath
    Assert-Stability ($saved.Timestamp -eq $Timestamp -and -not $saved.PausedByUser) 'Explicit fast-path save did not renew connection intent.'
    Assert-Stability ($saved.SchemaVersion -eq 2 -and $saved.Routes[0].Ownership -eq 'Unknown') 'Legacy route was silently adopted during state migration.'
    $script:PreviousActiveState=$saved; $Timestamp='20260923_171500_000'; $ReconcileOnly=$true
    Save-State
    Assert-Stability ((Get-HitNetJsonObject -Path $StatePath).Timestamp -eq $saved.Timestamp) 'Route reconciliation changed the activity epoch.'
    $ReconcileOnly=$false; $script:OperationCommitted=$false

    $stale=$owned.PSObject.Copy(); $stale.InterfaceIndex=4
    $merged=@(Merge-HitNetRouteRecords -ExpectedRoutes @($base) -PreviousRoutes @($stale,$legacy))
    Assert-Stability (@($merged | Where-Object { $_.InterfaceIndex -eq 4 -and $_.Ownership -eq 'Created' }).Count -eq 1) 'Stale ownership was dropped before cleanup completed.'

    $rule=[pscustomobject]@{Name='fixture-rule';Namespace=@('.example.test');NameServers=@('198.18.0.2');Comment='Corporate policy';DisplayName='Corporate policy'}
    $script:rules=@($rule)
    $nrptReused=Get-HitNetNrptRecord -Rule $rule
    Remove-HitNetOwnedResources -NrptRules @($nrptReused)
    Assert-Stability ($script:rules.Count -eq 1) 'Foreign compatible NRPT rule was removed.'
    $nrptOwned=Get-HitNetNrptRecord -Rule $rule -Created
    $changedRule=$rule.PSObject.Copy(); $changedRule.NameServers=@('10.0.0.53'); $script:rules=@($changedRule)
    $failed=$false
    try { Remove-HitNetOwnedResources -NrptRules @($nrptOwned) } catch { $failed=$true }
    Assert-Stability ($failed -and $script:rules.Count -eq 1) 'Changed NRPT policy was removed.'

    # Manual pause survives event retention and expires only with a new explicit connection epoch.
    $now=[datetime]::UtcNow
    $snapshot=[pscustomobject]@{Active=$true;Epoch='old';RasConnected=$false;EthernetReady=$true;ManualDisconnect=$false}
    $previous=[pscustomobject]@{Epoch='old';RasConnected=$false;CheckedAtUtc=$now.AddSeconds(-900).ToString('o');Code='GUARD_MANUAL_DISCONNECT';NextDialUtc=$null}
    Assert-Stability ((Get-HitNetGuardDecision $snapshot $previous $now) -eq 'MANUAL_DISCONNECT') 'Expired manual-disconnect event triggered dialing.'
    $previous | Add-Member PausedByUser $true
    $previous.Code='GUARD_INTENT_CHANGED'; $previous.CheckedAtUtc=$now.AddDays(-7).ToString('o')
    Assert-Stability ((Get-HitNetGuardDecision $snapshot $previous $now) -eq 'MANUAL_DISCONNECT') 'Persisted pause expired.'
    $snapshot.Epoch='new'
    Assert-Stability ((Get-HitNetGuardDecision $snapshot $previous $now) -eq 'CONFIRM_DISCONNECT') 'New explicit connection epoch remained paused.'

    $planArgs=@{ActiveState=[pscustomobject]@{RasEntry='HITnet';TunInterfaceAlias='Meta';NrptRuleNames=@('fixture-rule');Routes=@($base)};RasConnected=$true;ProxyListening=$true;TunReady=$true;RasEntry='HITnet';TunInterfaceAlias='Meta';TunInterfaceIndex=10;TunIpv4Gateway='198.18.0.2';TunIpv6Gateway='fdfe:dcba:9876::2';NrptNamespaces=@('.example.test');NrptRules=@($rule);Routes=@($base)}
    $plan=New-HitNetReconcilePlan @planArgs
    Assert-Stability ($plan.RoutesToRemove.Count -eq 0 -and $plan.RoutesToAdd.Count -eq 4) 'Reconciliation attempted to delete legacy routes after a TUN index change.'

    # SecureString passes through unchanged; neither a shell nor rasdial receives it.
    $script:fixturePassword='fixture space " quote & $ ! ' + [char]0x5bc6
    $cred=[pscredential]::new('fixture-user',(ConvertTo-SecureString $script:fixturePassword -AsPlainText -Force))
    $script:nativeError=0; $script:rasConnected=$false
    $dial=Invoke-HitNetRasDial -RasEntry HITnet -Credential $cred
    Assert-Stability ($dial.Created -and $script:nativeCalls -eq 1) 'Native dial was not used.'
    $script:rasConnected=$true
    $dial=Invoke-HitNetRasDial -RasEntry HITnet -Credential $cred
    Assert-Stability (-not $dial.Created -and $script:nativeCalls -eq 1) 'Connected RAS was redialed.'
    $script:rasConnected=$false; $script:nativeError=691; $failed=$false
    try { Invoke-HitNetRasDial -RasEntry HITnet -Credential $cred | Out-Null } catch { $failed=$_.Exception.Message -match '691' }
    Assert-Stability $failed 'Native RAS failure was reported as success.'
    $cred.Password.Dispose()

    $settingsPath=Join-Path $testRoot 'settings.json'
    Write-HitNetJsonAtomic -Path $settingsPath -InputObject ([pscustomobject]@{Value=1})
    Write-HitNetJsonAtomic -Path $settingsPath -InputObject ([pscustomobject]@{Value=2})
    Assert-Stability ((Get-HitNetJsonObject $settingsPath).Value -eq 2) 'Atomic settings update failed.'
    [IO.File]::WriteAllText($settingsPath,'{ broken JSON')
    $failed=$false
    try { Resolve-HitNetClashConfig -ScriptDir $PSScriptRoot -SettingsPath $settingsPath | Out-Null } catch { $failed=$_.Exception.Message -match 'INVALID_JSON' }
    Assert-Stability $failed 'Corrupt settings silently fell back to defaults.'

    # Real restore cleanup must throw when any removal failed, even if RAS was already disconnected.
    Import-FixtureFunction 'restore_wlan_clash.ps1' 'Invoke-RestoreLocalCleanup'
    $RasEntry='fixture'; $script:rasConnected=$false; $script:routes=@($base); $script:failDelete=$true
    $active=[pscustomobject]@{Routes=@($owned);NrptRules=@();NrptRuleNames=@()}
    $failed=$false
    try { Invoke-RestoreLocalCleanup -ActiveState $active } catch { $failed=$_.Exception.Message -match 'RESTORE_LOCAL_CLEANUP_FAILED' }
    Assert-Stability $failed 'Partial cleanup was reported successful.'
    $script:failDelete=$false
    Invoke-RestoreLocalCleanup -ActiveState $active
    Assert-Stability ($script:routes.Count -eq 0) 'Restore did not remove its owned route.'

    Import-FixtureFunction 'enter_pppoe_codex.ps1' 'Restore-OnFailure'
    $script:OperationCommitted=$false; $script:OperationDial=$null
    $OperationCreatedRoutes.Clear()
    $OperationCreatedNrptRules=New-Object 'System.Collections.Generic.List[object]'
    $script:routes=@($base); $script:rasConnected=$true
    Restore-OnFailure
    Assert-Stability ($script:rasConnected -and $script:routes.Count -eq 1) 'Failed enter changed pre-existing networking.'

    foreach ($file in @('enter_pppoe_codex.ps1','connect_pppoe_only.ps1','HitNetClashGuard.ps1')) {
        $text=Get-Content -LiteralPath (Join-Path $PSScriptRoot $file) -Raw
        Assert-Stability ($text -notmatch 'rasdial\.exe\s+\$RasEntry\s+\$Cred') ('Credential-bearing rasdial call remains in '+$file)
    }
    'HITNET_STABILITY_TEST_OK assertions='+$script:checks+' (mocked networking; no disconnections)'
}
finally {
    $full=[IO.Path]::GetFullPath($testRoot)
    $boundary=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '.runtime'))+[IO.Path]::DirectorySeparatorChar
    if ($full.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $full)) { Remove-Item -LiteralPath $full -Recurse -Force }
}
