<#
.SYNOPSIS
    HostRename - Diagnose: grenzt auf Kopien der GPO ein, welcher Teil den Fehler im GPMC-Bericht auslöst, und prüft Konstruktionen für den Sofortstart.

.DESCRIPTION
    Der GPMC-Bericht (Reiter "Einstellungen") der GPO meldet "Unbekannter Fehler bei der Erstellung des HTML-Berichts", obwohl die
    GPO auf den Clients funktioniert. Dieses Skript findet heraus, welcher Teil der GPO den Fehler auslöst. Die echte GPO bleibt
    unberührt: Das Skript legt von ihr mehrere Kopien an (TEST-HostRename-V0 bis V10), ändert in jeder Kopie genau einen Punkt,
    erzeugt den HTML-Bericht und löscht die Kopien wieder.

    VARIANTEN
      V0  unverändert (Kontrolle; muss den Fehler zeigen, sonst reproduziert der Cmdlet-Bericht das Problem der GPMC nicht)
      V1  Beschreibung des Tasks ohne Klammern
      V2  ohne Registrierungs-Trigger
      V3  Konto "NT AUTHORITY\System" statt SYSTEM und SID
      V4  Dateikopie mit Aktion Update statt Replace
      V5  V1, V2 und V3 zusammen
      V6  ohne Item-Level-Targeting (Marker-Bedingung)
      V7  nur die Dateikopie (Task entfernt)
      V8  nur der Task (Dateikopie entfernt)
      V9  ohne Wiederholung am täglichen Trigger
      V10 Registrierungs-Trigger ohne Verzögerung (Element Delay entfernt)

    AUSWERTUNG
      Die Variante, in der der Bericht wieder funktioniert, nennt die Ursache. Funktionieren mehrere, wirkt die Änderung der ersten
      (kleinsten) Variante; V5 zeigt, ob erst mehrere Punkte zusammen den Fehler auslösen. V7 und V8 grenzen ein, welche der beiden
      Preferences den Fehler enthält. Funktioniert keine Variante, liegt die Ursache nicht an diesen Punkten, möglicherweise an der
      GPMC selbst: dann den Reiter "Einstellungen" einer beliebigen anderen GPO prüfen.

    KANDIDATEN FÜR DEN SOFORTSTART (-Candidates)
      Mit -Candidates prüft das Skript statt der Fehlersuche, welche Konstruktionen der GPMC-Bericht verträgt, die den Task kurz
      nach dem Anlegen starten lassen. Dazu ersetzt es in den Kopien (TEST-HostRename-K0 bis K7) die Trigger:
        K0  nur Systemstart-Trigger, Aktion Create (Standard 1.1.7 und 1.1.8; Kontrolle, muss funktionieren)
        K1  Systemstart + Registrierungs-Trigger (2 Minuten), Aktion Create
        K2  nur Registrierungs-Trigger (2 Minuten), Aktion Create
        K3  Registrierungs-Trigger vor dem Systemstart-Trigger, Aktion Create
        K4  Systemstart + Registrierungs-Trigger ohne Verzögerung, Aktion Create (Standard seit 1.1.9)
        K5  wie K1, aber Aktion Update (die Form bis Version 1.1.5)
        K6  Systemstart-Task und zusätzlich eine Sofortige Aufgabe (ImmediateTaskV2)
        K7  nur eine Sofortige Aufgabe (geplanter Task entfernt)
      Die Kandidaten mit "Bericht OK" sind für den Sofortstart nutzbar. Die GPO selbst wird nicht verändert.

    Erzeugt schon V0 keinen Fehler, reproduziert der Cmdlet-Bericht das Problem der GPMC nicht. Dann mit -Keep starten und den Reiter
    "Einstellungen" der Kopien in der GPMC ansehen; die Kopien danach löschen:
      Get-GPO -All | Where-Object DisplayName -like 'TEST-HostRename-*' | Remove-GPO

.PARAMETER SourceGpo
    Name der GPO, die geprüft wird (Standard: COMP - HostRename).

.PARAMETER Keep
    Die Kopien nicht löschen, damit ihr Bericht in der GPMC angesehen werden kann.

.PARAMETER Candidates
    Statt der Fehlersuche die Kandidaten für den Sofortstart prüfen (K0 bis K7, siehe Beschreibung).

.EXAMPLE
    .\Test-GpoReport.ps1

    Prüft die GPO "COMP - HostRename" und räumt die Kopien wieder auf.

