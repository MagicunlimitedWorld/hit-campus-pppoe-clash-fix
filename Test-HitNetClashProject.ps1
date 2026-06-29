param(
    [switch]$IncludeBusyLockCheck
)

$ErrorActionPreference = "Stop"

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$PSHOMEValue = $PSHOME
$PowerShellExe = Join-Path $PSHOMEValue "powershell.exe"
if (-not (Test-Path -LiteralPath $PowerShellExe)) {
    if ($PSHOMEValue -match "WindowsApps") {
        # PSHOME from modern packaged PowerShell can point to unavailable path on some hosts.
        $PowerShellExe = (Get-Command powershell.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source)
        if (-not $PowerShellExe) {
            $PowerShellExe = (Get-Command pwsh.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source)
        }
    }
}
if (-not $PowerShellExe -or -not (Test-Path -LiteralPath $PowerShellExe)) {
    $PowerShellExe = (Get-Command powershell.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source)
}
if (-not $PowerShellExe -or -not (Test-Path -LiteralPath $PowerShellExe)) {
    throw "Cannot resolve a working PowerShell executable in PATH."
}
$RuntimeScript = Join-Path $ScriptDir "HitNetClashRuntime.ps1"
if (-not (Test-Path -LiteralPath $RuntimeScript)) {
    throw "Runtime helper not found: $RuntimeScript"
}
. $RuntimeScript

function Write-Check {
    param([string]$Message)
    Write-Host ("[hitnet-test] {0}" -f $Message)
}

function Invoke-Check {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Script
    )

    Write-Check ("START {0}" -f $Name)
    & $Script
    Write-Check ("OK {0}" -f $Name)
}

function New-TempRasPhoneBook {
    param([string]$Path)

    $content = @'
[HITnet]
Type=5
PBVersion=8
DialParamsUID=12345
Guid=TESTGUID

[OfficeNet]
Type=5
PBVersion=8
DialParamsUID=67890
Guid=OFFICEGUID
'@
    Set-Content -Path $Path -Value $content -Encoding UTF8
    return $Path
}

function Invoke-RasEntryParserChecks {
    Write-Check "RasEntry parser checks"

    $tmpRoot = Join-Path $ScriptDir ".runtime\\parser-test"
    if (-not (Test-Path -LiteralPath $tmpRoot)) {
        New-Item -Path $tmpRoot -ItemType Directory -Force | Out-Null
    }

    $pbk = Join-Path $tmpRoot "rasphone.pbk"
    try {
        New-TempRasPhoneBook -Path $pbk | Out-Null

        $entries = Get-HitNetRasEntries -RasPhonePaths @($pbk)
        if (-not (Test-HitNetRasEntryExists -RasEntries $entries -RasEntry "HITnet")) {
            throw "Expected RasEntry HITnet not found."
        }
        if (Test-HitNetRasEntryExists -RasEntries $entries -RasEntry "NotExist") {
            throw "Unexpected RasEntry NotExist was found."
        }

        $summary = Get-HitNetRasEntriesSummary -RasEntries $entries
        if ($summary -notmatch "HITnet|OfficeNet") {
            throw "Ras entry summary missing expected entries."
        }

        $hint = Get-HitNetRasFailureHint -RasOutput "Remote failure: error 623." -RasEntries $entries -RasEntry "NoEntry"
        if (-not ($hint -match "rasphone\.exe -a" -and $hint -match "(?i)NoEntry|not found|not found in rasphone")) {
            throw "Failure hint for 623 is not actionable or missing the candidate entry name."
        }

        Write-Check "Ras entry parser checks passed"
    }
    finally {
        Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Get-ProjectScriptFiles {
    Get-ChildItem -LiteralPath $ScriptDir -Recurse -Filter "*.ps1" -File |
        Where-Object {
            $_.FullName -notmatch "\\\.git\\" -and
            $_.FullName -notmatch "\\\.runtime\\" -and
            $_.FullName -notmatch "\\\.local\\"
        } |
        Sort-Object FullName
}

function New-AutoConnectSelfTestSettings {
    param([string]$RasEntry = "SelfTestRas")

    $settingsDir = Join-Path $ScriptDir ".local"
    if (-not (Test-Path -LiteralPath $settingsDir)) {
        New-Item -Path $settingsDir -ItemType Directory -Force | Out-Null
    }

    $settingsPath = Join-Path $settingsDir "project_selftest.settings.json"
    $secure = ConvertTo-SecureString "selftest-password" -AsPlainText -Force
    $settings = [ordered]@{
        RememberAccount = $true
        Account = "selftest-account"
        RememberPassword = $true
        PasswordProtected = ConvertFrom-SecureString $secure
        AutoCloseOnSuccess = $false
        AutoConnectOnLogon = $false
        RasEntry = $RasEntry
        ProxyUrl = "http://127.0.0.1:18080"
        TunInterfaceAlias = "SelfTestTun"
        TunIpv4Gateway = "198.18.0.2"
        TunIpv6Gateway = "fdfe:dcba:9876::2"
        ClashPath = "C:\SelfTest\clash-verge.exe"
    }
    [pscustomobject]$settings | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $settingsPath -Encoding UTF8
    return $settingsPath
}

function Invoke-ExternalPowerShell {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$RequiredToken
    )

    $output = & $PowerShellExe @Arguments 2>&1 | Out-String -Width 4096
    if ($LASTEXITCODE -ne 0) {
        throw ("PowerShell command failed with exit code {0}: {1}" -f $LASTEXITCODE, $output.Trim())
    }
    if ($output -notmatch [regex]::Escape($RequiredToken)) {
        throw ("Expected token not found: {0}. Output: {1}" -f $RequiredToken, $output.Trim())
    }
}

function Invoke-NativeCapture {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$Script
    )

    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        return (& $Script 2>&1 | Out-String -Width 4096)
    }
    finally {
        $ErrorActionPreference = $oldPreference
    }
}

