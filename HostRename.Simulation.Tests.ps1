<#
.SYNOPSIS
    HostRename - end-to-end simulation of the ACMP Client Command with the real scripts in a simulated environment.

.DESCRIPTION
    Runs the real scripts as a whole (Invoke-HostRename.ps1, Test-DeploymentNetwork.ps1,
    Update-ComputerCertificate.ps1) and the two documented snippets (state check from docs/acmp-guide.md,
    section 4, step 1, and status script from docs/acmp-rollout.md, section 4.3; both are extracted from the
    Markdown at test time), chained like the ACMP Client Command in docs/acmp-guide.md, section 4, across all
    phases of a device. The wrapper Invoke-AcmpHostRename.ps1, which implements that Client Command in one
    script run, is run the same way (scenarios W1 to W9).

    The environment is simulated: registry (HKLM, in memory), computer name (active and pending), CIM classes
    (domain, serial numbers), AD (computer objects, delegation), network paths (LAN, DirectAccess, corporate WLAN,
    offline), the machine certificate store and the CA. All scripts run from copies in TestDrive. Nothing changes
    the real machine: no rename, no HKLM write, no reboot, no certificate request, no scheduled task change; file
    system writes are only allowed inside TestDrive. Before every script run, the harness checks that every
    command that could change the machine resolves to its mock, and stops otherwise.

    This is a simulation: it shows that the scripts and the documented flow fit together. It does not replace the
    device tests (docs/test-plan.md, docs/acmp-rollout.md section 5): real AD, DNS, ACLs, WinRT, certificate
    enrollment and ACMP itself are not involved.

    SCENARIOS
      S1  LAN device, template DE{Serial}, -NoCentralLog: dry run, rename, rerun before the reboot, reboot,
          cleanup, done; status phases Open > RebootPending > AfterReboot > Done; then a different template
      S2  DirectAccess device (gate RESULT=DIRECTACCESS), with -Reboot passed anyway (REBOOT_IGNORED)
      S3  WLAN user: rename over LAN, certificate before the reboot fails (rename pending), after the reboot on
          WLAN only the gate waits (20), then on LAN: certificate RENEWED with -RemoveOld, cleanup
      S4  corporate WLAN only (gate 20, nothing runs), then cable
      S5  offline (gate 21, nothing runs), then LAN
      S6  no delegation (exit 4, permanent, never renamed)
      S7  target name already taken in AD (future ID)
      S8  unusable serial number (future ID, or exit 5 with -OnSerialProblem Skip)
      S9  name already matches the template (exit 0, no reboot, cleanup in the same run)
      S10 GPO regression: -Deployment Gpo removes task and script copy, Acmp never does
      S11 32-bit process on 64-bit Windows (PLATFORM, nothing written)
      S12 local folder prepared by a standard user (LOCAL_DIR), then removed by an administrator

      Wrapper Invoke-AcmpHostRename.ps1 (the whole Client Command in one script run per ACMP invocation;
      every run checks the summary line HOSTRENAME PHASE=... EXIT=... STEP=... MESSAGE="..." as the last line):
      W1  LAN: dry run, 3010, 3010 again before the reboot, reboot, 0 done (marker), then 0 at the state check
      W2  corporate WLAN only (20, lists as one string each), then cable (3010)
      W3  offline (21)
      W4  no delegation (4), rerun 4 at the state check (permanent), release + delegation -> 3010
      W5  WLAN user with -CertificateTemplate: CA denies (1, no cleanup), then RENEWED and cleanup (0)
      W6  name already matches the template (0, cleanup in the same run)
      W7  parameter errors (log choice missing, blank or twice; -RemoveOldCertificates alone), missing script
      W8  32-bit process on 64-bit Windows (PLATFORM, nothing runs or is written)
      W9  -WhatIf after the reboot with certificate template (nothing written, no certificate, no cleanup)
      plus structural checks of the wrapper (parses, single exit point, scripts it calls)

.PARAMETER ScriptFolder
    Folder containing the scripts and docs (default: the folder of this test file).

.EXAMPLE
    Invoke-Pester -Path .\HostRename.Simulation.Tests.ps1 -Output Detailed

.NOTES
    Product          HostRename
    Version          1.2.0
    Date             2026-11-03
    Execution        Any platform with Pester 5.3+ (no administrator rights needed)
    Encoding         UTF-8 with BOM (required for Windows PowerShell 5.1)

.LINK
    docs/acmp-guide.md
#>
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.3.0' }
#Requires -Version 5.1
param(
    [string]$ScriptFolder = ''
)

