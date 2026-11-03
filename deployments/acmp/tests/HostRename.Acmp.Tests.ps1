<#
.SYNOPSIS
    HostRename - tests for the ACMP deployment mode and the optional central log of Invoke-HostRename.ps1.

.DESCRIPTION
    Loads the relevant functions from Invoke-HostRename.ps1 (via AST, like tests/HostRename.Local.Tests.ps1) and tests
    them with mocks; needs neither AD nor the real registry and runs on any platform.

    CHECKS
      1. Parameter -Deployment (ValidateSet Gpo/Acmp, default Gpo); a single exit point (Exit-HostRename);
         order of the start checks (32-bit check, local folder, REBOOT_IGNORED before the done check)
      2. Local folder per deployment mode (Resolve-LocalDir); protected ACMP folder (Initialize-LocalDir,
         Set-LocalDirAcl, mocked Get-Item/Get-Acl/icacls)
      3. Disabled central log (-NoCentralLog, '' or a non-absolute path: Resolve-CentralLogPath): Send-PendingLog,
         Test-LogPending, Write-RenameLog; the whole script in a child process with -CentralLogPath "''"
      4. Cleanup decisions: Gpo as before, Acmp keeps the script file and its folder, no deferral without a central log
      5. Reporting values (Save-RunState / Exit-HostRename): written, not with -WhatIf or -SkipState, exit code
         unaffected by errors
      6. Test-CentralLog: SMB port check per address and address family (mocked)

.PARAMETER ScriptFolder
    Folder containing Invoke-HostRename.ps1 (default: the repository root, three levels above this test file:
    deployments\acmp\tests\ -> root).

.EXAMPLE
    Invoke-Pester -Path .\deployments\acmp\tests\HostRename.Acmp.Tests.ps1 -Output Detailed

.NOTES
    Product          HostRename
    Version          1.2.0
    Date             2026-11-03
    Execution        Any platform with Pester 5.3+ (no administrator rights needed)
    Encoding         UTF-8 with BOM (required for Windows PowerShell 5.1)

.LINK
    README.md
#>
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.3.0' }
#Requires -Version 5.1
param(
    [string]$ScriptFolder = ''
)

BeforeAll {
    $ScriptFolder = if ($ScriptFolder) { $ScriptFolder } else { Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) }
    $invokePath   = Join-Path $ScriptFolder 'Invoke-HostRename.ps1'
    $tk = $null; $er = $null
    $invokeAst = [System.Management.Automation.Language.Parser]::ParseFile($invokePath, [ref]$tk, [ref]$er)
    $wanted = @('ConvertTo-CsvField', 'Resolve-LocalDir', 'Send-PendingLog', 'Write-RenameLog', 'Test-LogPending',
                'Invoke-Cleanup', 'Save-RunState', 'Exit-HostRename', 'Resolve-CentralLogPath', 'Test-Wow64Process',
                'Get-OwnerSid', 'Set-LocalDirAcl', 'Initialize-LocalDir', 'Resolve-HostAddress', 'Connect-TcpAddress',
                'Test-CentralLog')
    $fns = @($invokeAst.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -in $wanted }, $true))
    $FunctionText = ($fns | ForEach-Object { $_.Extent.Text }) -join "`n"
    # Exit-HostRename calls 'exit', which would end the Pester run: it is tested in a child process instead,
    # so it is not loaded into this session.
    $inSession = @($fns | Where-Object { $_.Name -ne 'Exit-HostRename' } | ForEach-Object { $_.Extent.Text }) -join "`n"
    . ([scriptblock]::Create($inSession))

    # Stubs so that the Windows-only cmdlets can be mocked on any platform
    function Get-ScheduledTask { param($TaskName, $ErrorAction) }
    function Unregister-ScheduledTask { param($TaskName, $Confirm) }
    # -Type is a dynamic parameter of the registry provider (not available off-Windows): own stub with the full signature
    function Set-ItemProperty { param($Path, $Name, $Value, $Type) }
    # NTFS ACLs cannot be tested off-Windows: Get-Acl and icacls.exe are stubs that the tests mock
    function Get-Acl { param($LiteralPath) }
    function icacls.exe { param([Parameter(ValueFromRemainingArguments)]$Rest) }
    # Top-level statements of the script (outside function definitions), for the order of the start checks
    $topLevel = { param($name)
        @($invokeAst.FindAll({ param($a) $a -is [System.Management.Automation.Language.CommandAst] -and $a.GetCommandName() -eq $name }, $true) |
            Where-Object {
                $p = $_.Parent; $inFn = $false
                while ($p) { if ($p -is [System.Management.Automation.Language.FunctionDefinitionAst]) { $inFn = $true; break }; $p = $p.Parent }
                -not $inFn
            })
    }
}

