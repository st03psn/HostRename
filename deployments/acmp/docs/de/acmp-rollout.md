# ACMP: Deployment-Prozess und Prüfung eines Laufs

[English version](../acmp-rollout.md) · Bauanleitung: [acmp-anleitung.md](acmp-anleitung.md) · Gerätetests: [testplan.md](testplan.md) · Zeitplan: [roadmap.md](roadmap.md)

Stand: 3. November 2026 · Version 1.2.0

Dieses Dokument beschreibt, **wie HostRename über ACMP ausgerollt wird**, von der Vorbereitung bis zum Abschluss, und **wie geprüft wird, ob ein Lauf funktioniert hat**. [acmp-anleitung.md](acmp-anleitung.md) erklärt, wie der Client-Command aufgebaut wird. [testplan.md](testplan.md) listet die einzelnen Gerätetests (T3); dieses Dokument verweist auf sie per ID.

> **Teststand:** In 1.2.0 ist noch nichts in ACMP oder auf einem echten Gerät gelaufen. Die ACMP-Begriffe (Client-Command, Container, Custom Field, Abfrage, Zeitplan) beschreiben, was gebraucht wird. Wo die ACMP-Konsole anders funktioniert oder die Dinge anders benennt, sind die Stellen mit „in ACMP prüfen“ markiert. Dieses Dokument nach den ersten ACMP-Tests anpassen (Abschnitt 5, Block AC-A).

## 1. Überblick

```text
Phase             Wer / wo               Abschlusskriterium
---------------   --------------------   ---------------------------------------------------------------
0 Vorbereiten     Admin, AD + ACMP       Delegation gesetzt, Dateirepository gefüllt, Custom Fields definiert
1 Aufbauen        ACMP-Konsole           Client-Commands angelegt, AC-A-Tests auf 1 Testgerät bestanden
2 Funktionstest   3–5 Testgeräte         AC-B- und AC-C-Tests bestanden (LAN, DA, nur WLAN, offline, Fehler)
3 Probelauf       alle Geräte, -WhatIf   Befunde bereinigt (Duplikate, Seriennummern, zu lang, Berechtigungen)
4 Pilot           etwa 20 Geräte         Abnahmekriterien in Abschnitt 6 erfüllt
5 Wellen          etwa 100, dann Rest    Abnahmekriterien je Welle erfüllt
6 Abschluss       Admin                  alle Geräte fertig oder erklärt, Client-Command aus, Delegation entfernt
```

Der GPO-Weg bleibt eine Alternative. Die HostRename-GPO **niemals** mit OUs verknüpfen, deren Geräte den ACMP-Client-Command erhalten.

## 2. Bausteine in ACMP

### 2.1 Client-Commands

Drei Client-Commands verwenden, damit Bestandsaufnahme, Probelauf und echter Lauf klar getrennt sind. Die Namen sind Vorschläge.

| Client-Command | Zweck | Ändert das Gerät | Inhalt |
| --- | --- | --- | --- |
| **HostRename – Status** | Zustand in Custom Fields sammeln | nein | Skript nur lesend (Abschnitt 4.2), läuft auf allen Geräten im Geltungsbereich, auch nach dem Abschluss |
| **HostRename – Probelauf** | Phase 3 | nein | `Invoke-AcmpHostRename.ps1 ... -WhatIf` (Gate + `Invoke-HostRename.ps1 -WhatIf`, schreibt nichts); keine Dialoge |
| **HostRename – Umbenennen** | Phasen 4–5 | ja | `Invoke-AcmpHostRename.ps1 ...`: Der Wrapper führt den vollständigen Ablauf aus [acmp-anleitung.md](acmp-anleitung.md), Abschnitt 4 (Zustandsprüfung, Gate, Umbenennen, Gate nach dem Neustart, Zertifikat, Cleanup) in einem Lauf aus; der Client-Command zeigt bei Exit-Code 3010 den Neustart-Dialog und bei 20 den Dialog „LAN-Kabel“ (siehe [acmp-anleitung.md](acmp-anleitung.md), „Empfohlen: der Wrapper“) |

