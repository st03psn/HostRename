<#
.SYNOPSIS
    HostRename - network gate tests: checks the decision logic and the detection functions of
    Test-DeploymentNetwork.ps1 with mocks.

.DESCRIPTION
    Runs on Windows and Linux without network access to a domain. The functions are loaded from
    Test-DeploymentNetwork.ps1 via the AST, so the script body (detection and exit) does not run.
    Cmdlets that do not exist on the test system (Get-NetAdapter, Get-NetConnectionProfile,
    Get-DAConnectionStatus, Resolve-DnsName, Get-CimInstance) are replaced by empty stub functions so they
    can be mocked.

    CHECKS
      1. Script file: syntax, UTF-8 with BOM, LF line endings, comment-based help, .NOTES version line,
         no PowerShell 7-only syntax
      2. Resolve-NetworkDecision: all exit codes and edge cases (table-driven)
      3. Parameter helpers and result line
      4. Detection functions with mocked cmdlets (wired LAN, DirectAccess, WLAN, domain reachability)
      5. Test-TcpPort against a local listener; the script in a child process (one line, exit code)

    NOT CHECKED: the real cmdlet and WinRT output on Windows (different adapters, docking stations,
    DirectAccess, location privacy for the SSID). These need a test on real devices.

.PARAMETER ScriptFolder
    Folder with Test-DeploymentNetwork.ps1 (default: the parent folder of the folder of this test file,
    i.e. components\).

.EXAMPLE
    Invoke-Pester -Path .\components\tests\HostRename.Network.Tests.ps1 -Output Detailed

.NOTES
    Product          HostRename
    Version          1.2.0
    Date             2026-11-03
    Runs as          any user, Windows PowerShell 5.1 or PowerShell 7 (also on Linux)
    Encoding         UTF-8 with BOM (required for Windows PowerShell 5.1)

.LINK
    Test-DeploymentNetwork.ps1
#>
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.3.0' }
#Requires -Version 5.1
param(
    [string]$ScriptFolder = ''
)

