<#
.SYNOPSIS
    HostRename - lokale Tests: prüft Skripte, Registry, icacls, Selbstlöschung und Namenslogik.

.DESCRIPTION
    Läuft auf jedem Windows-Rechner (DC und Client) als Administrator und braucht kein AD-Objekt.

    PRÜFT
      1. Syntax aller .ps1-Dateien im Skriptordner; einheitliche Versionsangaben (Variable im Client-Skript und .NOTES)
      2. Sind die CSE-GUIDs für GPP "Files", "Scheduled Tasks" und "Registry" auf diesem System bekannt (gpprefcl.dll)?
      3. Funktionieren die icacls-Befehle des Tasks (Besitzer und ACL des lokalen Ordners)?
      4. Kann ein per SYSTEM laufender Scheduled Task sich selbst löschen und danach seine Skriptdatei
         entfernen (Grundlage von -Cleanup)?
      5. Namenslogik, aus Invoke-HostRename.ps1 geladen: Namensvorlagen (Platzhalter, Längenangaben, Kürzen,
         Fehlerfälle), Bewertung von Seriennummern (mit vorgegebenen WMI-Werten) und die generierte
         Zukunfts-ID (stabil, eindeutig, gültiges Alphabet)

    Die Tests legen nur temporäre Objekte unter %ProgramData%\HostRename-Pester-* an und räumen sie wieder auf.

.PARAMETER ScriptFolder
    Ordner mit den Skripten (Standard: der Ordner dieser Testdatei).

.EXAMPLE
    Invoke-Pester -Path .\HostRename.Local.Tests.ps1 -Output Detailed

.NOTES
    Produkt          HostRename
    Version          1.1.9
    Stand            2026-10-30
    Ausführung       Administrator auf dem DC oder Client (Windows PowerShell 5.1)
    Kodierung        UTF-8 mit BOM (für die Windows PowerShell 5.1 erforderlich)

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
    # Vorlage, Name, Seriennummer, Modus -> erwarteter Zielname bzw. Fehlercode (Maximallänge 15)
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
    # WMI-Werte (BIOS, System-Produkt, Mainboard) -> erwartete Seriennummer und Quelle
    $SerialCases = @(
        @{ Label = 'Dell Service Tag im BIOS';                          Bios = 'ABC1234';                Csp = 'X';         Bb = 'Y';    Expect = 'ABC1234';        Source = 'BIOS' }
        @{ Label = 'Hersteller-Platzhalter im BIOS, System-Produkt ok'; Bios = 'To Be Filled By O.E.M.'; Csp = 'XYZ98765'; Bb = 'B';    Expect = 'XYZ98765';       Source = 'ComputerSystemProduct' }
        @{ Label = 'VM-Seriennummer mit Leerzeichen und Bindestrichen'; Bios = 'VMware-42 1a 3b 4c';    Csp = '';          Bb = '';     Expect = 'VMWARE421A3B4C'; Source = 'BIOS' }
        @{ Label = 'alle Quellen unbrauchbar';                          Bios = 'Default string';        Csp = '0';         Bb = 'None'; Expect = '';               Source = '' }
        @{ Label = 'nur ein wiederholtes Zeichen';                      Bios = '00000000';              Csp = 'FFFFFFFF';  Bb = 'xx';   Expect = '';               Source = '' }
    )
}

BeforeAll {
    $ScriptFolder = if ($ScriptFolder) { $ScriptFolder } else { $PSScriptRoot }

    # Funktionen der Namensvorlage aus dem Client-Skript laden (dieselbe Logik wie auf den Clients)
    $invokePath = Join-Path $ScriptFolder 'Invoke-HostRename.ps1'
    if (Test-Path $invokePath) {
        $tk = $null; $er = $null
        $invokeAst = [System.Management.Automation.Language.Parser]::ParseFile($invokePath, [ref]$tk, [ref]$er)
        $fns = $invokeAst.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -in @('Resolve-NameTemplate', 'Get-DeviceSerial', 'New-FutureId') }, $true)
        . ([scriptblock]::Create((($fns | ForEach-Object { $_.Extent.Text }) -join "`r`n")))
    }

    # WMI-Werte für die Seriennummer-Tests vorgeben; solange leer, wird die echte Abfrage durchgereicht
    $cim = @{}
    function Get-CimInstance {
        param([string]$ClassName)
        if ($cim.Count -gt 0) { [pscustomobject]$cim[$ClassName] }
        else                  { CimCmdlets\Get-CimInstance -ClassName $ClassName }
    }
}

Describe 'Voraussetzungen' {
    It 'läuft mit Administratorrechten' {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) |
            Should -BeTrue -Because 'Scheduled Tasks als SYSTEM und icacls /setowner benötigen Administratorrechte'
    }
}

