<#
.SYNOPSIS
    HostRename - local tests: checks scripts, registry, icacls, self-deletion and name logic.

.DESCRIPTION
    Runs on any Windows machine (DC and client) as administrator and does not need an AD object.

    CHECKS
      1. Syntax of all .ps1 files in the script folder; consistent version information (variable in the client script and .NOTES)
      2. Are the CSE GUIDs for GPP "Files", "Scheduled Tasks" and "Registry" known on this system (gpprefcl.dll)?
      3. Do the icacls commands of the task work (owner and ACL of the local folder)?
      4. Can a scheduled task running as SYSTEM delete itself and then remove its own script file
         (basis of -Cleanup)?
      5. Name logic, loaded from Invoke-HostRename.ps1: name templates (placeholders, length specifications,
         shortening, error cases), evaluation of serial numbers (with given WMI values) and the generated
         future ID (stable, unique, valid alphabet)

    The tests only create temporary objects under %ProgramData%\HostRename-Pester-* and clean them up again.

.PARAMETER ScriptFolder
    Folder containing the scripts (default: the folder of this test file).

.EXAMPLE
    Invoke-Pester -Path .\HostRename.Local.Tests.ps1 -Output Detailed

.NOTES
    Produkt          HostRename
    Version          1.1.9
    Date             2026-10-30
    Execution        Administrator on the DC or client (Windows PowerShell 5.1)
    Encoding         UTF-8 with BOM (required for Windows PowerShell 5.1)

.LINK
    README.md
#>
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.3.0' }
#Requires -Version 5.1
param(
    [string]$ScriptFolder = ''
)