BeforeDiscovery {
    function New-Wlan { param([string]$Ssid, [bool]$Domain = $false) [pscustomobject]@{ Ssid = $Ssid; DomainAuthenticated = $Domain; Source = 'Test' } }

    $lanDa   = @('Lan', 'DirectAccess')
    $corp    = New-Wlan -Ssid 'CORP-WLAN'
    $corpDom = New-Wlan -Ssid '' -Domain $true      # SSID withheld, profile domain-authenticated
    $homeNet    = New-Wlan -Ssid 'HomeNet'

    # Allow, wired up/domain-authenticated, DA status, WLAN connections, corporate SSIDs, DC reachable -> exit code, RESULT
    $DecisionCases = @(
        @{ Label = 'LAN domain-authenticated';                           Allow = $lanDa;                 WiredUp = $true;  WiredAuth = $true;  Da = 'NotAvailable';      Wlan = @();                 Ssid = @('CORP-WLAN'); Reach = $true;  Exit = 0;  Result = 'LAN' }
        @{ Label = 'LAN and corporate WLAN at the same time: LAN wins';  Allow = $lanDa;                 WiredUp = $true;  WiredAuth = $true;  Da = 'ConnectedLocally';  Wlan = @($corp);            Ssid = @('CORP-WLAN'); Reach = $true;  Exit = 0;  Result = 'LAN' }
        @{ Label = 'DirectAccess connected remotely';                    Allow = $lanDa;                 WiredUp = $false; WiredAuth = $false; Da = 'ConnectedRemotely'; Wlan = @($homeNet);            Ssid = @('CORP-WLAN'); Reach = $true;  Exit = 0;  Result = 'DIRECTACCESS' }
        @{ Label = 'LAN in a foreign network plus DirectAccess';         Allow = $lanDa;                 WiredUp = $true;  WiredAuth = $false; Da = 'ConnectedRemotely'; Wlan = @();                 Ssid = @();            Reach = $true;  Exit = 0;  Result = 'DIRECTACCESS' }
        @{ Label = 'corporate WLAN with Wlan allowed';                   Allow = @('Lan', 'Wlan');       WiredUp = $false; WiredAuth = $false; Da = 'NotAvailable';      Wlan = @($corp);            Ssid = @('CORP-WLAN'); Reach = $true;  Exit = 0;  Result = 'WLAN' }
        @{ Label = 'LAN not allowed, corporate WLAN allowed';            Allow = @('Wlan');              WiredUp = $true;  WiredAuth = $true;  Da = 'ConnectedLocally';  Wlan = @($corp);            Ssid = @('CORP-WLAN'); Reach = $true;  Exit = 0;  Result = 'WLAN' }
        @{ Label = 'DA ConnectedLocally does not hide the LAN';          Allow = $lanDa;                 WiredUp = $true;  WiredAuth = $true;  Da = 'ConnectedLocally';  Wlan = @();                 Ssid = @();            Reach = $true;  Exit = 0;  Result = 'LAN' }
        @{ Label = 'LAN domain-authenticated but no DC answers';         Allow = $lanDa;                 WiredUp = $true;  WiredAuth = $true;  Da = 'NotAvailable';      Wlan = @();                 Ssid = @();            Reach = $false; Exit = 21; Result = 'LAN' }
        @{ Label = 'DirectAccess connected but no DC answers';           Allow = $lanDa;                 WiredUp = $false; WiredAuth = $false; Da = 'ConnectedRemotely'; Wlan = @();                 Ssid = @();            Reach = $false; Exit = 21; Result = 'DIRECTACCESS' }
        @{ Label = 'only corporate WLAN (SSID match)';                   Allow = $lanDa;                 WiredUp = $false; WiredAuth = $false; Da = 'ConnectedLocally';  Wlan = @($corp);            Ssid = @('CORP-WLAN'); Reach = $true;  Exit = 20; Result = 'WLAN' }
        @{ Label = 'only corporate WLAN, SSID compared case-insensitive'; Allow = $lanDa;                WiredUp = $false; WiredAuth = $false; Da = 'NotAvailable';      Wlan = @($corp);            Ssid = @('corp-wlan'); Reach = $true;  Exit = 20; Result = 'WLAN' }
        @{ Label = 'only corporate WLAN, DC not reachable from WLAN';    Allow = $lanDa;                 WiredUp = $false; WiredAuth = $false; Da = 'NotAvailable';      Wlan = @($corp);            Ssid = @('CORP-WLAN'); Reach = $false; Exit = 20; Result = 'WLAN' }
        @{ Label = 'only corporate WLAN by domain profile, no SSID';     Allow = $lanDa;                 WiredUp = $false; WiredAuth = $false; Da = 'NotAvailable';      Wlan = @($corpDom);         Ssid = @();            Reach = $true;  Exit = 20; Result = 'WLAN' }
        @{ Label = 'corporate WLAN plus cable in a foreign network';     Allow = $lanDa;                 WiredUp = $true;  WiredAuth = $false; Da = 'NotAvailable';      Wlan = @($corp);            Ssid = @('CORP-WLAN'); Reach = $true;  Exit = 20; Result = 'WLAN' }
        @{ Label = 'two WLAN adapters, one corporate';                   Allow = $lanDa;                 WiredUp = $false; WiredAuth = $false; Da = 'NotAvailable';      Wlan = @($homeNet, $corp);     Ssid = @('X', 'CORP-WLAN'); Reach = $true; Exit = 20; Result = 'WLAN' }
        @{ Label = 'only corporate WLAN, Lan not allowed';               Allow = @('DirectAccess');      WiredUp = $false; WiredAuth = $false; Da = 'NotAvailable';      Wlan = @($corp);            Ssid = @('CORP-WLAN'); Reach = $true;  Exit = 22; Result = 'WLAN' }
        @{ Label = 'DirectAccess with only Lan allowed';                 Allow = @('Lan');               WiredUp = $false; WiredAuth = $false; Da = 'ConnectedRemotely'; Wlan = @($homeNet);            Ssid = @('CORP-WLAN'); Reach = $true;  Exit = 22; Result = 'DIRECTACCESS' }
        @{ Label = 'LAN with only DirectAccess allowed';                 Allow = @('DirectAccess');      WiredUp = $true;  WiredAuth = $true;  Da = 'ConnectedLocally';  Wlan = @();                 Ssid = @();            Reach = $true;  Exit = 22; Result = 'LAN' }
        @{ Label = 'LAN and corporate WLAN, only DirectAccess allowed';  Allow = @('DirectAccess');      WiredUp = $true;  WiredAuth = $true;  Da = 'ConnectedLocally';  Wlan = @($corp);            Ssid = @('CORP-WLAN'); Reach = $true;  Exit = 22; Result = 'LAN' }
        @{ Label = 'DA not allowed and no DC answers is still 22';       Allow = @('Lan');               WiredUp = $false; WiredAuth = $false; Da = 'ConnectedRemotely'; Wlan = @();                 Ssid = @();            Reach = $false; Exit = 22; Result = 'DIRECTACCESS' }
        @{ Label = 'foreign LAN, DC reachable anyway (other VPN)';       Allow = $lanDa;                 WiredUp = $true;  WiredAuth = $false; Da = 'NotAvailable';      Wlan = @();                 Ssid = @();            Reach = $true;  Exit = 22; Result = 'OTHER' }
        @{ Label = 'LAN up, network not yet identified (NLA)';           Allow = $lanDa;                 WiredUp = $true;  WiredAuth = $false; Da = 'ConnectedLocally';  Wlan = @();                 Ssid = @();            Reach = $true;  Exit = 22; Result = 'OTHER' }
        @{ Label = 'non-corporate SSID with Wlan allowed, DC reachable'; Allow = @('Lan', 'Wlan');       WiredUp = $false; WiredAuth = $false; Da = 'NotAvailable';      Wlan = @($homeNet);            Ssid = @('CORP-WLAN'); Reach = $true;  Exit = 22; Result = 'OTHER' }
        @{ Label = 'corporate SSID not configured, profile not domain';  Allow = $lanDa;                 WiredUp = $false; WiredAuth = $false; Da = 'NotAvailable';      Wlan = @($corp);            Ssid = @();            Reach = $true;  Exit = 22; Result = 'OTHER' }
        @{ Label = 'foreign LAN, no DirectAccess, offline';              Allow = $lanDa;                 WiredUp = $true;  WiredAuth = $false; Da = 'NotAvailable';      Wlan = @();                 Ssid = @();            Reach = $false; Exit = 21; Result = 'NONE' }
        @{ Label = 'home WLAN, DA configured but inactive';              Allow = $lanDa;                 WiredUp = $false; WiredAuth = $false; Da = 'Error';             Wlan = @($homeNet);            Ssid = @('CORP-WLAN'); Reach = $false; Exit = 21; Result = 'NONE' }
        @{ Label = 'home WLAN with Wlan allowed, offline';               Allow = @('Lan', 'Wlan');       WiredUp = $false; WiredAuth = $false; Da = 'NotConfigured';     Wlan = @($homeNet);            Ssid = @('CORP-WLAN'); Reach = $false; Exit = 21; Result = 'NONE' }
        @{ Label = 'no network at all';                                  Allow = @('Lan', 'DirectAccess', 'Wlan'); WiredUp = $false; WiredAuth = $false; Da = 'NotAvailable'; Wlan = @();             Ssid = @();            Reach = $false; Exit = 21; Result = 'NONE' }
    )

    # NdisPhysicalMedium, PhysicalMediaType, MediaType -> adapter kind
    $KindCases = @(
        @{ Label = 'Ethernet 802.3';                  Phys = 14;    PhysType = '802.3';         Media = '802.3'; Expect = 'Wired' }
        @{ Label = 'USB/dock adapter, unspecified';   Phys = 0;     PhysType = 'Unspecified';   Media = '802.3'; Expect = 'Wired' }
        @{ Label = 'only the string property';        Phys = $null; PhysType = '802.3';         Media = '802.3'; Expect = 'Wired' }
        @{ Label = 'WLAN (media type 802.3 as well)'; Phys = 9;     PhysType = 'Native 802.11'; Media = '802.3'; Expect = 'Wlan' }
        @{ Label = 'WWAN';                            Phys = 8;     PhysType = 'Wireless WAN';  Media = 'Wireless WAN'; Expect = 'Other' }
        @{ Label = 'Bluetooth PAN';                   Phys = 10;    PhysType = 'BlueTooth';     Media = '802.3'; Expect = 'Other' }
        @{ Label = 'unspecified, not 802.3';          Phys = 0;     PhysType = 'Unspecified';   Media = 'IP';    Expect = 'Other' }
    )
}

