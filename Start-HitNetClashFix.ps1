param(
    [string]$RasEntry = "HITnet",
    [string]$ProxyUrl = "http://127.0.0.1:7897",
    [string]$SettingsPath,
    [switch]$SelfTest,
    [switch]$NoElevation
)

$ErrorActionPreference = "Stop"

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$EnterScript = Join-Path $ScriptDir "enter_pppoe_codex.ps1"
$RestoreScript = Join-Path $ScriptDir "restore_wlan_clash.ps1"
$RuntimeDir = Join-Path $ScriptDir ".runtime"
$RuntimeLogDir = Join-Path $RuntimeDir "logs"
$RuntimeMarkerDir = Join-Path $RuntimeDir "markers"
$RuntimeStateDir = Join-Path $RuntimeDir "state"
$StatePath = Join-Path $RuntimeStateDir "pppoe_codex_active_state.json"
if ([string]::IsNullOrWhiteSpace($SettingsPath)) {
    $SettingsPath = Join-Path $ScriptDir ".local\settings.json"
}

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
        "-RasEntry", (Quote-Arg $RasEntry),
        "-ProxyUrl", (Quote-Arg $ProxyUrl),
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
    if (-not (Test-Path -LiteralPath $SettingsPath)) {
        return [pscustomobject]@{
            RememberAccount = $false
            Account = ""
            RememberPassword = $false
            PasswordProtected = ""
            AutoCloseOnSuccess = $false
        }
    }
    try {
        $settings = Get-Content -LiteralPath $SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        return [pscustomobject]@{
            RememberAccount = [bool]$settings.RememberAccount
            Account = [string]$settings.Account
            RememberPassword = [bool]$settings.RememberPassword
            PasswordProtected = [string]$settings.PasswordProtected
            AutoCloseOnSuccess = [bool]$settings.AutoCloseOnSuccess
        }
    }
    catch {
        return [pscustomobject]@{
            RememberAccount = $false
            Account = ""
            RememberPassword = $false
            PasswordProtected = ""
            AutoCloseOnSuccess = $false
        }
    }
}

function Save-AppSettings {
    param(
        [string]$Account,
        [securestring]$Password,
        [bool]$RememberAccount,
        [bool]$RememberPassword,
        [bool]$AutoCloseOnSuccess
    )

    $settingsDir = Split-Path -Parent $SettingsPath
    if (-not (Test-Path -LiteralPath $settingsDir)) {
        New-Item -Path $settingsDir -ItemType Directory -Force | Out-Null
    }

    $protectedPassword = ""
    if ($RememberPassword -and $null -ne $Password -and $Password.Length -gt 0) {
        $protectedPassword = ConvertFrom-SecureString $Password
    }

    $settings = [pscustomobject]@{
        RememberAccount = $RememberAccount
        Account = if ($RememberAccount) { $Account } else { "" }
        RememberPassword = $RememberPassword
        PasswordProtected = $protectedPassword
        AutoCloseOnSuccess = $AutoCloseOnSuccess
    }
    $settings | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $SettingsPath -Encoding UTF8
}

function Test-ClashPort {
    try {
        $uri = [Uri]$ProxyUrl
        $connections = Get-NetTCPConnection -LocalAddress "127.0.0.1" -LocalPort $uri.Port -State Listen -ErrorAction SilentlyContinue
        return [bool]$connections
    }
    catch {
        return $false
    }
}

function Get-RasConnected {
    try {
        $status = (& rasdial.exe 2>&1 | Out-String)
        return ($status -match [regex]::Escape($RasEntry))
    }
    catch {
        return $false
    }
}

function Get-StateSummary {
    $rasText = if (Get-RasConnected) { "HITnet: 已连接" } else { "HITnet: 未连接" }
    $clashText = if (Test-ClashPort) { "Clash: 7897 已监听" } else { "Clash: 7897 未监听" }
    $stateText = if (Test-Path -LiteralPath $StatePath) { "状态文件: 存在" } else { "状态文件: 无" }
    return "$rasText    $clashText    $stateText"
}

