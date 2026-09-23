function Test-HitNetOperationRollbackAllowed {
    param($Journal, $ActiveState)
    if (-not $Journal -or [string]$Journal.OperationId -notmatch '^\d{8}_\d{6}_\d{3}$') { return $false }
    if ($ActiveState) {
        if ([string]$ActiveState.Timestamp -notmatch '^\d{8}_\d{6}_\d{3}$') { return $false }
        if ([string]$ActiveState.Timestamp -ge [string]$Journal.OperationId) { return $false }
    }
    return $true
}

function Test-HitNetRouteIdentity {
    param($Left, $Right)
    return ($Left.DestinationPrefix -eq $Right.DestinationPrefix -and
        [int]$Left.InterfaceIndex -eq [int]$Right.InterfaceIndex -and
        [string]$Left.NextHop -eq [string]$Right.NextHop)
}

function New-HitNetRouteRecord {
    param($Route, [object[]]$PreviousRoutes = @(), [switch]$Created)
    $previous = @($PreviousRoutes | Where-Object { Test-HitNetRouteIdentity $_ $Route } | Select-Object -First 1)
    $ownership = 'Reused'; $store = 'ActiveStore'
    if ($Created) { $ownership = 'Created' }
    elseif ($previous.Count) {
        $ownership = if ($previous[0].Ownership -in @('Created', 'Reused', 'Unknown')) { [string]$previous[0].Ownership } else { 'Unknown' }
        $store = if ($previous[0].PolicyStore -eq 'ActiveStore') { 'ActiveStore' } else { 'Unknown' }
        if ($ownership -eq 'Created' -and $null -ne $Route.RouteMetric -and
            [int]$previous[0].RouteMetric -ne [int]$Route.RouteMetric) { $ownership = 'Unknown' }
    }
    return [pscustomobject]@{
        DestinationPrefix = [string]$Route.DestinationPrefix; InterfaceIndex = [int]$Route.InterfaceIndex
        NextHop = [string]$Route.NextHop; AddressFamily = [string]$Route.AddressFamily
        RouteMetric = if ($null -ne $Route.RouteMetric) { [int]$Route.RouteMetric } else { 0 }
        Ownership = $ownership; PolicyStore = $store
    }
}

function Merge-HitNetRouteRecords {
    param([object[]]$ExpectedRoutes, [object[]]$PreviousRoutes = @(), [object[]]$CreatedRoutes = @())
    foreach ($route in @($ExpectedRoutes)) {
        $created = @($CreatedRoutes | Where-Object { Test-HitNetRouteIdentity $_ $route }).Count -gt 0
        New-HitNetRouteRecord -Route $route -PreviousRoutes $PreviousRoutes -Created:$created
    }
    # Retain provenance for old routes even after a TUN interface change. Unknown entries are never claimed.
    foreach ($old in @($PreviousRoutes)) {
        if ($null -eq $old) { continue }
        if (@($ExpectedRoutes | Where-Object { Test-HitNetRouteIdentity $_ $old }).Count -eq 0) {
            New-HitNetRouteRecord -Route $old -PreviousRoutes @($old)
        }
    }
}

function Get-HitNetNrptRecord {
    param($Rule, [object[]]$PreviousRules = @(), [switch]$Created)
    $previous = @($PreviousRules | Where-Object { $_.Name -eq $Rule.Name } | Select-Object -First 1)
    $owned = $Created -or ($previous.Count -gt 0 -and $previous[0].Ownership -eq 'Created')
    if ($previous.Count -and -not (Test-HitNetNrptIdentity $previous[0] $Rule)) { $owned = $false }
    # Old project rules carry a project-specific marker; route tuples have no equivalent proof.
    if (-not $previous.Count -and (Test-HitNetProjectNrptRule -Rule $Rule)) { $owned = $true }
    [pscustomobject]@{
        Name = [string]$Rule.Name; Namespace = @($Rule.Namespace); NameServers = @($Rule.NameServers)
        Ownership = if ($owned) { 'Created' } else { 'Reused' }
    }
}

function Test-HitNetNrptIdentity {
    param($Left, $Right)
    return ($Left.Name -eq $Right.Name -and
        (@($Left.Namespace | Sort-Object) -join '|') -eq (@($Right.Namespace | Sort-Object) -join '|') -and
        (@($Left.NameServers | Sort-Object) -join '|') -eq (@($Right.NameServers | Sort-Object) -join '|'))
}

function Remove-HitNetOwnedResources {
    param([object[]]$Routes = @(), [object[]]$NrptRules = @())
    $failures = New-Object System.Collections.Generic.List[string]
    foreach ($route in @($Routes)) {
        if ($route.Ownership -ne 'Created' -or $route.PolicyStore -ne 'ActiveStore') { continue }
        try {
            $matches = @(Get-NetRoute -PolicyStore ActiveStore -DestinationPrefix $route.DestinationPrefix -InterfaceIndex ([int]$route.InterfaceIndex) -NextHop $route.NextHop -ErrorAction Stop)
            foreach ($match in $matches) {
                if ($null -ne $route.RouteMetric -and [int]$match.RouteMetric -ne [int]$route.RouteMetric) { throw 'Route metric changed; preserve the route.' }
                Remove-NetRoute -PolicyStore ActiveStore -DestinationPrefix $route.DestinationPrefix -InterfaceIndex ([int]$route.InterfaceIndex) -NextHop $route.NextHop -Confirm:$false -ErrorAction Stop
            }
        }
        catch {
            # An absent route is already clean; provider/permission errors must remain failures.
            if ($_.FullyQualifiedErrorId -notmatch 'CmdletizationQuery_NotFound') { $failures.Add("Route $($route.DestinationPrefix): $($_.Exception.Message)") }
        }
    }
    foreach ($record in @($NrptRules)) {
        if ($record.Ownership -ne 'Created') { continue }
        try {
            $current = @(Get-DnsClientNrptRule -ErrorAction Stop | Where-Object { $_.Name -eq $record.Name })
            foreach ($rule in $current) {
                if (-not (Test-HitNetNrptIdentity $record $rule)) { throw 'NRPT rule changed; preserve the rule.' }
                Remove-DnsClientNrptRule -Name $record.Name -Force -ErrorAction Stop
            }
        }
        catch { $failures.Add("NRPT $($record.Name): $($_.Exception.Message)") }
    }
    if ($failures.Count) { throw ('RESOURCE_CLEANUP_FAILED: ' + ($failures -join '; ')) }
}

function Test-HitNetOwnedResourcesRemoved {
    param([object[]]$Routes = @(), [object[]]$NrptRules = @())
    foreach ($route in @($Routes)) {
        if ($route.Ownership -ne 'Created' -or $route.PolicyStore -ne 'ActiveStore') { continue }
        try {
            if (@(Get-NetRoute -PolicyStore ActiveStore -DestinationPrefix $route.DestinationPrefix -InterfaceIndex ([int]$route.InterfaceIndex) -NextHop $route.NextHop -ErrorAction Stop).Count) { return $false }
        }
        catch { if ($_.FullyQualifiedErrorId -notmatch 'CmdletizationQuery_NotFound') { throw } }
    }
    $ownedNames = @($NrptRules | Where-Object { $_.Ownership -eq 'Created' } | ForEach-Object { $_.Name })
    if ($ownedNames.Count -and @(Get-DnsClientNrptRule -ErrorAction Stop | Where-Object { $_.Name -in $ownedNames }).Count) { return $false }
    return $true
}