BeforeDiscovery {
    $folder = if ($ScriptFolder) { $ScriptFolder } else { $PSScriptRoot }
    $ScriptFiles = @(Get-ChildItem -Path $folder -Filter '*.ps1' | ForEach-Object { @{ Name = $_.Name; Path = $_.FullName } })
    $CseCases = @(
        @{ Name = 'Preferences: Files';           Guid = '{7150F9BF-48AD-4DA4-A49C-29EF4A8369BA}' }
        @{ Name = 'Preferences: Scheduled Tasks'; Guid = '{AADCED64-746C-4633-A97C-D61349046527}' }
        @{ Name = 'Preferences: Registry';        Guid = '{B087BE9D-ED37-454F-AF9C-04291E351182}' }
    )
    # Template, name, serial number, mode -> expected target name or error code (maximum length 15)
    $TemplateCases = @(
        @{ Tpl = 'DE{Serial}';           Name = 'PC349219';        Serial = 'PF2ABCDE';             Mode = 'TruncateEnd';   Ok = $true;  Expect = 'DEPF2ABCDE';      Code = '' }
        @{ Tpl = 'NG-{Name}';            Name = 'PC349219';        Serial = 'PF2ABCDE';             Mode = 'TruncateEnd';   Ok = $true;  Expect = 'NG-PC349219';     Code = '' }
        @{ Tpl = '{Name}-W11';           Name = 'PC349219';        Serial = 'PF2ABCDE';             Mode = 'TruncateEnd';   Ok = $true;  Expect = 'PC349219-W11';    Code = '' }
        @{ Tpl = 'DE-{Serial:-6}';       Name = 'PC349219';        Serial = 'PF2ABCDE';             Mode = 'TruncateEnd';   Ok = $true;  Expect = 'DE-2ABCDE';       Code = '' }
        @{ Tpl = 'DE{Serial}-{Name:-4}'; Name = 'PC349219';        Serial = 'PF2ABCDE';             Mode = 'TruncateEnd';   Ok = $true;  Expect = 'DEPF2ABCDE-9219'; Code = '' }
        @{ Tpl = '{Serial:5}-{Name:-4}'; Name = 'PC349219';        Serial = 'ABCDEFGHIJ0123456789'; Mode = 'TruncateEnd';   Ok = $true;  Expect = 'ABCDE-9219';      Code = '' }
        @{ Tpl = 'DE{Serial}';           Name = 'PC349219';        Serial = 'ABCDEFGHIJ0123456789'; Mode = 'TruncateEnd';   Ok = $true;  Expect = 'DEABCDEFGHIJ012'; Code = '' }
        @{ Tpl = 'DE{Serial}';           Name = 'PC349219';        Serial = 'ABCDEFGHIJ0123456789'; Mode = 'TruncateStart'; Ok = $true;  Expect = 'DEHIJ0123456789'; Code = '' }
        @{ Tpl = 'DE{Serial}';           Name = 'PC349219';        Serial = 'ABCDEFGHIJ0123456789'; Mode = 'Skip';          Ok = $false; Expect = '';                Code = 'TOO_LONG' }
        @{ Tpl = 'NG-{Name}';            Name = 'DESKTOP-AB12CD3'; Serial = 'PF2ABCDE';             Mode = 'TruncateEnd';   Ok = $true;  Expect = 'NG-DESKTOP-AB12'; Code = '' }
        @{ Tpl = '{Name}-W11';           Name = 'DESKTOP-AB12CD3'; Serial = 'PF2ABCDE';             Mode = 'TruncateEnd';   Ok = $true;  Expect = 'DESKTOP-AB1-W11'; Code = '' }
        @{ Tpl = 'NG-{Name}';            Name = 'ABC-DEFGHIJKLMN'; Serial = 'PF2ABCDE';             Mode = 'TruncateEnd';   Ok = $true;  Expect = 'NG-ABC-DEFGHIJK'; Code = '' }
        @{ Tpl = 'DE{Serial}-{Name}';    Name = 'PC349219';        Serial = 'PF2ABCDE';             Mode = 'TruncateEnd';   Ok = $true;  Expect = 'DEPF2ABCDE-PC34'; Code = '' }
        @{ Tpl = 'DE{Serial}-{Name}';    Name = 'PC349219';        Serial = 'PF2ABCDE';             Mode = 'TruncateStart'; Ok = $true;  Expect = 'DEPF2ABCDE-9219'; Code = '' }
        @{ Tpl = 'DE{Foo}';              Name = 'PC349219';        Serial = 'PF2ABCDE';             Mode = 'TruncateEnd';   Ok = $false; Expect = '';                Code = 'TEMPLATE' }
        @{ Tpl = '{Serial}';             Name = 'PC349219';        Serial = '123456';               Mode = 'TruncateEnd';   Ok = $false; Expect = '';                Code = 'NAME_INVALID' }
        @{ Tpl = 'ABCDEFGHIJKLMNOP{Serial}'; Name = 'PC1';         Serial = 'XYZ1234';              Mode = 'TruncateEnd';   Ok = $false; Expect = '';                Code = 'TRUNCATE' }
    )
    # WMI values (BIOS, system product, baseboard) -> expected serial number and source
    $SerialCases = @(
        @{ Label = 'Dell service tag in BIOS';                          Bios = 'ABC1234';                Csp = 'X';         Bb = 'Y';    Expect = 'ABC1234';        Source = 'BIOS' }
        @{ Label = 'Manufacturer placeholder in BIOS, system product OK'; Bios = 'To Be Filled By O.E.M.'; Csp = 'XYZ98765'; Bb = 'B';    Expect = 'XYZ98765';       Source = 'ComputerSystemProduct' }
        @{ Label = 'VM serial number with spaces and hyphens'; Bios = 'VMware-42 1a 3b 4c';    Csp = '';          Bb = '';     Expect = 'VMWARE421A3B4C'; Source = 'BIOS' }
        @{ Label = 'all sources unusable';                          Bios = 'Default string';        Csp = '0';         Bb = 'None'; Expect = '';               Source = '' }
        @{ Label = 'only a repeated character';                      Bios = '00000000';              Csp = 'FFFFFFFF';  Bb = 'xx';   Expect = '';               Source = '' }
    )
}

BeforeAll {
    $ScriptFolder = if ($ScriptFolder) { $ScriptFolder } else { $PSScriptRoot }

    # Load the name template functions from the client script (same logic as on the clients)
    $invokePath = Join-Path $ScriptFolder 'Invoke-HostRename.ps1'
    if (Test-Path $invokePath) {
        $tk = $null; $er = $null
        $invokeAst = [System.Management.Automation.Language.Parser]::ParseFile($invokePath, [ref]$tk, [ref]$er)
        $fns = $invokeAst.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -in @('Resolve-NameTemplate', 'Get-DeviceSerial', 'New-FutureId') }, $true)
        . ([scriptblock]::Create((($fns | ForEach-Object { $_.Extent.Text }) -join "`r`n")))
    }

    # Provide WMI values for the serial number tests; while empty, the real query is passed through
    $cim = @{}
    function Get-CimInstance {
        param([string]$ClassName)
        if ($cim.Count -gt 0) { [pscustomobject]$cim[$ClassName] }
        else                  { CimCmdlets\Get-CimInstance -ClassName $ClassName }
    }
}