Describe 'Parameter -Deployment and exit points' {
    It 'is a ValidateSet of Gpo and Acmp with default Gpo' {
        $p = $invokeAst.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Deployment' }
        $p | Should -Not -BeNullOrEmpty
        $p.DefaultValue.Value | Should -BeExactly 'Gpo'
        $vs = $p.Attributes | Where-Object { $_.TypeName.Name -eq 'ValidateSet' }
        @($vs.PositionalArguments | ForEach-Object { $_.Value }) | Should -Be @('Gpo', 'Acmp')
    }
    It 'the script contains exactly one exit statement (inside Exit-HostRename)' {
        $exits = @($invokeAst.FindAll({ param($a) $a.GetType().Name -eq 'ExitStatementAst' }, $true))
        $exits.Count | Should -Be 1
        $fn = $fns | Where-Object { $_.Name -eq 'Exit-HostRename' }
        $exits[0].Extent.StartOffset | Should -BeGreaterThan $fn.Extent.StartOffset
        $exits[0].Extent.EndOffset   | Should -BeLessThan $fn.Extent.EndOffset
    }
    It 'the default of -CentralLogPath is unchanged (non-empty)' {
        $p = $invokeAst.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'CentralLogPath' }
        $p.DefaultValue.Value | Should -Match '^\\\\'
    }
    It 'has the switch -NoCentralLog' {
        $p = $invokeAst.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'NoCentralLog' }
        $p | Should -Not -BeNullOrEmpty
        $p.StaticType | Should -Be ([switch])
    }
    It 'checks the 32-bit process first, then the local folder, both before the main flow (ACMP only)' {
        $wow   = @(& $topLevel 'Test-Wow64Process')
        $init  = @(& $topLevel 'Initialize-LocalDir')
        $main  = $invokeAst.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.TryStatementAst] } | Select-Object -Last 1
        $wow.Count  | Should -Be 1
        $init.Count | Should -Be 1
        $wow[0].Extent.StartOffset  | Should -BeLessThan $init[0].Extent.StartOffset
        $init[0].Extent.StartOffset | Should -BeLessThan $main.Extent.StartOffset
        # No log or reporting value before the 32-bit check: the first top-level Write-RenameLog follows it
        $firstLog = @(& $topLevel 'Write-RenameLog' | Sort-Object { $_.Extent.StartOffset })[0]
        $firstLog.Extent.StartOffset | Should -BeGreaterThan $wow[0].Extent.StartOffset
        $wowIf = $wow[0].Parent
        while ($wowIf -and $wowIf -isnot [System.Management.Automation.Language.IfStatementAst]) { $wowIf = $wowIf.Parent }
        $wowIf.Extent.Text | Should -Match "Deployment -eq 'Acmp'"
        $wowIf.Extent.Text | Should -Match 'Exit-HostRename -Code 1 -SkipState'
        $wowIf.Extent.Text | Should -Match 'NoLocalLog = \$true'
    }
    It 'creates the local folder without checks in Gpo mode and with an explicit -LocalDir (unchanged)' {
        $init = @(& $topLevel 'Initialize-LocalDir')[0]
        $if = $init.Parent
        while ($if -and $if -isnot [System.Management.Automation.Language.IfStatementAst]) { $if = $if.Parent }
        $if.Clauses[0].Item1.Extent.Text | Should -Be "`$Deployment -eq 'Acmp' -and -not `$explicitLocalDir"
        $if.ElseClause.Extent.Text | Should -Match 'TEMP'
    }
    It 'logs REBOOT_IGNORED before the done/pending check (on every run)' {
        $text = $invokeAst.Extent.Text
        $text.IndexOf("-EventName REBOOT_IGNORED") | Should -BeGreaterThan 0
        $text.IndexOf("-EventName REBOOT_IGNORED") | Should -BeLessThan $text.IndexOf('$done = $false')
        ([regex]::Matches($text, 'EventName REBOOT_IGNORED')).Count | Should -Be 1
    }
}

Describe 'Resolve-CentralLogPath' {
    It 'disables the central log for <Label>' -ForEach @(
        @{ Label = 'an empty value';          Value = '' }
        @{ Label = 'whitespace only';         Value = '   ' }
        @{ Label = "the literal ''";          Value = "''" }
        @{ Label = 'the literal ""';          Value = '""' }
        @{ Label = "the literal '' with spaces"; Value = " '' " }
    ) {
        $r = Resolve-CentralLogPath -Path $Value
        $r.Path    | Should -BeExactly ''
        $r.Warning | Should -BeExactly ''
    }
    It '-NoCentralLog wins over a valid path' {
        $r = Resolve-CentralLogPath -Path '\\srv\share\log.csv' -NoCentralLog
        $r.Path | Should -BeExactly ''
        $r.Warning | Should -BeExactly ''
    }
    It 'keeps a UNC or rooted local path: <Value>' -ForEach @(
        @{ Value = '\\FILESERVER\HostRename$\log\rename-log.csv' }
        @{ Value = '\\srv.corp.example\share\x.csv' }
        @{ Value = 'C:\Logs\rename-log.csv' }
    ) {
        $r = Resolve-CentralLogPath -Path $Value
        $r.Path    | Should -BeExactly $Value
        $r.Warning | Should -BeExactly ''
    }
    It 'disables a non-absolute path with a warning: <Value>' -ForEach @(
        @{ Value = 'rename-log.csv' }
        @{ Value = 'log\rename-log.csv' }
        @{ Value = '\\server' }
        @{ Value = '\\server\' }
        @{ Value = '\log\x.csv' }
        @{ Value = 'C:x.csv' }
        @{ Value = "'\\srv\share\x.csv'" }
    ) {
        $r = Resolve-CentralLogPath -Path $Value
        $r.Path    | Should -BeExactly ''
        $r.Warning | Should -BeExactly "central log path '$($Value.Trim())' is not an absolute path - central log disabled"
    }
}

Describe 'Test-Wow64Process' {
    It 'returns a boolean matching the current process' {
        $r = Test-Wow64Process
        $r | Should -BeOfType [bool]
        $r | Should -Be ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess)
    }
}

