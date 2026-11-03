# Anleitung: ACMP-Client-Command „HostRename“ aufbauen

[English version](../acmp-guide.md) · Hintergrund: [ACMP-Umsetzungsplan](ACMP-Umsetzungsplan.md) · Rollout und Prüfung eines Laufs: [acmp-rollout.md](acmp-rollout.md) · Tests: [Testplan](testplan.md)

Stand: 3. November 2026 · Version 1.2.0

> **Teststand:** Alles hier Beschriebene ist neu in 1.2.0. Die Skripte wurden nur mit Mocks getestet (Linux, PowerShell 7). Auf echten Windows-Geräten oder in ACMP ist noch nichts bestätigt. Welche Editor-Elemente ACMP bietet und wie sie heißen, ist hier **nicht bekannt**: Diese Stellen sind mit „in ACMP prüfen“ markiert. Der vorgeschlagene Ablauf ist ein Ausgangspunkt, der in den Gerätetests ([testplan.md](testplan.md)) angepasst wird.

GPO und ACMP sind **alternative** Verteilwege. Niemals beide auf demselben Gerät: Die HostRename-GPO nicht mit Geräten verknüpfen, die den Client-Command erhalten.

## 1. Voraussetzungen

- **Delegation** bleibt nötig: Auch unter ACMP benennt sich das Gerät mit seinem eigenen Computerkonto (SYSTEM) um. Einmalig auf einem Admin-PC oder DC als Domänenadmin in einer erhöhten PowerShell setzen:

  ```powershell
  .\Prepare-HostRename.ps1 -Action Setup -Component Delegation
  # einzelne OU zusätzlich oder statt $ClientOuDN:
  .\Prepare-HostRename.ps1 -Action Setup -Component Delegation -OuDN 'OU=Notebooks,DC=contoso,DC=com'
  ```

  Die OU-Liste ist `$ClientOuDN` im Block „ADJUST HERE“ von `Prepare-HostRename.ps1`.
- **Share** (`-Component Share`) nur, wenn das zentrale CSV-Log genutzt werden soll. Ohne zentrales Log ist kein Share nötig.
- **Keine GPO** für diese Geräte (die Haupt-GPO nicht anlegen oder nicht mit den OUs der ACMP-Geräte verknüpfen).
- Die Geräte haben Windows PowerShell 5.1 (immer vorhanden); Skripte mit `powershell.exe -NoProfile -ExecutionPolicy Bypass -File ...` aufrufen.
- **64-Bit-PowerShell ist Pflicht.** Ist der ACMP-Agent ein 32-Bit-Prozess, startet `powershell.exe` die 32-Bit-Kopie aus `SysWOW64`, und Registry-Schreibzugriffe auf `HKLM\SOFTWARE` landen in `WOW6432Node` (das Gerät gälte nie als „fertig“). `Invoke-HostRename.ps1 -Deployment Acmp` verweigert deshalb den Lauf in einem 32-Bit-Prozess auf 64-Bit-Windows: Es gibt `[ERROR] PLATFORM: ...` auf stdout aus und endet mit Exit-Code 1, bevor irgendetwas geschrieben wird (kein Log, keine Berichtswerte). Dann statt `powershell.exe` den Pfad `%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe` aufrufen (`Sysnative` sehen nur 32-Bit-Prozesse). Ob der ACMP-Agent als 32- oder 64-Bit-Prozess läuft: in ACMP prüfen (Gerätetest A1).
- Für den Zertifikatsschritt: der **Vorlagenname** (nicht der Anzeigename) des WLAN-Computerzertifikats. Er ist noch nicht bekannt und muss zuerst ermittelt werden.

## 2. Dateirepository

Diese Dateien ins Dateirepository von ACMP legen (in ACMP prüfen: wo und wie Dateien verwaltet und auf den Client übertragen werden):

| Datei | Gebraucht für |
| --- | --- |
| `Invoke-HostRename.ps1` | Umbenennung, Cleanup |
| `Test-DeploymentNetwork.ps1` | Netzwerk-Gate |
| `Update-ComputerCertificate.ps1` | Zertifikatserneuerung (nur wenn WLAN-Geräte betroffen sind) |

