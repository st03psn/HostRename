<#
.SYNOPSIS
    Network gate for deployments: determines over which path the device is connected to the domain and
    returns that as an exit code.

.DESCRIPTION
    Meant to run before an action of a deployment tool (e.g. ACMP, as SYSTEM). The script checks over which
    path the device currently reaches the domain (wired LAN, DirectAccess, corporate WLAN), compares that with
    the allowed paths (-Allow) and ends with an exit code. It changes nothing on the device. It is a generic
    building block and not tied to HostRename: it can be placed in front of any action (software, certificate
    renewal, domain rejoin).

    DETECTION (language-independent, no parsing of netsh or other localized text)
      Wired LAN       Physical adapter (Get-NetAdapter -Physical) with status Up and physical medium 802.3
                      (NdisPhysicalMedium 14). Docking stations and USB LAN adapters count as wired. Adapters
                      that report the physical medium as "Unspecified" (0) but the media type 802.3 also count
                      as wired: some USB/dock adapters do this, while a WLAN adapter managed by Windows must
                      report Native 802.11 (9). The path counts only if a connection profile of such an adapter
                      is DomainAuthenticated (Get-NetConnectionProfile).
      DirectAccess    Get-DAConnectionStatus reports ConnectedRemotely. If the cmdlet does not exist or fails
                      (no DA client, service not running), DirectAccess counts as not connected.
      WLAN            Connected SSIDs from the WinRT class Windows.Networking.Connectivity.NetworkInformation
                      (GetConnectionProfiles, WlanConnectionProfileDetails.GetConnectedSsid()), including the
                      domain authentication of that profile. If WinRT is not available (e.g. PowerShell 7) or
                      returns no WLAN connection, the connection profile of the wireless adapter is used: its
                      name is usually the SSID, but for a domain network it is the domain name.
                      A WLAN connection counts as corporate WLAN if its SSID is listed in -CorporateSsid
                      (case-insensitive) OR its profile is domain-authenticated. The second rule keeps the
                      detection working when Windows withholds the SSID (location privacy in newer Windows 11
                      builds) or the fallback only returns the domain name.
      Domain          DNS SRV record _ldap._tcp.dc._msdcs.<domain> resolves (Resolve-DnsName) and TCP port 389
                      of at least one of the first three DCs answers within 1.5 s. The connection is opened per
                      resolved address with its own address family, so IPv6-only paths (DirectAccess) work too.
                      All addresses of a DC are tried (IPv6 and IPv4), at most 6 connection attempts in total.

    DECISION (in this order)
      1. Allowed path detected: LAN (if Lan allowed), else DirectAccess (if allowed), else corporate WLAN
         (if Wlan allowed). DC reachable -> 0; DC not reachable -> 21.
      2. Wired LAN or DirectAccess detected but not allowed -> 22.
      3. Only corporate WLAN detected and not allowed: Lan allowed -> 20 (plugging in a cable helps), otherwise
         22. Code 20 does not require a reachable DC: the SSID alone identifies the corporate WLAN, and some
         networks block LDAP from the WLAN segment.
      4. No path detected, but a DC answers (e.g. other VPN, unknown adapter type, NLA not finished) -> 22
         with RESULT=OTHER. The gate does not allow a path it cannot classify.
      5. Nothing detected and no DC reachable -> 21.

    EDGE CASES
      LAN and WLAN at the same time          LAN wins (0 if Lan allowed). If only Wlan is allowed, 0 as WLAN.
      LAN in a foreign network               Wired adapter up, profile not DomainAuthenticated: not a LAN
                                             path. With DA connected -> DA path; otherwise 21 (offline) or
                                             22 (OTHER, if a DC answers anyway).
      LAN up but NLA still identifying       No DomainAuthenticated profile yet: not a LAN path; usually 22
                                             (OTHER) or 21. Retry later.
      DA configured but inactive             Status other than ConnectedRemotely (e.g. ConnectedLocally inside
                                             the company, Error, Connecting): not a DA path; the result
                                             follows from LAN/WLAN.
      WLAN with a non-corporate SSID         Not a corporate WLAN. At home without DA -> 21; with DA -> DA path.
      Corporate WLAN plus foreign cable      20 (if Lan allowed): the cable is not in the domain network.
      Corporate WLAN, Lan not allowed        22 (no point in asking for a cable).
      Domain-authenticated LAN, DC silent    21 (retry later), not 0.
      Hyper-V external switch on the NIC     The profile sits on the virtual adapter, so the LAN is not
                                             recognized (22 OTHER). Not relevant for typical notebooks.

    PASSING LISTS
      With powershell.exe -File, "-Allow Lan,DirectAccess" arrives as ONE string. Both list parameters
      therefore also accept comma-separated values. SSIDs that contain a comma are not supported.

