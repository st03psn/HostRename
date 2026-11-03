<#
.SYNOPSIS
    HostRename - Client-Skript: benennt ein domänengebundenes Windows-Gerät und sein AD-Computerobjekt um.

.DESCRIPTION
    Läuft auf dem Client als Scheduled Task (SYSTEM) und benennt den Computer mit Rename-Computer um; dabei
    wird auch das AD-Computerobjekt umbenannt. Das Skript ist idempotent: Es kann beliebig oft laufen und
    benennt jedes Gerät nur einmal um. Mit -WhatIf zeigt es nur den Zielnamen, ohne etwas zu ändern.

    NAMENSVORLAGE
      {Name}          bisheriger Hostname
      {Serial}        Seriennummer (BIOS, sonst System-Produkt, sonst Mainboard; nur A-Z und 0-9).
                      Herstellerplatzhalter ("To Be Filled By O.E.M."), Werte unter 4 Zeichen und Werte aus
                      nur einem Zeichen werden verworfen.
      Länge           {Serial:8} = erste 8, {Serial:-8} = letzte 8 Zeichen (ebenso {Name:4}, {Name:-4})
      Ohne Vorlage    -Prefix und -Suffix bilden "Prefix{Name}Suffix"
      Zielname        höchstens 15 Zeichen aus A-Z, 0-9, _ und -; kein - am Anfang oder Ende; nicht nur Ziffern
      Zu lang         Gekürzt werden nur die Platzhalter-Werte, der letzte zuerst; feste Zeichen bleiben (-OnTooLong)

    ABLAUF
      1. Erledigt?    Entspricht der Name der Vorlage bzw. dem gemerkten Zielnamen (HKLM:\SOFTWARE\HostRenameState),
                      ist nichts zu tun; mit -Cleanup wird aufgeräumt. Eine andere Vorlage löst eine neue
                      Umbenennung aus.
      2. Zentrales Log prüfen: Namensauflösung, Port 445, Schreibrecht. Das Ergebnis steht nur im lokalen Log
                      (LOG_CHECK); das Umbenennen läuft in jedem Fall weiter.
      3. Seriennummer ermitteln (nur bei {Serial}). Ist sie unbrauchbar oder der Zielname im AD schon vergeben,
                      ersetzt eine Zukunfts-ID den Platzhalter (-OnSerialProblem).
      4. Vorabprüfungen: Domänenmitglied, Secure Channel, Schreibrechte auf dem eigenen AD-Objekt
                      (allowedAttributesEffective), Namenskollision im AD, DNS-Auflösung (nur Warnung).
      5. Zielnamen bilden und gegebenenfalls kürzen.
      6. Umbenennen, im AD nachprüfen (nur Warnung), Zustand merken, optional Neustart planen (-Reboot).
      7. Mit -Cleanup: Log-Einträge auf den Share bringen, Registry-Marker setzen, Task und Skript entfernen
                      und, sobald alles angekommen ist, die lokalen Logdateien samt leerem Ordner. Bis dahin
                      bleibt die Bereinigung zurückgestellt und wird beim nächsten Lauf nachgeholt.

    ZUKUNFTS-ID
      Ist die Seriennummer nicht verwendbar oder der Zielname im AD schon vergeben, ersetzt eine generierte
      ID den Platzhalter {Serial} (-OnSerialProblem GenerateId, Standard). Sie ist kurz (-FutureIdLength,
      Standard 8 Zeichen aus A-Z ohne I und O sowie 2-9), wird stabil aus der MachineGuid berechnet und bei
      einer Kollision mit dem nächsten Zähler neu gebildet (bis zu 5 Versuche). Mit -OnSerialProblem Skip
      wird stattdessen übersprungen (Exit-Code 5) bzw. bei einer Kollision abgebrochen.

    LOGGING
      Jedes Ereignis steht im zentralen CSV-Log auf dem Share (-CentralLogPath) und im lokalen Log
      (-LocalDir). Ist der Share nicht erreichbar, bleiben die Einträge in pending.csv und werden beim
      nächsten Lauf nachgeliefert; der Grund steht als LOG_DELIVERY im lokalen Log.

    VORAUSSETZUNGEN
      - Ausführung als SYSTEM bzw. mit Administratorrechten in der 64-Bit-PowerShell.
      - AD-Rechte: Das Computerkonto (SELF) braucht Schreibrechte auf sein Objekt (cn, name, sAMAccountName,
        displayName, Account Restrictions, Reset password sowie die Validated Writes für DNS-Hostname und
        SPN), oder es wird -DomainCredential verwendet. Prepare-HostRename.ps1 setzt sie per Delegation.
      - Zentrales Log: Domänencomputer brauchen auf dem Log-Ordner Daten schreiben und anfügen sowie
        Attribute lesen und schreiben, aber kein Lesen der Inhalte.

.PARAMETER NameTemplate
    Namensvorlage mit {Name} und/oder {Serial}; hat Vorrang vor -Prefix und -Suffix. Beispiele:
      'DE{Serial}'          PC349219 -> DE<Seriennummer>
      'NG-{Name}'           PC349219 -> NG-PC349219 (entspricht -Prefix "NG-")
      'DE-{Serial:-8}'      DE- plus die letzten 8 Zeichen der Seriennummer
      '{Serial}-{Name:-4}'  Seriennummer, Bindestrich, die letzten 4 Zeichen des alten Namens
    Feste Zeichen: A-Z, 0-9, _ und -.

.PARAMETER Prefix
    Prefix vor dem bisherigen Namen, z. B. "NG-" (höchstens 10 Zeichen; A-Z, 0-9, Bindestrich).

.PARAMETER Suffix
    Suffix hinter dem bisherigen Namen, z. B. "-W11" (höchstens 10 Zeichen; A-Z, 0-9, Bindestrich).

.PARAMETER OnTooLong
    Verhalten, wenn der Name aus der Vorlage länger als 15 Zeichen wäre:
      TruncateEnd     Platzhalter-Werte hinten kürzen [Standard]
      TruncateStart   Platzhalter-Werte vorne kürzen (erhält z. B. laufende Nummern am Ende)
      Skip            nicht umbenennen (Exit-Code 2)

