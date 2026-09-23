param([string]$JournalPath, [string]$DonePath, [string]$LogPath, [int]$TimeoutSeconds = 180)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'HitNetClashConfig.ps1')
. (Join-Path $PSScriptRoot 'HitNetClashRuntime.ps1')
$deadline = [datetime]::UtcNow.AddSeconds([Math]::Max(30, $TimeoutSeconds))
while ([datetime]::UtcNow -lt $deadline) {
    if (Test-Path -LiteralPath $DonePath) { return }
    Start-Sleep -Seconds 5
}
$lock = New-HitNetNamedMutexState -Name 'Local\HitCampusPppoeClashEnter'
try {
    if (-not (Acquire-HitNetNamedMutex -State $lock -WaitSeconds 0)) {
        Write-HitNetLog -LogPath $LogPath -Message 'WATCHDOG_BUSY: operation still owns its lock; no network changes.'
        return
    }
    if (Test-Path -LiteralPath $DonePath) { return }
    $journal = Get-HitNetJsonObject -Path $JournalPath
    $active = Get-HitNetJsonObject -Path (Join-Path $PSScriptRoot '.runtime\state\pppoe_codex_active_state.json')
    if (-not (Test-HitNetOperationRollbackAllowed -Journal $journal -ActiveState $active)) { return }
    Remove-HitNetOwnedResources -Routes @($journal.Routes) -NrptRules @($journal.NrptRules)
    Write-HitNetLog -LogPath $LogPath -Message 'WATCHDOG_ROLLBACK: removed only journaled additions; RAS connections retained.'
}
catch { Write-HitNetLog -LogPath $LogPath -Message ('WATCHDOG_FAILED: ' + $_.Exception.Message) }
finally { Release-HitNetNamedMutex -State $lock }
