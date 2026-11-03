<#
.SYNOPSIS
    HostRename - Preparation: legt Share, AD-Delegation und GPO an bzw. entfernt sie wieder.

.DESCRIPTION
    Eine Stelle für die gesamte Serverseite von HostRename. Alle Pfade und Namen stehen als Variablen im
    Block "HIER ANPASSEN" am Anfang des Skripts.

    KOMPONENTEN (-Component, Standard: alle drei)
      Share        Ordner und NTFS-Rechte, Freigabe, rename-log.csv mit Kopfzeile, Kopie von Invoke-HostRename.ps1
                   Ausführung: Fileserver bzw. DC, lokaler Administrator, erhöhte PowerShell
      Delegation   SELF darf Computerobjekte unter den Client-OUs ($ClientOuDN, einzelne per -OuDN) umbenennen:
                   Schreiben cn, name, sAMAccountName, displayName und Account Restrictions, Reset password sowie
                   die Validated Writes für DNS-Hostname und SPN (nur Computerobjekte, nur untergeordnet)
                   Ausführung: DC oder Admin-PC mit RSAT, Domänen-Admin
      Gpo          GPO mit Dateikopie (GPP Files, Aktion Replace) und Scheduled Task (GPP) mit den Triggern
                   Registrierung (Start sofort nach dem Anlegen) und Systemstart (5 Minuten Verzögerung), optional täglich mit Wiederholung; Item-Level-Targeting auf den Registry-Marker;
                   der Link wird zunächst nicht oder deaktiviert angelegt
                   Ausführung: DC oder Admin-PC mit RSAT, Domänen-Admin

    AKTIONEN (-Action)
      Setup        Prüft zuerst die Umbenennungsregel ($NameTemplate bzw. $Prefix und $Suffix) und zeigt
                   Beispielnamen, legt dann an (Reihenfolge: Share, Delegation, Gpo) und schreibt
                   HostRename.Checks.psd1 für die Tests.
      Remove       Entfernt in der Reihenfolge Gpo, Delegation, Share:
                     Gpo          Links in der Domäne, danach die GPO
                     Delegation   die ACEs von SELF (vorher ACL-Backup im Ordner AclBackup)
                     Share        die Freigabe; Ordner und Logs bleiben, außer mit -RemoveData
                                  (die Logdatei wird vorher nach $LogArchiveDir kopiert)

      CleanupGpo   Optional, erst am Ende: Bereinigungs-GPO, die auf den Clients die Registry-Schlüssel von HostRename
                   ($CleanupRegistryKeys) löscht. Wird nicht zusammen mit Gpo angelegt und nur, wenn die Haupt-GPO
                   nicht mehr existiert. Gehört nicht zum Standard von -Component.
                   Ausführung: DC oder Admin-PC mit RSAT, Domänen-Admin

    -WhatIf zeigt nur, was das Skript tun würde. Remove fragt vor dem Löschen nach (außer mit -Force).
    Fehlt eine OU im AD, fragt die Delegation interaktiv nach einer anderen OU (leere Eingabe = Abbruch).
    Unter PowerShell 7 startet sich das Skript selbst in der Windows PowerShell 5.1 neu, weil AD- und
    GPO-Module sowie das AD:-Laufwerk nur dort zuverlässig verfügbar sind.

.PARAMETER Action
    Setup oder Remove.

.PARAMETER Component
    Share, Delegation, Gpo und CleanupGpo, einzeln oder kombiniert (Standard: Share, Delegation, Gpo). Share
    arbeitet lokal und läuft auf dem Fileserver; Delegation, Gpo und CleanupGpo laufen auf einem Admin-PC mit
    RSAT oder einem DC. Beispiel für getrennte Maschinen: auf dem Fileserver nur Share, danach auf dem Admin-PC
    Delegation und Gpo.

.PARAMETER OuDN
    Nur Delegation: Distinguished Name(s) einzelner OUs, auf die die Delegation gesetzt bzw. entfernt wird.
    Ohne Angabe gelten alle OUs aus $ClientOuDN. So lassen sich einzelne OUs nachträglich hinzufügen oder
    zurücknehmen, auch OUs, die nicht in $ClientOuDN stehen.

.PARAMETER RemoveData
    Nur bei Remove und Share: löscht zusätzlich $ShareRoot (die Logdatei wird vorher nach $LogArchiveDir
    kopiert).

.PARAMETER Force
    Keine Rückfragen: weder die Sicherheitsabfrage bei Remove noch die Rückfrage bei einer fehlenden OU.

.EXAMPLE
    .\Prepare-HostRename.ps1 -Action Setup -WhatIf

    Trockenlauf: prüft die Umbenennungsregel und zeigt, was angelegt würde.

.EXAMPLE
    .\Prepare-HostRename.ps1 -Action Setup

    Legt Share, Delegation und GPO an.

.EXAMPLE
    .\Prepare-HostRename.ps1 -Action Setup -Component Share

    Nur der Share (z. B. auf einem separaten Fileserver).

.EXAMPLE
    .\Prepare-HostRename.ps1 -Action Setup -Component Delegation -OuDN 'OU=Notebooks,DC=contoso,DC=com'

    Setzt die Delegation zusätzlich auf einer einzelnen OU.

.EXAMPLE
    .\Prepare-HostRename.ps1 -Action Setup -Component Delegation, Gpo

    Auf dem Admin-PC bzw. DC, wenn der Share auf einem Fileserver liegt und dort mit -Component Share
    angelegt wurde. $ShareServer muss auf den Fileserver zeigen.

.EXAMPLE
    .\Prepare-HostRename.ps1 -Action Setup -Component CleanupGpo

    Ganz am Ende, nach Abschluss aller Umbenennungen und nach dem Entfernen der Haupt-GPO: legt die
    Bereinigungs-GPO an, die die Registry-Schlüssel auf den Clients löscht.

.EXAMPLE
    .\Prepare-HostRename.ps1 -Action Remove

    Entfernt GPO, Delegation und Freigabe; Ordner und Logs bleiben.

.EXAMPLE
    .\Prepare-HostRename.ps1 -Action Remove -RemoveData -Force

    Entfernt alles ohne Rückfrage, auch die Ordner (die Logdatei wird vorher archiviert).

.NOTES
    Produkt          HostRename
    Version          1.1.9
    Stand            2026-10-30
    Ausführung       Erhöhte Windows PowerShell 5.1 auf dem DC bzw. Fileserver als Domänen-Admin und lokaler Administrator
    Kodierung        UTF-8 mit BOM (für die Windows PowerShell 5.1 erforderlich)

.LINK
    README.md
#>
#Requires -Version 5.1

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Setup', 'Remove')]
    [string]$Action,

    [ValidateSet('Share', 'Delegation', 'Gpo', 'CleanupGpo')]
    [string[]]$Component = @('Share', 'Delegation', 'Gpo'),

    [string[]]$OuDN = @(),

    [switch]$RemoveData,

    [switch]$Force
)

# AD-/GPO-Module, das AD:-Laufwerk und lebende GPO-Objekte gibt es nur in der Windows PowerShell 5.1.
# Unter PowerShell 7 startet sich das Skript deshalb selbst in der 5.1 neu (mit denselben Parametern).
if ($PSVersionTable.PSEdition -eq 'Core' -and $env:OS -eq 'Windows_NT') {
    $ps51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $relaunch = "& '{0}' -Action {1} -Component {2}" -f $PSCommandPath.Replace("'", "''"), $Action, ($Component -join ',')
    if ($OuDN)             { $relaunch += ' -OuDN ' + (($OuDN | ForEach-Object { "'" + $_.Replace("'", "''") + "'" }) -join ',') }
    if ($RemoveData)       { $relaunch += ' -RemoveData' }
    if ($Force)            { $relaunch += ' -Force' }
    if ($WhatIfPreference) { $relaunch += ' -WhatIf' }
    Write-Host 'PowerShell 7 erkannt - starte Prepare-HostRename.ps1 in der Windows PowerShell 5.1 neu ...' -ForegroundColor DarkGray
    & $ps51 -NoProfile -ExecutionPolicy Bypass -Command "$relaunch; exit `$LASTEXITCODE"
    exit $LASTEXITCODE
}

# =====================  HIER ANPASSEN  =====================

# --- Share (wird auf dem Rechner angelegt, auf dem -Component Share läuft) -------------------------
$ShareServer         = $env:COMPUTERNAME                      # Servername in den UNC-Pfaden der GPO (bei separatem Fileserver dessen Name)
$ShareRoot           = 'C:\HostRename'                        # Wurzelordner auf dem Server
$ShareName           = 'HostRename$'                          # Name der (versteckten) Freigabe
# Share-Berechtigungen; die NTFS-Rechte begrenzen in jedem Fall zusätzlich je Ordner:
#   Restricted = Administratoren Vollzugriff, Domänencomputer Ändern
#   Everyone   = Jeder Vollzugriff; die Rechte regelt allein NTFS (klassischer Ansatz)
$ShareAccessMode     = 'Restricted'
$ScriptsFolderName   = 'scripts'                              # Unterordner mit dem Client-Skript (Domänencomputer: lesen)
$LogFolderName       = 'log'                                  # Unterordner mit dem zentralen Log (Domänencomputer: nur anfügen)
$LogFileName         = 'rename-log.csv'                       # zentrale Logdatei
$LogArchiveDir       = 'C:\HostRename-LogArchive'             # Remove -RemoveData: hierhin wird die Logdatei vorher kopiert