Describe 'Initialize-LocalDir (mocked file system and ACL)' {
    BeforeAll {
        $dir   = 'C:\ProgramData\HostRename'
        $rp    = [System.IO.FileAttributes]::Directory -bor [System.IO.FileAttributes]::ReparsePoint
        function New-FsItem { param([string]$Name, [System.IO.FileAttributes]$Attributes = 'Archive', [bool]$Container = $false)
            [pscustomobject]@{ Name = $Name; FullName = "C:\ProgramData\HostRename\$Name"; Attributes = $Attributes; PSIsContainer = $Container } }
    }
    BeforeEach {
        $script:exists = $true
        $script:owners = @{}
        Mock Test-Path { $script:exists }
        Mock New-Item { $script:exists = $true }
        Mock Get-Item { [pscustomobject]@{ FullName = $dir; Attributes = [System.IO.FileAttributes]::Directory; PSIsContainer = $true } }
        Mock Get-ChildItem { }
        Mock Get-OwnerSid { if ($script:owners.ContainsKey($Path)) { $script:owners[$Path] } else { 'S-1-5-18' } }
        Mock Set-LocalDirAcl { }
    }
    It 'creates a missing folder and protects it' {
        $script:exists = $false
        Initialize-LocalDir -Path $dir | Should -BeExactly ''
        Should -Invoke New-Item -Times 1 -Exactly -ParameterFilter { $Path -eq $dir -and $ItemType -eq 'Directory' }
        Should -Invoke Set-LocalDirAcl -Times 1 -Exactly -ParameterFilter { $Path -eq $dir -and $Container }
    }
    It 'accepts an existing folder owned by <Owner> and protects it and every file in it' -ForEach @(@{ Owner = 'S-1-5-18' }, @{ Owner = 'S-1-5-32-544' }) {
        $script:owners[$dir] = $Owner
        Mock Get-ChildItem { New-FsItem 'rename-local.csv'; New-FsItem 'pending.csv' }
        Initialize-LocalDir -Path $dir | Should -BeExactly ''
        Should -Invoke New-Item -Times 0 -Exactly
        Should -Invoke Set-LocalDirAcl -Times 1 -Exactly -ParameterFilter { $Path -eq $dir -and $Container }
        Should -Invoke Set-LocalDirAcl -Times 1 -Exactly -ParameterFilter { $Path -eq "$dir\rename-local.csv" -and -not $Container }
        Should -Invoke Set-LocalDirAcl -Times 1 -Exactly -ParameterFilter { $Path -eq "$dir\pending.csv" -and -not $Container }
    }
    It 'refuses an existing folder that is a reparse point (junction/symbolic link)' {
        Mock Get-Item { [pscustomobject]@{ FullName = $dir; Attributes = $rp; PSIsContainer = $true } }
        Initialize-LocalDir -Path $dir | Should -Match 'reparse point'
        Should -Invoke Set-LocalDirAcl -Times 0 -Exactly
        Should -Invoke Get-ChildItem -Times 0 -Exactly
    }
    It 'refuses an existing folder owned by a user' {
        $script:owners[$dir] = 'S-1-5-21-1111111111-2222222222-3333333333-1001'
        Initialize-LocalDir -Path $dir | Should -Match 'owner .* is S-1-5-21-1111111111-2222222222-3333333333-1001'
        Should -Invoke Set-LocalDirAcl -Times 0 -Exactly
    }
    It 'refuses an existing file in the folder that is a reparse point (<Name>)' -ForEach @(@{ Name = 'pending.csv' }, @{ Name = 'rename-local.csv' }) {
        $n = $Name
        Mock Get-ChildItem { New-FsItem $n ([System.IO.FileAttributes]::Archive -bor [System.IO.FileAttributes]::ReparsePoint) }
        Initialize-LocalDir -Path $dir | Should -Match "$([regex]::Escape($n)).*reparse point"
        Should -Invoke Set-LocalDirAcl -Times 0 -Exactly -ParameterFilter { $Path -ne $dir }
    }
    It 'refuses a file in the folder that is owned by a user' {
        $script:owners["$dir\pending.csv"] = 'S-1-5-21-1-2-3-1001'
        Mock Get-ChildItem { New-FsItem 'pending.csv' }
        Initialize-LocalDir -Path $dir | Should -Match 'owner of .*pending\.csv.* is S-1-5-21-1-2-3-1001'
        Should -Invoke Set-LocalDirAcl -Times 0 -Exactly -ParameterFilter { $Path -ne $dir }
    }
    It 'refuses a folder it has just created if something appeared in it before it was locked' {
        $script:exists = $false
        Mock Get-ChildItem { New-FsItem 'pending.csv' }
        Initialize-LocalDir -Path $dir | Should -Match 'just created but already contains'
    }
    It 'returns the reason (does not throw) if the folder cannot be created' {
        $script:exists = $false
        Mock New-Item { throw 'access denied' }
        Initialize-LocalDir -Path $dir | Should -Match 'could not be secured: access denied'
    }
    It 'returns the reason (does not throw) if icacls fails' {
        Mock Set-LocalDirAcl { throw 'icacls failed' }
        Initialize-LocalDir -Path $dir | Should -Match 'could not be secured: icacls failed'
    }
    It '-WhatIf: creates nothing and changes no ACL, but still checks an existing folder' {
        $WhatIfPreference = $true
        $script:exists = $false
        Initialize-LocalDir -Path $dir | Should -BeExactly ''
        Should -Invoke New-Item -Times 0 -Exactly
        $script:exists = $true
        Mock Get-ChildItem { New-FsItem 'pending.csv' }
        Initialize-LocalDir -Path $dir | Should -BeExactly ''
        Should -Invoke Set-LocalDirAcl -Times 0 -Exactly
        $script:owners[$dir] = 'S-1-5-21-1-2-3-1001'
        Initialize-LocalDir -Path $dir | Should -Match 'owner'
    }
}