.PARAMETER Allow
    Allowed paths: Lan, DirectAccess, Wlan (default: Lan, DirectAccess). Comma-separated values are accepted.

.PARAMETER CorporateSsid
    SSIDs of the corporate WLAN (EAP-TLS). Comma-separated values are accepted. Needed to recognize the
    corporate WLAN when its profile is not reported as domain-authenticated; without it, exit code 20 only
    occurs for a domain-authenticated WLAN.

.PARAMETER DomainName
    DNS name of the domain whose DCs must be reachable (default: the domain of this computer). Without
    -DomainName, a computer that is not a domain member ends with exit code 1.

.PARAMETER Quiet
    Suppresses the result line on stdout; only the exit code remains. Details still appear with -Verbose.

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-DeploymentNetwork.ps1 -CorporateSsid "CORP-WLAN"

    Allows wired LAN and DirectAccess. On the corporate WLAN only, the exit code is 20.
    Output e.g.: RESULT=LAN EXIT=0 DOMAIN=corp.example DC=dc01.corp.example LAN=DomainAuthenticated ...

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-DeploymentNetwork.ps1 -Allow Lan -Verbose

    Allows wired LAN only (DirectAccess -> 22) and shows the details of each detection.

.EXAMPLE
    .\Test-DeploymentNetwork.ps1 -Allow Lan, DirectAccess, Wlan -CorporateSsid "CORP-WLAN", "CORP-WLAN-5G"

    Allows every path; the corporate WLAN is recognized by two SSIDs.

.OUTPUTS
    Exactly one line on stdout (unless -Quiet), e.g.
      RESULT=DIRECTACCESS EXIT=0 DOMAIN=corp.example DC=dc01.corp.example LAN=None DA=ConnectedRemotely WLAN="none" ALLOW=Lan,DirectAccess REASON="..."
    RESULT is the detected path (LAN, DIRECTACCESS, WLAN, OTHER, NONE, ERROR), EXIT the verdict:
      0       allowed path detected and a DC is reachable
      20      only the corporate WLAN (EAP-TLS) is available: ask the user to plug in a LAN cable
      21      no domain connectivity (offline, foreign network without DA, or no DC answers)
      22      path detected but not allowed (e.g. DirectAccess with -Allow Lan), or unknown path to the domain
      1       unexpected error (e.g. not a domain member and no -DomainName)

.NOTES
    Product          HostRename
    Version          1.2.0
    Date             2026-11-03
    Runs as          SYSTEM (deployment tool) or manually; no administrator rights required
    Encoding         UTF-8 with BOM (required for Windows PowerShell 5.1)

.LINK
    README.md
#>
#Requires -Version 5.1

[CmdletBinding()]
param(
    [ValidateScript({
        foreach ($v in ($_ -split ',')) {
            if ($v.Trim() -notin @('Lan', 'DirectAccess', 'Wlan')) {
                throw "Invalid value '$($v.Trim())' for -Allow. Valid values: Lan, DirectAccess, Wlan."
            }
        }
        $true
    })]
    [string[]]$Allow = @('Lan', 'DirectAccess'),

    [string[]]$CorporateSsid = @(),

    [ValidatePattern('^$|^[A-Za-z0-9][A-Za-z0-9.-]*$')]
    [string]$DomainName = '',

    [switch]$Quiet
)

# ---- Parameter helpers ---------------------------------------------------------------
function Split-ListValue {
    # Splits comma-separated values (powershell.exe -File passes "a,b" as one string), trims them and
    # drops empty entries.
    param([string[]]$Value)
    foreach ($v in @($Value)) {
        foreach ($part in ([string]$v -split ',')) {
            $p = $part.Trim()
            if ($p) { $p }
        }
    }
}

function ConvertTo-AllowList {
    # Normalizes -Allow to the canonical spelling (Lan, DirectAccess, Wlan) without duplicates.
    param([string[]]$Value)
    $out = @()
    foreach ($p in @(Split-ListValue -Value $Value)) {
        foreach ($c in @('Lan', 'DirectAccess', 'Wlan')) {
            if ($c -eq $p -and $out -notcontains $c) { $out += $c }
        }
    }
    $out
}