.PARAMETER OnSerialProblem
    Verhalten, wenn die Vorlage {Serial} enthält, die Seriennummer aber nicht verwendbar ist oder der
    Zielname im AD schon existiert:
      GenerateId      generierte Zukunfts-ID statt der Seriennummer verwenden [Standard]
      Skip            nicht umbenennen (Exit-Code 5 bzw. COLLISION)

.PARAMETER FutureIdLength
    Länge der generierten Zukunfts-ID, 4 bis 12 Zeichen (Standard: 8).

.PARAMETER CentralLogPath
    Vollständiger Pfad der zentralen CSV-Datei auf dem Share. Der Standardwert ist ein Platzhalter; die GPO
    übergibt den echten Pfad aus Prepare-HostRename.ps1.

.PARAMETER DomainCredential
    Optional: Domänenkonto mit Rechten zum Umbenennen des AD-Objekts. Ohne Angabe gilt der Kontext des
    ausführenden Kontos (SYSTEM = Computerkonto).

.PARAMETER Reboot
    Plant nach erfolgreicher Umbenennung einen Neustart mit Vorwarnzeit (-RebootDelaySeconds).

.PARAMETER RebootDelaySeconds
    Vorwarnzeit für den Neustart in Sekunden (Standard: 900).

.PARAMETER Cleanup
    Entfernt nach Abschluss den Scheduled Task (-TaskName), dieses Skript, die lokalen Logdateien und den
    leeren Ordner. Nur für den Lauf per Scheduled Task gedacht; bei manuellen Läufen NICHT angeben, sonst
    wird die Skriptdatei (z. B. auf dem Share) gelöscht.

.PARAMETER TaskName
    Name des Scheduled Tasks, der mit -Cleanup entfernt wird (Standard: HostRename).

.PARAMETER LocalDir
    Lokaler Ordner für rename-local.csv und pending.csv (Standard: <Program Files>\HostRename). Dort dürfen
    Standardbenutzer nichts anlegen oder ändern, SYSTEM schreibt also nicht in einen von Benutzern
    manipulierbaren Ordner. Die GPO übergibt den Ordner, in den sie das Skript kopiert.

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-HostRename.ps1 -Prefix "NG-" -WhatIf

    Testlauf ohne Änderung: zeigt den Zielnamen für dieses Gerät.

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-HostRename.ps1 -Prefix "NG-" -Reboot

    Benennt um und startet nach 15 Minuten neu.

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-HostRename.ps1 -NameTemplate "DE{Serial}" -WhatIf

    Vorschau einer Umbenennung nach Seriennummer: PC349219 -> DE<Seriennummer>.

.OUTPUTS
    Keine Pipeline-Ausgabe. Der Exit-Code beschreibt das Ergebnis:
      0       nichts zu tun (Name entspricht schon der Vorlage) bzw. -WhatIf
      3010    umbenannt oder Umbenennung ausstehend, Neustart erforderlich
      1       Fehler (Details im Log)
      2       übersprungen: Name zu lang (-OnTooLong Skip)
      4       keine Berechtigung zum Umbenennen auf dem eigenen AD-Objekt
      5       keine verwendbare Seriennummer (Vorlage mit {Serial}, nur bei -OnSerialProblem Skip)

.NOTES
    Produkt          HostRename
    Version          1.1.9
    Stand            2026-10-30
    Ausführung       Scheduled Task als SYSTEM (per GPO verteilt) oder manuell als Administrator
    Kodierung        UTF-8 mit BOM (für die Windows PowerShell 5.1 erforderlich)

.LINK
    README.md
#>
#Requires -Version 5.1

[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidatePattern('^$|^[A-Za-z0-9_{}:-]+$')]
    [string]$NameTemplate = '',

    [ValidatePattern('^$|^[A-Za-z0-9][A-Za-z0-9-]{0,9}$')]
    [string]$Prefix = '',

    [ValidatePattern('^$|^[A-Za-z0-9-]{1,10}$')]
    [string]$Suffix = '',

    [ValidateSet('TruncateStart', 'TruncateEnd', 'Skip')]
    [string]$OnTooLong = 'TruncateEnd',

    [ValidateSet('GenerateId', 'Skip')]
    [string]$OnSerialProblem = 'GenerateId',

    [ValidateRange(4, 12)]
    [int]$FutureIdLength = 8,

    [string]$CentralLogPath = '\\FILESERVER\HostRename$\log\rename-log.csv',

    [pscredential]$DomainCredential,

    [switch]$Reboot,

    [int]$RebootDelaySeconds = 900,

    [switch]$Cleanup,

    [string]$TaskName = 'HostRename',

    [string]$LocalDir = ''
)

$ErrorActionPreference = 'Stop'
$ScriptVersion = '1.1.9'   # muss zur Version in .NOTES passen (prüft HostRename.Local.Tests.ps1)
$MaxLen     = 15
if (-not $LocalDir) {
    $programFiles = if ($env:ProgramW6432) { $env:ProgramW6432 } else { $env:ProgramFiles }
    $LocalDir = Join-Path $programFiles 'HostRename'
}
$LocalLog   = Join-Path $LocalDir 'rename-local.csv'
$PendingLog = Join-Path $LocalDir 'pending.csv'
$CsvHeader  = 'Timestamp;Level;Event;ComputerName;TargetName;Serial;MachineGuid;Message'
$regCN      = 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName'
$MarkerKey  = 'HKLM:\SOFTWARE\HostRename'   # muss zu $MarkerRegistryKey in Prepare-HostRename.ps1 passen
$StateKey   = 'HKLM:\SOFTWARE\HostRenameState'   # merkt sich Ursprungsname und Zielname (Idempotenz bei Vorlagen mit {Name} + {Serial})

try {
    if (-not (Test-Path $LocalDir)) { New-Item -ItemType Directory -Path $LocalDir -Force | Out-Null }
}
catch {
    # z. B. manueller Lauf ohne Administratorrechte: auf den Temp-Ordner ausweichen
    $LocalDir   = Join-Path $env:TEMP 'HostRename'
    $LocalLog   = Join-Path $LocalDir 'rename-local.csv'
    $PendingLog = Join-Path $LocalDir 'pending.csv'
    New-Item -ItemType Directory -Path $LocalDir -Force | Out-Null
}