# --- Client-Skript -----------------------------------------------------------------------------------
$ScriptName          = 'Invoke-HostRename.ps1'                # muss neben diesem Skript liegen (wird in $ScriptsFolderName kopiert)
$LocalFolder         = 'C:\Program Files\HostRename'          # Zielordner auf dem Client; Standardbenutzer dürfen unter Program Files nichts ändern
# Ordner-ACL vor jedem Lauf per icacls sperren: nur nötig, wenn $LocalFolder in einem für Benutzer
# beschreibbaren Bereich liegt (z. B. C:\ProgramData); unter Program Files nicht erforderlich.
$HardenLocalFolder   = $false

# --- AD-Delegation -----------------------------------------------------------------------------------
# OUs (oder Container) mit den umzubenennenden Computerobjekten; mehrere möglich.
$ClientOuDN          = @(
    'OU=Clients,DC=contoso,DC=com'
    # 'OU=Notebooks,DC=contoso,DC=com'
)
$AclBackupDir        = if ($PSScriptRoot) { Join-Path $PSScriptRoot 'AclBackup' } else { Join-Path $env:TEMP 'AclBackup' }

# --- GPO ---------------------------------------------------------------------------------------------
$GpoName             = 'COMP - HostRename'
$LinkTargetOU        = ''                                     # leer = nicht verknüpfen; sonst DN der OU (der Link wird DEAKTIVIERT angelegt)
$SecurityFilterGroup = ''                                     # z. B. 'GG-HostRename-Pilot' (Gruppe mit Computerkonten); leer = alle

# --- Bereinigungs-GPO (optional, erst nach Abschluss aller Umbenennungen) ----------------------------
# Löscht die Registry-Schlüssel von HostRename auf den Clients. Verknüpfung und Sicherheitsfilter wie bei der Haupt-GPO.
$CleanupGpoName      = 'COMP - HostRename Cleanup'
# HKLM-Schlüssel, die die Bereinigungs-GPO löscht (Marker und Zustand). Nur 'SOFTWARE\HostRename' stehen lassen,
# wenn der Zustand erhalten bleiben soll.
$CleanupRegistryKeys = @(
    'SOFTWARE\HostRename'
    'SOFTWARE\HostRenameState'
)

# --- Umbenennungsregel (wird dem Task übergeben) -----------------------------------------------------
# Entweder $NameTemplate ODER $Prefix/$Suffix verwenden; die Vorlage hat Vorrang.
#   Platzhalter  {Name} = bisheriger Hostname, {Serial} = Seriennummer (BIOS u. a.; nur A-Z/0-9)
#   mit Länge    {Serial:8} = erste 8 Zeichen, {Serial:-8} = letzte 8 Zeichen (ebenso {Name:4}, {Name:-4})
#   Beispiele    'DE{Serial}'          PC349219 -> DE<Seriennummer>
#                'NG-{Name}'           PC349219 -> NG-PC349219   (entspricht $Prefix = 'NG-')
#                'DE-{Serial:-8}'      DE- plus die letzten 8 Zeichen der Seriennummer
#                '{Serial}-{Name:-4}'  Seriennummer, Bindestrich, letzte 4 Zeichen des alten Namens
$NameTemplate        = ''
$Prefix              = 'NG-'                                  # nur ohne $NameTemplate: Prefix vor dem bisherigen Namen
$Suffix              = ''                                     # nur ohne $NameTemplate: Suffix hinter dem bisherigen Namen
# Nur für Vorlagen mit {Serial}: Ist die Seriennummer nicht verwendbar oder der Zielname im AD schon vergeben,
# ersetzt eine generierte Zukunfts-ID (stabil aus der MachineGuid) die Seriennummer.
$OnSerialProblem     = 'GenerateId'                           # GenerateId | Skip (Gerät überspringen, Exit-Code 5 bzw. COLLISION)
$FutureIdLength      = 8                                      # Länge der Zukunfts-ID, 4 bis 12 (Zeichen A-Z ohne I/O und 2-9)
$OnTooLong           = 'TruncateEnd'                          # TruncateEnd | TruncateStart | Skip (bei mehr als 15 Zeichen)
$Reboot              = $false                                 # $true = Neustart nach der Umbenennung (mit Vorwarnzeit)
$RebootDelaySeconds  = 900                                    # Vorwarnzeit für den Neustart in Sekunden
$CleanupAfterSuccess = $true                                  # Task, Skript und lokale Logs nach der Umbenennung vom Client entfernen
$MarkerRegistryKey   = 'SOFTWARE\HostRename'                  # HKLM-Marker; muss zu $MarkerKey in Invoke-HostRename.ps1 passen

# --- Scheduled Task ----------------------------------------------------------------------------------
$TaskName            = 'HostRename'
$TaskRunAs           = 'SYSTEM'                               # Konto des Tasks, sprachunabhängig ("NT AUTHORITY\System" scheitert auf deutschen Clients)
$TaskUserId          = 'S-1-5-18'                             # dasselbe Konto als SID im Task-XML
$BootDelay           = 'PT5M'                                 # Verzögerung nach dem Systemstart (ISO 8601); der Task startet einmal je Neustart
# Registrierungs-Trigger ("Bei Erstellung/Änderung der Aufgabe"): Der Task startet sofort, wenn die GPO ihn anlegt. Er wird bewusst OHNE
# Verzögerung angelegt: Mit dem Element <Delay> scheitert der GPMC-Bericht der GPO (belegt mit Test-GpoReport.ps1 -Candidates), ohne
# Verzögerung wird er angezeigt. Mit der Aktion Create feuert er einmal beim Anlegen, mit Update bei jeder Verarbeitung der GPO.
$RegistrationTrigger = $true
# Zusätzlicher täglicher Trigger (Uhrzeit, z. B. '12:00') für Geräte, die tagelang laufen, ohne neu zu starten. Leer = nur Systemstart.
$DailyTriggerTime    = ''
# Wiederholung des täglichen Triggers über 24 Stunden (ISO 8601, z. B. 'PT1H'). Sie wirkt nur zusammen mit einem täglichen Trigger
# (bei leerem $DailyTriggerTime beginnt sie um 00:00) und startet einen erst nach dem Hochfahren angelegten Task spätestens nach diesem
# Intervall. Leer = ohne Wiederholung.
$RepeatInterval      = ''
# GPP-Aktion für den Task:
#   C = Create   [Standard] nur anlegen, wenn er fehlt. Der Task bleibt über den Neustart unverändert, sodass der Trigger "Systemstart"
#                feuern kann. Änderungen an der Task-Definition (Regel, Neustart-Schalter, Pfade) erreichen vorhandene Tasks NICHT: dann den
#                Task auf den noch nicht fertigen Geräten einmal löschen. Das Skript selbst wird weiter bei jeder Verarbeitung ersetzt.
#   U = Update   Änderungen erreichen vorhandene Tasks. Beobachtet: Der Task startete nach einem Neustart nicht, weil die GPO ihn beim
#                Hochfahren neu schreibt (vermutlich nach dem Systemstart-Trigger). Mit $RepeatInterval ausgleichbar.
#   R = Replace  löschen und neu anlegen (bei den Triggern wie Update)
$TaskItemAction      = 'C'

# --- Konfiguration für die Pester-Tests --------------------------------------------------------------
$WriteChecksConfig   = $true                                  # Setup schreibt HostRename.Checks.psd1 aus den Werten dieses Blocks
$ChecksConfigPath    = if ($PSScriptRoot) { Join-Path $PSScriptRoot 'HostRename.Checks.psd1' } else { Join-Path $env:TEMP 'HostRename.Checks.psd1' }
# ===========================================================

# Abgeleitete Pfade (nicht ändern)
$DelegationOus     = @(if ($OuDN) { $OuDN } else { $ClientOuDN })     # -OuDN hat Vorrang vor $ClientOuDN
$ShareUnc          = '\\' + $ShareServer + '\' + $ShareName
$SourceShareFolder = $ShareUnc + '\' + $ScriptsFolderName
$CentralLogPath    = $ShareUnc + '\' + $LogFolderName + '\' + $LogFileName

$ErrorActionPreference = 'Stop'

