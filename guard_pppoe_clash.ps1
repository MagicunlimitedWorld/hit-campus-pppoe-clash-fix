param([string]$SettingsPath, [switch]$ObserveOnly)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'HitNetClashConfig.ps1')
. (Join-Path $PSScriptRoot 'HitNetClashRuntime.ps1')
. (Join-Path $PSScriptRoot 'HitNetClashGuard.ps1')
if (-not $SettingsPath) { $SettingsPath = Join-Path $PSScriptRoot '.local\settings.json' }
$log = Join-Path $PSScriptRoot ('.runtime\logs\connection_guard_{0}.log' -f (Get-Date -Format yyyyMMdd))
$lock = New-HitNetNamedMutexState -Name 'Local\HitCampusPppoeClashGuard'
$resultCode = 2
try {
    if (-not (Acquire-HitNetNamedMutex -State $lock -WaitSeconds 0)) {
        Write-Output 'GUARD_BUSY'
        exit 0
    }
    $result = Invoke-HitNetGuardCycle -ScriptDir $PSScriptRoot -SettingsPath $SettingsPath -ObserveOnly:$ObserveOnly
    Write-HitNetLog -LogPath $log -Message ($result | ConvertTo-Json -Depth 5 -Compress)
    $resultCode = $result.ExitCode
}
catch { Write-HitNetLog -LogPath $log -Message ('GUARD_FAILED: {0}' -f $_.Exception.Message) }
finally { Release-HitNetNamedMutex -State $lock }
exit $resultCode