BeforeAll {
    $ScriptFolder = if ($ScriptFolder) { $ScriptFolder } else { Split-Path -Parent $PSScriptRoot }
    $GatePath = Join-Path $ScriptFolder 'Test-DeploymentNetwork.ps1'

    # Load all functions of the gate script without running its body (detection and exit)
    $tk = $null; $er = $null
    $GateAst = [System.Management.Automation.Language.Parser]::ParseFile($GatePath, [ref]$tk, [ref]$er)
    $fns = $GateAst.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)
    . ([scriptblock]::Create((($fns | ForEach-Object { $_.Extent.Text }) -join "`r`n")))

    # Stub functions for cmdlets missing on this system (Linux, PowerShell 7) so that Mock can replace them
    if (-not (Get-Command Get-NetAdapter -ErrorAction SilentlyContinue)) {
        function Get-NetAdapter { [CmdletBinding()] param([switch]$Physical) }
    }
    if (-not (Get-Command Get-NetConnectionProfile -ErrorAction SilentlyContinue)) {
        function Get-NetConnectionProfile { [CmdletBinding()] param([int]$InterfaceIndex) }
    }
    if (-not (Get-Command Get-DAConnectionStatus -ErrorAction SilentlyContinue)) {
        function Get-DAConnectionStatus { [CmdletBinding()] param() }
    }
    if (-not (Get-Command Resolve-DnsName -ErrorAction SilentlyContinue)) {
        function Resolve-DnsName { [CmdletBinding()] param([string]$Name, [string]$Type, [switch]$DnsOnly, [switch]$QuickTimeout) }
    }
    if (-not (Get-Command Get-CimInstance -ErrorAction SilentlyContinue)) {
        function Get-CimInstance { [CmdletBinding()] param([string]$ClassName) }
    }

    function New-Adapter {
        param([string]$Name, [int]$Index, [string]$Status = 'Up', $Phys = 14, [string]$PhysType = '802.3', [string]$Media = '802.3')
        [pscustomobject]@{ Name = $Name; InterfaceDescription = "$Name adapter"; ifIndex = $Index; Status = $Status
                           NdisPhysicalMedium = $Phys; PhysicalMediaType = $PhysType; MediaType = $Media }
    }
    function New-CnfException { param([string]$Name) New-Object System.Management.Automation.CommandNotFoundException -ArgumentList "The term '$Name' is not recognized." }
}