Probelauf und Umbenennen rufen den Wrapper mit **denselben Parametern** auf (Vorlage, `-NoCentralLog` oder `-CentralLogPath`, `-CorporateSsid`, für WLAN-Geräte `-CertificateTemplate`); der Probelauf ergänzt nur `-WhatIf`. Eine andere Vorlage löst eine erneute Umbenennung aus.

Die Client-Commands versionieren, zum Beispiel indem die Skriptversion in Name oder Beschreibung steht. Einen Client-Command nur zwischen den Wellen ändern.

### 2.2 Custom Fields

Sie werden von **HostRename – Status** gefüllt oder von einem Statusschritt am Ende von **HostRename – Umbenennen**. Wie Custom Fields in ACMP definiert und gefüllt werden: in ACMP prüfen.

| Custom Field | Quelle | Verwendung |
| --- | --- | --- |
| `HR_Done` | Marker `HKLM\SOFTWARE\HostRename` existiert (`1`/`0`) | fertig |
| `HR_TargetName` | `HKLM\SOFTWARE\HostRenameState\TargetName` | Umbenennung ist erfolgt |
| `HR_LastExitCode` | `...\HostRenameState\LastExitCode` | **primärer Status** des letzten Laufs von `Invoke-HostRename.ps1` |
| `HR_LastEvent` | `...\HostRenameState\LastEvent` | nur Hinweis (letztes protokolliertes Ereignis, nicht das Ergebnis) |
| `HR_LastRun` | `...\HostRenameState\LastRun` | Alter der Information |
| `HR_Version` | `...\HostRenameState\ScriptVersion` | welche Skriptversion lief |
| `HR_Phase` | abgeleitet (Abschnitt 4.2) | für Container und Berichte |
| `HR_Gate` | letzte Zusammenfassungszeile von `Test-DeploymentNetwork.ps1` | warum ein Gerät wartet (nur WLAN, offline) |
| `HR_Cert` | letzte Zusammenfassungszeile von `Update-ComputerCertificate.ps1` | Zertifikatszustand (nur WLAN-Geräte) |

> „Fertig“ **nur** am Marker (`HR_Done`) und „umbenannt“ nur an `HR_TargetName` festmachen. Der Schlüssel `HostRenameState` existiert nach jedem Lauf, auch nach Fehlern und „nichts zu tun“.

### 2.3 Container (Gerätegruppen)

Statische Container steuern, **wer** den Client-Command erhält. Dynamische Container, aus den Custom Fields gebaut, zeigen, **wo** ein Gerät steht. In ACMP prüfen, wie dynamische Container oder Abfragen definiert werden.

| Container | Typ | Inhalt |
| --- | --- | --- |
| `HR-Test` | statisch | 3–5 Testgeräte (eines je Weg: LAN, DA, WLAN-Benutzer, selten online) |
| `HR-Pilot` | statisch | etwa 20 Geräte, gemischt: Standorte, Modelle, LAN-/DA-/WLAN-Benutzer |
| `HR-Wave-1`, `HR-Wave-2`, … | statisch | etwa 100, dann der Rest |
| `HR-Open` | dynamisch | `HR_Done = 0` und `HR_TargetName` leer |
| `HR-RebootPending` | dynamisch | `HR_LastExitCode = 3010` |
| `HR-AfterReboot` | dynamisch | `HR_TargetName` = aktueller Computername und `HR_Done = 0` |
| `HR-Done` | dynamisch | `HR_Done = 1` |
| `HR-Retry` | dynamisch | `HR_LastExitCode = 1` oder Gate 20/21/22 |
| `HR-Permanent` | dynamisch | `HR_LastExitCode` in 2, 4, 5 (braucht manuelles Eingreifen; der Client-Command endet bis zur Freigabe des Geräts in Schritt 1 mit `phase=permanent`, siehe [acmp-anleitung.md](acmp-anleitung.md), Abschnitt 4) |
| `HR-Stale` | dynamisch | `HR_LastRun` älter als N Tage und `HR_Done = 0` |

### 2.4 Zeitplan und Wiederholung