Describe 'Set-LocalDirAcl and Get-OwnerSid (mocked icacls / Get-Acl)' {
    BeforeAll {
        function New-Acl { param([string[]]$Sids, [string]$Owner = 'S-1-5-18')
            $acl = [pscustomobject]@{ Sids = $Sids; Owner = $Owner }
            $acl | Add-Member -MemberType ScriptMethod -Name GetAccessRules -Value {
                param($explicit, $inherited, $type)
                foreach ($s in $this.Sids) { [pscustomobject]@{ IdentityReference = [pscustomobject]@{ Value = $s } } }
            }
            $acl | Add-Member -MemberType ScriptMethod -Name GetOwner -Value { param($type) [pscustomobject]@{ Value = $this.Owner } }
            $acl
        }
    }
    BeforeEach {
        Mock icacls.exe { $global:LASTEXITCODE = 0 }
        Mock Get-Acl { New-Acl -Sids 'S-1-5-18', 'S-1-5-32-544' }
    }
    It 'folder: owner Administrators, inheritance removed, full control (OI)(CI) for SYSTEM and Administrators by SID' {
        Set-LocalDirAcl -Path 'C:\ProgramData\HostRename' -Container
        Should -Invoke icacls.exe -Times 1 -Exactly -ParameterFilter { ($Rest -join ' ') -eq 'C:\ProgramData\HostRename /setowner *S-1-5-32-544 /C /Q' }
        Should -Invoke icacls.exe -Times 1 -Exactly -ParameterFilter { ($Rest -join ' ') -eq 'C:\ProgramData\HostRename /inheritance:r /grant:r *S-1-5-18:(OI)(CI)F *S-1-5-32-544:(OI)(CI)F /C /Q' }
        Should -Invoke icacls.exe -Times 2 -Exactly
    }
    It 'file: no inheritance flags' {
        Set-LocalDirAcl -Path 'C:\ProgramData\HostRename\pending.csv'
        Should -Invoke icacls.exe -Times 1 -Exactly -ParameterFilter { ($Rest -join ' ') -eq 'C:\ProgramData\HostRename\pending.csv /inheritance:r /grant:r *S-1-5-18:F *S-1-5-32-544:F /C /Q' }
    }
    It 'removes every other explicit entry by SID' {
        Mock Get-Acl { New-Acl -Sids 'S-1-5-18', 'S-1-5-32-545', 'S-1-5-32-544', 'S-1-5-21-1-2-3-1001', 'S-1-5-32-545' }
        Set-LocalDirAcl -Path 'D' -Container
        Should -Invoke icacls.exe -Times 1 -Exactly -ParameterFilter { ($Rest -join ' ') -eq 'D /remove *S-1-5-32-545 /C /Q' }
        Should -Invoke icacls.exe -Times 1 -Exactly -ParameterFilter { ($Rest -join ' ') -eq 'D /remove *S-1-5-21-1-2-3-1001 /C /Q' }
        Should -Invoke icacls.exe -Times 4 -Exactly
    }
    It 'throws if icacls fails' {
        Mock icacls.exe { $global:LASTEXITCODE = 5 }
        { Set-LocalDirAcl -Path 'D' -Container } | Should -Throw '*setowner*exit code 5*'
    }
    It 'Get-OwnerSid returns the owner as a SID string' {
        Mock Get-Acl { New-Acl -Sids @() -Owner 'S-1-5-32-544' }
        Get-OwnerSid -Path 'D' | Should -BeExactly 'S-1-5-32-544'
    }
}

Describe 'Test-CentralLog (mocked name resolution and connect)' {
    BeforeEach {
        Mock Resolve-HostAddress { [System.Net.IPAddress]::Parse('2001:db8::5'); [System.Net.IPAddress]::Parse('192.0.2.5') }
        Mock Connect-TcpAddress { $false }
        # Off-Windows a UNC path is a relative file name: keep it in TestDrive (.NET uses the process directory)
        $oldCwd = [Environment]::CurrentDirectory
        [Environment]::CurrentDirectory = $TestDrive
    }
    AfterEach { [Environment]::CurrentDirectory = $oldCwd }
    It 'tries each address with its own family; IPv4 answering after IPv6 is not an SmbPort failure' {
        Mock Connect-TcpAddress { $Address.AddressFamily -eq 'InterNetwork' }
        $r = Test-CentralLog -Path '\\hostrename-test.invalid\share\log.csv'
        $r.Stage | Should -Not -Be 'SmbPort'
        $r.Stage | Should -Not -Be 'NameResolution'
        Should -Invoke Connect-TcpAddress -Times 2 -Exactly -ParameterFilter { $Port -eq 445 }
    }
    It 'IPv6 only (DirectAccess) answering is not an SmbPort failure' {
        Mock Connect-TcpAddress { $Address.AddressFamily -eq 'InterNetworkV6' }
        $r = Test-CentralLog -Path '\\hostrename-test.invalid\share\log.csv'
        $r.Stage | Should -Not -Be 'SmbPort'
        Should -Invoke Connect-TcpAddress -Times 1 -Exactly
    }
    It 'SmbPort when no address answers (all addresses named)' {
        $r = Test-CentralLog -Path '\\hostrename-test.invalid\share\log.csv'
        $r.Ok | Should -BeFalse
        $r.Stage | Should -Be 'SmbPort'
        $r.Error | Should -Match '2001:db8::5, 192\.0\.2\.5'
    }
    It 'NameResolution when the server cannot be resolved' {
        Mock Resolve-HostAddress { throw 'No such host is known' }
        $r = Test-CentralLog -Path '\\hostrename-test.invalid\share\log.csv'
        $r.Stage | Should -Be 'NameResolution'
        Should -Invoke Connect-TcpAddress -Times 0 -Exactly
    }
}