Describe 'Versionsangaben' {
    It 'die Version im Client-Skript ($ScriptVersion, steht im START-Eintrag des Logs) entspricht der Version in den .NOTES aller Skripte' {
        # [regex]::Match statt $Matches: Should -Match wertet in einem eigenen Gültigkeitsbereich aus, $Matches bliebe leer
        $inv  = Get-Content -Raw -Path (Join-Path $ScriptFolder 'Invoke-HostRename.ps1')
        $ver  = [regex]::Match($inv, "(?m)^\`$ScriptVersion\s*=\s*'([^']+)'")
        $ver.Success | Should -BeTrue -Because '$ScriptVersion wurde in Invoke-HostRename.ps1 nicht gefunden'
        $code = $ver.Groups[1].Value
        $notes = foreach ($f in Get-ChildItem -Path $ScriptFolder -Filter '*.ps1') {
            $v = [regex]::Match((Get-Content -Raw -Path $f.FullName), '(?m)^\s+Version\s+(\S+)\s*$')
            if ($v.Success) { [pscustomobject]@{ File = $f.Name; Version = $v.Groups[1].Value } }
        }
        @($notes).Count | Should -BeGreaterThan 0 -Because 'In den .NOTES der Skripte steht keine Version'
        $differ = @($notes | Where-Object { $_.Version -ne $code } | ForEach-Object { "$($_.File)=$($_.Version)" })
        $differ | Should -BeNullOrEmpty -Because "ScriptVersion ist $code; abweichend: $($differ -join ', ')"
    }
}

Describe 'Syntax: <Name>' -ForEach $ScriptFiles {
    It 'lässt sich fehlerfrei parsen' {
        $tokens = $null; $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
        $msg = ($errors | ForEach-Object { 'Zeile {0}: {1}' -f $_.Extent.StartLineNumber, $_.Message }) -join '; '
        $errors | Should -BeNullOrEmpty -Because $msg
    }
}

Describe 'GPP-Client-Side-Extensions auf diesem System' {
    It '<Name> ist registriert (<Guid>)' -ForEach $CseCases {
        $key = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\GPExtensions\$Guid"
        Test-Path $key | Should -BeTrue -Because 'Die GUID in gPCMachineExtensionNames stimmt sonst nicht mit der Windows-Registrierung überein'
    }
    It '<Name> wird von gpprefcl.dll verarbeitet' -ForEach $CseCases {
        $key = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\GPExtensions\$Guid"
        (Get-ItemProperty -Path $key -ErrorAction Stop).DllName | Should -Match 'gpprefcl\.dll'
    }
}

Describe 'Ordner-Absicherung per icacls (Befehle aus dem Scheduled Task)' {
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

    It 'icacls-Befehle konnten aus Prepare-HostRename.ps1 gelesen werden' {
        $fmtOwner | Should -Not -BeNullOrEmpty
        $fmtAcl   | Should -Not -BeNullOrEmpty
    }
    It '/setowner mit SID-Notation (*S-1-5-32-544) wird akzeptiert' {
        $exitOwner | Should -Be 0
    }
    It '/inheritance:r /grant:r mit SID-Notation wird akzeptiert' {
        $exitAcl | Should -Be 0
    }
    It 'Besitzer ist die Gruppe Administratoren' {
        $dirAcl.GetOwner([Security.Principal.SecurityIdentifier]).Value | Should -Be 'S-1-5-32-544'
    }
    It 'Vererbung vom Elternordner ist entfernt' {
        $dirAcl.AreAccessRulesProtected | Should -BeTrue
    }
    It 'SYSTEM hat Vollzugriff' {
        $r = $dirAcl.Access | Where-Object { (& $sid $_) -eq 'S-1-5-18' }
        ($r.FileSystemRights -band $FSR::FullControl) | Should -Be $FSR::FullControl
    }
    It 'Benutzer (S-1-5-32-545) dürfen lesen, aber nicht schreiben' {
        $r = @($dirAcl.Access | Where-Object { (& $sid $_) -eq 'S-1-5-32-545' })
        $r.Count | Should -BeGreaterThan 0
        foreach ($rule in $r) {
            ($rule.FileSystemRights -band $FSR::ReadAndExecute) | Should -Be $FSR::ReadAndExecute
            ($rule.FileSystemRights -band $writeMask) | Should -Be 0
        }
    }
    It 'Die vorhandene Datei im Ordner hat ebenfalls keine Schreibrechte für Benutzer' {
        $r = @($fileAcl.Access | Where-Object { (& $sid $_) -in @('S-1-5-32-545', 'S-1-5-11', 'S-1-1-0') })
        foreach ($rule in $r) {
            ($rule.FileSystemRights -band $writeMask) | Should -Be 0
        }
    }
}