- **HostRename – Status:** täglich und beim Agent-Start, damit die Custom Fields aktuell bleiben.
- **HostRename – Umbenennen:** wiederholt auf dem Wellen-Container, bis das Gerät fertig ist, zum Beispiel bei jedem Agent-Start oder jeder Anmeldung plus einmal täglich. Schritt 1 des Ablaufs beendet den Lauf auf fertigen Geräten sofort, wiederholte Läufe sind also harmlos.
- Welche Auslöser ACMP bietet und wie „wiederholen bis erfolgreich“ eingestellt wird: in ACMP prüfen (Test AC-A7).

## 3. Deployment-Prozess Schritt für Schritt

### Phase 0: vorbereiten

1. Die Delegation setzen (siehe [acmp-anleitung.md](acmp-anleitung.md), Abschnitt 1). Für ein zentrales Log zusätzlich die Freigabe anlegen.
2. `Invoke-AcmpHostRename.ps1`, `Invoke-HostRename.ps1`, `Test-DeploymentNetwork.ps1` und `Update-ComputerCertificate.ps1` (nur mit `-CertificateTemplate` genutzt) unverändert in das ACMP-Dateirepository legen.
3. Die Custom Fields (Abschnitt 2.2) und die Container (Abschnitt 2.3) definieren.
4. Die Parameter festlegen: Vorlage, zentrales Log ja oder nein, Firmen-SSID, Name der Zertifikatsvorlage. In allen Client-Commands identisch verwenden.
5. Sicherstellen, dass die HostRename-GPO nicht mit diesen OUs verknüpft ist.

### Phase 1: aufbauen

1. Die drei Client-Commands anlegen (Abschnitt 2.1), zunächst nur `HR-Test` zugewiesen.
2. Block **AC-A** (Abschnitt 5) durchführen: Dateiübertragung, 64-Bit, Exit-Codes, Ausgabe, Custom Fields, Dialoge, Neustart, Wiederholung.
3. Die Client-Commands an das anpassen, was AC-A zeigt (zum Beispiel Sysnative bei einem 32-Bit-Agent oder wie 3010 behandelt wird).

### Phase 2: Funktionstest auf Testgeräten

1. Die Blöcke **AC-B** (Ende-zu-Ende je Weg) und **AC-C** (Fehler und Unterbrechungen) auf `HR-Test` durchführen.
2. Parallel die Gerätetests aus [testplan.md](testplan.md), die ACMP nicht abdeckt: WLAN vor und nach dem Neustart (W1, W2), Zertifikat (C1–C9), DirectAccess über Stunden (R7, R8), Namensabhängigkeiten (D1–D7).
3. Die Neustart-Frist festlegen (A8) und die Dialogtexte abschließen.

### Phase 3: Probelauf auf allen Geräten

1. **HostRename – Probelauf** allen Geräten im Geltungsbereich zuweisen.
2. Die stdout-Ausgabe (`WHATIF` mit dem Zielnamen) und die Exit-Codes einsammeln. `-WhatIf` schreibt kein lokales Log und keine Berichtswerte.
3. Auswerten wie in [testplan.md](testplan.md), T4: doppelte Zielnamen, `SERIAL_FALLBACK`, `TRUNCATE`, `COLLISION`, Exit 4, Geräte, die sich nie melden.
4. Die Befunde bereinigen. Den Probelauf wiederholen, bis keine neuen Befunde mehr auftreten.

### Phase 4: Pilot

1. **HostRename – Umbenennen** `HR-Pilot` zuweisen.
2. Den Fortschritt täglich über die Container (Abschnitt 2.3) und die Prüfungen in Abschnitt 4 verfolgen.
3. Erst weitermachen, wenn die Abnahmekriterien in Abschnitt 6 erfüllt sind.

### Phase 5: Wellen

Wie der Pilot mit `HR-Wave-1`, `HR-Wave-2` und so weiter. Vor jeder Welle: `HR-Permanent` und `HR-Stale` der vorigen Welle prüfen und Änderungen am Client-Command festhalten.

### Phase 6: Abschluss