Describe 'Connect-TcpAddress (local listener)' {
    It 'connects to a local listener (IPv4), false once it is closed' {
        $listener = New-Object System.Net.Sockets.TcpListener -ArgumentList ([System.Net.IPAddress]::Loopback), 0
        $listener.Start()
        try {
            $port = $listener.LocalEndpoint.Port
            Connect-TcpAddress -Address ([System.Net.IPAddress]::Loopback) -Port $port -TimeoutMs 2000 | Should -BeTrue
        }
        finally { $listener.Stop() }
        Connect-TcpAddress -Address ([System.Net.IPAddress]::Loopback) -Port $port -TimeoutMs 2000 | Should -BeFalse
    }
}

Describe 'Resolve-LocalDir' {
    BeforeAll {
        $old = @{ PD = $env:ProgramData; PF = $env:ProgramFiles; PW = $env:ProgramW6432 }
        $env:ProgramData = Join-Path $TestDrive 'ProgramData'
        $env:ProgramFiles = Join-Path $TestDrive 'ProgramFiles'
        $env:ProgramW6432 = ''
    }
    AfterAll { $env:ProgramData = $old.PD; $env:ProgramFiles = $old.PF; $env:ProgramW6432 = $old.PW }

    It 'Gpo without -LocalDir uses Program Files' {
        Resolve-LocalDir -Deployment 'Gpo' -LocalDir '' | Should -Be (Join-Path $env:ProgramFiles 'HostRename')
    }
    It 'Gpo prefers ProgramW6432 (64-bit Program Files)' {
        $env:ProgramW6432 = Join-Path $TestDrive 'PF64'
        try { Resolve-LocalDir -Deployment 'Gpo' -LocalDir '' | Should -Be (Join-Path $TestDrive 'PF64' | Join-Path -ChildPath 'HostRename') }
        finally { $env:ProgramW6432 = '' }
    }
    It 'Acmp without -LocalDir uses ProgramData' {
        Resolve-LocalDir -Deployment 'Acmp' -LocalDir '' | Should -Be (Join-Path $env:ProgramData 'HostRename')
    }
    It '<Mode> with an explicit -LocalDir keeps it' -ForEach @(@{ Mode = 'Gpo' }, @{ Mode = 'Acmp' }) {
        Resolve-LocalDir -Deployment $Mode -LocalDir 'X:\custom' | Should -Be 'X:\custom'
    }
}

Describe 'Central log disabled (-CentralLogPath empty)' {
    BeforeEach {
        $LocalDir        = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $LocalDir | Out-Null
        $LocalLog        = Join-Path $LocalDir 'rename-local.csv'
        $PendingLog      = Join-Path $LocalDir 'pending.csv'
        $CsvHeader       = 'h'
        $CentralLogPath  = ''
        $script:CurrentName = 'PC1'; $script:TargetName = ''; $script:Serial = ''; $script:MachineGuid = ''
    }
    It 'Write-RenameLog writes only the local log, no pending.csv' {
        Write-RenameLog -Level INFO -EventName TEST -Message 'm' | Out-Null
        Test-Path $LocalLog   | Should -BeTrue
        Test-Path $PendingLog | Should -BeFalse
    }
    It 'Test-LogPending is false even if a pending.csv exists' {
        Set-Content -Path $PendingLog -Value 'row'
        Test-LogPending | Should -BeFalse
    }
    It 'Send-PendingLog is a no-op (pending.csv untouched, no error, no warning logged)' {
        Set-Content -Path $PendingLog -Value 'row'
        { Send-PendingLog } | Should -Not -Throw
        Test-Path $PendingLog | Should -BeTrue
        Test-Path $LocalLog   | Should -BeFalse
    }
    It 'Write-RenameLog writes no file at all while the local folder must not be used (NoLocalLog), but prints the line' {
        $CentralLogPath = Join-Path $TestDrive 'central-nolocal.csv'
        $script:NoLocalLog = $true
        try { $out = @(Write-RenameLog -Level ERROR -EventName LOCAL_DIR -Message 'm') }
        finally { $script:NoLocalLog = $false }
        $out.Count | Should -Be 1
        $out[0] | Should -Match '\[ERROR\] LOCAL_DIR: m$'
        $script:LastEvent | Should -Be 'LOCAL_DIR'
        Test-Path $LocalLog       | Should -BeFalse
        Test-Path $PendingLog     | Should -BeFalse
        Test-Path $CentralLogPath | Should -BeFalse
    }
    It 'with a central log, Write-RenameLog still delivers (Gpo behaviour unchanged)' {
        $CentralLogPath = Join-Path $TestDrive 'central.csv'
        Write-RenameLog -Level INFO -EventName TEST -Message 'm' | Out-Null
        Test-Path $PendingLog | Should -BeFalse
        (Get-Content $CentralLogPath) -join '|' | Should -Match 'TEST'
    }
}

