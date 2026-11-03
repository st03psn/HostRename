<#
.SYNOPSIS
    HostRename - DC tests: check AD, GPO and shares (read-only).

.DESCRIPTION
    Runs on a domain controller or admin PC with RSAT in Windows PowerShell 5.1 and changes nothing.
    Under PowerShell 7 the tests abort with a message (AD: drive and GPO objects).

    CHECKS
      Schema       Are the hard-coded GUIDs of the validated writes correct?
      Delegation   Does SELF have the expected rights on every client OU (cn, name, sAMAccountName, displayName,
                   validated writes for DNS host name and SPN, Reset password, Account Restrictions), for
                   descendant computer objects only and without broader rights?
      GPO          Status, SYSVOL files (Files.xml, ScheduledTasks.xml), CSE entry, version numbers
                   (AD versus GPT.INI), recognition by Get-GPOReport, file copy with action Replace, task with
                   SYSTEM account, invocation with renaming rule and -LocalDir, triggers, item-level targeting
      Cleanup      If present (optional, only created at the end): Registry.xml of the cleanup GPO deletes
                   the configured HostRename keys, CSE entry, version numbers, main GPO removed
      Shares       NTFS permissions: source folder read-only for computers, log folder writable (including
                   read and write attributes) but not readable

    Configuration: HostRename.Checks.psd1 (written by Prepare-HostRename.ps1 during Setup).

.PARAMETER ConfigPath
    Path of the test configuration (default: HostRename.Checks.psd1 next to this file).

.EXAMPLE
    powershell.exe -NoProfile -Command "Invoke-Pester -Path .\HostRename.Dc.Tests.ps1 -Output Detailed"

    Starts the tests in Windows PowerShell 5.1, even if the current session is PowerShell 7.

.NOTES
    Product          HostRename
    Version          1.1.9
    Date             2026-10-30
    Run on           DC or admin PC with RSAT, Windows PowerShell 5.1, domain admin (read-only)
    Encoding         UTF-8 with BOM (required for Windows PowerShell 5.1)

.LINK
    README.md
#>
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.3.0' }
#Requires -Version 5.1
param(
    [string]$ConfigPath = ''
)

