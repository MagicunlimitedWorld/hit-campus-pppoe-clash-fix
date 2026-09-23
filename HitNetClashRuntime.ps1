function Initialize-HitNetRasNative {
    if ('HitNet.GuardRas' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Security;
namespace HitNet {
    public static class GuardRas {
        // ras.h uses pack(4), including the Windows 8+ encrypted-password pointer.
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode, Pack = 4)]
        public struct DialParameters {
            public uint Size;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 257)] public string Entry;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 129)] public string Phone;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 129)] public string Callback;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 257)] public string User;
            [MarshalAs(UnmanagedType.ByValArray, SizeConst = 257, ArraySubType = UnmanagedType.U2)] public char[] Password;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 16)] public string Domain;
            public uint SubEntry;
            public UIntPtr CallbackId;
            public uint IfIndex;
            public IntPtr EncryptedPassword;
        }
        [DllImport("rasapi32.dll", CharSet = CharSet.Unicode)]
        private static extern uint RasDialW(IntPtr extensions, string book, ref DialParameters parameters,
            uint notifierType, IntPtr notifier, out IntPtr connection);
        [DllImport("rasapi32.dll", CharSet = CharSet.Unicode)]
        private static extern uint RasGetEntryDialParamsW(string book, ref DialParameters parameters,
            [MarshalAs(UnmanagedType.Bool)] out bool hasPassword);
        [DllImport("rasapi32.dll")]
        public static extern uint RasHangUpW(IntPtr connection);
        private static DialParameters Create(string entry) {
            var p = new DialParameters();
            p.Size = (uint)Marshal.SizeOf(typeof(DialParameters));
            p.Entry = entry; p.Phone = ""; p.Callback = ""; p.User = ""; p.Domain = "";
            p.Password = new char[257];
            return p;
        }
        public static uint ValidatePhonebook(string book, string entry) {
            var p = Create(entry);
            try { bool hasPassword; return RasGetEntryDialParamsW(book, ref p, out hasPassword); }
            finally { if (p.Password != null) Array.Clear(p.Password, 0, p.Password.Length); }
        }
        public static uint Dial(string book, string entry, string user, SecureString password, out IntPtr connection) {
            if (entry.Length > 256 || user.Length > 256 || password.Length > 256)
                throw new ArgumentException("RAS field length exceeded.");
            var p = Create(entry); p.User = user;
            IntPtr plain = Marshal.SecureStringToGlobalAllocUnicode(password);
            connection = IntPtr.Zero;
            try {
                for (int i = 0; i < password.Length; i++) p.Password[i] = (char)Marshal.ReadInt16(plain, i * 2);
                uint error = RasDialW(IntPtr.Zero, book, ref p, 0, IntPtr.Zero, out connection);
                // Only release a failed dial's own reference; never hang up a successful session.
                if (error != 0 && connection != IntPtr.Zero) RasHangUpW(connection);
                return error;
            }
            finally {
                Marshal.ZeroFreeGlobalAllocUnicode(plain);
                Array.Clear(p.Password, 0, p.Password.Length);
            }
        }
    }
}
'@
}

function Get-HitNetRasPhonebook {
    param([string]$RasEntry)
    $paths = @(
        (Join-Path $env:APPDATA 'Microsoft\Network\Connections\Pbk\rasphone.pbk'),
        (Join-Path $env:ProgramData 'Microsoft\Network\Connections\Pbk\rasphone.pbk')
    )
    $found = @(foreach ($path in $paths) {
        if (Test-HitNetRasEntryExists -RasEntries @(Get-HitNetRasEntries -RasPhonePaths @($path)) -RasEntry $RasEntry) { $path }
    })
    if ($found.Count -ne 1) { throw 'GUARD_PHONEBOOK_AMBIGUOUS_OR_MISSING: expected one matching phonebook.' }
    return $found[0]
}


function Write-HitNetLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LogPath,
        [string]$Message = ""
    )

    $parent = Split-Path -Parent $LogPath
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -Path $parent -ItemType Directory -Force | Out-Null
    }

    $line = "{0} {1}" -f (Get-Date -Format "s"), $Message
    $line | Tee-Object -FilePath $LogPath -Append
}

function Invoke-HitNetLogged {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LogPath,
        [Parameter(Mandatory = $true)]
        [string]$Title,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Script,
        [switch]$ContinueOnError
    )

    Write-HitNetLog -LogPath $LogPath -Message ("=== {0} ===" -f $Title)
    try {
        $output = & $Script 2>&1 | Out-String -Width 4096
        if ([string]::IsNullOrWhiteSpace($output)) {
            "(no output)" | Tee-Object -FilePath $LogPath -Append
        }
        else {
            $output.TrimEnd() | Tee-Object -FilePath $LogPath -Append
        }
    }
    catch {
        if ($ContinueOnError) {
            Write-HitNetLog -LogPath $LogPath -Message ("ERROR: {0}" -f $_.Exception.Message)
        }
        else {
            throw
        }
    }
}



