<#
.SYNOPSIS
    HostRename - client tests: checks from the pilot device's point of view what could not be clarified without a real AD.

.DESCRIPTION
    Run as local administrator on the pilot device. Everything that has to count as "the computer" runs in
    a temporary scheduled task as SYSTEM (= computer account on the network).

    CHECKS
      1. SYSTEM context: domain membership, secure channel
      2. Permission to rename: runs the real function Test-AdRenamePermission from
         Invoke-HostRename.ps1 in the SYSTEM context and shows which attributes the computer account
         may write
      3. Name template: preview of the target name for this device (serial number or future ID, shortening)
         using the real functions from Invoke-HostRename.ps1, without changing anything
      4. Log share: can the computer account append? (writes a test file pester-write-test-<PC>.csv)
      5. Source share: can the computer account read the script but not change it?
      6. GPO: is applied on this device according to gpresult
      7. Deployment state
           PreRun    before the first run: script copied, task created correctly from the GPP, trigger,
                     local folder not writable for users
           PostRun   after rename and reboot: name per template, AD object, marker, task and script
                     removed, central logs complete, local log files and folder removed
           Auto      chooses automatically based on the registry marker
      8. Optional (-RunIltRoundtrip, only on a pilot device before the first run): proves via gpupdate
         that item-level targeting works (marker set = the GPO does not create task and script,
         marker removed = the GPO creates both again)

    Configuration: HostRename.Checks.psd1 (written by Prepare-HostRename.ps1 during setup).

.PARAMETER ConfigPath
    Path of the test configuration (default: HostRename.Checks.psd1 next to this file).

.PARAMETER ScriptFolder
    Folder containing Invoke-HostRename.ps1 (default: the folder of this test file).

.PARAMETER Phase
    Auto, PreRun or PostRun (see above; default: Auto).

.PARAMETER RunIltRoundtrip
    Additionally runs the roundtrip test for item-level targeting. Temporarily changes the task and
    script on the pilot device; the GPO restores both.

.PARAMETER SkipGpUpdate
    Skips the gpupdate before the test.

.EXAMPLE
    Invoke-Pester -Path .\HostRename.Client.Tests.ps1 -Output Detailed

    Checks the pilot device before the first run (the phase is chosen automatically).

.EXAMPLE
    $c = New-PesterContainer -Path .\HostRename.Client.Tests.ps1 -Data @{ Phase = 'PostRun' }
    Invoke-Pester -Container $c -Output Detailed

    Checks the device after rename and reboot.

.EXAMPLE
    $c = New-PesterContainer -Path .\HostRename.Client.Tests.ps1 -Data @{ RunIltRoundtrip = $true }
    Invoke-Pester -Container $c -Output Detailed

    Roundtrip test for item-level targeting on the pilot device.

.NOTES
    Product          HostRename
    Version          1.2.0
    Date             2026-11-03
    Execution        Local administrator on the pilot device (Windows PowerShell 5.1)
    Encoding         UTF-8 with BOM (required for Windows PowerShell 5.1)

.LINK
    README.md
#>
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.3.0' }
#Requires -Version 5.1
param(
    [string]$ConfigPath   = '',
    [string]$ScriptFolder = '',
    [ValidateSet('Auto', 'PreRun', 'PostRun')]
    [string]$Phase = 'Auto',
    [bool]$RunIltRoundtrip = $false,
    [bool]$SkipGpUpdate    = $false
)