# ---- Detection -----------------------------------------------------------------------
function Get-MachineDomain {
    # Returns the DNS domain of this computer, or '' if it is not a domain member (or CIM is not available).
    try { $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop }
    catch [System.Management.Automation.CommandNotFoundException] {
        Write-Verbose 'Get-CimInstance is not available; domain membership unknown.'
        return ''
    }
    if ($cs.PartOfDomain) { return [string]$cs.Domain }
    return ''
}

function Get-AdapterKind {
    # Classifies a Get-NetAdapter object by its physical medium: Wired, Wlan or Other.
    # Uses the numeric NDIS values first; the string properties are English constants of the cmdlet.
    param($Adapter)
    $phys = $Adapter.NdisPhysicalMedium
    if ($phys -eq 14 -or $Adapter.PhysicalMediaType -eq '802.3') { return 'Wired' }
    if ($phys -eq 9  -or $Adapter.PhysicalMediaType -eq 'Native 802.11') { return 'Wlan' }
    $unspecified = ($phys -eq 0 -or $Adapter.PhysicalMediaType -eq 'Unspecified')
    if ($unspecified -and $Adapter.MediaType -eq '802.3') { return 'Wired' }   # some USB/dock adapters
    return 'Other'
}

function Get-InterfaceDomainAuthenticated {
    # True if one of the connection profiles of the interface is DomainAuthenticated.
    param([int]$InterfaceIndex)
    $profiles = @(Get-NetConnectionProfile -InterfaceIndex $InterfaceIndex -ErrorAction SilentlyContinue)
    return [bool](@($profiles | Where-Object { "$($_.NetworkCategory)" -eq 'DomainAuthenticated' }).Count)
}

function Get-WiredDomainState {
    # Wired path: physical 802.3 adapter that is Up; DomainAuthenticated if one of them has a domain profile.
    $state = [pscustomobject]@{ Up = $false; DomainAuthenticated = $false; Adapters = @() }
    try { $adapters = @(Get-NetAdapter -Physical -ErrorAction Stop) }
    catch [System.Management.Automation.CommandNotFoundException] {
        Write-Verbose 'Get-NetAdapter is not available; no wired adapter detected.'
        return $state
    }
    foreach ($a in $adapters) {
        if ($a.Status -ne 'Up' -or (Get-AdapterKind -Adapter $a) -ne 'Wired') { continue }
        $state.Up = $true
        $auth = Get-InterfaceDomainAuthenticated -InterfaceIndex $a.ifIndex
        if ($auth) { $state.DomainAuthenticated = $true }
        $state.Adapters += $a.Name
        Write-Verbose "Wired adapter '$($a.Name)' ($($a.InterfaceDescription)) is up, domain-authenticated: $auth."
    }
    if (-not $state.Up) { Write-Verbose 'No wired adapter is up.' }
    return $state
}

function Get-DirectAccessState {
    # Returns the DirectAccess status (ConnectedRemotely means connected over DA), NotAvailable if the cmdlet
    # does not exist, or NotConfigured if it fails (no DA client, service not running).
    try {
        $s = Get-DAConnectionStatus -ErrorAction Stop
        $status = [string]$s.Status
        if (-not $status) { $status = 'Unknown' }
        Write-Verbose "DirectAccess status: $status."
        return $status
    }
    catch [System.Management.Automation.CommandNotFoundException] {
        Write-Verbose 'Get-DAConnectionStatus is not available; DirectAccess counts as not connected.'
        return 'NotAvailable'
    }
    catch {
        Write-Verbose "DirectAccess status not available: $($_.Exception.Message)"
        return 'NotConfigured'
    }
}

