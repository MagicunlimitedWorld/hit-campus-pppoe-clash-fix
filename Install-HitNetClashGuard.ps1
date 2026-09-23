param([string]$SettingsPath)

$ErrorActionPreference = 'Stop'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this installer as the same Windows user with administrator privileges.'
}
. (Join-Path $PSScriptRoot 'HitNetClashConfig.ps1')
. (Join-Path $PSScriptRoot 'HitNetClashRuntime.ps1')
. (Join-Path $PSScriptRoot 'HitNetClashGuard.ps1')
if (-not $SettingsPath) { $SettingsPath = Join-Path $PSScriptRoot '.local\settings.json' }
$log = Join-Path $PSScriptRoot '.runtime\logs\guard-install.log'
try {
    $config = Resolve-HitNetClashConfig -ScriptDir $PSScriptRoot -SettingsPath $SettingsPath
    $null = Get-HitNetGuardCredential -SettingsPath $SettingsPath
    $book = Get-HitNetGuardPhonebook -RasEntry $config.RasEntry
    Initialize-HitNetGuardNative
    $code = [HitNet.GuardRas]::ValidatePhonebook($book, $config.RasEntry)
    if ($code -ne 0) { throw "Native RAS phonebook validation failed: $code" }

    $backup = Join-Path $PSScriptRoot ('.runtime\backups\guard-install-' + (Get-Date -Format yyyyMMdd_HHmmss))
    New-Item -ItemType Directory -Path $backup | Out-Null
    $task = Get-ScheduledTask -TaskName HitCampusPppoeClashHealthCheck -ErrorAction SilentlyContinue
    if ($task) { Export-ScheduledTask -TaskName $task.TaskName | Set-Content -LiteralPath (Join-Path $backup 'health-task.xml') -Encoding Unicode }
    $service = Get-Service -Name RayLinkService -ErrorAction SilentlyContinue
    if ($service) {
        $recovery = & sc.exe qfailure RayLinkService
        if ($LASTEXITCODE -ne 0) { throw 'Cannot read RayLink recovery configuration.' }
        $recovery | Set-Content -LiteralPath (Join-Path $backup 'raylink-recovery-before.txt') -Encoding UTF8
        $null = & sc.exe failure RayLinkService reset= 86400 actions= restart/60000/restart/120000/restart/300000
        if ($LASTEXITCODE -ne 0) { throw 'Cannot configure RayLink service failure recovery.' }
    }
    Register-HitNetGuardTask -ScriptDir $PSScriptRoot -SettingsPath $SettingsPath
    Write-HitNetLog -LogPath $log -Message "GUARD_INSTALL_OK: 15-minute recovery task; 3-minute execution limit; RayLink failure restart configured when installed. Backup=$backup"
}
catch {
    Write-HitNetLog -LogPath $log -Message ('GUARD_INSTALL_FAILED: ' + $_.Exception.Message)
    throw
}