# ---- Hilfsfunktionen --------------------------------------------------------------------------------
function Write-Step([string]$Text) { Write-Host "`n== $Text" -ForegroundColor Cyan }
function Write-Ok([string]$Text)   { Write-Host "   $Text" -ForegroundColor Green }
function Write-Info([string]$Text) { Write-Host "   $Text" -ForegroundColor DarkGray }

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function ConvertTo-XmlText([string]$Text) { [System.Security.SecurityElement]::Escape($Text) }
function New-GppUid {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Erzeugt nur eine GUID-Zeichenfolge, ändert keinen Systemzustand.')]
    param()
    '{' + [guid]::NewGuid().ToString().ToUpper() + '}'
}
function Write-Utf8File {
    param([string]$Path, [string]$Content)
    $dir = Split-Path $Path -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
}
function ConvertTo-PsLiteral([string]$Text) { "'" + $Text.Replace("'", "''") + "'" }

function ConvertTo-SidString {
    # Prinzipale immer über die SID vergleichen: Namen wie "NT AUTHORITY\SELF" sind je nach Systemsprache
    # unterschiedlich (deutsch: "NT-AUTORITÄT\SELF").
    param($Identity)
    if ($Identity -is [System.Security.Principal.SecurityIdentifier]) { return $Identity.Value }
    try { return $Identity.Translate([System.Security.Principal.SecurityIdentifier]).Value } catch { return '' }
}

function Get-DomainSidValue {
    # SID der Domäne, in der dieser Rechner Mitglied ist (ohne AD-Modul)
    $domainName = (Get-CimInstance Win32_ComputerSystem).Domain
    (New-Object Security.Principal.SecurityIdentifier(([ADSI]"LDAP://$domainName").objectSid[0], 0)).Value
}

function Initialize-AdContext {
    Import-Module ActiveDirectory -ErrorAction Stop
    $script:domain  = Get-ADDomain
    $script:pdc     = $script:domain.PDCEmulator     # alle Schreibzugriffe gegen dieselbe DC (vermeidet Replikationsprobleme)
    $script:dnsRoot = $script:domain.DNSRoot
    Write-Info "Domäne: $($script:dnsRoot) | PDC-Emulator: $($script:pdc)"
}