.EXAMPLE
    .\Test-GpoReport.ps1 -SourceGpo 'COMP - HostRename' -Keep

    Behält die Kopien, um sie in der GPMC zu öffnen.

.EXAMPLE
    .\Test-GpoReport.ps1 -Candidates

    Prüft, welche Konstruktionen für den Sofortstart der GPMC-Bericht verträgt.

.NOTES
    Produkt          HostRename
    Version          1.1.9
    Stand            2026-10-30
    Ausführung       Erhöhte Windows PowerShell 5.1 auf einem DC oder Admin-PC (Module GroupPolicy und ActiveDirectory),
                     Konto mit dem Recht, GPOs anzulegen und zu löschen (Domänen-Admin)
    Kodierung        UTF-8 mit BOM (für die Windows PowerShell 5.1 erforderlich)

#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$SourceGpo = 'COMP - HostRename',
    [switch]$Keep,
    [switch]$Candidates
)

$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSEdition -eq 'Core') {
    throw 'Bitte in der Windows PowerShell 5.1 ausführen (GroupPolicy-Modul): powershell.exe -ExecutionPolicy Bypass -File .\Test-GpoReport.ps1'
}
Import-Module GroupPolicy, ActiveDirectory

$srv  = (Get-ADDomain).PDCEmulator
$dom  = (Get-ADDomain).DNSRoot
$utf8 = New-Object System.Text.UTF8Encoding($false)

# ---- Varianten ----------------------------------------------------------------------------------------------------------
# Jede Variante ändert genau einen Punkt (V5: drei zusammen). $t = ScheduledTasks.xml, $f = Files.xml.
# Ein Rückgabewert 'DROP-TASKS' bzw. 'DROP-FILES' entfernt die jeweilige Datei aus der Kopie.
$noBraces = { param($t, $f) $n = $t.SelectSingleNode("//*[local-name()='Description']"); $n.InnerText = $n.InnerText -replace '[{}\[\]]', '' }
$noRegTr  = { param($t, $f) $n = $t.SelectSingleNode('//RegistrationTrigger'); if ($n) { [void]$n.ParentNode.RemoveChild($n) } }
$oldAcct  = { param($t, $f) $t.SelectSingleNode('//Properties').SetAttribute('runAs', 'NT AUTHORITY\System'); $t.SelectSingleNode('//UserId').InnerText = 'NT AUTHORITY\System' }
$noRegDly = { param($t, $f) foreach ($n in @($t.SelectNodes('//RegistrationTrigger/Delay'))) { [void]$n.ParentNode.RemoveChild($n) } }
$noRepeat = { param($t, $f) foreach ($n in @($t.SelectNodes('//Repetition'))) { [void]$n.ParentNode.RemoveChild($n) } }
$noIlt    = { param($t, $f) foreach ($d in @($t, $f)) { foreach ($n in @($d.SelectNodes('//Filters'))) { [void]$n.ParentNode.RemoveChild($n) } } }
$variants = [ordered]@{
    'V0 unverändert (Kontrolle)'                       = { param($t, $f) }
    'V1 Beschreibung ohne Klammern'                    = $noBraces
    'V2 ohne Registrierungs-Trigger'                   = $noRegTr
    'V3 Konto "NT AUTHORITY\System" statt SYSTEM/SID'  = $oldAcct
    'V4 Dateikopie mit Aktion Update statt Replace'    = { param($t, $f) $e = $f.SelectSingleNode('//File'); $e.SetAttribute('image', '2'); $e.SelectSingleNode('Properties').SetAttribute('action', 'U') }
    'V5 V1 + V2 + V3 zusammen'                         = { param($t, $f) & $noBraces $t $f; & $noRegTr $t $f; & $oldAcct $t $f }
    'V6 ohne Item-Level-Targeting'                     = $noIlt
    'V7 nur die Dateikopie (Task entfernt)'            = { param($t, $f) 'DROP-TASKS' }
    'V8 nur der Task (Dateikopie entfernt)'            = { param($t, $f) 'DROP-FILES' }
    'V9 ohne Wiederholung am täglichen Trigger'        = $noRepeat
    'V10 Registrierung ohne Verzögerung (Delay weg)'   = $noRegDly
}