Describe 'Script file Test-DeploymentNetwork.ps1' {
    It 'has no syntax errors' {
        $er | Should -BeNullOrEmpty
    }
    It 'is UTF-8 with BOM and has LF line endings' {
        $bytes = [System.IO.File]::ReadAllBytes($GatePath)
        $bytes[0..2] | Should -Be @(0xEF, 0xBB, 0xBF)
        [System.Text.Encoding]::UTF8.GetString($bytes) | Should -Not -Match "`r"
    }
    It 'has comment-based help before #Requires, recognized by Get-Help' {
        $raw = Get-Content -Raw -Path $GatePath
        $raw.IndexOf('#>') | Should -BeLessThan $raw.IndexOf('#Requires -Version 5.1')
        $help = Get-Help $GatePath -Full
        $help.Synopsis | Should -Match 'Network gate'
        @($help.parameters.parameter.name) | Should -Be @('Allow', 'CorporateSsid', 'DomainName', 'Quiet')
    }
    It 'has exactly one .NOTES version line in the format the version test reads' {
        $m = [regex]::Matches((Get-Content -Raw -Path $GatePath), '(?m)^\s+Version\s+(\S+)\s*$')
        $m.Count | Should -Be 1
        $m[0].Groups[1].Value | Should -Match '^\d+\.\d+\.\d+$'
    }
    It 'uses no PowerShell 7-only syntax (ternary, ??, ?., &&, ||, -Parallel)' {
        $kinds = @('QuestionMark', 'QuestionQuestion', 'QuestionQuestionEquals', 'QuestionDot', 'QuestionLBracket', 'AndAnd', 'OrOr')
        $bad = @($tk | Where-Object { $kinds -contains "$($_.Kind)" } | ForEach-Object { "$($_.Kind) at line $($_.Extent.StartLineNumber)" })
        $bad | Should -BeNullOrEmpty
        (Get-Content -Raw -Path $GatePath) | Should -Not -Match '-Parallel\b'
    }
    It 'defines the detection functions and the pure decision function' {
        foreach ($n in 'Get-WiredDomainState', 'Get-DirectAccessState', 'Get-WlanSsid', 'Test-DomainReachable', 'Resolve-NetworkDecision') {
            Get-Command $n -CommandType Function -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty -Because "$n is needed"
        }
    }
}

Describe 'Resolve-NetworkDecision' {
    It '<Label>: exit <Exit>, RESULT=<Result>' -ForEach $DecisionCases {
        $d = Resolve-NetworkDecision -Allow $Allow -WiredUp $WiredUp -WiredDomainAuthenticated $WiredAuth -DirectAccessStatus $Da `
            -Wlan $Wlan -CorporateSsid $Ssid -DomainReachable $Reach
        $d.ExitCode | Should -Be $Exit
        $d.Result   | Should -Be $Result
        $d.Reason   | Should -Not -BeNullOrEmpty
    }
    It 'mentions the foreign cable in the reason for exit 20' {
        $d = Resolve-NetworkDecision -Allow 'Lan' -WiredUp $true -WiredDomainAuthenticated $false -DirectAccessStatus '' `
            -Wlan @([pscustomobject]@{ Ssid = 'CORP'; DomainAuthenticated = $false }) -CorporateSsid 'CORP' -DomainReachable $true
        $d.ExitCode | Should -Be 20
        $d.Reason   | Should -Match 'wired adapter is up'
    }
    It 'accepts $null and empty WLAN entries' {
        (Resolve-NetworkDecision -Allow 'Lan' -WiredUp $false -WiredDomainAuthenticated $false -Wlan $null -DomainReachable $false).ExitCode | Should -Be 21
        (Resolve-NetworkDecision -Allow 'Lan' -WiredUp $false -WiredDomainAuthenticated $false -Wlan @($null) -DomainReachable $false).ExitCode | Should -Be 21
    }
}

Describe 'Parameter helpers' {
    It 'Split-ListValue splits comma-separated values (powershell.exe -File) and trims them' {
        @(Split-ListValue -Value 'CORP-WLAN, CORP 5G', '', 'X') | Should -Be @('CORP-WLAN', 'CORP 5G', 'X')
        @(Split-ListValue -Value @()) | Should -BeNullOrEmpty
    }
    It 'ConvertTo-AllowList normalizes spelling and removes duplicates' {
        @(ConvertTo-AllowList -Value 'lan,DIRECTACCESS', 'Lan', ' wlan ') | Should -Be @('Lan', 'DirectAccess', 'Wlan')
    }
}

Describe 'Format-ResultLine' {
    It 'builds one line with all fields' {
        $d = [pscustomobject]@{ ExitCode = 0; Result = 'LAN'; Reason = 'Allowed path LAN, domain reachable.' }
        $l = Format-ResultLine -Decision $d -DomainName 'corp.example' -Dc 'dc01.corp.example' `
            -Wired ([pscustomobject]@{ Up = $true; DomainAuthenticated = $true }) -DirectAccessStatus 'NotAvailable' `
            -Wlan @([pscustomobject]@{ Ssid = 'CORP'; DomainAuthenticated = $false }, [pscustomobject]@{ Ssid = ''; DomainAuthenticated = $true }) -Allow 'Lan', 'DirectAccess'
        $l | Should -Be 'RESULT=LAN EXIT=0 DOMAIN=corp.example DC=dc01.corp.example LAN=DomainAuthenticated DA=NotAvailable WLAN="CORP;?(DomainAuthenticated)" ALLOW=Lan,DirectAccess REASON="Allowed path LAN, domain reachable."'
    }
    It 'stays one line for an error with line breaks and quotes, with unknown fields as -' {
        $d = [pscustomobject]@{ ExitCode = 1; Result = 'ERROR'; Reason = "Unexpected error: line one`r`nline ""two""" }
        $l = Format-ResultLine -Decision $d
        $l | Should -Not -Match "[`r`n]"
        $l | Should -Be 'RESULT=ERROR EXIT=1 DOMAIN=- DC=none LAN=- DA=- WLAN="-" ALLOW= REASON="Unexpected error: line one line ''two''"'
    }
    It 'shows WLAN=none and LAN=None when nothing is connected' {
        $d = [pscustomobject]@{ ExitCode = 21; Result = 'NONE'; Reason = 'No domain connectivity.' }
        $l = Format-ResultLine -Decision $d -DomainName 'corp.example' -Wired ([pscustomobject]@{ Up = $false; DomainAuthenticated = $false }) -DirectAccessStatus 'Error' -Wlan @() -Allow 'Lan'
        $l | Should -Match ' LAN=None DA=Error WLAN="none" '
    }
}

