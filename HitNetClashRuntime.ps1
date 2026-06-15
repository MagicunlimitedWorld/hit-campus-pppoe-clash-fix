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

function Get-HitNetPlainPasswordFromCredential {
    param([pscredential]$Credential)

    if (-not $Credential) {
        throw "Credential is required."
    }

    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Credential.Password)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

function Test-HitNetRasConnected {
    param([Parameter(Mandatory = $true)][string]$EntryName)

    try {
        $status = (& rasdial.exe 2>&1 | Out-String)
        return ($status -match [regex]::Escape($EntryName))
    }
    catch {
        return $false
    }
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
    $routeTable = @(Get-NetRoute -DestinationPrefix ($expected.Prefix) -ErrorAction SilentlyContinue |
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
    $routeTable = @(Get-NetRoute -DestinationPrefix ($expected.Prefix) -ErrorAction SilentlyContinue |
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
    param(
        [Parameter(Mandatory = $true)][string]$TunInterfaceAlias,
        [Parameter(Mandatory = $true)][string]$TunIpv4Gateway,
        [Parameter(Mandatory = $true)][string]$TunIpv6Gateway
    )

    foreach ($route in Get-HitNetExpectedSplitRoutes -TunIpv4Gateway $TunIpv4Gateway -TunIpv6Gateway $TunIpv6Gateway) {
        Get-NetRoute -DestinationPrefix $route.Prefix -InterfaceAlias $TunInterfaceAlias -NextHop $route.NextHop -ErrorAction SilentlyContinue |
            ForEach-Object {
                "Removing $($route.AddressFamily) split route: $($_.DestinationPrefix) via $($_.NextHop)"
                $_ | Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
            }
    }
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
    param([string]$RasOutput)

    if ($RasOutput -match "(?i)(error|\u9519\u8BEF)\s*629| 629 ") {
        return "RAS_ERROR_629: remote side terminated PPPoE during authentication/registration. Common causes: wrong password, campus account/session restriction, PPPoE server/port/VLAN rejecting the session, or retrying too soon after a previous session."
    }
    if ($RasOutput -match "(?i)(error|\u9519\u8BEF)\s*691| 691 ") {
        return "RAS_ERROR_691: authentication failed. Re-enter the campus account password carefully."
    }
    if ($RasOutput -match "(?i)(error|\u9519\u8BEF)\s*651| 651 ") {
        return "RAS_ERROR_651: PPPoE server or physical link did not respond. Check Ethernet link, wall port, VLAN, and campus PPPoE availability."
    }
    if ($RasOutput -match "(?i)(error|\u9519\u8BEF)\s*633| 633 ") {
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

function Get-HitNetScheduledTaskSnapshot {
    param([Parameter(Mandatory = $true)][string]$TaskName)

    try {
        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $task) {
            return [pscustomobject]@{
                Enabled = $false
                Text = "Auto-connect on logon: disabled"
                ActionText = "(not registered)"
            }
        }

        $text = "Auto-connect on logon: enabled State=$($task.State)"
        try {
            $info = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction Stop
            $text = "Auto-connect on logon: enabled State=$($task.State) LastRun=$($info.LastRunTime) LastResult=$($info.LastTaskResult)"
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
            Text = "Auto-connect on logon: not checked"
            ActionText = "(task query failed: $($_.Exception.Message))"
        }
    }
}
