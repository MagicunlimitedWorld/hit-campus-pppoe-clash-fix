param(
    [switch]$IncludeBusyLockCheck
)

$ErrorActionPreference = "Stop"

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$PowerShellExe = Join-Path $PSHOME "powershell.exe"

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
        RasEntry = "SelfTestRas"
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
            Invoke-ExternalPowerShell -Arguments @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $ScriptDir "auto_connect_pppoe_clash.ps1"), "-SettingsPath", $testSettings, "-ValidateOnly") -RequiredToken "AUTO_CONNECT_VALIDATE_OK"
        }
        finally {
            Remove-Item -LiteralPath $testSettings -Force -ErrorAction SilentlyContinue
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