function Get-WinRtWlanConnection {
    # Connected WLAN connections from WinRT (Windows PowerShell 5.1). Each: Ssid, DomainAuthenticated, Source.
    # Throws if WinRT is not available (e.g. PowerShell 7); the caller then uses the fallback.
    $null = [Windows.Networking.Connectivity.NetworkInformation, Windows.Networking.Connectivity, ContentType = WindowsRuntime]
    foreach ($p in [Windows.Networking.Connectivity.NetworkInformation]::GetConnectionProfiles()) {
        if (-not $p.IsWlanConnectionProfile) { continue }
        if ([int]$p.GetNetworkConnectivityLevel() -eq 0) { continue }   # NetworkConnectivityLevel.None: not connected
        $ssid = ''
        try { $ssid = [string]$p.WlanConnectionProfileDetails.GetConnectedSsid() }
        catch { Write-Verbose "SSID not readable via WinRT: $($_.Exception.Message)" }
        [pscustomobject]@{
            Ssid                = $ssid
            DomainAuthenticated = ([int]$p.GetDomainConnectivityLevel() -eq 2)   # DomainConnectivityLevel.Authenticated
            Source              = 'WinRT'
        }
    }
}

function Get-ProfileWlanConnection {
    # Fallback: connection profiles of wireless adapters that are Up. The profile name is usually the SSID,
    # but for a domain network it is the domain name.
    try { $adapters = @(Get-NetAdapter -Physical -ErrorAction Stop) }
    catch [System.Management.Automation.CommandNotFoundException] {
        Write-Verbose 'Get-NetAdapter is not available; no WLAN adapter detected.'
        return
    }
    foreach ($a in $adapters) {
        if ($a.Status -ne 'Up' -or (Get-AdapterKind -Adapter $a) -ne 'Wlan') { continue }
        $profiles = @(Get-NetConnectionProfile -InterfaceIndex $a.ifIndex -ErrorAction SilentlyContinue)
        if (-not $profiles.Count) {
            [pscustomobject]@{ Ssid = ''; DomainAuthenticated = $false; Source = 'ConnectionProfile' }
        }
        foreach ($p in $profiles) {
            [pscustomobject]@{
                Ssid                = [string]$p.Name
                DomainAuthenticated = ("$($p.NetworkCategory)" -eq 'DomainAuthenticated')
                Source              = 'ConnectionProfile'
            }
        }
    }
}

function Get-WlanSsid {
    # Connected WLAN connections (Ssid, DomainAuthenticated, Source): WinRT first, connection profile as fallback.
    $conn = @()
    try { $conn = @(Get-WinRtWlanConnection) }
    catch { Write-Verbose "WinRT NetworkInformation not available: $($_.Exception.Message)" }
    if (-not $conn.Count) { $conn = @(Get-ProfileWlanConnection) }
    foreach ($c in $conn) {
        Write-Verbose "WLAN connection: SSID '$($c.Ssid)', domain-authenticated: $($c.DomainAuthenticated) (source: $($c.Source))."
    }
    if (-not $conn.Count) { Write-Verbose 'No WLAN connection detected.' }
    $conn
}

function Resolve-HostAddress {
    # Distinct addresses of a host in resolver order (throws if the name cannot be resolved).
    param([Parameter(Mandatory)][string]$ComputerName)
    $seen = @{}
    foreach ($a in [System.Net.Dns]::GetHostAddresses($ComputerName)) {
        $k = $a.ToString()
        if (-not $seen.ContainsKey($k)) { $seen[$k] = $true; $a }
    }
}

function Test-TcpPort {
    # True if a TCP connection to one of the addresses of the host succeeds within the timeout (per address).
    # One socket per address with its own address family (the default TcpClient is IPv4 only in .NET Framework).
    # All distinct addresses are tried in resolver order, at most -MaxAttempts. -Address skips the name resolution.
    param([string]$ComputerName, [int]$Port, [int]$TimeoutMs = 1500, [int]$MaxAttempts = 6, [object[]]$Address)
    $addrs = @($Address | Where-Object { $_ })
    if (-not $addrs.Count) {
        try { $addrs = @(Resolve-HostAddress -ComputerName $ComputerName) }
        catch { Write-Verbose "'$ComputerName' cannot be resolved: $($_.Exception.Message)"; return $false }
    }
    foreach ($addr in ($addrs | Select-Object -First $MaxAttempts)) {
        $tcp = $null
        try {
            # Inside try: creating an IPv6 socket throws on a host without IPv6
            $tcp = New-Object System.Net.Sockets.TcpClient -ArgumentList $addr.AddressFamily
            $iar = $tcp.BeginConnect($addr, $Port, $null, $null)
            if ($iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) {
                $tcp.EndConnect($iar)
                return $true
            }
            Write-Verbose "Port $Port on $ComputerName ($addr): timeout after $TimeoutMs ms."
        }
        catch { Write-Verbose "Port $Port on $ComputerName ($addr): $($_.Exception.Message)" }
        finally { if ($tcp) { $tcp.Close() } }
    }
    return $false
}

