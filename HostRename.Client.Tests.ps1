<#
.SYNOPSIS
    HostRename - Client-Tests: prüft aus Sicht des Pilotgeräts, was sich ohne echtes AD nicht klären ließ.

.DESCRIPTION
    Als lokaler Administrator auf dem Pilotgerät ausführen. Alles, was "als Computer" gelten muss, läuft in
    einem temporären Scheduled Task als SYSTEM (= Computerkonto im Netzwerk).

    PRÜFT
      1. SYSTEM-Kontext: Domänenmitglied, Secure Channel
      2. Berechtigung zum Umbenennen: führt die echte Funktion Test-AdRenamePermission aus
         Invoke-HostRename.ps1 im SYSTEM-Kontext aus und zeigt, welche Attribute das Computerkonto
         schreiben darf
      3. Namensvorlage: Vorschau des Zielnamens für dieses Gerät (Seriennummer oder Zukunfts-ID, Kürzung)
         mit den echten Funktionen aus Invoke-HostRename.ps1, ohne etwas zu ändern
      4. Log-Share: Kann das Computerkonto anfügen? (schreibt eine Testdatei pester-write-test-<PC>.csv)
      5. Quell-Share: Kann das Computerkonto das Skript lesen und nicht ändern?
      6. GPO: wird per gpresult auf diesem Gerät angewendet
      7. Deployment-Zustand
           PreRun    vor dem ersten Lauf: Skript kopiert, Task korrekt aus der GPP erzeugt, Trigger,
                     lokaler Ordner nicht für Benutzer beschreibbar
           PostRun   nach Umbenennung und Neustart: Name nach Vorlage, AD-Objekt, Marker, Task und Skript
                     entfernt, zentrale Logs vollständig, lokale Logdateien und Ordner entfernt
           Auto      wählt anhand des Registry-Markers automatisch
      8. Optional (-RunIltRoundtrip, nur auf einem Pilotgerät vor dem ersten Lauf): beweist per gpupdate,
         dass das Item-Level-Targeting funktioniert (Marker gesetzt = die GPO legt Task und Skript nicht an,
         Marker entfernt = die GPO legt beides wieder an)

    Konfiguration: HostRename.Checks.psd1 (schreibt Prepare-HostRename.ps1 beim Setup).

.PARAMETER ConfigPath
    Pfad der Test-Konfiguration (Standard: HostRename.Checks.psd1 neben dieser Datei).

.PARAMETER ScriptFolder
    Ordner mit Invoke-HostRename.ps1 (Standard: der Ordner dieser Testdatei).

.PARAMETER Phase
    Auto, PreRun oder PostRun (siehe oben; Standard: Auto).

.PARAMETER RunIltRoundtrip
    Führt zusätzlich den Roundtrip-Test für das Item-Level-Targeting aus. Verändert vorübergehend Task und
    Skript auf dem Pilotgerät; die GPO stellt beides wieder her.

.PARAMETER SkipGpUpdate
    Überspringt das gpupdate vor dem Test.

.EXAMPLE
    Invoke-Pester -Path .\HostRename.Client.Tests.ps1 -Output Detailed

    Prüft das Pilotgerät vor dem ersten Lauf (Phase wird automatisch gewählt).

.EXAMPLE
    $c = New-PesterContainer -Path .\HostRename.Client.Tests.ps1 -Data @{ Phase = 'PostRun' }
    Invoke-Pester -Container $c -Output Detailed

    Prüft das Gerät nach Umbenennung und Neustart.

.EXAMPLE
    $c = New-PesterContainer -Path .\HostRename.Client.Tests.ps1 -Data @{ RunIltRoundtrip = $true }
    Invoke-Pester -Container $c -Output Detailed

    Roundtrip-Test für das Item-Level-Targeting auf dem Pilotgerät.