Describe 'Get-AdapterKind' {
    It '<Label> -> <Expect>' -ForEach $KindCases {
        Get-AdapterKind -Adapter ([pscustomobject]@{ NdisPhysicalMedium = $Phys; PhysicalMediaType = $PhysType; MediaType = $Media }) | Should -Be $Expect
    }
}

Describe 'Get-MachineDomain' {
    It 'returns the domain of a domain member' {
        Mock Get-CimInstance { [pscustomobject]@{ PartOfDomain = $true; Domain = 'corp.example' } }
        Get-MachineDomain | Should -Be 'corp.example'
    }
    It 'returns an empty string in a workgroup' {
        Mock Get-CimInstance { [pscustomobject]@{ PartOfDomain = $false; Domain = 'WORKGROUP' } }
        Get-MachineDomain | Should -Be ''
    }
    It 'returns an empty string when Get-CimInstance does not exist' {
        Mock Get-CimInstance { throw (New-CnfException 'Get-CimInstance') }
        Get-MachineDomain | Should -Be ''
    }
}

Describe 'Get-WiredDomainState (mocked Get-NetAdapter / Get-NetConnectionProfile)' {
    BeforeEach {
        Mock Get-NetAdapter {
            New-Adapter -Name 'Ethernet' -Index 5
            New-Adapter -Name 'WLAN' -Index 7 -Phys 9 -PhysType 'Native 802.11'
            New-Adapter -Name 'Ethernet 2' -Index 9 -Status 'Disconnected'
        }
    }
    It 'domain-authenticated wired adapter; WLAN and disconnected adapters are not queried' {
        Mock Get-NetConnectionProfile { [pscustomobject]@{ Name = 'corp.example'; NetworkCategory = 'DomainAuthenticated' } } -ParameterFilter { $InterfaceIndex -eq 5 }
        Mock Get-NetConnectionProfile { throw 'must not be queried' }
        $s = Get-WiredDomainState
        $s.Up | Should -BeTrue
        $s.DomainAuthenticated | Should -BeTrue
        $s.Adapters | Should -Be @('Ethernet')
        Should -Invoke Get-NetConnectionProfile -Times 1 -Exactly
    }
    It 'wired adapter in a foreign network (Public/Private profile)' {
        Mock Get-NetConnectionProfile { [pscustomobject]@{ Name = 'Network 3'; NetworkCategory = 'Public' } }
        $s = Get-WiredDomainState
        $s.Up | Should -BeTrue
        $s.DomainAuthenticated | Should -BeFalse
    }
    It 'wired adapter without a profile yet (network being identified)' {
        Mock Get-NetConnectionProfile { }
        $s = Get-WiredDomainState
        $s.Up | Should -BeTrue
        $s.DomainAuthenticated | Should -BeFalse
    }
    It 'one of two profiles on the interface is DomainAuthenticated' {
        Mock Get-NetConnectionProfile { [pscustomobject]@{ NetworkCategory = 'Private' }; [pscustomobject]@{ NetworkCategory = 'DomainAuthenticated' } }
        (Get-WiredDomainState).DomainAuthenticated | Should -BeTrue
    }
    It 'USB/dock adapter with unspecified physical medium counts as wired' {
        Mock Get-NetAdapter { New-Adapter -Name 'USB LAN' -Index 12 -Phys 0 -PhysType 'Unspecified' }
        Mock Get-NetConnectionProfile { [pscustomobject]@{ NetworkCategory = 'DomainAuthenticated' } }
        (Get-WiredDomainState).DomainAuthenticated | Should -BeTrue
    }
    It 'domain-authenticated WLAN does not count as wired' {
        Mock Get-NetAdapter { New-Adapter -Name 'WLAN' -Index 7 -Phys 9 -PhysType 'Native 802.11' }
        Mock Get-NetConnectionProfile { [pscustomobject]@{ NetworkCategory = 'DomainAuthenticated' } }
        $s = Get-WiredDomainState
        $s.Up | Should -BeFalse
        $s.DomainAuthenticated | Should -BeFalse
    }
    It 'no adapter at all' {
        Mock Get-NetAdapter { }
        (Get-WiredDomainState).Up | Should -BeFalse
    }
    It 'Get-NetAdapter does not exist: no wired path' {
        Mock Get-NetAdapter { throw (New-CnfException 'Get-NetAdapter') }
        (Get-WiredDomainState).Up | Should -BeFalse
    }
    It 'other errors of Get-NetAdapter are passed on (script: exit 1)' {
        Mock Get-NetAdapter { throw 'CIM failure' }
        { Get-WiredDomainState } | Should -Throw '*CIM failure*'
    }
}