1. Alle Geräte in `HR-Done`. Den Rest erklären oder einzeln behandeln (`HR-Permanent`, `HR-Stale`).
2. **HostRename – Umbenennen** deaktivieren. **HostRename – Status** noch eine Weile behalten, wenn Berichte weiter gebraucht werden.
3. Die Delegation entfernen: `.\Prepare-HostRename.ps1 -Action Remove -Component Delegation`.
4. Optional: die Registry-Schlüssel auf den Clients (beide Schlüssel `HKLM\SOFTWARE\HostRename*`) über einen kleinen Client-Command entfernen sowie `C:\ProgramData\HostRename`, wenn kein zentrales Log genutzt wurde und die lokalen Logs nicht mehr gebraucht werden.

## 4. Prüfung, ob ein Lauf funktioniert hat

### 4.1 Nachweis nach Ebene

Von oben nach unten prüfen. Ein Lauf ist nur dann in Ordnung, wenn alle zutreffenden Ebenen übereinstimmen.

| Ebene | Wo | Was zu prüfen ist |
| --- | --- | --- |
| 1 ACMP-Job | Job- bzw. Client-Command-Verlauf des Geräts (in ACMP prüfen) | Exit-Code jedes Schritts, stdout-Ausgabe (Zusammenfassungszeilen `RESULT=... EXIT=...`, Ereignisse auf stdout) |
| 2 Custom Fields | ACMP-Inventar, Container | `HR_Done`, `HR_TargetName`, `HR_LastExitCode`, `HR_LastRun` aktuell |
| 3 Gerät | Registry, lokales Log, Computername | `HKLM\SOFTWARE\HostRenameState`, Marker `HKLM\SOFTWARE\HostRename`, `C:\ProgramData\HostRename\rename-local.csv`, `$env:COMPUTERNAME` |
| 4 AD / DNS | Admin-PC | Computerobjekt mit dem neuen Namen, kein Objekt mit dem alten Namen; DNS-A-Eintrag des neuen Namens |
| 5 Zentrales Log (optional) | Freigabe | Zeilen mit `ComputerName` oder `MachineGuid` des Geräts |
| 6 Zertifikat / WLAN (WLAN-Geräte) | Gerät | neues Zertifikat mit dem neuen DNS-Namen; WLAN verbindet |

### 4.2 Erwarteter Zustand je Phase

| Phase des Geräts | `LastExitCode` | `TargetName` | Marker | Computername | ACMP | Nächster Schritt |
| --- | --- | --- | --- | --- | --- | --- |
| noch nicht gestartet | – | – | – | alt | – | Umbenennung läuft, wenn das Gate es erlaubt |
| wartet auf einen Weg | unverändert | – | – | alt | Gate 20/21/22 | automatisch beim nächsten Lauf (20: Benutzer steckt das Kabel an) |
| umbenannt, Neustart ausstehend | 3010 | neu | – | alt (aktiv), neu (ausstehend) | Neustart-Dialog gezeigt | Benutzer oder Frist startet neu |
| nach dem Neustart | 3010 oder 0 | neu | – | neu | Gate 0 | Zertifikat (WLAN-Geräte), Cleanup |
| fertig | 0 | neu (leer, wenn der Name schon zur Vorlage passte) | vorhanden (`ComputerName` = neu) | neu | Schritt 1 beendet den Lauf | keiner |
| Wiederholung | 1 | evtl. | – | evtl. | Fehler im Job | automatisch beim nächsten Lauf; nach mehreren Fehlschlägen das Log prüfen |
| dauerhaft | 2, 4 oder 5 | – | – | alt | Client-Command endet bei jedem Lauf in Schritt 1 (Wrapper: Exit 2, 4 oder 5 mit `PHASE=Permanent STEP=StateCheck`; einzelne Schritte: `phase=permanent`) | manuelles Eingreifen: Ursache beheben, dann das Gerät durch Löschen von `LastExitCode` freigeben (siehe [acmp-anleitung.md](acmp-anleitung.md), Abschnitt 4) |

### 4.3 Statusskript für den Client-Command „HostRename – Status“

Nur lesend. Es schreibt nichts und gibt eine Zeile aus, die ACMP speichern oder in Custom Fields zerlegen kann. In ACMP prüfen, wie eine Skriptausgabe oder ein Registrywert ein Custom Field füllt. Kann ACMP Registrywerte direkt lesen, diese verwenden und hier nur `HR_Phase` ableiten.

