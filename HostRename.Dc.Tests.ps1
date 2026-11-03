<#
.SYNOPSIS
    HostRename - DC-Tests: prüft AD, GPO und Freigaben (rein lesend).

.DESCRIPTION
    Läuft auf einem Domänencontroller oder Admin-PC mit RSAT in der Windows PowerShell 5.1 und ändert nichts.
    Unter PowerShell 7 brechen die Tests mit einem Hinweis ab (AD:-Laufwerk und GPO-Objekte).

    PRÜFT
      Schema       Stimmen die fest hinterlegten GUIDs der Validated Writes?
      Delegation   Hat SELF auf jeder Client-OU die erwarteten Rechte (cn, name, sAMAccountName, displayName,
                   Validated Writes für DNS-Hostname und SPN, Reset password, Account Restrictions), nur für
                   untergeordnete Computerobjekte und ohne breitere Rechte?
      GPO          Status, SYSVOL-Dateien (Files.xml, ScheduledTasks.xml), CSE-Eintrag, Versionsnummern
                   (AD gegen GPT.INI), Erkennung durch Get-GPOReport, Dateikopie mit Aktion Replace, Task mit
                   SYSTEM-Konto, Aufruf mit Umbenennungsregel und -LocalDir, Trigger, Item-Level-Targeting
      Bereinigung  Falls vorhanden (optional, entsteht erst am Ende): Registry.xml der Bereinigungs-GPO löscht
                   die konfigurierten HostRename-Schlüssel, CSE-Eintrag, Versionsnummern, Haupt-GPO entfernt
      Freigaben    NTFS-Rechte: Quellordner für Computer nur lesbar, Log-Ordner beschreibbar (inklusive
                   Attribute lesen und schreiben) aber nicht lesbar

    Konfiguration: HostRename.Checks.psd1 (schreibt Prepare-HostRename.ps1 beim Setup).

.PARAMETER ConfigPath
    Pfad der Test-Konfiguration (Standard: HostRename.Checks.psd1 neben dieser Datei).

.EXAMPLE
    powershell.exe -NoProfile -Command "Invoke-Pester -Path .\HostRename.Dc.Tests.ps1 -Output Detailed"

    Startet die Tests in der Windows PowerShell 5.1, auch wenn die aktuelle Sitzung PowerShell 7 ist.

.NOTES
    Produkt          HostRename
    Version          1.1.9
    Stand            2026-10-30
    Ausführung       DC oder Admin-PC mit RSAT, Windows PowerShell 5.1, Domänen-Admin (lesend)
    Kodierung        UTF-8 mit BOM (für die Windows PowerShell 5.1 erforderlich)

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
        throw 'Die DC-Tests brauchen die Windows PowerShell 5.1 (AD:-Laufwerk und GroupPolicy-Objekte stehen unter PowerShell 7 nicht zuverlässig zur Verfügung). Start: powershell.exe -NoProfile -Command "Invoke-Pester -Path .\HostRename.Dc.Tests.ps1 -Output Detailed"'
    }

    $ConfigPath = if ($ConfigPath) { $ConfigPath } else { Join-Path $PSScriptRoot 'HostRename.Checks.psd1' }
    if (-not (Test-Path $ConfigPath)) {
        throw "Konfiguration '$ConfigPath' fehlt. Zuerst .\Prepare-HostRename.ps1 -Action Setup ausführen (schreibt die Datei aus den Variablen des Skripts) oder HostRename.Checks.beispiel.psd1 als HostRename.Checks.psd1 kopieren und anpassen."
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
        if (-not $o) { throw "Schema-Objekt '$LdapName' nicht gefunden" }
        New-Object System.Guid (, [byte[]]$o.schemaIDGUID)
    }

    function Get-SidValue {
        param($Ace)
        try { $Ace.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value } catch { '' }
    }

    # "Breite" Prinzipale: Jeder, Authentifizierte Benutzer, Benutzer, Domänen-Benutzer, Domänencomputer
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