Describe 'Prerequisites' {
    It 'runs with administrator rights' {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) |
            Should -BeTrue -Because 'Scheduled tasks as SYSTEM and icacls /setowner require administrator rights'
    }
}

Describe 'Version information' {
    It 'the version in the client script ($ScriptVersion, appears in the START log entry) matches the version in the .NOTES of all scripts' {
        # [regex]::Match instead of $Matches: Should -Match evaluates in its own scope, so $Matches would stay empty
        $inv  = Get-Content -Raw -Path (Join-Path $ScriptFolder 'Invoke-HostRename.ps1')
        $ver  = [regex]::Match($inv, "(?m)^\`$ScriptVersion\s*=\s*'([^']+)'")
        $ver.Success | Should -BeTrue -Because '$ScriptVersion was not found in Invoke-HostRename.ps1'
        $code = $ver.Groups[1].Value
        $notes = foreach ($f in Get-ChildItem -Path $ScriptFolder -Filter '*.ps1') {
            $v = [regex]::Match((Get-Content -Raw -Path $f.FullName), '(?m)^\s+Version\s+(\S+)\s*$')
            if ($v.Success) { [pscustomobject]@{ File = $f.Name; Version = $v.Groups[1].Value } }
        }
        @($notes).Count | Should -BeGreaterThan 0 -Because 'No version is given in the .NOTES of the scripts'
        $differ = @($notes | Where-Object { $_.Version -ne $code } | ForEach-Object { "$($_.File)=$($_.Version)" })
        $differ | Should -BeNullOrEmpty -Because "ScriptVersion is $code; differing: $($differ -join ', ')"
    }
}

Describe 'Syntax: <Name>' -ForEach $ScriptFiles {
    It 'parses without errors' {
        $tokens = $null; $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
        $msg = ($errors | ForEach-Object { 'Line {0}: {1}' -f $_.Extent.StartLineNumber, $_.Message }) -join '; '
        $errors | Should -BeNullOrEmpty -Because $msg
    }
}

Describe 'GPP client-side extensions on this system' {
    It '<Name> is registered (<Guid>)' -ForEach $CseCases {
        $key = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\GPExtensions\$Guid"
        Test-Path $key | Should -BeTrue -Because 'Otherwise the GUID in gPCMachineExtensionNames does not match the Windows registration'
    }
    It '<Name> is processed by gpprefcl.dll' -ForEach $CseCases {
        $key = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\GPExtensions\$Guid"
        (Get-ItemProperty -Path $key -ErrorAction Stop).DllName | Should -Match 'gpprefcl\.dll'
    }
}