```powershell
# HostRename-Status (nur lesend). Ausgabe: eine Zeile, Exit-Code 0.
$state  = Get-ItemProperty 'HKLM:\SOFTWARE\HostRenameState' -ErrorAction SilentlyContinue
$done   = Test-Path 'HKLM:\SOFTWARE\HostRename'
$target = if ($state) { [string]$state.TargetName } else { '' }
$active = $env:COMPUTERNAME
$phase  = if ($done) { 'Done' }
          elseif (-not $target) { if ($state -and $state.LastExitCode -in 2,4,5) { 'Permanent' } else { 'Open' } }
          elseif ($active -ieq $target) { 'AfterReboot' }
          else { 'RebootPending' }
'HR_PHASE={0} HR_DONE={1} HR_TARGET={2} HR_EXIT={3} HR_EVENT={4} HR_LASTRUN={5} HR_VERSION={6} NAME={7}' -f `
    $phase, [int]$done, $target, $state.LastExitCode, $state.LastEvent, $state.LastRun, $state.ScriptVersion, $active
exit 0
```

Es wie alle Skripte in der 64-Bit-PowerShell ausführen (siehe [acmp-anleitung.md](acmp-anleitung.md), Abschnitt 1).

### 4.4 Prüfungen auf der Admin-Seite

```powershell
# AD: neuer Name existiert, alter Name ist weg (RSAT-Modul ActiveDirectory)
Get-ADComputer -Identity '<NewName>' -Properties whenChanged, DNSHostName | Select-Object Name, DNSHostName, whenChanged
Get-ADComputer -Filter "Name -eq '<OldName>'"            # erwartet: kein Ergebnis

# DNS: Eintrag des neuen Namens, veralteter Eintrag des alten Namens
Resolve-DnsName '<NewName>' -Type A
Resolve-DnsName '<OldName>' -Type A -ErrorAction SilentlyContinue   # veralteter Eintrag: bereinigen oder von der Aufräumfunktion (Scavenging) erledigen lassen