Describe 'AD-Schema: fest hinterlegte GUIDs' {
    It 'Extended Right "<Name>" existiert und ist ein Validated Write' -ForEach @(
        @{ Name = 'Validated write to DNS host name';          Guid = '72e39547-7b18-11d1-adef-00c04fd8d5cd' }
        @{ Name = 'Validated write to service principal name'; Guid = 'f3a64788-5306-11d1-a9c5-0000f80367c1' }
    ) {
        $o = Get-ADObject -Server $pdc -SearchBase "CN=Extended-Rights,$configNC" -LDAPFilter "(rightsGuid=$Guid)" -Properties validAccesses, displayName
        $o | Should -Not -BeNullOrEmpty -Because "GUID $Guid ist im Skript fest hinterlegt"
        @($o.validAccesses) | Should -Contain 8 -Because 'validAccesses = 8 entspricht ADS_RIGHT_DS_SELF (Validated Write); dieselbe GUID wird auch als Property-Set (48) geführt'
    }
    It 'Attribut <Attr> existiert im Schema' -ForEach @(
        @{ Attr = 'cn' }, @{ Attr = 'name' }, @{ Attr = 'sAMAccountName' }, @{ Attr = 'displayName' }
    ) {
        { Get-SchemaGuid -LdapName $Attr -SchemaClass attributeSchema } | Should -Not -Throw
    }
    It 'Klasse computer existiert im Schema' {
        { Get-SchemaGuid -LdapName 'computer' -SchemaClass classSchema } | Should -Not -Throw
    }
}