Describe 'Invoke-Cleanup' {
    BeforeAll {
        # Invoke-Cleanup reads $SelfPath (in the script: $PSCommandPath; here: a fake script in TestDrive)
        $scriptDir  = Join-Path $TestDrive 'acmp-cache'
        $scriptFile = Join-Path $scriptDir 'Invoke-HostRename.ps1'
        $SelfPath   = $scriptFile
        function Invoke-CleanupResult { @(Invoke-Cleanup)[-1] }   # Write-RenameLog output precedes the return value
    }
    BeforeEach {
        $LocalDir        = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $LocalDir | Out-Null
        $LocalLog        = Join-Path $LocalDir 'rename-local.csv'
        $PendingLog      = Join-Path $LocalDir 'pending.csv'
        $CsvHeader       = 'h'
        $CentralLogPath  = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.csv')
        $TaskName        = 'HostRename'
        $MarkerKey       = 'HKLM:\SOFTWARE\HostRename'
        $Deployment      = 'Gpo'
        $script:CurrentName = 'PC1'; $script:TargetName = 'NEW1'; $script:Serial = ''; $script:MachineGuid = ''
        $script:deliveryWarned = $false
        New-Item -ItemType Directory -Path $scriptDir -Force | Out-Null
        Set-Content -Path $scriptFile -Value '# fake script'
        Mock New-Item { }
        Mock Set-ItemProperty { }
        Mock Unregister-ScheduledTask { }
    }
    It 'Gpo: removes the script file, the task and the local logs and the empty LocalDir (as before)' {
        Mock Get-ScheduledTask { [pscustomobject]@{ TaskName = 'HostRename' } }
        Invoke-CleanupResult | Should -BeTrue
        Test-Path $scriptFile | Should -BeFalse
        Test-Path $scriptDir  | Should -BeFalse -Because 'the emptied script folder is removed in Gpo mode (as before)'
        Should -Invoke Unregister-ScheduledTask -Times 1 -Exactly
        Should -Invoke Set-ItemProperty -Times 1 -Exactly -ParameterFilter { $Path -eq $MarkerKey -and $Name -eq 'Completed' }
        Test-Path $LocalDir | Should -BeFalse
        (Get-Content $CentralLogPath) -join '|' | Should -Match 'CLEANUP_DONE'
        (Get-Content $CentralLogPath) -join '|' | Should -Match 'Scheduled task ''HostRename'' and script were removed\.'
    }
    It 'Gpo: does not remove a non-existing task' {
        Mock Get-ScheduledTask { $null }
        Invoke-CleanupResult | Should -BeTrue
        Should -Invoke Unregister-ScheduledTask -Times 0 -Exactly
    }
    It 'Acmp: never removes the script file or its folder, still sets the marker, removes logs and LocalDir' {
        $Deployment = 'Acmp'
        Mock Get-ScheduledTask { $null }
        Invoke-CleanupResult | Should -BeTrue
        Test-Path $scriptFile | Should -BeTrue
        Test-Path $scriptDir  | Should -BeTrue
        Should -Invoke Set-ItemProperty -Times 1 -Exactly -ParameterFilter { $Path -eq $MarkerKey -and $Name -eq 'Completed' }
        Should -Invoke Set-ItemProperty -Times 1 -Exactly -ParameterFilter { $Path -eq $MarkerKey -and $Name -eq 'ComputerName' -and $Value -eq 'NEW1' }
        Should -Invoke Unregister-ScheduledTask -Times 0 -Exactly
        Test-Path $LocalDir | Should -BeFalse
        $central = (Get-Content $CentralLogPath) -join '|'
        $central | Should -Match 'CLEANUP_DONE'
        $central | Should -Match 'no scheduled task ''HostRename'' found'
        $central | Should -Match 'script file kept'
    }
    It 'Acmp: removes the task if it exists' {
        $Deployment = 'Acmp'
        Mock Get-ScheduledTask { [pscustomobject]@{ TaskName = 'HostRename' } }
        Invoke-CleanupResult | Should -BeTrue
        Should -Invoke Unregister-ScheduledTask -Times 1 -Exactly
        (Get-Content $CentralLogPath) -join '|' | Should -Match 'scheduled task ''HostRename'' removed'
    }
    It 'Acmp: does not remove LocalDir if it is the script folder' {
        $Deployment = 'Acmp'
        $LocalDir   = $scriptDir
        $LocalLog   = Join-Path $scriptDir 'rename-local.csv'; $PendingLog = Join-Path $scriptDir 'pending.csv'
        Mock Get-ScheduledTask { $null }
        Invoke-CleanupResult | Should -BeTrue
        Test-Path $scriptDir  | Should -BeTrue
        Test-Path $scriptFile | Should -BeTrue
        Test-Path $LocalLog   | Should -BeFalse
    }
    It '<Mode> with the central log disabled: no deferral, local logs and folder are kept' -ForEach @(@{ Mode = 'Gpo' }, @{ Mode = 'Acmp' }) {
        $Deployment     = $Mode
        $CentralLogPath = ''
        Mock Get-ScheduledTask { $null }
        Invoke-CleanupResult | Should -BeTrue
        Test-Path $LocalLog | Should -BeTrue
        Test-Path $LocalDir | Should -BeTrue
        Test-Path $PendingLog | Should -BeFalse
        $log = (Get-Content $LocalLog) -join '|'
        $log | Should -Not -Match 'CLEANUP_DEFERRED'
        $log | Should -Match 'CLEANUP_DONE'
        $log | Should -Match 'kept'
        Should -Invoke Set-ItemProperty -Times 1 -Exactly -ParameterFilter { $Name -eq 'Completed' }
    }
    It '<Mode> with an unreachable central log: deferred, nothing removed, no marker' -ForEach @(@{ Mode = 'Gpo' }, @{ Mode = 'Acmp' }) {
        $Deployment     = $Mode
        $CentralLogPath = Join-Path (Join-Path $TestDrive 'no-such-dir') 'c.csv'
        Mock Start-Sleep { }
        Mock Get-ScheduledTask { [pscustomobject]@{ TaskName = 'HostRename' } }
        Set-Content -Path $PendingLog -Value 'row'
        Invoke-CleanupResult | Should -BeFalse
        Should -Invoke Set-ItemProperty -Times 0 -Exactly
        Should -Invoke Unregister-ScheduledTask -Times 0 -Exactly
        Test-Path $scriptFile | Should -BeTrue
        Test-Path $LocalLog   | Should -BeTrue
        (Get-Content $LocalLog) -join '|' | Should -Match 'CLEANUP_DEFERRED'
    }
}

