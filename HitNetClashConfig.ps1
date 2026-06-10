$script:HitNetClashFallbackConfig = [pscustomobject]@{
    RasEntry = "HITnet"
    ProxyUrl = "http://127.0.0.1:7897"
    TunInterfaceAlias = "Meta"
    TunIpv4Gateway = "198.18.0.2"
    TunIpv6Gateway = "fdfe:dcba:9876::2"
    ClashProcessName = "clash-verge"
    ClashCoreProcessName = "verge-mihomo"
    ClashExecutableCandidates = @(
        "%LOCALAPPDATA%\Programs\Clash Verge\clash-verge.exe",
        "%LOCALAPPDATA%\Programs\Clash Verge Rev\clash-verge.exe",
        "%PROGRAMFILES%\Clash Verge\clash-verge.exe",
        "%PROGRAMFILES%\Clash Verge Rev\clash-verge.exe",
        "D:\clash verge\clash-verge.exe"
    )
    NrptNamespaces = @(".openai.com", ".chatgpt.com", ".oaistatic.com", ".oaiusercontent.com", ".github.com")
    EthernetNamePatterns = @("Ethernet", "以太网", "Realtek PCIe", "Intel(R) Ethernet")
}

function ConvertTo-HitNetStringArray {
    param(
        $Value,
        [string[]]$DefaultValue = @()
    )

    if ($null -eq $Value) {
        return @($DefaultValue)
    }

    if ($Value -is [array]) {
        $items = $Value
    }
    else {
        $items = @($Value)
    }

    $result = @()
    foreach ($item in $items) {
        $text = [string]$item
        if (-not [string]::IsNullOrWhiteSpace($text)) {
            $result += $text.Trim()
        }
    }

    if ($result.Count -eq 0) {
        return @($DefaultValue)
    }
    return $result
}

function Expand-HitNetPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ""
    }
    return [Environment]::ExpandEnvironmentVariables($Path.Trim())
}

function Get-HitNetJsonObject {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    try {
        return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        return $null
    }
}

function Get-HitNetValue {
    param(
        [string]$Override,
        $Local,
        $Example,
        $Fallback
    )

    if (-not [string]::IsNullOrWhiteSpace($Override)) {
        return $Override.Trim()
    }
    if ($null -ne $Local -and -not [string]::IsNullOrWhiteSpace([string]$Local)) {
        return ([string]$Local).Trim()
    }
    if ($null -ne $Example -and -not [string]::IsNullOrWhiteSpace([string]$Example)) {
        return ([string]$Example).Trim()
    }
    return [string]$Fallback
}

function Find-HitNetClashPath {
    param(
        [string]$PreferredPath,
        [string[]]$CandidatePaths,
        [string]$ProcessName = "clash-verge"
    )

    if (-not [string]::IsNullOrWhiteSpace($PreferredPath)) {
        $expanded = Expand-HitNetPath -Path $PreferredPath
        if (Test-Path -LiteralPath $expanded) {
            return $expanded
        }
        return $expanded
    }

    $proc = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_.Path) } |
        Select-Object -First 1
    if ($proc) {
        return $proc.Path
    }

    foreach ($candidate in $CandidatePaths) {
        $expanded = Expand-HitNetPath -Path $candidate
        if (Test-Path -LiteralPath $expanded) {
            return $expanded
        }
    }

    if ($CandidatePaths.Count -gt 0) {
        return (Expand-HitNetPath -Path $CandidatePaths[0])
    }
    return ""
}

function Resolve-HitNetClashConfig {
    param(
        [string]$ScriptDir,
        [string]$SettingsPath,
        [string]$RasEntry,
        [string]$ProxyUrl,
        [string]$TunInterfaceAlias,
        [string]$TunIpv4Gateway,
        [string]$TunIpv6Gateway,
        [string]$ClashPath
    )

    if ([string]::IsNullOrWhiteSpace($ScriptDir)) {
        $ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
    }
    if ([string]::IsNullOrWhiteSpace($SettingsPath)) {
        $SettingsPath = Join-Path $ScriptDir ".local\settings.json"
    }

    $examplePath = Join-Path $ScriptDir "config.example.json"
    $example = Get-HitNetJsonObject -Path $examplePath
    $local = Get-HitNetJsonObject -Path $SettingsPath
    $fallback = $script:HitNetClashFallbackConfig

    $candidateDefaults = ConvertTo-HitNetStringArray -Value $example.ClashExecutableCandidates -DefaultValue $fallback.ClashExecutableCandidates
    $candidateLocal = ConvertTo-HitNetStringArray -Value $local.ClashExecutableCandidates -DefaultValue @()
    $candidatePaths = @()
    foreach ($item in @($candidateLocal + $candidateDefaults)) {
        if ($candidatePaths -notcontains $item) {
            $candidatePaths += $item
        }
    }

    $clashProcessName = Get-HitNetValue -Override "" -Local $local.ClashProcessName -Example $example.ClashProcessName -Fallback $fallback.ClashProcessName
    $resolvedClashPath = Find-HitNetClashPath -PreferredPath (Get-HitNetValue -Override $ClashPath -Local $local.ClashPath -Example "" -Fallback "") -CandidatePaths $candidatePaths -ProcessName $clashProcessName

    $proxy = Get-HitNetValue -Override $ProxyUrl -Local $local.ProxyUrl -Example $example.ProxyUrl -Fallback $fallback.ProxyUrl
    $proxyUri = $null
    try {
        $proxyUri = [Uri]$proxy
    }
    catch {
        throw "Invalid ProxyUrl: $proxy"
    }

    return [pscustomobject]@{
        RasEntry = Get-HitNetValue -Override $RasEntry -Local $local.RasEntry -Example $example.RasEntry -Fallback $fallback.RasEntry
        ProxyUrl = $proxy
        ProxyHost = $proxyUri.Host
        ProxyPort = $proxyUri.Port
        ProxyServer = "{0}:{1}" -f $proxyUri.Host, $proxyUri.Port
        TunInterfaceAlias = Get-HitNetValue -Override $TunInterfaceAlias -Local $local.TunInterfaceAlias -Example $example.TunInterfaceAlias -Fallback $fallback.TunInterfaceAlias
        TunIpv4Gateway = Get-HitNetValue -Override $TunIpv4Gateway -Local $local.TunIpv4Gateway -Example $example.TunIpv4Gateway -Fallback $fallback.TunIpv4Gateway
        TunIpv6Gateway = Get-HitNetValue -Override $TunIpv6Gateway -Local $local.TunIpv6Gateway -Example $example.TunIpv6Gateway -Fallback $fallback.TunIpv6Gateway
        ClashPath = $resolvedClashPath
        ClashProcessName = $clashProcessName
        ClashCoreProcessName = Get-HitNetValue -Override "" -Local $local.ClashCoreProcessName -Example $example.ClashCoreProcessName -Fallback $fallback.ClashCoreProcessName
        ClashExecutableCandidates = $candidatePaths
        NrptNamespaces = ConvertTo-HitNetStringArray -Value $local.NrptNamespaces -DefaultValue (ConvertTo-HitNetStringArray -Value $example.NrptNamespaces -DefaultValue $fallback.NrptNamespaces)
        EthernetNamePatterns = ConvertTo-HitNetStringArray -Value $local.EthernetNamePatterns -DefaultValue (ConvertTo-HitNetStringArray -Value $example.EthernetNamePatterns -DefaultValue $fallback.EthernetNamePatterns)
        SettingsPath = $SettingsPath
        ExampleConfigPath = $examplePath
    }
}