Die Skripte sind UTF-8 mit BOM. Kodierung beibehalten und im Repository nicht bearbeiten. Das Cleanup im ACMP-Modus löscht nie die Skriptdatei oder ihren Ordner: Die Datei gehört zum Cache von ACMP.

## 3. Parameter je Skript

Alle Aufrufe laufen als SYSTEM über `powershell.exe -NoProfile -ExecutionPolicy Bypass -File <Skript> ...`. Details: `Get-Help .\<Skript>.ps1 -Full`.

### `Test-DeploymentNetwork.ps1` (Gate)

| Parameter | Bedeutung |
| --- | --- |
| `-Allow` | erlaubte Wege: `Lan`, `DirectAccess`, `Wlan` (Standard `Lan, DirectAccess`). Mit `-File` kommt eine Kommaliste wie `-Allow Lan,DirectAccess` als ein String an; das Skript akzeptiert das |
| `-CorporateSsid` | SSID(s) des Firmen-WLANs mit EAP-TLS (kommagetrennt); ohne Angabe tritt Exit 20 nur bei einem domänenauthentifizierten WLAN auf |
| `-DomainName` | Domäne, deren DCs erreichbar sein müssen (Standard: eigene Domäne) |
| `-Quiet` | keine Ergebniszeile auf stdout, nur der Exit-Code |

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-DeploymentNetwork.ps1 -CorporateSsid "CORP-WLAN"
```

Das Skript gibt genau eine Zusammenfassungszeile aus, z. B. `RESULT=LAN EXIT=0 DOMAIN=... DC=... LAN=DomainAuthenticated ...`. Diese Zeile im ACMP-Protokoll festhalten (in ACMP prüfen).

### `Invoke-HostRename.ps1` (Umbenennung)

Für ACMP relevante Parameter:

| Parameter | Bedeutung |
| --- | --- |
| `-Deployment Acmp` | ACMP-Modus: lokale Logs in `C:\ProgramData\HostRename`, `-Reboot` wird ignoriert (Ereignis `REBOOT_IGNORED`), `-Cleanup` behält Skriptdatei und Ordner |
| `-NameTemplate` / `-Prefix` / `-Suffix` | Umbenennungsregel wie in der README, z. B. `-NameTemplate "DE{Serial}"` |
| `-OnTooLong`, `-OnSerialProblem`, `-FutureIdLength` | wie in der README (Name zu lang, unbrauchbare Seriennummer) |
| `-NoCentralLog` | kein zentrales Log: nur das lokale Log wird geschrieben, nichts wartet auf Auslieferung, die lokalen Logdateien bleiben als einziger Nachweis erhalten |
| `-CentralLogPath` | UNC-Pfad des zentralen CSV-Logs (nur, wenn ein zentrales Log genutzt wird). Ein Wert, der kein absoluter Pfad ist, schaltet das zentrale Log mit der Warnung `LOG_CHECK` im lokalen Log ab |
| `-LocalDir` | lokaler Logordner; im ACMP-Modus weglassen (Standard `C:\ProgramData\HostRename`, geschützt, siehe unten). Ein ausdrücklich angegebener Ordner wird unverändert genutzt: Standardbenutzer dürfen dort nicht schreiben können |
| `-Cleanup` | Abschlusslauf: Marker setzen, Logs ausliefern, lokale Logs entfernen (nur mit zentralem Log) |
| `-WhatIf` | zeigt nur den Zielnamen, ändert nichts, schreibt keine Berichtswerte |

```powershell
# Probelauf
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-HostRename.ps1 -Deployment Acmp -NameTemplate "DE{Serial}" -NoCentralLog -WhatIf
# Umbenennen ohne zentrales Log
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-HostRename.ps1 -Deployment Acmp -NameTemplate "DE{Serial}" -NoCentralLog
# Umbenennen mit zentralem Log
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-HostRename.ps1 -Deployment Acmp -NameTemplate "DE{Serial}" -CentralLogPath "\\<Server>\HostRename$\log\rename-log.csv"
# Abschlusslauf nach dem Neustart
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-HostRename.ps1 -Deployment Acmp -NameTemplate "DE{Serial}" -NoCentralLog -Cleanup
# 32-Bit-ACMP-Agent auf 64-Bit-Windows: dieselben Aufrufe mit der 64-Bit-PowerShell
%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-HostRename.ps1 -Deployment Acmp -NameTemplate "DE{Serial}" -NoCentralLog
```

In allen Aufrufen **dieselbe** Vorlage verwenden (eine andere Vorlage löst eine neue Umbenennung aus). Kein `-Reboot` übergeben: ACMP steuert den Neustart (wird es doch übergeben, steht bei jedem Lauf die Warnung `REBOOT_IGNORED` im lokalen Log). Der Standardwert von `-CentralLogPath` ist ein Platzhalterpfad (`\\FILESERVER\...`); daher immer entweder `-NoCentralLog` oder einen echten UNC-Pfad angeben. Nicht `-CentralLogPath ''` verwenden: Mit `powershell.exe -File` kommen die beiden Anführungszeichen wörtlich an (oder das leere Argument entfällt in manchen Konsolen). Das Skript behandelt `''`, `""` und leere Werte zwar als „kein zentrales Log“, der dokumentierte Weg ist aber `-NoCentralLog`.

**Geschützter Logordner.** Standardbenutzer dürfen in `C:\ProgramData` Ordner anlegen. Bevor das Skript etwas schreibt, prüft es daher den Standardordner `C:\ProgramData\HostRename`: Existiert er, darf er keine Junction und kein symbolischer Link sein und muss SYSTEM oder den Administratoren gehören; Dateien darin dürfen keine Analysepunkte (Reparse Points) sein und müssen ebenfalls SYSTEM oder den Administratoren gehören. Sonst gibt das Skript `[ERROR] LOCAL_DIR: ...` auf stdout aus, nutzt den Ordner nicht und endet mit Exit-Code 1 (die Berichtswerte werden trotzdem geschrieben). Ein Administrator entfernt den Ordner dann; der nächste Lauf legt ihn neu an. Bei jedem Lauf setzt das Skript den Besitzer Administratoren, entfernt die Vererbung und gibt nur SYSTEM und den Administratoren Vollzugriff (Ordner und Dateien, per SID mit `icacls`). Standardbenutzer können die lokalen Logs daher nicht mehr lesen.

### `Update-ComputerCertificate.ps1` (Zertifikatserneuerung)

| Parameter | Bedeutung |
| --- | --- |
| `-Template` | **Pflicht**: Vorlagenname des WLAN-Computerzertifikats |
| `-ExpectedDnsName` | DNS-Name, den das Zertifikat enthalten muss (Standard: `<Hostname>.<Computerdomäne>`) |
| `-RemoveOld` | andere Zertifikate derselben Vorlage entfernen, deren SAN den erwarteten Namen nicht enthält, samt privatem Schlüssel; erst nachdem ein gültiges neues bestätigt ist. Ohne den Schalter wird nichts entfernt |
| `-MinValidDays` | ein vorhandenes passendes Zertifikat, das länger gültig ist, gilt als aktuell (Standard 30) |
| `-WhatIf` | zeigt, ob ein Zertifikat angefordert würde |

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Update-ComputerCertificate.ps1 -Template <Vorlagenname> -WhatIf
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Update-ComputerCertificate.ps1 -Template <Vorlagenname> -RemoveOld
```