function Get-DetailedStatusText {
    param([string]$Label = "刷新状态")

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add(("=== {0} {1} ===" -f $Label, (Get-Date -Format "yyyy-MM-dd HH:mm:ss"))) | Out-Null
    $lines.Add((Get-StateSummary)) | Out-Null
    $lines.Add(("状态文件路径: {0}" -f $StatePath)) | Out-Null

    $ras = (& rasdial.exe 2>&1 | Out-String).Trim()
    $lines.Add("--- rasdial ---") | Out-Null
    $lines.Add($(if ([string]::IsNullOrWhiteSpace($ras)) { "(no output)" } else { $ras })) | Out-Null

    $lines.Add("--- Clash listen ---") | Out-Null
    $proc = Get-Process verge-mihomo -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($proc) {
        $listen = Get-NetTCPConnection -OwningProcess $proc.Id -State Listen -ErrorAction SilentlyContinue |
            Select-Object LocalAddress, LocalPort, State |
            Sort-Object LocalPort |
            Out-String -Width 4096
        $lines.Add($listen.Trim()) | Out-Null
    }
    else {
        $lines.Add("verge-mihomo 未运行") | Out-Null
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
    Save-AppSettings -Account "selftest-account" -Password $secure -RememberAccount $true -RememberPassword $true -AutoCloseOnSuccess $true
    $loaded = Get-AppSettings
    $plain = ConvertTo-PlainTextFromProtectedText -ProtectedText $loaded.PasswordProtected
    if (-not $loaded.RememberAccount -or $loaded.Account -ne "selftest-account" -or $plain -ne "selftest-password" -or -not $loaded.AutoCloseOnSuccess) {
        throw "SelfTest settings roundtrip failed."
    }
    $statusText = Get-DetailedStatusText -Label "SelfTest"
    if ([string]::IsNullOrWhiteSpace($statusText) -or $statusText -notmatch "rasdial" -or $statusText -notmatch "Codex split routes") {
        throw "SelfTest detailed status output failed."
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
$form.Text = "HIT 校园网 PPPoE + Clash 修复"
$form.StartPosition = "CenterScreen"
$form.Size = [System.Drawing.Size]::new(680, 520)
$form.MinimumSize = [System.Drawing.Size]::new(680, 520)
$form.Font = [System.Drawing.Font]::new("Microsoft YaHei UI", 9)

$statusLabel = [System.Windows.Forms.Label]::new()
$statusLabel.AutoSize = $false
$statusLabel.Location = [System.Drawing.Point]::new(18, 18)
$statusLabel.Size = [System.Drawing.Size]::new(620, 24)
$statusLabel.Text = Get-StateSummary
$form.Controls.Add($statusLabel)

$accountLabel = [System.Windows.Forms.Label]::new()
$accountLabel.Location = [System.Drawing.Point]::new(20, 60)
$accountLabel.Size = [System.Drawing.Size]::new(90, 24)
$accountLabel.Text = "校园网账号"
$form.Controls.Add($accountLabel)

$accountBox = [System.Windows.Forms.TextBox]::new()
$accountBox.Location = [System.Drawing.Point]::new(118, 57)
$accountBox.Size = [System.Drawing.Size]::new(250, 24)
$accountBox.Text = if ($settings.RememberAccount) { $settings.Account } else { "" }
$form.Controls.Add($accountBox)

$rememberAccountBox = [System.Windows.Forms.CheckBox]::new()
$rememberAccountBox.Location = [System.Drawing.Point]::new(385, 57)
$rememberAccountBox.Size = [System.Drawing.Size]::new(120, 24)
$rememberAccountBox.Text = "记住账号"
$rememberAccountBox.Checked = [bool]$settings.RememberAccount
$form.Controls.Add($rememberAccountBox)

$passwordLabel = [System.Windows.Forms.Label]::new()
$passwordLabel.Location = [System.Drawing.Point]::new(20, 96)
$passwordLabel.Size = [System.Drawing.Size]::new(90, 24)
$passwordLabel.Text = "校园网密码"
$form.Controls.Add($passwordLabel)

$passwordBox = [System.Windows.Forms.TextBox]::new()
$passwordBox.Location = [System.Drawing.Point]::new(118, 93)
$passwordBox.Size = [System.Drawing.Size]::new(250, 24)
$passwordBox.UseSystemPasswordChar = $true
if ($settings.RememberPassword) {
    $passwordBox.Text = ConvertTo-PlainTextFromProtectedText -ProtectedText $settings.PasswordProtected
}
$form.Controls.Add($passwordBox)

$rememberPasswordBox = [System.Windows.Forms.CheckBox]::new()
$rememberPasswordBox.Location = [System.Drawing.Point]::new(385, 93)
$rememberPasswordBox.Size = [System.Drawing.Size]::new(120, 24)
$rememberPasswordBox.Text = "记住密码"
$rememberPasswordBox.Checked = [bool]$settings.RememberPassword
$form.Controls.Add($rememberPasswordBox)

$connectButton = [System.Windows.Forms.Button]::new()
$connectButton.Location = [System.Drawing.Point]::new(118, 136)
$connectButton.Size = [System.Drawing.Size]::new(180, 34)
$connectButton.Text = "连接有线网"
$form.Controls.Add($connectButton)

$restoreButton = [System.Windows.Forms.Button]::new()
$restoreButton.Location = [System.Drawing.Point]::new(315, 136)
$restoreButton.Size = [System.Drawing.Size]::new(180, 34)
$restoreButton.Text = "一键切换回 WLAN"
$form.Controls.Add($restoreButton)

$refreshButton = [System.Windows.Forms.Button]::new()
$refreshButton.Location = [System.Drawing.Point]::new(20, 136)
$refreshButton.Size = [System.Drawing.Size]::new(80, 34)
$refreshButton.Text = "刷新状态"
$form.Controls.Add($refreshButton)

$autoCloseBox = [System.Windows.Forms.CheckBox]::new()
$autoCloseBox.Location = [System.Drawing.Point]::new(515, 141)
$autoCloseBox.Size = [System.Drawing.Size]::new(140, 24)
$autoCloseBox.Text = "成功后自动关闭"
$autoCloseBox.Checked = [bool]$settings.AutoCloseOnSuccess
$form.Controls.Add($autoCloseBox)

$outputBox = [System.Windows.Forms.TextBox]::new()
$outputBox.Location = [System.Drawing.Point]::new(20, 188)
$outputBox.Size = [System.Drawing.Size]::new(630, 250)
$outputBox.Multiline = $true
$outputBox.ScrollBars = "Vertical"
$outputBox.ReadOnly = $true
$outputBox.WordWrap = $false
$form.Controls.Add($outputBox)

$hintLabel = [System.Windows.Forms.Label]::new()
$hintLabel.Location = [System.Drawing.Point]::new(20, 448)
$hintLabel.Size = [System.Drawing.Size]::new(630, 20)
$hintLabel.Text = "默认成功后不关闭窗口；勾选成功后自动关闭才会自动退出。"
$form.Controls.Add($hintLabel)

$script:CurrentJob = $null
$script:CurrentAction = ""
$script:CloseAfterSuccess = $false
$script:SuccessSeenAt = $null
$script:LastJobOutputText = ""

function Set-ControlsBusy {
    param([bool]$Busy)
    $connectButton.Enabled = -not $Busy
    $restoreButton.Enabled = -not $Busy
    $refreshButton.Enabled = -not $Busy
    $accountBox.Enabled = -not $Busy
    $passwordBox.Enabled = -not $Busy
    $rememberAccountBox.Enabled = -not $Busy
    $rememberPasswordBox.Enabled = -not $Busy
    $autoCloseBox.Enabled = -not $Busy
}

function Append-Output {
    param([string]$Text)
    if (-not [string]::IsNullOrWhiteSpace($Text)) {
        $outputBox.AppendText($Text.TrimEnd() + [Environment]::NewLine)
    }
}

function Save-CurrentUiSettings {
    if ([string]::IsNullOrEmpty($passwordBox.Text)) {
        $securePassword = [securestring]::new()
    }
    else {
        $securePassword = ConvertTo-SecureString $passwordBox.Text -AsPlainText -Force
    }
    Save-AppSettings -Account $accountBox.Text.Trim() -Password $securePassword -RememberAccount $rememberAccountBox.Checked -RememberPassword $rememberPasswordBox.Checked -AutoCloseOnSuccess $autoCloseBox.Checked
}

function Start-BackendJob {
    param(
        [ValidateSet("connect", "restore")]
        [string]$Action,
        [pscredential]$Credential
    )

    Set-ControlsBusy -Busy $true
    $script:CurrentAction = $Action
    $script:CloseAfterSuccess = $false
    $script:SuccessSeenAt = $null
    $script:LastJobOutputText = ""
    $statusLabel.Text = if ($Action -eq "connect") { "正在连接有线网..." } else { "正在切换回 WLAN..." }
    $outputBox.Clear()
    Append-Output ("=== {0} {1} ===" -f ($(if ($Action -eq "connect") { "连接有线网" } else { "切换回 WLAN" }), (Get-Date -Format "yyyy-MM-dd HH:mm:ss")))
    Append-Output ("脚本: {0}" -f $(if ($Action -eq "connect") { $EnterScript } else { $RestoreScript }))
    Append-Output ("日志目录: {0}" -f $RuntimeLogDir)

    if ($Action -eq "connect") {
        $script:CurrentJob = Start-Job -ArgumentList $EnterScript, $RasEntry, $ProxyUrl, $Credential -ScriptBlock {
            param($scriptPath, $ras, $proxy, $cred)
            & $scriptPath -RasEntry $ras -ProxyUrl $proxy -Credential $cred 2>&1 | ForEach-Object { $_.ToString() }
        }
    }
    else {
        $script:CurrentJob = Start-Job -ArgumentList $RestoreScript, $RasEntry, $ProxyUrl -ScriptBlock {
            param($scriptPath, $ras, $proxy)
            & $scriptPath -RasEntry $ras -ProxyUrl $proxy -Reason "ui restore" 2>&1 | ForEach-Object { $_.ToString() }
        }
    }
}

$refreshButton.Add_Click({
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

    $securePassword = ConvertTo-SecureString $passwordBox.Text -AsPlainText -Force
    Save-AppSettings -Account $accountBox.Text.Trim() -Password $securePassword -RememberAccount $rememberAccountBox.Checked -RememberPassword $rememberPasswordBox.Checked -AutoCloseOnSuccess $autoCloseBox.Checked
    $credential = [pscredential]::new($accountBox.Text.Trim(), $securePassword)
    Start-BackendJob -Action "connect" -Credential $credential
})

$restoreButton.Add_Click({
    Save-CurrentUiSettings
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

            $successToken = if ($script:CurrentAction -eq "connect") { "ENTER_PPPOE_CODEX_OK" } else { "RESTORE_WLAN_CLASH_DONE" }
            $success = ($state -eq "Completed" -and $output -match [regex]::Escape($successToken))
            if ($success) {
                Append-Output (Get-DetailedStatusText -Label "操作完成后状态")
                if ($autoCloseBox.Checked) {
                    $statusLabel.Text = if ($script:CurrentAction -eq "connect") { "连接成功，窗口即将关闭。" } else { "已切换回 WLAN，窗口即将关闭。" }
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
            $statusLabel.Text = if ($script:CurrentAction -eq "connect") { "正在连接有线网..." } else { "正在切换回 WLAN..." }
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