BeforeAll {
    if ($PSVersionTable.PSEdition -eq 'Core') {
        throw 'The DC tests need Windows PowerShell 5.1 (the AD: drive and GroupPolicy objects are not reliably available under PowerShell 7). Start with: powershell.exe -NoProfile -Command "Invoke-Pester -Path .\HostRename.Dc.Tests.ps1 -Output Detailed"'
    }

    $ConfigPath = if ($ConfigPath) { $ConfigPath } else { Join-Path $PSScriptRoot 'HostRename.Checks.psd1' }
    if (-not (Test-Path $ConfigPath)) {
        throw "Configuration '$ConfigPath' is missing. First run .\Prepare-HostRename.ps1 -Action Setup (writes the file from the script's variables) or copy HostRename.Checks.beispiel.psd1 to HostRename.Checks.psd1 and adjust it."
    }
    $cfg = Import-PowerShellDataFile -Path $ConfigPath

    Import-Module ActiveDirectory, GroupPolicy -ErrorAction Stop

    $domain   = Get-ADDomain
    $pdc      = $domain.PDCEmulator
    $dnsRoot  = $domain.DNSRoot
    $rootDse  = Get-ADRootDSE -Server $pdc
    $configNC = $rootDse.configurationNamingContext
    $schemaNC = $rootDse.schemaNamingContext

    function Get-SchemaGuid {
        param([string]$LdapName, [ValidateSet('attributeSchema', 'classSchema')][string]$SchemaClass)
        $o = Get-ADObject -Server $pdc -SearchBase $schemaNC `
                -Filter "lDAPDisplayName -eq '$LdapName' -and objectClass -eq '$SchemaClass'" -Properties schemaIDGUID
        if (-not $o) { throw "Schema object '$LdapName' not found" }
        New-Object System.Guid (, [byte[]]$o.schemaIDGUID)
    }

    function Get-SidValue {
        param($Ace)
        try { $Ace.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value } catch { '' }
    }

    # "Broad" principals: Everyone, Authenticated Users, Users, Domain Users, Domain Computers
    $broadSids = @('S-1-1-0', 'S-1-5-11', 'S-1-5-32-545', "$($domain.DomainSID.Value)-513", "$($domain.DomainSID.Value)-515")
    $FSR = [System.Security.AccessControl.FileSystemRights]
    $writeMask = $FSR::WriteData -bor $FSR::AppendData -bor $FSR::Delete -bor $FSR::DeleteSubdirectoriesAndFiles -bor $FSR::ChangePermissions -bor $FSR::TakeOwnership
    $readMask  = $FSR::ReadData

    function Get-BroadAces {
        param([string]$Path, $Mask)
        $acl = Get-Acl -Path $Path
        @($acl.Access | Where-Object {
            $_.AccessControlType -eq 'Allow' -and
            ($broadSids -contains (Get-SidValue $_)) -and
            (($_.FileSystemRights -band $Mask) -ne 0)
        })
    }
}

Describe 'AD schema: hard-coded GUIDs' {
    It 'Extended right "<Name>" exists and is a validated write' -ForEach @(
        @{ Name = 'Validated write to DNS host name';          Guid = '72e39547-7b18-11d1-adef-00c04fd8d5cd' }
        @{ Name = 'Validated write to service principal name'; Guid = 'f3a64788-5306-11d1-a9c5-0000f80367c1' }
    ) {
        $o = Get-ADObject -Server $pdc -SearchBase "CN=Extended-Rights,$configNC" -LDAPFilter "(rightsGuid=$Guid)" -Properties validAccesses, displayName
        $o | Should -Not -BeNullOrEmpty -Because "GUID $Guid is hard-coded in the script"
        @($o.validAccesses) | Should -Contain 8 -Because 'validAccesses = 8 corresponds to ADS_RIGHT_DS_SELF (validated write); the same GUID is also listed as a property set (48)'
    }
    It 'Attribute <Attr> exists in the schema' -ForEach @(
        @{ Attr = 'cn' }, @{ Attr = 'name' }, @{ Attr = 'sAMAccountName' }, @{ Attr = 'displayName' }
    ) {
        { Get-SchemaGuid -LdapName $Attr -SchemaClass attributeSchema } | Should -Not -Throw
    }
    It 'Class computer exists in the schema' {
        { Get-SchemaGuid -LdapName 'computer' -SchemaClass classSchema } | Should -Not -Throw
    }
}

Describe 'Delegation on the client OUs' {
    BeforeAll {
        $computerGuid = Get-SchemaGuid -LdapName 'computer' -SchemaClass classSchema
        $ADR = [System.DirectoryServices.ActiveDirectoryRights]

        # Rights that HostRename sets (object GUID -> label)
        $ownGuids = @{}
        foreach ($a in 'cn', 'name', 'sAMAccountName', 'displayName') { $ownGuids[(Get-SchemaGuid -LdapName $a -SchemaClass attributeSchema)] = "Write: $a" }
        $ownGuids[[guid]'72e39547-7b18-11d1-adef-00c04fd8d5cd'] = 'Validated write: DNS host name'
        $ownGuids[[guid]'f3a64788-5306-11d1-a9c5-0000f80367c1'] = 'Validated write: service principal name'
        $ownGuids[[guid]'00299570-246d-11d0-a768-00aa006e0529'] = 'Reset password'
        $ownGuids[[guid]'4c164200-20c0-11d0-a768-00aa006e0529'] = 'Write: Account Restrictions'

        $nameCache = @{}
        function Get-ObjectTypeName {
            # Resolves the object GUID of an ACE to a readable name (extended right or schema attribute)
            param([guid]$Guid)
            if ($Guid -eq [guid]::Empty) { return '(all properties)' }
            if ($nameCache.ContainsKey($Guid)) { return $nameCache[$Guid] }
            $name = $Guid.ToString()
            $er = Get-ADObject -Server $pdc -SearchBase "CN=Extended-Rights,$configNC" -LDAPFilter "(rightsGuid=$Guid)" -Properties displayName -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($er) { $name = $er.displayName }
            else {
                $esc = ($Guid.ToByteArray() | ForEach-Object { '\{0:x2}' -f $_ }) -join ''
                $at  = Get-ADObject -Server $pdc -SearchBase $schemaNC -LDAPFilter "(schemaIDGUID=$esc)" -Properties lDAPDisplayName -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($at) { $name = $at.lDAPDisplayName }
            }
            $nameCache[$Guid] = $name
            $name
        }

        $ouData = @(foreach ($dn in @($cfg.ClientOuDN)) {
            $ou   = Get-ADObject -Server $pdc -Identity $dn -ErrorAction SilentlyContinue
            $aces = @()
            if ($ou) {
                $acl  = Get-Acl -Path ('AD:' + $dn)
                $aces = @($acl.Access | Where-Object {
                    (Get-SidValue $_) -eq 'S-1-5-10' -and
                    $_.AccessControlType -eq 'Allow' -and
                    $_.InheritedObjectType -eq $computerGuid
                })
            }
            [pscustomobject]@{ Dn = $dn; Exists = [bool]$ou; SelfAces = $aces }
        })
    }

    It 'at least one OU is configured (ClientOuDN)' {
        $ouData.Count | Should -BeGreaterThan 0
    }
    It 'all configured OUs exist' {
        $missing = @($ouData | Where-Object { -not $_.Exists } | ForEach-Object { $_.Dn })
        $missing | Should -BeNullOrEmpty -Because "Not found: $($missing -join '; ')"
    }
    It 'SELF may write <Attr> on computer objects (in every OU)' -ForEach @(
        @{ Attr = 'cn' }, @{ Attr = 'name' }, @{ Attr = 'sAMAccountName' }, @{ Attr = 'displayName' }
    ) {
        $g = Get-SchemaGuid -LdapName $Attr -SchemaClass attributeSchema
        $bad = foreach ($o in $ouData) {
            $hit = @($o.SelfAces | Where-Object { $_.ObjectType -eq $g -and (($_.ActiveDirectoryRights -band $ADR::WriteProperty) -eq $ADR::WriteProperty) })
            if ($hit.Count -eq 0) { $o.Dn }
        }
        @($bad) | Should -BeNullOrEmpty -Because "Missing in: $(@($bad) -join '; ')"
    }
    It 'SELF has the validated write "<Name>" (in every OU)' -ForEach @(
        @{ Name = 'DNS host name';          Guid = '72e39547-7b18-11d1-adef-00c04fd8d5cd' }
        @{ Name = 'service principal name'; Guid = 'f3a64788-5306-11d1-a9c5-0000f80367c1' }
    ) {
        $bad = foreach ($o in $ouData) {
            $hit = @($o.SelfAces | Where-Object { $_.ObjectType -eq [guid]$Guid -and (($_.ActiveDirectoryRights -band $ADR::Self) -eq $ADR::Self) })
            if ($hit.Count -eq 0) { $o.Dn }
        }
        @($bad) | Should -BeNullOrEmpty -Because "Missing in: $(@($bad) -join '; ')"
    }
    It 'SELF has the right "<Name>" (in every OU)' -ForEach @(
        @{ Name = 'Reset password';                  Guid = '00299570-246d-11d0-a768-00aa006e0529'; Right = 'ExtendedRight' }
        @{ Name = 'Write: Account Restrictions';     Guid = '4c164200-20c0-11d0-a768-00aa006e0529'; Right = 'WriteProperty' }
    ) {
        $need = [System.DirectoryServices.ActiveDirectoryRights]$Right
        $bad = foreach ($o in $ouData) {
            $hit = @($o.SelfAces | Where-Object { $_.ObjectType -eq [guid]$Guid -and (($_.ActiveDirectoryRights -band $need) -eq $need) })
            if ($hit.Count -eq 0) { $o.Dn }
        }
        @($bad) | Should -BeNullOrEmpty -Because "Missing in: $(@($bad) -join '; ') - without this right Rename-Computer often fails with 'Access denied'"
    }
    It 'the HostRename rights apply only to descendant objects, not to the OU itself' {
        $bad = foreach ($o in $ouData) {
            $own = @($o.SelfAces | Where-Object { $ownGuids.ContainsKey([guid]$_.ObjectType) })
            if ($own.Count -eq 0 -or @($own | Where-Object { $_.InheritanceType -ne 'Descendents' }).Count -gt 0) { $o.Dn }
        }
        @($bad) | Should -BeNullOrEmpty -Because "Rights are missing or do not apply to descendant objects only in: $(@($bad) -join '; ')"
    }
    It 'SELF has no broader rights on computer objects (GenericAll/WriteDacl/WriteOwner)' {
        # Check each right individually: GenericAll is a composite mask that also contains the WriteProperty bit
        $isDangerous = {
            param($r)
            (($r -band $ADR::GenericAll) -eq $ADR::GenericAll) -or (($r -band $ADR::WriteDacl) -eq $ADR::WriteDacl) -or (($r -band $ADR::WriteOwner) -eq $ADR::WriteOwner)
        }
        $bad = foreach ($o in $ouData) { foreach ($a in $o.SelfAces) { if (& $isDangerous $a.ActiveDirectoryRights) { "$($o.Dn): $($a.ActiveDirectoryRights)" } } }
        @($bad) | Should -BeNullOrEmpty -Because ($bad -join '; ')
    }
    It 'Info: SELF entries for computer objects per OU (display only; further entries come e.g. from LAPS)' {
        foreach ($o in $ouData) {
            $own   = @($o.SelfAces | Where-Object { $ownGuids.ContainsKey([guid]$_.ObjectType) })
            $other = @($o.SelfAces | Where-Object { -not $ownGuids.ContainsKey([guid]$_.ObjectType) })
            Write-Host "    $($o.Dn): $($own.Count) HostRename entries (expected 8), $($other.Count) others"
            foreach ($a in $other) { Write-Host ("      other entry: {0,-28} {1}" -f $a.ActiveDirectoryRights, (Get-ObjectTypeName ([guid]$a.ObjectType))) }
        }
        $true | Should -BeTrue
    }
}

Describe 'GPO and SYSVOL' {
    BeforeAll {
        $gpo     = Get-GPO -Name $cfg.GpoName -Server $pdc -ErrorAction SilentlyContinue
        $gpoGuid = if ($gpo) { $gpo.Id.ToString('B').ToUpper() } else { '' }
        $sysvol  = "\\$pdc\SYSVOL\$dnsRoot\Policies\$gpoGuid"

        function Read-XmlFile {
            param([string]$Path)
            $r = [pscustomobject]@{ Xml = $null; Error = $null; Exists = (Test-Path $Path) }
            if ($r.Exists) {
                try { $x = New-Object System.Xml.XmlDocument; $x.Load($Path); $r.Xml = $x } catch { $r.Error = $_.Exception.Message }
            }
            $r
        }
        $files = Read-XmlFile (Join-Path $sysvol 'Machine\Preferences\Files\Files.xml')
        $tasks = Read-XmlFile (Join-Path $sysvol 'Machine\Preferences\ScheduledTasks\ScheduledTasks.xml')

        $gpc    = if ($gpo) { Get-ADObject -Server $pdc -Identity $gpo.Path -Properties versionNumber, gPCMachineExtensionNames } else { $null }
        $gptIni = Join-Path $sysvol 'GPT.INI'
        $report = if ($gpo) { Get-GPOReport -Guid $gpo.Id -ReportType Xml -Server $pdc } else { '' }

        $fileItem = if ($files.Xml) { $files.Xml.Files.File } else { $null }
        $taskItem = if ($tasks.Xml) { $tasks.Xml.ScheduledTasks.TaskV2 } else { $null }
        $task     = if ($taskItem) { $taskItem.Properties.Task } else { $null }
        $execs    = if ($task) { @($task.Actions.Exec) } else { @() }
    }

    It 'the GPO exists' {
        $gpo | Should -Not -BeNullOrEmpty -Because "GpoName = $($cfg.GpoName)"
    }
    It 'user configuration is disabled' {
        $gpo.GpoStatus | Should -Be 'UserSettingsDisabled'
    }

    Context 'Files.xml' {
        It 'exists and is well-formed XML' {
            $files.Exists | Should -BeTrue
            $files.Error  | Should -BeNullOrEmpty
        }
        It 'copies the script from the configured share' {
            $fileItem.Properties.fromPath | Should -Be (Join-Path $cfg.SourceShareFolder $cfg.ScriptName)
        }
        It 'copies to the configured local folder (action Replace)' {
            $fileItem.Properties.targetPath | Should -Be (Join-Path $cfg.LocalFolder $cfg.ScriptName)
            $fileItem.Properties.action     | Should -Be 'R' -Because 'With Update, overwriting an existing script copy on the client fails (error 0x50)'
        }
        It 'has item-level targeting on the marker (only if cleanup is expected)' {
            if (-not $cfg.ExpectCleanup) { Set-ItResult -Skipped -Because 'ExpectCleanup = $false'; return }
            $f = $fileItem.Filters.FilterRegistry
            $f           | Should -Not -BeNullOrEmpty
            $f.key       | Should -Be $cfg.MarkerRegistryKey
            $f.not       | Should -Be '1'
            $f.type      | Should -Be 'KEYEXISTS'
        }
    }

    Context 'ScheduledTasks.xml' {
        It 'exists and is well-formed XML' {
            $tasks.Exists | Should -BeTrue
            $tasks.Error  | Should -BeNullOrEmpty
        }
        It 'contains the configured task (SYSTEM, highest privileges)' {
            $taskItem.name                      | Should -Be $cfg.TaskName
            $task.Principals.Principal.UserId   | Should -Match '^(SYSTEM|S-1-5-18)$' -Because 'A localized or English account name (NT AUTHORITY\System) fails on clients with a different system language'
            $taskItem.Properties.runAs          | Should -Match '^(SYSTEM|S-1-5-18)$'
            $task.Principals.Principal.RunLevel | Should -Be 'HighestAvailable'
        }
        It 'starts the local script with the configured renaming rule' {
            $last = $execs[-1]
            $last.Command   | Should -Be 'powershell.exe'
            $last.Arguments | Should -Match ([regex]::Escape((Join-Path $cfg.LocalFolder $cfg.ScriptName)))
            $rule = if ($cfg.NameTemplate) { '-NameTemplate "' + $cfg.NameTemplate + '"' } else { '-Prefix "' + $cfg.Prefix + '"' }
            $last.Arguments | Should -Match ([regex]::Escape($rule))
        }
        It 'passes the local folder (-LocalDir) for the local logs' {
            $execs[-1].Arguments | Should -Match ([regex]::Escape('-LocalDir "' + $cfg.LocalFolder + '"'))
        }
        It 'passes -OnSerialProblem and -FutureIdLength (only if the template uses {Serial})' {
            if ($cfg.NameTemplate -notmatch '\{SERIAL(:-?\d+)?\}') { Set-ItResult -Skipped -Because 'The template does not use {Serial}'; return }
            $mode = if ($cfg.OnSerialProblem) { $cfg.OnSerialProblem } else { 'GenerateId' }
            $len  = if ($cfg.FutureIdLength)  { $cfg.FutureIdLength }  else { 8 }
            $execs[-1].Arguments | Should -Match ([regex]::Escape("-OnSerialProblem $mode"))
            $execs[-1].Arguments | Should -Match ([regex]::Escape("-FutureIdLength $len"))
        }
        It 'passes -Cleanup and -TaskName (only if cleanup is expected)' {
            if (-not $cfg.ExpectCleanup) { Set-ItResult -Skipped -Because 'ExpectCleanup = $false'; return }
            $execs[-1].Arguments | Should -Match '-Cleanup'
            $execs[-1].Arguments | Should -Match ([regex]::Escape('-TaskName "' + $cfg.TaskName + '"'))
        }
        It 'first locks down the local folder via icacls (only if hardening is expected)' {
            if (-not $cfg.ExpectHardening) { Set-ItResult -Skipped -Because 'ExpectHardening = $false'; return }
            $execs.Count | Should -BeGreaterOrEqual 3
            $execs[0].Command | Should -Be 'icacls.exe'
            $execs[1].Command | Should -Be 'icacls.exe'
        }
        It 'has a system startup trigger' {
            $task.Triggers.BootTrigger | Should -Not -BeNullOrEmpty
        }
        It 'the daily trigger repeats (RepeatInterval) so that a task created after boot runs soon (only if RepeatInterval is set)' {
            if (-not $cfg.RepeatInterval) { Set-ItResult -Skipped -Because 'RepeatInterval is empty'; return }
            @($task.Triggers.CalendarTrigger.Repetition.Interval)[0] | Should -Be $cfg.RepeatInterval
        }
        It 'has a registration trigger so that a newly created task runs immediately (only if RegistrationTrigger is set)' {
            if (-not $cfg.RegistrationTrigger) { Set-ItResult -Skipped -Because 'RegistrationTrigger is turned off'; return }
            $task.Triggers.RegistrationTrigger | Should -Not -BeNullOrEmpty
        }
        It 'the registration trigger has no Delay element (with a delay the GPO''s HTML report fails in the GPMC)' {
            if (-not $cfg.RegistrationTrigger) { Set-ItResult -Skipped -Because 'RegistrationTrigger is turned off'; return }
            @($task.Triggers.RegistrationTrigger.Delay) -join '' | Should -BeNullOrEmpty
        }
        It 'has item-level targeting on the marker (only if cleanup is expected)' {
            if (-not $cfg.ExpectCleanup) { Set-ItResult -Skipped -Because 'ExpectCleanup = $false'; return }
            $f = $taskItem.Filters.FilterRegistry
            $f      | Should -Not -BeNullOrEmpty
            $f.key  | Should -Be $cfg.MarkerRegistryKey
            $f.not  | Should -Be '1'
            $f.type | Should -Be 'KEYEXISTS'
        }
    }

    Context 'Registration and versions' {
        It 'gPCMachineExtensionNames contains the Files CSE' {
            $gpc.gPCMachineExtensionNames | Should -Match ([regex]::Escape('[{7150F9BF-48AD-4DA4-A49C-29EF4A8369BA}'))
        }
        It 'gPCMachineExtensionNames contains the Scheduled Tasks CSE' {
            $gpc.gPCMachineExtensionNames | Should -Match ([regex]::Escape('[{AADCED64-746C-4633-A97C-D61349046527}'))
        }
        It 'versionNumber (AD) matches Version in GPT.INI' {
            $ini = (Get-Content -Path $gptIni | Where-Object { $_ -match '^Version=' }) -replace '^Version=', ''
            [int]$gpc.versionNumber | Should -Be ([int]$ini) -Because 'Differences mark the GPO as inconsistent (gpresult/GPMC warning)'
        }
        It 'SYSVOL version is identical on all domain controllers (replication)' {
            $versions = Get-ADDomainController -Filter * | ForEach-Object {
                $p = "\\$($_.HostName)\SYSVOL\$dnsRoot\Policies\$gpoGuid\GPT.INI"
                if (Test-Path $p) { (Get-Content -Path $p | Where-Object { $_ -match '^Version=' }) } else { "missing on $($_.HostName)" }
            }
            @($versions | Select-Object -Unique).Count | Should -Be 1 -Because (($versions) -join ', ')
        }
    }

    Context 'Recognition by the GPMC report engine' {
        It 'the GPO report contains the Files preference (script name)' {
            $report | Should -Match ([regex]::Escape($cfg.ScriptName))
        }
        It 'the GPO report contains the Scheduled Task preference' {
            $report | Should -Match ([regex]::Escape($cfg.TaskName))
        }
        It 'the GPO report contains the item-level targeting (marker key)' {
            if (-not $cfg.ExpectCleanup) { Set-ItResult -Skipped -Because 'ExpectCleanup = $false'; return }
            $report | Should -Match ([regex]::Escape($cfg.MarkerRegistryKey)) -Because 'If the filter is not parsed, the XML syntax of the targeting is probably wrong'
        }
    }

    Context 'Security filtering' {
        It 'only the pilot group may apply the GPO (only if PilotGroup is set)' {
            if (-not $cfg.PilotGroup) { Set-ItResult -Skipped -Because 'PilotGroup is empty'; return }
            $perms = Get-GPPermission -Guid $gpo.Id -All -Server $pdc
            $pilot = @($perms | Where-Object { $_.Trustee.Name -eq $cfg.PilotGroup })
            $pilot.Permission | Should -Contain 'GpoApply'
            $auth = @($perms | Where-Object { $_.Trustee.Sid.Value -eq 'S-1-5-11' })
            $auth.Permission | Should -Not -Contain 'GpoApply'
        }
    }
}

Describe 'Cleanup GPO (optional, only created at the end)' {
    BeforeAll {
        $cgpo     = Get-GPO -Name $cfg.CleanupGpoName -Server $pdc -ErrorAction SilentlyContinue
        $cGuid    = if ($cgpo) { $cgpo.Id.ToString('B').ToUpper() } else { '' }
        $cSysvol  = "\\$pdc\SYSVOL\$dnsRoot\Policies\$cGuid"
        $cRegPath = Join-Path $cSysvol 'Machine\Preferences\Registry\Registry.xml'
        $cXml     = $null
        if ($cgpo -and (Test-Path $cRegPath)) { try { $cXml = New-Object System.Xml.XmlDocument; $cXml.Load($cRegPath) } catch { $cXml = $null } }
        $cgpc     = if ($cgpo) { Get-ADObject -Server $pdc -Identity $cgpo.Path -Properties versionNumber, gPCMachineExtensionNames } else { $null }
        $mainGpo  = Get-GPO -Name $cfg.GpoName -Server $pdc -ErrorAction SilentlyContinue
    }

    It 'the cleanup GPO exists (otherwise skip: it is only created after all renames are finished)' {
        if (-not $cgpo) { Set-ItResult -Skipped -Because "No GPO '$($cfg.CleanupGpoName)' present (rollout has not reached the end yet)"; return }
        $cgpo | Should -Not -BeNullOrEmpty
    }
    It 'Registry.xml is well-formed and deletes every configured key under HKLM (action D, without value name)' {
        if (-not $cgpo) { Set-ItResult -Skipped -Because 'Cleanup GPO not present'; return }
        $cXml | Should -Not -BeNullOrEmpty -Because "Registry.xml is missing or not valid XML: $cRegPath"
        $items = @($cXml.RegistrySettings.Registry)
        $missing = foreach ($k in @($cfg.CleanupRegKeys)) {
            $hit = @($items | Where-Object { $_.Properties.action -eq 'D' -and $_.Properties.hive -eq 'HKEY_LOCAL_MACHINE' -and $_.Properties.key -ieq $k -and -not $_.Properties.name })
            if ($hit.Count -eq 0) { $k }
        }
        @($missing) | Should -BeNullOrEmpty -Because "No delete item for: $(@($missing) -join '; ')"
    }
    It 'it deletes only keys whose last part begins with HostRename (protection against accidentally deleted branches)' {
        if (-not $cgpo -or -not $cXml) { Set-ItResult -Skipped -Because 'Cleanup GPO or Registry.xml not present'; return }
        $bad = @(@($cXml.RegistrySettings.Registry) | Where-Object { $_.Properties.key -notmatch '\\HostRename[^\\]*$' } | ForEach-Object { $_.Properties.key })
        $bad | Should -BeNullOrEmpty -Because ($bad -join '; ')
    }
    It 'user configuration is disabled' {
        if (-not $cgpo) { Set-ItResult -Skipped -Because 'Cleanup GPO not present'; return }
        $cgpo.GpoStatus | Should -Be 'UserSettingsDisabled'
    }
    It 'gPCMachineExtensionNames contains the Registry CSE' {
        if (-not $cgpo) { Set-ItResult -Skipped -Because 'Cleanup GPO not present'; return }
        $cgpc.gPCMachineExtensionNames | Should -Match ([regex]::Escape('[{B087BE9D-ED37-454F-AF9C-04291E351182}'))
    }
    It 'versionNumber (AD) matches Version in GPT.INI' {
        if (-not $cgpo) { Set-ItResult -Skipped -Because 'Cleanup GPO not present'; return }
        $ini = (Get-Content (Join-Path $cSysvol 'GPT.INI') | Where-Object { $_ -match '^Version=' }) -replace 'Version=', ''
        [int]$cgpc.versionNumber | Should -Be ([int]$ini)
    }
    It 'the main GPO no longer exists (otherwise it recreates script and task on finished devices)' {
        if (-not $cgpo) { Set-ItResult -Skipped -Because 'Cleanup GPO not present'; return }
        $mainGpo | Should -BeNullOrEmpty -Because "The main GPO '$($cfg.GpoName)' must be removed before the cleanup GPO"
    }
}

Describe 'Source share (NTFS)' {
    It 'the source folder and the script are reachable' {
        Test-Path (Join-Path $cfg.SourceShareFolder $cfg.ScriptName) | Should -BeTrue
    }
    It 'computers/users have NO write permissions (otherwise code execution as SYSTEM on all clients is possible)' {
        $w = Get-BroadAces -Path $cfg.SourceShareFolder -Mask $writeMask
        $w | Should -BeNullOrEmpty -Because (($w | ForEach-Object { "$($_.IdentityReference): $($_.FileSystemRights)" }) -join '; ')
    }
    It 'Domain Computers (or Authenticated Users) have read permissions' {
        $r = Get-BroadAces -Path $cfg.SourceShareFolder -Mask $readMask
        $r.Count | Should -BeGreaterThan 0
    }
}

Describe 'Log share (NTFS)' {
    BeforeAll {
        $logDir = Split-Path -Path $cfg.CentralLogPath -Parent
    }
    It 'the log folder is reachable' {
        Test-Path $logDir | Should -BeTrue
    }
    It 'Domain Computers (or broader groups) may write/append' {
        $mask = $FSR::WriteData -bor $FSR::AppendData
        $w = Get-BroadAces -Path $logDir -Mask $mask
        $w.Count | Should -BeGreaterThan 0
    }
    It 'Domain Computers may read and write attributes in the log folder (otherwise appending fails with "Access denied")' {
        $wa = Get-BroadAces -Path $logDir -Mask $FSR::WriteAttributes
        $ra = Get-BroadAces -Path $logDir -Mask $FSR::ReadAttributes
        $wa.Count | Should -BeGreaterThan 0 -Because 'Write attributes (WA) is missing'
        $ra.Count | Should -BeGreaterThan 0 -Because 'Read attributes (RA) is missing; with only W or WD,AD,WEA,WA,RC,S access was denied in practice'
    }
    It 'computers/users must NOT read the logs of other devices' {
        $r = Get-BroadAces -Path $logDir -Mask $readMask
        $r | Should -BeNullOrEmpty -Because (($r | ForEach-Object { "$($_.IdentityReference): $($_.FileSystemRights)" }) -join '; ')
    }
    It 'the central CSV (if present) has the expected columns' {
        if (-not (Test-Path $cfg.CentralLogPath)) { Set-ItResult -Skipped -Because 'Central log file does not exist yet'; return }
        $first = (Get-Content -Path $cfg.CentralLogPath -TotalCount 1 -Encoding UTF8).TrimStart([char]0xFEFF)
        $first | Should -Be 'Timestamp;Level;Event;ComputerName;TargetName;Serial;MachineGuid;Message'
    }
}