BeforeAll {
    $ScriptFolder = if ($ScriptFolder) { $ScriptFolder } else { $PSScriptRoot }
    $script:Src = @{
        Invoke     = Join-Path $ScriptFolder 'Invoke-HostRename.ps1'
        Gate       = Join-Path $ScriptFolder 'Test-DeploymentNetwork.ps1'
        Cert       = Join-Path $ScriptFolder 'Update-ComputerCertificate.ps1'
        Wrapper    = Join-Path $ScriptFolder 'Invoke-AcmpHostRename.ps1'
        Guide      = Join-Path $ScriptFolder 'docs/acmp-guide.md'
        Rollout    = Join-Path $ScriptFolder 'docs/acmp-rollout.md'
        GuideDe    = Join-Path $ScriptFolder 'docs/de/acmp-anleitung.md'
        RolloutDe  = Join-Path $ScriptFolder 'docs/de/acmp-rollout.md'
    }
    $script:ScriptVersion = [regex]::Match([System.IO.File]::ReadAllText($script:Src.Invoke), "(?m)^\`$ScriptVersion\s*=\s*'([^']+)'").Groups[1].Value

    # ---- Documented snippets (extracted from the Markdown, so the documented code is what is tested) ----------
    function Get-MarkdownCodeBlock {
        # First ```powershell block after the first heading that matches $Heading.
        param([string]$Path, [string]$Heading)
        $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
        $h = [regex]::Match($text, "(?m)^#{2,4} [^\r\n]*$Heading")
        if (-not $h.Success) { throw "Heading '$Heading' not found in $Path" }
        $m = [regex]::Match($text.Substring($h.Index), '(?s)```powershell\r?\n(.*?)\r?\n```')
        if (-not $m.Success) { throw "No powershell block after '$Heading' in $Path" }
        $m.Groups[1].Value
    }
    function Remove-CodeComment {
        # Code without comments and blank lines (to compare the English and German snippets)
        param([string]$Code)
        @($Code -split '\r?\n' | ForEach-Object { ($_ -replace '(^|\s+)#.*$', '').TrimEnd() } | Where-Object { $_ }) -join "`n"
    }
    $script:StateCheckCode = Get-MarkdownCodeBlock -Path $script:Src.Guide -Heading 'Step 1: state check'
    $script:StatusCode     = Get-MarkdownCodeBlock -Path $script:Src.Rollout -Heading '4\.3 Status script'

    # ---- Script functions that are mocked: the real definitions give the mocks their parameters ---------------
    # (Pester can only mock a command that exists. The alias Pester creates wins over the function the script
    # defines when it runs, so the mock applies inside the script.)
    function Get-ScriptFunctionText {
        param([string]$Path, [string[]]$Name)
        $tk = $null; $er = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tk, [ref]$er)
        $fns = @($ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $Name -contains $a.Name }, $true))
        $missing = @($Name | Where-Object { @($fns.Name) -notcontains $_ })
        if ($missing.Count) { throw "Functions not found in ${Path}: $($missing -join ', ')" }
        ($fns | ForEach-Object { $_.Extent.Text }) -join "`n"
    }
    . ([scriptblock]::Create((Get-ScriptFunctionText -Path $script:Src.Invoke -Name @(
        'Test-AdComputerExists', 'Test-AdRenamePermission', 'Test-Wow64Process', 'Get-OwnerSid', 'Set-LocalDirAcl', 'New-FutureId'))))
    . ([scriptblock]::Create((Get-ScriptFunctionText -Path $script:Src.Gate -Name @(
        'Get-WinRtWlanConnection', 'Resolve-HostAddress', 'Test-TcpPort'))))
    . ([scriptblock]::Create((Get-ScriptFunctionText -Path $script:Src.Cert -Name @(
        'Get-MachineCertificate', 'Remove-MachineCertificate', 'Resolve-TemplateOid', 'Request-TemplateCertificate'))))

    # ---- Stubs for Windows-only commands (only where they do not exist; they are mocked below) -----------------
    if (-not (Get-Command Get-CimInstance -ErrorAction SilentlyContinue)) { function Get-CimInstance { [CmdletBinding()] param([string]$ClassName) } }
    if (-not (Get-Command Rename-Computer -ErrorAction SilentlyContinue)) { function Rename-Computer { [CmdletBinding(SupportsShouldProcess)] param([string]$NewName, [switch]$Force, [pscredential]$DomainCredential) } }
    if (-not (Get-Command Test-ComputerSecureChannel -ErrorAction SilentlyContinue)) { function Test-ComputerSecureChannel { [CmdletBinding()] param() } }
    if (-not (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue)) { function Get-ScheduledTask { [CmdletBinding()] param([string]$TaskName) } }
    if (-not (Get-Command Unregister-ScheduledTask -ErrorAction SilentlyContinue)) { function Unregister-ScheduledTask { [CmdletBinding(SupportsShouldProcess)] param([string]$TaskName) } }
    if (-not (Get-Command Get-NetAdapter -ErrorAction SilentlyContinue)) { function Get-NetAdapter { [CmdletBinding()] param([switch]$Physical) } }
    if (-not (Get-Command Get-NetConnectionProfile -ErrorAction SilentlyContinue)) { function Get-NetConnectionProfile { [CmdletBinding()] param([int]$InterfaceIndex) } }
    if (-not (Get-Command Get-DAConnectionStatus -ErrorAction SilentlyContinue)) { function Get-DAConnectionStatus { [CmdletBinding()] param() } }
    if (-not (Get-Command Resolve-DnsName -ErrorAction SilentlyContinue)) { function Resolve-DnsName { [CmdletBinding()] param([string]$Name, [string]$Type, [switch]$DnsOnly, [switch]$QuickTimeout) } }
    # -Type is a dynamic parameter of the registry provider (missing off-Windows): own stub with the full signature
    function Set-ItemProperty { param($Path, $Name, $Value, $Type) }
    # External programs: a function wins over the .exe, so none of them can ever run from a simulated script
    function shutdown.exe { $global:HRSim.ShutdownCalls.Add(($args -join ' ')) }
    function nltest.exe { $global:HRSim.ExeCalls.Add('nltest ' + ($args -join ' ')); $global:LASTEXITCODE = 1 }
    function icacls.exe { $global:HRSim.ExeCalls.Add('icacls ' + ($args -join ' ')); $global:LASTEXITCODE = 0 }

    # Commands that could change the machine (or read real state) and must resolve to their mock in every run
    $script:GuardedCommands = @(
        'Rename-Computer', 'Set-ItemProperty', 'New-Item', 'Remove-Item', 'Get-ItemProperty', 'Test-Path',
        'Get-ScheduledTask', 'Unregister-ScheduledTask', 'Get-CimInstance', 'Test-ComputerSecureChannel', 'Start-Sleep',
        'Test-AdComputerExists', 'Test-AdRenamePermission', 'Test-Wow64Process', 'Get-OwnerSid', 'Set-LocalDirAcl',
        'Get-NetAdapter', 'Get-NetConnectionProfile', 'Get-DAConnectionStatus', 'Resolve-DnsName',
        'Get-WinRtWlanConnection', 'Resolve-HostAddress', 'Test-TcpPort',
        'Get-MachineCertificate', 'Remove-MachineCertificate', 'Resolve-TemplateOid', 'Request-TemplateCertificate')
    function Assert-SimMocks {
        foreach ($n in $script:GuardedCommands) {
            $c = @(Get-Command $n -ErrorAction SilentlyContinue)[0]
            if (-not $c -or $c.CommandType -ne 'Alias') { throw "Simulation stopped: '$n' does not resolve to its mock (found: $($c.CommandType))." }
        }
        foreach ($n in 'shutdown.exe', 'nltest.exe', 'icacls.exe') {
            if (@(Get-Command $n -ErrorAction SilentlyContinue)[0].CommandType -ne 'Function') { throw "Simulation stopped: '$n' would run the real program." }
        }
    }

    # ---- Simulated registry (HKLM in memory) -------------------------------------------------------------------
    function Test-SimRegistryPath {
        param($Path)
        [string](@($Path)[0]) -match '^(HKLM:|HKCU:|HKEY_|Registry::|Microsoft\.PowerShell\.Core\\Registry::)'
    }
    function ConvertTo-SimRegKey {
        param([string]$Path)
        $k = $Path -replace '^Microsoft\.PowerShell\.Core\\Registry::', '' -replace '^Registry::', '' -replace '^HKEY_LOCAL_MACHINE', 'HKLM:'
        if ($k -notmatch '^HKLM:') { throw "Simulation: registry path outside HKLM is not expected: $Path" }
        $k = $k.TrimEnd('\')
        if ($k -eq 'HKLM:') { $k = 'HKLM:\' }
        $k -replace '\\{2,}', '\'
    }
    function Get-SimRegKey {
        # Values of a key (hashtable, case-insensitive) or $null if the key does not exist
        param([string]$Path)
        $k = ConvertTo-SimRegKey $Path
        if ($global:HRSim.Registry.ContainsKey($k)) { return , $global:HRSim.Registry[$k] }
        return $null
    }
    function Test-SimRegKey {
        param([string]$Path)
        $k = ConvertTo-SimRegKey $Path
        if ($global:HRSim.Registry.ContainsKey($k)) { return $true }
        foreach ($existing in @($global:HRSim.Registry.Keys)) { if ($existing.StartsWith("$k\", [StringComparison]::OrdinalIgnoreCase)) { return $true } }
        return $false
    }
    function Assert-SimFileSystemPath {
        # Writes and deletions outside HKLM are only allowed inside the scenario folder in TestDrive
        param([string[]]$Path, [string]$Command)
        # (prefix or sentinel file in a parent folder: TestDrive may be given as an 8.3 short path on Windows)
        foreach ($p in $Path) {
            $full = [System.IO.Path]::GetFullPath($p)
            $inside = $full.StartsWith($global:HRSim.Root, [StringComparison]::OrdinalIgnoreCase)
            $d = $full
            while (-not $inside -and $d) {
                $inside = [System.IO.File]::Exists([System.IO.Path]::Combine($d, $global:HRSim.Sentinel))
                $d = [System.IO.Path]::GetDirectoryName($d)
            }
            if (-not $inside) { throw "Simulation: $Command outside the simulation folder refused: $p" }
        }
    }
    function Get-SimActiveName  { [string](Get-SimRegKey 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName').ComputerName }
    function Get-SimPendingName { [string](Get-SimRegKey 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName').ComputerName }
    function Get-SimState  { Get-SimRegKey 'HKLM:\SOFTWARE\HostRenameState' }
    function Get-SimMarker { Get-SimRegKey 'HKLM:\SOFTWARE\HostRename' }

    # ---- Test certificates (same construction as HostRename.Certificate.Tests.ps1) --------------------------------
    function New-SimCertificate {
        param([string[]]$DnsName, [string]$TemplateName, [int]$NotAfterDays = 365)
        $key = [System.Security.Cryptography.ECDsa]::Create([System.Security.Cryptography.ECCurve+NamedCurves]::nistP256)
        $req = New-Object System.Security.Cryptography.X509Certificates.CertificateRequest("CN=$($DnsName[0])", $key, [System.Security.Cryptography.HashAlgorithmName]::SHA256)
        $san = New-Object System.Security.Cryptography.X509Certificates.SubjectAlternativeNameBuilder
        foreach ($n in $DnsName) { $san.AddDnsName($n) }
        $req.CertificateExtensions.Add($san.Build($false))
        $nameBytes = [System.Text.Encoding]::BigEndianUnicode.GetBytes($TemplateName)   # 1.3.6.1.4.1.311.20.2 as BMPString
        $ext = [byte[]](@([byte]0x1E, [byte]$nameBytes.Length) + $nameBytes)
        $req.CertificateExtensions.Add((New-Object System.Security.Cryptography.X509Certificates.X509Extension('1.3.6.1.4.1.311.20.2', $ext, $false)))
        $now = [DateTimeOffset]::Now
        $req.CreateSelfSigned($now.AddDays(-1), $now.AddDays($NotAfterDays))
    }

    # ---- Device and environment ---------------------------------------------------------------------------------
    $global:HRSimSavedEnv = @{ COMPUTERNAME = $env:COMPUTERNAME; ProgramData = $env:ProgramData }

    function New-SimDevice {
        # Fresh simulated device in its own folder under TestDrive; sets $env:COMPUTERNAME and $env:ProgramData.
        param(
            [Parameter(Mandatory)][string]$Root,
            [string]$Name = 'PC349219',
            [string]$BiosSerial = 'SIM4711AB',
            [string]$ProductSerial = 'SIM4711AB',
            [string]$BoardSerial = 'BRD0815XY',
            [string]$Network = 'Lan',
            [string[]]$OtherAdObjects = @(),
            [bool]$Delegation = $true,
            [string]$Domain = 'sim.invalid'
        )
        $Root = [System.IO.Path]::GetFullPath($Root)
        foreach ($d in 'ProgramData', 'AcmpCache') { [void][System.IO.Directory]::CreateDirectory((Join-Path $Root $d)) }
        $sentinel = '.hostrename-simulation-root'
        [System.IO.File]::WriteAllText((Join-Path $Root $sentinel), '')
        $cache = Join-Path $Root 'AcmpCache'
        $paths = @{
            Invoke     = Join-Path $cache 'Invoke-HostRename.ps1'
            Gate       = Join-Path $cache 'Test-DeploymentNetwork.ps1'
            Cert       = Join-Path $cache 'Update-ComputerCertificate.ps1'
            Wrapper    = Join-Path $cache 'Invoke-AcmpHostRename.ps1'
            StateCheck = Join-Path $cache 'StateCheck.ps1'
            Status     = Join-Path $cache 'Status.ps1'
        }
        [System.IO.File]::Copy($script:Src.Invoke, $paths.Invoke, $true)
        [System.IO.File]::Copy($script:Src.Gate, $paths.Gate, $true)
        [System.IO.File]::Copy($script:Src.Cert, $paths.Cert, $true)
        [System.IO.File]::Copy($script:Src.Wrapper, $paths.Wrapper, $true)
        $utf8Bom = New-Object System.Text.UTF8Encoding($true)
        [System.IO.File]::WriteAllText($paths.StateCheck, $script:StateCheckCode, $utf8Bom)
        [System.IO.File]::WriteAllText($paths.Status, $script:StatusCode, $utf8Bom)

        $reg = @{}
        $reg['HKLM:\SOFTWARE\Microsoft\Cryptography'] = @{ MachineGuid = '0d3c5f9e-6b1a-4c2e-9f77-3a5b1c2d4e6f' }
        $reg['HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName'] = @{ ComputerName = $Name }
        $reg['HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName'] = @{ ComputerName = $Name }
        $ad = New-Object System.Collections.Generic.List[string]
        $ad.Add($Name.ToUpperInvariant())
        foreach ($o in $OtherAdObjects) { $ad.Add($o.ToUpperInvariant()) }

        $global:HRSim = @{
            Root          = $Root
            Sentinel      = $sentinel
            ProgramData   = Join-Path $Root 'ProgramData'
            LocalDir      = Join-Path (Join-Path $Root 'ProgramData') 'HostRename'
            Paths         = $paths
            Registry      = $reg
            RegWrites     = 0
            Device        = @{
                Domain = $Domain; BiosSerial = $BiosSerial; ProductSerial = $ProductSerial; BoardSerial = $BoardSerial
                Uuid = '4C4C4544-0053-4D10-8031-B1C04F4D5832'; Delegation = $Delegation; SecureChannel = $true
                Wow64 = $false; FolderOwner = 'S-1-5-18'; CaDenied = $false
            }
            Ad            = $ad
            Net           = $null
            TaskExists    = $false
            RenameCalls   = New-Object System.Collections.Generic.List[string]
            TaskRemovals  = New-Object System.Collections.Generic.List[string]
            AclCalls      = New-Object System.Collections.Generic.List[string]
            ShutdownCalls = New-Object System.Collections.Generic.List[string]
            ExeCalls      = New-Object System.Collections.Generic.List[string]
            Certs         = New-Object System.Collections.Generic.List[System.Security.Cryptography.X509Certificates.X509Certificate2]
            CertRequests  = New-Object System.Collections.Generic.List[string]
            CertRemovals  = New-Object System.Collections.Generic.List[string]
            Phases        = New-Object System.Collections.Generic.List[string]
            Reboots       = 0
        }
        Set-SimNetwork -Path $Network
        $env:COMPUTERNAME = $Name
        $env:ProgramData  = $global:HRSim.ProgramData
    }

    function Set-SimNetwork {
        # Network situation of the device: Lan, DirectAccess, CorpWlan (corporate WLAN only), Offline (home network)
        param([ValidateSet('Lan', 'DirectAccess', 'CorpWlan', 'Offline')][string]$Path)
        $global:HRSim.Net = switch ($Path) {
            'Lan'          { @{ Wired = 'DomainAuthenticated'; DA = 'ConnectedLocally'; Wlan = @(); Dns = $true; Dc = $true } }
            'DirectAccess' { @{ Wired = 'None'; DA = 'ConnectedRemotely'; Wlan = @(@{ Ssid = 'HOME-WIFI'; DomainAuthenticated = $false }); Dns = $true; Dc = $true } }
            'CorpWlan'     { @{ Wired = 'None'; DA = 'NotConfigured'; Wlan = @(@{ Ssid = 'CORP-WLAN'; DomainAuthenticated = $false }); Dns = $true; Dc = $true } }
            'Offline'      { @{ Wired = 'None'; DA = 'NotConfigured'; Wlan = @(@{ Ssid = 'HOME-WIFI'; DomainAuthenticated = $false }); Dns = $false; Dc = $false } }
        }
    }

    function Invoke-SimulatedReboot {
        # The pending name becomes the active name (as after a real restart)
        $pending = Get-SimPendingName
        (Get-SimRegKey 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName').ComputerName = $pending
        $env:COMPUTERNAME = $pending
        $global:HRSim.Reboots++
    }

    # ---- Running scripts ----------------------------------------------------------------------------------------
    function Invoke-SimScript {
        # Runs a script like powershell.exe -File would: fresh exit code, stdout and host output captured as lines
        param([Parameter(Mandatory)][string]$Path, [hashtable]$Parameters = @{})
        Assert-SimMocks
        $global:LASTEXITCODE = 0
        $out = & $Path @Parameters 6>&1
        $code = $global:LASTEXITCODE
        $lines = @($out | ForEach-Object { "$_" })
        [pscustomobject]@{ ExitCode = $code; Output = $lines; Text = ($lines -join "`n") }
    }
    function Invoke-SimStatus {
        # Status script (docs/acmp-rollout.md 4.3); records the phase; must not write anything
        $writes = $global:HRSim.RegWrites
        $r = Invoke-SimScript -Path $global:HRSim.Paths.Status
        if ($global:HRSim.RegWrites -ne $writes) { throw 'The status script wrote to the registry.' }
        $phase = [regex]::Match($r.Text, 'HR_PHASE=(\S+)').Groups[1].Value
        if ($global:HRSim.Phases.Count -eq 0 -or $global:HRSim.Phases[$global:HRSim.Phases.Count - 1] -ne $phase) { $global:HRSim.Phases.Add($phase) }
        $r | Add-Member -NotePropertyName Phase -NotePropertyValue $phase -PassThru
    }
    function Invoke-SimHostRename {
        param([hashtable]$Parameters, [string]$Path = $global:HRSim.Paths.Invoke)
        Invoke-SimScript -Path $Path -Parameters $Parameters
    }

    function Invoke-SimulatedClientCommand {
        <#
          The Client Command "HostRename - Rename" as described in docs/acmp-guide.md, section 4:
            1 state check (documented snippet) -> done: end; permanent (LastExitCode 2/4/5): end
            2 gate: 20 dialog "LAN cable", end; 21/22 end silently; 1 end (retry)
            3 rename (phase=rename only), 4 evaluate: 3010 reboot dialog, end; 1 retry; 2/4/5 permanent; 0 continue
            6 gate (already passed in this run), 7 certificate (WLAN devices only), 8 cleanup
            9 report: status script
          The reboot itself is done by the scenario (Invoke-SimulatedReboot), so reruns before it can be tested.
        #>
        param(
            [Parameter(Mandatory)][hashtable]$RenameParameters,
            [string]$CertificateTemplate = '',
            [switch]$RemoveOld,
            [string[]]$CorporateSsid = @('CORP-WLAN')
        )
        $run = [pscustomobject]@{ Phase = ''; Steps = [ordered]@{}; Outcome = ''; Dialog = ''; Status = $null }
        $acmp = @{ Deployment = 'Acmp' } + $RenameParameters
        $run.Outcome = & {
            $writes = $global:HRSim.RegWrites
            $sc = Invoke-SimScript -Path $global:HRSim.Paths.StateCheck
            if ($global:HRSim.RegWrites -ne $writes) { throw 'The state check wrote to the registry.' }
            $run.Steps['StateCheck'] = $sc
            $run.Phase = [regex]::Match($sc.Text, '(?m)^phase=(\S+)').Groups[1].Value
            if ($run.Phase -notin 'done', 'permanent', 'after-reboot', 'rename') { throw "State check: unexpected output '$($sc.Text)' (exit $($sc.ExitCode))" }
            if ($run.Phase -eq 'done') { return 'Done' }
            if ($run.Phase -eq 'permanent') { return 'Permanent' }

            $gate = Invoke-SimScript -Path $global:HRSim.Paths.Gate -Parameters @{ CorporateSsid = $CorporateSsid }
            $run.Steps['Gate'] = $gate
            switch ($gate.ExitCode) {
                0       { }
                20      { $run.Dialog = 'LanCable'; return 'WaitForCable' }
                21      { return 'WaitSilently' }
                22      { return 'WaitSilently' }
                default { return 'Retry' }
            }

            if ($run.Phase -eq 'rename') {
                $rn = Invoke-SimHostRename -Parameters $acmp
                $run.Steps['Rename'] = $rn
                switch ($rn.ExitCode) {
                    3010    { $run.Dialog = 'Reboot'; return 'RebootRequired' }
                    0       { }
                    1       { return 'Retry' }
                    2       { return 'Permanent' }
                    4       { return 'Permanent' }
                    5       { return 'Permanent' }
                    default { return "Unexpected exit code $($rn.ExitCode)" }
                }
            }

            if ($CertificateTemplate) {
                $cert = Invoke-SimScript -Path $global:HRSim.Paths.Cert -Parameters @{ Template = $CertificateTemplate; RemoveOld = [bool]$RemoveOld }
                $run.Steps['Certificate'] = $cert
                if ($cert.ExitCode -ne 0) { return 'Retry' }
            }

            $cl = Invoke-SimHostRename -Parameters ($acmp + @{ Cleanup = $true })
            $run.Steps['Cleanup'] = $cl
            switch ($cl.ExitCode) {
                0       { return 'Done' }
                3010    { $run.Dialog = 'Reboot'; return 'RebootRequired' }
                default { return 'Retry' }
            }
        }
        $run.Status = Invoke-SimStatus
        $run
    }

    function Invoke-SimWrapper {
        # Runs Invoke-AcmpHostRename.ps1 (the whole Client Command in one run) like powershell.exe -File would.
        # Checks that the last line is the summary line and that its EXIT matches the exit code.
        # Ran = the steps whose script the wrapper started ("HOSTRENAME STEP=<step> RUN=<script>" lines).
        param([hashtable]$Parameters = @{})
        $r = Invoke-SimScript -Path $global:HRSim.Paths.Wrapper -Parameters $Parameters
        $last = if ($r.Output.Count) { [string]$r.Output[$r.Output.Count - 1] } else { '' }
        $m = [regex]::Match($last, '^HOSTRENAME PHASE=(\w+) EXIT=(\d+) STEP=(\w+) MESSAGE="([^"]*)"$')
        if (-not $m.Success) { throw "Wrapper: the last line is not the summary line: '$last'`n$($r.Text)" }
        if ([int]$m.Groups[2].Value -ne $r.ExitCode) { throw "Wrapper: summary EXIT=$($m.Groups[2].Value) but exit code $($r.ExitCode)" }
        $ran = @($r.Output | ForEach-Object { $x = [regex]::Match($_, '^HOSTRENAME STEP=(\w+) RUN=(\S+)$'); if ($x.Success) { $x.Groups[1].Value } })
        $r | Add-Member -NotePropertyName Summary -NotePropertyValue $last
        $r | Add-Member -NotePropertyName Phase -NotePropertyValue $m.Groups[1].Value
        $r | Add-Member -NotePropertyName Step -NotePropertyValue $m.Groups[3].Value
        $r | Add-Member -NotePropertyName Message -NotePropertyValue $m.Groups[4].Value
        $r | Add-Member -NotePropertyName Ran -NotePropertyValue $ran -PassThru
    }

    function Get-SimLocalLog {
        param([string]$Path = (Join-Path $global:HRSim.LocalDir 'rename-local.csv'))
        if (-not [System.IO.File]::Exists($Path)) { return @() }
        @(Import-Csv -Path $Path -Delimiter ';')
    }

    # ---- Mocks: fake registry (HKLM), file system guard, environment ---------------------------------------------
    Mock Test-Path {
        $p = if ($PesterBoundParameters.ContainsKey('LiteralPath')) { $PesterBoundParameters['LiteralPath'] } else { $PesterBoundParameters['Path'] }
        if (Test-SimRegistryPath $p) { return (Test-SimRegKey ([string]@($p)[0])) }
        & $ExecutionContext.InvokeCommand.GetCmdlet('Test-Path') @PesterBoundParameters
    }
    Mock Get-ItemProperty {
        $p = if ($PesterBoundParameters.ContainsKey('LiteralPath')) { $PesterBoundParameters['LiteralPath'] } else { $PesterBoundParameters['Path'] }
        if (-not (Test-SimRegistryPath $p)) { return (& $ExecutionContext.InvokeCommand.GetCmdlet('Get-ItemProperty') @PesterBoundParameters) }
        $p = [string]@($p)[0]
        $quiet = [string]$PesterBoundParameters['ErrorAction'] -in 'SilentlyContinue', 'Ignore'
        $vals = Get-SimRegKey $p
        if ($null -eq $vals) {
            if ($quiet) { return }
            throw (New-Object System.Management.Automation.ItemNotFoundException("Cannot find path '$p' because it does not exist."))
        }
        if ($PesterBoundParameters.ContainsKey('Name')) {
            foreach ($n in @($PesterBoundParameters['Name'])) {
                if (-not $vals.ContainsKey($n)) { if ($quiet) { return }; throw "Property $n does not exist at path $p." }
            }
        }
        $o = [ordered]@{}
        foreach ($k in $vals.Keys) { $o[$k] = $vals[$k] }
        [pscustomobject]$o
    }
    Mock Set-ItemProperty {
        if (-not (Test-SimRegistryPath $Path)) { throw "Simulation: Set-ItemProperty outside the registry is not expected: $Path" }
        if ($WhatIfPreference) { return }                       # like the real cmdlet under -WhatIf
        $vals = Get-SimRegKey ([string]$Path)
        if ($null -eq $vals) { throw "Cannot find path '$Path' because it does not exist." }
        $v = $Value
        if ("$Type" -eq 'DWord') { $v = [int]$Value }
        $vals[[string]$Name] = $v
        $global:HRSim.RegWrites++
    }
    Mock New-Item {
        $p = @($PesterBoundParameters['Path'])
        if (Test-SimRegistryPath $p) {
            if ($WhatIfPreference) { return }
            foreach ($one in $p) {
                $k = ConvertTo-SimRegKey ([string]$one)
                if ($global:HRSim.Registry.ContainsKey($k)) {
                    if (-not $Force) { throw "A key at this path already exists: $one" }
                    $global:HRSim.Registry[$k] = @{}               # registry provider: -Force on an existing key recreates it empty
                }
                else { $global:HRSim.Registry[$k] = @{} }
                $global:HRSim.RegWrites++
                [pscustomobject]@{ PSPath = $k }
            }
            return
        }
        Assert-SimFileSystemPath -Path $p -Command 'New-Item'
        & $ExecutionContext.InvokeCommand.GetCmdlet('New-Item') @PesterBoundParameters
    }
    Mock Remove-Item {
        $p = @(if ($PesterBoundParameters.ContainsKey('LiteralPath')) { $PesterBoundParameters['LiteralPath'] } else { $PesterBoundParameters['Path'] })
        if (Test-SimRegistryPath $p) {
            if ($WhatIfPreference) { return }
            foreach ($one in $p) { [void]$global:HRSim.Registry.Remove((ConvertTo-SimRegKey ([string]$one))); $global:HRSim.RegWrites++ }
            return
        }
        Assert-SimFileSystemPath -Path $p -Command 'Remove-Item'
        & $ExecutionContext.InvokeCommand.GetCmdlet('Remove-Item') @PesterBoundParameters
    }
    Mock Start-Sleep { }

    # ---- Mocks: computer, domain and AD ----------------------------------------------------------------------------
    Mock Get-CimInstance {
        $d = $global:HRSim.Device
        switch ($ClassName) {
            'Win32_ComputerSystem'        { [pscustomobject]@{ Name = (Get-SimActiveName); DNSHostName = (Get-SimActiveName); PartOfDomain = $true; Domain = $d.Domain } }
            'Win32_BIOS'                  { [pscustomobject]@{ SerialNumber = $d.BiosSerial } }
            'Win32_ComputerSystemProduct' { [pscustomobject]@{ IdentifyingNumber = $d.ProductSerial; UUID = $d.Uuid } }
            'Win32_BaseBoard'             { [pscustomobject]@{ SerialNumber = $d.BoardSerial } }
            default                       { throw "Simulation: unexpected CIM class '$ClassName'." }
        }
    }
    Mock Test-ComputerSecureChannel { [bool]$global:HRSim.Device.SecureChannel }
    Mock Test-Wow64Process { [bool]$global:HRSim.Device.Wow64 }
    Mock Get-OwnerSid { $global:HRSim.Device.FolderOwner }
    Mock Set-LocalDirAcl { $global:HRSim.AclCalls.Add([string]$Path) }
    Mock Get-ScheduledTask { if ($global:HRSim.TaskExists) { [pscustomobject]@{ TaskName = $TaskName } } }
    Mock Unregister-ScheduledTask { $global:HRSim.TaskRemovals.Add([string]$TaskName); $global:HRSim.TaskExists = $false }
    Mock Test-AdComputerExists { $global:HRSim.Ad.Contains(([string]$Name).ToUpperInvariant()) }
    Mock Test-AdRenamePermission {
        if (-not $global:HRSim.Ad.Contains($ComputerName.ToUpperInvariant())) {
            return [pscustomobject]@{ Found = $false; Inconclusive = $false; Dn = $null; Writable = @(); Missing = @('cn', 'sAMAccountName') }
        }
        $dn = "CN=$ComputerName,OU=Clients,DC=sim,DC=invalid"
        if ($global:HRSim.Device.Delegation) {
            [pscustomobject]@{ Found = $true; Inconclusive = $false; Dn = $dn; Writable = @('cn', 'name', 'sAMAccountName', 'displayName', 'dNSHostName', 'servicePrincipalName'); Missing = @() }
        }
        else {
            [pscustomobject]@{ Found = $true; Inconclusive = $false; Dn = $dn; Writable = @('dNSHostName', 'servicePrincipalName'); Missing = @('cn', 'sAMAccountName') }
        }
    }
    Mock Rename-Computer {
        if ($WhatIfPreference -or $PesterBoundParameters['WhatIf']) { return }
        if (-not $global:HRSim.Device.Delegation) { throw 'Access is denied.' }
        $global:HRSim.RenameCalls.Add([string]$NewName)
        $old = (Get-SimActiveName).ToUpperInvariant()
        (Get-SimRegKey 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName').ComputerName = [string]$NewName
        [void]$global:HRSim.Ad.Remove($old)                    # the AD object is renamed at once
        $global:HRSim.Ad.Add(([string]$NewName).ToUpperInvariant())
    }

    # ---- Mocks: network (gate) ---------------------------------------------------------------------------------------
    Mock Get-NetAdapter {
        $n = $global:HRSim.Net
        [pscustomobject]@{ Name = 'Ethernet'; InterfaceDescription = 'Sim Ethernet'; ifIndex = 11; NdisPhysicalMedium = 14; PhysicalMediaType = '802.3'; MediaType = '802.3'
                           Status = $(if ($n.Wired -ne 'None') { 'Up' } else { 'Disconnected' }) }
        [pscustomobject]@{ Name = 'Wi-Fi'; InterfaceDescription = 'Sim Wireless'; ifIndex = 12; NdisPhysicalMedium = 9; PhysicalMediaType = 'Native 802.11'; MediaType = 'Native 802.11'
                           Status = $(if (@($n.Wlan).Count) { 'Up' } else { 'Disconnected' }) }
    }
    Mock Get-NetConnectionProfile {
        $n = $global:HRSim.Net
        $idx = [int]@($InterfaceIndex)[0]
        if ($idx -eq 11 -and $n.Wired -eq 'DomainAuthenticated') { [pscustomobject]@{ Name = $global:HRSim.Device.Domain; NetworkCategory = 'DomainAuthenticated' } }
        elseif ($idx -eq 11 -and $n.Wired -eq 'Up') { [pscustomobject]@{ Name = 'Network'; NetworkCategory = 'Public' } }
        elseif ($idx -eq 12) {
            foreach ($w in @($n.Wlan)) { [pscustomobject]@{ Name = $w.Ssid; NetworkCategory = $(if ($w.DomainAuthenticated) { 'DomainAuthenticated' } else { 'Private' }) } }
        }
    }
    Mock Get-DAConnectionStatus {
        $s = $global:HRSim.Net.DA
        if ($s -eq 'NotConfigured') { throw 'The DirectAccess client is not configured.' }
        [pscustomobject]@{ Status = $s }
    }
    Mock Get-WinRtWlanConnection {
        foreach ($w in @($global:HRSim.Net.Wlan)) { [pscustomobject]@{ Ssid = $w.Ssid; DomainAuthenticated = [bool]$w.DomainAuthenticated; Source = 'WinRT' } }
    }
    Mock Resolve-DnsName {
        if (-not $global:HRSim.Net.Dns) { throw "DNS name does not exist: $Name" }
        [pscustomobject]@{ Name = $Name; NameTarget = "dc01.$($global:HRSim.Device.Domain)"; Priority = 0; Weight = 100 }
    }
    Mock Resolve-HostAddress { [System.Net.IPAddress]::Parse('192.0.2.10') }
    Mock Test-TcpPort { [bool]$global:HRSim.Net.Dc }

    # ---- Mocks: certificate store and CA -----------------------------------------------------------------------------
    Mock Get-MachineCertificate { $global:HRSim.Certs.ToArray() }
    Mock Remove-MachineCertificate {
        $c = @($global:HRSim.Certs | Where-Object { $_.Thumbprint -eq $Thumbprint })
        if (-not $c.Count) { throw "Certificate $Thumbprint not found." }
        [void]$global:HRSim.Certs.Remove($c[0])
        $global:HRSim.CertRemovals.Add($Thumbprint)
    }
    Mock Resolve-TemplateOid { $null }
    Mock Request-TemplateCertificate {
        # The CA issues a certificate for the current DNS host name of the device (or denies it: Device.CaDenied)
        $global:HRSim.CertRequests.Add($Template)
        if ($global:HRSim.Device.CaDenied) { return [pscustomobject]@{ Status = 'Denied'; Certificate = $null; Message = 'Denied by the simulated CA.' } }
        $active = (Get-SimActiveName).ToLowerInvariant()
        $c = New-SimCertificate -DnsName "$active.$($global:HRSim.Device.Domain)", $active -TemplateName $Template
        $global:HRSim.Certs.Add($c)
        [pscustomobject]@{ Status = 'Issued'; Certificate = $c; Message = '' }
    }
}

AfterAll {
    foreach ($n in 'COMPUTERNAME', 'ProgramData') {
        [System.Environment]::SetEnvironmentVariable($n, $global:HRSimSavedEnv[$n])
    }
    Remove-Variable -Name HRSim, HRSimSavedEnv -Scope Global -ErrorAction SilentlyContinue
}

Describe 'Simulation harness and documented snippets' {
    BeforeAll { New-SimDevice -Root (Join-Path $TestDrive 'Harness') }

    It 'extracts the state check (acmp-guide, step 1) and the status script (acmp-rollout, 4.3) from the docs' {
        $script:StateCheckCode | Should -Match "Test-Path 'HKLM:\\SOFTWARE\\HostRename'"
        $script:StatusCode     | Should -Match 'HR_PHASE='
    }
    It 'the German docs contain the same code (comments aside)' {
        Remove-CodeComment (Get-MarkdownCodeBlock -Path $script:Src.GuideDe -Heading 'Schritt 1:') | Should -BeExactly (Remove-CodeComment $script:StateCheckCode)
        Remove-CodeComment (Get-MarkdownCodeBlock -Path $script:Src.RolloutDe -Heading '4\.3 Statusskript') | Should -BeExactly (Remove-CodeComment $script:StatusCode)
    }
    It 'every command that could change the machine resolves to its mock' {
        { Assert-SimMocks } | Should -Not -Throw
    }
    It 'the fake registry is used for HKLM, and file writes outside the simulation folder are refused' {
        Test-Path 'HKLM:\SOFTWARE\Microsoft\Cryptography' | Should -BeTrue
        Test-Path 'HKLM:\SOFTWARE\HostRename' | Should -BeFalse
        (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName').ComputerName | Should -Be 'PC349219'
        { New-Item -ItemType Directory -Path (Join-Path ([System.IO.Path]::GetTempPath()) 'HostRename-Sim-Refused') } | Should -Throw '*refused*'
    }
    It 'the state check reports phase=rename on a fresh device and phase=done once the marker exists' {
        (Invoke-SimScript -Path $global:HRSim.Paths.StateCheck).Text | Should -Match '^phase=rename$'
        $global:HRSim.Registry['HKLM:\SOFTWARE\HostRename'] = @{}
        $r = Invoke-SimScript -Path $global:HRSim.Paths.StateCheck
        $r.Text | Should -Match '^phase=done$'
        $r.ExitCode | Should -Be 0
    }
    It 'the state check reports phase=permanent for LastExitCode 2, 4 and 5 (marker absent), not for 0, 1 or 3010, and phase=done wins' {
        $global:HRSim.Registry.Remove('HKLM:\SOFTWARE\HostRename')
        foreach ($code in 2, 4, 5) {
            $global:HRSim.Registry['HKLM:\SOFTWARE\HostRenameState'] = @{ LastExitCode = $code }
            $r = Invoke-SimScript -Path $global:HRSim.Paths.StateCheck
            $r.Text | Should -Match '^phase=permanent$'
            $r.ExitCode | Should -Be 0
        }
        foreach ($code in 0, 1, 3010) {
            $global:HRSim.Registry['HKLM:\SOFTWARE\HostRenameState'] = @{ LastExitCode = $code }
            (Invoke-SimScript -Path $global:HRSim.Paths.StateCheck).Text | Should -Match '^phase=rename$'
        }
        $global:HRSim.Registry['HKLM:\SOFTWARE\HostRenameState'] = @{ LastExitCode = 4 }
        $global:HRSim.Registry['HKLM:\SOFTWARE\HostRename'] = @{}
        (Invoke-SimScript -Path $global:HRSim.Paths.StateCheck).Text | Should -Match '^phase=done$'
    }
}

Describe 'S1 LAN device, template DE{Serial}, without central log: full flow' {
    BeforeAll {
        New-SimDevice -Root (Join-Path $TestDrive 'S1') -Network Lan
        $script:P = @{ NameTemplate = 'DE{Serial}'; NoCentralLog = $true }
    }

    It 'before anything ran: status Open, no HostRename keys' {
        (Invoke-SimStatus).Text | Should -Match '^HR_PHASE=Open HR_DONE=0 HR_TARGET= HR_EXIT= '
        Get-SimState | Should -BeNullOrEmpty
    }
    It 'dry run (gate + -WhatIf): exit 0, WHATIF with the target name, nothing written' {
        $g = Invoke-SimScript -Path $global:HRSim.Paths.Gate -Parameters @{ CorporateSsid = 'CORP-WLAN' }
        $g.ExitCode | Should -Be 0
        $g.Text | Should -Match '^RESULT=LAN EXIT=0 DOMAIN=sim.invalid DC=dc01.sim.invalid LAN=DomainAuthenticated '
        $r = Invoke-SimHostRename -Parameters ($script:P + @{ Deployment = 'Acmp'; WhatIf = $true })
        $r.ExitCode | Should -Be 0
        $r.Text | Should -Match "\[INFO\] WHATIF: 'PC349219' would be renamed to 'DESIM4711AB'"
        $global:HRSim.RegWrites | Should -Be 0
        Get-SimState | Should -BeNullOrEmpty
        $global:HRSim.RenameCalls.Count | Should -Be 0
        [System.IO.Directory]::Exists($global:HRSim.LocalDir) | Should -BeFalse -Because '-WhatIf creates no local folder and no log'
    }
    It 'run 1: state check rename, gate LAN, rename exit 3010, reboot dialog' {
        $run = Invoke-SimulatedClientCommand -RenameParameters $script:P
        $run.Phase | Should -Be 'rename'
        $run.Steps['Gate'].ExitCode | Should -Be 0
        $run.Steps['Rename'].ExitCode | Should -Be 3010
        $run.Steps['Rename'].Text | Should -Match "RENAMED: Successfully renamed: 'PC349219' -> 'DESIM4711AB'"
        $run.Outcome | Should -Be 'RebootRequired'
        $run.Dialog | Should -Be 'Reboot'
        $run.Steps.Contains('Cleanup') | Should -BeFalse
        $run.Status.Phase | Should -Be 'RebootPending'
    }
    It 'after run 1: pending name, state and reporting values, AD object renamed, folder protected, no reboot scheduled' {
        Get-SimActiveName  | Should -Be 'PC349219'
        Get-SimPendingName | Should -Be 'DESIM4711AB'
        $s = Get-SimState
        $s.TargetName    | Should -Be 'DESIM4711AB'
        $s.OriginalName  | Should -Be 'PC349219'
        $s.Template      | Should -Be 'DE{SERIAL}'
        $s.FutureId      | Should -Be ''
        $s.LastExitCode  | Should -Be 3010
        $s.LastEvent     | Should -Be 'AD_VERIFY'
        $s.Deployment    | Should -Be 'Acmp'
        $s.ScriptVersion | Should -Be $script:ScriptVersion
        $s.LastRun       | Should -Match '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d[+-]\d\d:\d\d$'
        Get-SimMarker | Should -BeNullOrEmpty
        $global:HRSim.Ad | Should -Contain 'DESIM4711AB'
        $global:HRSim.Ad | Should -Not -Contain 'PC349219'
        $global:HRSim.AclCalls | Should -Contain $global:HRSim.LocalDir
        $global:HRSim.ShutdownCalls.Count | Should -Be 0
        @(Get-SimLocalLog).Event | Should -Be @('START', 'LOG_CHECK', 'SERIAL', 'PERM_CHECK', 'RENAMED', 'AD_VERIFY')
    }
    It 'run 2 before the reboot: 3010 again (PENDING_REBOOT), no second rename' {
        $run = Invoke-SimulatedClientCommand -RenameParameters $script:P
        $run.Phase | Should -Be 'rename'
        $run.Steps['Rename'].ExitCode | Should -Be 3010
        $run.Steps['Rename'].Text | Should -Match "PENDING_REBOOT: Rename to 'DESIM4711AB' is already pending"
        $run.Outcome | Should -Be 'RebootRequired'
        $global:HRSim.RenameCalls.Count | Should -Be 1
        (Get-SimState).LastEvent | Should -Be 'PENDING_REBOOT'
        $run.Status.Phase | Should -Be 'RebootPending'
    }
    It 'reboot: the new name becomes active; status AfterReboot' {
        Invoke-SimulatedReboot
        Get-SimActiveName | Should -Be 'DESIM4711AB'
        $st = Invoke-SimStatus
        $st.Phase | Should -Be 'AfterReboot'
        $st.Text | Should -Match 'HR_EXIT=3010 '
    }
    It 'run 3 after the reboot: gate 0, cleanup exit 0, marker set, done' {
        $run = Invoke-SimulatedClientCommand -RenameParameters $script:P
        $run.Phase | Should -Be 'after-reboot'
        $run.Steps.Contains('Rename') | Should -BeFalse
        $run.Steps['Gate'].ExitCode | Should -Be 0
        $run.Steps['Cleanup'].ExitCode | Should -Be 0
        $run.Steps['Cleanup'].Text | Should -Match 'ALREADY_DONE'
        $run.Steps['Cleanup'].Text | Should -Match '(?m)CLEANUP_DONE' -Because 'the cleanup events reach stdout (ACMP job output)'
        $run.Steps['Cleanup'].Text | Should -Not -Match '(?m)^\s*(True|False)\s*$' -Because 'the return value of Invoke-Cleanup must not leak'
        $run.Outcome | Should -Be 'Done'
        $m = Get-SimMarker
        $m.ComputerName | Should -Be 'DESIM4711AB'
        $m.Completed | Should -Not -BeNullOrEmpty
        (Get-SimState).LastExitCode | Should -Be 0
        (Get-SimState).LastEvent | Should -Be 'CLEANUP_DONE'
        $run.Status.Phase | Should -Be 'Done'
        $run.Status.Text | Should -Match '^HR_PHASE=Done HR_DONE=1 HR_TARGET=DESIM4711AB HR_EXIT=0 HR_EVENT=CLEANUP_DONE '
    }
    It 'after the cleanup: local log kept (no central log), script file in the ACMP cache kept, no task touched' {
        $events = @(Get-SimLocalLog).Event
        $events | Should -Contain 'CLEANUP'
        $events[-1] | Should -Be 'CLEANUP_DONE'
        [System.IO.File]::Exists($global:HRSim.Paths.Invoke) | Should -BeTrue
        $global:HRSim.TaskRemovals.Count | Should -Be 0
        $global:HRSim.RenameCalls.Count | Should -Be 1
    }
    It 'run 4: ends at step 1 (done), no script runs' {
        $lastRun = (Get-SimState).LastRun
        $run = Invoke-SimulatedClientCommand -RenameParameters $script:P
        $run.Phase | Should -Be 'done'
        @($run.Steps.Keys) | Should -Be @('StateCheck')
        $run.Outcome | Should -Be 'Done'
        (Get-SimState).LastRun | Should -Be $lastRun
    }
    It 'status phases over the whole flow: Open > RebootPending > AfterReboot > Done' {
        ($global:HRSim.Phases -join ' > ') | Should -Be 'Open > RebootPending > AfterReboot > Done'
    }
    It 'a different template renames again when the script is called directly (the Client Command stops at step 1)' {
        $run = Invoke-SimulatedClientCommand -RenameParameters @{ NameTemplate = 'NB{Serial}'; NoCentralLog = $true }
        $run.Outcome | Should -Be 'Done'
        $global:HRSim.RenameCalls.Count | Should -Be 1
        $r = Invoke-SimHostRename -Parameters @{ Deployment = 'Acmp'; NameTemplate = 'NB{Serial}'; NoCentralLog = $true }
        $r.ExitCode | Should -Be 3010
        Get-SimPendingName | Should -Be 'NBSIM4711AB'
    }
}

Describe 'S2 DirectAccess device (with -Reboot passed anyway)' {
    BeforeAll {
        New-SimDevice -Root (Join-Path $TestDrive 'S2') -Network DirectAccess
        $script:P = @{ NameTemplate = 'DE{Serial}'; NoCentralLog = $true; Reboot = $true }
    }

    It 'run 1: gate RESULT=DIRECTACCESS exit 0, rename 3010, REBOOT_IGNORED, no reboot scheduled' {
        $run = Invoke-SimulatedClientCommand -RenameParameters $script:P
        $run.Steps['Gate'].Text | Should -Match '^RESULT=DIRECTACCESS EXIT=0 .* LAN=None DA=ConnectedRemotely WLAN="HOME-WIFI" '
        $run.Steps['Rename'].ExitCode | Should -Be 3010
        $run.Steps['Rename'].Text | Should -Match 'REBOOT_IGNORED'
        $run.Outcome | Should -Be 'RebootRequired'
        $global:HRSim.ShutdownCalls.Count | Should -Be 0
    }
    It 'after the reboot: cleanup done; REBOOT_IGNORED logged on every run; never a reboot by the script' {
        Invoke-SimulatedReboot
        $run = Invoke-SimulatedClientCommand -RenameParameters $script:P
        $run.Outcome | Should -Be 'Done'
        (Get-SimMarker).ComputerName | Should -Be 'DESIM4711AB'
        @(Get-SimLocalLog | Where-Object Event -eq 'REBOOT_IGNORED').Count | Should -Be 2
        $global:HRSim.ShutdownCalls.Count | Should -Be 0
        $global:HRSim.ExeCalls.Count | Should -Be 0
    }
}

Describe 'S3 WLAN user: rename over LAN, certificate after the reboot' {
    BeforeAll {
        New-SimDevice -Root (Join-Path $TestDrive 'S3') -Network Lan
        $global:HRSim.Certs.Add((New-SimCertificate -DnsName 'pc349219.sim.invalid', 'pc349219' -TemplateName 'SimWlanMachine' -NotAfterDays 300))
        $script:OldThumb = $global:HRSim.Certs[0].Thumbprint
        $script:P = @{ NameTemplate = 'DE{Serial}'; NoCentralLog = $true }
    }

    It 'run 1 on LAN: rename 3010' {
        (Invoke-SimulatedClientCommand -RenameParameters $script:P -CertificateTemplate 'SimWlanMachine' -RemoveOld).Outcome | Should -Be 'RebootRequired'
    }
    It 'the certificate script before the reboot ends with exit 1 (rename pending) and changes nothing' {
        $c = Invoke-SimScript -Path $global:HRSim.Paths.Cert -Parameters @{ Template = 'SimWlanMachine'; RemoveOld = $true }
        $c.ExitCode | Should -Be 1
        $c.Output[-1] | Should -Match "^RESULT=ERROR EXIT=1 TEMPLATE=SimWlanMachine DNS=pc349219.sim.invalid .*MESSAGE=`"Computer rename to 'DESIM4711AB' is pending"
        $global:HRSim.CertRequests.Count | Should -Be 0
        $global:HRSim.Certs.Count | Should -Be 1
    }
    It 'after the reboot on corporate WLAN only: gate 20, no certificate, no cleanup' {
        Invoke-SimulatedReboot
        Set-SimNetwork -Path CorpWlan
        $run = Invoke-SimulatedClientCommand -RenameParameters $script:P -CertificateTemplate 'SimWlanMachine' -RemoveOld
        $run.Phase | Should -Be 'after-reboot'
        $run.Steps['Gate'].ExitCode | Should -Be 20
        $run.Outcome | Should -Be 'WaitForCable'
        $run.Dialog | Should -Be 'LanCable'
        $run.Steps.Contains('Certificate') | Should -BeFalse
        Get-SimMarker | Should -BeNullOrEmpty
        $run.Status.Phase | Should -Be 'AfterReboot'
    }
    It 'back on LAN: certificate RENEWED for the new name, old certificate removed (-RemoveOld), then cleanup' {
        Set-SimNetwork -Path Lan
        $run = Invoke-SimulatedClientCommand -RenameParameters $script:P -CertificateTemplate 'SimWlanMachine' -RemoveOld
        $c = $run.Steps['Certificate']
        $c.ExitCode | Should -Be 0
        $c.Output[-1] | Should -Match '^RESULT=RENEWED EXIT=0 TEMPLATE=SimWlanMachine DNS=desim4711ab.sim.invalid THUMBPRINT=\w+ NOTAFTER=\S+ REMOVED=1 '
        $global:HRSim.CertRemovals | Should -Be @($script:OldThumb)
        $global:HRSim.Certs.Count | Should -Be 1
        # Check the SAN extension, not GetNameInfo(DnsName): under .NET Framework (Windows PowerShell 5.1)
        # GetNameInfo returns the subject CN instead of the first SAN dNSName.
        $san = $global:HRSim.Certs[0].Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.17' }
        $san | Should -Not -BeNullOrEmpty
        $san.Format($false) | Should -Match ([regex]::Escape('desim4711ab.sim.invalid'))
        $run.Steps['Cleanup'].ExitCode | Should -Be 0
        $run.Outcome | Should -Be 'Done'
        (Get-SimMarker).ComputerName | Should -Be 'DESIM4711AB'
    }
    It 'a further certificate run finds the current certificate (NOT_NEEDED)' {
        $c = Invoke-SimScript -Path $global:HRSim.Paths.Cert -Parameters @{ Template = 'SimWlanMachine'; RemoveOld = $true }
        $c.ExitCode | Should -Be 0
        $c.Output[-1] | Should -Match '^RESULT=NOT_NEEDED EXIT=0 .* REMOVED=0 '
        $global:HRSim.CertRequests.Count | Should -Be 1
    }
}

Describe 'S4 corporate WLAN only, then cable' {
    BeforeAll {
        New-SimDevice -Root (Join-Path $TestDrive 'S4') -Network CorpWlan
        $script:P = @{ NameTemplate = 'DE{Serial}'; NoCentralLog = $true }
    }

    It 'gate 20 (RESULT=WLAN): LAN cable dialog, Invoke-HostRename never runs, nothing written' {
        $run = Invoke-SimulatedClientCommand -RenameParameters $script:P
        $run.Steps['Gate'].ExitCode | Should -Be 20
        $run.Steps['Gate'].Text | Should -Match '^RESULT=WLAN EXIT=20 .*WLAN="CORP-WLAN" '
        $run.Outcome | Should -Be 'WaitForCable'
        $run.Steps.Contains('Rename') | Should -BeFalse
        $global:HRSim.RegWrites | Should -Be 0
        Get-SimState | Should -BeNullOrEmpty
        [System.IO.Directory]::Exists($global:HRSim.LocalDir) | Should -BeFalse
        $run.Status.Phase | Should -Be 'Open'
    }
    It 'with the cable plugged in, the next run renames' {
        Set-SimNetwork -Path Lan
        $run = Invoke-SimulatedClientCommand -RenameParameters $script:P
        $run.Steps['Gate'].ExitCode | Should -Be 0
        $run.Outcome | Should -Be 'RebootRequired'
        $global:HRSim.RenameCalls | Should -Be @('DESIM4711AB')
    }
}

Describe 'S5 offline (home network without DirectAccess), then LAN' {
    BeforeAll {
        New-SimDevice -Root (Join-Path $TestDrive 'S5') -Network Offline
        $script:P = @{ NameTemplate = 'DE{Serial}'; NoCentralLog = $true }
    }

    It 'gate 21 (RESULT=NONE): ends silently, nothing happens' {
        $run = Invoke-SimulatedClientCommand -RenameParameters $script:P
        $run.Steps['Gate'].ExitCode | Should -Be 21
        $run.Steps['Gate'].Text | Should -Match '^RESULT=NONE EXIT=21 '
        $run.Outcome | Should -Be 'WaitSilently'
        $run.Dialog | Should -Be ''
        $global:HRSim.RegWrites | Should -Be 0
        $global:HRSim.RenameCalls.Count | Should -Be 0
    }
    It 'on LAN the next run renames' {
        Set-SimNetwork -Path Lan
        (Invoke-SimulatedClientCommand -RenameParameters $script:P).Outcome | Should -Be 'RebootRequired'
    }
}

Describe 'S6 no delegation on the OU' {
    BeforeAll {
        New-SimDevice -Root (Join-Path $TestDrive 'S6') -Delegation $false
        $script:P = @{ NameTemplate = 'DE{Serial}'; NoCentralLog = $true }
    }

    It 'exit 4 (PERM_DENIED): permanent, no rename, status Permanent' {
        $run = Invoke-SimulatedClientCommand -RenameParameters $script:P
        $run.Steps['Rename'].ExitCode | Should -Be 4
        $run.Steps['Rename'].Text | Should -Match '\[ERROR\] PERM_DENIED: No write permissions on: cn, sAMAccountName'
        $run.Outcome | Should -Be 'Permanent'
        $s = Get-SimState
        $s.LastExitCode | Should -Be 4
        $s.LastEvent | Should -Be 'PERM_DENIED'
        $s.ContainsKey('TargetName') | Should -BeFalse
        $global:HRSim.RenameCalls.Count | Should -Be 0
        Get-SimPendingName | Should -Be 'PC349219'
        $run.Status.Phase | Should -Be 'Permanent'
    }
    It 'reruns end at step 1 with phase=permanent: no gate, no script, nothing renamed' {
        $before = (Get-SimState).LastRun
        1..2 | ForEach-Object {
            $run = Invoke-SimulatedClientCommand -RenameParameters $script:P
            $run.Phase | Should -Be 'permanent'
            $run.Outcome | Should -Be 'Permanent'
            @($run.Steps.Keys) | Should -Be @('StateCheck')
            $run.Status.Phase | Should -Be 'Permanent'
        }
        (Get-SimState).LastRun | Should -Be $before -Because 'no script ran'
        $global:HRSim.RenameCalls.Count | Should -Be 0
    }
    It 'release without fixing the cause: the next run proceeds and ends at exit 4 again' {
        $global:HRSim.Registry['HKLM:\SOFTWARE\HostRenameState'].Remove('LastExitCode')   # = the documented release
        $run = Invoke-SimulatedClientCommand -RenameParameters $script:P
        $run.Phase | Should -Be 'rename'
        $run.Steps['Rename'].ExitCode | Should -Be 4
        $run.Outcome | Should -Be 'Permanent'
        (Get-SimState).LastExitCode | Should -Be 4
        $global:HRSim.RenameCalls.Count | Should -Be 0
    }
    It 'release after the delegation is granted: the next run renames' {
        $run = Invoke-SimulatedClientCommand -RenameParameters $script:P
        $run.Phase | Should -Be 'permanent'
        $global:HRSim.Registry['HKLM:\SOFTWARE\HostRenameState'].Remove('LastExitCode')   # = the documented release
        $global:HRSim.Device.Delegation = $true
        $run = Invoke-SimulatedClientCommand -RenameParameters $script:P
        $run.Phase | Should -Be 'rename'
        $run.Steps['Rename'].ExitCode | Should -Be 3010
        $run.Outcome | Should -Be 'RebootRequired'
        $global:HRSim.RenameCalls.Count | Should -Be 1
        (Get-SimState).LastExitCode | Should -Be 3010
    }
}

Describe 'S7 target name already taken in AD (duplicate serial number)' {
    BeforeAll {
        New-SimDevice -Root (Join-Path $TestDrive 'S7') -OtherAdObjects 'DESIM4711AB'
        $script:P = @{ NameTemplate = 'DE{Serial}'; NoCentralLog = $true }
        $script:Id = New-FutureId -Seed '0d3c5f9e-6b1a-4c2e-9f77-3a5b1c2d4e6f' -Length 8 -Attempt 0
    }

    It 'uses the future ID from the MachineGuid: valid name, TargetName and FutureId recorded' {
        $run = Invoke-SimulatedClientCommand -RenameParameters $script:P
        $run.Steps['Rename'].ExitCode | Should -Be 3010
        $run.Steps['Rename'].Text | Should -Match "SERIAL_FALLBACK: Target name 'DESIM4711AB' already exists in AD"
        $name = "DE$script:Id"
        $name | Should -Match '^[A-Z0-9_]([A-Z0-9_-]*[A-Z0-9_])?$'
        $name.Length | Should -BeLessOrEqual 15
        $global:HRSim.RenameCalls | Should -Be @($name)
        (Get-SimState).TargetName | Should -Be $name
        (Get-SimState).FutureId | Should -Be $script:Id
        $global:HRSim.Ad | Should -Contain 'DESIM4711AB'
    }
    It 'after the reboot the device is recognized as renamed and completes' {
        Invoke-SimulatedReboot
        $run = Invoke-SimulatedClientCommand -RenameParameters $script:P
        $run.Phase | Should -Be 'after-reboot'
        $run.Outcome | Should -Be 'Done'
        (Get-SimMarker).ComputerName | Should -Be "DE$script:Id"
        $global:HRSim.RenameCalls.Count | Should -Be 1
    }
}

Describe 'S8 unusable serial number ("To Be Filled By O.E.M.")' {
    It 'GenerateId (default): future ID instead of the serial number' {
        New-SimDevice -Root (Join-Path $TestDrive 'S8a') -BiosSerial 'To Be Filled By O.E.M.' -ProductSerial 'Default string' -BoardSerial 'None'
        $run = Invoke-SimulatedClientCommand -RenameParameters @{ NameTemplate = 'DE{Serial}'; NoCentralLog = $true }
        $run.Steps['Rename'].ExitCode | Should -Be 3010
        $run.Steps['Rename'].Text | Should -Match 'SERIAL_FALLBACK: No usable serial number \(BIOS: "To Be Filled By O.E.M."'
        $id = New-FutureId -Seed '0d3c5f9e-6b1a-4c2e-9f77-3a5b1c2d4e6f' -Length 8 -Attempt 0
        (Get-SimState).TargetName | Should -Be "DE$id"
        (Get-SimState).FutureId | Should -Be $id
    }
    It '-OnSerialProblem Skip: exit 5 (SERIAL_INVALID), permanent, no rename' {
        New-SimDevice -Root (Join-Path $TestDrive 'S8b') -BiosSerial 'To Be Filled By O.E.M.' -ProductSerial 'Default string' -BoardSerial 'None'
        $run = Invoke-SimulatedClientCommand -RenameParameters @{ NameTemplate = 'DE{Serial}'; NoCentralLog = $true; OnSerialProblem = 'Skip' }
        $run.Steps['Rename'].ExitCode | Should -Be 5
        $run.Steps['Rename'].Text | Should -Match '\[ERROR\] SERIAL_INVALID'
        $run.Outcome | Should -Be 'Permanent'
        (Get-SimState).LastExitCode | Should -Be 5
        $global:HRSim.RenameCalls.Count | Should -Be 0
        $run.Status.Phase | Should -Be 'Permanent'
    }
}

Describe 'S9 name already matches the template' {
    BeforeAll { New-SimDevice -Root (Join-Path $TestDrive 'S9') -Name 'DESIM4711AB' }

    It 'exit 0 (ALREADY_DONE), no reboot; the cleanup in the same run sets the marker' {
        $run = Invoke-SimulatedClientCommand -RenameParameters @{ NameTemplate = 'DE{Serial}'; NoCentralLog = $true }
        $run.Steps['Rename'].ExitCode | Should -Be 0
        $run.Steps['Rename'].Text | Should -Match 'ALREADY_DONE'
        $run.Steps['Cleanup'].ExitCode | Should -Be 0
        $run.Outcome | Should -Be 'Done'
        $run.Dialog | Should -Be ''
        $global:HRSim.RenameCalls.Count | Should -Be 0
        (Get-SimMarker).ComputerName | Should -Be 'DESIM4711AB'
        (Get-SimState).ContainsKey('TargetName') | Should -BeFalse -Because 'no rename happened, so no TargetName is recorded'
        $run.Status.Phase | Should -Be 'Done'
    }
}

Describe 'S10 GPO regression: -Deployment Gpo removes task and script copy' {
    BeforeAll {
        New-SimDevice -Root (Join-Path $TestDrive 'S10')
        $script:GpoDir = Join-Path (Join-Path $global:HRSim.Root 'ProgramFiles') 'HostRename'
        [void][System.IO.Directory]::CreateDirectory($script:GpoDir)
        $script:GpoCopy = Join-Path $script:GpoDir 'Invoke-HostRename.ps1'
        [System.IO.File]::Copy($script:Src.Invoke, $script:GpoCopy, $true)
        $global:HRSim.TaskExists = $true
    }

    It 'task run (rename + -Cleanup): 3010, marker set, task and script copy removed, local log kept' {
        # Arguments as the GPO task passes them (central log replaced by -NoCentralLog in the simulation)
        $r = Invoke-SimHostRename -Path $script:GpoCopy -Parameters @{ NameTemplate = 'DE{Serial}'; NoCentralLog = $true; LocalDir = $script:GpoDir; Cleanup = $true; TaskName = 'HostRename' }
        $r.ExitCode | Should -Be 3010
        Get-SimPendingName | Should -Be 'DESIM4711AB'
        (Get-SimState).Deployment | Should -Be 'Gpo'
        (Get-SimMarker).ComputerName | Should -Be 'DESIM4711AB'
        $global:HRSim.TaskRemovals | Should -Be @('HostRename')
        [System.IO.File]::Exists($script:GpoCopy) | Should -BeFalse -Because 'in GPO mode the cleanup deletes the script copy'
        @(Get-SimLocalLog -Path (Join-Path $script:GpoDir 'rename-local.csv')).Event[-1] | Should -Be 'CLEANUP_DONE'
        $global:HRSim.AclCalls.Count | Should -Be 0 -Because 'the folder protection is only for the ACMP default folder'
        [System.IO.Directory]::Exists($global:HRSim.LocalDir) | Should -BeFalse
        $global:HRSim.ShutdownCalls.Count | Should -Be 0
    }
    It 'the same cleanup in Acmp mode keeps the script file' {
        $r = Invoke-SimHostRename -Parameters @{ Deployment = 'Acmp'; NameTemplate = 'DE{Serial}'; NoCentralLog = $true; Cleanup = $true }
        $r.ExitCode | Should -Be 3010
        [System.IO.File]::Exists($global:HRSim.Paths.Invoke) | Should -BeTrue
        (Get-SimLocalLog | Where-Object Event -eq 'CLEANUP_DONE').Message | Should -Match "no scheduled task 'HostRename' found, script file kept"
    }
}

Describe 'S11 32-bit PowerShell on 64-bit Windows' {
    BeforeAll {
        New-SimDevice -Root (Join-Path $TestDrive 'S11')
        $global:HRSim.Device.Wow64 = $true
    }

    It 'exit 1 with PLATFORM on stdout, nothing written (no log, no reporting values, no folder)' {
        $run = Invoke-SimulatedClientCommand -RenameParameters @{ NameTemplate = 'DE{Serial}'; NoCentralLog = $true }
        $run.Steps['Rename'].ExitCode | Should -Be 1
        $run.Steps['Rename'].Text | Should -Match '\[ERROR\] PLATFORM: HostRename runs in a 32-bit PowerShell'
        $run.Outcome | Should -Be 'Retry'
        $global:HRSim.RegWrites | Should -Be 0
        [System.IO.Directory]::Exists($global:HRSim.LocalDir) | Should -BeFalse
        $global:HRSim.RenameCalls.Count | Should -Be 0
        $run.Status.Phase | Should -Be 'Open'
    }
}

Describe 'S12 local folder prepared by a standard user (LOCAL_DIR)' {
    BeforeAll {
        New-SimDevice -Root (Join-Path $TestDrive 'S12')
        [void][System.IO.Directory]::CreateDirectory($global:HRSim.LocalDir)
        $global:HRSim.Device.FolderOwner = 'S-1-5-32-545'
    }

    It 'exit 1 with LOCAL_DIR on stdout; the folder is not used; reporting values are written' {
        $run = Invoke-SimulatedClientCommand -RenameParameters @{ NameTemplate = 'DE{Serial}'; NoCentralLog = $true }
        $run.Steps['Rename'].ExitCode | Should -Be 1
        $run.Steps['Rename'].Text | Should -Match '\[ERROR\] LOCAL_DIR: owner of local folder .* is S-1-5-32-545'
        $run.Outcome | Should -Be 'Retry'
        @([System.IO.Directory]::GetFileSystemEntries($global:HRSim.LocalDir)).Count | Should -Be 0
        $global:HRSim.AclCalls.Count | Should -Be 0
        (Get-SimState).LastExitCode | Should -Be 1
        (Get-SimState).LastEvent | Should -Be 'LOCAL_DIR'
        $global:HRSim.RenameCalls.Count | Should -Be 0
    }
    It 'after an administrator removed the folder, the next run recreates and protects it and renames' {
        [System.IO.Directory]::Delete($global:HRSim.LocalDir, $true)
        $global:HRSim.Device.FolderOwner = 'S-1-5-18'
        $run = Invoke-SimulatedClientCommand -RenameParameters @{ NameTemplate = 'DE{Serial}'; NoCentralLog = $true }
        $run.Outcome | Should -Be 'RebootRequired'
        $global:HRSim.AclCalls | Should -Contain $global:HRSim.LocalDir
    }
}

# ---- Wrapper Invoke-AcmpHostRename.ps1: the whole Client Command in one script run per ACMP invocation ----------

Describe 'Wrapper structure (Invoke-AcmpHostRename.ps1)' {
    BeforeAll {
        $tk = $null; $er = $null
        $script:WrapperAst = [System.Management.Automation.Language.Parser]::ParseFile($script:Src.Wrapper, [ref]$tk, [ref]$er)
        $script:WrapperErrors = $er
    }

    It 'parses without errors' {
        @($script:WrapperErrors).Count | Should -Be 0
    }
    It 'has exactly one exit statement, inside its own exit point Exit-AcmpHostRename' {
        $exits = @($script:WrapperAst.FindAll({ param($a) $a -is [System.Management.Automation.Language.ExitStatementAst] }, $true))
        $exits.Count | Should -Be 1
        $p = $exits[0].Parent
        while ($p -and $p -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) { $p = $p.Parent }
        $p.Name | Should -Be 'Exit-AcmpHostRename'
    }
    It 'ends with the call of the exit point (after the try/catch around the flow)' {
        $last = $script:WrapperAst.EndBlock.Statements[$script:WrapperAst.EndBlock.Statements.Count - 1]
        $last.Extent.Text | Should -Be 'Exit-AcmpHostRename'
        $prev = $script:WrapperAst.EndBlock.Statements[$script:WrapperAst.EndBlock.Statements.Count - 2]
        $prev | Should -BeOfType ([System.Management.Automation.Language.TryStatementAst])
    }
    It 'calls only the three existing scripts, by name from its own folder' {
        $text = [System.IO.File]::ReadAllText($script:Src.Wrapper)
        $called = @([regex]::Matches($text, "Invoke-AcmpSubScript '([^']+)'") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        $called | Should -Be @('Invoke-HostRename.ps1', 'Test-DeploymentNetwork.ps1', 'Update-ComputerCertificate.ps1')
        $text | Should -Match 'Join-Path \$PSScriptRoot \$AcmpScript'
    }
    It 'the command lines in acmp-guide ("Recommended: the wrapper") use only its parameters, and the German guide has the same code' {
        $en = Get-MarkdownCodeBlock -Path $script:Src.Guide -Heading 'Recommended: the wrapper'
        $de = Get-MarkdownCodeBlock -Path $script:Src.GuideDe -Heading 'Empfohlen: der Wrapper'
        Remove-CodeComment $de | Should -BeExactly (Remove-CodeComment $en)
        $known = @($script:WrapperAst.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }) + 'WhatIf'
        $lines = @($en -split '\r?\n' | Where-Object { $_ -notmatch '^\s*#' -and $_ -match 'Invoke-AcmpHostRename\.ps1' })
        $lines.Count | Should -BeGreaterThan 1
        foreach ($l in $lines) {
            $tail = $l.Substring($l.IndexOf('Invoke-AcmpHostRename.ps1'))
            foreach ($m in [regex]::Matches($tail, '(?<=\s)-(\w+)')) { $known | Should -Contain $m.Groups[1].Value }
            $tail | Should -Match '-NoCentralLog|-CentralLogPath'
        }
    }
    It 'does not set $ErrorActionPreference (the called scripts run in its process and would inherit it)' {
        $assign = @($script:WrapperAst.FindAll({ param($a) $a -is [System.Management.Automation.Language.AssignmentStatementAst] -and $a.Left.Extent.Text -match 'ErrorActionPreference' }, $true))
        $assign.Count | Should -Be 0
    }
}

Describe 'W1 wrapper, LAN device: full flow over several invocations' {
    BeforeAll {
        New-SimDevice -Root (Join-Path $TestDrive 'W1') -Network Lan
        $script:P = @{ NameTemplate = 'DE{Serial}'; NoCentralLog = $true; CorporateSsid = 'CORP-WLAN' }
    }

    It 'dry run (-WhatIf): exit 0, PHASE=DryRun with the target name, nothing written' {
        $r = Invoke-SimWrapper -Parameters ($script:P + @{ WhatIf = $true })
        $r.ExitCode | Should -Be 0
        $r.Summary | Should -Match "^HOSTRENAME PHASE=DryRun EXIT=0 STEP=Rename MESSAGE=`"Dry run \(phase rename\): 'PC349219' would be renamed to 'DESIM4711AB'"
        $r.Ran | Should -Be @('Gate', 'Rename')
        $r.Text | Should -Match '(?m)^RESULT=LAN EXIT=0 '
        $global:HRSim.RegWrites | Should -Be 0
        $global:HRSim.RenameCalls.Count | Should -Be 0
        [System.IO.Directory]::Exists($global:HRSim.LocalDir) | Should -BeFalse
    }
    It 'run 1: gate, rename, exit 3010 (PHASE=RebootRequired), no cleanup' {
        $r = Invoke-SimWrapper -Parameters $script:P
        $r.ExitCode | Should -Be 3010
        $r.Summary | Should -Match '^HOSTRENAME PHASE=RebootRequired EXIT=3010 STEP=Rename '
        $r.Ran | Should -Be @('Gate', 'Rename')
        $r.Text | Should -Match "RENAMED: Successfully renamed: 'PC349219' -> 'DESIM4711AB'"
        Get-SimPendingName | Should -Be 'DESIM4711AB'
        Get-SimMarker | Should -BeNullOrEmpty
        $global:HRSim.ShutdownCalls.Count | Should -Be 0
    }
    It 'run 2 before the reboot: 3010 again (PENDING_REBOOT), no second rename' {
        $r = Invoke-SimWrapper -Parameters $script:P
        $r.ExitCode | Should -Be 3010
        $r.Summary | Should -Match '^HOSTRENAME PHASE=RebootRequired EXIT=3010 STEP=Rename '
        $r.Text | Should -Match 'PENDING_REBOOT'
        $global:HRSim.RenameCalls.Count | Should -Be 1
    }
    It 'run 3 after the reboot: gate, cleanup, exit 0 (PHASE=Done), marker set' {
        Invoke-SimulatedReboot
        $r = Invoke-SimWrapper -Parameters $script:P
        $r.ExitCode | Should -Be 0
        $r.Summary | Should -Match '^HOSTRENAME PHASE=Done EXIT=0 STEP=Cleanup MESSAGE="Cleanup done'
        $r.Ran | Should -Be @('Gate', 'Cleanup')
        $r.Text | Should -Match 'CLEANUP_DONE'
        (Get-SimMarker).ComputerName | Should -Be 'DESIM4711AB'
        (Get-SimState).LastExitCode | Should -Be 0
        [System.IO.File]::Exists($global:HRSim.Paths.Wrapper) | Should -BeTrue
        [System.IO.File]::Exists($global:HRSim.Paths.Invoke) | Should -BeTrue
        (Invoke-SimStatus).Phase | Should -Be 'Done'
    }
    It 'run 4: exit 0 at the state check (PHASE=Done), no script runs, nothing written' {
        $writes = $global:HRSim.RegWrites
        $r = Invoke-SimWrapper -Parameters $script:P
        $r.ExitCode | Should -Be 0
        $r.Summary | Should -Match '^HOSTRENAME PHASE=Done EXIT=0 STEP=StateCheck '
        @($r.Ran).Count | Should -Be 0
        $r.Output.Count | Should -Be 1 -Because 'only the summary line is printed'
        $global:HRSim.RegWrites | Should -Be $writes
        $global:HRSim.RenameCalls.Count | Should -Be 1
    }
}

Describe 'W2 wrapper, corporate WLAN only, then cable' {
    BeforeAll {
        New-SimDevice -Root (Join-Path $TestDrive 'W2') -Network CorpWlan
        # Lists as powershell.exe -File passes them: one string each
        $script:P = @{ NameTemplate = 'DE{Serial}'; NoCentralLog = $true; Allow = 'Lan,DirectAccess'; CorporateSsid = 'CORP-WLAN,CORP-WLAN-5G' }
    }

    It 'exit 20 (PHASE=Gate, LAN cable), Invoke-HostRename never runs, nothing written' {
        $r = Invoke-SimWrapper -Parameters $script:P
        $r.ExitCode | Should -Be 20
        $r.Summary | Should -Match '^HOSTRENAME PHASE=Gate EXIT=20 STEP=Gate MESSAGE="Gate RESULT=WLAN: only the corporate WLAN: ask the user to connect a LAN cable'
        $r.Ran | Should -Be @('Gate')
        $r.Text | Should -Match '(?m)^RESULT=WLAN EXIT=20 .*ALLOW=Lan,DirectAccess '
        $global:HRSim.RegWrites | Should -Be 0
        Get-SimState | Should -BeNullOrEmpty
    }
    It 'with the cable plugged in, the next run renames (3010)' {
        Set-SimNetwork -Path Lan
        $r = Invoke-SimWrapper -Parameters $script:P
        $r.ExitCode | Should -Be 3010
        $r.Phase | Should -Be 'RebootRequired'
        $global:HRSim.RenameCalls | Should -Be @('DESIM4711AB')
    }
}

Describe 'W3 wrapper, offline (home network without DirectAccess)' {
    BeforeAll { New-SimDevice -Root (Join-Path $TestDrive 'W3') -Network Offline }

    It 'exit 21 (PHASE=Gate), silent, nothing written' {
        $r = Invoke-SimWrapper -Parameters @{ NameTemplate = 'DE{Serial}'; NoCentralLog = $true; CorporateSsid = 'CORP-WLAN' }
        $r.ExitCode | Should -Be 21
        $r.Summary | Should -Match '^HOSTRENAME PHASE=Gate EXIT=21 STEP=Gate MESSAGE="Gate RESULT=NONE: no domain connection'
        $r.Ran | Should -Be @('Gate')
        $global:HRSim.RegWrites | Should -Be 0
        $global:HRSim.RenameCalls.Count | Should -Be 0
    }
}

Describe 'W4 wrapper, no delegation: permanent, then release' {
    BeforeAll {
        New-SimDevice -Root (Join-Path $TestDrive 'W4') -Delegation $false
        $script:P = @{ NameTemplate = 'DE{Serial}'; NoCentralLog = $true }
    }

    It 'exit 4 (PHASE=Permanent, STEP=Rename), LastExitCode 4 stored, no rename' {
        $r = Invoke-SimWrapper -Parameters $script:P
        $r.ExitCode | Should -Be 4
        $r.Summary | Should -Match '^HOSTRENAME PHASE=Permanent EXIT=4 STEP=Rename '
        $r.Text | Should -Match 'PERM_DENIED'
        (Get-SimState).LastExitCode | Should -Be 4
        $global:HRSim.RenameCalls.Count | Should -Be 0
    }
    It 'rerun: exit 4 at the state check, no gate, no rename, nothing written' {
        $writes = $global:HRSim.RegWrites
        $r = Invoke-SimWrapper -Parameters $script:P
        $r.ExitCode | Should -Be 4
        $r.Summary | Should -Match '^HOSTRENAME PHASE=Permanent EXIT=4 STEP=StateCheck MESSAGE="Permanent error from an earlier run \(LastExitCode 4\)'
        @($r.Ran).Count | Should -Be 0
        $global:HRSim.RegWrites | Should -Be $writes
    }
    It 'release (LastExitCode removed) after the delegation is granted: the next run renames (3010)' {
        $global:HRSim.Registry['HKLM:\SOFTWARE\HostRenameState'].Remove('LastExitCode')   # = the documented release
        $global:HRSim.Device.Delegation = $true
        $r = Invoke-SimWrapper -Parameters $script:P
        $r.ExitCode | Should -Be 3010
        $r.Ran | Should -Be @('Gate', 'Rename')
        $global:HRSim.RenameCalls | Should -Be @('DESIM4711AB')
    }
}

Describe 'W5 wrapper, WLAN user with -CertificateTemplate' {
    BeforeAll {
        New-SimDevice -Root (Join-Path $TestDrive 'W5') -Network Lan
        $global:HRSim.Certs.Add((New-SimCertificate -DnsName 'pc349219.sim.invalid', 'pc349219' -TemplateName 'SimWlanMachine' -NotAfterDays 300))
        $script:OldThumb = $global:HRSim.Certs[0].Thumbprint
        $script:P = @{ NameTemplate = 'DE{Serial}'; NoCentralLog = $true; CorporateSsid = 'CORP-WLAN'; CertificateTemplate = 'SimWlanMachine'; RemoveOldCertificates = $true }
    }

    It 'run 1 on LAN: rename 3010, the certificate step does not run before the reboot' {
        $r = Invoke-SimWrapper -Parameters $script:P
        $r.ExitCode | Should -Be 3010
        $r.Ran | Should -Be @('Gate', 'Rename')
        $global:HRSim.CertRequests.Count | Should -Be 0
    }
    It 'after the reboot, CA denies: exit 1 (PHASE=Certificate), no cleanup, marker not set' {
        Invoke-SimulatedReboot
        $global:HRSim.Device.CaDenied = $true
        $r = Invoke-SimWrapper -Parameters $script:P
        $r.ExitCode | Should -Be 1
        $r.Summary | Should -Match '^HOSTRENAME PHASE=Certificate EXIT=1 STEP=Certificate MESSAGE="Certificate RESULT=ERROR: not renewed; no cleanup'
        $r.Ran | Should -Be @('Gate', 'Certificate')
        Get-SimMarker | Should -BeNullOrEmpty
        $global:HRSim.CertRemovals.Count | Should -Be 0
    }
    It 'next run: certificate RENEWED (old one removed), then cleanup, exit 0 (PHASE=Done)' {
        $global:HRSim.Device.CaDenied = $false
        $r = Invoke-SimWrapper -Parameters $script:P
        $r.ExitCode | Should -Be 0
        $r.Ran | Should -Be @('Gate', 'Certificate', 'Cleanup')
        $r.Text | Should -Match '(?m)^RESULT=RENEWED EXIT=0 TEMPLATE=SimWlanMachine DNS=desim4711ab.sim.invalid .*REMOVED=1 '
        $r.Summary | Should -Match '^HOSTRENAME PHASE=Done EXIT=0 STEP=Cleanup '
        $global:HRSim.CertRemovals | Should -Be @($script:OldThumb)
        (Get-SimMarker).ComputerName | Should -Be 'DESIM4711AB'
    }
}

Describe 'W6 wrapper, name already matches the template' {
    BeforeAll { New-SimDevice -Root (Join-Path $TestDrive 'W6') -Name 'DESIM4711AB' }

    It 'exit 0 with the cleanup in the same run (marker set), no reboot' {
        $r = Invoke-SimWrapper -Parameters @{ NameTemplate = 'DE{Serial}'; NoCentralLog = $true }
        $r.ExitCode | Should -Be 0
        $r.Ran | Should -Be @('Gate', 'Rename', 'Cleanup')
        $r.Text | Should -Match 'ALREADY_DONE'
        $r.Summary | Should -Match '^HOSTRENAME PHASE=Done EXIT=0 STEP=Cleanup '
        (Get-SimMarker).ComputerName | Should -Be 'DESIM4711AB'
        $global:HRSim.RenameCalls.Count | Should -Be 0
    }
}

Describe 'W7 wrapper, parameter errors and a missing script' {
    BeforeAll { New-SimDevice -Root (Join-Path $TestDrive 'W7') }

    It 'neither -NoCentralLog nor -CentralLogPath: exit 1 (PHASE=Error, STEP=Parameters), nothing runs' {
        $r = Invoke-SimWrapper -Parameters @{ NameTemplate = 'DE{Serial}' }
        $r.ExitCode | Should -Be 1
        $r.Summary | Should -Match '^HOSTRENAME PHASE=Error EXIT=1 STEP=Parameters MESSAGE="Pass exactly one of -NoCentralLog or -CentralLogPath'
        @($r.Ran).Count | Should -Be 0
        $global:HRSim.RegWrites | Should -Be 0
    }
    It 'a blank -CentralLogPath or the literal two quote characters count as missing' {
        foreach ($v in ' ', "''", '""') {
            $r = Invoke-SimWrapper -Parameters @{ NameTemplate = 'DE{Serial}'; CentralLogPath = $v }
            $r.ExitCode | Should -Be 1
            $r.Step | Should -Be 'Parameters'
        }
    }
    It 'both -NoCentralLog and -CentralLogPath: exit 1' {
        $r = Invoke-SimWrapper -Parameters @{ NameTemplate = 'DE{Serial}'; NoCentralLog = $true; CentralLogPath = '\\server\share\log.csv' }
        $r.ExitCode | Should -Be 1
        $r.Message | Should -Match 'both were given'
        @($r.Ran).Count | Should -Be 0
    }
    It '-RemoveOldCertificates without -CertificateTemplate: exit 1' {
        $r = Invoke-SimWrapper -Parameters @{ NameTemplate = 'DE{Serial}'; NoCentralLog = $true; RemoveOldCertificates = $true }
        $r.ExitCode | Should -Be 1
        $r.Step | Should -Be 'Parameters'
    }
    It 'a script missing next to the wrapper: exit 1 (PHASE=Error) with the summary line, nothing written' {
        [System.IO.File]::Delete($global:HRSim.Paths.Gate)
        $r = Invoke-SimWrapper -Parameters @{ NameTemplate = 'DE{Serial}'; NoCentralLog = $true }
        $r.ExitCode | Should -Be 1
        $r.Summary | Should -Match '^HOSTRENAME PHASE=Error EXIT=1 STEP=Gate MESSAGE="Unexpected error in step Gate: Test-DeploymentNetwork.ps1 not found'
        $global:HRSim.RegWrites | Should -Be 0
    }
}

Describe 'W8 wrapper, 32-bit PowerShell on 64-bit Windows' {
    BeforeAll {
        New-SimDevice -Root (Join-Path $TestDrive 'W8')
        $global:HRSim.Device.Wow64 = $true
    }

    It 'exit 1 with [ERROR] PLATFORM before anything else; no script runs, nothing written' {
        # also without the log choice: the platform check comes first
        $r = Invoke-SimWrapper -Parameters @{ NameTemplate = 'DE{Serial}' }
        $r.ExitCode | Should -Be 1
        $r.Text | Should -Match '\[ERROR\] PLATFORM: .*Sysnative'
        $r.Summary | Should -Match '^HOSTRENAME PHASE=Error EXIT=1 STEP=Platform '
        @($r.Ran).Count | Should -Be 0
        $global:HRSim.RegWrites | Should -Be 0
        [System.IO.Directory]::Exists($global:HRSim.LocalDir) | Should -BeFalse
    }
}

Describe 'W9 wrapper, -WhatIf writes nothing (also after the reboot, with certificate template)' {
    BeforeAll {
        New-SimDevice -Root (Join-Path $TestDrive 'W9') -Network Lan
        $script:P = @{ NameTemplate = 'DE{Serial}'; NoCentralLog = $true; CertificateTemplate = 'SimWlanMachine' }
    }

    It 'after a rename and reboot: dry run exit 0 (PHASE=DryRun, phase after reboot), no certificate, no cleanup, nothing written' {
        (Invoke-SimWrapper -Parameters $script:P).ExitCode | Should -Be 3010
        Invoke-SimulatedReboot
        $writes = $global:HRSim.RegWrites
        $logLines = @(Get-SimLocalLog).Count
        $r = Invoke-SimWrapper -Parameters ($script:P + @{ WhatIf = $true })
        $r.ExitCode | Should -Be 0
        $r.Summary | Should -Match '^HOSTRENAME PHASE=DryRun EXIT=0 STEP=Rename MESSAGE="Dry run \(phase after reboot\)'
        $r.Ran | Should -Be @('Gate', 'Rename')
        $global:HRSim.RegWrites | Should -Be $writes
        @(Get-SimLocalLog).Count | Should -Be $logLines
        $global:HRSim.CertRequests.Count | Should -Be 0
        Get-SimMarker | Should -BeNullOrEmpty
    }
}