Describe 'Get-DirectAccessState (mocked Get-DAConnectionStatus)' {
    It 'returns the status, e.g. ConnectedRemotely' {
        Mock Get-DAConnectionStatus { [pscustomobject]@{ Status = 'ConnectedRemotely'; Substatus = 'None' } }
        Get-DirectAccessState | Should -Be 'ConnectedRemotely'
    }
    It 'ConnectedLocally is passed through unchanged' {
        Mock Get-DAConnectionStatus { [pscustomobject]@{ Status = 'ConnectedLocally' } }
        Get-DirectAccessState | Should -Be 'ConnectedLocally'
    }
    It 'cmdlet does not exist -> NotAvailable' {
        Mock Get-DAConnectionStatus { throw (New-CnfException 'Get-DAConnectionStatus') }
        Get-DirectAccessState | Should -Be 'NotAvailable'
    }
    It 'cmdlet fails (no DA client, service stopped) -> NotConfigured' {
        Mock Get-DAConnectionStatus { throw 'The DirectAccess client is not configured.' }
        Get-DirectAccessState | Should -Be 'NotConfigured'
    }
    It 'empty status -> Unknown' {
        Mock Get-DAConnectionStatus { [pscustomobject]@{ Status = $null } }
        Get-DirectAccessState | Should -Be 'Unknown'
    }
}

Describe 'Get-WlanSsid (WinRT with fallback)' {
    It 'uses WinRT when it returns connections; no fallback' {
        Mock Get-WinRtWlanConnection { [pscustomobject]@{ Ssid = 'CORP-WLAN'; DomainAuthenticated = $true; Source = 'WinRT' } }
        Mock Get-ProfileWlanConnection { throw 'must not be called' }
        $w = @(Get-WlanSsid)
        $w.Count | Should -Be 1
        $w[0].Ssid | Should -Be 'CORP-WLAN'
        Should -Invoke Get-ProfileWlanConnection -Times 0 -Exactly
    }
    It 'falls back to the connection profile when WinRT is not available' {
        Mock Get-WinRtWlanConnection { throw 'Unable to find type [Windows.Networking.Connectivity.NetworkInformation]' }
        Mock Get-ProfileWlanConnection { [pscustomobject]@{ Ssid = 'HomeNet'; DomainAuthenticated = $false; Source = 'ConnectionProfile' } }
        (@(Get-WlanSsid))[0].Source | Should -Be 'ConnectionProfile'
    }
    It 'falls back when WinRT returns no WLAN connection' {
        Mock Get-WinRtWlanConnection { }
        Mock Get-ProfileWlanConnection { }
        @(Get-WlanSsid).Count | Should -Be 0
        Should -Invoke Get-ProfileWlanConnection -Times 1 -Exactly
    }
}

Describe 'Get-ProfileWlanConnection (mocked Get-NetAdapter / Get-NetConnectionProfile)' {
    BeforeEach {
        Mock Get-NetAdapter {
            New-Adapter -Name 'Ethernet' -Index 5
            New-Adapter -Name 'WLAN' -Index 7 -Phys 9 -PhysType 'Native 802.11'
        }
    }
    It 'reads the profile name as SSID, only for the WLAN adapter' {
        Mock Get-NetConnectionProfile { [pscustomobject]@{ Name = 'HomeNet'; NetworkCategory = 'Private' } } -ParameterFilter { $InterfaceIndex -eq 7 }
        Mock Get-NetConnectionProfile { throw 'must not be queried' }
        $w = @(Get-ProfileWlanConnection)
        $w.Count | Should -Be 1
        $w[0].Ssid | Should -Be 'HomeNet'
        $w[0].DomainAuthenticated | Should -BeFalse
    }
    It 'domain network: name is the domain name, but DomainAuthenticated is set' {
        Mock Get-NetConnectionProfile { [pscustomobject]@{ Name = 'corp.example'; NetworkCategory = 'DomainAuthenticated' } }
        $w = @(Get-ProfileWlanConnection)
        $w[0].Ssid | Should -Be 'corp.example'
        $w[0].DomainAuthenticated | Should -BeTrue
    }
    It 'WLAN adapter up without a profile yields an entry without SSID' {
        Mock Get-NetConnectionProfile { }
        $w = @(Get-ProfileWlanConnection)
        $w.Count | Should -Be 1
        $w[0].Ssid | Should -Be ''
    }
    It 'Get-NetAdapter does not exist: no entries' {
        Mock Get-NetAdapter { throw (New-CnfException 'Get-NetAdapter') }
        @(Get-ProfileWlanConnection).Count | Should -Be 0
    }
}

Describe 'Get-WinRtWlanConnection' {
    It 'throws where WinRT is not available (PowerShell 7, Linux), so Get-WlanSsid falls back' -Skip:($PSVersionTable.PSEdition -eq 'Desktop') {
        { @(Get-WinRtWlanConnection) } | Should -Throw
    }
    It 'runs without error in Windows PowerShell 5.1 (real WinRT call)' -Skip:($PSVersionTable.PSEdition -ne 'Desktop') {
        { $script:winrt = @(Get-WinRtWlanConnection) } | Should -Not -Throw
        foreach ($c in $script:winrt) { $c.PSObject.Properties.Name | Should -Contain 'Ssid' }
    }
}