Push-Location $ScriptDir
try {
    Invoke-Check -Name "PowerShell parser" -Script {
        $failures = New-Object System.Collections.Generic.List[string]
        foreach ($file in Get-ProjectScriptFiles) {
            $tokens = $null
            $errors = $null
            [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors) | Out-Null
            if ($errors -and $errors.Count -gt 0) {
                foreach ($err in $errors) {
                    $failures.Add(("{0}:{1}:{2} {3}" -f $file.FullName, $err.Extent.StartLineNumber, $err.Extent.StartColumnNumber, $err.Message)) | Out-Null
                }
            }
        }
        if ($failures.Count -gt 0) {
            throw ($failures -join [Environment]::NewLine)
        }
    }

    Invoke-Check -Name "UI SelfTest" -Script {
        Invoke-ExternalPowerShell -Arguments @("-NoProfile", "-ExecutionPolicy", "Bypass", "-STA", "-File", (Join-Path $ScriptDir "Start-HitNetClashFix.ps1"), "-SelfTest") -RequiredToken "SELFTEST_OK"
    }

    Invoke-Check -Name "auto-connect ValidateOnly" -Script {
        $testSettings = New-AutoConnectSelfTestSettings
        try {
            $rasEntries = @(Get-HitNetRasEntries)
            if (-not $rasEntries -or $rasEntries.Count -eq 0) {
                Write-Check "SKIP auto-connect ValidateOnly (no rasphone entries detected in this environment)."
            }
            else {
                $testSettings = New-AutoConnectSelfTestSettings -RasEntry ([string]$rasEntries[0])
                Invoke-ExternalPowerShell -Arguments @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $ScriptDir "auto_connect_pppoe_clash.ps1"), "-SettingsPath", $testSettings, "-ValidateOnly") -RequiredToken "AUTO_CONNECT_VALIDATE_OK"
            }
        }
        finally {
            Remove-Item -LiteralPath $testSettings -Force -ErrorAction SilentlyContinue
        }
    }

    Invoke-Check -Name "auto-connect ValidateOnly missing RasEntry" -Script {
        $missingName = "SelfTestNotExist"
        $testSettings = New-AutoConnectSelfTestSettings -RasEntry $missingName
        try {
            $output = Invoke-NativeCapture -Script {
                & $PowerShellExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $ScriptDir "auto_connect_pppoe_clash.ps1") -SettingsPath $testSettings -ValidateOnly
            }
            if ($LASTEXITCODE -eq 0 -or $output -notmatch "RAS_ENTRY_NOT_FOUND") {
                throw ("auto-connect missing RasEntry should fail with RAS_ENTRY_NOT_FOUND. Output: {0}" -f $output.Trim())
            }
        }
        finally {
            Remove-Item -LiteralPath $testSettings -Force -ErrorAction SilentlyContinue
        }
    }

    Invoke-Check -Name "enter missing RasEntry precheck" -Script {
        $enterScript = Join-Path $ScriptDir "enter_pppoe_codex.ps1"
        $output = Invoke-NativeCapture -Script {
            & $PowerShellExe -NoProfile -ExecutionPolicy Bypass -File $enterScript -RasEntry "SelfTestNotExist" -LockWaitSeconds 0 -ProbeMode Minimal
        }
        if ($LASTEXITCODE -eq 0 -or $output -notmatch "RAS_ENTRY_NOT_FOUND") {
            throw ("enter missing RasEntry should fail with RAS_ENTRY_NOT_FOUND. Output: {0}" -f $output.Trim())
        }
        if ($output -match "pre-clean stale Codex|NRPT before enter|routes before enter|RESTORE_WLAN_CLASH") {
            throw ("enter missing RasEntry reached a mutation or restore stage. Output: {0}" -f $output.Trim())
        }
    }

    Invoke-Check -Name "pppoe-only missing RasEntry precheck" -Script {
        $pppoeOnlyScript = Join-Path $ScriptDir "connect_pppoe_only.ps1"
        $output = Invoke-NativeCapture -Script {
            & $PowerShellExe -NoProfile -ExecutionPolicy Bypass -File $pppoeOnlyScript -RasEntry "SelfTestNotExist" -ConnectAttempts 1
        }
        if ($LASTEXITCODE -eq 0 -or $output -notmatch "RAS_ENTRY_NOT_FOUND") {
            throw ("pppoe-only missing RasEntry should fail with RAS_ENTRY_NOT_FOUND. Output: {0}" -f $output.Trim())
        }
        if ($output -match "HIT 校园网账号|Dial PPPoE only attempt") {
            throw ("pppoe-only missing RasEntry reached credential prompt or dial attempt. Output: {0}" -f $output.Trim())
        }
    }

    Invoke-Check -Name "config.example.json parse" -Script {
        Get-Content -LiteralPath (Join-Path $ScriptDir "config.example.json") -Raw -Encoding UTF8 | ConvertFrom-Json | Out-Null
    }

    Invoke-Check -Name "git diff check" -Script {
        $output = Invoke-NativeCapture -Script { git diff --check -- . }
        if ($LASTEXITCODE -ne 0) {
            throw $output.Trim()
        }
    }

    Invoke-Check -Name "tracked and publishable file sensitive scan" -Script {
        $files = New-Object System.Collections.Generic.List[string]
        $tracked = @((Invoke-NativeCapture -Script { git ls-files }) -split [Environment]::NewLine)
        $untracked = @((Invoke-NativeCapture -Script { git ls-files --others --exclude-standard }) -split [Environment]::NewLine)
        foreach ($file in @($tracked + $untracked)) {
            if ([string]::IsNullOrWhiteSpace($file)) {
                continue
            }
            if ($file -match "^(\.local/|\.runtime/|\.git/)") {
                continue
            }
            $full = Join-Path $ScriptDir $file
            if (Test-Path -LiteralPath $full -PathType Leaf) {
                $files.Add($full) | Out-Null
            }
        }

        $patterns = @(
            [pscustomobject]@{ Name = "OpenAI API key"; Regex = "sk-[A-Za-z0-9_-]{20,}" },
            [pscustomobject]@{ Name = "Proxy node URI"; Regex = ("(?i)(vme" + "s" + "s://|vle" + "s" + "s://|tro" + "jan://|hysteria" + "2://|s" + "s://)") },
            [pscustomobject]@{ Name = "DPAPI password blob in JSON"; Regex = '(?i)"PasswordProtected"\s*:\s*"[A-Za-z0-9+/=]{40,}"' }
        )
        $hits = New-Object System.Collections.Generic.List[string]
        foreach ($file in $files) {
            $text = Get-Content -LiteralPath $file -Raw -ErrorAction SilentlyContinue
            foreach ($pattern in $patterns) {
                if ($text -match $pattern.Regex) {
                    $hits.Add(("{0}: {1}" -f $file, $pattern.Name)) | Out-Null
                }
            }
        }
        if ($hits.Count -gt 0) {
            throw ($hits -join [Environment]::NewLine)
        }
        Write-Check ("scanned_files={0}" -f $files.Count)
    }

    Invoke-Check -Name "RasEntry parser" -Script {
        Invoke-RasEntryParserChecks
    }

    if ($IncludeBusyLockCheck) {
        Invoke-Check -Name "enter busy lock" -Script {
            $holder = Start-Job -ScriptBlock {
                $mutex = [System.Threading.Mutex]::new($false, "Local\HitCampusPppoeClashEnter")
                try {
                    $null = $mutex.WaitOne()
                    Start-Sleep -Seconds 12
                }
                finally {
                    try { $mutex.ReleaseMutex() } catch {}
                    $mutex.Dispose()
                }
            }
            try {
                Start-Sleep -Seconds 2
                $enterScript = Join-Path $ScriptDir "enter_pppoe_codex.ps1"
                $output = Invoke-NativeCapture -Script { & $PowerShellExe -NoProfile -ExecutionPolicy Bypass -File $enterScript -LockWaitSeconds 0 -ProbeMode Minimal }
                if ($output -notmatch "ENTER_PPPOE_CODEX_BUSY") {
                    throw ("Expected ENTER_PPPOE_CODEX_BUSY. Output: {0}" -f $output.Trim())
                }
                if ($output -match "pre-clean stale Codex|connect RAS entry|NRPT before enter|routes before enter") {
                    throw ("Busy lock test reached a mutation stage. Output: {0}" -f $output.Trim())
                }
            }
            finally {
                Stop-Job -Job $holder -ErrorAction SilentlyContinue | Out-Null
                Remove-Job -Job $holder -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Write-Check "HITNET_PROJECT_TEST_OK"
}
finally {
    Pop-Location
}
