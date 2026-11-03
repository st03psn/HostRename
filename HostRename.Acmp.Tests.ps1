<#
.SYNOPSIS
    HostRename - tests for the ACMP deployment mode and the optional central log of Invoke-HostRename.ps1.

.DESCRIPTION
    Loads the relevant functions from Invoke-HostRename.ps1 (via AST, like HostRename.Local.Tests.ps1) and tests
    them with mocks; needs neither AD nor the real registry and runs on any platform.

    CHECKS
      1. Parameter -Deployment (ValidateSet Gpo/Acmp, default Gpo); a single exit point (Exit-HostRename)
      2. Local folder per deployment mode (Resolve-LocalDir)
      3. Disabled central log (-CentralLogPath ''): Send-PendingLog, Test-LogPending, Write-RenameLog
      4. Cleanup decisions: Gpo as before, Acmp keeps the script file and its folder, no deferral without a central log
      5. Reporting values (Save-RunState / Exit-HostRename): written, not with -WhatIf, exit code unaffected by errors

.PARAMETER ScriptFolder
    Folder containing Invoke-HostRename.ps1 (default: the folder of this test file).

.EXAMPLE
    Invoke-Pester -Path .\HostRename.Acmp.Tests.ps1 -Output Detailed

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
    $ScriptFolder = if ($ScriptFolder) { $ScriptFolder } else { $PSScriptRoot }
    $invokePath   = Join-Path $ScriptFolder 'Invoke-HostRename.ps1'
    $tk = $null; $er = $null
    $invokeAst = [System.Management.Automation.Language.Parser]::ParseFile($invokePath, [ref]$tk, [ref]$er)
    $wanted = @('ConvertTo-CsvField', 'Resolve-LocalDir', 'Send-PendingLog', 'Write-RenameLog', 'Test-LogPending',
                'Invoke-Cleanup', 'Save-RunState', 'Exit-HostRename')
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
        Mock Test-Path { $false } -ParameterFilter { $Path -eq $StateKey }
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
            param([string]$Stubs, [int]$Code, [switch]$WhatIf)
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
Exit-HostRename -Code $Code
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
    It 'writes nothing under -WhatIf but still exits with the code' {
        $r = Invoke-ExitScript -Stubs '' -Code 0 -WhatIf
        $r.ExitCode | Should -Be 0
        $r.Values | Should -BeNullOrEmpty
    }
}