Die letzte stdout-Zeile ist eine Zusammenfassung: `RESULT=RENEWED|NOT_NEEDED|WHATIF|ERROR EXIT=... TEMPLATE=... DNS=...`. Solange eine Umbenennung noch auf den Neustart wartet, endet das Skript mit Exit-Code 1.

## 4. Ablauf des Client-Commands

```text
1  Zustand prüfen     fertig?          -> Ende
                      dauerhafter Fehler? -> Ende (bis zur Freigabe)
2  Gate               20 -> Dialog „LAN-Kabel anschließen“, Ende (später erneut)
                      21, 22 -> still beenden (später erneut)
3  Umbenennen         Invoke-HostRename.ps1 -Deployment Acmp ...
4  Exit-Code prüfen   3010 -> Neustart-Dialog, Neustart durch ACMP
                      0    -> weiter mit Phase „nach dem Neustart“
                      1    -> Ende, beim nächsten Lauf erneut
                      2,4,5 -> dauerhaft, nicht wiederholen, melden
   --- nach dem Neustart (nächster Lauf des Client-Commands) ---
5  Zustand prüfen     Marker fehlt, TargetName vorhanden -> weiter
6  Gate               wie oben
7  Zertifikat         nur WLAN-Geräte: Update-ComputerCertificate.ps1 -Template ... [-RemoveOld]
8  Cleanup            Invoke-HostRename.ps1 -Deployment Acmp ... -Cleanup
9  Bericht            Custom Fields aus der Registry
```

