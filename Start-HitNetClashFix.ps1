param(
    [string]$RasEntry,
    [string]$ProxyUrl,
    [string]$TunInterfaceAlias,
    [string]$ClashPath,
    [string]$SettingsPath,
    [switch]$SelfTest,
    [switch]$NoElevation
)

$ErrorActionPreference = "Stop"

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$EnterScript = Join-Path $ScriptDir "enter_pppoe_codex.ps1"
$PppoeOnlyScript = Join-Path $ScriptDir "connect_pppoe_only.ps1"
$RestoreScript = Join-Path $ScriptDir "restore_wlan_clash.ps1"
$AutoConnectScript = Join-Path $ScriptDir "auto_connect_pppoe_clash.ps1"
$ConfigScript = Join-Path $ScriptDir "HitNetClashConfig.ps1"
$AutoConnectTaskName = "HitCampusPppoeClashAutoConnect"
$RuntimeDir = Join-Path $ScriptDir ".runtime"
$RuntimeLogDir = Join-Path $RuntimeDir "logs"
$RuntimeMarkerDir = Join-Path $RuntimeDir "markers"
$RuntimeStateDir = Join-Path $RuntimeDir "state"
$StatePath = Join-Path $RuntimeStateDir "pppoe_codex_active_state.json"
if ([string]::IsNullOrWhiteSpace($SettingsPath)) {
    $SettingsPath = Join-Path $ScriptDir ".local\settings.json"
}

if (-not (Test-Path -LiteralPath $ConfigScript)) {
    throw "Config helper not found: $ConfigScript"
}
. $ConfigScript
$script:CurrentConfig = Resolve-HitNetClashConfig -ScriptDir $ScriptDir -SettingsPath $SettingsPath -RasEntry $RasEntry -ProxyUrl $ProxyUrl -TunInterfaceAlias $TunInterfaceAlias -ClashPath $ClashPath

$script:RasEntryBox = $null
$script:ProxyUrlBox = $null
$script:TunAliasBox = $null
$script:ClashPathBox = $null

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Quote-Arg {
    param([string]$Value)
    return '"' + ($Value -replace '"', '\"') + '"'
}

function Restart-AsAdministrator {
    $powershellExe = Join-Path $PSHOME "powershell.exe"
    $args = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-STA",
        "-File", (Quote-Arg $PSCommandPath),
        "-RasEntry", (Quote-Arg $script:CurrentConfig.RasEntry),
        "-ProxyUrl", (Quote-Arg $script:CurrentConfig.ProxyUrl),
        "-TunInterfaceAlias", (Quote-Arg $script:CurrentConfig.TunInterfaceAlias),
        "-ClashPath", (Quote-Arg $script:CurrentConfig.ClashPath),
        "-SettingsPath", (Quote-Arg $SettingsPath),
        "-NoElevation"
    ) -join " "
    Start-Process -FilePath $powershellExe -ArgumentList $args -Verb RunAs | Out-Null
}