BeforeAll {
    $ConfigPath   = if ($ConfigPath)   { $ConfigPath }   else { Join-Path $PSScriptRoot 'HostRename.Checks.psd1' }
    $ScriptFolder = if ($ScriptFolder) { $ScriptFolder } else { $PSScriptRoot }
    if (-not (Test-Path $ConfigPath)) {
        throw "Configuration '$ConfigPath' is missing. First run .\Prepare-HostRename.ps1 -Action Setup (writes the file from the script's variables) or copy HostRename.Checks.beispiel.psd1 to HostRename.Checks.psd1 and adjust it."
    }
    $cfg = Import-PowerShellDataFile -Path $ConfigPath

    $localScript  = Join-Path $cfg.LocalFolder $cfg.ScriptName
    $sourceScript = Join-Path $cfg.SourceShareFolder $cfg.ScriptName
    $markerPath   = 'HKLM:\' + $cfg.MarkerRegistryKey
    $deployScript = Join-Path $ScriptFolder 'Invoke-HostRename.ps1'

    $phaseResolved = if ($Phase -ne 'Auto') { $Phase } elseif (Test-Path $markerPath) { 'PostRun' } else { 'PreRun' }

    function Invoke-AsSystem {
        # Runs code in a temporary scheduled task as SYSTEM and returns the (JSON) result.
        param(
            [Parameter(Mandatory)][string]$Code,
            [hashtable]$Variables = @{},
            [int]$TimeoutSec = 120
        )
        $id   = [guid]::NewGuid().ToString('N')
        $dir  = Join-Path $env:ProgramData "HostRename-Pester-$id"
        $task = "HostRename-Pester-$id"
        $ps1  = Join-Path $dir 'run.ps1'
        $out  = Join-Path $dir 'result.json'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        $pre = ''
        foreach ($k in $Variables.Keys) {
            $pre += ('${0} = ''{1}''' -f $k, ([string]$Variables[$k]).Replace("'", "''")) + "`r`n"
        }
        $template = @'
$ErrorActionPreference = 'Stop'
__PRE__
try {
    $result = & {
__CODE__
    }
    $result | ConvertTo-Json -Depth 6 -Compress | Set-Content -Path '__OUT__' -Encoding UTF8
}
catch {
    @{ Error = $_.Exception.Message } | ConvertTo-Json -Compress | Set-Content -Path '__OUT__' -Encoding UTF8
}
'@
        $body = $template.Replace('__PRE__', $pre).Replace('__CODE__', $Code).Replace('__OUT__', $out)
        Set-Content -Path $ps1 -Value $body -Encoding UTF8

        $action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $ps1)
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        try {
            Register-ScheduledTask -TaskName $task -Action $action -Principal $principal | Out-Null
            Start-ScheduledTask -TaskName $task
            $sw = [Diagnostics.Stopwatch]::StartNew()
            while (-not (Test-Path $out) -and $sw.Elapsed.TotalSeconds -lt $TimeoutSec) { Start-Sleep -Milliseconds 500 }
            Start-Sleep -Milliseconds 500
            if (Test-Path $out) { return (Get-Content -Path $out -Raw -Encoding UTF8 | ConvertFrom-Json) }
            return [pscustomobject]@{ Error = "Timeout after $TimeoutSec s" }
        }
        finally {
            Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction SilentlyContinue
            Remove-Item -Path $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    function Invoke-GpUpdate {
        Start-Process -FilePath gpupdate.exe -ArgumentList '/target:computer', '/force' -Wait -WindowStyle Hidden
        Start-Sleep -Seconds 5
    }

    function Get-ComputerNames {
        $k = 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName'
        [pscustomobject]@{
            Active  = (Get-ItemProperty "$k\ActiveComputerName").ComputerName
            Pending = (Get-ItemProperty "$k\ComputerName").ComputerName
        }
    }

    $names = Get-ComputerNames
}

Describe 'Prerequisites' {
    It 'runs with administrator rights' {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) | Should -BeTrue
    }
    It 'the device is a member of a domain' {
        (Get-CimInstance Win32_ComputerSystem).PartOfDomain | Should -BeTrue
    }
    It 'Invoke-HostRename.ps1 is located next to the tests (for the function check)' {
        Test-Path $deployScript | Should -BeTrue -Because "Expected: $deployScript"
    }
}

Describe 'Computer account context (SYSTEM)' {
    BeforeAll {
        $sys = Invoke-AsSystem -Code @'
$cs = Get-CimInstance Win32_ComputerSystem
[pscustomobject]@{
    User          = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    UserSid       = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    PartOfDomain  = $cs.PartOfDomain
    Domain        = $cs.Domain
    SecureChannel = [bool](Test-ComputerSecureChannel)
}
'@
    }
    It 'the test actually runs as SYSTEM' {
        $sys.Error | Should -BeNullOrEmpty
        $sys.UserSid | Should -Be 'S-1-5-18' -Because "User: $($sys.User)"
    }
    It 'the secure channel to the domain is intact' {
        $sys.SecureChannel | Should -BeTrue
    }
}

Describe 'Permission to rename (real function from Invoke-HostRename.ps1, as SYSTEM)' {
    BeforeAll {
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($deployScript, [ref]$tokens, [ref]$errors)
        $wanted = @('ConvertTo-LdapEscaped', 'Test-AdRenamePermission')
        $fn = $ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -in $wanted }, $true)
        $fnText = ($fn | ForEach-Object { $_.Extent.Text }) -join "`r`n"

        $call = @'