Describe 'Test-DomainReachable (mocked Resolve-DnsName / Resolve-HostAddress / Test-TcpPort)' {
    BeforeEach {
        Mock Resolve-DnsName {
            [pscustomobject]@{ Name = $Name; Type = 'SRV'; NameTarget = 'dc2.corp.example'; Priority = 10; Weight = 100; Port = 389 }
            [pscustomobject]@{ Name = $Name; Type = 'SRV'; NameTarget = 'dc1.corp.example'; Priority = 0;  Weight = 50;  Port = 389 }
            [pscustomobject]@{ Name = $Name; Type = 'SRV'; NameTarget = 'dc3.corp.example'; Priority = 0;  Weight = 100; Port = 389 }
            [pscustomobject]@{ Name = 'dc1.corp.example'; Type = 'A'; IPAddress = '192.0.2.10' }   # additional record
        }
        # One address per DC by default (default mock without a parameter filter, as Pester 6 requires)
        Mock Resolve-HostAddress { [System.Net.IPAddress]::Parse('192.0.2.1') }
    }
    It 'queries the DC SRV record of the domain and tries DCs by priority, then weight' {
        Mock Test-TcpPort { $ComputerName -eq 'dc1.corp.example' }
        $r = Test-DomainReachable -DomainName 'corp.example'
        $r.Reachable | Should -BeTrue
        $r.DnsOk | Should -BeTrue
        $r.Dc | Should -Be 'dc1.corp.example'
        Should -Invoke Resolve-DnsName -Times 1 -Exactly -ParameterFilter { $Name -eq '_ldap._tcp.dc._msdcs.corp.example' -and $Type -eq 'SRV' }
        Should -Invoke Test-TcpPort -Times 1 -Exactly -ParameterFilter { $ComputerName -eq 'dc3.corp.example' -and $Port -eq 389 }
        Should -Invoke Test-TcpPort -Times 0 -Exactly -ParameterFilter { $ComputerName -eq 'dc2.corp.example' }
    }
    It 'no DC answers on port 389' {
        Mock Test-TcpPort { $false }
        $r = Test-DomainReachable -DomainName 'corp.example'
        $r.Reachable | Should -BeFalse
        $r.DnsOk | Should -BeTrue
        $r.Error | Should -Match 'port 389'
        Should -Invoke Test-TcpPort -Times 3 -Exactly
    }
    It 'tries at most -MaxDc DCs' {
        Mock Test-TcpPort { $false }
        $null = Test-DomainReachable -DomainName 'corp.example' -MaxDc 2
        Should -Invoke Test-TcpPort -Times 2 -Exactly
    }
    It 'DNS lookup fails (offline, foreign DNS)' {
        Mock Resolve-DnsName { throw 'DNS name does not exist' }
        Mock Test-TcpPort { $true }
        $r = Test-DomainReachable -DomainName 'corp.example'
        $r.Reachable | Should -BeFalse
        $r.DnsOk | Should -BeFalse
        $r.Error | Should -Match 'DNS SRV lookup'
        Should -Invoke Test-TcpPort -Times 0 -Exactly
    }
    It 'tries every address of a DC (IPv6 first, then IPv4) with the address list handed to Test-TcpPort' {
        Mock Resolve-HostAddress {
            [System.Net.IPAddress]::Parse('2001:db8::10')
            [System.Net.IPAddress]::Parse('fd00::10')
            [System.Net.IPAddress]::Parse('192.0.2.10')
        }
        Mock Test-TcpPort { @($Address | Where-Object { $_.AddressFamily -eq 'InterNetwork' }).Count -gt 0 }
        $r = Test-DomainReachable -DomainName 'corp.example'
        $r.Reachable | Should -BeTrue
        $r.Dc | Should -Be 'dc3.corp.example'
        Should -Invoke Test-TcpPort -Times 1 -Exactly -ParameterFilter { @($Address).Count -eq 3 -and $MaxAttempts -eq 3 }
    }
    It 'caps the connection attempts at -MaxAttempts across all DCs' {
        Mock Resolve-HostAddress {
            [System.Net.IPAddress]::Parse('2001:db8::10')
            [System.Net.IPAddress]::Parse('fd00::10')
            [System.Net.IPAddress]::Parse('192.0.2.10')
            [System.Net.IPAddress]::Parse('192.0.2.11')
        }
        Mock Test-TcpPort { $false }
        $r = Test-DomainReachable -DomainName 'corp.example'
        $r.Reachable | Should -BeFalse
        # dc3: 4 addresses, dc1: the remaining 2 of 6, dc2: none left
        Should -Invoke Test-TcpPort -Times 1 -Exactly -ParameterFilter { $ComputerName -eq 'dc3.corp.example' -and @($Address).Count -eq 4 }
        Should -Invoke Test-TcpPort -Times 1 -Exactly -ParameterFilter { $ComputerName -eq 'dc1.corp.example' -and @($Address).Count -eq 2 }
        Should -Invoke Test-TcpPort -Times 0 -Exactly -ParameterFilter { $ComputerName -eq 'dc2.corp.example' }
    }
    It 'skips a DC whose name cannot be resolved' {
        Mock Resolve-HostAddress { throw 'No such host is known' } -ParameterFilter { $ComputerName -eq 'dc3.corp.example' }
        Mock Test-TcpPort { $true }
        $r = Test-DomainReachable -DomainName 'corp.example'
        $r.Dc | Should -Be 'dc1.corp.example'
        Should -Invoke Test-TcpPort -Times 0 -Exactly -ParameterFilter { $ComputerName -eq 'dc3.corp.example' }
    }
    It 'DNS answer without SRV records' {
        Mock Resolve-DnsName { [pscustomobject]@{ Type = 'SOA'; PrimaryServer = 'ns.example' } }
        $r = Test-DomainReachable -DomainName 'corp.example'
        $r.DnsOk | Should -BeFalse
        $r.Error | Should -Match 'no DC'
    }
}