Wie der Client-Command später erneut gestartet wird (Zeitplan, „später erneut“, Wiederholung bei Fehler), ist Sache von ACMP: in ACMP prüfen.

### Schritt 1: Zustand prüfen („fertig“ entscheiden)

Das Gerät ist **fertig**, wenn der Marker-Schlüssel `HKLM\SOFTWARE\HostRename` existiert. Das Cleanup setzt ihn als letzten Schritt. Eine Umbenennung hat stattgefunden (und das Gerät wartet auf Neustart, Zertifikat oder Cleanup), wenn `TargetName` in `HKLM\SOFTWARE\HostRenameState` existiert.

> **Niemals die bloße Existenz des Schlüssels `HKLM\SOFTWARE\HostRenameState` als „fertig“-Kriterium verwenden.** Seit 1.2.0 existiert er nach jedem Lauf, weil das Skript dort die Berichtswerte schreibt (`LastRun`, `LastExitCode`, ...), auch nach einem Fehler oder bei „nichts zu tun“.

Beispiel (PowerShell, für eine Bedingung oder einen Skriptschritt; in ACMP prüfen, wie das Ergebnis ausgewertet wird):

```powershell
if (Test-Path 'HKLM:\SOFTWARE\HostRename') { 'phase=done'; exit 0 }   # fertig: Client-Command endet hier
$s = Get-ItemProperty 'HKLM:\SOFTWARE\HostRenameState' -ErrorAction SilentlyContinue
if ($s.LastExitCode -in 2, 4, 5) { 'phase=permanent'; exit 0 }   # dauerhafter Fehler: Ende bis zur Freigabe
if ($s.TargetName -and $env:COMPUTERNAME -ieq $s.TargetName) { 'phase=after-reboot' } else { 'phase=rename' }
```

Das Snippet endet immer mit Exit-Code 0; die Phase steht in seiner Ausgabe (`phase=done`, `phase=permanent`, `phase=after-reboot` oder `phase=rename`). Der Namensvergleich ist optional: `Invoke-HostRename.ps1` ist idempotent. Passt der Name schon, liefert es 0 (nichts zu tun) oder, solange ein Neustart aussteht, wieder 3010.

**Dauerhafte Fehler.** Nach Exit-Code 2, 4 oder 5 hat das Skript ihn in `LastExitCode` abgelegt. Da der Marker fehlt, endet Schritt 1 danach bei jedem weiteren Lauf mit `phase=permanent`: Der Client-Command bricht dort ab, weder Gate noch Skript laufen erneut, ein Gerät mit dauerhaftem Fehler wird also nicht endlos wiederholt. Um ein Gerät nach Behebung der Ursache freizugeben (zum Beispiel die Delegation), den Wert löschen, als Administrator auf dem Gerät oder über einen kleinen ACMP-Client-Command:

```powershell
Remove-ItemProperty -Path HKLM:\SOFTWARE\HostRenameState -Name LastExitCode
```

Der nächste Lauf macht dann mit Schritt 2 weiter. Ein späterer erfolgreicher Lauf überschreibt `LastExitCode` ohnehin; ist die Ursache nicht behoben, endet der Lauf wieder mit demselben Exit-Code und das Gerät ist erneut gesperrt.

### Schritt 2 und 6: Gate

| Exit-Code | Bedeutung | Reaktion |
| --- | --- | --- |
| 0 | erlaubter Weg (LAN/DirectAccess), DC erreichbar | weiter |
| 20 | nur Firmen-WLAN | Dialog mit Bitte um LAN-Kabel, Ende, später erneut |
| 21 | keine Domänenverbindung | still beenden, später erneut |
| 22 | Weg nicht erlaubt oder unbekannt | still beenden, später erneut |
| 1 | unerwarteter Fehler | beenden, später erneut, melden |

### Schritt 3 und 4: Umbenennen und Exit-Code auswerten