.NOTES
    Produkt          HostRename
    Version          1.1.9
    Stand            2026-10-30
    Ausführung       Lokaler Administrator auf dem Pilotgerät (Windows PowerShell 5.1)
    Kodierung        UTF-8 mit BOM (für die Windows PowerShell 5.1 erforderlich)

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
        throw "Konfiguration '$ConfigPath' fehlt. Zuerst .\Prepare-HostRename.ps1 -Action Setup ausführen (schreibt die Datei aus den Variablen des Skripts) oder HostRename.Checks.beispiel.psd1 als HostRename.Checks.psd1 kopieren und anpassen."
    }
    $cfg = Import-PowerShellDataFile -Path $ConfigPath

    $localScript  = Join-Path $cfg.LocalFolder $cfg.ScriptName
    $sourceScript = Join-Path $cfg.SourceShareFolder $cfg.ScriptName
    $markerPath   = 'HKLM:\' + $cfg.MarkerRegistryKey
    $deployScript = Join-Path $ScriptFolder 'Invoke-HostRename.ps1'

    $phaseResolved = if ($Phase -ne 'Auto') { $Phase } elseif (Test-Path $markerPath) { 'PostRun' } else { 'PreRun' }

    function Invoke-AsSystem {
        # Führt Code in einem temporären Scheduled Task als SYSTEM aus und liefert das (JSON-)Ergebnis zurück.
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
            return [pscustomobject]@{ Error = "Timeout nach $TimeoutSec s" }
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

Describe 'Voraussetzungen' {
    It 'läuft mit Administratorrechten' {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) | Should -BeTrue
    }
    It 'das Gerät ist Mitglied einer Domäne' {
        (Get-CimInstance Win32_ComputerSystem).PartOfDomain | Should -BeTrue
    }
    It 'Invoke-HostRename.ps1 liegt neben den Tests (für die Funktionsprüfung)' {
        Test-Path $deployScript | Should -BeTrue -Because "Erwartet: $deployScript"
    }
}

Describe 'Computerkonto-Kontext (SYSTEM)' {
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
    It 'der Test läuft tatsächlich als SYSTEM' {
        $sys.Error | Should -BeNullOrEmpty
        $sys.UserSid | Should -Be 'S-1-5-18' -Because "Benutzer: $($sys.User)"
    }
    It 'der Secure Channel zur Domäne ist intakt' {
        $sys.SecureChannel | Should -BeTrue
    }
}

Describe 'Berechtigung zum Umbenennen (echte Funktion aus Invoke-HostRename.ps1, als SYSTEM)' {
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
    It 'beide Funktionen wurden im Skript gefunden' {
        $fn.Count | Should -Be 2
    }
    It 'das Computerobjekt wird im AD gefunden' {
        $perm.Error | Should -BeNullOrEmpty
        $perm.Found | Should -BeTrue
    }
    It 'die Schreibrechte sind auswertbar (allowedAttributesEffective ist nicht leer)' {
        $perm.Inconclusive | Should -BeFalse -Because 'Sonst würde Invoke-HostRename.ps1 mit WARN fortfahren, ohne die Berechtigung zu kennen'
    }
    It 'cn und sAMAccountName sind für das Computerkonto schreibbar (Delegation wirkt)' {
        Write-Host "    Schreibbar (relevante Attribute): $(@($perm.Writable) -join ', ')"
        Write-Host "    Hinweis: dNSHostName/servicePrincipalName erscheinen nur, wenn Validated Writes dort mitgemeldet werden - das ist unkritisch."
        @($perm.Missing) | Should -BeNullOrEmpty -Because "Fehlend: $(@($perm.Missing) -join ', ') - Delegation (Prepare-HostRename.ps1 -Action Setup -Component Delegation) bzw. OU des Geräts prüfen"
    }
}

Describe 'Namensvorlage auf diesem Gerät (Vorschau, nur Phase PreRun)' {
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
    It 'liefert eine verwendbare Seriennummer oder (bei GenerateId) eine Zukunfts-ID (nur wenn die Vorlage {Serial} verwendet)' {
        if ($phaseResolved -ne 'PreRun') { Set-ItResult -Skipped -Because "Phase ist $phaseResolved"; return }
        if (-not $usesSerial)            { Set-ItResult -Skipped -Because 'Die Vorlage verwendet {Serial} nicht'; return }
        if ($usedFutureId) { Write-Host "    Keine verwendbare Seriennummer (verworfen: $(@($serial.Rejected) -join '; ')) -> Zukunfts-ID '$serialValue'" }
        else               { Write-Host "    Seriennummer: '$($serial.Value)' (Quelle: $($serial.Source))" }
        $serialValue | Should -Not -BeNullOrEmpty -Because "OnSerialProblem = $onSerial; verworfene Werte: $(@($serial.Rejected) -join '; ')"
    }
    It 'ergibt für dieses Gerät einen gültigen Zielnamen' {
        if ($phaseResolved -ne 'PreRun') { Set-ItResult -Skipped -Because "Phase ist $phaseResolved"; return }
        $plan | Should -Not -BeNullOrEmpty -Because 'Keine Regel konfiguriert oder keine verwendbare Seriennummer'
        Write-Host "    Vorschau: $($names.Active) -> $($plan.Name)$(if ($plan.Truncated) { '  (gekürzt)' })"
        $plan.Ok | Should -BeTrue -Because $plan.Error
    }
    It 'der Zielname passt zum erwarteten Muster (NameLike)' {
        if ($phaseResolved -ne 'PreRun') { Set-ItResult -Skipped -Because "Phase ist $phaseResolved"; return }
        $plan.Name | Should -BeLike $likePattern
    }
}