Describe 'Reporting values (Save-RunState)' {
    BeforeEach {
        $StateKey      = 'HKLM:\SOFTWARE\HostRenameState'
        $MarkerKey     = 'HKLM:\SOFTWARE\HostRename'
        $Deployment    = 'Acmp'
        $ScriptVersion = '9.9.9'
        $script:LastEvent = 'RENAMED'
        $LocalDir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $LocalDir | Out-Null
        $LocalLog = Join-Path $LocalDir 'rename-local.csv'; $PendingLog = Join-Path $LocalDir 'pending.csv'
        $CsvHeader = 'h'; $CentralLogPath = ''
        $script:CurrentName = 'PC1'; $script:TargetName = ''; $script:Serial = ''; $script:MachineGuid = ''
        # Default mock without parameter filter: Pester 6 no longer falls back to the original command
        # when no parameter filter matches (Pester 5 did). File system paths are answered via .NET.
        Mock Test-Path {
            if ($Path -eq $StateKey) { return $false }
            [System.IO.File]::Exists($Path) -or [System.IO.Directory]::Exists($Path)
        }
        Mock New-Item { }
        Mock Set-ItemProperty { }
    }
    It 'writes the five values with the expected types to the state key' {
        Save-RunState -Code 3010
        Should -Invoke New-Item -Times 1 -Exactly -ParameterFilter { $Path -eq $StateKey }
        foreach ($n in 'LastRun', 'LastExitCode', 'LastEvent', 'Deployment', 'ScriptVersion') {
            Should -Invoke Set-ItemProperty -Times 1 -Exactly -ParameterFilter { $Path -eq $StateKey -and $Name -eq $n }
        }
        Should -Invoke Set-ItemProperty -Times 1 -Exactly -ParameterFilter { $Name -eq 'LastExitCode' -and $Value -eq 3010 -and $Type -eq 'DWord' }
        Should -Invoke Set-ItemProperty -Times 1 -Exactly -ParameterFilter { $Name -eq 'LastEvent' -and $Value -eq 'RENAMED' }
        Should -Invoke Set-ItemProperty -Times 1 -Exactly -ParameterFilter { $Name -eq 'Deployment' -and $Value -eq 'Acmp' }
        Should -Invoke Set-ItemProperty -Times 1 -Exactly -ParameterFilter { $Name -eq 'ScriptVersion' -and $Value -eq '9.9.9' }
        Should -Invoke Set-ItemProperty -Times 1 -Exactly -ParameterFilter { $Name -eq 'LastRun' -and $Value -match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[+-]\d{2}:\d{2}$' }
    }
    It 'does not recreate an existing key' {
        Mock Test-Path { $true } -ParameterFilter { $Path -eq $StateKey }
        Save-RunState -Code 0
        Should -Invoke New-Item -Times 0 -Exactly
    }
    It 'never touches the marker key and only writes values on the state key' {
        Save-RunState -Code 0
        Should -Invoke Set-ItemProperty -Times 0 -Exactly -ParameterFilter { $Path -ne $StateKey }
        Should -Invoke New-Item -Times 0 -Exactly -ParameterFilter { $Path -ne $StateKey }
    }
    It 'does not write anything with -WhatIf' {
        $WhatIfPreference = $true
        Save-RunState -Code 0
        Should -Invoke Set-ItemProperty -Times 0 -Exactly
        Should -Invoke New-Item -Times 0 -Exactly
    }
    It 'does not throw when writing fails and logs a local STATE warning' {
        Mock Set-ItemProperty { throw 'access denied' }
        { Save-RunState -Code 1 } | Should -Not -Throw
        (Get-Content $LocalLog) -join '|' | Should -Match 'STATE.*Run state could not be saved.*access denied'
    }
    It 'does not throw when writing fails and the local log is gone' {
        Mock Set-ItemProperty { throw 'access denied' }
        $ErrorActionPreference = 'Stop'   # as in the script
        Remove-Item -Path $LocalDir -Recurse -Force
        { Save-RunState -Code 1 } | Should -Not -Throw
    }
    It 'Write-RenameLog tracks the last event code (also local-only events)' {
        Write-RenameLog -Level INFO -EventName FIRST -Message 'a' | Out-Null
        Write-RenameLog -Level INFO -EventName SECOND -Message 'b' -LocalOnly | Out-Null
        $script:LastEvent | Should -Be 'SECOND'
    }
}

Describe 'Exit-HostRename (child process)' {
    BeforeAll {
        $pwshExe = (Get-Process -Id $PID).Path
        # Linux/macOS truncate exit codes to 8 bits (3010 -> 194); Windows keeps them
        function ConvertTo-OsExitCode { param([int]$Code) if ($PSVersionTable.PSVersion.Major -lt 6 -or $IsWindows) { $Code } else { $Code -band 255 } }
        function Invoke-ExitScript {
            param([string]$Stubs, [int]$Code, [switch]$WhatIf, [string]$ExitArgs = '')
            $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $dir | Out-Null
            $out = Join-Path $dir 'values.txt'
            $wi  = if ($WhatIf) { '$WhatIfPreference = $true' } else { '' }
            $body = @"
`$ErrorActionPreference = 'Stop'
`$StateKey = 'HKLM:\SOFTWARE\HostRenameState'; `$Deployment = 'Gpo'; `$ScriptVersion = '1.2.3'
`$LocalDir = '$dir'; `$LocalLog = Join-Path `$LocalDir 'l.csv'; `$PendingLog = Join-Path `$LocalDir 'p.csv'
`$CsvHeader = 'h'; `$CentralLogPath = ''; `$script:LastEvent = 'LASTONE'
`$script:CurrentName = 'PC1'; `$script:TargetName = ''; `$script:Serial = ''; `$script:MachineGuid = ''
function Test-Path { `$false }
function New-Item { }
function Set-ItemProperty { param(`$Path, `$Name, `$Value, `$Type) Add-Content -Path '$out' -Value "`$Name=`$Value" }
$Stubs
$FunctionText
$wi
Exit-HostRename -Code $Code $ExitArgs
Add-Content -Path '$out' -Value 'NOT-REACHED'
"@
            $f = Join-Path $dir 'run.ps1'
            Set-Content -Path $f -Value $body -Encoding UTF8
            & $pwshExe -NoProfile -File $f | Out-Null
            [pscustomobject]@{ ExitCode = $LASTEXITCODE; Values = $(if (Test-Path $out) { @(Get-Content $out) } else { @() }) }
        }
    }
    It 'exits with the given code and writes the reporting values' {
        $r = Invoke-ExitScript -Stubs '' -Code 3010
        $r.ExitCode | Should -Be (ConvertTo-OsExitCode 3010)
        $r.Values | Should -Contain 'LastExitCode=3010'
        $r.Values | Should -Contain 'LastEvent=LASTONE'
        $r.Values | Should -Contain 'Deployment=Gpo'
        $r.Values | Should -Contain 'ScriptVersion=1.2.3'
        $r.Values | Should -Not -Contain 'NOT-REACHED'
    }
    It 'keeps the exit code <Code> if writing the values fails' -ForEach @(@{ Code = 0 }, @{ Code = 1 }, @{ Code = 5 }) {
        $r = Invoke-ExitScript -Stubs 'function Set-ItemProperty { throw "registry unavailable" }' -Code $Code
        $r.ExitCode | Should -Be (ConvertTo-OsExitCode $Code)
    }
    It '-SkipState writes no reporting values (32-bit process) but exits with the code' {
        $r = Invoke-ExitScript -Stubs '' -Code 1 -ExitArgs '-SkipState'
        $r.ExitCode | Should -Be 1
        $r.Values | Should -BeNullOrEmpty
    }
    It 'writes nothing under -WhatIf but still exits with the code' {
        $r = Invoke-ExitScript -Stubs '' -Code 0 -WhatIf
        $r.ExitCode | Should -Be 0
        $r.Values | Should -BeNullOrEmpty
    }
}


Describe 'Whole script in a child process: central log disabled or unusable' {
    BeforeAll {
        $exe    = (Get-Process -Id $PID).Path
        $hostRenamePath = Join-Path $ScriptFolder 'Invoke-HostRename.ps1'
        function Invoke-HostRenameChild {
            # Runs the real script without a name template (CONFIG error, exit 1) from a fresh working directory.
            # Registry writes are replaced by stubs, so nothing changes on the test machine.
            param([string]$CentralArg, [switch]$NoCentralLog)
            $work  = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $local = Join-Path $work 'local'
            New-Item -ItemType Directory -Path $work | Out-Null
            $central = if ($NoCentralLog) { '-NoCentralLog' } else { "-CentralLogPath '$($CentralArg -replace "'", "''")'" }
            $wrapper = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.ps1')
            $body = @"
function Set-ItemProperty { }
function New-Item { param(`$Path, `$ItemType, [switch]`$Force) if (`$Path -like 'HKLM:*') { return }; Microsoft.PowerShell.Management\New-Item -Path `$Path -ItemType `$ItemType -Force:`$Force }
Set-Location -LiteralPath '$work'
[Environment]::CurrentDirectory = '$work'
& '$hostRenamePath' -Deployment Acmp -LocalDir '$local' $central
exit `$LASTEXITCODE
"@
            Set-Content -Path $wrapper -Value $body -Encoding UTF8
            $ErrorActionPreference = 'Continue'   # Windows PowerShell 5.1: stderr of a native command must not throw
            $out = & $exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $wrapper 2>$null
            [pscustomobject]@{
                Exit     = $LASTEXITCODE
                Out      = @($out)
                WorkDir  = @(Get-ChildItem -LiteralPath $work -Force | ForEach-Object { $_.Name })
                LocalLog = $(if (Test-Path (Join-Path $local 'rename-local.csv')) { (Get-Content (Join-Path $local 'rename-local.csv')) -join '|' } else { '' })
                Pending  = Test-Path (Join-Path $local 'pending.csv')
            }
        }
    }
    It 'the literal <Label> writes no junk file and no pending.csv' -ForEach @(
        @{ Label = "''"; Arg = "''" }
        @{ Label = '""'; Arg = '""' }
        @{ Label = 'blank'; Arg = '  ' }
    ) {
        $r = Invoke-HostRenameChild -CentralArg $Arg
        $r.Exit | Should -Be 1
        $r.WorkDir | Should -Be @('local')
        $r.Pending | Should -BeFalse
        $r.LocalLog | Should -Not -Match 'not an absolute path'
        $r.LocalLog | Should -Match '"ERROR";"(CONFIG|RENAME_FAILED)"'
    }
    It '-NoCentralLog writes only the local log' {
        $r = Invoke-HostRenameChild -NoCentralLog
        $r.Exit | Should -Be 1
        $r.WorkDir | Should -Be @('local')
        $r.Pending | Should -BeFalse
        $r.LocalLog | Should -Match '"ERROR";"(CONFIG|RENAME_FAILED)"'
    }
    It 'a relative path is disabled with the warning LOG_CHECK and is not written' {
        $r = Invoke-HostRenameChild -CentralArg 'rename-log.csv'
        $r.Exit | Should -Be 1
        $r.WorkDir | Should -Be @('local')
        $r.Pending | Should -BeFalse
        $r.LocalLog | Should -Match '"WARN";"LOG_CHECK";.*central log path ''rename-log\.csv'' is not an absolute path - central log disabled'
        ($r.Out -join '|') | Should -Match 'LOG_CHECK: central log path'
    }
}