Siehe die Exit-Code-Tabelle unten. Nach 3010 den Neustart-Dialog zeigen und ACMP neu starten lassen (Textvorschläge unten). Der Dialog sollte sagen: das Kabel bis nach dem Neustart angeschlossen lassen.

Die Neustart-Frist (wie lange der Benutzer verschieben darf) ist **offen** und wird in den Gerätetests festgelegt. Grund für Zügigkeit: Zwischen Umbenennung und Neustart weichen Computername und AD-Konto voneinander ab (Risiko für den DirectAccess-Tunnel und für WLAN-Anmeldungen). Prüfen, ob der vorhandene Neustart-Dialog von ACMP genutzt werden kann (in ACMP prüfen).

### Schritt 7: Zertifikat (nur WLAN-Geräte)

Nur auf Geräten, die das EAP-TLS-WLAN nutzen. Ob dieser Schritt überhaupt nötig ist, klären die Gerätetests. Wie „WLAN-Geräte“ in ACMP ausgewählt werden (Gruppe, Custom Field, Bedingung), ist offen: in ACMP prüfen. Endet der Schritt mit Exit-Code 1, endet der Client-Command und versucht es beim nächsten Lauf erneut (ohne das Cleanup).

### Schritt 8: Cleanup

`Invoke-HostRename.ps1 -Deployment Acmp -Cleanup` liefert die Logs aus (nur mit zentralem Log), setzt den Marker `HKLM\SOFTWARE\HostRename` und entfernt einen geplanten Task, falls einer existiert (unter ACMP gibt es keinen). Skriptdatei und Ordner bleiben. Mit zentralem Log werden die lokalen Logs nach der Auslieferung entfernt, ohne zentrales Log bleiben sie in `C:\ProgramData\HostRename`. Nach diesem Lauf meldet Schritt 1 ab sofort „fertig“. Die Cleanup-Ereignisse (`CLEANUP`, `CLEANUP_DONE`, `CLEANUP_DEFERRED`, `CLEANUP_FAILED`) erscheinen auf stdout und damit in der ACMP-Jobausgabe sowie im lokalen Log und in `LastEvent`.

## 5. Exit-Code-Vertrag

| Exit-Code | Quelle | Bedeutung | Reaktion |
| --- | --- | --- | --- |
| 0 | alle | fertig / nichts zu tun / `-WhatIf` / Gate: erlaubter Weg | weiter |
| 3010 | `Invoke-HostRename.ps1` | umbenannt (oder Umbenennung ausstehend), Neustart nötig | Neustart-Dialog, Neustart durch ACMP |
| 1 | alle | Fehler, Details im Log | beim nächsten Lauf erneut; nach mehreren Fehlschlägen in den Bericht |
| 2 | `Invoke-HostRename.ps1` | Name zu lang (`-OnTooLong Skip`) | dauerhaft, nicht wiederholen, melden |
| 4 | `Invoke-HostRename.ps1` | keine Berechtigung am eigenen AD-Objekt | dauerhaft, Delegation prüfen, melden |
| 5 | `Invoke-HostRename.ps1` | keine brauchbare Seriennummer (`-OnSerialProblem Skip`) | dauerhaft, nicht wiederholen, melden |
| 20 | `Test-DeploymentNetwork.ps1` | nur Firmen-WLAN | Dialog „LAN-Kabel anschließen“, später erneut |
| 21 | `Test-DeploymentNetwork.ps1` | keine Domänenverbindung | still, später erneut |
| 22 | `Test-DeploymentNetwork.ps1` | Weg nicht erlaubt / unbekannt | still, später erneut |
| ab 100, ab 1001 | ACMP selbst | eigene Codes von ACMP | wie ACMP sie abbildet: in ACMP prüfen |

Die Skriptcodes sind 0 bis 5, 20 bis 22 und 3010. Alle außer 3010 liegen unter den eigenen Bereichen von ACMP; **3010 liegt zahlenmäßig im Bereich von ACMP (ab 1001)**. In ACMP prüfen, wie 3010 aus einem Skript behandelt wird: unverändert durchgereicht, in einer Bedingung nutzbar oder als ACMP-Code gedeutet (Gerätetest A1).