Describe 'Zentraler Log-Share aus Sicht des Computerkontos' {
    BeforeAll {
        $logDir   = Split-Path -Path $cfg.CentralLogPath -Parent
        $testFile = Join-Path $logDir ('pester-write-test-' + $env:COMPUTERNAME + '.csv')
        $write = Invoke-AsSystem -Variables @{ LogDir = $logDir } -Code @'
$file = Join-Path $LogDir ('pester-write-test-' + $env:COMPUTERNAME + '.csv')
$fs = [System.IO.File]::Open($file, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
try {
    $sw = New-Object System.IO.StreamWriter($fs, (New-Object System.Text.UTF8Encoding($true)))
    $sw.WriteLine('Pester-Schreibtest ' + (Get-Date -Format s))
    $sw.Flush()
}
finally { $fs.Dispose() }
@{ Written = $true }
'@
    }
    It 'das Computerkonto kann mit denselben Optionen wie das Skript (Append, FileShare.Read) anfügen' {
        $write.Error   | Should -BeNullOrEmpty
        $write.Written | Should -BeTrue
    }
    AfterAll {
        # Testdatei aufräumen (das Computerkonto hat meist keine Löschrechte, der Admin schon)
        if ($testFile -and (Test-Path $testFile)) { Remove-Item -Path $testFile -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Quell-Share aus Sicht des Computerkontos' {
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
    It 'das Computerkonto kann das Skript lesen' {
        $srcInfo.Error | Should -BeNullOrEmpty
        $srcInfo.Hash  | Should -Be $adminHash
    }
    It 'das Computerkonto kann das Skript NICHT ändern (Schutz vor Manipulation)' {
        $srcInfo.CanWrite | Should -BeFalse
    }
}

Describe 'GPO-Anwendung auf diesem Gerät' {
    BeforeAll {
        $tmp = Join-Path $env:TEMP ('gpresult-' + [guid]::NewGuid().ToString('N') + '.xml')
        & gpresult.exe /scope computer /x $tmp /f | Out-Null
        $gpr = $null
        if (Test-Path $tmp) { $gpr = New-Object System.Xml.XmlDocument; $gpr.Load($tmp) }
        $applied = if ($gpr) { @($gpr.Rsop.ComputerResults.GPO | Where-Object { $_.Name -eq $cfg.GpoName }) } else { @() }
    }
    AfterAll { if ($tmp) { Remove-Item -Path $tmp -Force -ErrorAction SilentlyContinue } }

    It 'die GPO taucht in den Ergebnissen der Computerrichtlinie auf' {
        $applied.Count | Should -BeGreaterThan 0 -Because 'OU-Verknüpfung (Link aktiviert?), Sicherheitsfilterung oder noch kein gpupdate?'
    }
    It 'die GPO wird nicht durch Filter oder Berechtigung ausgeschlossen' {
        if ($applied.Count -eq 0) { Set-ItResult -Skipped -Because 'GPO nicht in der Ergebnisliste'; return }
        $applied[0].FilterAllowed | Should -Be 'true'
        $applied[0].AccessDenied  | Should -Be 'false'
    }
}

Describe 'Deployment-Zustand vor dem ersten Lauf (Phase PreRun)' {
    BeforeAll {
        $t       = Get-ScheduledTask -TaskName $cfg.TaskName -ErrorAction SilentlyContinue
        $info    = if ($t) { Get-ScheduledTaskInfo -TaskName $cfg.TaskName } else { $null }
        $actions = if ($t) { @($t.Actions) } else { @() }
    }
    It 'das Skript wurde per GPP lokal abgelegt' {
        if ($phaseResolved -ne 'PreRun') { Set-ItResult -Skipped -Because "Phase ist $phaseResolved"; return }
        Test-Path $localScript | Should -BeTrue
    }
    It 'die lokale Kopie ist identisch mit dem Original auf dem Share' {
        if ($phaseResolved -ne 'PreRun') { Set-ItResult -Skipped -Because "Phase ist $phaseResolved"; return }
        (Get-FileHash $localScript -Algorithm SHA256).Hash | Should -Be (Get-FileHash $sourceScript -Algorithm SHA256).Hash
    }
    It 'die lokale Kopie ist syntaktisch korrekt' {
        if ($phaseResolved -ne 'PreRun') { Set-ItResult -Skipped -Because "Phase ist $phaseResolved"; return }
        $tk = $null; $er = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($localScript, [ref]$tk, [ref]$er)
        $er | Should -BeNullOrEmpty
    }
    It 'der Scheduled Task wurde aus der GPP erzeugt' {
        if ($phaseResolved -ne 'PreRun') { Set-ItResult -Skipped -Because "Phase ist $phaseResolved"; return }
        $t | Should -Not -BeNullOrEmpty
    }
    It 'der Task läuft als SYSTEM mit höchsten Rechten' {
        if ($phaseResolved -ne 'PreRun') { Set-ItResult -Skipped -Because "Phase ist $phaseResolved"; return }
        $t.Principal.UserId   | Should -Match 'SYSTEM|S-1-5-18'
        $t.Principal.RunLevel | Should -Be 'Highest'
    }
    It 'die letzte Aktion startet das lokale Skript mit der konfigurierten Umbenennungsregel' {
        if ($phaseResolved -ne 'PreRun') { Set-ItResult -Skipped -Because "Phase ist $phaseResolved"; return }
        $last = $actions[-1]
        $last.Execute   | Should -Be 'powershell.exe'
        $last.Arguments | Should -Match ([regex]::Escape($localScript))
        $rule = if ($cfg.NameTemplate) { '-NameTemplate "' + $cfg.NameTemplate + '"' } else { '-Prefix "' + $cfg.Prefix + '"' }
        $last.Arguments | Should -Match ([regex]::Escape($rule))
    }
    It 'der Task übergibt -OnSerialProblem und -FutureIdLength (nur wenn die Vorlage {Serial} verwendet)' {
        if ($phaseResolved -ne 'PreRun') { Set-ItResult -Skipped -Because "Phase ist $phaseResolved"; return }
        if ($cfg.NameTemplate -notmatch '\{SERIAL(:-?\d+)?\}') { Set-ItResult -Skipped -Because 'Die Vorlage verwendet {Serial} nicht'; return }
        $mode = if ($cfg.OnSerialProblem) { $cfg.OnSerialProblem } else { 'GenerateId' }
        $len  = if ($cfg.FutureIdLength)  { $cfg.FutureIdLength }  else { 8 }
        $actions[-1].Arguments | Should -Match ([regex]::Escape("-OnSerialProblem $mode"))
        $actions[-1].Arguments | Should -Match ([regex]::Escape("-FutureIdLength $len"))
    }
    It 'der Task übergibt -Cleanup (nur wenn Cleanup erwartet wird)' {
        if ($phaseResolved -ne 'PreRun') { Set-ItResult -Skipped -Because "Phase ist $phaseResolved"; return }
        if (-not $cfg.ExpectCleanup)     { Set-ItResult -Skipped -Because 'ExpectCleanup = $false'; return }
        $actions[-1].Arguments | Should -Match '-Cleanup'
    }
    It 'der Task führt zuerst die icacls-Absicherung aus (nur wenn Hardening erwartet wird)' {
        if ($phaseResolved -ne 'PreRun') { Set-ItResult -Skipped -Because "Phase ist $phaseResolved"; return }
        if (-not $cfg.ExpectHardening)   { Set-ItResult -Skipped -Because 'ExpectHardening = $false'; return }
        $actions.Count      | Should -BeGreaterOrEqual 3
        $actions[0].Execute | Should -Be 'icacls.exe'
        $actions[1].Execute | Should -Be 'icacls.exe'
    }
    It 'der Task hat einen Systemstart-Trigger' {
        if ($phaseResolved -ne 'PreRun') { Set-ItResult -Skipped -Because "Phase ist $phaseResolved"; return }
        @($t.Triggers | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_TaskBootTrigger' }).Count | Should -BeGreaterThan 0
    }
    It 'Standardbenutzer dürfen im lokalen Ordner nichts anlegen oder ändern (Standard-ACL bzw. Härtung)' {
        if ($phaseResolved -ne 'PreRun') { Set-ItResult -Skipped -Because "Phase ist $phaseResolved"; return }
        if (-not (Test-Path $cfg.LocalFolder)) { Set-ItResult -Skipped -Because 'Der lokale Ordner existiert noch nicht (GPO noch nicht angewendet)'; return }
        $FSR2 = [System.Security.AccessControl.FileSystemRights]
        $mask = $FSR2::WriteData -bor $FSR2::AppendData -bor $FSR2::Delete -bor $FSR2::DeleteSubdirectoriesAndFiles -bor $FSR2::ChangePermissions -bor $FSR2::TakeOwnership
        $bad = @((Get-Acl -Path $cfg.LocalFolder).Access | Where-Object {
            $sid = try { $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value } catch { '' }
            $_.AccessControlType -eq 'Allow' -and $sid -in @('S-1-5-32-545', 'S-1-5-11', 'S-1-1-0') -and (($_.FileSystemRights -band $mask) -ne 0) })
        $bad | Should -BeNullOrEmpty -Because (($bad | ForEach-Object { "$($_.IdentityReference): $($_.FileSystemRights)" }) -join '; ')
    }
    It 'der Task hat einen Registrierungs-Trigger ohne Verzögerung (nur wenn RegistrationTrigger gesetzt ist)' {
        if ($phaseResolved -ne 'PreRun') { Set-ItResult -Skipped -Because "Phase ist $phaseResolved"; return }
        if (-not $cfg.RegistrationTrigger) { Set-ItResult -Skipped -Because 'RegistrationTrigger ist abgeschaltet'; return }
        $reg = @($t.Triggers | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_TaskRegistrationTrigger' })
        $reg.Count | Should -BeGreaterThan 0
        $reg[0].Delay | Should -BeNullOrEmpty
    }
    It 'der Task hat den täglichen Trigger mit Wiederholung (nur wenn RepeatInterval gesetzt ist)' {
        if ($phaseResolved -ne 'PreRun') { Set-ItResult -Skipped -Because "Phase ist $phaseResolved"; return }
        if (-not $cfg.RepeatInterval) { Set-ItResult -Skipped -Because 'RepeatInterval ist leer'; return }
        $daily = @($t.Triggers | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_TaskDailyTrigger' })
        $daily.Count | Should -BeGreaterThan 0
        $daily[0].Repetition.Interval | Should -Be $cfg.RepeatInterval
    }
    It 'der Task ist nach dem Anlegen gelaufen (Hinweis: LastRunTime/LastTaskResult werden angezeigt)' {
        if ($phaseResolved -ne 'PreRun') { Set-ItResult -Skipped -Because "Phase ist $phaseResolved"; return }
        if (-not $info) { Set-ItResult -Skipped -Because 'Kein Task vorhanden'; return }
        Write-Host "    LastRunTime: $($info.LastRunTime)   LastTaskResult: 0x$('{0:X}' -f $info.LastTaskResult)   NextRunTime: $($info.NextRunTime)"
        if ($info.LastRunTime -lt [datetime]'2001-01-01') { Set-ItResult -Skipped -Because 'Der Task ist noch nicht gelaufen (0x41303); mit Start-ScheduledTask -TaskName ' + $cfg.TaskName + ' manuell starten'; return }
        $info.LastTaskResult | Should -BeIn @(0, 3010) -Because 'Erwartet 0 (nichts zu tun) bzw. 3010 (umbenannt, Neustart nötig)'
    }
    It 'der lokale Ordner ist abgesichert, sobald der Task einmal gelaufen ist' {
        if ($phaseResolved -ne 'PreRun')  { Set-ItResult -Skipped -Because "Phase ist $phaseResolved"; return }
        if (-not $cfg.ExpectHardening)    { Set-ItResult -Skipped -Because 'ExpectHardening = $false'; return }
        if (-not $info -or $info.LastRunTime -lt [datetime]'2001-01-01') { Set-ItResult -Skipped -Because 'Der Task ist noch nie gelaufen'; return }
        $acl = Get-Acl -Path $cfg.LocalFolder
        $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value | Should -Be 'S-1-5-32-544'
        $acl.AreAccessRulesProtected | Should -BeTrue
    }
}

Describe 'Ergebnis nach Umbenennung und Neustart (Phase PostRun)' {
    BeforeAll {
        $localLog  = Join-Path $cfg.LocalFolder 'rename-local.csv'
        $localRows = if (Test-Path $localLog) { @(Import-Csv -Path $localLog -Delimiter ';' -Encoding UTF8) } else { @() }
        $machineGuid = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Cryptography').MachineGuid
    }
    It 'der aktive Computername entspricht der Namensvorlage' {
        if ($phaseResolved -ne 'PostRun') { Set-ItResult -Skipped -Because "Phase ist $phaseResolved"; return }
        $nameLike = if ($cfg.NameLike) { $cfg.NameLike } else { "$($cfg.Prefix)*" }
        if ($names.Pending -like $nameLike -and $names.Active -notlike $nameLike) {
            Set-ItResult -Skipped -Because "Umbenennung auf '$($names.Pending)' steht aus - Neustart erforderlich"; return
        }
        $names.Active | Should -BeLike $nameLike
    }
    It 'der Zustand (HostRenameState) enthält Zielname und Vorlage' {
        if ($phaseResolved -ne 'PostRun') { Set-ItResult -Skipped -Because "Phase ist $phaseResolved"; return }
        $stateKey = 'HKLM:\SOFTWARE\HostRenameState'
        if (-not (Test-Path $stateKey)) { Set-ItResult -Skipped -Because 'Kein Zustand vorhanden (Gerät hieß schon passend oder wurde nicht von HostRename umbenannt)'; return }
        $st = Get-ItemProperty -Path $stateKey
        $st.TargetName | Should -BeExactly $names.Pending
        $st.Template   | Should -Not -BeNullOrEmpty
    }
    It 'das AD-Computerobjekt existiert mit dem neuen Namen' {
        if ($phaseResolved -ne 'PostRun') { Set-ItResult -Skipped -Because "Phase ist $phaseResolved"; return }
        $r = Invoke-AsSystem -Variables @{ Name = $names.Pending } -Code @'
$s = [adsisearcher]"(&(objectCategory=computer)(sAMAccountName=$Name`$))"
$hit = $s.FindOne()
@{ Found = [bool]$hit; Dn = $(if ($hit) { [string]$hit.Properties['distinguishedname'][0] } else { '' }) }
'@
        $r.Error | Should -BeNullOrEmpty
        $r.Found | Should -BeTrue -Because "Kein Computerobjekt mit sAMAccountName $($names.Pending)`$ gefunden"
    }
    It 'der Secure Channel ist nach der Umbenennung intakt' {
        if ($phaseResolved -ne 'PostRun') { Set-ItResult -Skipped -Because "Phase ist $phaseResolved"; return }
        if ($names.Pending -ne $names.Active) { Set-ItResult -Skipped -Because 'Neustart steht noch aus'; return }
        $r = Invoke-AsSystem -Code '[bool](Test-ComputerSecureChannel)'
        $r | Should -BeTrue
    }
    It 'der Registry-Marker ist gesetzt (nur wenn Cleanup erwartet wird)' {
        if ($phaseResolved -ne 'PostRun') { Set-ItResult -Skipped -Because "Phase ist $phaseResolved"; return }
        if (-not $cfg.ExpectCleanup)      { Set-ItResult -Skipped -Because 'ExpectCleanup = $false'; return }
        (Get-ItemProperty -Path $markerPath).Completed | Should -Not -BeNullOrEmpty
    }
    It 'der Scheduled Task wurde entfernt (nur wenn Cleanup erwartet wird)' {
        if ($phaseResolved -ne 'PostRun') { Set-ItResult -Skipped -Because "Phase ist $phaseResolved"; return }
        if (-not $cfg.ExpectCleanup)      { Set-ItResult -Skipped -Because 'ExpectCleanup = $false'; return }
        Get-ScheduledTask -TaskName $cfg.TaskName -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }
    It 'lokale Logdateien und Ordner sind nach der Bereinigung entfernt, wenn das zentrale Log funktioniert (nur wenn Cleanup erwartet wird)' {
        if ($phaseResolved -ne 'PostRun') { Set-ItResult -Skipped -Because "Phase ist $phaseResolved"; return }
        if (-not $cfg.ExpectCleanup)      { Set-ItResult -Skipped -Because 'ExpectCleanup = $false'; return }
        try   { $central = @(Import-Csv -Path $cfg.CentralLogPath -Delimiter ';' -Encoding UTF8 -ErrorAction Stop | Where-Object { $_.MachineGuid -eq $machineGuid }) }
        catch { Set-ItResult -Skipped -Because "Zentrales Log nicht lesbar für dieses Konto: $($_.Exception.Message)"; return }
        if (@($central | ForEach-Object { $_.Event }) -notcontains 'CLEANUP_DONE') { Set-ItResult -Skipped -Because 'CLEANUP_DONE steht nicht im zentralen Log (Zustellung hängt, lokale Logs bleiben dann erhalten)'; return }
        Test-Path (Join-Path $cfg.LocalFolder 'rename-local.csv') | Should -BeFalse
        Test-Path (Join-Path $cfg.LocalFolder 'pending.csv')      | Should -BeFalse
        Test-Path $cfg.LocalFolder                                | Should -BeFalse -Because 'Der leere Ordner wird mit entfernt'
    }
    It 'das lokale Skript wurde entfernt (nur wenn Cleanup erwartet wird)' {
        if ($phaseResolved -ne 'PostRun') { Set-ItResult -Skipped -Because "Phase ist $phaseResolved"; return }
        if (-not $cfg.ExpectCleanup)      { Set-ItResult -Skipped -Because 'ExpectCleanup = $false'; return }
        Test-Path $localScript | Should -BeFalse
    }
    It 'das lokale Log dokumentiert die Umbenennung bzw. den bereits gesetzten Namen' {
        if ($phaseResolved -ne 'PostRun') { Set-ItResult -Skipped -Because "Phase ist $phaseResolved"; return }
        if (-not $localRows.Count) { Set-ItResult -Skipped -Because 'Das lokale Log existiert nicht mehr (nach erfolgreicher Zustellung entfernt, Soll)'; return }
        $ev = @($localRows | ForEach-Object { $_.Event })
        ($ev -contains 'RENAMED' -or $ev -contains 'ALREADY_DONE' -or $ev -contains 'PENDING_REBOOT') | Should -BeTrue -Because "Events: $($ev -join ', ')"
    }
    It 'das lokale Log dokumentiert die Bereinigung (nur wenn Cleanup erwartet wird)' {
        if ($phaseResolved -ne 'PostRun') { Set-ItResult -Skipped -Because "Phase ist $phaseResolved"; return }
        if (-not $cfg.ExpectCleanup)      { Set-ItResult -Skipped -Because 'ExpectCleanup = $false'; return }
        if (-not $localRows.Count) { Set-ItResult -Skipped -Because 'Das lokale Log existiert nicht mehr (nach erfolgreicher Zustellung entfernt, Soll); CLEANUP_DONE steht im zentralen Log'; return }
        @($localRows | ForEach-Object { $_.Event }) | Should -Contain 'CLEANUP_DONE'
    }
    It 'das zentrale Log enthält Einträge dieses Geräts (per MachineGuid)' {
        if ($phaseResolved -ne 'PostRun') { Set-ItResult -Skipped -Because "Phase ist $phaseResolved"; return }
        try   { $rows = @(Import-Csv -Path $cfg.CentralLogPath -Delimiter ';' -Encoding UTF8 -ErrorAction Stop) }
        catch { Set-ItResult -Skipped -Because "Zentrales Log nicht lesbar für dieses Konto: $($_.Exception.Message)"; return }
        $mine = @($rows | Where-Object { $_.MachineGuid -eq $machineGuid })
        $mine.Count | Should -BeGreaterThan 0
        $errs = @($mine | Where-Object { $_.Level -eq 'ERROR' })
        Write-Host "    Zentrales Log: $($mine.Count) Einträge dieses Geräts, davon $($errs.Count) ERROR"
        if ($cfg.ExpectCleanup) { @($mine | ForEach-Object { $_.Event }) | Should -Contain 'CLEANUP_DONE' }
    }
    It 'die GPO legt Task und Skript nach gpupdate NICHT erneut an (nur wenn Cleanup erwartet wird)' {
        if ($phaseResolved -ne 'PostRun') { Set-ItResult -Skipped -Because "Phase ist $phaseResolved"; return }
        if (-not $cfg.ExpectCleanup)      { Set-ItResult -Skipped -Because 'ExpectCleanup = $false'; return }
        if ($SkipGpUpdate)                { Set-ItResult -Skipped -Because 'SkipGpUpdate = $true'; return }
        Invoke-GpUpdate
        Test-Path $localScript | Should -BeFalse
        Get-ScheduledTask -TaskName $cfg.TaskName -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }
}

Describe 'Item-Level-Targeting: Roundtrip mit Marker (opt-in: -RunIltRoundtrip)' {
    BeforeAll {
        $iltRun = $RunIltRoundtrip -and
                  $cfg.ExpectCleanup -and
                  ($phaseResolved -eq 'PreRun') -and
                  (Test-Path $localScript) -and
                  [bool](Get-ScheduledTask -TaskName $cfg.TaskName -ErrorAction SilentlyContinue)
        $withMarker = $null; $withoutMarker = $null
        if ($iltRun) {
            # A) Mit Marker: Task und Skript entfernen, GPO anwenden -> darf NICHTS neu anlegen
            New-Item -Path $markerPath -Force | Out-Null
            Unregister-ScheduledTask -TaskName $cfg.TaskName -Confirm:$false
            Remove-Item -Path $localScript -Force
            Invoke-GpUpdate
            $withMarker = [pscustomobject]@{
                FileExists = (Test-Path $localScript)
                TaskExists = [bool](Get-ScheduledTask -TaskName $cfg.TaskName -ErrorAction SilentlyContinue)
            }
            # B) Ohne Marker: GPO anwenden -> muss beides wieder anlegen
            Remove-Item -Path $markerPath -Recurse -Force
            Invoke-GpUpdate
            $withoutMarker = [pscustomobject]@{
                FileExists = (Test-Path $localScript)
                TaskExists = [bool](Get-ScheduledTask -TaskName $cfg.TaskName -ErrorAction SilentlyContinue)
            }
        }
    }
    AfterAll {
        # Sicherstellen, dass der Marker nicht auf dem Pilotgerät verbleibt
        if ($iltRun -and (Test-Path $markerPath)) { Remove-Item -Path $markerPath -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'Mit Marker: die GPO legt das Skript NICHT neu an' {
        if (-not $iltRun) { Set-ItResult -Skipped -Because 'Nicht aktiviert oder Voraussetzungen nicht erfüllt (-RunIltRoundtrip, Phase PreRun, Task+Skript vorhanden)'; return }
        $withMarker.FileExists | Should -BeFalse -Because 'Das Item-Level-Targeting greift nicht - XML-Syntax des Targetings prüfen'
    }
    It 'Mit Marker: die GPO legt den Task NICHT neu an' {
        if (-not $iltRun) { Set-ItResult -Skipped -Because 'Nicht aktiviert oder Voraussetzungen nicht erfüllt'; return }
        $withMarker.TaskExists | Should -BeFalse -Because 'Das Item-Level-Targeting greift nicht - XML-Syntax des Targetings prüfen'
    }
    It 'Ohne Marker: die GPO legt das Skript wieder an' {
        if (-not $iltRun) { Set-ItResult -Skipped -Because 'Nicht aktiviert oder Voraussetzungen nicht erfüllt'; return }
        $withoutMarker.FileExists | Should -BeTrue -Because 'Die GPP "Files" wird nicht (mehr) angewendet - ILT-Syntax oder GPO-Verarbeitung prüfen'
    }
    It 'Ohne Marker: die GPO legt den Task wieder an' {
        if (-not $iltRun) { Set-ItResult -Skipped -Because 'Nicht aktiviert oder Voraussetzungen nicht erfüllt'; return }
        $withoutMarker.TaskExists | Should -BeTrue -Because 'Die GPP "Scheduled Tasks" wird nicht (mehr) angewendet - ILT-Syntax oder GPO-Verarbeitung prüfen'
    }
}