Describe 'Selbstlöschung eines laufenden Scheduled Tasks (Grundlage von -Cleanup)' {
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

    It 'der Task hat das Skript gestartet und es wurde ausgeführt' {
        $result.Count | Should -BeGreaterThan 0 -Because 'Der Task hat innerhalb von 60 s nichts geschrieben'
        ($result -join ' | ') | Should -Not -Match 'error:' -Because ($result -join ' | ')
    }
    It 'Unregister-ScheduledTask aus dem laufenden Task heraus funktioniert' {
        $result | Should -Contain 'task-unregistered'
    }
    It 'das Skript läuft nach dem Löschen des Tasks weiter' {
        $result | Should -Contain 'script-deleted'
    }
    It 'der Task ist danach nicht mehr vorhanden' {
        Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }
    It 'die Skriptdatei hat sich selbst gelöscht' {
        Test-Path $scriptPath | Should -BeFalse
        $result | Should -Contain 'done'
    }
}

Describe 'Namensvorlagen: Funktionen sind geladen' {
    It 'Resolve-NameTemplate und Get-DeviceSerial wurden aus Invoke-HostRename.ps1 gelesen' {
        Get-Command Resolve-NameTemplate -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        Get-Command Get-DeviceSerial     -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        Get-Command New-FutureId         -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
}

Describe 'Namensvorlage <Tpl> | Name <Name> | Serial <Serial> | <Mode>' -ForEach $TemplateCases {
    It 'ergibt das erwartete Ergebnis' {
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

Describe 'Seriennummer-Bewertung (vorgegebene WMI-Werte): <Label>' -ForEach $SerialCases {
    BeforeAll {
        $cim.Clear()
        $cim['Win32_BIOS']                 = @{ SerialNumber = $Bios }
        $cim['Win32_ComputerSystemProduct'] = @{ IdentifyingNumber = $Csp }
        $cim['Win32_BaseBoard']            = @{ SerialNumber = $Bb }
        $result = Get-DeviceSerial
    }
    AfterAll { $cim.Clear() }

    It 'liefert die erwartete Seriennummer' {
        if ($Expect) { $result.Value | Should -BeExactly $Expect }
        else         { $result.Value | Should -BeNullOrEmpty }
    }
    It 'nennt die erwartete Quelle' {
        if ($Source) { $result.Source | Should -Be $Source }
        else         { $result.Source | Should -BeNullOrEmpty }
    }
}

Describe 'Zukunfts-ID (New-FutureId)' {
    It 'ist für denselben Startwert stabil (wiederholte Läufe ergeben denselben Namen)' {
        New-FutureId -Seed 'GUID-1' | Should -BeExactly (New-FutureId -Seed 'GUID-1')
    }
    It 'liefert beim nächsten Versuch eine andere ID (Kollisionsfall)' {
        New-FutureId -Seed 'GUID-1' -Attempt 1 | Should -Not -BeExactly (New-FutureId -Seed 'GUID-1' -Attempt 0)
    }
    It 'liefert für verschiedene Startwerte verschiedene IDs' {
        $ids = 1..1000 | ForEach-Object { New-FutureId -Seed "seed-$_" }
        @($ids | Select-Object -Unique).Count | Should -Be 1000
    }
    It 'hat die gewünschte Länge <_>' -ForEach @(4, 8, 12) {
        (New-FutureId -Seed 'x' -Length $_).Length | Should -Be $_
    }
    It 'verwendet nur A-Z ohne I und O sowie 2-9' {
        $bad = 1..500 | ForEach-Object { New-FutureId -Seed "s$_" } | Where-Object { $_ -cnotmatch '^[A-HJ-NP-Z2-9]{8}$' }
        @($bad).Count | Should -Be 0
    }
    It 'besteht nie nur aus Ziffern (auch bei kurzen IDs)' {
        $bad = 1..500 | ForEach-Object { New-FutureId -Seed "s$_" -Length 4 } | Where-Object { $_ -match '^[0-9]+$' }
        @($bad).Count | Should -Be 0
    }
    It 'ergibt zusammen mit einer Vorlage einen gültigen Namen' {
        $r = Resolve-NameTemplate -Template 'DE{SERIAL}' -CurrentName 'PC349219' -Serial (New-FutureId -Seed 'GUID-1') -MaxLength 15 -OnTooLong 'TruncateEnd'
        $r.Ok | Should -BeTrue -Because $r.Error
        $r.Name | Should -Match '^DE[A-HJ-NP-Z2-9]{8}$'
    }
}