Bei `LOCAL_DIR` und `PLATFORM` (siehe oben) hat Exit-Code 1 keinen Eintrag im lokalen Log; der Grund steht nur auf stdout (ACMP-Ausgabe).

### Textvorschläge für Dialoge (Beispiele, ans Unternehmen anpassen)

| Situation | Text |
| --- | --- |
| Exit 20 (nur WLAN) | „Bitte LAN-Kabel anschließen. Die Umbenennung Ihres Geräts ist nur über das Firmennetz per Kabel oder über DirectAccess möglich. Die Aktion wird später automatisch wiederholt.“ |
| Exit 3010 (Neustart) | „Ihr Gerät wurde umbenannt und muss neu gestartet werden. Bitte speichern Sie Ihre Arbeit und lassen Sie das LAN-Kabel bis nach dem Neustart angeschlossen.“ |
| Fertig | „Die Umbenennung ist abgeschlossen.“ |

Ob Dialoge in der Benutzersitzung erscheinen können, während der Client-Command als SYSTEM läuft, ist einer der Gerätetests.

## 6. Berichte über ACMP-Custom-Fields

`Invoke-HostRename.ps1` schreibt nach jedem Lauf (nicht mit `-WhatIf`, nicht in einem 32-Bit-Prozess) diese Werte nach `HKLM\SOFTWARE\HostRenameState`. Sie dienen nur dem Bericht; die Skriptlogik liest sie nie.

| Registrywert | Inhalt |
| --- | --- |
| `LastRun` | Zeitpunkt des letzten Laufs (`yyyy-MM-ddTHH:mm:sszzz`) |
| `LastExitCode` | Exit-Code des letzten Laufs (DWORD): **der eigentliche Status** |
| `LastEvent` | der in diesem Lauf zuletzt protokollierte Ereigniscode; ein Detail, kein Status (siehe unten) |
| `Deployment` | `Acmp` oder `Gpo` |
| `ScriptVersion` | z. B. `1.2.0` |
| `TargetName` | Zielname (erst nach einer Umbenennung) |

`LastEvent` ist einfach die zuletzt geschriebene Logzeile und damit nicht das „Ergebnis“ des Laufs: Nach einer erfolgreichen Umbenennung folgt auf `RENAMED` noch `AD_VERIFY`, und `LOG_DELIVERY` kann folgen, wenn das zentrale Log nicht erreichbar ist. Für den Status `LastExitCode` verwenden, `LastEvent` nur als Hinweis. Realistische Kombinationen:

| Situation | `LastExitCode` | typisches `LastEvent` |
| --- | --- | --- |
| umbenannt, Neustart ausstehend | 3010 | `AD_VERIFY` (oder `LOG_DELIVERY`) |
| erneuter Lauf vor dem Neustart | 3010 | `PENDING_REBOOT` |
| Name passt bereits | 0 | `ALREADY_DONE` |
| Abschlusslauf mit `-Cleanup` | 0 | `CLEANUP_DONE` (oder `CLEANUP_DEFERRED`/`LOG_DELIVERY`, solange das zentrale Log nicht erreichbar ist) |
| keine Berechtigung am eigenen AD-Objekt | 4 | `PERM_DENIED` |
| andere Fehler | 1 | z. B. `PRECHECK`, `RENAME_FAILED`, `COLLISION`, `LOCAL_DIR` |

Weitere Quelle: der Marker `HKLM\SOFTWARE\HostRename` (`Completed`, `ComputerName`) für „fertig“. Wie ACMP-Custom-Fields definiert und aus Registrywerten gefüllt werden: in ACMP prüfen. Das lokale Log ist `C:\ProgramData\HostRename\rename-local.csv`; es bleibt erhalten, wenn kein zentrales Log genutzt wird.

## 7. Checkliste für Aufbau und Rollout

1. Delegation setzen; keine GPO-Verknüpfung für diese Geräte.
2. Dateirepository füllen (3 Skripte).
3. Client-Command nach Abschnitt 4 bauen, zuerst mit `-WhatIf` und `-NoCentralLog` (64-Bit-PowerShell, siehe Abschnitt 1).
4. Gerätetests ([testplan.md](testplan.md), T3) durchführen, Ablauf, Texte und Neustart-Frist anpassen.
5. Probelauf auf allen Geräten (T4), dann Wellen (T5).