# ===========================================================================================
#  SHARE
# ===========================================================================================
function Invoke-ShareSetup {
    Write-Step "Share: $ShareUnc  ($ShareRoot)"

    $domainComputersSid  = (Get-DomainSidValue) + '-515'
    $domainComputersName = (New-Object Security.Principal.SecurityIdentifier $domainComputersSid).Translate([Security.Principal.NTAccount]).Value
    $adminsName          = (New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-544').Translate([Security.Principal.NTAccount]).Value
    $everyoneName        = (New-Object Security.Principal.SecurityIdentifier 'S-1-1-0').Translate([Security.Principal.NTAccount]).Value

    $scriptsDir = Join-Path $ShareRoot $ScriptsFolderName
    $logDir     = Join-Path $ShareRoot $LogFolderName
    $logFile    = Join-Path $logDir $LogFileName

    New-Item -ItemType Directory -Path $scriptsDir, $logDir -Force | Out-Null

    # Basis: nur Administratoren und SYSTEM (Vererbung vom Laufwerk entfernt)
    & icacls.exe $ShareRoot /inheritance:r /grant '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F' | Out-Null
    # scripts: Domänencomputer lesen/ausführen (GPP kopiert das Skript als Computerkonto), niemals schreiben
    & icacls.exe $scriptsDir /grant:r "*${domainComputersSid}:(OI)(CI)RX" | Out-Null
    # log: Domänencomputer dürfen nur Dateien anlegen/anfügen, nichts lesen
    # Anfügen per .NET/SMB braucht mehr als "Daten schreiben/anfügen" (WD,AD). In der Praxis geprüft: Mit "W" allein und mit WD,AD,WEA,WA,RC,S wurde der
    # Zugriff verweigert; es geht mit zusätzlich "Attribute lesen" (RA). Lesen und Löschen der Inhalte bleiben verboten (kein RD, kein D).
    & icacls.exe $logDir /grant:r "*${domainComputersSid}:(OI)(CI)(WD,AD,WEA,WA,RA,RC,S)" | Out-Null

    Write-Ok "Ordner und NTFS-Rechte gesetzt ($scriptsDir, $logDir)"

    if (-not (Test-Path $logFile)) {
        # UTF-8 mit BOM in 5.1 und 7 gleich (Excel erkennt Umlaute); Set-Content -Encoding UTF8 schreibt in 7 kein BOM
        [System.IO.File]::WriteAllText($logFile, 'Timestamp;Level;Event;ComputerName;TargetName;Serial;MachineGuid;Message' + "`r`n", (New-Object System.Text.UTF8Encoding($true)))
        Write-Ok "Logdatei mit Kopfzeile angelegt: $logFile"
    }
    else { Write-Info "Logdatei existiert bereits: $logFile" }

    $localScript = if ($PSScriptRoot) { Join-Path $PSScriptRoot $ScriptName } else { $null }
    if ($localScript -and (Test-Path $localScript)) {
        Unblock-File -Path $localScript -ErrorAction SilentlyContinue      # Mark-of-the-Web nach Download/ZIP entfernen
        Copy-Item -Path $localScript -Destination $scriptsDir -Force
        Write-Ok "Client-Skript kopiert: $(Join-Path $scriptsDir $ScriptName)"
    }
    else { Write-Warning "'$ScriptName' liegt nicht neben diesem Skript - bitte manuell nach '$scriptsDir' kopieren." }

    # Gewünschte Share-Berechtigungen (Konto -> Recht); die NTFS-Rechte oben begrenzen in jedem Fall je Ordner
    $wanted = if ($ShareAccessMode -eq 'Everyone') { @{ $everyoneName = 'Full' } } else { @{ $adminsName = 'Full'; $domainComputersName = 'Change' } }
    $modeText = if ($ShareAccessMode -eq 'Everyone') { "${everyoneName}: Vollzugriff; die Rechte regelt NTFS" } else { "${adminsName}: Vollzugriff, ${domainComputersName}: Ändern; NTFS begrenzt je Ordner" }
    if (-not (Get-SmbShare -Name $ShareName -ErrorAction SilentlyContinue)) {
        New-SmbShare -Name $ShareName -Path $ShareRoot -FullAccess @($wanted.Keys | Where-Object { $wanted[$_] -eq 'Full' }) -ChangeAccess @($wanted.Keys | Where-Object { $wanted[$_] -eq 'Change' }) | Out-Null
        Write-Ok "Freigabe angelegt: $ShareUnc ($modeText)"
    }
    else {
        # Vorhandene Freigabe: Berechtigungen auf den gewünschten Stand bringen (idempotent)
        $changed = $false
        foreach ($acc in @(Get-SmbShareAccess -Name $ShareName)) {
            $key = @($wanted.Keys | Where-Object { $_ -ieq $acc.AccountName }) | Select-Object -First 1
            if (-not $key -or $wanted[$key] -ne [string]$acc.AccessRight -or [string]$acc.AccessControlType -ne 'Allow') {
                Revoke-SmbShareAccess -Name $ShareName -AccountName $acc.AccountName -Force | Out-Null; $changed = $true
            }
        }
        $present = @(Get-SmbShareAccess -Name $ShareName | Where-Object { [string]$_.AccessControlType -eq 'Allow' })
        foreach ($key in $wanted.Keys) {
            if (-not @($present | Where-Object { $_.AccountName -ieq $key -and [string]$_.AccessRight -eq $wanted[$key] })) {
                Grant-SmbShareAccess -Name $ShareName -AccountName $key -AccessRight $wanted[$key] -Force | Out-Null; $changed = $true
            }
        }
        if ($changed) { Write-Ok "Freigabe '$ShareName' existiert; Berechtigungen angepasst ($modeText)" }
        else          { Write-Info "Freigabe '$ShareName' existiert bereits - Berechtigungen unverändert ($modeText)." }
    }
}

function Invoke-ShareRemove {
    Write-Step "Share entfernen: $ShareName"
    if (Get-SmbShare -Name $ShareName -ErrorAction SilentlyContinue) {
        Remove-SmbShare -Name $ShareName -Force
        Write-Ok "Freigabe '$ShareName' entfernt."
    }
    else { Write-Info "Freigabe '$ShareName' existiert nicht." }

    if ($RemoveData) {
        $logFile = Join-Path (Join-Path $ShareRoot $LogFolderName) $LogFileName
        if (Test-Path $logFile) {
            New-Item -ItemType Directory -Path $LogArchiveDir -Force | Out-Null
            $archive = Join-Path $LogArchiveDir ('{0}_{1:yyyyMMdd-HHmmss}.csv' -f [IO.Path]::GetFileNameWithoutExtension($LogFileName), (Get-Date))
            Copy-Item -Path $logFile -Destination $archive -Force
            Write-Ok "Logdatei archiviert: $archive"
        }
        if (Test-Path $ShareRoot) {
            Remove-Item -Path $ShareRoot -Recurse -Force
            Write-Ok "Ordner gelöscht: $ShareRoot"
        }
    }
    else { Write-Info "Ordner und Logs bleiben unter $ShareRoot erhalten (zum Löschen: -RemoveData)." }
}

# ===========================================================================================
#  DELEGATION
# ===========================================================================================
function Get-DelegationRules {
    $schemaNC = (Get-ADRootDSE -Server $script:pdc).schemaNamingContext
    function Get-SchemaGuid {
        param([string]$LdapName, [ValidateSet('attributeSchema', 'classSchema')][string]$SchemaClass)
        $o = Get-ADObject -Server $script:pdc -SearchBase $schemaNC `
                -Filter "lDAPDisplayName -eq '$LdapName' -and objectClass -eq '$SchemaClass'" -Properties schemaIDGUID
        if (-not $o) { throw "Schema-Objekt '$LdapName' ($SchemaClass) nicht gefunden." }
        New-Object System.Guid (, [byte[]]$o.schemaIDGUID)
    }
    $computerClassGuid = Get-SchemaGuid -LdapName 'computer' -SchemaClass 'classSchema'

    $definitions = @(
        @{ Label = 'Schreiben: cn';             Rights = 'WriteProperty'; Guid = (Get-SchemaGuid 'cn'             'attributeSchema') }
        @{ Label = 'Schreiben: name';           Rights = 'WriteProperty'; Guid = (Get-SchemaGuid 'name'           'attributeSchema') }
        @{ Label = 'Schreiben: sAMAccountName'; Rights = 'WriteProperty'; Guid = (Get-SchemaGuid 'sAMAccountName' 'attributeSchema') }
        @{ Label = 'Schreiben: displayName';    Rights = 'WriteProperty'; Guid = (Get-SchemaGuid 'displayName'    'attributeSchema') }
        # Validated Writes (Rights = Self); feste, in jeder AD identische GUIDs
        @{ Label = 'Validated write: DNS host name';          Rights = 'Self'; Guid = [guid]'72e39547-7b18-11d1-adef-00c04fd8d5cd' }
        @{ Label = 'Validated write: service principal name'; Rights = 'Self'; Guid = [guid]'f3a64788-5306-11d1-a9c5-0000f80367c1' }
        # Nach dem Umbenennen setzt Windows das Kennwort des Computerkontos neu (die Kerberos-Schlüssel hängen am Namen)
        @{ Label = 'Reset password';                          Rights = 'ExtendedRight';  Guid = [guid]'00299570-246d-11d0-a768-00aa006e0529' }
        @{ Label = 'Schreiben: Account Restrictions';         Rights = 'WriteProperty';  Guid = [guid]'4c164200-20c0-11d0-a768-00aa006e0529' }
    )
    $selfSid = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-10')   # NT AUTHORITY\SELF
    $rules = foreach ($d in $definitions) {
        New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
            $selfSid,
            [System.DirectoryServices.ActiveDirectoryRights]$d.Rights,
            [System.Security.AccessControl.AccessControlType]::Allow,
            $d.Guid,
            [System.DirectoryServices.ActiveDirectorySecurityInheritance]::Descendents,   # nur untergeordnete Objekte ...
            $computerClassGuid)                                                          # ... und zwar nur Computerobjekte
    }
    [pscustomobject]@{ Rules = @($rules); Definitions = $definitions; ComputerGuid = $computerClassGuid }
}

function Set-Delegation {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Hilfsfunktion: Die Abfrage (ShouldProcess) erfolgt im Hauptablauf vor dem Aufruf.')]
    param([ValidateSet('Grant', 'Revoke')][string]$Mode)
    $verb = if ($Mode -eq 'Grant') { 'setzen' } else { 'entfernen' }
    Write-Step ("Delegation {0}: SELF auf Computerobjekten, {1} OU(s)" -f $verb, $DelegationOus.Count)
    Initialize-AdContext

    $del = Get-DelegationRules
    $failed = @()
    $used   = @()

    foreach ($ouDn in $DelegationOus) {
        Write-Host "   --- $ouDn" -ForegroundColor Cyan
        # OU im AD suchen. Fehlt sie, wird (interaktiv) nach einer anderen OU gefragt; leere Eingabe bricht den Lauf ab.
        # Mit -Force oder ohne Konsole gibt es keine Rückfrage: Die OU wird übersprungen und am Ende gemeldet.
        $target = $null
        $reason = ''
        try { $target = Get-ADObject -Server $script:pdc -Identity $ouDn } catch { $reason = $_.Exception.Message }
        while (-not $target) {
            Write-Warning "OU '$ouDn' wurde im AD nicht gefunden. ($reason)"
            if ($Force -or -not [Environment]::UserInteractive) { break }
            $answer = Read-Host "Andere OU eingeben (Distinguished Name, Domäne: $($script:domain.DistinguishedName)) oder Enter zum Abbrechen"
            if ([string]::IsNullOrWhiteSpace($answer)) { throw 'Abgebrochen: keine gültige OU angegeben. Es wurde nichts weiter geändert.' }
            $ouDn = $answer.Trim()
            Write-Host "   --- $ouDn" -ForegroundColor Cyan
            try { $target = Get-ADObject -Server $script:pdc -Identity $ouDn; $reason = '' } catch { $reason = $_.Exception.Message }
        }
        if (-not $target) { $failed += $ouDn; continue }
        $used += $ouDn

        $path = "AD:$ouDn"
        $acl  = Get-Acl -Path $path

        New-Item -ItemType Directory -Path $AclBackupDir -Force | Out-Null
        $safeName = $target.Name -replace '[^\w\- ]', '_'
        $backup = Join-Path $AclBackupDir ('ACL_{0}_{1:yyyyMMdd-HHmmss}.sddl' -f $safeName, (Get-Date))
        $acl.Sddl | Set-Content -Path $backup -Encoding ASCII
        Write-Info "ACL-Backup: $backup"

        foreach ($r in $del.Rules) {
            if ($Mode -eq 'Revoke') { [void]$acl.RemoveAccessRule($r) } else { $acl.AddAccessRule($r) }
        }
        Set-Acl -Path $path -AclObject $acl
        Write-Ok ("Delegation {0}." -f $(if ($Mode -eq 'Grant') { 'gesetzt' } else { 'entfernt' }))

        $selfAces = @((Get-Acl -Path $path).Access | Where-Object {
            (ConvertTo-SidString $_.IdentityReference) -eq 'S-1-5-10' -and
            $_.AccessControlType -eq 'Allow' -and
            $_.InheritedObjectType -eq $del.ComputerGuid })

        # Kontrolle: Sind alle erwarteten Rechte vorhanden (Setzen) bzw. alle entfernt (Entfernen)?
        $found = @($del.Definitions | Where-Object { $d = $_; @($selfAces | Where-Object { $_.ObjectType -eq $d.Guid }).Count -gt 0 }).Count
        if     ($Mode -eq 'Grant'  -and $found -lt $del.Definitions.Count) { Write-Warning "Nur $found von $($del.Definitions.Count) Rechten gefunden - Delegation prüfen." }
        elseif ($Mode -eq 'Grant')                                           { Write-Ok "Kontrolle: alle $found Rechte sind vorhanden." }
        elseif ($Mode -eq 'Revoke'  -and $found -gt 0)                       { Write-Warning "$found Rechte sind noch vorhanden - Entfernen prüfen." }
        else                                                                 { Write-Ok 'Kontrolle: alle Rechte sind entfernt.' }
    }
    # Die tatsächlich verwendeten OUs (auch eine interaktiv eingegebene) in die Test-Konfiguration übernehmen
    $script:DelegationOus = @($used) + @($failed)
    if ($failed.Count) { throw "Folgende OUs wurden nicht gefunden: $($failed -join '; ')" }
}

# ===========================================================================================
#  GPO
# ===========================================================================================
function Register-GpoExtension {
    # Trägt die CSE-Paare der Preferences in gPCMachineExtensionNames ein und erhöht die Versionsnummer
    # (AD und GPT.INI), damit die Clients die Preferences verarbeiten.
    param($Gpo, [string]$Sysvol, [string[]]$Pairs)
    $gpc = Get-ADObject -Identity $Gpo.Path -Server $script:pdc -Properties versionNumber, gPCMachineExtensionNames
    $existing = @()
    if ($gpc.gPCMachineExtensionNames) {
        $existing = [regex]::Matches($gpc.gPCMachineExtensionNames, '\[[^\]]+\]') | ForEach-Object { $_.Value }
    }
    $extString = (($existing + $Pairs) | Sort-Object -Unique) -join ''
    $newVer    = [int]$gpc.versionNumber + 1      # untere 16 Bit = Computerkonfiguration
    Set-ADObject -Identity $Gpo.Path -Server $script:pdc -Replace @{ gPCMachineExtensionNames = $extString; versionNumber = $newVer }

    $gptIni = Join-Path $Sysvol 'GPT.INI'
    $lines  = if (Test-Path $gptIni) { @(Get-Content -Path $gptIni) } else { @('[General]') }
    if ($lines -match '^Version=') { $lines = $lines -replace '^Version=\d+', "Version=$newVer" }
    else                           { $lines += "Version=$newVer" }
    Set-Content -Path $gptIni -Value $lines -Encoding ASCII
    Write-Ok "CSE registriert, Versionsnummer gesetzt: $newVer"
}

function Set-GpoSecurityFilter {
    # Sicherheitsfilterung (optional): Anwenden nur für $SecurityFilterGroup
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Hilfsfunktion: Die Abfrage (ShouldProcess) erfolgt im Hauptablauf vor dem Aufruf.')]
    param($Gpo)
    if (-not $SecurityFilterGroup) { return }
    $authUsers = (New-Object Security.Principal.SecurityIdentifier('S-1-5-11')).Translate([Security.Principal.NTAccount]).Value.Split('\')[-1]
    Set-GPPermission -Guid $Gpo.Id -Server $script:pdc -TargetName $authUsers -TargetType Group -PermissionLevel GpoRead -Replace | Out-Null
    Set-GPPermission -Guid $Gpo.Id -Server $script:pdc -TargetName $SecurityFilterGroup -TargetType Group -PermissionLevel GpoApply | Out-Null
    Write-Ok "Sicherheitsfilterung: Anwenden nur für '$SecurityFilterGroup'."
}

function Set-GpoLink {
    # Verknüpfung mit $LinkTargetOU, zunächst DEAKTIVIERT
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Hilfsfunktion: Die Abfrage (ShouldProcess) erfolgt im Hauptablauf vor dem Aufruf.')]
    param($Gpo, [string]$Name)
    if ($LinkTargetOU) {
        New-GPLink -Guid $Gpo.Id -Target $LinkTargetOU -LinkEnabled No -Server $script:pdc | Out-Null
        Write-Warning "GPO mit '$LinkTargetOU' verknüpft - Link ist DEAKTIVIERT. Aktivieren: Set-GPLink -Name '$Name' -Target '$LinkTargetOU' -LinkEnabled Yes"
    }
    else { Write-Info "Nicht verknüpft. Verknüpfen: New-GPLink -Name '$Name' -Target '<OU-DN>' -LinkEnabled Yes" }
}

function Invoke-GpoSetup {
    Write-Step "GPO anlegen: $GpoName"
    Import-Module GroupPolicy -ErrorAction Stop
    Initialize-AdContext

    if (Get-GPO -Name $GpoName -Server $script:pdc -ErrorAction SilentlyContinue) {
        Write-Warning "Eine GPO '$GpoName' existiert bereits - übersprungen. Zum Neuanlegen zuerst: -Action Remove -Component Gpo"
        return
    }
    if (-not (Test-Path $SourceShareFolder)) {
        Write-Warning "Quellordner '$SourceShareFolder' ist von hier aus nicht erreichbar (Share schon angelegt?). Die GPO wird trotzdem angelegt."
    }

    if ($TaskItemAction -notin @('C', 'U', 'R')) { throw "`$TaskItemAction '$TaskItemAction' ist ungültig (C, U oder R)." }
    $gpo = New-GPO -Name $GpoName -Server $script:pdc -Comment "Kopiert $ScriptName vom Share und legt den lokalen Scheduled Task an."
    $gpo.GpoStatus = 'UserSettingsDisabled'
    $gpoGuid = $gpo.Id.ToString('B').ToUpper()
    $sysvol  = "\\$($script:pdc)\SYSVOL\$($script:dnsRoot)\Policies\$gpoGuid"
    Write-Ok "GPO angelegt: $GpoName $gpoGuid"

    # Item-Level-Targeting: Item nur anwenden, wenn der Marker-Schlüssel NICHT existiert
    # (not="1" + KEYEXISTS). Damit legt die GPO Skript und Task nach der Bereinigung nicht erneut an.
    $iltXml = ''
    if ($CleanupAfterSuccess) {
        $iltXml = '<Filters><FilterRegistry bool="AND" not="1" hive="HKEY_LOCAL_MACHINE" key="{0}" type="KEYEXISTS" valueName="" valueType="REG_SZ" valueData="" min="0.0.0.0" max="0.0.0.0" gte="0" lte="0" /></Filters>' -f (ConvertTo-XmlText $MarkerRegistryKey)
    }

    # ---- GPP "Files": Skript vom Share kopieren
    # Aktion R (Replace): löscht die vorhandene Kopie und legt sie neu an. Mit U (Update) scheiterte das Überschreiben einer vorhandenen
    # Datei auf dem Client mit Fehler 0x50 "Datei existiert" (Ereignis 4117, Group Policy Files), und der Client behielt die alte Skriptversion.
    $now        = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $fromPath   = Join-Path $SourceShareFolder $ScriptName
    $targetPath = Join-Path $LocalFolder $ScriptName

$filesXml = @"
<?xml version="1.0" encoding="utf-8"?>
<Files clsid="{215B2E53-57CE-475c-80FE-9EEC14635851}">
  <File clsid="{50BE44C8-567A-4ed1-B1D0-9234FE1F38AF}" name="$(ConvertTo-XmlText $ScriptName)" status="$(ConvertTo-XmlText $ScriptName)" image="1" changed="$now" uid="$(New-GppUid)">
    <Properties action="R" fromPath="$(ConvertTo-XmlText $fromPath)" targetPath="$(ConvertTo-XmlText $targetPath)" readOnly="0" archive="1" hidden="0" suppress="0" />
    $iltXml
  </File>
</Files>
"@
    Write-Utf8File -Path (Join-Path $sysvol 'Machine\Preferences\Files\Files.xml') -Content $filesXml

    # ---- GPP "Scheduled Task"
    $ruleArgs = @()
    if ($NameTemplate) { $ruleArgs += ('-NameTemplate "{0}"' -f $NameTemplate) }
    else {
        if ($Prefix) { $ruleArgs += ('-Prefix "{0}"' -f $Prefix) }
        if ($Suffix) { $ruleArgs += ('-Suffix "{0}"' -f $Suffix) }
    }
    if ($NameTemplate -match '\{SERIAL(:-?\d+)?\}') {
        $ruleArgs += ('-OnSerialProblem {0}' -f $OnSerialProblem)
        $ruleArgs += ('-FutureIdLength {0}' -f $FutureIdLength)
    }
    $ruleText = if ($NameTemplate) { $NameTemplate } else { '{0}{{Name}}{1}' -f $Prefix, $Suffix }
    $argParts = @('-NoProfile -ExecutionPolicy Bypass', ('-File "{0}"' -f $targetPath)) + $ruleArgs +
                @(('-OnTooLong {0}' -f $OnTooLong), ('-CentralLogPath "{0}"' -f $CentralLogPath), ('-LocalDir "{0}"' -f $LocalFolder))
    if ($Reboot) { $argParts += '-Reboot'; $argParts += ('-RebootDelaySeconds {0}' -f $RebootDelaySeconds) }
    if ($CleanupAfterSuccess) { $argParts += '-Cleanup'; $argParts += ('-TaskName "{0}"' -f $TaskName) }
    $taskArgs = ConvertTo-XmlText ($argParts -join ' ')

    # Aktionen: optional zuerst den lokalen Ordner absichern (SIDs sind sprachunabhängig:
    # S-1-5-18 = SYSTEM, S-1-5-32-544 = Administratoren, S-1-5-32-545 = Benutzer), danach das Skript starten.
    $actionsXml = ''
    if ($HardenLocalFolder) {
        $icaclsOwner = ConvertTo-XmlText ('"{0}" /setowner *S-1-5-32-544' -f $LocalFolder)
        $icaclsAcl   = ConvertTo-XmlText ('"{0}" /inheritance:r /grant:r *S-1-5-18:(OI)(CI)F *S-1-5-32-544:(OI)(CI)F *S-1-5-32-545:(OI)(CI)RX' -f $LocalFolder)
        $actionsXml += "<Exec><Command>icacls.exe</Command><Arguments>$icaclsOwner</Arguments></Exec>"
        $actionsXml += "<Exec><Command>icacls.exe</Command><Arguments>$icaclsAcl</Arguments></Exec>"
    }
    $actionsXml += "<Exec><Command>powershell.exe</Command><Arguments>$taskArgs</Arguments></Exec>"

    $triggers = "<BootTrigger><Enabled>true</Enabled><Delay>$BootDelay</Delay></BootTrigger>"
    # Täglicher Trigger, optional mit Wiederholung. Aufbau und Reihenfolge der Elemente wie in einer von der GPMC geschriebenen Datei
    # (StartBoundary, Enabled, ScheduleByDay, Repetition zuletzt).
    # Registrierungs-Trigger ohne <Delay>: Mit Delay scheitert der GPMC-Bericht (Test-GpoReport.ps1 -Candidates, K1 bis K3 und K5 gegen K4).
    if ($RegistrationTrigger) { $triggers += '<RegistrationTrigger><Enabled>true</Enabled></RegistrationTrigger>' }
    $dailyAt = if ($DailyTriggerTime) { $DailyTriggerTime } elseif ($RepeatInterval) { '00:00' } else { '' }
    if ($dailyAt) {
        $start  = '{0:yyyy-MM-dd}T{1}:00' -f (Get-Date), $dailyAt
        $repeat = if ($RepeatInterval) { "<Repetition><Interval>$RepeatInterval</Interval><Duration>P1D</Duration><StopAtDurationEnd>false</StopAtDurationEnd></Repetition>" } else { '' }
        $triggers += "<CalendarTrigger><StartBoundary>$start</StartBoundary><Enabled>true</Enabled><ScheduleByDay><DaysInterval>1</DaysInterval></ScheduleByDay>$repeat</CalendarTrigger>"
    }

    $taskNameXml = ConvertTo-XmlText $TaskName
    $taskImage   = @{ C = 0; R = 1; U = 2 }[$TaskItemAction]      # Symbol-Nummer der GPP-Aktion (C=0, R=1, U=2)
$tasksXml = @"
<?xml version="1.0" encoding="utf-8"?>
<ScheduledTasks clsid="{CC63F200-7309-4ba0-B154-A71CD118DBCC}">
  <TaskV2 clsid="{D8896631-B747-47a7-84A6-C155337F3BC8}" name="$taskNameXml" image="$taskImage" changed="$now" uid="$(New-GppUid)">
    <Properties action="$TaskItemAction" name="$taskNameXml" runAs="$(ConvertTo-XmlText $TaskRunAs)" logonType="S4U">
      <Task version="1.2">
        <RegistrationInfo>
          <Author>GPO $(ConvertTo-XmlText $GpoName)</Author>
          <Description>Benennt den Hostnamen nach der Vorlage '$(ConvertTo-XmlText $ruleText)' um (idempotent). Log: $(ConvertTo-XmlText $CentralLogPath)</Description>
        </RegistrationInfo>
        <Principals>
          <Principal id="Author">
            <UserId>$(ConvertTo-XmlText $TaskUserId)</UserId>
            <LogonType>S4U</LogonType>
            <RunLevel>HighestAvailable</RunLevel>
          </Principal>
        </Principals>
        <Settings>
          <IdleSettings>
            <Duration>PT10M</Duration>
            <WaitTimeout>PT1H</WaitTimeout>
            <StopOnIdleEnd>true</StopOnIdleEnd>
            <RestartOnIdle>false</RestartOnIdle>
          </IdleSettings>
          <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
          <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
          <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
          <AllowHardTerminate>true</AllowHardTerminate>
          <StartWhenAvailable>true</StartWhenAvailable>
          <RunOnlyIfNetworkAvailable>true</RunOnlyIfNetworkAvailable>
          <AllowStartOnDemand>true</AllowStartOnDemand>
          <Enabled>true</Enabled>
          <Hidden>false</Hidden>
          <ExecutionTimeLimit>PT1H</ExecutionTimeLimit>
          <Priority>7</Priority>
        </Settings>
        <Triggers>$triggers</Triggers>
        <Actions Context="Author">$actionsXml</Actions>
      </Task>
    </Properties>
    $iltXml
  </TaskV2>
</ScheduledTasks>
"@
    Write-Utf8File -Path (Join-Path $sysvol 'Machine\Preferences\ScheduledTasks\ScheduledTasks.xml') -Content $tasksXml
    Write-Ok 'GPP-Dateien (Files, Scheduled Tasks) in SYSVOL geschrieben.'

    # ---- CSE-Registrierung + Versionsnummer (damit Clients die Preferences verarbeiten)
    Register-GpoExtension -Gpo $gpo -Sysvol $sysvol -Pairs @(
        '[{7150F9BF-48AD-4DA4-A49C-29EF4A8369BA}{3A0DBA37-F8B2-4356-83DE-3E90BD5C261F}]',   # Preferences: Files
        '[{AADCED64-746C-4633-A97C-D61349046527}{CAB54552-DEEA-4691-817E-ED4A4D1AFC72}]'    # Preferences: Scheduled Tasks
    )

    Set-GpoSecurityFilter -Gpo $gpo
    Set-GpoLink -Gpo $gpo -Name $GpoName

    # ---- Selbsttest
    try {
        $report = Get-GPOReport -Guid $gpo.Id -ReportType Xml -Server $script:pdc
        $okFile = $report -match [regex]::Escape($ScriptName)
        $okTask = $report -match [regex]::Escape($TaskName)
        if ($okFile -and $okTask) { Write-Ok 'Selbsttest OK: Files- und Scheduled-Task-Preference werden von der GPO erkannt.' }
        else { Write-Warning "Selbsttest: Preferences im GPO-Report nicht vollständig gefunden (Files: $okFile, Task: $okTask). GPO in der GPMC prüfen." }
    }
    catch { Write-Warning "Selbsttest nicht möglich: $($_.Exception.Message)" }
}

function Invoke-CleanupGpoSetup {
    Write-Step "Bereinigungs-GPO anlegen: $CleanupGpoName"
    Import-Module GroupPolicy -ErrorAction Stop
    Initialize-AdContext

    if (Get-GPO -Name $CleanupGpoName -Server $script:pdc -ErrorAction SilentlyContinue) {
        Write-Warning "Eine GPO '$CleanupGpoName' existiert bereits - übersprungen. Zum Neuanlegen zuerst: -Action Remove -Component CleanupGpo"
        return
    }

    # Schutz: Solange die Haupt-GPO existiert, legt sie Skript und Task auf bereits umbenannten Geräten neu an, sobald der Marker
    # gelöscht ist; bei Vorlagen mit {Name} und {Serial} würden die Geräte ohne Zustandsschlüssel sogar erneut umbenannt.
    if (Get-GPO -Name $GpoName -Server $script:pdc -ErrorAction SilentlyContinue) {
        $msg = "Die Haupt-GPO '$GpoName' existiert noch. Die Bereinigungs-GPO gehört ans Ende, nach Abschluss aller Umbenennungen und nach dem Entfernen der Haupt-GPO (-Action Remove -Component Gpo)."
        if (-not $Force) { throw $msg + ' Mit -Force wird sie trotzdem angelegt.' }
        Write-Warning ($msg + ' Wird wegen -Force trotzdem angelegt.')
    }
    $keys = @($CleanupRegistryKeys | Where-Object { $_ -and $_.Trim() } | ForEach-Object { $_.Trim() })
    if (-not $keys) { throw '$CleanupRegistryKeys ist leer: Es gäbe nichts zu löschen.' }
    # Schutz vor Tippfehlern: Diese GPO löscht auf allen Clients ganze Schlüssel samt Inhalt. Erlaubt sind nur einfache HKLM-Pfade
    # (ohne Hive-Präfix), deren letzter Teil mit 'HostRename' beginnt; so kann kein Zweig wie SOFTWARE oder SOFTWARE\Microsoft gelöscht werden.
    $badKeys = @($keys | Where-Object { $_ -notmatch '^[A-Za-z0-9_]+(\\[A-Za-z0-9_.-]+)*\\HostRename[A-Za-z0-9_.-]*$' -or $_ -match '^(HKLM|HKCU|HKCR|HKU|HKCC|HKEY_\w+)\\' })
    if ($badKeys) { throw "Ungültiger Eintrag in `$CleanupRegistryKeys: $($badKeys -join ', '). Erlaubt sind nur HKLM-Schlüssel ohne Hive-Präfix, deren letzter Teil mit 'HostRename' beginnt, z. B. 'SOFTWARE\HostRename'." }

    $gpo = New-GPO -Name $CleanupGpoName -Server $script:pdc -Comment 'Löscht die Registry-Schlüssel von HostRename auf den Clients. Erst nach Abschluss aller Umbenennungen und dem Entfernen der Haupt-GPO verknüpfen.'
    $gpo.GpoStatus = 'UserSettingsDisabled'
    $gpoGuid = $gpo.Id.ToString('B').ToUpper()
    $sysvol  = "\\$($script:pdc)\SYSVOL\$($script:dnsRoot)\Policies\$gpoGuid"
    Write-Ok "GPO angelegt: $CleanupGpoName $gpoGuid"

    # ---- GPP "Registry": je Schlüssel ein Item mit Aktion D (Delete); ohne Wertnamen wird der ganze Schlüssel gelöscht
    $now   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $items = foreach ($k in $keys) {
        $leaf = ConvertTo-XmlText (($k.TrimEnd('\') -split '\\')[-1])
        $keyX = ConvertTo-XmlText $k
@"
  <Registry clsid="{9CD4B2F4-923D-47f5-A062-E897DD1DAD50}" name="$leaf" status="$leaf" image="3" changed="$now" uid="$(New-GppUid)">
    <Properties action="D" displayDecimal="0" default="0" hive="HKEY_LOCAL_MACHINE" key="$keyX" name="" type="REG_SZ" value="" />
  </Registry>
"@
    }
$regXml = @"
<?xml version="1.0" encoding="utf-8"?>
<RegistrySettings clsid="{A3CCFC41-DFDB-43a5-8D26-0FE8B954DA51}">
$($items -join "`n")
</RegistrySettings>
"@
    Write-Utf8File -Path (Join-Path $sysvol 'Machine\Preferences\Registry\Registry.xml') -Content $regXml
    Write-Ok "GPP-Datei (Registry) in SYSVOL geschrieben: Löschen von $($keys.Count) Schlüssel(n) unter HKLM."

    Register-GpoExtension -Gpo $gpo -Sysvol $sysvol -Pairs @(
        '[{B087BE9D-ED37-454F-AF9C-04291E351182}{BEE07A6A-EC9F-4659-B8C9-0B1937907C83}]'    # Preferences: Registry
    )
    Set-GpoSecurityFilter -Gpo $gpo
    Set-GpoLink -Gpo $gpo -Name $CleanupGpoName
    Write-Info 'Erst aktivieren bzw. verknüpfen, wenn alle Geräte umbenannt sind und die Haupt-GPO entfernt ist.'

    # ---- Selbsttest
    try {
        $report  = Get-GPOReport -Guid $gpo.Id -ReportType Xml -Server $script:pdc
        $missing = @($keys | Where-Object { $report -notmatch [regex]::Escape($_) })
        if (-not $missing) { Write-Ok 'Selbsttest OK: Die Registry-Preference wird von der GPO erkannt.' }
        else { Write-Warning "Selbsttest: Schlüssel im GPO-Report nicht gefunden: $($missing -join ', '). GPO in der GPMC prüfen." }
    }
    catch { Write-Warning "Selbsttest nicht möglich: $($_.Exception.Message)" }
}

function Remove-HostRenameGpo {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Hilfsfunktion: Die Abfrage (ShouldProcess) erfolgt im Hauptablauf vor dem Aufruf.')]
    param([string]$Name)
    Write-Step "GPO entfernen: $Name"
    Import-Module GroupPolicy -ErrorAction Stop
    Initialize-AdContext

    $gpo = Get-GPO -Name $Name -Server $script:pdc -ErrorAction SilentlyContinue
    if (-not $gpo) { Write-Info "GPO '$Name' existiert nicht."; return }

    # Links in der Domäne (Domänenwurzel und alle OUs) entfernen; Standort-Links (Sites) werden nicht erfasst
    $guid = $gpo.Id.ToString()
    $containers = @(Get-ADObject -Server $script:pdc -SearchBase $script:domain.DistinguishedName -SearchScope Subtree `
                        -LDAPFilter "(gPLink=*$guid*)" -Properties gPLink)
    foreach ($c in $containers) {
        Remove-GPLink -Guid $gpo.Id -Target $c.DistinguishedName -Server $script:pdc | Out-Null
        Write-Ok "Link entfernt: $($c.DistinguishedName)"
    }
    Remove-GPO -Guid $gpo.Id -Server $script:pdc
    Write-Ok "GPO gelöscht: $Name ($guid)"
}

function Invoke-GpoRemove        { Remove-HostRenameGpo -Name $GpoName }
function Invoke-CleanupGpoRemove { Remove-HostRenameGpo -Name $CleanupGpoName }

# ===========================================================================================
#  Umbenennungsregel prüfen
# ===========================================================================================
function Test-NameRule {
    # Prüft Format der Regel und rechnet sie mit Beispielwerten durch. Dafür wird die Funktion
    # Resolve-NameTemplate aus Invoke-HostRename.ps1 geladen, damit Prepare und Client dieselbe Logik nutzen.
    Write-Step 'Umbenennungsregel prüfen'
    if (-not $NameTemplate -and -not $Prefix -and -not $Suffix) { throw 'Umbenennungsregel fehlt: $NameTemplate oder $Prefix/$Suffix setzen.' }
    if ($Prefix -notmatch '^$|^[A-Za-z0-9][A-Za-z0-9-]{0,9}$')  { throw "`$Prefix '$Prefix' ist ungültig (max. 10 Zeichen aus A-Z, 0-9 und -; nicht mit - beginnen)." }
    if ($Suffix -notmatch '^$|^[A-Za-z0-9-]{1,10}$')            { throw "`$Suffix '$Suffix' ist ungültig (max. 10 Zeichen aus A-Z, 0-9 und -)." }
    if ($NameTemplate -notmatch '^$|^[A-Za-z0-9_{}:-]+$')       { throw "`$NameTemplate '$NameTemplate' enthält unzulässige Zeichen (erlaubt: A-Z, 0-9, _, -, {Name}, {Serial})." }
    if ($NameTemplate -and ([regex]::Replace($NameTemplate, '\{(Name|Serial)(:-?\d+)?\}', '', 'IgnoreCase') -match '[{}]')) {
        throw "Unbekannter Platzhalter in `$NameTemplate '$NameTemplate' (erlaubt: {Name}, {Serial}, jeweils mit :N bzw. :-N)."
    }

    if ($OnSerialProblem -notin @('GenerateId', 'Skip')) { throw "`$OnSerialProblem '$OnSerialProblem' ist ungültig (GenerateId oder Skip)." }
    if ($FutureIdLength -lt 4 -or $FutureIdLength -gt 12) { throw "`$FutureIdLength $FutureIdLength ist ungültig (4 bis 12)." }

    $tpl = if ($NameTemplate) { $NameTemplate } else { '{0}{{Name}}{1}' -f $Prefix, $Suffix }
    $tpl = $tpl.ToUpper()
    $usesSerial = $tpl -match '\{SERIAL(:-?\d+)?\}'
    Write-Info "Vorlage: $tpl (bei zu langem Namen: $OnTooLong)"
    if ($usesSerial) { Write-Info "Seriennummer unbrauchbar oder doppelt: $OnSerialProblem$(if ($OnSerialProblem -eq 'GenerateId') { " (ID mit $FutureIdLength Zeichen)" })" }

    $invoke = if ($PSScriptRoot) { Join-Path $PSScriptRoot $ScriptName } else { $null }
    if (-not $invoke -or -not (Test-Path $invoke)) { Write-Warning "'$ScriptName' nicht neben diesem Skript gefunden - Beispielrechnung übersprungen."; return }
    $tk = $null; $er = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($invoke, [ref]$tk, [ref]$er)
    $fns = @($ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -in @('Resolve-NameTemplate', 'New-FutureId') }, $true))
    if ($fns.Count -lt 2) { Write-Warning "Resolve-NameTemplate/New-FutureId in '$ScriptName' nicht gefunden - Beispielrechnung übersprungen."; return }
    . ([scriptblock]::Create((($fns | ForEach-Object { $_.Extent.Text }) -join "`r`n")))

    $cases = @(
        @{ Label = 'Beispiel';      Name = 'PC349219';        Serial = 'PF2ABCDE' },
        @{ Label = 'Längster Fall'; Name = 'DESKTOP-AB12CD3'; Serial = 'ABCDEFGHIJ0123456789' }
    )
    foreach ($c in $cases) {
        $r = Resolve-NameTemplate -Template $tpl -CurrentName $c.Name -Serial $c.Serial -MaxLength 15 -OnTooLong $OnTooLong
        if ($r.Ok) {
            Write-Ok ('{0}: Name {1}, Seriennummer {2} -> {3}{4}' -f $c.Label, $c.Name, $c.Serial, $r.Name, $(if ($r.Truncated) { '  (gekürzt)' } else { '' }))
        }
        elseif ($r.Code -eq 'TOO_LONG') {
            Write-Warning ('{0}: {1}' -f $c.Label, $r.Error)
        }
        else { throw "Die Umbenennungsregel '$tpl' ist nicht verwendbar ($($c.Label)): $($r.Error)" }
    }

    if ($usesSerial -and $OnSerialProblem -eq 'GenerateId') {
        $id = New-FutureId -Seed 'BEISPIEL-MACHINEGUID' -Length $FutureIdLength -Attempt 0
        $r  = Resolve-NameTemplate -Template $tpl -CurrentName 'PC349219' -Serial $id -MaxLength 15 -OnTooLong $OnTooLong
        if (-not $r.Ok) { throw "Mit einer Zukunfts-ID ($FutureIdLength Zeichen) ergibt die Vorlage '$tpl' keinen gültigen Namen: $($r.Error)" }
        Write-Ok ("Ohne verwendbare Seriennummer (Zukunfts-ID): Name PC349219 -> {0}{1}" -f $r.Name, $(if ($r.Truncated) { '  (gekürzt)' } else { '' }))
    }
    elseif ($usesSerial) { Write-Info 'Ohne verwendbare Seriennummer wird das Gerät übersprungen (Exit-Code 5).' }
}

function Test-LocalFolder {
    # Hinweis, wenn der lokale Zielordner für Standardbenutzer beschreibbar sein könnte und nicht gehärtet wird
    if (-not $HardenLocalFolder -and $LocalFolder -match '(?i)\\(ProgramData|Users|Temp)(\\|$)') {
        Write-Warning "`$LocalFolder '$LocalFolder' liegt in einem für Benutzer beschreibbaren Bereich. Entweder einen Ordner unter 'C:\Program Files' verwenden oder `$HardenLocalFolder = `$true setzen."
    }
    elseif ($HardenLocalFolder -and $LocalFolder -match '(?i)\\Program Files') {
        Write-Info "Hinweis: `$HardenLocalFolder ist unter 'Program Files' nicht erforderlich (Standard-ACL schützt den Ordner)."
    }
}

# ===========================================================================================
#  Pester-Konfiguration
# ===========================================================================================
function Write-ChecksConfig {
    Write-Step "Konfiguration für die Pester-Tests: $ChecksConfigPath"
    $bool = { param($b) if ($b) { '$true' } else { '$false' } }
    # Muster für den Namen nach der Umbenennung (Platzhalter -> *), z. B. 'DE{Serial}' -> 'DE*'
    # OUs für die Tests: bei -OuDN (einzelne OU nachträglich) bleiben die übrigen aus $ClientOuDN in der Prüfung;
    # eine interaktiv korrigierte OU steht bereits in $DelegationOus.
    $configOus = if ($OuDN) { @($ClientOuDN) + @($DelegationOus) } else { @($DelegationOus) }
    $configOus = @($configOus | Where-Object { $_ } | Select-Object -Unique)
    $nameLike = if ($NameTemplate) { [regex]::Replace($NameTemplate, '\{(Name|Serial)(:-?\d+)?\}', '*', 'IgnoreCase').ToUpper() }
                else               { ($Prefix + '*' + $Suffix).ToUpper() }
$content = @"
@{
    # Erzeugt von Prepare-HostRename.ps1 am $(Get-Date -Format 'yyyy-MM-dd HH:mm') - bei Änderungen das Skript erneut mit -Action Setup ausführen oder hier anpassen

    GpoName           = $(ConvertTo-PsLiteral $GpoName)
    ClientOuDN        = @($((@($configOus) | ForEach-Object { ConvertTo-PsLiteral $_ }) -join ', '))
    SourceShareFolder = $(ConvertTo-PsLiteral $SourceShareFolder)
    ScriptName        = $(ConvertTo-PsLiteral $ScriptName)
    LocalFolder       = $(ConvertTo-PsLiteral $LocalFolder)
    CentralLogPath    = $(ConvertTo-PsLiteral $CentralLogPath)
    NameTemplate      = $(ConvertTo-PsLiteral $NameTemplate)
    Prefix            = $(ConvertTo-PsLiteral $Prefix)
    Suffix            = $(ConvertTo-PsLiteral $Suffix)
    NameLike          = $(ConvertTo-PsLiteral $nameLike)      # Muster für den Namen nach der Umbenennung
    OnTooLong         = $(ConvertTo-PsLiteral $OnTooLong)
    OnSerialProblem   = $(ConvertTo-PsLiteral $OnSerialProblem)
    RegistrationTrigger = $(& $bool $RegistrationTrigger)
    RepeatInterval    = $(ConvertTo-PsLiteral $RepeatInterval)
    FutureIdLength    = $FutureIdLength
    TaskName          = $(ConvertTo-PsLiteral $TaskName)
    CleanupGpoName    = $(ConvertTo-PsLiteral $CleanupGpoName)
    CleanupRegKeys    = @($((@($CleanupRegistryKeys) | ForEach-Object { ConvertTo-PsLiteral $_ }) -join ', '))
    MarkerRegistryKey = $(ConvertTo-PsLiteral $MarkerRegistryKey)

    ExpectCleanup     = $(& $bool $CleanupAfterSuccess)
    ExpectHardening   = $(& $bool $HardenLocalFolder)
    PilotGroup        = $(ConvertTo-PsLiteral $SecurityFilterGroup)
}
"@
    [System.IO.File]::WriteAllText($ChecksConfigPath, $content, (New-Object System.Text.UTF8Encoding($true)))   # UTF-8 mit BOM (5.1 und 7)
    Write-Ok 'geschrieben.'
}

# ===========================================================================================
#  Ablauf
# ===========================================================================================
if (-not (Test-IsAdmin)) { throw 'Bitte in einer PowerShell mit "Als Administrator ausführen" starten (UAC-Filterung des Tokens).' }

$components = @(@('Share', 'Delegation', 'Gpo', 'CleanupGpo') | Where-Object { $Component -contains $_ })
if ($Action -eq 'Setup' -and $components -contains 'Gpo' -and $components -contains 'CleanupGpo') {
    throw 'Haupt-GPO und Bereinigungs-GPO nicht in einem Lauf anlegen: Die Bereinigungs-GPO gehört ans Ende, nach Abschluss aller Umbenennungen und dem Entfernen der Haupt-GPO.'
}
if ($Action -eq 'Remove') { [array]::Reverse($components) }

Write-Host "HostRename Preparation: $Action -> $($components -join ', ')" -ForegroundColor White
if ($Action -eq 'Setup' -and $components -contains 'Gpo') { Test-NameRule; Test-LocalFolder }     # auch bei -WhatIf (nur lesend)
# Share und GPO auf verschiedenen Maschinen: $ShareServer muss der Fileserver sein, nicht der Rechner, auf dem die GPO angelegt wird
if ($Action -eq 'Setup' -and $components -contains 'Gpo' -and $components -notcontains 'Share' -and $ShareServer -ieq $env:COMPUTERNAME -and -not (Get-SmbShare -Name $ShareName -ErrorAction SilentlyContinue)) {
    Write-Warning "`$ShareServer ist '$ShareServer', also dieser Rechner, hier gibt es aber keine Freigabe '$ShareName'. Liegt der Share auf einem Fileserver, `$ShareServer dort hin ändern, bevor die GPO angelegt wird."
}
if ($Action -eq 'Setup' -and $components -contains 'Gpo' -and $ShareServer -ne $env:COMPUTERNAME -and $components -contains 'Share') {
    Write-Warning "Share wird auf diesem Rechner ($env:COMPUTERNAME) angelegt, die GPO verweist aber auf '$ShareServer'. `$ShareServer prüfen."
}

if ($Action -eq 'Remove' -and -not $Force -and -not $WhatIfPreference) {
    Write-Host "`nEntfernt werden: $($components -join ', ')" -ForegroundColor Yellow
    if ($components -contains 'Share' -and $RemoveData) { Write-Host "  Share-Ordner $ShareRoot wird GELÖSCHT (Logdatei wird nach $LogArchiveDir archiviert)." -ForegroundColor Yellow }
    if ((Read-Host 'Fortfahren? (j/N)') -notmatch '^(j|ja|y|yes)$') { Write-Host 'Abgebrochen.'; return }
}

foreach ($c in $components) {
    switch ($c) {
        'Share' {
            if ($Action -eq 'Setup') { if ($PSCmdlet.ShouldProcess("$ShareRoot / $ShareName", 'Share anlegen')) { Invoke-ShareSetup } }
            else                     { if ($PSCmdlet.ShouldProcess($ShareName, 'Share entfernen'))              { Invoke-ShareRemove } }
        }
        'Delegation' {
            if (-not $DelegationOus) { throw 'Keine OU angegeben: $ClientOuDN füllen oder -OuDN verwenden.' }
            if ($Action -eq 'Setup') { if ($PSCmdlet.ShouldProcess($DelegationOus -join '; ', 'Delegation setzen'))   { Set-Delegation -Mode Grant } }
            else                     { if ($PSCmdlet.ShouldProcess($DelegationOus -join '; ', 'Delegation entfernen')) { Set-Delegation -Mode Revoke } }
        }
        'Gpo' {
            if ($Action -eq 'Setup') { if ($PSCmdlet.ShouldProcess($GpoName, 'GPO anlegen'))    { Invoke-GpoSetup } }
            else                     { if ($PSCmdlet.ShouldProcess($GpoName, 'GPO entfernen')) { Invoke-GpoRemove } }
        }
        'CleanupGpo' {
            if ($Action -eq 'Setup') { if ($PSCmdlet.ShouldProcess($CleanupGpoName, 'Bereinigungs-GPO anlegen'))    { Invoke-CleanupGpoSetup } }
            else                     { if ($PSCmdlet.ShouldProcess($CleanupGpoName, 'Bereinigungs-GPO entfernen')) { Invoke-CleanupGpoRemove } }
        }
    }
}

if ($Action -eq 'Setup' -and $WriteChecksConfig -and -not $WhatIfPreference) { Write-ChecksConfig }

Write-Host "`nFertig." -ForegroundColor White