function Test-HitNetRasConnected {
    param([Parameter(Mandatory = $true)][string]$EntryName)
    $status = @(& rasdial.exe 2>&1)
    if ($LASTEXITCODE -ne 0) { throw 'RAS_STATUS_UNAVAILABLE: connection state could not be read.' }
    return @($status | Where-Object { $_.ToString().Trim() -eq $EntryName }).Count -gt 0
}

function Get-HitNetRasEntries {
    param([string[]]$RasPhonePaths)

    $candidatePaths = @()
    if ($RasPhonePaths -and $RasPhonePaths.Count -gt 0) {
        foreach ($path in @($RasPhonePaths)) {
            if ([string]::IsNullOrWhiteSpace($path)) {
                continue
            }
            $candidatePaths += [Environment]::ExpandEnvironmentVariables($path.Trim())
        }
    }
    else {
        $candidatePaths += Join-Path $env:APPDATA "Microsoft\Network\Connections\Pbk\rasphone.pbk"
        $candidatePaths += Join-Path $env:ALLUSERSPROFILE "Microsoft\Network\Connections\Pbk\rasphone.pbk"
        $candidatePaths += Join-Path $env:ProgramData "Microsoft\Network\Connections\Pbk\rasphone.pbk"
    }

    $entries = New-Object System.Collections.Generic.List[string]
    foreach ($path in $candidatePaths | Select-Object -Unique) {
        if (-not (Test-Path -LiteralPath $path)) {
            continue
        }

        try {
            $content = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
        }
        catch {
            continue
        }

        $sectionName = ""
        $sectionLines = New-Object System.Collections.Generic.List[string]
        $emitSection = {
            param(
                [string]$Name,
                [System.Collections.Generic.List[string]]$Lines
            )

            if ([string]::IsNullOrWhiteSpace($Name)) {
                return
            }

            if ($Name -match "(?i)^(global|media|connection|modem|authentication|general|phonebook|network|dns)$") {
                return
            }

            $isRasEntry = $false
            foreach ($line in $Lines) {
                if ($line -match "(?i)^(Type|PBVersion|PhoneNumber|DialParamsUID|PreferredDevice)=") {
                    $isRasEntry = $true
                    break
                }
            }
            if (-not $isRasEntry) {
                return
            }

            $trimmed = $Name.Trim()
            if (-not [string]::IsNullOrWhiteSpace($trimmed)) {
                if ($entries -notcontains $trimmed) {
                    $entries.Add($trimmed) | Out-Null
                }
            }
        }

        foreach ($line in ($content -split "`r?`n")) {
            if ($line -match "^\[(.+)\]\s*$") {
                if (-not [string]::IsNullOrWhiteSpace($sectionName)) {
                    & $emitSection -Name $sectionName -Lines $sectionLines
                }
                $sectionName = $Matches[1]
                $sectionLines.Clear()
            }
            else {
                if (-not [string]::IsNullOrWhiteSpace($sectionName)) {
                    $sectionLines.Add($line) | Out-Null
                }
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($sectionName)) {
            & $emitSection -Name $sectionName -Lines $sectionLines
        }
    }

    return ($entries | Sort-Object)
}

function Test-HitNetRasEntryExists {
    param(
        [string[]]$RasEntries,
        [string]$RasEntry
    )

    if ([string]::IsNullOrWhiteSpace($RasEntry) -or -not $RasEntries) {
        return $false
    }
    foreach ($entry in @($RasEntries)) {
        if (-not [string]::IsNullOrWhiteSpace($entry) -and $entry.Trim().Equals($RasEntry.Trim(), [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

function Get-HitNetRasEntriesSummary {
    param(
        [string[]]$RasEntries,
        [int]$MaxEntries = 20
    )

    if (-not $RasEntries -or $RasEntries.Count -eq 0) {
        return "未检测到 RasEntry"
    }

    $shown = @($RasEntries | Select-Object -First $MaxEntries)
    if ($RasEntries.Count -gt $MaxEntries) {
        return ("检测到 {0} 个 RasEntry: {1} ..." -f $RasEntries.Count, ($shown -join ", "))
    }
    return ("检测到 {0} 个 RasEntry: {1}" -f $RasEntries.Count, ($RasEntries -join ", "))
}

function Test-HitNetProxyPortListening {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProxyUrl,
        [int]$TimeoutMilliseconds = 800
    )

    try {
        $uri = [Uri]$ProxyUrl
        $hostName = if ($uri.Host -in @("0.0.0.0", "::", "[::]")) { "127.0.0.1" } else { $uri.Host }
        $client = [System.Net.Sockets.TcpClient]::new()
        try {
            $async = $client.BeginConnect($hostName, $uri.Port, $null, $null)
            if (-not $async.AsyncWaitHandle.WaitOne([Math]::Max(1, $TimeoutMilliseconds), $false)) {
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

function Test-HitNetTunReady {
    param([Parameter(Mandatory = $true)][string]$TunInterfaceAlias)

    try {
        $adapter = Get-NetAdapter -Name $TunInterfaceAlias -ErrorAction SilentlyContinue | Select-Object -First 1
        return ($adapter -and $adapter.Status -eq "Up")
    }
    catch {
        return $false
    }
}

function Test-HitNetEthernetReady {
    param(
        [string[]]$EthernetNamePatterns,
        [string]$TunInterfaceAlias = ""
    )

    foreach ($pattern in @($EthernetNamePatterns)) {
        if ([string]::IsNullOrWhiteSpace([string]$pattern)) {
            continue
        }

        $namePattern = "*$(([string]$pattern).Trim())*"
        $adapter = Get-NetAdapter -Name $namePattern -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Status -eq "Up" -and
                $_.Name -ne $TunInterfaceAlias -and
                $_.Name -notmatch "WLAN|Wi-?Fi|Wireless|Meta|Clash|TUN|Loopback|Bluetooth"
            } |
            Select-Object -First 1
        if ($adapter) {
            return $true
        }
    }
    return $false
}

function Get-HitNetRoutesByPrefix {
    param([Parameter(Mandatory = $true)][string[]]$DestinationPrefix)

    foreach ($prefix in @($DestinationPrefix)) {
        if ([string]::IsNullOrWhiteSpace($prefix)) {
            continue
        }
        Get-NetRoute -DestinationPrefix $prefix -ErrorAction SilentlyContinue
    }
}

function Get-HitNetExpectedSplitRoutes {
    param(
        [Parameter(Mandatory = $true)][string]$TunIpv4Gateway,
        [Parameter(Mandatory = $true)][string]$TunIpv6Gateway
    )

    return @(
        [pscustomobject]@{ Prefix = "0.0.0.0/1"; NextHop = $TunIpv4Gateway; AddressFamily = "IPv4" },
        [pscustomobject]@{ Prefix = "128.0.0.0/1"; NextHop = $TunIpv4Gateway; AddressFamily = "IPv4" },
        [pscustomobject]@{ Prefix = "::/1"; NextHop = $TunIpv6Gateway; AddressFamily = "IPv6" },
        [pscustomobject]@{ Prefix = "8000::/1"; NextHop = $TunIpv6Gateway; AddressFamily = "IPv6" }
    )
}

function Test-HitNetSplitRoutesReady {
    param(
        [Parameter(Mandatory = $true)][string]$TunInterfaceAlias,
        [Parameter(Mandatory = $true)][string]$TunIpv4Gateway,
        [Parameter(Mandatory = $true)][string]$TunIpv6Gateway
    )

    $expected = @(Get-HitNetExpectedSplitRoutes -TunIpv4Gateway $TunIpv4Gateway -TunIpv6Gateway $TunIpv6Gateway)
    $routeTable = @(Get-HitNetRoutesByPrefix -DestinationPrefix @($expected.Prefix) |
        Where-Object { $_.InterfaceAlias -eq $TunInterfaceAlias })

    foreach ($route in $expected) {
        $found = $routeTable |
            Where-Object { $_.DestinationPrefix -eq $route.Prefix -and $_.NextHop -eq $route.NextHop } |
            Select-Object -First 1
        if (-not $found) {
            return $false
        }
    }
    return $true
}

function Test-HitNetSplitRoutesRemoved {
    param(
        [Parameter(Mandatory = $true)][string]$TunInterfaceAlias,
        [Parameter(Mandatory = $true)][string]$TunIpv4Gateway,
        [Parameter(Mandatory = $true)][string]$TunIpv6Gateway
    )

    $expected = @(Get-HitNetExpectedSplitRoutes -TunIpv4Gateway $TunIpv4Gateway -TunIpv6Gateway $TunIpv6Gateway)
    $routeTable = @(Get-HitNetRoutesByPrefix -DestinationPrefix @($expected.Prefix) |
        Where-Object { $_.InterfaceAlias -eq $TunInterfaceAlias })

    foreach ($route in $expected) {
        $found = $routeTable |
            Where-Object { $_.DestinationPrefix -eq $route.Prefix -and $_.NextHop -eq $route.NextHop } |
            Select-Object -First 1
        if ($found) {
            return $false
        }
    }
    return $true
}

function Remove-HitNetSplitRoutes {
    param([string]$TunInterfaceAlias, [string]$TunIpv4Gateway, [string]$TunIpv6Gateway, [object[]]$RecordedRoutes = @())
    # Legacy parameters remain accepted, but tuples alone never establish ownership.
    Remove-HitNetOwnedResources -Routes $RecordedRoutes
}

function Get-HitNetProjectNrptRules {
    Get-DnsClientNrptRule -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Comment -like "CodexClashEnter*" -or
            $_.DisplayName -like "CodexClashEnter*" -or
            $_.Comment -like "CodexClashTrial*" -or
            $_.DisplayName -like "CodexClashTrial*"
        }
}

function Remove-HitNetProjectNrptRules {
    Get-HitNetProjectNrptRules |
        ForEach-Object {
            "Removing NRPT rule: Name=$($_.Name) Namespace=$($_.Namespace -join ',')"
            Remove-DnsClientNrptRule -Name $_.Name -Force -ErrorAction SilentlyContinue
        }
}

function Test-HitNetProjectNrptRemoved {
    $rules = @(Get-HitNetProjectNrptRules)
    return ($rules.Count -eq 0)
}

function Test-HitNetNrptRulesReady {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$NrptNamespaces,
        [string]$NameServer = "198.18.0.2"
    )

    $rules = @(Get-DnsClientNrptRule -ErrorAction SilentlyContinue |
        Where-Object { @($_.NameServers) -contains $NameServer })

    foreach ($namespace in @($NrptNamespaces)) {
        if ([string]::IsNullOrWhiteSpace($namespace)) {
            continue
        }

        $rule = $rules |
            Where-Object { @($_.Namespace) -contains $namespace } |
            Select-Object -First 1
        if (-not $rule) {
            return $false
        }
    }
    return $true
}

function Test-HitNetProjectNrptRule {
    param(
        [Parameter(Mandatory = $true)]
        $Rule,
        [string[]]$RecordedRuleNames = @()
    )

    if ($Rule.Name -and @($RecordedRuleNames) -contains [string]$Rule.Name) {
        return $true
    }

    return (
        [string]$Rule.Comment -like "CodexClashEnter*" -or
        [string]$Rule.DisplayName -like "CodexClashEnter*" -or
        [string]$Rule.Comment -like "CodexClashTrial*" -or
        [string]$Rule.DisplayName -like "CodexClashTrial*"
    )
}

function New-HitNetReconcilePlan {
    param(
        $ActiveState,
        [bool]$RasConnected,
        [bool]$ProxyListening,
        [bool]$TunReady,
        [Parameter(Mandatory = $true)][string]$RasEntry,
        [Parameter(Mandatory = $true)][string]$TunInterfaceAlias,
        [int]$TunInterfaceIndex,
        [Parameter(Mandatory = $true)][string]$TunIpv4Gateway,
        [Parameter(Mandatory = $true)][string]$TunIpv6Gateway,
        [Parameter(Mandatory = $true)][string[]]$NrptNamespaces,
        [object[]]$NrptRules = @(),
        [object[]]$Routes = @(),
        [string]$NameServer = "198.18.0.2"
    )

    $result = [ordered]@{
        Code = ""
        Reason = ""
        NrptNamespacesToAdd = @()
        NrptRuleNames = @()
        RoutesToAdd = @()
        RoutesToRemove = @()
        ExpectedRoutes = @()
        StateNeedsUpdate = $false
    }

    if ($null -eq $ActiveState) {
        $result.Code = "SKIPPED_INACTIVE"
        $result.Reason = "The project active-state file does not exist."
        return [pscustomobject]$result
    }
    if (-not $RasConnected) {
        $result.Code = "SKIPPED_RAS_DISCONNECTED"
        $result.Reason = "The configured PPPoE session is not connected."
        return [pscustomobject]$result
    }
    if (-not $ProxyListening) {
        $result.Code = "BLOCKED_PROXY_UNAVAILABLE"
        $result.Reason = "The configured local proxy port is not listening."
        return [pscustomobject]$result
    }
    if (-not $TunReady) {
        $result.Code = "BLOCKED_TUN_UNAVAILABLE"
        $result.Reason = "The configured Meta/TUN adapter is not Up."
        return [pscustomobject]$result
    }
    if ($TunInterfaceIndex -le 0) {
        $result.Code = "BLOCKED_TUN_INTERFACE_INDEX"
        $result.Reason = "The current Meta/TUN interface index is unavailable."
        return [pscustomobject]$result
    }
    if ([string]::IsNullOrWhiteSpace($TunIpv4Gateway) -or [string]::IsNullOrWhiteSpace($TunIpv6Gateway)) {
        $result.Code = "BLOCKED_TUN_GATEWAY"
        $result.Reason = "The current Meta/TUN gateway is unavailable."
        return [pscustomobject]$result
    }

    $stateRasEntry = [string]$ActiveState.RasEntry
    $stateTunAlias = [string]$ActiveState.TunInterfaceAlias
    if (
        [string]::IsNullOrWhiteSpace($stateRasEntry) -or
        -not $stateRasEntry.Equals($RasEntry, [System.StringComparison]::OrdinalIgnoreCase) -or
        [string]::IsNullOrWhiteSpace($stateTunAlias) -or
        -not $stateTunAlias.Equals($TunInterfaceAlias, [System.StringComparison]::OrdinalIgnoreCase)
    ) {
        $result.Code = "BLOCKED_STATE_MISMATCH"
        $result.Reason = "The active-state PPPoE or TUN binding does not match the current configuration."
        return [pscustomobject]$result
    }

    $expectedRoutes = @(
        [pscustomobject]@{ DestinationPrefix = "0.0.0.0/1"; InterfaceIndex = $TunInterfaceIndex; NextHop = $TunIpv4Gateway; AddressFamily = "IPv4" },
        [pscustomobject]@{ DestinationPrefix = "128.0.0.0/1"; InterfaceIndex = $TunInterfaceIndex; NextHop = $TunIpv4Gateway; AddressFamily = "IPv4" },
        [pscustomobject]@{ DestinationPrefix = "::/1"; InterfaceIndex = $TunInterfaceIndex; NextHop = $TunIpv6Gateway; AddressFamily = "IPv6" },
        [pscustomobject]@{ DestinationPrefix = "8000::/1"; InterfaceIndex = $TunInterfaceIndex; NextHop = $TunIpv6Gateway; AddressFamily = "IPv6" }
    )
    $result.ExpectedRoutes = $expectedRoutes

    $recordedRuleNames = @($ActiveState.NrptRuleNames | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $validRuleNames = New-Object System.Collections.Generic.List[string]
    $namespacesToAdd = New-Object System.Collections.Generic.List[string]
    $conflicts = New-Object System.Collections.Generic.List[string]

    foreach ($namespace in @($NrptNamespaces)) {
        if ([string]::IsNullOrWhiteSpace($namespace)) {
            continue
        }

        $matchingRules = @($NrptRules | Where-Object { @($_.Namespace) -contains $namespace })
        $projectRules = @($matchingRules | Where-Object { Test-HitNetProjectNrptRule -Rule $_ -RecordedRuleNames $recordedRuleNames })
        $foreignRules = @($matchingRules | Where-Object { -not (Test-HitNetProjectNrptRule -Rule $_ -RecordedRuleNames $recordedRuleNames) })
        if (@($foreignRules | Where-Object { @($_.NameServers) -notcontains $NameServer }).Count -gt 0) {
            $conflicts.Add($namespace) | Out-Null
            continue
        }

        $validProjectRules = @($matchingRules | Where-Object { @($_.NameServers) -contains $NameServer })
        if ($validProjectRules.Count -eq 0) {
            if ($projectRules.Count -gt 0) {
                $conflicts.Add($namespace) | Out-Null
            }
            else {
                $namespacesToAdd.Add($namespace) | Out-Null
            }
            continue
        }

        foreach ($rule in $validProjectRules) {
            if ($rule.Name -and $validRuleNames -notcontains [string]$rule.Name) {
                $validRuleNames.Add([string]$rule.Name) | Out-Null
            }
        }
    }

    if ($conflicts.Count -gt 0) {
        $result.Code = "BLOCKED_NRPT_CONFLICT"
        $result.Reason = "A foreign or incompatible NRPT rule exists for: $($conflicts -join ', ')."
        return [pscustomobject]$result
    }

    $result.NrptNamespacesToAdd = @($namespacesToAdd)
    $result.NrptRuleNames = @($validRuleNames)

    $routesToAdd = New-Object System.Collections.Generic.List[object]
    foreach ($expected in $expectedRoutes) {
        $found = $Routes |
            Where-Object {
                $_.DestinationPrefix -eq $expected.DestinationPrefix -and
                [int]$_.InterfaceIndex -eq [int]$expected.InterfaceIndex -and
                [string]$_.NextHop -eq [string]$expected.NextHop
            } |
            Select-Object -First 1
        if (-not $found) {
            $routesToAdd.Add($expected) | Out-Null
        }
    }
    $result.RoutesToAdd = @($routesToAdd | ForEach-Object { $_ })

    $expectedPrefixes = @($expectedRoutes | ForEach-Object { $_.DestinationPrefix })
    $routesToRemove = New-Object System.Collections.Generic.List[object]
    foreach ($recorded in @($ActiveState.Routes)) {
        if ($recorded.Ownership -ne 'Created' -or $recorded.PolicyStore -ne 'ActiveStore') { continue }
        if ($null -eq $recorded -or $expectedPrefixes -notcontains [string]$recorded.DestinationPrefix) {
            continue
        }
        $stillExpected = $expectedRoutes |
            Where-Object {
                $_.DestinationPrefix -eq [string]$recorded.DestinationPrefix -and
                [int]$_.InterfaceIndex -eq [int]$recorded.InterfaceIndex -and
                [string]$_.NextHop -eq [string]$recorded.NextHop
            } |
            Select-Object -First 1
        if ($stillExpected) {
            continue
        }

        $exists = $Routes |
            Where-Object {
                $_.DestinationPrefix -eq [string]$recorded.DestinationPrefix -and
                [int]$_.InterfaceIndex -eq [int]$recorded.InterfaceIndex -and
                [string]$_.NextHop -eq [string]$recorded.NextHop
            } |
            Select-Object -First 1
        if ($exists) {
            $routesToRemove.Add([pscustomobject]@{
                DestinationPrefix = [string]$recorded.DestinationPrefix
                InterfaceIndex = [int]$recorded.InterfaceIndex
                NextHop = [string]$recorded.NextHop
                AddressFamily = [string]$recorded.AddressFamily
                RouteMetric = [int]$recorded.RouteMetric
                Ownership = 'Created'; PolicyStore = 'ActiveStore'
            }) | Out-Null
        }
    }
    $result.RoutesToRemove = @($routesToRemove | ForEach-Object { $_ })

    $expectedRouteKeys = @($expectedRoutes | ForEach-Object { "{0}|{1}|{2}" -f $_.DestinationPrefix, $_.InterfaceIndex, $_.NextHop } | Sort-Object -Unique)
    $stateRouteKeys = @($ActiveState.Routes | Where-Object {
        ("{0}|{1}|{2}" -f $_.DestinationPrefix, $_.InterfaceIndex, $_.NextHop) -in $expectedRouteKeys
    } | ForEach-Object { "{0}|{1}|{2}" -f $_.DestinationPrefix, $_.InterfaceIndex, $_.NextHop } | Sort-Object -Unique)
    $ruleNamesDiffer = @((Compare-Object -ReferenceObject @($recordedRuleNames | Sort-Object -Unique) -DifferenceObject @($validRuleNames | Sort-Object -Unique))).Count -gt 0
    $routeStateDiffers = @((Compare-Object -ReferenceObject $stateRouteKeys -DifferenceObject $expectedRouteKeys)).Count -gt 0
    $result.StateNeedsUpdate = ($ruleNamesDiffer -or $routeStateDiffers -or $namespacesToAdd.Count -gt 0)

    if ($routesToAdd.Count -gt 0 -or $routesToRemove.Count -gt 0 -or $namespacesToAdd.Count -gt 0 -or $result.StateNeedsUpdate) {
        $result.Code = "REPAIR_NEEDED"
        $result.Reason = "One or more project-owned NRPT, split-route, or state entries need reconciliation."
    }
    else {
        $result.Code = "ALREADY_OK"
        $result.Reason = "Project-owned NRPT and split routes already match the current Meta/TUN binding."
    }
    return [pscustomobject]$result
}

function New-HitNetNamedMutexState {
    param([Parameter(Mandatory = $true)][string]$Name)

    return [pscustomobject]@{
        Name = $Name
        Mutex = $null
        Acquired = $false
    }
}

function Acquire-HitNetNamedMutex {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$State,
        [int]$WaitSeconds = 3,
        [string]$LogPath = ""
    )

    $State.Mutex = [System.Threading.Mutex]::new($false, $State.Name)
    $timeoutSeconds = [Math]::Max(0, $WaitSeconds)

    try {
        if ($timeoutSeconds -eq 0) {
            $State.Acquired = $State.Mutex.WaitOne(0)
        }
        else {
            $State.Acquired = $State.Mutex.WaitOne([TimeSpan]::FromSeconds($timeoutSeconds))
        }
    }
    catch [System.Threading.AbandonedMutexException] {
        $State.Acquired = $true
    }

    if (-not $State.Acquired) {
        $State.Mutex.Dispose()
        $State.Mutex = $null
        return $false
    }

    if (-not [string]::IsNullOrWhiteSpace($LogPath)) {
        Write-HitNetLog -LogPath $LogPath -Message ("Enter lock acquired: {0}" -f $State.Name)
    }
    return $true
}

function Release-HitNetNamedMutex {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$State,
        [string]$LogPath = ""
    )

    if (-not $State -or -not $State.Mutex) {
        return
    }

    try {
        if ($State.Acquired) {
            $State.Mutex.ReleaseMutex()
            if (-not [string]::IsNullOrWhiteSpace($LogPath)) {
                Write-HitNetLog -LogPath $LogPath -Message ("Enter lock released: {0}" -f $State.Name)
            }
        }
    }
    catch {
        if (-not [string]::IsNullOrWhiteSpace($LogPath)) {
            Write-HitNetLog -LogPath $LogPath -Message ("Enter lock release warning: {0}" -f $_.Exception.Message)
        }
    }
    finally {
        $State.Mutex.Dispose()
        $State.Mutex = $null
        $State.Acquired = $false
    }
}

function Start-HitNetOpenAiHeadProbe {
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [string]$ProxyUrl = "",
        [switch]$UseProxy,
        [int]$TimeoutSeconds = 8
    )

    Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue

    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $true
    if ($UseProxy) {
        $handler.UseProxy = $true
        $handler.Proxy = [System.Net.WebProxy]::new($ProxyUrl)
    }
    else {
        $handler.UseProxy = $false
    }

    $client = [System.Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds([Math]::Max(1, $TimeoutSeconds))
    $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Head, "https://api.openai.com/v1/models")
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $task = $client.SendAsync($request)

    return [pscustomobject]@{
        Label = $Label
        Client = $client
        Request = $request
        Task = $task
        Stopwatch = $watch
        TimeoutSeconds = [Math]::Max(1, $TimeoutSeconds)
    }
}

function Complete-HitNetOpenAiHeadProbe {
    param([Parameter(Mandatory = $true)][pscustomobject]$Probe)

    try {
        $timeoutMs = [Math]::Max(1, [int]$Probe.TimeoutSeconds) * 1000
        if (-not $Probe.Task.Wait($timeoutMs)) {
            throw "timeout"
        }

        $Probe.Stopwatch.Stop()
        $response = $Probe.Task.Result
        try {
            return [pscustomobject]@{
                Label = $Probe.Label
                Code = [int]$response.StatusCode
                TotalSeconds = $Probe.Stopwatch.Elapsed.TotalSeconds
                Error = ""
            }
        }
        finally {
            $response.Dispose()
        }
    }
    catch {
        $Probe.Stopwatch.Stop()
        $err = $_.Exception
        if ($err.InnerException) {
            $err = $err.InnerException
        }
        return [pscustomobject]@{
            Label = $Probe.Label
            Code = 0
            TotalSeconds = $Probe.Stopwatch.Elapsed.TotalSeconds
            Error = $err.Message
        }
    }
    finally {
        if ($Probe.Request) { $Probe.Request.Dispose() }
        if ($Probe.Client) { $Probe.Client.Dispose() }
    }
}

function Write-HitNetOpenAiProbeResult {
    param(
        [Parameter(Mandatory = $true)][string]$LogPath,
        [Parameter(Mandatory = $true)][pscustomobject]$Result
    )

    Write-HitNetLog -LogPath $LogPath -Message ("=== OpenAI {0} after enter changes ===" -f $Result.Label)
    ("code={0} total={1:n3}s err={2}" -f $Result.Code, $Result.TotalSeconds, $Result.Error) |
        Tee-Object -FilePath $LogPath -Append
}

function Get-HitNetRasFailureHint {
    param(
        [string]$RasOutput,
        [string[]]$RasEntries = @(),
        [string]$RasEntry
    )

    if ($RasOutput -match "(?i)(error).*623") {
        if (Test-HitNetRasEntryExists -RasEntries $RasEntries -RasEntry $RasEntry) {
            return "RAS_ERROR_623: entry exists but PPPoE handshake did not start correctly. Check credentials/account status first, then retry after network/VLAN recovery."
        }
        $summary = Get-HitNetRasEntriesSummary -RasEntries $RasEntries
        return "RAS_ERROR_623: RasEntry '{0}' not found in rasphone.pbk. {1}. Suggested action: run 'rasphone.exe -a' and confirm the exact PPPoE name matches the config." -f $RasEntry, $summary
    }

    if ($RasOutput -match "(?i)(error).*629") {
        return "RAS_ERROR_629: remote side terminated PPPoE during authentication/registration. Common causes: wrong password, campus account/session restriction, PPPoE server/port/VLAN rejecting the session, or retrying too soon after a previous session."
    }
    if ($RasOutput -match "(?i)(error).*691") {
        return "RAS_ERROR_691: authentication failed. Re-enter the campus account password carefully."
    }
    if ($RasOutput -match "(?i)(error).*651") {
        return "RAS_ERROR_651: PPPoE server or physical link did not respond. Check Ethernet link, wall port, VLAN, and campus PPPoE availability."
    }
    if ($RasOutput -match "(?i)(error).*633") {
        return "RAS_ERROR_633: modem/PPPoE device is already in use. Disconnect stale PPPoE sessions and retry."
    }
    return "RAS_ERROR_UNKNOWN: PPPoE did not connect; inspect the preceding rasdial output."
}

function Test-HitNetWorkspacePath {
    param(
        [Parameter(Mandatory = $true)][string]$WorkspacePath,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $workspace = (Resolve-Path -LiteralPath $WorkspacePath).Path
    $full = [System.IO.Path]::GetFullPath($Path)
    return $full.StartsWith($workspace, [System.StringComparison]::OrdinalIgnoreCase)
}

function Write-HitNetJsonAtomic {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$InputObject,
        [int]$Depth = 8
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $parent = Split-Path -Parent $fullPath
    if ([string]::IsNullOrWhiteSpace($parent)) {
        throw "Atomic JSON target must have a parent directory: $fullPath"
    }
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -Path $parent -ItemType Directory -Force | Out-Null
    }

    $nonce = [guid]::NewGuid().ToString("N")
    $tempPath = Join-Path $parent (".{0}.{1}.tmp" -f ([System.IO.Path]::GetFileName($fullPath)), $nonce)
    $backupPath = Join-Path $parent (".{0}.{1}.bak" -f ([System.IO.Path]::GetFileName($fullPath)), $nonce)
    try {
        $json = $InputObject | ConvertTo-Json -Depth $Depth
        $encoding = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::WriteAllText($tempPath, $json, $encoding)
        Get-Content -LiteralPath $tempPath -Raw -Encoding UTF8 | ConvertFrom-Json | Out-Null

        if (Test-Path -LiteralPath $fullPath) {
            [System.IO.File]::Replace($tempPath, $fullPath, $backupPath, $true)
        }
        else {
            [System.IO.File]::Move($tempPath, $fullPath)
        }
    }
    finally {
        if (Test-Path -LiteralPath $tempPath) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $backupPath) {
            Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-HitNetScheduledTaskSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$TaskName,
        [string]$DisplayLabel = "Auto-connect on logon"
    )

    try {
        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $task) {
            return [pscustomobject]@{
                Enabled = $false
                Text = "${DisplayLabel}: disabled"
                ActionText = "(not registered)"
            }
        }

        $text = "${DisplayLabel}: enabled State=$($task.State)"
        try {
            $info = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction Stop
            $text = "${DisplayLabel}: enabled State=$($task.State) LastRun=$($info.LastRunTime) LastResult=$($info.LastTaskResult)"
        }
        catch {
        }

        $actions = @($task.Actions | ForEach-Object { "{0} {1}" -f $_.Execute, $_.Arguments }) -join [Environment]::NewLine
        if ([string]::IsNullOrWhiteSpace($actions)) {
            $actions = "(registered without action text)"
        }

        return [pscustomobject]@{
            Enabled = $true
            Text = $text
            ActionText = $actions
        }
    }
    catch {
        return [pscustomobject]@{
            Enabled = $false
            Text = "${DisplayLabel}: not checked"
            ActionText = "(task query failed: $($_.Exception.Message))"
        }
    }
}

function Invoke-HitNetNativeRasDial {
    param([string]$Phonebook, [string]$RasEntry, [pscredential]$Credential)
    Initialize-HitNetRasNative
    $handle = [IntPtr]::Zero
    $code = [HitNet.GuardRas]::Dial($Phonebook, $RasEntry, $Credential.UserName, $Credential.Password, [ref]$handle)
    [pscustomobject]@{ ErrorCode = $code; ConnectionHandle = $handle }
}

function Invoke-HitNetRasDial {
    param([Parameter(Mandatory = $true)][string]$RasEntry, [Parameter(Mandatory = $true)][pscredential]$Credential)
    if (Test-HitNetRasConnected -EntryName $RasEntry) {
        return [pscustomobject]@{ Created = $false; ConnectionHandle = [IntPtr]::Zero }
    }
    $book = Get-HitNetRasPhonebook -RasEntry $RasEntry
    $result = Invoke-HitNetNativeRasDial -Phonebook $book -RasEntry $RasEntry -Credential $Credential
    if ($result.ErrorCode -ne 0) { throw ('RAS_DIAL_FAILED: RAS error {0}.' -f $result.ErrorCode) }
    # This is our RAS reference. Rollback releases only this handle, never a connection by name.
    [pscustomobject]@{ Created = $true; ConnectionHandle = $result.ConnectionHandle }
}

function Undo-HitNetRasDial {
    param($DialResult)
    if ($DialResult -and $DialResult.Created -and $DialResult.ConnectionHandle -ne [IntPtr]::Zero) {
        Initialize-HitNetRasNative
        $code = [HitNet.GuardRas]::RasHangUpW($DialResult.ConnectionHandle)
        if ($code -ne 0 -and $code -ne 6) { throw "RAS_ROLLBACK_FAILED: RAS error $code." }
    }
}

. (Join-Path $PSScriptRoot 'HitNetClashResources.ps1')