Describe 'Resolve-HostAddress' {
    It 'returns distinct addresses' {
        $a = @(Resolve-HostAddress -ComputerName '127.0.0.1')
        $a.Count | Should -Be 1
        $a[0].ToString() | Should -Be '127.0.0.1'
    }
    It 'throws for a name that cannot be resolved' {
        $unknown = 'no-such-host.invalid'
        { Resolve-HostAddress -ComputerName $unknown } | Should -Throw
    }
}

Describe 'Test-TcpPort (mocked Resolve-HostAddress)' {
    BeforeAll { $dcName = 'dc.example' }
    It 'tries each distinct address with its own address family, at most -MaxAttempts' {
        Mock Resolve-HostAddress {
            [System.Net.IPAddress]::Parse('::1')
            [System.Net.IPAddress]::Parse('127.0.0.1')
        }
        $listener = New-Object System.Net.Sockets.TcpListener -ArgumentList ([System.Net.IPAddress]::Loopback), 0
        $listener.Start()
        try {
            $port = $listener.LocalEndpoint.Port
            # ::1 is not listening (IPv4 listener only): the IPv4 address must still be tried
            Test-TcpPort -ComputerName $dcName -Port $port -TimeoutMs 2000 | Should -BeTrue
            Test-TcpPort -ComputerName $dcName -Port $port -TimeoutMs 2000 -MaxAttempts 1 | Should -BeFalse
        }
        finally { $listener.Stop() }
    }
    It 'uses -Address without resolving the name' {
        Mock Resolve-HostAddress { throw 'must not be called' }
        $listener = New-Object System.Net.Sockets.TcpListener -ArgumentList ([System.Net.IPAddress]::Loopback), 0
        $listener.Start()
        try {
            $port = $listener.LocalEndpoint.Port
            Test-TcpPort -ComputerName $dcName -Port $port -TimeoutMs 2000 -Address @([System.Net.IPAddress]::Loopback) | Should -BeTrue
        }
        finally { $listener.Stop() }
        Should -Invoke Resolve-HostAddress -Times 0 -Exactly
    }
}

Describe 'Test-TcpPort (local listener)' {
    It 'true for an open port, false for a closed one' {
        $listener = New-Object System.Net.Sockets.TcpListener -ArgumentList ([System.Net.IPAddress]::Loopback), 0
        $listener.Start()
        try {
            $port = $listener.LocalEndpoint.Port
            Test-TcpPort -ComputerName '127.0.0.1' -Port $port -TimeoutMs 2000 | Should -BeTrue
        }
        finally { $listener.Stop() }
        Test-TcpPort -ComputerName '127.0.0.1' -Port $port -TimeoutMs 2000 | Should -BeFalse
    }
}

Describe 'Script run in a child process' {
    BeforeAll {
        $exe = (Get-Process -Id $PID).Path
        function Invoke-Gate { param([string[]]$Arguments)
            # Windows PowerShell 5.1 turns stderr output of a native command into an error record, which
            # throws under ErrorActionPreference Stop. The test only checks stdout and the exit code.
            $ErrorActionPreference = 'Continue'
            $out = & $exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $GatePath @Arguments 2>$null
            [pscustomobject]@{ Out = @($out); Exit = $LASTEXITCODE }
        }
    }
    It 'prints exactly one result line and ends with a gate exit code (domain that does not exist)' {
        $r = Invoke-Gate -Arguments '-DomainName', 'gate-test.invalid', '-Allow', 'Lan,DirectAccess'
        $r.Out.Count | Should -Be 1
        $r.Out[0] | Should -Match '^RESULT=(LAN|DIRECTACCESS|WLAN|OTHER|NONE) EXIT=(20|21|22) DOMAIN=gate-test\.invalid '
        $r.Exit | Should -BeIn @(20, 21, 22)
        $r.Out[0] | Should -Match "EXIT=$($r.Exit) "
    }
    It '-Quiet prints nothing' {
        $r = Invoke-Gate -Arguments '-DomainName', 'gate-test.invalid', '-Quiet'
        $r.Out.Count | Should -Be 0
        $r.Exit | Should -BeIn @(20, 21, 22)
    }
    It 'rejects an invalid -Allow value' {
        $r = Invoke-Gate -Arguments '-Allow', 'Lan,Foo'
        $r.Exit | Should -Not -Be 0
        $r.Exit | Should -Not -BeIn @(20, 21, 22)
    }
}