# ---- Kandidaten für den Sofortstart (-Candidates) ------------------------------------------------------------------------
# Jeder Kandidat ersetzt die Trigger der Kopie und setzt die GPP-Aktion; K6 und K7 fügen eine Sofortige Aufgabe (ImmediateTaskV2) hinzu.
$bootXml   = '<BootTrigger><Enabled>true</Enabled><Delay>PT5M</Delay></BootTrigger>'
$regXml    = '<RegistrationTrigger><Enabled>true</Enabled><Delay>PT2M</Delay></RegistrationTrigger>'
$regNoDly  = '<RegistrationTrigger><Enabled>true</Enabled></RegistrationTrigger>'
$setTrig   = { param($t, $xml, $action) $t.SelectSingleNode('//TaskV2/Properties/Task/Triggers').InnerXml = $xml; $t.SelectSingleNode('//TaskV2/Properties').SetAttribute('action', $action) }
$addNow    = {
    # Sofortige Aufgabe nach dem Aufbau einer von der GPMC geschriebenen Datei: eigener Elementname und CLSID, image 0, Zeittrigger mit den
    # Platzhaltern %LocalTimeXmlEx% (die GPP-Erweiterung setzt die Zeit beim Anwenden ein) und DeleteExpiredTaskAfter PT0S.
    param($t)
    $src = $t.SelectSingleNode('//TaskV2')
    $imm = $t.CreateElement('ImmediateTaskV2')
    $imm.SetAttribute('clsid', '{9756B581-76EC-4169-9AFC-0CA8D43ADB5F}')
    $imm.SetAttribute('name', 'HostRename-Sofort')
    $imm.SetAttribute('image', '0')
    $imm.SetAttribute('changed', $src.GetAttribute('changed'))
    $imm.SetAttribute('uid', '{' + [guid]::NewGuid().ToString().ToUpper() + '}')
    $imm.SetAttribute('userContext', '0')
    $imm.SetAttribute('removePolicy', '0')
    $imm.InnerXml = $src.InnerXml
    $p = $imm.SelectSingleNode('Properties')
    $p.SetAttribute('name', 'HostRename-Sofort'); $p.SetAttribute('action', 'C')
    $imm.SelectSingleNode('Properties/Task/Triggers').InnerXml = '<TimeTrigger><StartBoundary>%LocalTimeXmlEx%</StartBoundary><EndBoundary>%LocalTimeXmlEx%</EndBoundary><Enabled>true</Enabled></TimeTrigger>'
    $del = $t.CreateElement('DeleteExpiredTaskAfter'); $del.InnerText = 'PT0S'
    [void]$imm.SelectSingleNode('Properties/Task/Settings').AppendChild($del)
    [void]$src.ParentNode.InsertAfter($imm, $src)
}
$candidateVariants = [ordered]@{
    'K0 nur Systemstart (Kontrolle), Create'           = { param($t, $f) & $setTrig $t $bootXml 'C' }
    'K1 Systemstart + Registrierung (2 Min.), Create'  = { param($t, $f) & $setTrig $t ($bootXml + $regXml) 'C' }
    'K2 nur Registrierung (2 Min.), Create'            = { param($t, $f) & $setTrig $t $regXml 'C' }
    'K3 Registrierung vor Systemstart, Create'         = { param($t, $f) & $setTrig $t ($regXml + $bootXml) 'C' }
    'K4 Systemstart + Registrierung ohne Verzögerung'  = { param($t, $f) & $setTrig $t ($bootXml + $regNoDly) 'C' }
    'K5 wie K1, aber Aktion Update (Form bis 1.1.5)'   = { param($t, $f) & $setTrig $t ($bootXml + $regXml) 'U' }
    'K6 Systemstart-Task + Sofortige Aufgabe'          = { param($t, $f) & $setTrig $t $bootXml 'C'; & $addNow $t }
    'K7 nur Sofortige Aufgabe (Task entfernt)'         = { param($t, $f) & $setTrig $t $bootXml 'C'; & $addNow $t; $x = $t.SelectSingleNode('//TaskV2'); [void]$x.ParentNode.RemoveChild($x) }
}

function Save-Xml($doc, $path) {      # UTF-8 ohne BOM; die XML-Deklaration des Dokuments bleibt erhalten
    $w = New-Object Xml.XmlWriterSettings; $w.Encoding = $utf8; $w.Indent = $false
    $xw = [Xml.XmlWriter]::Create($path, $w); try { $doc.Save($xw) } finally { $xw.Dispose() }
}