# ---- Geräte-Identität (stabile Schlüssel für die Log-Suche) -----------------
$script:CurrentName = $env:COMPUTERNAME
$script:TargetName  = ''
$script:Serial      = ''
$script:MachineGuid = ''
try { $script:Serial      = (Get-CimInstance -ClassName Win32_BIOS).SerialNumber }
catch { Write-Verbose "Seriennummer (BIOS) nicht lesbar, das Log bleibt ohne Seriennummer: $($_.Exception.Message)" }
try { $script:MachineGuid = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Cryptography').MachineGuid }
catch { Write-Verbose "MachineGuid nicht lesbar, das Log bleibt ohne MachineGuid: $($_.Exception.Message)" }

# ---- Logging -----------------------------------------------------------------
function ConvertTo-CsvField {
    param([string]$Value)
    '"' + (($Value -replace '[\r\n]+', ' ') -replace '"', '""') + '"'
}

function Send-PendingLog {
    # Hängt alle noch nicht übertragenen Zeilen an die zentrale CSV an.
    # Exklusiver Schreibzugriff (FileShare.Read) + Retry, damit parallele Geräte sich nicht überschreiben.
    if (-not (Test-Path $PendingLog)) { return }
    $lines = @(Get-Content -Path $PendingLog -Encoding UTF8 | Where-Object { $_ })
    if ($lines.Count -eq 0) { return }

    $lastError = ''
    for ($i = 1; $i -le 6; $i++) {
        try {
            $fs = [System.IO.File]::Open($CentralLogPath,
                    [System.IO.FileMode]::Append,
                    [System.IO.FileAccess]::Write,
                    [System.IO.FileShare]::Read)
            try {
                $sw = New-Object System.IO.StreamWriter($fs, (New-Object System.Text.UTF8Encoding($true)))
                # Position statt Length: nach dem Öffnen im Append-Modus steht die Position am Dateiende; 0 = leere Datei.
                # Length bräuchte das Recht "Attribute lesen", das Computerkonten auf dem Log-Ordner bewusst nicht haben.
                if ($fs.Position -eq 0) { $sw.WriteLine($CsvHeader) }
                foreach ($l in $lines) { $sw.WriteLine($l) }
                $sw.Flush()
            }
            finally { $fs.Dispose() }
            Remove-Item -Path $PendingLog -Force
            return
        }
        catch {
            $lastError = $_.Exception.Message
            Start-Sleep -Milliseconds (Get-Random -Minimum 300 -Maximum 1500)
        }
    }
    # Share nicht erreichbar/gesperrt: Einträge bleiben in pending.csv und werden beim nächsten Lauf nachgeliefert.
    # Den Grund einmal pro Lauf lokal festhalten (sonst bleibt der Fehler unsichtbar). -LocalOnly verhindert Rekursion.
    if (-not $script:deliveryWarned) {
        $script:deliveryWarned = $true
        Write-RenameLog -Level WARN -EventName LOG_DELIVERY -Message "Zentrales Log '$CentralLogPath' nicht beschreibbar: $lastError - Einträge bleiben in pending.csv und werden beim nächsten Lauf nachgeliefert." -LocalOnly
    }
}

function Write-RenameLog {
    param(
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level,
        [string]$EventName,
        [string]$Message,
        [switch]$LocalOnly
    )
    $ts  = Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz'
    $row = (@($ts, $Level, $EventName, $script:CurrentName, $script:TargetName,
              $script:Serial, $script:MachineGuid, $Message) |
            ForEach-Object { ConvertTo-CsvField ([string]$_) }) -join ';'

    if (-not (Test-Path $LocalLog)) { Set-Content -Path $LocalLog -Value $CsvHeader -Encoding UTF8 }
    Add-Content -Path $LocalLog -Value $row -Encoding UTF8
    Write-Output ('{0} [{1}] {2}: {3}' -f $ts, $Level, $EventName, $Message)

    if (-not $LocalOnly) {
        Add-Content -Path $PendingLog -Value $row -Encoding UTF8
        Send-PendingLog
    }
}

# ---- AD-Hilfsfunktionen -------------------------------------------------------
function ConvertTo-LdapEscaped {
    param([string]$Value)
    $Value.Replace('\', '\5c').Replace('*', '\2a').Replace('(', '\28').Replace(')', '\29')
}

function Test-AdComputerExists {
    param([string]$Name)
    $n = ConvertTo-LdapEscaped $Name
    $searcher = [adsisearcher]"(&(objectCategory=computer)(|(sAMAccountName=$n`$)(name=$n)))"
    return [bool]$searcher.FindOne()
}

function Test-AdRenamePermission {
    <#
      Prüft über das konstruierte AD-Attribut allowedAttributesEffective, welche Attribute das
      ausführende Konto (SYSTEM = Computerkonto bzw. -DomainCredential) auf dem Computerobjekt
      SCHREIBEN darf. Die Auswertung der ACL übernimmt das AD selbst (inkl. SELF und Gruppen).
      Entscheidend für ein Rename sind cn und sAMAccountName. Die Validated Writes (DNS-Hostname,
      SPN) lassen sich so nicht zuverlässig prüfen; fehlen sie, meldet Rename-Computer den Fehler.
    #>
    param(
        [Parameter(Mandatory)][string]$ComputerName,
        [Parameter(Mandatory)][string]$DomainName,
        [pscredential]$Credential
    )
    $required = @('cn', 'sAMAccountName')
    $relevant = @('cn', 'name', 'sAMAccountName', 'displayName', 'dNSHostName', 'servicePrincipalName')

    $n      = ConvertTo-LdapEscaped $ComputerName
    $filter = "(&(objectCategory=computer)(sAMAccountName=$n`$))"
    if ($Credential) {
        $root     = New-Object System.DirectoryServices.DirectoryEntry("LDAP://$DomainName", $Credential.UserName, $Credential.GetNetworkCredential().Password)
        $searcher = New-Object System.DirectoryServices.DirectorySearcher($root, $filter)
    }
    else {
        $searcher = [adsisearcher]$filter
    }
    [void]$searcher.PropertiesToLoad.AddRange(@('distinguishedName', 'allowedAttributesEffective'))
    $res = $searcher.FindOne()

    if (-not $res) {
        return [pscustomobject]@{ Found = $false; Inconclusive = $false; Dn = $null; Writable = @(); Missing = $required }
    }

    $dn       = [string]$res.Properties['distinguishedname'][0]
    $writable = @($res.Properties['allowedattributeseffective'] | ForEach-Object { [string]$_ })
    $missing  = @($required | Where-Object { $writable -notcontains $_ })

    [pscustomobject]@{
        Found        = $true
        Inconclusive = ($writable.Count -eq 0)    # leer = Ergebnis nicht auswertbar
        Dn           = $dn
        Writable     = @($writable | Where-Object { $relevant -contains $_ })
        Missing      = $missing
    }
}

# ---- Bereinigung ----------------------------------------------------------------
function Test-LogPending {
    if (-not (Test-Path $PendingLog)) { return $false }
    return (@(Get-Content -Path $PendingLog -Encoding UTF8 | Where-Object { $_ }).Count -gt 0)
}

function Invoke-Cleanup {
    # Entfernt Scheduled Task, Skript, lokale Logdateien und den (leeren) Ordner.
    # Rückgabe: $true = bereinigt, $false = zurückgestellt/fehlgeschlagen.
    # Fehler hier dürfen das Ergebnis der Umbenennung nie beeinflussen.
    try {
        # 1) Erst alle Log-Einträge auf den Share bringen - danach gibt es keinen Task mehr, der sie nachliefern könnte
        Send-PendingLog
        if (Test-LogPending) {
            Write-RenameLog -Level WARN -EventName CLEANUP_DEFERRED -Message 'Log-Einträge sind noch nicht auf dem Share angekommen - Bereinigung wird beim nächsten Lauf nachgeholt.' -LocalOnly
            return $false
        }

        # 2) Beginn der Bereinigung zentral protokollieren und sicherstellen, dass der Eintrag angekommen ist
        Write-RenameLog -Level INFO -EventName CLEANUP -Message "Entferne Scheduled Task '$TaskName', Skript und lokale Logdateien."
        if (Test-LogPending) {
            Write-RenameLog -Level WARN -EventName CLEANUP_DEFERRED -Message 'Log-Einträge sind noch nicht auf dem Share angekommen - Bereinigung wird beim nächsten Lauf nachgeholt.' -LocalOnly
            return $false
        }

        # 3) Marker setzen: Die GPO legt Skript und Task bei vorhandenem Marker nicht erneut an
        New-Item -Path $MarkerKey -Force | Out-Null
        Set-ItemProperty -Path $MarkerKey -Name 'Completed'    -Value (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz')
        Set-ItemProperty -Path $MarkerKey -Name 'ComputerName' -Value ([string]$script:TargetName)

        # 4) Task zuerst entfernen (ein verwaister Task wäre schädlicher als eine verwaiste Datei)
        if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        }

        # 5) Skript entfernen
        $scriptDir = $null
        if ($PSCommandPath -and (Test-Path $PSCommandPath)) {
            $scriptDir = Split-Path -Path $PSCommandPath -Parent
            Remove-Item -Path $PSCommandPath -Force
        }
        Write-RenameLog -Level INFO -EventName CLEANUP_DONE -Message "Scheduled Task '$TaskName' und Skript wurden entfernt."

        # 6) Lokale Logdateien und leere Ordner entfernen - aber nur, wenn alles (auch CLEANUP_DONE) auf dem Share angekommen ist.
        #    Sonst bleiben die lokalen Logs als Nachweis erhalten.
        if (-not (Test-LogPending)) {
            Remove-Item -Path $LocalLog, $PendingLog -Force -ErrorAction SilentlyContinue
            foreach ($dir in @($scriptDir, $LocalDir) | Where-Object { $_ } | Select-Object -Unique) {
                if ((Test-Path $dir) -and -not (Get-ChildItem -Path $dir -Force -ErrorAction SilentlyContinue)) {
                    Remove-Item -Path $dir -Force -ErrorAction SilentlyContinue
                }
            }
        }
        return $true
    }
    catch {
        Write-RenameLog -Level WARN -EventName CLEANUP_FAILED -Message "Bereinigung fehlgeschlagen: $($_.Exception.Message)"
        return $false
    }
}

# ---- Zentrales Log prüfen ------------------------------------------------------------
function Test-CentralLog {
    # Prüft in drei Stufen, ob das zentrale Log erreichbar und für dieses Konto beschreibbar ist, ohne etwas zu schreiben:
    #   1) Namensauflösung des Servers  2) TCP-Port 445 (SMB)  3) Datei zum Anfügen öffnen (Share- und NTFS-Recht)
    # Liefert Ok, die Stufe des Scheiterns und eine Fehlermeldung. Das Ergebnis dient nur der Diagnose im lokalen Log.
    param([string]$Path = $CentralLogPath)
    $res = [pscustomobject]@{ Ok = $false; Stage = ''; Error = '' }

    if ($Path -match '^\\\\([^\\]+)\\') {
        $server = $Matches[1]
        try { $null = [System.Net.Dns]::GetHostAddresses($server) }
        catch { $res.Stage = 'Namensauflösung'; $res.Error = "Server '$server' ist nicht auflösbar ($($_.Exception.Message))"; return $res }

        $tcp = New-Object System.Net.Sockets.TcpClient
        try {
            $iar = $tcp.BeginConnect($server, 445, $null, $null)
            if (-not $iar.AsyncWaitHandle.WaitOne(3000, $false)) { $res.Stage = 'SMB-Port'; $res.Error = "Port 445 auf '$server' antwortet nicht (Timeout nach 3 s)"; return $res }
            $tcp.EndConnect($iar)
        }
        catch { $res.Stage = 'SMB-Port'; $res.Error = "Port 445 auf '$server' nicht erreichbar ($($_.Exception.Message))"; return $res }
        finally { $tcp.Close() }
    }

    try {
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
        $fs.Dispose()
        $res.Ok = $true
    }
    catch [System.UnauthorizedAccessException] {
        $res.Stage = 'Zugriff'; $res.Error = "Zugriff verweigert: Share- und NTFS-Recht Schreiben für Domänencomputer prüfen ($($_.Exception.Message))"
    }
    catch [System.IO.DirectoryNotFoundException] {
        $res.Stage = 'Pfad'; $res.Error = "Ordner oder Freigabe nicht gefunden ($($_.Exception.Message))"
    }
    catch {
        $res.Stage = 'Öffnen'; $res.Error = $_.Exception.Message
    }
    return $res
}

# ---- Secure Channel -------------------------------------------------------------
function Test-SecureChannel {
    # Test-ComputerSecureChannel gibt es in der Windows PowerShell 5.1 und in neueren PowerShell-7-Versionen;
    # sonst Fallback auf nltest (Exit-Code 0 = Secure Channel in Ordnung).
    param([string]$Domain)
    if (Get-Command Test-ComputerSecureChannel -ErrorAction SilentlyContinue) { return [bool](Test-ComputerSecureChannel) }
    $null = & nltest.exe "/sc_verify:$Domain" 2>&1
    return ($LASTEXITCODE -eq 0)
}

# ---- Namensvorlage ---------------------------------------------------------------
function Get-DeviceSerial {
    # Liefert die erste verwendbare Seriennummer (nur A-Z/0-9): BIOS, dann System-Produkt, dann Mainboard.
    # Verworfen werden zu kurze Werte (< 4 Zeichen), Hersteller-Platzhalter und Werte aus nur einem Zeichen.
    $placeholder = @('TOBEFILLEDBYOEM', 'DEFAULTSTRING', 'SYSTEMSERIALNUMBER', 'SERIALNUMBER', 'NONE', 'NA', 'UNKNOWN',
                     'NOTAVAILABLE', 'NOTSPECIFIED', 'OEM', 'OEMSTRING', '123456789', '1234567890', '0123456789')
    $sources = @(
        @{ Name = 'BIOS';                  Get = { (Get-CimInstance -ClassName Win32_BIOS).SerialNumber } },
        @{ Name = 'ComputerSystemProduct'; Get = { (Get-CimInstance -ClassName Win32_ComputerSystemProduct).IdentifyingNumber } },
        @{ Name = 'BaseBoard';             Get = { (Get-CimInstance -ClassName Win32_BaseBoard).SerialNumber } }
    )
    $rejected = @()
    foreach ($src in $sources) {
        $raw   = try { [string](& $src.Get) } catch { '' }
        $clean = ($raw -replace '[^A-Za-z0-9]', '').ToUpper()
        $valid = ($clean.Length -ge 4) -and ($placeholder -notcontains $clean) -and (@($clean.ToCharArray() | Select-Object -Unique).Count -gt 1)
        if ($valid) { return [pscustomobject]@{ Value = $clean; Source = $src.Name; Raw = $raw; Rejected = $rejected } }
        $rejected += ('{0}: "{1}"' -f $src.Name, $raw)
    }
    [pscustomobject]@{ Value = $null; Source = $null; Raw = ''; Rejected = $rejected }
}

function New-FutureId {
    # Kurze, stabile Zukunfts-ID aus einem Startwert (MachineGuid): gleiche Eingabe = gleiche ID, damit wiederholte
    # Läufe denselben Namen ergeben. Alphabet ohne mehrdeutige Zeichen (kein I, O, 0, 1). -Attempt erzeugt bei
    # einer Kollision eine andere ID. Reine Ziffern werden vermieden (Computernamen dürfen nicht nur aus Ziffern bestehen).
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Erzeugt nur eine Zeichenfolge, ändert keinen Systemzustand (wie New-Guid).')]
    param(
        [Parameter(Mandatory)][string]$Seed,
        [ValidateRange(4, 12)][int]$Length = 8,
        [int]$Attempt = 0
    )
    $alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'          # 32 Zeichen: 256 teilbar durch 32, daher gleichverteilt
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        for ($inner = 0; $inner -lt 20; $inner++) {
            $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes(('{0}|{1}|{2}' -f $Seed, $Attempt, $inner)))
            $id = -join (0..($Length - 1) | ForEach-Object { $alphabet[$bytes[$_] % 32] })
            if ($id -notmatch '^[0-9]+$') { return $id }
        }
        return $id
    }
    finally { $sha.Dispose() }
}