$cs   = Get-CimInstance Win32_ComputerSystem
$name = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName').ComputerName
Test-AdRenamePermission -ComputerName $name -DomainName $cs.Domain
'@
        $perm = Invoke-AsSystem -Code ($fnText + $call)
    }
    It 'both functions were found in the script' {
        $fn.Count | Should -Be 2
    }
    It 'the computer object is found in AD' {
        $perm.Error | Should -BeNullOrEmpty
        $perm.Found | Should -BeTrue
    }
    It 'the write permissions can be evaluated (allowedAttributesEffective is not empty)' {
        $perm.Inconclusive | Should -BeFalse -Because 'Otherwise Invoke-HostRename.ps1 would continue with WARN without knowing the permission'
    }
    It 'cn and sAMAccountName are writable for the computer account (delegation is effective)' {
        Write-Host "    Writable (relevant attributes): $(@($perm.Writable) -join ', ')"
        Write-Host "    Note: dNSHostName/servicePrincipalName only appear if Validated Writes are reported there - this is not critical."
        @($perm.Missing) | Should -BeNullOrEmpty -Because "Missing: $(@($perm.Missing) -join ', ') - check the delegation (Prepare-HostRename.ps1 -Action Setup -Component Delegation) or the device's OU"
    }
}

Describe 'Name template on this device (preview, phase PreRun only)' {
    BeforeAll {
        $tpl = if ($cfg.NameTemplate) { $cfg.NameTemplate } elseif ($cfg.Prefix -or $cfg.Suffix) { '{0}{{Name}}{1}' -f $cfg.Prefix, $cfg.Suffix } else { '' }
        $tpl        = $tpl.ToUpper()
        $usesSerial = $tpl -match '\{SERIAL(:-?\d+)?\}'
        $onTooLong  = if ($cfg.OnTooLong) { $cfg.OnTooLong } else { 'TruncateEnd' }
        $likePattern = if ($cfg.NameLike) { $cfg.NameLike } else { "$($cfg.Prefix)*" }

        $tk2 = $null; $er2 = $null
        $ast2 = [System.Management.Automation.Language.Parser]::ParseFile($deployScript, [ref]$tk2, [ref]$er2)
        $fns2 = $ast2.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -in @('Resolve-NameTemplate', 'Get-DeviceSerial', 'New-FutureId') }, $true)
        . ([scriptblock]::Create((($fns2 | ForEach-Object { $_.Extent.Text }) -join "`r`n")))

        $onSerial = if ($cfg.OnSerialProblem) { $cfg.OnSerialProblem } else { 'GenerateId' }
        $idLength = if ($cfg.FutureIdLength) { [int]$cfg.FutureIdLength } else { 8 }
        $serial   = if ($usesSerial) { Get-DeviceSerial } else { $null }
        $serialValue = ''
        $usedFutureId = $false
        if ($usesSerial) {
            if ($serial.Value) { $serialValue = $serial.Value }
            elseif ($onSerial -eq 'GenerateId') {
                $seed = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Cryptography').MachineGuid
                $serialValue = New-FutureId -Seed $seed -Length $idLength -Attempt 0
                $usedFutureId = $true
            }
        }
        $plan = $null
        if ($tpl -and (-not $usesSerial -or $serialValue)) {
            $plan = Resolve-NameTemplate -Template $tpl -CurrentName $names.Active -Serial $serialValue -MaxLength 15 -OnTooLong $onTooLong
        }
    }
    It 'yields a usable serial number or (with GenerateId) a future ID (only if the template uses {Serial})' {
        if ($phaseResolved -ne 'PreRun') { Set-ItResult -Skipped -Because "Phase is $phaseResolved"; return }
        if (-not $usesSerial)            { Set-ItResult -Skipped -Because 'The template does not use {Serial}'; return }
        if ($usedFutureId) { Write-Host "    No usable serial number (discarded: $(@($serial.Rejected) -join '; ')) -> future ID '$serialValue'" }
        else               { Write-Host "    Serial number: '$($serial.Value)' (source: $($serial.Source))" }
        $serialValue | Should -Not -BeNullOrEmpty -Because "OnSerialProblem = $onSerial; discarded values: $(@($serial.Rejected) -join '; ')"
    }
    It 'yields a valid target name for this device' {
        if ($phaseResolved -ne 'PreRun') { Set-ItResult -Skipped -Because "Phase is $phaseResolved"; return }
        $plan | Should -Not -BeNullOrEmpty -Because 'No rule configured or no usable serial number'
        Write-Host "    Vorschau: $($names.Active) -> $($plan.Name)$(if ($plan.Truncated) { '  (shortened)' })"
        $plan.Ok | Should -BeTrue -Because $plan.Error
    }
    It 'the target name matches the expected pattern (NameLike)' {
        if ($phaseResolved -ne 'PreRun') { Set-ItResult -Skipped -Because "Phase is $phaseResolved"; return }
        $plan.Name | Should -BeLike $likePattern
    }
}