# ---- Ablauf -------------------------------------------------------------------------------------------------------------
if ($Candidates) { $set = $candidateVariants; $tag = 'K' } else { $set = $variants; $tag = 'V' }
$last = $set.Count - 1
$results = @()
$i = 0
foreach ($name in $set.Keys) {
    $copy = "TEST-HostRename-$tag$i"; $i++
    try {
        Copy-GPO -SourceName $SourceGpo -TargetName $copy -SourceDomainController $srv -TargetDomainController $srv | Out-Null
        $gpo   = Get-GPO -Name $copy -Server $srv
        $base  = "\\$srv\SYSVOL\$dom\Policies\$($gpo.Id.ToString('B').ToUpper())\Machine\Preferences"
        $tPath = "$base\ScheduledTasks\ScheduledTasks.xml"
        $fPath = "$base\Files\Files.xml"
        $t = New-Object Xml.XmlDocument; $t.Load($tPath)
        $f = New-Object Xml.XmlDocument; $f.Load($fPath)
        $drop = & $set[$name] $t $f
        Save-Xml $t $tPath; Save-Xml $f $fPath
        if ($drop -eq 'DROP-TASKS') { Remove-Item -Path $tPath -Force }
        if ($drop -eq 'DROP-FILES') { Remove-Item -Path $fPath -Force }

        $html = Join-Path $env:TEMP "$copy.html"
        try   { Get-GPOReport -Guid $gpo.Id -Server $srv -ReportType Html -Path $html -ErrorAction Stop; $ok = $true;  $text = 'Bericht OK' }
        catch { $ok = $false; $text = 'FEHLER: ' + $_.Exception.Message }
        if ($ok -and -not $Keep) { Remove-Item -Path $html -Force -ErrorAction SilentlyContinue }
    }
    catch { $ok = $false; $text = 'ABBRUCH bei der Vorbereitung: ' + $_.Exception.Message }
    finally { if (-not $Keep -and (Get-GPO -Name $copy -Server $srv -ErrorAction SilentlyContinue)) { Remove-GPO -Name $copy -Server $srv } }

    $results += [pscustomobject]@{ Name = $name; Ok = $ok }
    '{0,-52} {1}' -f $name, $text
}

# ---- Zusammenfassung ----------------------------------------------------------------------------------------------------
''
if ($Candidates) {
    $good = @($results | Select-Object -Skip 1 | Where-Object Ok | ForEach-Object { ($_.Name -split ' ')[0] })
    $bad  = @($results | Select-Object -Skip 1 | Where-Object { -not $_.Ok } | ForEach-Object { ($_.Name -split ' ')[0] })
    if (-not $results[0].Ok) { 'K0 (nur Systemstart-Trigger) erzeugt schon einen Fehler: Die Kontrolle ist ungültig. Quell-GPO und Reiter "Einstellungen" einer anderen GPO prüfen.' }
    else {
        'Bericht OK bei    : ' + $(if ($good.Count) { $good -join ', ' } else { '(keinem Kandidaten)' })
        'Bericht FEHLER bei: ' + $(if ($bad.Count)  { $bad -join ', ' }  else { '(keinem Kandidaten)' })
        'Die Kandidaten mit "Bericht OK" lassen sich für den Sofortstart verwenden.'
    }
}
elseif ($results[0].Ok) {
    'V0 (unverändert) erzeugt keinen Fehler: Der Cmdlet-Bericht reproduziert das Problem der GPMC nicht.'
    ('Mit -Keep starten und den Reiter "Einstellungen" der Kopien TEST-HostRename-V0 bis V{0} in der GPMC ansehen.' -f $last)
}
else {
    $good = @($results | Select-Object -Skip 1 | Where-Object Ok | ForEach-Object { ($_.Name -split ' ')[0] })
    if ($good.Count) { 'Der Bericht funktioniert in: ' + ($good -join ', ') + '  -> die Änderung der ersten dieser Varianten nennt die Ursache.' }
    else             { 'In keiner Variante funktioniert der Bericht: Die Ursache liegt nicht an diesen Punkten, möglicherweise an der GPMC selbst (Reiter "Einstellungen" einer anderen GPO prüfen).' }
}
if ($Keep) { 'Die Kopien TEST-HostRename-{0}0 bis {0}{1} wurden behalten. Löschen: Get-GPO -All | Where-Object DisplayName -like ''TEST-HostRename-*'' | Remove-GPO' -f $tag, $last }