function Test-DomainReachable {
    # DNS SRV lookup for the DCs of the domain, then TCP 389 on the first DCs (by priority and weight).
    # Every distinct address of a DC is tried (a DC that publishes an unreachable IPv6 address first is still
    # tried over IPv4), with at most -MaxAttempts connection attempts in total across all DCs.
    param([string]$DomainName, [int]$TimeoutMs = 1500, [int]$MaxDc = 3, [int]$MaxAttempts = 6)
    $res = [pscustomobject]@{ Reachable = $false; DnsOk = $false; Dc = ''; Error = '' }
    $query = "_ldap._tcp.dc._msdcs.$DomainName"
    try { $records = @(Resolve-DnsName -Name $query -Type SRV -DnsOnly -QuickTimeout -ErrorAction Stop) }
    catch {
        $res.Error = "DNS SRV lookup '$query' failed: $($_.Exception.Message)"
        Write-Verbose $res.Error
        return $res
    }
    $targets = @($records |
        Where-Object { $_.PSObject.Properties['NameTarget'] -and $_.NameTarget } |
        Sort-Object -Property @{ Expression = { [int]$_.Priority } }, @{ Expression = { [int]$_.Weight }; Descending = $true } |
        ForEach-Object { [string]$_.NameTarget } |
        Select-Object -Unique)
    if (-not $targets.Count) {
        $res.Error = "DNS SRV lookup '$query' returned no DC."
        Write-Verbose $res.Error
        return $res
    }
    $res.DnsOk = $true
    $left = $MaxAttempts
    foreach ($t in ($targets | Select-Object -First $MaxDc)) {
        if ($left -le 0) { Write-Verbose "Limit of $MaxAttempts connection attempts reached."; break }
        try { $addrs = @(Resolve-HostAddress -ComputerName $t) }
        catch { Write-Verbose "DC '$t' cannot be resolved: $($_.Exception.Message)"; continue }
        if (-not $addrs.Count) { Write-Verbose "DC '$t' resolves to no address."; continue }
        $batch = @($addrs | Select-Object -First $left)
        $left -= $batch.Count
        if (Test-TcpPort -ComputerName $t -Port 389 -TimeoutMs $TimeoutMs -Address $batch -MaxAttempts $batch.Count) {
            $res.Reachable = $true
            $res.Dc = $t
            Write-Verbose "DC '$t' answers on port 389."
            return $res
        }
    }
    $res.Error = "No DC answered on port 389 ($(($targets | Select-Object -First $MaxDc) -join ', '))."
    Write-Verbose $res.Error
    return $res
}

# ---- Decision ------------------------------------------------------------------------
function Resolve-NetworkDecision {
    # Pure function: maps the detected state to exit code, RESULT and reason (rules: see help, DECISION).
    param(
        [string[]]$Allow = @(),
        [bool]$WiredUp,
        [bool]$WiredDomainAuthenticated,
        [string]$DirectAccessStatus = '',
        [object[]]$Wlan = @(),
        [string[]]$CorporateSsid = @(),
        [bool]$DomainReachable
    )
    $Allow         = @($Allow)
    $CorporateSsid = @($CorporateSsid)
    $lan  = $WiredDomainAuthenticated
    $da   = ($DirectAccessStatus -eq 'ConnectedRemotely')
    $corp = @(@($Wlan) | Where-Object { $_ -and ($_.DomainAuthenticated -or ($_.Ssid -and $CorporateSsid -contains $_.Ssid)) })
    $corpWlan = [bool]$corp.Count

    $path = ''
    if     ($lan      -and $Allow -contains 'Lan')          { $path = 'LAN' }
    elseif ($da       -and $Allow -contains 'DirectAccess') { $path = 'DIRECTACCESS' }
    elseif ($corpWlan -and $Allow -contains 'Wlan')         { $path = 'WLAN' }

    if ($path) {
        if ($DomainReachable) { return [pscustomobject]@{ ExitCode = 0;  Result = $path; Reason = "Allowed path $path, domain reachable." } }
        return [pscustomobject]@{ ExitCode = 21; Result = $path; Reason = "Allowed path $path detected, but no DC answered." }
    }
    if ($lan) { return [pscustomobject]@{ ExitCode = 22; Result = 'LAN'; Reason = 'Wired LAN (domain-authenticated) is not allowed.' } }
    if ($da)  { return [pscustomobject]@{ ExitCode = 22; Result = 'DIRECTACCESS'; Reason = 'DirectAccess is not allowed.' } }
    if ($corpWlan) {
        if ($Allow -contains 'Lan') {
            $r = 'Only the corporate WLAN is available; a LAN cable is needed.'
            if ($WiredUp) { $r += ' A wired adapter is up, but not in the domain network.' }
            return [pscustomobject]@{ ExitCode = 20; Result = 'WLAN'; Reason = $r }
        }
        return [pscustomobject]@{ ExitCode = 22; Result = 'WLAN'; Reason = 'Corporate WLAN is not allowed, and neither is wired LAN.' }
    }
    if ($DomainReachable) {
        return [pscustomobject]@{ ExitCode = 22; Result = 'OTHER'; Reason = 'A DC answers, but over no recognized path (other VPN, unknown adapter, network not yet identified).' }
    }
    return [pscustomobject]@{ ExitCode = 21; Result = 'NONE'; Reason = 'No domain connectivity.' }
}