Describe 'Central log share as seen by the computer account' {
    BeforeAll {
        $logDir   = Split-Path -Path $cfg.CentralLogPath -Parent
        $testFile = Join-Path $logDir ('pester-write-test-' + $env:COMPUTERNAME + '.csv')
        $write = Invoke-AsSystem -Variables @{ LogDir = $logDir } -Code @'
$file = Join-Path $LogDir ('pester-write-test-' + $env:COMPUTERNAME + '.csv')
$fs = [System.IO.File]::Open($file, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
try {
    $sw = New-Object System.IO.StreamWriter($fs, (New-Object System.Text.UTF8Encoding($true)))
    $sw.WriteLine('Pester write test ' + (Get-Date -Format s))
    $sw.Flush()
}
finally { $fs.Dispose() }
@{ Written = $true }
'@
    }
    It 'the computer account can append with the same options as the script (Append, FileShare.Read)' {
        $write.Error   | Should -BeNullOrEmpty
        $write.Written | Should -BeTrue
    }
    AfterAll {
        # Clean up the test file (the computer account usually has no delete rights, the admin does)
        if ($testFile -and (Test-Path $testFile)) { Remove-Item -Path $testFile -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Source share as seen by the computer account' {
    BeforeAll {
        $srcInfo = Invoke-AsSystem -Variables @{ Source = $sourceScript } -Code @'
$hash = (Get-FileHash -Path $Source -Algorithm SHA256).Hash
$canWrite = $false
try {
    $fs = [System.IO.File]::Open($Source, 'Open', 'Write', 'ReadWrite')
    $fs.Dispose()
    $canWrite = $true
}
catch { }
@{ Hash = $hash; CanWrite = $canWrite }
'@
        $adminHash = if (Test-Path $sourceScript) { (Get-FileHash -Path $sourceScript -Algorithm SHA256).Hash } else { $null }
    }
    It 'the computer account can read the script' {
        $srcInfo.Error | Should -BeNullOrEmpty
        $srcInfo.Hash  | Should -Be $adminHash
    }
    It 'the computer account can NOT change the script (protection against tampering)' {
        $srcInfo.CanWrite | Should -BeFalse
    }
}

Describe 'GPO application on this device' {
    BeforeAll {
        $tmp = Join-Path $env:TEMP ('gpresult-' + [guid]::NewGuid().ToString('N') + '.xml')
        & gpresult.exe /scope computer /x $tmp /f | Out-Null
        $gpr = $null
        if (Test-Path $tmp) { $gpr = New-Object System.Xml.XmlDocument; $gpr.Load($tmp) }
        $applied = if ($gpr) { @($gpr.Rsop.ComputerResults.GPO | Where-Object { $_.Name -eq $cfg.GpoName }) } else { @() }
    }
    AfterAll { if ($tmp) { Remove-Item -Path $tmp -Force -ErrorAction SilentlyContinue } }

    It 'the GPO appears in the computer policy results' {
        $applied.Count | Should -BeGreaterThan 0 -Because 'OU link (link enabled?), security filtering, or no gpupdate yet?'
    }
    It 'the GPO is not excluded by filter or permission' {
        if ($applied.Count -eq 0) { Set-ItResult -Skipped -Because 'GPO not in the result list'; return }
        $applied[0].FilterAllowed | Should -Be 'true'
        $applied[0].AccessDenied  | Should -Be 'false'
    }
}

Describe 'Deployment state before the first run (phase PreRun)' {
    BeforeAll {
        $t       = Get-ScheduledTask -TaskName $cfg.TaskName -ErrorAction SilentlyContinue
        $info    = if ($t) { Get-ScheduledTaskInfo -TaskName $cfg.TaskName } else { $null }
        $actions = if ($t) { @($t.Actions) } else { @() }
    }
    It 'the script was placed locally via GPP' {
        if ($phaseResolved -ne 'PreRun') { Set-ItResult -Skipped -Because "Phase is $phaseResolved"; return }
        Test-Path $localScript | Should -BeTrue
    }
    It 'the local copy is identical to the original on the share' {
        if ($phaseResolved -ne 'PreRun') { Set-ItResult -Skipped -Because "Phase is $phaseResolved"; return }
        (Get-FileHash $localScript -Algorithm SHA256).Hash | Should -Be (Get-FileHash $sourceScript -Algorithm SHA256).Hash
    }
    It 'the local copy is syntactically correct' {
        if ($phaseResolved -ne 'PreRun') { Set-ItResult -Skipped -Because "Phase is $phaseResolved"; return }
        $tk = $null; $er = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($localScript, [ref]$tk, [ref]$er)
        $er | Should -BeNullOrEmpty
    }
    It 'the scheduled task was created from the GPP' {
        if ($phaseResolved -ne 'PreRun') { Set-ItResult -Skipped -Because "Phase is $phaseResolved"; return }
        $t | Should -Not -BeNullOrEmpty
    }
    It 'the task runs as SYSTEM with highest privileges' {
        if ($phaseResolved -ne 'PreRun') { Set-ItResult -Skipped -Because "Phase is $phaseResolved"; return }
        $t.Principal.UserId   | Should -Match 'SYSTEM|S-1-5-18'
        $t.Principal.RunLevel | Should -Be 'Highest'
    }
    It 'the last action starts the local script with the configured rename rule' {
        if ($phaseResolved -ne 'PreRun') { Set-ItResult -Skipped -Because "Phase is $phaseResolved"; return }
        $last = $actions[-1]
        $last.Execute   | Should -Be 'powershell.exe'
        $last.Arguments | Should -Match ([regex]::Escape($localScript))
        $rule = if ($cfg.NameTemplate) { '-NameTemplate "' + $cfg.NameTemplate + '"' } else { '-Prefix "' + $cfg.Prefix + '"' }
        $last.Arguments | Should -Match ([regex]::Escape($rule))
    }
    It 'the task passes -OnSerialProblem and -FutureIdLength (only if the template uses {Serial})' {
        if ($phaseResolved -ne 'PreRun') { Set-ItResult -Skipped -Because "Phase is $phaseResolved"; return }
        if ($cfg.NameTemplate -notmatch '\{SERIAL(:-?\d+)?\}') { Set-ItResult -Skipped -Because 'The template does not use {Serial}'; return }
        $mode = if ($cfg.OnSerialProblem) { $cfg.OnSerialProblem } else { 'GenerateId' }
        $len  = if ($cfg.FutureIdLength)  { $cfg.FutureIdLength }  else { 8 }
        $actions[-1].Arguments | Should -Match ([regex]::Escape("-OnSerialProblem $mode"))
        $actions[-1].Arguments | Should -Match ([regex]::Escape("-FutureIdLength $len"))
    }
    It 'the task passes -Cleanup (only if cleanup is expected)' {
        if ($phaseResolved -ne 'PreRun') { Set-ItResult -Skipped -Because "Phase is $phaseResolved"; return }
        if (-not $cfg.ExpectCleanup)     { Set-ItResult -Skipped -Because 'ExpectCleanup = $false'; return }
        $actions[-1].Arguments | Should -Match '-Cleanup'
    }
    It 'the task runs the icacls hardening first (only if hardening is expected)' {
        if ($phaseResolved -ne 'PreRun') { Set-ItResult -Skipped -Because "Phase is $phaseResolved"; return }
        if (-not $cfg.ExpectHardening)   { Set-ItResult -Skipped -Because 'ExpectHardening = $false'; return }
        $actions.Count      | Should -BeGreaterOrEqual 3
        $actions[0].Execute | Should -Be 'icacls.exe'
        $actions[1].Execute | Should -Be 'icacls.exe'
    }
    It 'the task has a system startup trigger' {
        if ($phaseResolved -ne 'PreRun') { Set-ItResult -Skipped -Because "Phase is $phaseResolved"; return }
        @($t.Triggers | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_TaskBootTrigger' }).Count | Should -BeGreaterThan 0
    }
    It 'standard users must not create or change anything in the local folder (default ACL or hardening)' {
        if ($phaseResolved -ne 'PreRun') { Set-ItResult -Skipped -Because "Phase is $phaseResolved"; return }
        if (-not (Test-Path $cfg.LocalFolder)) { Set-ItResult -Skipped -Because 'The local folder does not exist yet (GPO not applied yet)'; return }
        $FSR2 = [System.Security.AccessControl.FileSystemRights]
        $mask = $FSR2::WriteData -bor $FSR2::AppendData -bor $FSR2::Delete -bor $FSR2::DeleteSubdirectoriesAndFiles -bor $FSR2::ChangePermissions -bor $FSR2::TakeOwnership
        $bad = @((Get-Acl -Path $cfg.LocalFolder).Access | Where-Object {
            $sid = try { $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value } catch { '' }
            $_.AccessControlType -eq 'Allow' -and $sid -in @('S-1-5-32-545', 'S-1-5-11', 'S-1-1-0') -and (($_.FileSystemRights -band $mask) -ne 0) })
        $bad | Should -BeNullOrEmpty -Because (($bad | ForEach-Object { "$($_.IdentityReference): $($_.FileSystemRights)" }) -join '; ')
    }
    It 'the task has a registration trigger without delay (only if RegistrationTrigger is set)' {
        if ($phaseResolved -ne 'PreRun') { Set-ItResult -Skipped -Because "Phase is $phaseResolved"; return }
        if (-not $cfg.RegistrationTrigger) { Set-ItResult -Skipped -Because 'RegistrationTrigger is disabled'; return }
        $reg = @($t.Triggers | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_TaskRegistrationTrigger' })
        $reg.Count | Should -BeGreaterThan 0
        $reg[0].Delay | Should -BeNullOrEmpty
    }
    It 'the task has the daily trigger with repetition (only if RepeatInterval is set)' {
        if ($phaseResolved -ne 'PreRun') { Set-ItResult -Skipped -Because "Phase is $phaseResolved"; return }
        if (-not $cfg.RepeatInterval) { Set-ItResult -Skipped -Because 'RepeatInterval is empty'; return }
        $daily = @($t.Triggers | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_TaskDailyTrigger' })
        $daily.Count | Should -BeGreaterThan 0
        $daily[0].Repetition.Interval | Should -Be $cfg.RepeatInterval
    }
    It 'the task has run since it was created (note: LastRunTime/LastTaskResult are displayed)' {
        if ($phaseResolved -ne 'PreRun') { Set-ItResult -Skipped -Because "Phase is $phaseResolved"; return }
        if (-not $info) { Set-ItResult -Skipped -Because 'No task present'; return }
        Write-Host "    LastRunTime: $($info.LastRunTime)   LastTaskResult: 0x$('{0:X}' -f $info.LastTaskResult)   NextRunTime: $($info.NextRunTime)"
        if ($info.LastRunTime -lt [datetime]'2001-01-01') { Set-ItResult -Skipped -Because 'The task has not run yet (0x41303); run Start-ScheduledTask -TaskName ' + $cfg.TaskName + ' to start it manually'; return }
        $info.LastTaskResult | Should -BeIn @(0, 3010) -Because 'Expected 0 (nothing to do) or 3010 (renamed, reboot required)'
    }
    It 'the local folder is hardened as soon as the task has run once' {
        if ($phaseResolved -ne 'PreRun')  { Set-ItResult -Skipped -Because "Phase is $phaseResolved"; return }
        if (-not $cfg.ExpectHardening)    { Set-ItResult -Skipped -Because 'ExpectHardening = $false'; return }
        if (-not $info -or $info.LastRunTime -lt [datetime]'2001-01-01') { Set-ItResult -Skipped -Because 'The task has never run'; return }
        $acl = Get-Acl -Path $cfg.LocalFolder
        $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value | Should -Be 'S-1-5-32-544'
        $acl.AreAccessRulesProtected | Should -BeTrue
    }
}

Describe 'Result after rename and reboot (phase PostRun)' {
    BeforeAll {
        $localLog  = Join-Path $cfg.LocalFolder 'rename-local.csv'
        $localRows = if (Test-Path $localLog) { @(Import-Csv -Path $localLog -Delimiter ';' -Encoding UTF8) } else { @() }
        $machineGuid = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Cryptography').MachineGuid
    }
    It 'the active computer name matches the name template' {
        if ($phaseResolved -ne 'PostRun') { Set-ItResult -Skipped -Because "Phase is $phaseResolved"; return }
        $nameLike = if ($cfg.NameLike) { $cfg.NameLike } else { "$($cfg.Prefix)*" }
        if ($names.Pending -like $nameLike -and $names.Active -notlike $nameLike) {
            Set-ItResult -Skipped -Because "Rename to '$($names.Pending)' is pending - reboot required"; return
        }
        $names.Active | Should -BeLike $nameLike
    }
    It 'the state (HostRenameState) contains target name and template' {
        if ($phaseResolved -ne 'PostRun') { Set-ItResult -Skipped -Because "Phase is $phaseResolved"; return }
        $stateKey = 'HKLM:\SOFTWARE\HostRenameState'
        # Since 1.2.0 the key also holds reporting values (LastRun, LastExitCode, ...) after every run,
        # so its mere existence does not mean that HostRename renamed the device: check TargetName.
        $st = if (Test-Path $stateKey) { Get-ItemProperty -Path $stateKey } else { $null }
        if (-not $st -or -not $st.TargetName) { Set-ItResult -Skipped -Because 'No rename state present (the device already had a matching name or was not renamed by HostRename)'; return }
        $st.TargetName | Should -BeExactly $names.Pending
        $st.Template   | Should -Not -BeNullOrEmpty
    }
    It 'the AD computer object exists with the new name' {
        if ($phaseResolved -ne 'PostRun') { Set-ItResult -Skipped -Because "Phase is $phaseResolved"; return }
        $r = Invoke-AsSystem -Variables @{ Name = $names.Pending } -Code @'
$s = [adsisearcher]"(&(objectCategory=computer)(sAMAccountName=$Name`$))"
$hit = $s.FindOne()
@{ Found = [bool]$hit; Dn = $(if ($hit) { [string]$hit.Properties['distinguishedname'][0] } else { '' }) }
'@
        $r.Error | Should -BeNullOrEmpty
        $r.Found | Should -BeTrue -Because "No computer object with sAMAccountName $($names.Pending)`$ found"
    }
    It 'the secure channel is intact after the rename' {
        if ($phaseResolved -ne 'PostRun') { Set-ItResult -Skipped -Because "Phase is $phaseResolved"; return }
        if ($names.Pending -ne $names.Active) { Set-ItResult -Skipped -Because 'Reboot is still pending'; return }
        $r = Invoke-AsSystem -Code '[bool](Test-ComputerSecureChannel)'
        $r | Should -BeTrue
    }
    It 'the registry marker is set (only if cleanup is expected)' {
        if ($phaseResolved -ne 'PostRun') { Set-ItResult -Skipped -Because "Phase is $phaseResolved"; return }
        if (-not $cfg.ExpectCleanup)      { Set-ItResult -Skipped -Because 'ExpectCleanup = $false'; return }
        (Get-ItemProperty -Path $markerPath).Completed | Should -Not -BeNullOrEmpty
    }
    It 'the scheduled task was removed (only if cleanup is expected)' {
        if ($phaseResolved -ne 'PostRun') { Set-ItResult -Skipped -Because "Phase is $phaseResolved"; return }
        if (-not $cfg.ExpectCleanup)      { Set-ItResult -Skipped -Because 'ExpectCleanup = $false'; return }
        Get-ScheduledTask -TaskName $cfg.TaskName -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }
    It 'local log files and folder are removed after the cleanup if the central log works (only if cleanup is expected)' {
        if ($phaseResolved -ne 'PostRun') { Set-ItResult -Skipped -Because "Phase is $phaseResolved"; return }
        if (-not $cfg.ExpectCleanup)      { Set-ItResult -Skipped -Because 'ExpectCleanup = $false'; return }
        try   { $central = @(Import-Csv -Path $cfg.CentralLogPath -Delimiter ';' -Encoding UTF8 -ErrorAction Stop | Where-Object { $_.MachineGuid -eq $machineGuid }) }
        catch { Set-ItResult -Skipped -Because "Central log not readable for this account: $($_.Exception.Message)"; return }
        if (@($central | ForEach-Object { $_.Event }) -notcontains 'CLEANUP_DONE') { Set-ItResult -Skipped -Because 'CLEANUP_DONE is not in the central log (delivery is stuck, local logs are then kept)'; return }
        Test-Path (Join-Path $cfg.LocalFolder 'rename-local.csv') | Should -BeFalse
        Test-Path (Join-Path $cfg.LocalFolder 'pending.csv')      | Should -BeFalse
        Test-Path $cfg.LocalFolder                                | Should -BeFalse -Because 'The empty folder is removed as well'
    }
    It 'the local script was removed (only if cleanup is expected)' {
        if ($phaseResolved -ne 'PostRun') { Set-ItResult -Skipped -Because "Phase is $phaseResolved"; return }
        if (-not $cfg.ExpectCleanup)      { Set-ItResult -Skipped -Because 'ExpectCleanup = $false'; return }
        Test-Path $localScript | Should -BeFalse
    }
    It 'the local log documents the rename or the already set name' {
        if ($phaseResolved -ne 'PostRun') { Set-ItResult -Skipped -Because "Phase is $phaseResolved"; return }
        if (-not $localRows.Count) { Set-ItResult -Skipped -Because 'The local log no longer exists (removed after successful delivery, as intended)'; return }
        $ev = @($localRows | ForEach-Object { $_.Event })
        ($ev -contains 'RENAMED' -or $ev -contains 'ALREADY_DONE' -or $ev -contains 'PENDING_REBOOT') | Should -BeTrue -Because "Events: $($ev -join ', ')"
    }
    It 'the local log documents the cleanup (only if cleanup is expected)' {
        if ($phaseResolved -ne 'PostRun') { Set-ItResult -Skipped -Because "Phase is $phaseResolved"; return }
        if (-not $cfg.ExpectCleanup)      { Set-ItResult -Skipped -Because 'ExpectCleanup = $false'; return }
        if (-not $localRows.Count) { Set-ItResult -Skipped -Because 'The local log no longer exists (removed after successful delivery, as intended); CLEANUP_DONE is in the central log'; return }
        @($localRows | ForEach-Object { $_.Event }) | Should -Contain 'CLEANUP_DONE'
    }
    It 'the central log contains entries of this device (by MachineGuid)' {
        if ($phaseResolved -ne 'PostRun') { Set-ItResult -Skipped -Because "Phase is $phaseResolved"; return }
        try   { $rows = @(Import-Csv -Path $cfg.CentralLogPath -Delimiter ';' -Encoding UTF8 -ErrorAction Stop) }
        catch { Set-ItResult -Skipped -Because "Central log not readable for this account: $($_.Exception.Message)"; return }
        $mine = @($rows | Where-Object { $_.MachineGuid -eq $machineGuid })
        $mine.Count | Should -BeGreaterThan 0
        $errs = @($mine | Where-Object { $_.Level -eq 'ERROR' })
        Write-Host "    Central log: $($mine.Count) entries of this device, of which $($errs.Count) ERROR"
        if ($cfg.ExpectCleanup) { @($mine | ForEach-Object { $_.Event }) | Should -Contain 'CLEANUP_DONE' }
    }
    It 'the GPO does NOT recreate task and script after gpupdate (only if cleanup is expected)' {
        if ($phaseResolved -ne 'PostRun') { Set-ItResult -Skipped -Because "Phase is $phaseResolved"; return }
        if (-not $cfg.ExpectCleanup)      { Set-ItResult -Skipped -Because 'ExpectCleanup = $false'; return }
        if ($SkipGpUpdate)                { Set-ItResult -Skipped -Because 'SkipGpUpdate = $true'; return }
        Invoke-GpUpdate
        Test-Path $localScript | Should -BeFalse
        Get-ScheduledTask -TaskName $cfg.TaskName -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }
}

Describe 'Item-level targeting: roundtrip with marker (opt-in: -RunIltRoundtrip)' {
    BeforeAll {
        $iltRun = $RunIltRoundtrip -and
                  $cfg.ExpectCleanup -and
                  ($phaseResolved -eq 'PreRun') -and
                  (Test-Path $localScript) -and
                  [bool](Get-ScheduledTask -TaskName $cfg.TaskName -ErrorAction SilentlyContinue)
        $withMarker = $null; $withoutMarker = $null
        if ($iltRun) {
            # A) With marker: remove task and script, apply GPO -> must NOT recreate anything
            New-Item -Path $markerPath -Force | Out-Null
            Unregister-ScheduledTask -TaskName $cfg.TaskName -Confirm:$false
            Remove-Item -Path $localScript -Force
            Invoke-GpUpdate
            $withMarker = [pscustomobject]@{
                FileExists = (Test-Path $localScript)
                TaskExists = [bool](Get-ScheduledTask -TaskName $cfg.TaskName -ErrorAction SilentlyContinue)
            }
            # B) Without marker: apply GPO -> must recreate both
            Remove-Item -Path $markerPath -Recurse -Force
            Invoke-GpUpdate
            $withoutMarker = [pscustomobject]@{
                FileExists = (Test-Path $localScript)
                TaskExists = [bool](Get-ScheduledTask -TaskName $cfg.TaskName -ErrorAction SilentlyContinue)
            }
        }
    }
    AfterAll {
        # Make sure the marker does not remain on the pilot device
        if ($iltRun -and (Test-Path $markerPath)) { Remove-Item -Path $markerPath -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'With marker: the GPO does NOT recreate the script' {
        if (-not $iltRun) { Set-ItResult -Skipped -Because 'Not enabled or prerequisites not met (-RunIltRoundtrip, phase PreRun, task + script present)'; return }
        $withMarker.FileExists | Should -BeFalse -Because 'Item-level targeting is not effective - check the XML syntax of the targeting'
    }
    It 'With marker: the GPO does NOT recreate the task' {
        if (-not $iltRun) { Set-ItResult -Skipped -Because 'Not enabled or prerequisites not met'; return }
        $withMarker.TaskExists | Should -BeFalse -Because 'Item-level targeting is not effective - check the XML syntax of the targeting'
    }
    It 'Without marker: the GPO recreates the script' {
        if (-not $iltRun) { Set-ItResult -Skipped -Because 'Not enabled or prerequisites not met'; return }
        $withoutMarker.FileExists | Should -BeTrue -Because 'The GPP "Files" is no longer applied - check the ILT syntax or the GPO processing'
    }
    It 'Without marker: the GPO recreates the task' {
        if (-not $iltRun) { Set-ItResult -Skipped -Because 'Not enabled or prerequisites not met'; return }
        $withoutMarker.TaskExists | Should -BeTrue -Because 'The GPP "Scheduled Tasks" is no longer applied - check the ILT syntax or the GPO processing'
    }
}