Describe 'Delegation auf den Client-OUs' {
    BeforeAll {
        $computerGuid = Get-SchemaGuid -LdapName 'computer' -SchemaClass classSchema
        $ADR = [System.DirectoryServices.ActiveDirectoryRights]

        # Rechte, die HostRename setzt (Objekt-GUID -> Bezeichnung)
        $ownGuids = @{}
        foreach ($a in 'cn', 'name', 'sAMAccountName', 'displayName') { $ownGuids[(Get-SchemaGuid -LdapName $a -SchemaClass attributeSchema)] = "Schreiben: $a" }
        $ownGuids[[guid]'72e39547-7b18-11d1-adef-00c04fd8d5cd'] = 'Validated write: DNS host name'
        $ownGuids[[guid]'f3a64788-5306-11d1-a9c5-0000f80367c1'] = 'Validated write: service principal name'
        $ownGuids[[guid]'00299570-246d-11d0-a768-00aa006e0529'] = 'Reset password'
        $ownGuids[[guid]'4c164200-20c0-11d0-a768-00aa006e0529'] = 'Schreiben: Account Restrictions'

        $nameCache = @{}
        function Get-ObjectTypeName {
            # Löst eine Objekt-GUID eines ACE in einen lesbaren Namen auf (Extended Right bzw. Schema-Attribut)
            param([guid]$Guid)
            if ($Guid -eq [guid]::Empty) { return '(alle Eigenschaften)' }
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

    It 'mindestens eine OU ist konfiguriert (ClientOuDN)' {
        $ouData.Count | Should -BeGreaterThan 0
    }
    It 'alle konfigurierten OUs existieren' {
        $missing = @($ouData | Where-Object { -not $_.Exists } | ForEach-Object { $_.Dn })
        $missing | Should -BeNullOrEmpty -Because "Nicht gefunden: $($missing -join '; ')"
    }
    It 'SELF darf <Attr> auf Computerobjekten schreiben (in jeder OU)' -ForEach @(
        @{ Attr = 'cn' }, @{ Attr = 'name' }, @{ Attr = 'sAMAccountName' }, @{ Attr = 'displayName' }
    ) {
        $g = Get-SchemaGuid -LdapName $Attr -SchemaClass attributeSchema
        $bad = foreach ($o in $ouData) {
            $hit = @($o.SelfAces | Where-Object { $_.ObjectType -eq $g -and (($_.ActiveDirectoryRights -band $ADR::WriteProperty) -eq $ADR::WriteProperty) })
            if ($hit.Count -eq 0) { $o.Dn }
        }
        @($bad) | Should -BeNullOrEmpty -Because "Fehlt in: $(@($bad) -join '; ')"
    }
    It 'SELF hat den Validated Write "<Name>" (in jeder OU)' -ForEach @(
        @{ Name = 'DNS host name';          Guid = '72e39547-7b18-11d1-adef-00c04fd8d5cd' }
        @{ Name = 'service principal name'; Guid = 'f3a64788-5306-11d1-a9c5-0000f80367c1' }
    ) {
        $bad = foreach ($o in $ouData) {
            $hit = @($o.SelfAces | Where-Object { $_.ObjectType -eq [guid]$Guid -and (($_.ActiveDirectoryRights -band $ADR::Self) -eq $ADR::Self) })
            if ($hit.Count -eq 0) { $o.Dn }
        }
        @($bad) | Should -BeNullOrEmpty -Because "Fehlt in: $(@($bad) -join '; ')"
    }
    It 'SELF hat das Recht "<Name>" (in jeder OU)' -ForEach @(
        @{ Name = 'Reset password';                  Guid = '00299570-246d-11d0-a768-00aa006e0529'; Right = 'ExtendedRight' }
        @{ Name = 'Schreiben: Account Restrictions'; Guid = '4c164200-20c0-11d0-a768-00aa006e0529'; Right = 'WriteProperty' }
    ) {
        $need = [System.DirectoryServices.ActiveDirectoryRights]$Right
        $bad = foreach ($o in $ouData) {
            $hit = @($o.SelfAces | Where-Object { $_.ObjectType -eq [guid]$Guid -and (($_.ActiveDirectoryRights -band $need) -eq $need) })
            if ($hit.Count -eq 0) { $o.Dn }
        }
        @($bad) | Should -BeNullOrEmpty -Because "Fehlt in: $(@($bad) -join '; ') - ohne dieses Recht scheitert Rename-Computer oft mit 'Zugriff verweigert'"
    }
    It 'die HostRename-Rechte gelten nur für untergeordnete Objekte, nicht für die OU selbst' {
        $bad = foreach ($o in $ouData) {
            $own = @($o.SelfAces | Where-Object { $ownGuids.ContainsKey([guid]$_.ObjectType) })
            if ($own.Count -eq 0 -or @($own | Where-Object { $_.InheritanceType -ne 'Descendents' }).Count -gt 0) { $o.Dn }
        }
        @($bad) | Should -BeNullOrEmpty -Because "Rechte fehlen oder gelten nicht nur für untergeordnete Objekte in: $(@($bad) -join '; ')"
    }
    It 'SELF hat auf Computerobjekten keine breiteren Rechte (GenericAll/WriteDacl/WriteOwner)' {
        # Jedes Recht einzeln prüfen: GenericAll ist eine Sammelmaske, die auch das Bit von WriteProperty enthält
        $isDangerous = {
            param($r)
            (($r -band $ADR::GenericAll) -eq $ADR::GenericAll) -or (($r -band $ADR::WriteDacl) -eq $ADR::WriteDacl) -or (($r -band $ADR::WriteOwner) -eq $ADR::WriteOwner)
        }
        $bad = foreach ($o in $ouData) { foreach ($a in $o.SelfAces) { if (& $isDangerous $a.ActiveDirectoryRights) { "$($o.Dn): $($a.ActiveDirectoryRights)" } } }
        @($bad) | Should -BeNullOrEmpty -Because ($bad -join '; ')
    }
    It 'Info: SELF-Einträge für Computerobjekte je OU (nur Anzeige; weitere Einträge stammen z. B. von LAPS)' {
        foreach ($o in $ouData) {
            $own   = @($o.SelfAces | Where-Object { $ownGuids.ContainsKey([guid]$_.ObjectType) })
            $other = @($o.SelfAces | Where-Object { -not $ownGuids.ContainsKey([guid]$_.ObjectType) })
            Write-Host "    $($o.Dn): $($own.Count) HostRename-Einträge (erwartet 8), $($other.Count) weitere"
            foreach ($a in $other) { Write-Host ("      weiterer Eintrag: {0,-28} {1}" -f $a.ActiveDirectoryRights, (Get-ObjectTypeName ([guid]$a.ObjectType))) }
        }
        $true | Should -BeTrue
    }
}

Describe 'GPO und SYSVOL' {
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

    It 'die GPO existiert' {
        $gpo | Should -Not -BeNullOrEmpty -Because "GpoName = $($cfg.GpoName)"
    }
    It 'Benutzerkonfiguration ist deaktiviert' {
        $gpo.GpoStatus | Should -Be 'UserSettingsDisabled'
    }

    Context 'Files.xml' {
        It 'existiert und ist wohlgeformtes XML' {
            $files.Exists | Should -BeTrue
            $files.Error  | Should -BeNullOrEmpty
        }
        It 'kopiert das Skript vom konfigurierten Share' {
            $fileItem.Properties.fromPath | Should -Be (Join-Path $cfg.SourceShareFolder $cfg.ScriptName)
        }
        It 'kopiert in den konfigurierten lokalen Ordner (Aktion Replace)' {
            $fileItem.Properties.targetPath | Should -Be (Join-Path $cfg.LocalFolder $cfg.ScriptName)
            $fileItem.Properties.action     | Should -Be 'R' -Because 'Mit Update scheitert das Überschreiben einer vorhandenen Skriptkopie auf dem Client (Fehler 0x50)'
        }
        It 'hat Item-Level-Targeting auf den Marker (nur wenn Cleanup erwartet wird)' {
            if (-not $cfg.ExpectCleanup) { Set-ItResult -Skipped -Because 'ExpectCleanup = $false'; return }
            $f = $fileItem.Filters.FilterRegistry
            $f           | Should -Not -BeNullOrEmpty
            $f.key       | Should -Be $cfg.MarkerRegistryKey
            $f.not       | Should -Be '1'
            $f.type      | Should -Be 'KEYEXISTS'
        }
    }

    Context 'ScheduledTasks.xml' {
        It 'existiert und ist wohlgeformtes XML' {
            $tasks.Exists | Should -BeTrue
            $tasks.Error  | Should -BeNullOrEmpty
        }
        It 'enthält den konfigurierten Task (SYSTEM, höchste Rechte)' {
            $taskItem.name                      | Should -Be $cfg.TaskName
            $task.Principals.Principal.UserId   | Should -Match '^(SYSTEM|S-1-5-18)$' -Because 'Ein lokalisierter oder englischer Kontoname (NT AUTHORITY\System) scheitert auf Clients mit anderer Systemsprache'
            $taskItem.Properties.runAs          | Should -Match '^(SYSTEM|S-1-5-18)$'
            $task.Principals.Principal.RunLevel | Should -Be 'HighestAvailable'
        }
        It 'startet das lokale Skript mit der konfigurierten Umbenennungsregel' {
            $last = $execs[-1]
            $last.Command   | Should -Be 'powershell.exe'
            $last.Arguments | Should -Match ([regex]::Escape((Join-Path $cfg.LocalFolder $cfg.ScriptName)))
            $rule = if ($cfg.NameTemplate) { '-NameTemplate "' + $cfg.NameTemplate + '"' } else { '-Prefix "' + $cfg.Prefix + '"' }
            $last.Arguments | Should -Match ([regex]::Escape($rule))
        }
        It 'übergibt den lokalen Ordner (-LocalDir) für die lokalen Logs' {
            $execs[-1].Arguments | Should -Match ([regex]::Escape('-LocalDir "' + $cfg.LocalFolder + '"'))
        }
        It 'übergibt -OnSerialProblem und -FutureIdLength (nur wenn die Vorlage {Serial} verwendet)' {
            if ($cfg.NameTemplate -notmatch '\{SERIAL(:-?\d+)?\}') { Set-ItResult -Skipped -Because 'Die Vorlage verwendet {Serial} nicht'; return }
            $mode = if ($cfg.OnSerialProblem) { $cfg.OnSerialProblem } else { 'GenerateId' }
            $len  = if ($cfg.FutureIdLength)  { $cfg.FutureIdLength }  else { 8 }
            $execs[-1].Arguments | Should -Match ([regex]::Escape("-OnSerialProblem $mode"))
            $execs[-1].Arguments | Should -Match ([regex]::Escape("-FutureIdLength $len"))
        }
        It 'übergibt -Cleanup und -TaskName (nur wenn Cleanup erwartet wird)' {
            if (-not $cfg.ExpectCleanup) { Set-ItResult -Skipped -Because 'ExpectCleanup = $false'; return }
            $execs[-1].Arguments | Should -Match '-Cleanup'
            $execs[-1].Arguments | Should -Match ([regex]::Escape('-TaskName "' + $cfg.TaskName + '"'))
        }
        It 'sperrt zuerst per icacls den lokalen Ordner (nur wenn Hardening erwartet wird)' {
            if (-not $cfg.ExpectHardening) { Set-ItResult -Skipped -Because 'ExpectHardening = $false'; return }
            $execs.Count | Should -BeGreaterOrEqual 3
            $execs[0].Command | Should -Be 'icacls.exe'
            $execs[1].Command | Should -Be 'icacls.exe'
        }
        It 'hat einen Systemstart-Trigger' {
            $task.Triggers.BootTrigger | Should -Not -BeNullOrEmpty
        }
        It 'der tägliche Trigger wiederholt sich (RepeatInterval), damit ein nach dem Booten angelegter Task bald läuft (nur wenn RepeatInterval gesetzt ist)' {
            if (-not $cfg.RepeatInterval) { Set-ItResult -Skipped -Because 'RepeatInterval ist leer'; return }
            @($task.Triggers.CalendarTrigger.Repetition.Interval)[0] | Should -Be $cfg.RepeatInterval
        }
        It 'hat einen Registrierungs-Trigger, damit ein neu angelegter Task sofort läuft (nur wenn RegistrationTrigger gesetzt ist)' {
            if (-not $cfg.RegistrationTrigger) { Set-ItResult -Skipped -Because 'RegistrationTrigger ist abgeschaltet'; return }
            $task.Triggers.RegistrationTrigger | Should -Not -BeNullOrEmpty
        }
        It 'der Registrierungs-Trigger hat kein Delay-Element (mit Delay scheitert der HTML-Bericht der GPO in der GPMC)' {
            if (-not $cfg.RegistrationTrigger) { Set-ItResult -Skipped -Because 'RegistrationTrigger ist abgeschaltet'; return }
            @($task.Triggers.RegistrationTrigger.Delay) -join '' | Should -BeNullOrEmpty
        }
        It 'hat Item-Level-Targeting auf den Marker (nur wenn Cleanup erwartet wird)' {
            if (-not $cfg.ExpectCleanup) { Set-ItResult -Skipped -Because 'ExpectCleanup = $false'; return }
            $f = $taskItem.Filters.FilterRegistry
            $f      | Should -Not -BeNullOrEmpty
            $f.key  | Should -Be $cfg.MarkerRegistryKey
            $f.not  | Should -Be '1'
            $f.type | Should -Be 'KEYEXISTS'
        }
    }

    Context 'Registrierung und Versionen' {
        It 'gPCMachineExtensionNames enthält die Files-CSE' {
            $gpc.gPCMachineExtensionNames | Should -Match ([regex]::Escape('[{7150F9BF-48AD-4DA4-A49C-29EF4A8369BA}'))
        }
        It 'gPCMachineExtensionNames enthält die Scheduled-Tasks-CSE' {
            $gpc.gPCMachineExtensionNames | Should -Match ([regex]::Escape('[{AADCED64-746C-4633-A97C-D61349046527}'))
        }
        It 'versionNumber (AD) entspricht Version in GPT.INI' {
            $ini = (Get-Content -Path $gptIni | Where-Object { $_ -match '^Version=' }) -replace '^Version=', ''
            [int]$gpc.versionNumber | Should -Be ([int]$ini) -Because 'Abweichungen markieren die GPO als inkonsistent (gpresult/GPMC-Warnung)'
        }
        It 'SYSVOL-Version ist auf allen Domänencontrollern identisch (Replikation)' {
            $versions = Get-ADDomainController -Filter * | ForEach-Object {
                $p = "\\$($_.HostName)\SYSVOL\$dnsRoot\Policies\$gpoGuid\GPT.INI"
                if (Test-Path $p) { (Get-Content -Path $p | Where-Object { $_ -match '^Version=' }) } else { "fehlt auf $($_.HostName)" }
            }
            @($versions | Select-Object -Unique).Count | Should -Be 1 -Because (($versions) -join ', ')
        }
    }

    Context 'Erkennung durch die GPMC-Berichtsengine' {
        It 'der GPO-Bericht enthält die Files-Preference (Skriptname)' {
            $report | Should -Match ([regex]::Escape($cfg.ScriptName))
        }
        It 'der GPO-Bericht enthält die Scheduled-Task-Preference' {
            $report | Should -Match ([regex]::Escape($cfg.TaskName))
        }
        It 'der GPO-Bericht enthält das Item-Level-Targeting (Marker-Schlüssel)' {
            if (-not $cfg.ExpectCleanup) { Set-ItResult -Skipped -Because 'ExpectCleanup = $false'; return }
            $report | Should -Match ([regex]::Escape($cfg.MarkerRegistryKey)) -Because 'Wird der Filter nicht geparst, ist die XML-Syntax des Targetings vermutlich falsch'
        }
    }

    Context 'Sicherheitsfilterung' {
        It 'nur die Pilot-Gruppe darf die GPO anwenden (nur wenn PilotGroup gesetzt ist)' {
            if (-not $cfg.PilotGroup) { Set-ItResult -Skipped -Because 'PilotGroup ist leer'; return }
            $perms = Get-GPPermission -Guid $gpo.Id -All -Server $pdc
            $pilot = @($perms | Where-Object { $_.Trustee.Name -eq $cfg.PilotGroup })
            $pilot.Permission | Should -Contain 'GpoApply'
            $auth = @($perms | Where-Object { $_.Trustee.Sid.Value -eq 'S-1-5-11' })
            $auth.Permission | Should -Not -Contain 'GpoApply'
        }
    }
}

Describe 'Bereinigungs-GPO (optional, erst am Ende angelegt)' {
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

    It 'die Bereinigungs-GPO ist angelegt (sonst überspringen: sie entsteht erst nach Abschluss aller Umbenennungen)' {
        if (-not $cgpo) { Set-ItResult -Skipped -Because "Keine GPO '$($cfg.CleanupGpoName)' vorhanden (noch nicht am Ende des Rollouts)"; return }
        $cgpo | Should -Not -BeNullOrEmpty
    }
    It 'Registry.xml ist wohlgeformt und löscht jeden konfigurierten Schlüssel unter HKLM (Aktion D, ohne Wertnamen)' {
        if (-not $cgpo) { Set-ItResult -Skipped -Because 'Bereinigungs-GPO nicht vorhanden'; return }
        $cXml | Should -Not -BeNullOrEmpty -Because "Registry.xml fehlt oder ist kein gültiges XML: $cRegPath"
        $items = @($cXml.RegistrySettings.Registry)
        $missing = foreach ($k in @($cfg.CleanupRegKeys)) {
            $hit = @($items | Where-Object { $_.Properties.action -eq 'D' -and $_.Properties.hive -eq 'HKEY_LOCAL_MACHINE' -and $_.Properties.key -ieq $k -and -not $_.Properties.name })
            if ($hit.Count -eq 0) { $k }
        }
        @($missing) | Should -BeNullOrEmpty -Because "Kein Delete-Item für: $(@($missing) -join '; ')"
    }
    It 'sie löscht nur Schlüssel, deren letzter Teil mit HostRename beginnt (Schutz vor versehentlich gelöschten Zweigen)' {
        if (-not $cgpo -or -not $cXml) { Set-ItResult -Skipped -Because 'Bereinigungs-GPO oder Registry.xml nicht vorhanden'; return }
        $bad = @(@($cXml.RegistrySettings.Registry) | Where-Object { $_.Properties.key -notmatch '\\HostRename[^\\]*$' } | ForEach-Object { $_.Properties.key })
        $bad | Should -BeNullOrEmpty -Because ($bad -join '; ')
    }
    It 'Benutzerkonfiguration ist deaktiviert' {
        if (-not $cgpo) { Set-ItResult -Skipped -Because 'Bereinigungs-GPO nicht vorhanden'; return }
        $cgpo.GpoStatus | Should -Be 'UserSettingsDisabled'
    }
    It 'gPCMachineExtensionNames enthält die Registry-CSE' {
        if (-not $cgpo) { Set-ItResult -Skipped -Because 'Bereinigungs-GPO nicht vorhanden'; return }
        $cgpc.gPCMachineExtensionNames | Should -Match ([regex]::Escape('[{B087BE9D-ED37-454F-AF9C-04291E351182}'))
    }
    It 'versionNumber (AD) entspricht Version in GPT.INI' {
        if (-not $cgpo) { Set-ItResult -Skipped -Because 'Bereinigungs-GPO nicht vorhanden'; return }
        $ini = (Get-Content (Join-Path $cSysvol 'GPT.INI') | Where-Object { $_ -match '^Version=' }) -replace 'Version=', ''
        [int]$cgpc.versionNumber | Should -Be ([int]$ini)
    }
    It 'die Haupt-GPO existiert nicht mehr (sonst legt sie Skript und Task auf fertigen Geräten neu an)' {
        if (-not $cgpo) { Set-ItResult -Skipped -Because 'Bereinigungs-GPO nicht vorhanden'; return }
        $mainGpo | Should -BeNullOrEmpty -Because "Die Haupt-GPO '$($cfg.GpoName)' muss vor der Bereinigungs-GPO entfernt sein"
    }
}

Describe 'Quell-Share (NTFS)' {
    It 'der Quellordner und das Skript sind erreichbar' {
        Test-Path (Join-Path $cfg.SourceShareFolder $cfg.ScriptName) | Should -BeTrue
    }
    It 'Computer/Benutzer haben KEINE Schreibrechte (sonst Codeausführung als SYSTEM auf allen Clients möglich)' {
        $w = Get-BroadAces -Path $cfg.SourceShareFolder -Mask $writeMask
        $w | Should -BeNullOrEmpty -Because (($w | ForEach-Object { "$($_.IdentityReference): $($_.FileSystemRights)" }) -join '; ')
    }
    It 'Domänencomputer (oder Authentifizierte Benutzer) haben Leserechte' {
        $r = Get-BroadAces -Path $cfg.SourceShareFolder -Mask $readMask
        $r.Count | Should -BeGreaterThan 0
    }
}

Describe 'Log-Share (NTFS)' {
    BeforeAll {
        $logDir = Split-Path -Path $cfg.CentralLogPath -Parent
    }
    It 'der Log-Ordner ist erreichbar' {
        Test-Path $logDir | Should -BeTrue
    }
    It 'Domänencomputer (oder breitere Gruppen) dürfen schreiben/anfügen' {
        $mask = $FSR::WriteData -bor $FSR::AppendData
        $w = Get-BroadAces -Path $logDir -Mask $mask
        $w.Count | Should -BeGreaterThan 0
    }
    It 'Domänencomputer dürfen im Log-Ordner Attribute lesen und schreiben (sonst scheitert das Anfügen mit "Zugriff verweigert")' {
        $wa = Get-BroadAces -Path $logDir -Mask $FSR::WriteAttributes
        $ra = Get-BroadAces -Path $logDir -Mask $FSR::ReadAttributes
        $wa.Count | Should -BeGreaterThan 0 -Because 'Attribute schreiben (WA) fehlt'
        $ra.Count | Should -BeGreaterThan 0 -Because 'Attribute lesen (RA) fehlt; mit nur W oder WD,AD,WEA,WA,RC,S wurde der Zugriff in der Praxis verweigert'
    }
    It 'Computer/Benutzer dürfen die Logs anderer Geräte NICHT lesen' {
        $r = Get-BroadAces -Path $logDir -Mask $readMask
        $r | Should -BeNullOrEmpty -Because (($r | ForEach-Object { "$($_.IdentityReference): $($_.FileSystemRights)" }) -join '; ')
    }
    It 'die zentrale CSV hat (falls vorhanden) die erwarteten Spalten' {
        if (-not (Test-Path $cfg.CentralLogPath)) { Set-ItResult -Skipped -Because 'Zentrale Logdatei existiert noch nicht'; return }
        $first = (Get-Content -Path $cfg.CentralLogPath -TotalCount 1 -Encoding UTF8).TrimStart([char]0xFEFF)
        $first | Should -Be 'Timestamp;Level;Event;ComputerName;TargetName;Serial;MachineGuid;Message'
    }
}