function Format-ResultLine {
    # Builds the single summary line for stdout (no line breaks, quotes in values replaced).
    param(
        $Decision,
        [string]$DomainName = '',
        [string]$Dc = '',
        $Wired = $null,
        [string]$DirectAccessStatus = '',
        [object[]]$Wlan = $null,
        [string[]]$Allow = @()
    )
    $lanText = '-'
    if ($Wired) {
        if ($Wired.DomainAuthenticated) { $lanText = 'DomainAuthenticated' }
        elseif ($Wired.Up)              { $lanText = 'Up' }
        else                            { $lanText = 'None' }
    }
    $wlanText = '-'
    if ($null -ne $Wlan) {
        $items = @(@($Wlan) | Where-Object { $_ } | ForEach-Object {
            $n = if ($_.Ssid) { [string]$_.Ssid } else { '?' }
            if ($_.DomainAuthenticated) { $n += '(DomainAuthenticated)' }
            $n
        })
        $wlanText = if ($items.Count) { $items -join ';' } else { 'none' }
    }
    $clean = { param($s) (([string]$s) -replace '[\r\n]+', ' ' -replace '"', "'").Trim() }
    $daText  = if ($DirectAccessStatus) { $DirectAccessStatus } else { '-' }
    $domText = if ($DomainName) { $DomainName } else { '-' }
    $dcText  = if ($Dc) { $Dc } else { 'none' }
    'RESULT={0} EXIT={1} DOMAIN={2} DC={3} LAN={4} DA={5} WLAN="{6}" ALLOW={7} REASON="{8}"' -f
        $Decision.Result, $Decision.ExitCode, $domText, $dcText, $lanText, $daText,
        (& $clean $wlanText), (@($Allow) -join ','), (& $clean $Decision.Reason)
}

# ---- Main ----------------------------------------------------------------------------
$allowList = @()
try {
    $allowList = @(ConvertTo-AllowList -Value $Allow)
    $ssidList  = @(Split-ListValue -Value $CorporateSsid)
    if (-not $DomainName) { $DomainName = Get-MachineDomain }
    if (-not $DomainName) { throw 'This computer is not a domain member (or its domain cannot be determined), and -DomainName was not given.' }

    $wired = Get-WiredDomainState
    $da    = Get-DirectAccessState
    $wlan  = @(Get-WlanSsid)
    $dc    = Test-DomainReachable -DomainName $DomainName

    $decision = Resolve-NetworkDecision -Allow $allowList -WiredUp ([bool]$wired.Up) -WiredDomainAuthenticated ([bool]$wired.DomainAuthenticated) `
        -DirectAccessStatus $da -Wlan $wlan -CorporateSsid $ssidList -DomainReachable ([bool]$dc.Reachable)
    $line = Format-ResultLine -Decision $decision -DomainName $DomainName -Dc $dc.Dc -Wired $wired -DirectAccessStatus $da -Wlan $wlan -Allow $allowList
}
catch {
    $decision = [pscustomobject]@{ ExitCode = 1; Result = 'ERROR'; Reason = "Unexpected error: $($_.Exception.Message)" }
    $line = Format-ResultLine -Decision $decision -DomainName $DomainName -Allow $allowList
}
if (-not $Quiet) { Write-Output $line }
exit $decision.ExitCode