# Zentrales Log (falls genutzt): alle Zeilen eines Geräts, nach MachineGuid
Import-Csv '\\<Server>\HostRename$\log\rename-log.csv' -Delimiter ';' | Where-Object MachineGuid -eq '<Guid>' | Format-Table Timestamp, Level, Event, ComputerName, TargetName, Message
```

### 4.5 Prüfungen auf dem Gerät (Helpdesk, Testgeräte)

```powershell
Get-ItemProperty HKLM:\SOFTWARE\HostRenameState
Test-Path HKLM:\SOFTWARE\HostRename
Import-Csv C:\ProgramData\HostRename\rename-local.csv -Delimiter ';' | Select-Object -Last 15 | Format-Table Timestamp, Level, Event, Message
Get-ChildItem Cert:\LocalMachine\My | Select-Object Subject, NotAfter, @{n='DNS';e={$_.DnsNameList -join ','}}
```

Das lokale Log ist nur als Administrator oder SYSTEM lesbar (geschützter Ordner).

## 5. ACMP-Testplan

Die Spalte „Ergebnis“ ausfüllen (OK oder Abweichung mit kurzer Notiz). Die Prüfung verwendet die Ebenen aus Abschnitt 4.1 (L1 = ACMP-Job, L2 = Custom Fields, L3 = Gerät, L4 = AD/DNS, L5 = zentrales Log, L6 = Zertifikat/WLAN).

### AC-A: ACMP-Mechanik (1 Testgerät, vor jeder Umbenennung)

| ID | Test | Schritte in ACMP | Erwartetes Ergebnis | Prüfung | Ergebnis |
| --- | --- | --- | --- | --- | --- |
| AC-A1 | Dateiübertragung | Client-Command kopiert die vier Skripte aus dem Dateirepository und führt `Get-FileHash` darauf aus | Dateien vorhanden, Hashes identisch mit dem Repository, BOM intakt | L1 | |
| AC-A2 | 64-Bit | Skriptschritt `[Environment]::Is64BitProcess` | `True`; bei `False` `%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe` verwenden und wiederholen | L1 | |
| AC-A3 | Exit-Codes | Skriptschritte mit `exit 0`, `1`, `5`, `20`, `3010` | jeder Code kommt unverändert an und ist in einer Bedingung nutzbar; notieren, wie 3010 behandelt wird (Testplan A1, A2) | L1 | |
| AC-A4 | Ausgabe | `Test-DeploymentNetwork.ps1` ausführen | die Zusammenfassungszeile ist im Jobverlauf sichtbar | L1 | |
| AC-A5 | Custom Fields | **HostRename – Status** auf einem Gerät ohne HostRename-Schlüssel ausführen, dann nach dem Anlegen eines Testwerts `HKLM:\SOFTWARE\HostRenameState\LastExitCode = 1` | Felder gefüllt (`HR_PHASE=Open`, `HR_EXIT=1`); die Container `HR-Open` / `HR-Retry` zeigen das Gerät; danach den Testwert entfernen | L2 | |
| AC-A6 | Dialog | als SYSTEM laufender Client-Command zeigt den Text „LAN-Kabel“ | Dialog erscheint in der Sitzung des angemeldeten Benutzers (Testplan A3) | L1 | |
| AC-A7 | Wiederholung | einen Client-Command mit „wiederholen bis erfolgreich“ oder einem Zeitplan zuweisen | läuft beim konfigurierten Auslöser erneut; hört auf, wenn die Bedingung „fertig“ sagt | L1 | |
| AC-A8 | Neustart-Steuerung | Neustart-Dialog mit Frist testen | Benutzer kann innerhalb der Frist verschieben; Neustart erfolgt spätestens zur Frist | L1, L3 | |

### AC-B: Ende-zu-Ende je Weg (Testgeräte, **HostRename – Umbenennen**)

| ID | Weg | Schritte | Erwartetes Ergebnis | Prüfung | Ergebnis |
| --- | --- | --- | --- | --- | --- |
| AC-B1 | LAN | Probelauf, dann Umbenennen auf einem LAN-Gerät | Probelauf: Exit 0, `WHATIF` mit dem Zielnamen. Umbenennen: Gate 0, Exit 3010, Neustart-Dialog; nach dem Neustart: Gate 0, Cleanup Exit 0, `HR_Done=1`, Container `HR-Done` | L1–L4 | |
| AC-B2 | DirectAccess | wie AC-B1 außerhalb des Standorts über DA | wie AC-B1; die Zeit von Umbenennung bis Neustart notieren und ob der Tunnel bestehen bleibt (Testplan R7, R8) | L1–L4 | |
| AC-B3 | WLAN-Benutzer mit Kabel | wie AC-B1, mit Zertifikatsschritt | wie AC-B1, zusätzlich Zertifikat `RESULT=RENEWED` vor dem Cleanup; danach funktioniert WLAN ohne Kabel (Testplan C7) | L1–L4, L6 | |
| AC-B4 | nur WLAN | Umbenennen auf einem Gerät nur mit Firmen-WLAN | Gate 20, Dialog „LAN-Kabel“, keine Umbenennung, `HR_LastExitCode` unverändert; nach dem Anstecken des Kabels benennt der nächste Lauf um | L1–L3 | |
| AC-B5 | offline / fremdes Netz | Umbenennen auf einem Gerät in einem Heimnetz ohne DA | Gate 21, kein Dialog, keine Umbenennung; benennt beim nächsten Lauf im LAN oder über DA um | L1–L3 | |
| AC-B6 | bereits fertig | Umbenennen erneut auf einem AC-B1-Gerät ausführen | Schritt 1 beendet den Lauf (Marker vorhanden), kein Skript läuft | L1, L3 | |
| AC-B7 | Name passt schon | Gerät, dessen Name bereits zur Vorlage passt | Exit 0 (`ALREADY_DONE`), kein Neustart; das Cleanup setzt den Marker | L1–L3 | |
| AC-B8 | Zentrales Log (falls genutzt) | AC-B1 mit `-CentralLogPath` | Zeilen in der zentralen CSV; nach dem Cleanup sind die lokalen Logs entfernt | L5, L3 | |
| AC-B9 | Client-Identität | das Gerät in der ACMP-Konsole vor und nach AC-B1 ansehen | dasselbe Client-Objekt, kein Duplikat; Historie, Container-Zugehörigkeit, Inventar notieren (Testplan A4) | L1, L2 | |

### AC-C: Fehler und Unterbrechungen

| ID | Situation | So erzeugen | Erwartetes Ergebnis | Prüfung | Ergebnis |
| --- | --- | --- | --- | --- | --- |
| AC-C1 | Keine Berechtigung | Testgerät in einer OU ohne Delegation | Exit 4 (`PERM_DENIED`), keine Umbenennung, Container `HR-Permanent`; Wiederholungen enden in Schritt 1 (Wrapper: Exit 4, `PHASE=Permanent STEP=StateCheck`; einzelne Schritte: `phase=permanent`), kein Gate, kein Skript; nach Behebung der Delegation und Löschen von `LastExitCode` läuft der nächste Lauf weiter und benennt um | L1–L3 | |
| AC-C2 | Name zu lang | zu lange Testvorlage mit `-OnTooLong Skip` | Exit 2, keine Umbenennung, `HR-Permanent`; Wiederholungen enden in Schritt 1 (Wrapper: Exit 2, `PHASE=Permanent STEP=StateCheck`; einzelne Schritte: `phase=permanent`); nach der Freigabe (`LastExitCode` gelöscht) läuft der Lauf wieder weiter | L1–L3 | |
| AC-C3 | Neustart verschoben | den Neustart-Dialog bis zur Frist verschieben | Neustart spätestens zur Frist; bis dahin liefern erneute Läufe 3010 (`PENDING_REBOOT`) | L1, L3 | |
| AC-C4 | Kabel vor dem Neustart gezogen | nach 3010 das Kabel ziehen, WLAN verwenden | notieren: funktioniert WLAN bis zum Neustart noch (Testplan W1)? Nach dem Neustart wartet das Gerät an Gate 20, bis ein Kabel angeschlossen ist | L1, L3, L6 | |
| AC-C5 | Gerät nach der Umbenennung offline | nach 3010 das Gerät einen Tag offline nehmen | der nächste Lauf macht mit der Phase nach dem Neustart weiter; nichts wird zweimal umbenannt | L1–L3 | |
| AC-C6 | Zentrales Log nicht erreichbar (falls genutzt) | die Freigabe während des Cleanups sperren | Exit 0, Marker nicht gesetzt; `CLEANUP_DEFERRED` im lokalen Log und als `HR_LastEvent` (die Cleanup-Ereignisse erscheinen auch in der ACMP-Ausgabe); der nächste Lauf schließt das Cleanup ab | L2, L3, L5 | |
| AC-C7 | Zertifikat schlägt fehl | falscher Vorlagenname | Zertifikat Exit 1, kein Cleanup, `HR-Retry`; nach Korrektur des Namens schließt der nächste Lauf ab | L1–L3, L6 | |
| AC-C8 | Geschützter Ordner | Standardbenutzer legt `C:\ProgramData\HostRename` vorab an (Testplan R14) | Exit 1, `[ERROR] LOCAL_DIR` in der ACMP-Ausgabe; nachdem ein Admin den Ordner gelöscht hat, funktioniert der nächste Lauf | L1, L3 | |
| AC-C9 | Zwei Läufe gleichzeitig | Umbenennen zweimal kurz hintereinander starten (falls ACMP es erlaubt) | keine doppelte Umbenennung; der zweite Lauf liefert 3010 oder endet bei Schritt 1 | L1, L3 | |

### AC-D: Probelauf und Berichte im großen Maßstab (Phase 3)

| ID | Test | Erwartetes Ergebnis | Ergebnis |
| --- | --- | --- | --- |
| AC-D1 | Probelauf auf allen Geräten | jedes erreichbare Gerät meldet einen Exit-Code und eine `WHATIF`-Zeile | |
| AC-D2 | Auswertung | Liste von Duplikaten, Seriennummern-Ersatz, Kürzungen, Kollisionen, Berechtigungsfehlern (Testplan T4) | |
| AC-D3 | Status auf allen Geräten | Custom Fields auf allen Geräten gefüllt; Container plausibel (alle `HR-Open` vor dem Pilot) | |

## 6. Abnahme- und Abbruchkriterien

### Zur nächsten Welle weitergehen, wenn

- jedes Gerät der Welle in `HR-Done` ist oder erklärt wird (`HR-Permanent` mit Grund, `HR-Stale` = nie im LAN/DA);
- kein Gerät der Welle dauerhaft seine Domänenverbindung oder sein WLAN verloren hat;
- Helpdesk-Anrufe wegen der Umbenennung bekannt und gelöst sind (zum Beispiel fehlendes WLAN, bis das Zertifikat erneuert ist);
- keine Duplikate in ACMP und keine unerwarteten Namensabhängigkeiten vorliegen (Testplan D1–D7).

### Den Rollout sofort stoppen, wenn

- sich ein Gerät nach dem Neustart nicht an der Domäne anmelden kann (sicherer Kanal defekt) oder DirectAccess dauerhaft verliert;
- WLAN-Benutzer ohne Kabel in großem Umfang abgeschnitten werden, obwohl die Zertifikatserneuerung im Ablauf ist;
- ACMP Duplikate erzeugt oder nach der Umbenennung Zuordnungen (Lizenzen, Inventar) verliert;
- ein anderer Skript-Exit-Code als 0, 1, 2, 3, 4, 5, 20–22 oder 3010 auftritt.

Zum Stoppen **HostRename – Umbenennen** deaktivieren oder die Zuweisung entfernen. Bereits umbenannte Geräte bleiben umbenannt. Geräte, die umbenannt, aber noch nicht neu gestartet sind, behalten diesen Zustand: entscheiden, ob sie neu gestartet oder zurückbenannt werden.

### Ein einzelnes Gerät zurückbenennen

Auf dem Gerät als Administrator: `Rename-Computer -NewName <OldName> -Restart` (der alte Name steht in `HostRenameState\OriginalName`), danach `Remove-Item HKLM:\SOFTWARE\HostRename, HKLM:\SOFTWARE\HostRenameState -Recurse -ErrorAction SilentlyContinue`. Das Gerät aus dem Wellen-Container entfernen, sonst wird es erneut umbenannt. Bei WLAN-Geräten muss das Zertifikat danach für den alten Namen erneuert werden.

## 7. Wo man bei Problemen nachsieht

| Symptom | Zuerst ansehen | Typische Ursache |
| --- | --- | --- |
| Gerät bleibt in `HR-Open` | Jobverlauf: Gate-Zeile | nie im LAN/DA (Gate 20/21/22); Client-Command nicht zugewiesen |
| `HR_LastExitCode = 1` | ACMP-Ausgabe, lokales Log | DC nicht erreichbar, sicherer Kanal, `LOCAL_DIR`, `PLATFORM` (32-Bit) |
| Exit 4 | lokales Log `PERM_CHECK` / `PERM_DENIED` | Delegation für die OU des Geräts fehlt; nach der Behebung das Gerät freigeben: `Remove-ItemProperty -Path HKLM:\SOFTWARE\HostRenameState -Name LastExitCode` (sonst endet der Client-Command in Schritt 1 mit `phase=permanent`) |
| Hängt in `HR-RebootPending` | Neustart-Dialog / Frist | Benutzer verschiebt, Neustart von ACMP nicht ausgelöst |
| Hängt in `HR-AfterReboot` | Zertifikatszeile, lokales Log `CLEANUP_DEFERRED` | Zertifikatsschritt schlägt fehl, zentrales Log nicht erreichbar |
| WLAN funktioniert nach dem Neustart nicht | Zertifikatspeicher, `HR_Cert` | Zertifikat noch nicht erneuert (Gerät braucht einmal Kabel oder DA) |
| Custom Fields leer oder alt | `HR_LastRun`, Status-Client-Command | Status nicht eingeplant, 32-Bit-Registry-Sicht |