Describe 'Folder hardening via icacls (commands from the scheduled task)' {
    BeforeAll {
        $gpoScript = Join-Path $ScriptFolder 'Prepare-HostRename.ps1'
        $text      = Get-Content -Path $gpoScript -Raw
        $fmtOwner  = [regex]::Match($text, '\$icaclsOwner\s*=\s*ConvertTo-XmlText \(''(?<f>[^'']+)''').Groups['f'].Value
        $fmtAcl    = [regex]::Match($text, '\$icaclsAcl\s*=\s*ConvertTo-XmlText \(''(?<f>[^'']+)''').Groups['f'].Value

        $tmp = Join-Path $env:ProgramData ('HostRename-Pester-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        $tmpFile = Join-Path $tmp 'script.ps1'
        Set-Content -Path $tmpFile -Value 'Write-Output test'

        $exitOwner = $null; $exitAcl = $null
        if ($fmtOwner -and $fmtAcl) {
            $exitOwner = (Start-Process -FilePath icacls.exe -ArgumentList ($fmtOwner -f $tmp) -Wait -PassThru -WindowStyle Hidden).ExitCode
            $exitAcl   = (Start-Process -FilePath icacls.exe -ArgumentList ($fmtAcl   -f $tmp) -Wait -PassThru -WindowStyle Hidden).ExitCode
        }
        $sid = { param($r) $r.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value }
        $dirAcl  = Get-Acl -Path $tmp
        $fileAcl = Get-Acl -Path $tmpFile
        $FSR = [System.Security.AccessControl.FileSystemRights]
        $writeMask = $FSR::WriteData -bor $FSR::AppendData -bor $FSR::Delete -bor $FSR::ChangePermissions -bor $FSR::TakeOwnership
    }
    AfterAll {
        if ($tmp -and (Test-Path $tmp)) { Remove-Item -Path $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'icacls commands could be read from Prepare-HostRename.ps1' {
        $fmtOwner | Should -Not -BeNullOrEmpty
        $fmtAcl   | Should -Not -BeNullOrEmpty
    }
    It '/setowner with SID notation (*S-1-5-32-544) is accepted' {
        $exitOwner | Should -Be 0
    }
    It '/inheritance:r /grant:r with SID notation is accepted' {
        $exitAcl | Should -Be 0
    }
    It 'owner is the Administrators group' {
        $dirAcl.GetOwner([Security.Principal.SecurityIdentifier]).Value | Should -Be 'S-1-5-32-544'
    }
    It 'inheritance from the parent folder is removed' {
        $dirAcl.AreAccessRulesProtected | Should -BeTrue
    }
    It 'SYSTEM has full control' {
        $r = $dirAcl.Access | Where-Object { (& $sid $_) -eq 'S-1-5-18' }
        ($r.FileSystemRights -band $FSR::FullControl) | Should -Be $FSR::FullControl
    }
    It 'users (S-1-5-32-545) may read but not write' {
        $r = @($dirAcl.Access | Where-Object { (& $sid $_) -eq 'S-1-5-32-545' })
        $r.Count | Should -BeGreaterThan 0
        foreach ($rule in $r) {
            ($rule.FileSystemRights -band $FSR::ReadAndExecute) | Should -Be $FSR::ReadAndExecute
            ($rule.FileSystemRights -band $writeMask) | Should -Be 0
        }
    }
    It 'the existing file in the folder also has no write permissions for users' {
        $r = @($fileAcl.Access | Where-Object { (& $sid $_) -in @('S-1-5-32-545', 'S-1-5-11', 'S-1-1-0') })
        foreach ($rule in $r) {
            ($rule.FileSystemRights -band $writeMask) | Should -Be 0
        }
    }
}

Describe 'Self-deletion of a running scheduled task (basis of -Cleanup)' {
    BeforeAll {
        $id         = [guid]::NewGuid().ToString('N')
        $dir        = Join-Path $env:ProgramData "HostRename-Pester-$id"
        $taskName   = "HostRename-Pester-SelfDelete-$id"
        $scriptPath = Join-Path $dir 'selfdelete.ps1'
        $resultPath = Join-Path $dir 'result.txt'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        $body = @'
$ErrorActionPreference = 'Stop'
$result = '__RESULT__'
try {
    Start-Sleep -Seconds 2
    Unregister-ScheduledTask -TaskName '__TASK__' -Confirm:$false
    Add-Content -Path $result -Value 'task-unregistered'
    Start-Sleep -Seconds 2
    Remove-Item -Path $PSCommandPath -Force
    Add-Content -Path $result -Value 'script-deleted'
    Add-Content -Path $result -Value 'done'
}
catch { Add-Content -Path $result -Value ('error: ' + $_.Exception.Message) }
'@
        $body = $body.Replace('__RESULT__', $resultPath).Replace('__TASK__', $taskName)
        Set-Content -Path $scriptPath -Value $body -Encoding UTF8

        $action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $scriptPath)
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal | Out-Null
        Start-ScheduledTask -TaskName $taskName

        $sw = [Diagnostics.Stopwatch]::StartNew()
        do {
            Start-Sleep -Milliseconds 500
            $finished = (Test-Path $resultPath) -and (Select-String -Path $resultPath -Pattern '^(done|error)' -Quiet)
        } until ($finished -or $sw.Elapsed.TotalSeconds -gt 60)

        $result = if (Test-Path $resultPath) { @(Get-Content -Path $resultPath) } else { @() }
    }
    AfterAll {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        if ($dir -and (Test-Path $dir)) { Remove-Item -Path $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'the task started the script and it was executed' {
        $result.Count | Should -BeGreaterThan 0 -Because 'The task wrote nothing within 60 s'
        ($result -join ' | ') | Should -Not -Match 'error:' -Because ($result -join ' | ')
    }
    It 'Unregister-ScheduledTask from within the running task works' {
        $result | Should -Contain 'task-unregistered'
    }
    It 'the script keeps running after the task is deleted' {
        $result | Should -Contain 'script-deleted'
    }
    It 'the task no longer exists afterwards' {
        Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }
    It 'the script file deleted itself' {
        Test-Path $scriptPath | Should -BeFalse
        $result | Should -Contain 'done'
    }
}

Describe 'Name templates: functions are loaded' {
    It 'Resolve-NameTemplate and Get-DeviceSerial were read from Invoke-HostRename.ps1' {
        Get-Command Resolve-NameTemplate -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        Get-Command Get-DeviceSerial     -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        Get-Command New-FutureId         -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
}

Describe 'Name template <Tpl> | Name <Name> | Serial <Serial> | <Mode>' -ForEach $TemplateCases {
    It 'produces the expected result' {
        $r = Resolve-NameTemplate -Template $Tpl.ToUpper() -CurrentName $Name -Serial $Serial -MaxLength 15 -OnTooLong $Mode
        if ($Ok) {
            $r.Ok   | Should -BeTrue -Because $r.Error
            $r.Name | Should -BeExactly $Expect
            $r.Name.Length | Should -BeLessOrEqual 15
        }
        else {
            $r.Ok   | Should -BeFalse
            $r.Code | Should -Be $Code
        }
    }
}

Describe 'Serial number evaluation (given WMI values): <Label>' -ForEach $SerialCases {
    BeforeAll {
        $cim.Clear()
        $cim['Win32_BIOS']                 = @{ SerialNumber = $Bios }
        $cim['Win32_ComputerSystemProduct'] = @{ IdentifyingNumber = $Csp }
        $cim['Win32_BaseBoard']            = @{ SerialNumber = $Bb }
        $result = Get-DeviceSerial
    }
    AfterAll { $cim.Clear() }

    It 'returns the expected serial number' {
        if ($Expect) { $result.Value | Should -BeExactly $Expect }
        else         { $result.Value | Should -BeNullOrEmpty }
    }
    It 'names the expected source' {
        if ($Source) { $result.Source | Should -Be $Source }
        else         { $result.Source | Should -BeNullOrEmpty }
    }
}

Describe 'Future ID (New-FutureId)' {
    It 'is stable for the same seed (repeated runs produce the same name)' {
        New-FutureId -Seed 'GUID-1' | Should -BeExactly (New-FutureId -Seed 'GUID-1')
    }
    It 'returns a different ID on the next attempt (collision case)' {
        New-FutureId -Seed 'GUID-1' -Attempt 1 | Should -Not -BeExactly (New-FutureId -Seed 'GUID-1' -Attempt 0)
    }
    It 'returns different IDs for different seeds' {
        $ids = 1..1000 | ForEach-Object { New-FutureId -Seed "seed-$_" }
        @($ids | Select-Object -Unique).Count | Should -Be 1000
    }
    It 'has the requested length <_>' -ForEach @(4, 8, 12) {
        (New-FutureId -Seed 'x' -Length $_).Length | Should -Be $_
    }
    It 'uses only A-Z without I and O plus 2-9' {
        $bad = 1..500 | ForEach-Object { New-FutureId -Seed "s$_" } | Where-Object { $_ -cnotmatch '^[A-HJ-NP-Z2-9]{8}$' }
        @($bad).Count | Should -Be 0
    }
    It 'never consists of digits only (even for short IDs)' {
        $bad = 1..500 | ForEach-Object { New-FutureId -Seed "s$_" -Length 4 } | Where-Object { $_ -match '^[0-9]+$' }
        @($bad).Count | Should -Be 0
    }
    It 'yields a valid name together with a template' {
        $r = Resolve-NameTemplate -Template 'DE{SERIAL}' -CurrentName 'PC349219' -Serial (New-FutureId -Seed 'GUID-1') -MaxLength 15 -OnTooLong 'TruncateEnd'
        $r.Ok | Should -BeTrue -Because $r.Error
        $r.Name | Should -Match '^DE[A-HJ-NP-Z2-9]{8}$'
    }
}