function Resolve-NameTemplate {
    # Bildet aus der Vorlage den Zielnamen. Platzhalter: {Name}, {Serial}, optional mit :N (erste N) bzw. :-N (letzte N).
    # Zu lange Namen: nur die Platzhalter-Werte werden gekürzt (letzter Platzhalter zuerst, mindestens 1 Zeichen bleibt).
    param(
        [Parameter(Mandatory)][string]$Template,
        [Parameter(Mandatory)][string]$CurrentName,
        [string]$Serial = '',
        [int]$MaxLength = 15,
        [string]$OnTooLong = 'TruncateEnd'
    )
    $res  = [pscustomobject]@{ Ok = $false; Name = ''; Full = ''; Truncated = $false; Code = ''; Error = '' }
    $segs = New-Object System.Collections.ArrayList
    $pos  = 0
    $rx   = [regex]::Matches($Template, '\{(?<tok>NAME|SERIAL)(?::(?<n>-?\d+))?\}', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    foreach ($m in $rx) {
        if ($m.Index -gt $pos) { [void]$segs.Add(@{ Kind = 'lit'; Text = $Template.Substring($pos, $m.Index - $pos) }) }
        $val = if ($m.Groups['tok'].Value -ieq 'NAME') { [string]$CurrentName } else { [string]$Serial }
        if ($m.Groups['n'].Success) {
            $n = [int]$m.Groups['n'].Value
            if ($n -ne 0 -and [math]::Abs($n) -lt $val.Length) {
                $val = if ($n -gt 0) { $val.Substring(0, $n) } else { $val.Substring($val.Length + $n) }
            }
        }
        [void]$segs.Add(@{ Kind = 'tok'; Text = $val })
        $pos = $m.Index + $m.Length
    }
    if ($pos -lt $Template.Length) { [void]$segs.Add(@{ Kind = 'lit'; Text = $Template.Substring($pos) }) }

    foreach ($sg in $segs) {
        if ($sg.Kind -eq 'lit' -and $sg.Text -match '[{}]') {
            $res.Code  = 'TEMPLATE'
            $res.Error = "Unbekannter Platzhalter in der Vorlage '$Template' (erlaubt: {Name}, {Serial}, jeweils mit :N bzw. :-N)."
            return $res
        }
        if ($sg.Kind -eq 'tok' -and [string]::IsNullOrEmpty($sg.Text)) {
            $res.Code  = 'TEMPLATE'
            $res.Error = "Ein Platzhalter der Vorlage '$Template' ergibt einen leeren Wert."
            return $res
        }
    }

    $join = { ($segs | ForEach-Object { $_.Text }) -join '' }
    $full = & $join
    $res.Full = $full.ToUpper()

    if ($full.Length -gt $MaxLength) {
        $res.Truncated = $true
        if ($OnTooLong -eq 'Skip') {
            $res.Code  = 'TOO_LONG'
            $res.Error = "Zielname '$($res.Full)' hat $($full.Length) Zeichen (max. $MaxLength). Übersprungen."
            return $res
        }
        for ($i = $segs.Count - 1; $i -ge 0; $i--) {
            $excess = (& $join).Length - $MaxLength
            if ($excess -le 0) { break }
            $sg = $segs[$i]
            if ($sg.Kind -ne 'tok') { continue }
            $cut = [math]::Min($excess, $sg.Text.Length - 1)
            if ($cut -le 0) { continue }
            $sg.Text = if ($OnTooLong -eq 'TruncateEnd') { $sg.Text.Substring(0, $sg.Text.Length - $cut) } else { $sg.Text.Substring($cut) }
            $trimmed = $sg.Text.Trim('-')                       # kein Bindestrich an den Schnittkanten
            if ($trimmed) { $sg.Text = $trimmed }
        }
        $full = & $join
        if ($full.Length -gt $MaxLength) {
            $res.Code  = 'TRUNCATE'
            $res.Error = "Zielname bleibt auch nach dem Kürzen zu lang ($($full.Length) Zeichen, max. $MaxLength). Vorlage '$Template' enthält zu viele feste Zeichen."
            return $res
        }
    }

    $name = $full.ToUpper()
    if ($name -notmatch '^[A-Z0-9_]([A-Z0-9_-]*[A-Z0-9_])?$' -or $name -match '^[0-9]+$') {
        $res.Code  = 'NAME_INVALID'
        $res.Error = "Zielname '$name' ist ungültig (erlaubt: A-Z, 0-9, _ und -; nicht mit - beginnen oder enden; nicht nur Ziffern)."
        return $res
    }
    $res.Ok   = $true
    $res.Name = $name
    $res
}

function Get-RenameState {
    if (Test-Path $StateKey) { Get-ItemProperty -Path $StateKey } else { $null }
}

function Set-RenameState {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Hilfsfunktion: Die Abfrage (ShouldProcess) erfolgt im Hauptablauf vor dem Umbenennen.')]
    param([string]$Original, [string]$Target, [string]$Template, [string]$FutureId = '')
    New-Item -Path $StateKey -Force | Out-Null
    Set-ItemProperty -Path $StateKey -Name 'FutureId'     -Value $FutureId
    Set-ItemProperty -Path $StateKey -Name 'OriginalName' -Value $Original
    Set-ItemProperty -Path $StateKey -Name 'TargetName'   -Value $Target
    Set-ItemProperty -Path $StateKey -Name 'Template'     -Value $Template
    Set-ItemProperty -Path $StateKey -Name 'Applied'      -Value (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz')
}

# ---- Hauptlogik ----------------------------------------------------------------
try {
    $active  = (Get-ItemProperty "$regCN\ActiveComputerName").ComputerName   # aktuell wirksam
    $pending = (Get-ItemProperty "$regCN\ComputerName").ComputerName         # nach Neustart wirksam
    $script:CurrentName = $active

    # 0) Namensvorlage bestimmen: -NameTemplate hat Vorrang, sonst "Prefix{Name}Suffix"
    $Template = if ($NameTemplate) { $NameTemplate } elseif ($Prefix -or $Suffix) { '{0}{{Name}}{1}' -f $Prefix, $Suffix } else { '' }
    if (-not $Template) {
        Write-RenameLog -Level ERROR -EventName CONFIG -Message 'Weder -NameTemplate noch -Prefix/-Suffix angegeben - nichts zu tun.'
        exit 1
    }
    $Template   = $Template.ToUpper()
    $usesName   = $Template -match '\{NAME(:-?\d+)?\}'
    $usesSerial = $Template -match '\{SERIAL(:-?\d+)?\}'
    $serialInfo = if ($usesSerial) { Get-DeviceSerial } else { $null }
    $state      = Get-RenameState

    # 1) Bereits erledigt oder Umbenennung ausstehend? (keine DC-Verbindung nötig)
    $done = $false
    if ($state -and ($state.Template -ieq $Template) -and $state.TargetName -and ($pending -ieq $state.TargetName)) {
        $done = $true                                           # mit genau dieser Vorlage von HostRename gesetzter Zielname
    }
    elseif (-not $usesSerial -and $Template -match '^(?<pre>[A-Z0-9_-]*)\{NAME\}(?<suf>[A-Z0-9_-]*)$') {
        # Prefix-/Suffix-Modus: bereits umbenannte Geräte erkennt man am Muster
        $pre = $Matches['pre']; $suf = $Matches['suf']
        if ($pre -or $suf) {
            $done = (-not $pre -or $pending.StartsWith($pre, [StringComparison]::OrdinalIgnoreCase)) -and
                    (-not $suf -or $pending.EndsWith($suf, [StringComparison]::OrdinalIgnoreCase))
        }
    }
    elseif (-not $usesName -and $serialInfo -and $serialInfo.Value) {
        # Vorlage ohne {Name} (z. B. DE{Serial}): der Zielname ist vom alten Namen unabhängig
        $probe = Resolve-NameTemplate -Template $Template -CurrentName $active -Serial $serialInfo.Value -MaxLength $MaxLen -OnTooLong $OnTooLong
        $done  = $probe.Ok -and ($pending -ieq $probe.Name)
    }

    if ($done) {
        $script:TargetName = $pending
        if ($active -ne $pending) {
            Write-RenameLog -Level WARN -EventName PENDING_REBOOT -Message "Umbenennung auf '$pending' ist bereits ausstehend - Neustart erforderlich."
            if ($Cleanup) { [void](Invoke-Cleanup) }
            exit 3010
        }
        # Nur lokal protokollieren, damit der zentrale Log nicht bei jedem Start zugemüllt wird
        Write-RenameLog -Level INFO -EventName ALREADY_DONE -Message "Hostname entspricht bereits der Vorlage '$Template' - nichts zu tun." -LocalOnly
        if ($Cleanup) { [void](Invoke-Cleanup) }
        exit 0
    }

    Write-RenameLog -Level INFO -EventName START -Message "HostRename ${ScriptVersion}: Vorlage '$Template', Modus bei zu langem Namen: $OnTooLong"

    # 1a) Zentrales Log prüfen. Nur Diagnose: Das Umbenennen läuft auch ohne zentrales Log, die Einträge werden dann nachgeliefert
    #     und die Bereinigung wartet. Das Ergebnis steht nur im lokalen Log, weil das zentrale ja nicht nutzbar sein könnte.
    $logCheck = Test-CentralLog
    if ($logCheck.Ok) { Write-RenameLog -Level INFO -EventName LOG_CHECK -Message "Zentrales Log '$CentralLogPath' ist erreichbar und beschreibbar." -LocalOnly }
    else              { Write-RenameLog -Level WARN -EventName LOG_CHECK -Message "Zentrales Log '$CentralLogPath' nicht nutzbar (Stufe: $($logCheck.Stage)): $($logCheck.Error). Einträge bleiben in pending.csv und werden nachgeliefert." -LocalOnly }

    if ($active -ne $pending) {
        Write-RenameLog -Level ERROR -EventName PRECHECK -Message "Eine andere Umbenennung ('$pending') ist ausstehend. Bitte erst neu starten."
        exit 1
    }

    # 1b) Seriennummer prüfen (nur wenn die Vorlage sie verwendet); bei Problemen ggf. Zukunfts-ID verwenden
    $serialValue = ''
    $idUsed      = $false
    $futureId    = ''
    # Startwert der ID: muss über Umbenennungen hinweg stabil sein (MachineGuid, sonst BIOS-UUID) - nie der Computername
    $idSeed      = $script:MachineGuid
    if ($usesSerial -and -not $idSeed) { $idSeed = try { [string](Get-CimInstance -ClassName Win32_ComputerSystemProduct).UUID } catch { '' } }
    if ($usesSerial) {
        if ($serialInfo.Value) {
            $serialValue = $serialInfo.Value
            Write-RenameLog -Level INFO -EventName SERIAL -Message "Seriennummer '$serialValue' (Quelle: $($serialInfo.Source))."
        }
        elseif ($OnSerialProblem -eq 'GenerateId' -and -not $idSeed) {
            Write-RenameLog -Level ERROR -EventName SERIAL_INVALID -Message "Keine verwendbare Seriennummer ($($serialInfo.Rejected -join '; ')) und keine MachineGuid/UUID für eine stabile ID. Übersprungen."
            exit 5
        }
        elseif ($OnSerialProblem -eq 'GenerateId') {
            $futureId    = New-FutureId -Seed $idSeed -Length $FutureIdLength -Attempt 0
            $serialValue = $futureId
            $idUsed      = $true
            Write-RenameLog -Level WARN -EventName SERIAL_FALLBACK -Message "Keine verwendbare Seriennummer ($($serialInfo.Rejected -join '; ')) - verwende generierte ID '$futureId' (aus der MachineGuid)."
        }
        else {
            Write-RenameLog -Level ERROR -EventName SERIAL_INVALID -Message "Keine verwendbare Seriennummer gefunden ($($serialInfo.Rejected -join '; ')). Übersprungen."
            exit 5
        }
    }

    # 2) Domäne und Secure Channel prüfen
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem
    if (-not $cs.PartOfDomain) {
        Write-RenameLog -Level ERROR -EventName PRECHECK -Message 'Gerät ist nicht Mitglied einer Domäne.'
        exit 1
    }
    if (-not (Test-SecureChannel -Domain $cs.Domain)) {
        Write-RenameLog -Level ERROR -EventName PRECHECK -Message "Secure Channel zur Domäne '$($cs.Domain)' ist nicht intakt bzw. DC nicht erreichbar."
        exit 1
    }

    # 2b) Berechtigung zum Umbenennen auf dem eigenen AD-Objekt prüfen (bevor irgendetwas geändert wird)
    $perm = Test-AdRenamePermission -ComputerName $active -DomainName $cs.Domain -Credential $DomainCredential
    $permContext = if ($DomainCredential) { $DomainCredential.UserName } else { 'Computerkonto (SELF)' }
    if (-not $perm.Found) {
        Write-RenameLog -Level ERROR -EventName PERM_CHECK -Message "Computerobjekt '$active`$' wurde im AD nicht gefunden - Berechtigungsprüfung nicht möglich."
        exit 1
    }
    elseif ($perm.Inconclusive) {
        Write-RenameLog -Level WARN -EventName PERM_CHECK -Message "Schreibrechte auf '$($perm.Dn)' konnten nicht ermittelt werden (Kontext: $permContext). Fahre fort; ein Fehler wird beim Umbenennen geloggt."
    }
    elseif ($perm.Missing.Count -gt 0) {
        Write-RenameLog -Level ERROR -EventName PERM_DENIED -Message "Keine Schreibrechte auf: $($perm.Missing -join ', ') am Objekt '$($perm.Dn)' (Kontext: $permContext). Delegation prüfen (Prepare-HostRename.ps1 -Action Setup -Component Delegation) oder -DomainCredential verwenden."
        exit 4
    }
    else {
        Write-RenameLog -Level INFO -EventName PERM_CHECK -Message "Berechtigung zum Umbenennen vorhanden auf '$($perm.Dn)' (Kontext: $permContext; schreibbar: $($perm.Writable -join ', '))."
    }

    # 3) Zielnamen aus der Vorlage bilden, ggf. kürzen
    $plan = Resolve-NameTemplate -Template $Template -CurrentName $active -Serial $serialValue -MaxLength $MaxLen -OnTooLong $OnTooLong
    if (-not $plan.Ok) {
        $script:TargetName = $plan.Full
        Write-RenameLog -Level ERROR -EventName $plan.Code -Message $plan.Error
        if ($plan.Code -eq 'TOO_LONG') { exit 2 } else { exit 1 }
    }
    $newName = $plan.Name
    $script:TargetName = $newName
    if ($plan.Truncated) {
        Write-RenameLog -Level WARN -EventName TRUNCATE -Message "Vorlage '$Template' ergab '$($plan.Full)' ($($plan.Full.Length) Zeichen), gekürzt auf '$newName' (Modus: $OnTooLong)."
    }
    if ($newName -ieq $active) {
        Write-RenameLog -Level INFO -EventName ALREADY_DONE -Message "Hostname '$active' entspricht bereits dem Ergebnis der Vorlage - nichts zu tun." -LocalOnly
        if ($Cleanup) { [void](Invoke-Cleanup) }
        exit 0
    }

    # 4) Kollisionsprüfung im AD (gilt auch für gekürzte Namen). Bei doppelter Seriennummer bzw. kollidierender ID
    #    wird eine (weitere) Zukunfts-ID verwendet: stabil aus der MachineGuid, bei Kollision mit dem nächsten Zähler.
    $idAttempt = if ($idUsed) { 0 } else { -1 }
    while (Test-AdComputerExists $newName) {
        if (-not $usesSerial -or $OnSerialProblem -ne 'GenerateId' -or -not $idSeed -or $idAttempt -ge 4) {
            Write-RenameLog -Level ERROR -EventName COLLISION -Message "Computerobjekt '$newName' existiert bereits im AD. Abbruch."
            exit 1
        }
        $idAttempt++
        $oldName  = $newName
        $futureId = New-FutureId -Seed $idSeed -Length $FutureIdLength -Attempt $idAttempt
        $plan     = Resolve-NameTemplate -Template $Template -CurrentName $active -Serial $futureId -MaxLength $MaxLen -OnTooLong $OnTooLong
        if (-not $plan.Ok) {
            Write-RenameLog -Level ERROR -EventName $plan.Code -Message $plan.Error
            exit 1
        }
        $newName           = $plan.Name
        $script:TargetName = $newName
        $idUsed            = $true
        Write-RenameLog -Level WARN -EventName SERIAL_FALLBACK -Message "Zielname '$oldName' existiert bereits im AD (doppelte Seriennummer?) - verwende generierte ID '$futureId' -> '$newName' (Versuch $($idAttempt + 1))."
        if ($newName -ieq $active) {
            Write-RenameLog -Level INFO -EventName ALREADY_DONE -Message "Hostname '$active' entspricht bereits dem Ergebnis der Vorlage (generierte ID) - nichts zu tun." -LocalOnly
            if ($Cleanup) { [void](Invoke-Cleanup) }
            exit 0
        }
    }

    # 5) DNS-Prüfung (nur Warnung, da veraltete Einträge häufig sind)
    try {
        $ips = [System.Net.Dns]::GetHostAddresses("$newName.$($cs.Domain)") | ForEach-Object { $_.IPAddressToString }
        Write-RenameLog -Level WARN -EventName DNS_EXISTS -Message "Zielname '$newName' löst im DNS bereits auf: $($ips -join ', ') (evtl. veralteter Eintrag)."
    }
    catch { Write-Verbose "Kein DNS-Eintrag für '$newName.$($cs.Domain)' (das ist der erwartete Fall): $($_.Exception.Message)" }

    # 6) Umbenennen (lokal + AD-Objekt)
    if ($PSCmdlet.ShouldProcess($active, "Umbenennen in '$newName'")) {
        $rp = @{ NewName = $newName; Force = $true; ErrorAction = 'Stop' }
        if ($DomainCredential) { $rp.DomainCredential = $DomainCredential }
        Rename-Computer @rp
        Write-RenameLog -Level INFO -EventName RENAMED -Message "Erfolgreich umbenannt: '$active' -> '$newName' (lokal wirksam nach Neustart)."
        try   { Set-RenameState -Original $active -Target $newName -Template $Template -FutureId $(if ($idUsed) { $futureId } else { '' }) }
        catch { Write-RenameLog -Level WARN -EventName STATE -Message "Zustand konnte nicht gespeichert werden: $($_.Exception.Message)" }

        # 7) Nachprüfung im AD
        try {
            $newOk = Test-AdComputerExists $newName
            $oldOk = Test-AdComputerExists $active
            if ($newOk -and -not $oldOk) { Write-RenameLog -Level INFO -EventName AD_VERIFY -Message "AD-Objekt '$newName' vorhanden, '$active' nicht mehr." }
            else { Write-RenameLog -Level WARN -EventName AD_VERIFY -Message "AD-Prüfung uneindeutig (neu vorhanden: $newOk, alt noch vorhanden: $oldOk). Ggf. Replikation abwarten." }
        }
        catch { Write-RenameLog -Level WARN -EventName AD_VERIFY -Message "AD-Nachprüfung nicht möglich: $($_.Exception.Message)" }

        if ($Reboot) {
            $msg = "Der Computername wird geändert. Das Gerät startet in $([math]::Round($RebootDelaySeconds / 60)) Minuten neu. Bitte Arbeit speichern."
            & shutdown.exe /r /t $RebootDelaySeconds /c $msg /d p:4:1
            Write-RenameLog -Level INFO -EventName REBOOT -Message "Neustart in $RebootDelaySeconds Sekunden geplant."
        }
        if ($Cleanup) { [void](Invoke-Cleanup) }
        exit 3010
    }
    else {
        Write-RenameLog -Level INFO -EventName WHATIF -Message "'$active' würde in '$newName' umbenannt (kein Eingriff)."
        exit 0
    }
}
catch {
    $m = $_.Exception.Message
    if ($m -match 'denied|verweigert') {
        $m += ' | Hinweis: AD-Rechte prüfen (Delegation für SELF auf der OU, einschließlich "Reset password", oder -DomainCredential). Details: C:\Windows\debug\NetSetup.LOG'
    }
    Write-RenameLog -Level ERROR -EventName RENAME_FAILED -Message $m
    exit 1
}
finally {
    Send-PendingLog   # ggf. noch offene Einträge nachliefern
}