function ConvertFrom-SecureStringToPlainText {
    param([securestring]$SecureString)
    if ($null -eq $SecureString -or $SecureString.Length -eq 0) {
        return ""
    }
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

function ConvertTo-PlainTextFromProtectedText {
    param([string]$ProtectedText)
    if ([string]::IsNullOrWhiteSpace($ProtectedText)) {
        return ""
    }
    try {
        $secure = ConvertTo-SecureString $ProtectedText
        return ConvertFrom-SecureStringToPlainText -SecureString $secure
    }
    catch {
        return ""
    }
}

function Get-AppSettings {
    $defaults = [pscustomobject]@{
        RememberAccount = $false
        Account = ""
        RememberPassword = $false
        PasswordProtected = ""
        AutoCloseOnSuccess = $false
        AutoConnectOnLogon = $false
        RasEntry = $script:CurrentConfig.RasEntry
        ProxyUrl = $script:CurrentConfig.ProxyUrl
        TunInterfaceAlias = $script:CurrentConfig.TunInterfaceAlias
        TunIpv4Gateway = $script:CurrentConfig.TunIpv4Gateway
        TunIpv6Gateway = $script:CurrentConfig.TunIpv6Gateway
        ClashPath = $script:CurrentConfig.ClashPath
    }

    if (-not (Test-Path -LiteralPath $SettingsPath)) {
        return $defaults
    }

    try {
        $settings = Get-Content -LiteralPath $SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        return [pscustomobject]@{
            RememberAccount = [bool]$settings.RememberAccount
            Account = [string]$settings.Account
            RememberPassword = [bool]$settings.RememberPassword
            PasswordProtected = [string]$settings.PasswordProtected
            AutoCloseOnSuccess = [bool]$settings.AutoCloseOnSuccess
            AutoConnectOnLogon = [bool]$settings.AutoConnectOnLogon
            RasEntry = $script:CurrentConfig.RasEntry
            ProxyUrl = $script:CurrentConfig.ProxyUrl
            TunInterfaceAlias = $script:CurrentConfig.TunInterfaceAlias
            TunIpv4Gateway = $script:CurrentConfig.TunIpv4Gateway
            TunIpv6Gateway = $script:CurrentConfig.TunIpv6Gateway
            ClashPath = $script:CurrentConfig.ClashPath
        }
    }
    catch {
        return $defaults
    }
}

function Save-AppSettings {
    param(
        [string]$Account,
        [securestring]$Password,
        [bool]$RememberAccount,
        [bool]$RememberPassword,
        [bool]$AutoCloseOnSuccess,
        [bool]$AutoConnectOnLogon,
        [string]$RasEntryValue,
        [string]$ProxyUrlValue,
        [string]$TunInterfaceAliasValue,
        [string]$TunIpv4GatewayValue,
        [string]$TunIpv6GatewayValue,
        [string]$ClashPathValue
    )

    $settingsDir = Split-Path -Parent $SettingsPath
    if (-not (Test-Path -LiteralPath $settingsDir)) {
        New-Item -Path $settingsDir -ItemType Directory -Force | Out-Null
    }

    $protectedPassword = ""
    if ($RememberPassword -and $null -ne $Password -and $Password.Length -gt 0) {
        $protectedPassword = ConvertFrom-SecureString $Password
    }

    $settings = [ordered]@{
        RememberAccount = $RememberAccount
        Account = if ($RememberAccount) { $Account } else { "" }
        RememberPassword = $RememberPassword
        PasswordProtected = $protectedPassword
        AutoCloseOnSuccess = $AutoCloseOnSuccess
        AutoConnectOnLogon = $AutoConnectOnLogon
        RasEntry = $RasEntryValue
        ProxyUrl = $ProxyUrlValue
        TunInterfaceAlias = $TunInterfaceAliasValue
        TunIpv4Gateway = $TunIpv4GatewayValue
        TunIpv6Gateway = $TunIpv6GatewayValue
        ClashPath = $ClashPathValue
    }

    $existing = Get-HitNetJsonObject -Path $SettingsPath
    foreach ($name in @("ClashExecutableCandidates", "NrptNamespaces", "EthernetNamePatterns", "ClashProcessName", "ClashCoreProcessName")) {
        if ($null -ne $existing -and $null -ne $existing.$name) {
            $settings[$name] = $existing.$name
        }
    }

    [pscustomobject]$settings | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $SettingsPath -Encoding UTF8
}

function Get-UiConfig {
    $ras = if ($script:RasEntryBox) { $script:RasEntryBox.Text.Trim() } else { $script:CurrentConfig.RasEntry }
    $proxy = if ($script:ProxyUrlBox) { $script:ProxyUrlBox.Text.Trim() } else { $script:CurrentConfig.ProxyUrl }
    $tun = if ($script:TunAliasBox) { $script:TunAliasBox.Text.Trim() } else { $script:CurrentConfig.TunInterfaceAlias }
    $clash = if ($script:ClashPathBox) { $script:ClashPathBox.Text.Trim() } else { $script:CurrentConfig.ClashPath }

    return [pscustomobject]@{
        RasEntry = $ras
        ProxyUrl = $proxy
        TunInterfaceAlias = $tun
        TunIpv4Gateway = $script:CurrentConfig.TunIpv4Gateway
        TunIpv6Gateway = $script:CurrentConfig.TunIpv6Gateway
        ClashPath = $clash
    }
}

function Test-ClashPort {
    param([string]$Url)
    try {
        $uri = [Uri]$Url
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

function Get-RasConnected {
    param([string]$EntryName)
    try {
        $status = (& rasdial.exe 2>&1 | Out-String)
        return ($status -match [regex]::Escape($EntryName))
    }
    catch {
        return $false
    }
}

function Get-TunReady {
    param([string]$Alias)
    try {
        $adapter = Get-NetAdapter -Name $Alias -ErrorAction SilentlyContinue
        return ($adapter -and $adapter.Status -eq "Up")
    }
    catch {
        return $false
    }
}

function Get-EthernetReady {
    $adapter = Get-NetAdapter -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Status -eq "Up" -and
            $_.Name -ne $script:CurrentConfig.TunInterfaceAlias -and
            $_.Name -notmatch "WLAN|Wi-?Fi|Wireless|Meta|Clash|TUN|Loopback|Bluetooth" -and
            $_.InterfaceDescription -notmatch "Wireless|Wi-?Fi|Meta|Clash|TUN|Loopback|Bluetooth|Virtual"
        } |
        Select-Object -First 1
    return [bool]$adapter
}

function Get-AutoConnectTask {
    try {
        return Get-ScheduledTask -TaskName $AutoConnectTaskName -ErrorAction SilentlyContinue | Select-Object -First 1
    }
    catch {
        return $null
    }
}

function Get-AutoConnectTaskActionArguments {
    param([string]$SettingsPathValue = $SettingsPath)
    return '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File {0} -SettingsPath {1}' -f (Quote-Arg $AutoConnectScript), (Quote-Arg $SettingsPathValue)
}

function Get-AutoConnectTaskStatusText {
    $task = Get-AutoConnectTask
    if (-not $task) {
        return "登录后自动连接: 未启用"
    }

    try {
        $info = Get-ScheduledTaskInfo -TaskName $AutoConnectTaskName -ErrorAction Stop
        return "登录后自动连接: 已启用 State=$($task.State) LastRun=$($info.LastRunTime) LastResult=$($info.LastTaskResult)"
    }
    catch {
        return "登录后自动连接: 已启用 State=$($task.State)"
    }
}

function Register-AutoConnectTask {
    if (-not (Test-Path -LiteralPath $AutoConnectScript)) {
        throw "自动连接脚本不存在: $AutoConnectScript"
    }

    $powershellExe = Join-Path $PSHOME "powershell.exe"
    $action = New-ScheduledTaskAction -Execute $powershellExe -Argument (Get-AutoConnectTaskActionArguments)
    $userId = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $userId
    try {
        $trigger.Delay = "PT30S"
    }
    catch {
    }
    $principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Highest
    $taskSettings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $AutoConnectTaskName -Action $action -Trigger $trigger -Principal $principal -Settings $taskSettings -Description "Logon auto-connect for HIT PPPoE plus Clash." -Force | Out-Null
}

function Unregister-AutoConnectTask {
    $task = Get-AutoConnectTask
    if ($task) {
        Unregister-ScheduledTask -TaskName $AutoConnectTaskName -Confirm:$false
    }
}

function Get-StateSummary {
    $cfg = Get-UiConfig
    $rasText = if (Get-RasConnected -EntryName $cfg.RasEntry) { "$($cfg.RasEntry): 已连接" } else { "$($cfg.RasEntry): 未连接" }
    $clashText = if (Test-ClashPort -Url $cfg.ProxyUrl) { "Clash: 已监听" } else { "Clash: 未监听" }
    $tunText = if (Get-TunReady -Alias $cfg.TunInterfaceAlias) { "TUN: 已就绪" } else { "TUN: 未就绪" }
    $ethText = if (Get-EthernetReady) { "有线: 已连接" } else { "有线: 未就绪" }
    $stateText = if (Test-Path -LiteralPath $StatePath) { "状态文件: 存在" } else { "状态文件: 无" }
    $autoText = if (Get-AutoConnectTask) { "自启: 已启用" } else { "自启: 未启用" }
    return "$rasText    $clashText    $tunText    $ethText    $stateText    $autoText"
}

function Get-DetailedStatusText {
    param([string]$Label = "刷新状态")

    $cfg = Get-UiConfig
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add(("=== {0} {1} ===" -f $Label, (Get-Date -Format "yyyy-MM-dd HH:mm:ss"))) | Out-Null
    $lines.Add((Get-StateSummary)) | Out-Null
    $lines.Add(("PPPoE: {0}" -f $cfg.RasEntry)) | Out-Null
    $lines.Add(("Proxy: {0}" -f $cfg.ProxyUrl)) | Out-Null
    $lines.Add(("TUN: {0}" -f $cfg.TunInterfaceAlias)) | Out-Null
    $lines.Add(("ClashPath: {0}" -f $cfg.ClashPath)) | Out-Null
    $lines.Add(("状态文件路径: {0}" -f $StatePath)) | Out-Null
    $lines.Add((Get-AutoConnectTaskStatusText)) | Out-Null

    $ras = (& rasdial.exe 2>&1 | Out-String).Trim()
    $lines.Add("--- rasdial ---") | Out-Null
    $lines.Add($(if ([string]::IsNullOrWhiteSpace($ras)) { "(no output)" } else { $ras })) | Out-Null

    $lines.Add("--- adapters ---") | Out-Null
    $tunPattern = [regex]::Escape($cfg.TunInterfaceAlias)
    $adapters = Get-NetAdapter -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match "WLAN|Wi-?Fi|以太|Ethernet|Meta|Clash|TUN|$tunPattern" -or $_.InterfaceDescription -match "Wireless|Ethernet|Meta|Clash|TUN|$tunPattern" } |
        Select-Object Name, InterfaceDescription, Status, LinkSpeed, ifIndex |
        Out-String -Width 4096
    $lines.Add($(if ([string]::IsNullOrWhiteSpace($adapters)) { "(none)" } else { $adapters.Trim() })) | Out-Null

    $lines.Add("--- Clash listen ---") | Out-Null
    $proc = Get-Process -Name $script:CurrentConfig.ClashCoreProcessName -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($proc) {
        $listen = Get-NetTCPConnection -OwningProcess $proc.Id -State Listen -ErrorAction SilentlyContinue |
            Select-Object LocalAddress, LocalPort, State |
            Sort-Object LocalPort |
            Out-String -Width 4096
        $lines.Add($listen.Trim()) | Out-Null
    }
    else {
        $lines.Add("$($script:CurrentConfig.ClashCoreProcessName) 未运行") | Out-Null
    }

    $nrpt = Get-DnsClientNrptRule -ErrorAction SilentlyContinue |
        Where-Object { $_.Comment -like "CodexClash*" -or $_.DisplayName -like "CodexClash*" } |
        Select-Object Namespace, NameServers, Comment |
        Out-String -Width 4096
    $lines.Add("--- Codex NRPT ---") | Out-Null
    $lines.Add($(if ([string]::IsNullOrWhiteSpace($nrpt)) { "(none)" } else { $nrpt.Trim() })) | Out-Null

    $routes = Get-NetRoute -DestinationPrefix "0.0.0.0/1", "128.0.0.0/1", "::/1", "8000::/1" -ErrorAction SilentlyContinue |
        Select-Object DestinationPrefix, NextHop, InterfaceAlias, RouteMetric, InterfaceMetric, AddressFamily |
        Out-String -Width 4096
    $lines.Add("--- Codex split routes ---") | Out-Null
    $lines.Add($(if ([string]::IsNullOrWhiteSpace($routes)) { "(none)" } else { $routes.Trim() })) | Out-Null

    $lines.Add("--- logon auto-connect task ---") | Out-Null
    $task = Get-AutoConnectTask
    if ($task) {
        $taskActions = @($task.Actions | ForEach-Object { "{0} {1}" -f $_.Execute, $_.Arguments }) -join [Environment]::NewLine
        $lines.Add($taskActions) | Out-Null
    }
    else {
        $lines.Add("(not registered)") | Out-Null
    }
    return ($lines -join [Environment]::NewLine)
}

function Invoke-SelfTest {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $testForm = [System.Windows.Forms.Form]::new()
    $testForm.Text = "SelfTest"
    $testButton = [System.Windows.Forms.Button]::new()
    $testButton.Text = "OK"
    $testForm.Controls.Add($testButton)
    if ($testForm.Controls.Count -ne 1) {
        throw "SelfTest control construction failed."
    }

    $testPath = Join-Path $ScriptDir ".local\selftest.settings.json"
    $script:SettingsPath = $testPath
    $secure = ConvertTo-SecureString "selftest-password" -AsPlainText -Force
    Save-AppSettings -Account "selftest-account" -Password $secure -RememberAccount $true -RememberPassword $true -AutoCloseOnSuccess $true -AutoConnectOnLogon $true -RasEntryValue "SelfTestRas" -ProxyUrlValue "http://127.0.0.1:18080" -TunInterfaceAliasValue "SelfTestTun" -TunIpv4GatewayValue "198.18.0.2" -TunIpv6GatewayValue "fdfe:dcba:9876::2" -ClashPathValue "C:\SelfTest\clash-verge.exe"
    $script:CurrentConfig = Resolve-HitNetClashConfig -ScriptDir $ScriptDir -SettingsPath $testPath
    $loaded = Get-AppSettings
    $plain = ConvertTo-PlainTextFromProtectedText -ProtectedText $loaded.PasswordProtected
    if (-not $loaded.RememberAccount -or $loaded.Account -ne "selftest-account" -or $plain -ne "selftest-password" -or -not $loaded.AutoCloseOnSuccess -or -not $loaded.AutoConnectOnLogon) {
        throw "SelfTest settings roundtrip failed."
    }
    if ($loaded.RasEntry -ne "SelfTestRas" -or $loaded.ProxyUrl -ne "http://127.0.0.1:18080" -or $loaded.TunInterfaceAlias -ne "SelfTestTun") {
        throw "SelfTest config roundtrip failed."
    }
    $statusText = Get-DetailedStatusText -Label "SelfTest"
    if ([string]::IsNullOrWhiteSpace($statusText) -or $statusText -notmatch "rasdial" -or $statusText -notmatch "Codex split routes") {
        throw "SelfTest detailed status output failed."
    }
    $taskArgs = Get-AutoConnectTaskActionArguments -SettingsPathValue $testPath
    if ($taskArgs -notmatch "auto_connect_pppoe_clash\.ps1" -or $taskArgs -notmatch [regex]::Escape($testPath) -or $taskArgs -match "selftest-password") {
        throw "SelfTest auto-connect task command failed."
    }
    foreach ($runtimePath in @($RuntimeLogDir, $RuntimeMarkerDir, $RuntimeStateDir)) {
        if ([string]::IsNullOrWhiteSpace($runtimePath)) {
            throw "SelfTest runtime path is empty."
        }
    }
    Remove-Item -LiteralPath $testPath -Force -ErrorAction SilentlyContinue
    "SELFTEST_OK"
}

if ($SelfTest) {
    Invoke-SelfTest
    exit 0
}

if (-not $NoElevation -and -not (Test-IsAdministrator)) {
    Restart-AsAdministrator
    exit 0
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$settings = Get-AppSettings

$form = [System.Windows.Forms.Form]::new()
$form.Text = "HIT PPPoE + Clash 代理修复"
$form.StartPosition = "CenterScreen"
$form.Size = [System.Drawing.Size]::new(760, 700)
$form.MinimumSize = [System.Drawing.Size]::new(760, 700)
$form.Font = [System.Drawing.Font]::new("Microsoft YaHei UI", 9)

$titleLabel = [System.Windows.Forms.Label]::new()
$titleLabel.AutoSize = $false
$titleLabel.Location = [System.Drawing.Point]::new(20, 14)
$titleLabel.Size = [System.Drawing.Size]::new(700, 28)
$titleLabel.Font = [System.Drawing.Font]::new("Microsoft YaHei UI", 13, [System.Drawing.FontStyle]::Bold)
$titleLabel.Text = "修复 PPPoE 拨号后 Clash 代理不可用"
$form.Controls.Add($titleLabel)

$subtitleLabel = [System.Windows.Forms.Label]::new()
$subtitleLabel.AutoSize = $false
$subtitleLabel.Location = [System.Drawing.Point]::new(22, 44)
$subtitleLabel.Size = [System.Drawing.Size]::new(700, 22)
$subtitleLabel.Text = "输入校园网账号后，一键连接有线 PPPoE 并保持 Clash 代理可用。"
$form.Controls.Add($subtitleLabel)

$statusLabel = [System.Windows.Forms.Label]::new()
$statusLabel.AutoSize = $false
$statusLabel.Location = [System.Drawing.Point]::new(22, 70)
$statusLabel.Size = [System.Drawing.Size]::new(700, 24)
$statusLabel.Text = Get-StateSummary
$form.Controls.Add($statusLabel)

$loginGroup = [System.Windows.Forms.GroupBox]::new()
$loginGroup.Location = [System.Drawing.Point]::new(20, 102)
$loginGroup.Size = [System.Drawing.Size]::new(700, 96)
$loginGroup.Text = "校园网登录"
$form.Controls.Add($loginGroup)

$advancedGroup = [System.Windows.Forms.GroupBox]::new()
$advancedGroup.Location = [System.Drawing.Point]::new(20, 210)
$advancedGroup.Size = [System.Drawing.Size]::new(700, 124)
$advancedGroup.Text = "高级配置"
$form.Controls.Add($advancedGroup)

$accountLabel = [System.Windows.Forms.Label]::new()
$accountLabel.Location = [System.Drawing.Point]::new(18, 30)
$accountLabel.Size = [System.Drawing.Size]::new(90, 24)
$accountLabel.Text = "校园网账号"
$loginGroup.Controls.Add($accountLabel)

$accountBox = [System.Windows.Forms.TextBox]::new()
$accountBox.Location = [System.Drawing.Point]::new(108, 27)
$accountBox.Size = [System.Drawing.Size]::new(250, 24)
$accountBox.Text = if ($settings.RememberAccount) { $settings.Account } else { "" }
$loginGroup.Controls.Add($accountBox)

$rememberAccountBox = [System.Windows.Forms.CheckBox]::new()
$rememberAccountBox.Location = [System.Drawing.Point]::new(378, 27)
$rememberAccountBox.Size = [System.Drawing.Size]::new(120, 24)
$rememberAccountBox.Text = "记住账号"
$rememberAccountBox.Checked = [bool]$settings.RememberAccount
$loginGroup.Controls.Add($rememberAccountBox)

$passwordLabel = [System.Windows.Forms.Label]::new()
$passwordLabel.Location = [System.Drawing.Point]::new(18, 62)
$passwordLabel.Size = [System.Drawing.Size]::new(90, 24)
$passwordLabel.Text = "校园网密码"
$loginGroup.Controls.Add($passwordLabel)

$passwordBox = [System.Windows.Forms.TextBox]::new()
$passwordBox.Location = [System.Drawing.Point]::new(108, 59)
$passwordBox.Size = [System.Drawing.Size]::new(250, 24)
$passwordBox.UseSystemPasswordChar = $true
if ($settings.RememberPassword) {
    $passwordBox.Text = ConvertTo-PlainTextFromProtectedText -ProtectedText $settings.PasswordProtected
}
$loginGroup.Controls.Add($passwordBox)

$rememberPasswordBox = [System.Windows.Forms.CheckBox]::new()
$rememberPasswordBox.Location = [System.Drawing.Point]::new(378, 59)
$rememberPasswordBox.Size = [System.Drawing.Size]::new(120, 24)
$rememberPasswordBox.Text = "记住密码"
$rememberPasswordBox.Checked = [bool]$settings.RememberPassword
$loginGroup.Controls.Add($rememberPasswordBox)

$autoCloseBox = [System.Windows.Forms.CheckBox]::new()
$autoCloseBox.Location = [System.Drawing.Point]::new(510, 28)
$autoCloseBox.Size = [System.Drawing.Size]::new(150, 24)
$autoCloseBox.Text = "成功后自动关闭"
$autoCloseBox.Checked = [bool]$settings.AutoCloseOnSuccess
$loginGroup.Controls.Add($autoCloseBox)

$autoConnectBox = [System.Windows.Forms.CheckBox]::new()
$autoConnectBox.Location = [System.Drawing.Point]::new(510, 60)
$autoConnectBox.Size = [System.Drawing.Size]::new(180, 24)
$autoConnectBox.Text = "登录后自动连接"
$autoConnectBox.Checked = [bool](Get-AutoConnectTask)
$loginGroup.Controls.Add($autoConnectBox)

$pppoeLabel = [System.Windows.Forms.Label]::new()
$pppoeLabel.Location = [System.Drawing.Point]::new(18, 30)
$pppoeLabel.Size = [System.Drawing.Size]::new(90, 24)
$pppoeLabel.Text = "PPPoE 名称"
$advancedGroup.Controls.Add($pppoeLabel)

$script:RasEntryBox = [System.Windows.Forms.TextBox]::new()
$script:RasEntryBox.Location = [System.Drawing.Point]::new(108, 27)
$script:RasEntryBox.Size = [System.Drawing.Size]::new(250, 24)
$script:RasEntryBox.Text = $settings.RasEntry
$advancedGroup.Controls.Add($script:RasEntryBox)

$proxyLabel = [System.Windows.Forms.Label]::new()
$proxyLabel.Location = [System.Drawing.Point]::new(18, 62)
$proxyLabel.Size = [System.Drawing.Size]::new(90, 24)
$proxyLabel.Text = "代理地址"
$advancedGroup.Controls.Add($proxyLabel)

$script:ProxyUrlBox = [System.Windows.Forms.TextBox]::new()
$script:ProxyUrlBox.Location = [System.Drawing.Point]::new(108, 59)
$script:ProxyUrlBox.Size = [System.Drawing.Size]::new(250, 24)
$script:ProxyUrlBox.Text = $settings.ProxyUrl
$advancedGroup.Controls.Add($script:ProxyUrlBox)

$tunLabel = [System.Windows.Forms.Label]::new()
$tunLabel.Location = [System.Drawing.Point]::new(378, 30)
$tunLabel.Size = [System.Drawing.Size]::new(90, 24)
$tunLabel.Text = "TUN 网卡"
$advancedGroup.Controls.Add($tunLabel)

$script:TunAliasBox = [System.Windows.Forms.TextBox]::new()
$script:TunAliasBox.Location = [System.Drawing.Point]::new(468, 27)
$script:TunAliasBox.Size = [System.Drawing.Size]::new(200, 24)
$script:TunAliasBox.Text = $settings.TunInterfaceAlias
$advancedGroup.Controls.Add($script:TunAliasBox)

$clashPathLabel = [System.Windows.Forms.Label]::new()
$clashPathLabel.Location = [System.Drawing.Point]::new(18, 94)
$clashPathLabel.Size = [System.Drawing.Size]::new(90, 24)
$clashPathLabel.Text = "Clash 路径"
$advancedGroup.Controls.Add($clashPathLabel)

$script:ClashPathBox = [System.Windows.Forms.TextBox]::new()
$script:ClashPathBox.Location = [System.Drawing.Point]::new(108, 91)
$script:ClashPathBox.Size = [System.Drawing.Size]::new(468, 24)
$script:ClashPathBox.Text = $settings.ClashPath
$advancedGroup.Controls.Add($script:ClashPathBox)

$browseButton = [System.Windows.Forms.Button]::new()
$browseButton.Location = [System.Drawing.Point]::new(588, 89)
$browseButton.Size = [System.Drawing.Size]::new(80, 28)
$browseButton.Text = "浏览"
$advancedGroup.Controls.Add($browseButton)

$refreshButton = [System.Windows.Forms.Button]::new()
$refreshButton.Location = [System.Drawing.Point]::new(20, 350)
$refreshButton.Size = [System.Drawing.Size]::new(90, 36)
$refreshButton.Text = "刷新状态"
$form.Controls.Add($refreshButton)

$connectButton = [System.Windows.Forms.Button]::new()
$connectButton.Location = [System.Drawing.Point]::new(128, 350)
$connectButton.Size = [System.Drawing.Size]::new(220, 36)
$connectButton.Text = "修复 PPPoE + Clash"
$connectButton.BackColor = [System.Drawing.SystemColors]::Highlight
$connectButton.ForeColor = [System.Drawing.Color]::White
$connectButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$connectButton.UseVisualStyleBackColor = $false
$form.Controls.Add($connectButton)

$pppoeOnlyButton = [System.Windows.Forms.Button]::new()
$pppoeOnlyButton.Location = [System.Drawing.Point]::new(362, 350)
$pppoeOnlyButton.Size = [System.Drawing.Size]::new(180, 36)
$pppoeOnlyButton.Text = "仅拨号有线 PPPoE"
$form.Controls.Add($pppoeOnlyButton)

$restoreButton = [System.Windows.Forms.Button]::new()
$restoreButton.Location = [System.Drawing.Point]::new(556, 350)
$restoreButton.Size = [System.Drawing.Size]::new(164, 36)
$restoreButton.Text = "一键切回 WLAN"
$form.Controls.Add($restoreButton)

$outputBox = [System.Windows.Forms.TextBox]::new()
$outputBox.Location = [System.Drawing.Point]::new(20, 404)
$outputBox.Size = [System.Drawing.Size]::new(700, 208)
$outputBox.Multiline = $true
$outputBox.ScrollBars = "Vertical"
$outputBox.ReadOnly = $true
$outputBox.WordWrap = $false
$form.Controls.Add($outputBox)

$hintLabel = [System.Windows.Forms.Label]::new()
$hintLabel.Location = [System.Drawing.Point]::new(20, 626)
$hintLabel.Size = [System.Drawing.Size]::new(700, 32)
$hintLabel.Text = "主按钮修复 PPPoE + Clash；仅拨号模式不启动或修改 Clash，不添加 NRPT/split route。"
$form.Controls.Add($hintLabel)

$script:CurrentJob = $null
$script:CurrentAction = ""
$script:CloseAfterSuccess = $false
$script:SuccessSeenAt = $null
$script:LastJobOutputText = ""
$script:SuppressAutoConnectChange = $false

function Set-ControlsBusy {
    param([bool]$Busy)
    foreach ($control in @($connectButton, $pppoeOnlyButton, $restoreButton, $refreshButton, $browseButton, $accountBox, $passwordBox, $rememberAccountBox, $rememberPasswordBox, $autoCloseBox, $autoConnectBox, $script:RasEntryBox, $script:ProxyUrlBox, $script:TunAliasBox, $script:ClashPathBox)) {
        $control.Enabled = -not $Busy
    }
}

function Append-Output {
    param([string]$Text)
    if (-not [string]::IsNullOrWhiteSpace($Text)) {
        $outputBox.AppendText($Text.TrimEnd() + [Environment]::NewLine)
    }
}

function Set-AutoConnectChecked {
    param([bool]$Checked)
    $script:SuppressAutoConnectChange = $true
    try {
        $autoConnectBox.Checked = $Checked
    }
    finally {
        $script:SuppressAutoConnectChange = $false
    }
}

function Save-CurrentUiSettings {
    if ([string]::IsNullOrEmpty($passwordBox.Text)) {
        $securePassword = [securestring]::new()
    }
    else {
        $securePassword = ConvertTo-SecureString $passwordBox.Text -AsPlainText -Force
    }

    $cfg = Get-UiConfig
    Save-AppSettings -Account $accountBox.Text.Trim() -Password $securePassword -RememberAccount $rememberAccountBox.Checked -RememberPassword $rememberPasswordBox.Checked -AutoCloseOnSuccess $autoCloseBox.Checked -AutoConnectOnLogon $autoConnectBox.Checked -RasEntryValue $cfg.RasEntry -ProxyUrlValue $cfg.ProxyUrl -TunInterfaceAliasValue $cfg.TunInterfaceAlias -TunIpv4GatewayValue $cfg.TunIpv4Gateway -TunIpv6GatewayValue $cfg.TunIpv6Gateway -ClashPathValue $cfg.ClashPath
    $script:CurrentConfig = Resolve-HitNetClashConfig -ScriptDir $ScriptDir -SettingsPath $SettingsPath -RasEntry $cfg.RasEntry -ProxyUrl $cfg.ProxyUrl -TunInterfaceAlias $cfg.TunInterfaceAlias -TunIpv4Gateway $cfg.TunIpv4Gateway -TunIpv6Gateway $cfg.TunIpv6Gateway -ClashPath $cfg.ClashPath
}

function Start-BackendJob {
    param(
        [ValidateSet("connect", "pppoeOnly", "restore")]
        [string]$Action,
        [pscredential]$Credential
    )

    Save-CurrentUiSettings
    $cfg = Get-UiConfig
    Set-ControlsBusy -Busy $true
    $script:CurrentAction = $Action
    $script:CloseAfterSuccess = $false
    $script:SuccessSeenAt = $null
    $script:LastJobOutputText = ""
    $actionTitle = switch ($Action) {
        "connect" { "修复 PPPoE + Clash" }
        "pppoeOnly" { "仅拨号有线 PPPoE" }
        "restore" { "切换回 WLAN" }
    }
    $scriptPath = switch ($Action) {
        "connect" { $EnterScript }
        "pppoeOnly" { $PppoeOnlyScript }
        "restore" { $RestoreScript }
    }
    $statusLabel.Text = switch ($Action) {
        "connect" { "正在修复 PPPoE + Clash..." }
        "pppoeOnly" { "正在仅拨号连接有线 PPPoE..." }
        "restore" { "正在切换回 WLAN..." }
    }
    $outputBox.Clear()
    Append-Output ("=== {0} {1} ===" -f $actionTitle, (Get-Date -Format "yyyy-MM-dd HH:mm:ss"))
    Append-Output ("脚本: {0}" -f $scriptPath)
    Append-Output ("日志目录: {0}" -f $RuntimeLogDir)
    if ($Action -eq "pppoeOnly") {
        Append-Output ("PPPoE={0}" -f $cfg.RasEntry)
        Append-Output "仅拨号模式不会启动/关闭 Clash，不会添加或删除 NRPT、split route、DNS、MTU。"
    }
    else {
        Append-Output ("PPPoE={0} Proxy={1} TUN={2} ClashPath={3}" -f $cfg.RasEntry, $cfg.ProxyUrl, $cfg.TunInterfaceAlias, $cfg.ClashPath)
    }

    if ($Action -eq "connect") {
        $script:CurrentJob = Start-Job -ArgumentList $EnterScript, $cfg.RasEntry, $cfg.ProxyUrl, $cfg.TunInterfaceAlias, $cfg.TunIpv4Gateway, $cfg.TunIpv6Gateway, $cfg.ClashPath, $SettingsPath, $Credential -ScriptBlock {
            param($scriptPath, $ras, $proxy, $tun, $tunV4, $tunV6, $clash, $settings, $cred)
            & $scriptPath -RasEntry $ras -ProxyUrl $proxy -TunInterfaceAlias $tun -TunIpv4Gateway $tunV4 -TunIpv6Gateway $tunV6 -ClashPath $clash -SettingsPath $settings -Credential $cred -ProbeMode Balanced 2>&1 | ForEach-Object { $_.ToString() }
        }
    }
    elseif ($Action -eq "pppoeOnly") {
        $script:CurrentJob = Start-Job -ArgumentList $PppoeOnlyScript, $cfg.RasEntry, $SettingsPath, $Credential -ScriptBlock {
            param($scriptPath, $ras, $settings, $cred)
            & $scriptPath -RasEntry $ras -SettingsPath $settings -Credential $cred 2>&1 | ForEach-Object { $_.ToString() }
        }
    }
    else {
        $script:CurrentJob = Start-Job -ArgumentList $RestoreScript, $cfg.RasEntry, $cfg.ProxyUrl, $cfg.TunInterfaceAlias, $cfg.TunIpv4Gateway, $cfg.TunIpv6Gateway, $SettingsPath -ScriptBlock {
            param($scriptPath, $ras, $proxy, $tun, $tunV4, $tunV6, $settings)
            & $scriptPath -RasEntry $ras -ProxyUrl $proxy -TunInterfaceAlias $tun -TunIpv4Gateway $tunV4 -TunIpv6Gateway $tunV6 -SettingsPath $settings -ProbeMode Balanced -Reason "ui restore" 2>&1 | ForEach-Object { $_.ToString() }
        }
    }
}

$browseButton.Add_Click({
    $dialog = [System.Windows.Forms.OpenFileDialog]::new()
    $dialog.Title = "选择 clash-verge.exe"
    $dialog.Filter = "Executable (*.exe)|*.exe|All files (*.*)|*.*"
    if (-not [string]::IsNullOrWhiteSpace($script:ClashPathBox.Text)) {
        $parent = Split-Path -Parent $script:ClashPathBox.Text
        if (Test-Path -LiteralPath $parent) {
            $dialog.InitialDirectory = $parent
        }
    }
    if ($dialog.ShowDialog() -eq "OK") {
        $script:ClashPathBox.Text = $dialog.FileName
    }
})

$autoConnectBox.Add_CheckedChanged({
    if ($script:SuppressAutoConnectChange) {
        return
    }

    try {
        if ($autoConnectBox.Checked) {
            if (-not $rememberAccountBox.Checked -or -not $rememberPasswordBox.Checked) {
                throw "请先勾选'记住账号'和'记住密码'。"
            }
            if ([string]::IsNullOrWhiteSpace($accountBox.Text) -or [string]::IsNullOrWhiteSpace($passwordBox.Text)) {
                throw "请先填写校园网账号和密码。"
            }
            if ([string]::IsNullOrWhiteSpace($script:RasEntryBox.Text) -or [string]::IsNullOrWhiteSpace($script:ProxyUrlBox.Text) -or [string]::IsNullOrWhiteSpace($script:TunAliasBox.Text)) {
                throw "请先填写 PPPoE 名称、代理地址和 TUN 网卡名。"
            }

            Save-CurrentUiSettings
            $validateOutput = (& $AutoConnectScript -SettingsPath $SettingsPath -ValidateOnly 2>&1 | Out-String -Width 4096).Trim()
            if ($validateOutput -notmatch "AUTO_CONNECT_VALIDATE_OK") {
                throw ("自动连接验证失败。{0}" -f $validateOutput)
            }

            Register-AutoConnectTask
            Save-CurrentUiSettings
            Append-Output "已启用登录后自动连接。任务将在当前 Windows 用户登录后延迟约 30 秒运行。"
        }
        else {
            Unregister-AutoConnectTask
            Save-CurrentUiSettings
            Append-Output "已关闭登录后自动连接。"
        }
        $statusLabel.Text = Get-StateSummary
    }
    catch {
        $message = $_.Exception.Message
        Append-Output ("登录后自动连接设置失败: {0}" -f $message)
        [System.Windows.Forms.MessageBox]::Show($message, "登录后自动连接", "OK", "Warning") | Out-Null
        Set-AutoConnectChecked -Checked ([bool](Get-AutoConnectTask))
        Save-CurrentUiSettings
        $statusLabel.Text = Get-StateSummary
    }
})

$refreshButton.Add_Click({
    Save-CurrentUiSettings
    $statusLabel.Text = Get-StateSummary
    Append-Output (Get-DetailedStatusText -Label "刷新状态")
})

$connectButton.Add_Click({
    if ([string]::IsNullOrWhiteSpace($accountBox.Text)) {
        [System.Windows.Forms.MessageBox]::Show("请输入校园网账号。", "缺少账号", "OK", "Warning") | Out-Null
        return
    }
    if ([string]::IsNullOrWhiteSpace($passwordBox.Text)) {
        [System.Windows.Forms.MessageBox]::Show("请输入校园网密码。", "缺少密码", "OK", "Warning") | Out-Null
        return
    }
    if ([string]::IsNullOrWhiteSpace($script:RasEntryBox.Text) -or [string]::IsNullOrWhiteSpace($script:ProxyUrlBox.Text) -or [string]::IsNullOrWhiteSpace($script:TunAliasBox.Text)) {
        [System.Windows.Forms.MessageBox]::Show("请填写 PPPoE 名称、代理地址和 TUN 网卡名。", "缺少配置", "OK", "Warning") | Out-Null
        return
    }

    $securePassword = ConvertTo-SecureString $passwordBox.Text -AsPlainText -Force
    $credential = [pscredential]::new($accountBox.Text.Trim(), $securePassword)
    Start-BackendJob -Action "connect" -Credential $credential
})

$pppoeOnlyButton.Add_Click({
    if ([string]::IsNullOrWhiteSpace($accountBox.Text)) {
        [System.Windows.Forms.MessageBox]::Show("请输入校园网账号。", "缺少账号", "OK", "Warning") | Out-Null
        return
    }
    if ([string]::IsNullOrWhiteSpace($passwordBox.Text)) {
        [System.Windows.Forms.MessageBox]::Show("请输入校园网密码。", "缺少密码", "OK", "Warning") | Out-Null
        return
    }
    if ([string]::IsNullOrWhiteSpace($script:RasEntryBox.Text)) {
        [System.Windows.Forms.MessageBox]::Show("请填写 PPPoE 名称。", "缺少配置", "OK", "Warning") | Out-Null
        return
    }

    $confirm = [System.Windows.Forms.MessageBox]::Show(
        "仅拨号模式不会启动、关闭或配置 Clash，也不会添加或删除 NRPT/split route。若 Clash TUN 已开启，系统流量仍可能经过 Clash。是否继续只拨号？",
        "仅拨号有线 PPPoE",
        "OKCancel",
        "Information"
    )
    if ($confirm -ne "OK") {
        return
    }

    $securePassword = ConvertTo-SecureString $passwordBox.Text -AsPlainText -Force
    $credential = [pscredential]::new($accountBox.Text.Trim(), $securePassword)
    Start-BackendJob -Action "pppoeOnly" -Credential $credential
})

$restoreButton.Add_Click({
    Start-BackendJob -Action "restore"
})

$timer = [System.Windows.Forms.Timer]::new()
$timer.Interval = 700
$timer.Add_Tick({
    if ($null -ne $script:CurrentJob) {
        $currentOutput = Receive-Job -Job $script:CurrentJob -Keep -ErrorAction SilentlyContinue | Out-String -Width 4096
        if ($currentOutput.Length -gt $script:LastJobOutputText.Length -and $currentOutput.StartsWith($script:LastJobOutputText)) {
            $newOutput = $currentOutput.Substring($script:LastJobOutputText.Length)
            Append-Output $newOutput
            $script:LastJobOutputText = $currentOutput
        }
        elseif ($currentOutput -ne $script:LastJobOutputText) {
            Append-Output $currentOutput
            $script:LastJobOutputText = $currentOutput
        }

        if ($script:CurrentJob.State -in @("Completed", "Failed", "Stopped")) {
            $output = Receive-Job -Job $script:CurrentJob -Keep -ErrorAction SilentlyContinue | Out-String -Width 4096
            $state = $script:CurrentJob.State
            Remove-Job -Job $script:CurrentJob -Force -ErrorAction SilentlyContinue
            $script:CurrentJob = $null

            $successToken = switch ($script:CurrentAction) {
                "connect" { "ENTER_PPPOE_CODEX_OK" }
                "pppoeOnly" { "PPPOE_ONLY_OK" }
                "restore" { "RESTORE_WLAN_CLASH_DONE" }
            }
            $success = ($state -eq "Completed" -and $output -match [regex]::Escape($successToken))
            if ($success) {
                Append-Output (Get-DetailedStatusText -Label "操作完成后状态")
                if ($autoCloseBox.Checked) {
                    $statusLabel.Text = switch ($script:CurrentAction) {
                        "connect" { "连接成功，窗口即将关闭。" }
                        "pppoeOnly" { "仅 PPPoE 拨号成功，窗口即将关闭。" }
                        "restore" { "已切换回 WLAN，窗口即将关闭。" }
                    }
                    $script:CloseAfterSuccess = $true
                    $script:SuccessSeenAt = Get-Date
                }
                else {
                    $statusLabel.Text = Get-StateSummary
                    Append-Output "操作成功。窗口保持打开。"
                    Set-ControlsBusy -Busy $false
                }
            }
            else {
                $statusLabel.Text = "操作失败。请查看输出，必要时点击一键切换回 WLAN。"
                Append-Output "操作失败。请检查上方输出和 .runtime/logs 中的日志。"
                Set-ControlsBusy -Busy $false
            }
        }
        else {
            $statusLabel.Text = switch ($script:CurrentAction) {
                "connect" { "正在修复 PPPoE + Clash..." }
                "pppoeOnly" { "正在仅拨号连接有线 PPPoE..." }
                "restore" { "正在切换回 WLAN..." }
            }
        }
    }
    elseif ($script:CloseAfterSuccess -and $null -ne $script:SuccessSeenAt) {
        if (((Get-Date) - $script:SuccessSeenAt).TotalSeconds -ge 2) {
            $timer.Stop()
            $form.Close()
        }
    }
})
$timer.Start()

$form.Add_FormClosing({
    if ($null -ne $script:CurrentJob -and $script:CurrentJob.State -eq "Running") {
        $answer = [System.Windows.Forms.MessageBox]::Show("操作仍在执行，确定要关闭窗口吗？", "确认关闭", "YesNo", "Warning")
        if ($answer -ne "Yes") {
            $_.Cancel = $true
            return
        }
    }
})

[void]$form.ShowDialog()
