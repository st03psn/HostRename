# Anleitung: ACMP-Client-Command „HostRename“ aufbauen

[English version](../acmp-guide.md) · Hintergrund: [ACMP-Umsetzungsplan](ACMP-Umsetzungsplan.md) · Tests: [Testplan](testplan.md)

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
| `-CentralLogPath` | Pfad des zentralen CSV-Logs; `''` (leer) schaltet es ab. Ohne zentrales Log bleiben die lokalen Logdateien als einziger Nachweis erhalten |
| `-LocalDir` | lokaler Logordner (Standard im ACMP-Modus: `C:\ProgramData\HostRename`) |
| `-Cleanup` | Abschlusslauf: Marker setzen, Logs ausliefern, lokale Logs entfernen (nur mit zentralem Log) |
| `-WhatIf` | zeigt nur den Zielnamen, ändert nichts, schreibt keine Berichtswerte |

```powershell
# Probelauf
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-HostRename.ps1 -Deployment Acmp -NameTemplate "DE{Serial}" -CentralLogPath '' -WhatIf
# Umbenennen ohne zentrales Log
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-HostRename.ps1 -Deployment Acmp -NameTemplate "DE{Serial}" -CentralLogPath ''
# Umbenennen mit zentralem Log
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-HostRename.ps1 -Deployment Acmp -NameTemplate "DE{Serial}" -CentralLogPath "\\<Server>\HostRename$\log\rename-log.csv"
# Abschlusslauf nach dem Neustart
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-HostRename.ps1 -Deployment Acmp -NameTemplate "DE{Serial}" -CentralLogPath '' -Cleanup
```

In allen Aufrufen **dieselbe** Vorlage verwenden (eine andere Vorlage löst eine neue Umbenennung aus). Kein `-Reboot` übergeben: ACMP steuert den Neustart. Der Standardwert von `-CentralLogPath` ist ein Platzhalterpfad (`\\FILESERVER\...`); daher immer entweder einen echten Pfad oder `''` angeben.

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
if (Test-Path 'HKLM:\SOFTWARE\HostRename') { exit 0 }   # fertig: Client-Command endet hier
$t = (Get-ItemProperty 'HKLM:\SOFTWARE\HostRenameState' -ErrorAction SilentlyContinue).TargetName
if ($t -and $env:COMPUTERNAME -ieq $t) { 'phase=after-reboot' } else { 'phase=rename' }
```

Der Namensvergleich ist optional: `Invoke-HostRename.ps1` ist idempotent. Passt der Name schon, liefert es 0 (nichts zu tun) oder, solange ein Neustart aussteht, wieder 3010.

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

`Invoke-HostRename.ps1 -Deployment Acmp -Cleanup` liefert die Logs aus (nur mit zentralem Log), setzt den Marker `HKLM\SOFTWARE\HostRename` und entfernt einen geplanten Task, falls einer existiert (unter ACMP gibt es keinen). Skriptdatei und Ordner bleiben. Mit zentralem Log werden die lokalen Logs nach der Auslieferung entfernt, ohne zentrales Log bleiben sie in `C:\ProgramData\HostRename`. Nach diesem Lauf meldet Schritt 1 ab sofort „fertig“.

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
| ab 100, ab 1001 | ACMP selbst | eigene Codes von ACMP | kollidieren nicht mit den Skriptcodes (alle unter 100); wie ACMP sie abbildet: in ACMP prüfen |

Ob und wie ACMP den Exit-Code eines PowerShell-Skripts durchreicht (besonders 3010), ist einer der Gerätetests (Testplan, Abschnitt ACMP).

### Textvorschläge für Dialoge (Beispiele, ans Unternehmen anpassen)

| Situation | Text |
| --- | --- |
| Exit 20 (nur WLAN) | „Bitte LAN-Kabel anschließen. Die Umbenennung Ihres Geräts ist nur über das Firmennetz per Kabel oder über DirectAccess möglich. Die Aktion wird später automatisch wiederholt.“ |
| Exit 3010 (Neustart) | „Ihr Gerät wurde umbenannt und muss neu gestartet werden. Bitte speichern Sie Ihre Arbeit und lassen Sie das LAN-Kabel bis nach dem Neustart angeschlossen.“ |
| Fertig | „Die Umbenennung ist abgeschlossen.“ |

Ob Dialoge in der Benutzersitzung erscheinen können, während der Client-Command als SYSTEM läuft, ist einer der Gerätetests.

## 6. Berichte über ACMP-Custom-Fields

`Invoke-HostRename.ps1` schreibt nach jedem Lauf (nicht mit `-WhatIf`) diese Werte nach `HKLM\SOFTWARE\HostRenameState`. Sie dienen nur dem Bericht; die Skriptlogik liest sie nie.

| Registrywert | Inhalt |
| --- | --- |
| `LastRun` | Zeitpunkt des letzten Laufs (`yyyy-MM-ddTHH:mm:sszzz`) |
| `LastExitCode` | Exit-Code des letzten Laufs (DWORD) |
| `LastEvent` | zuletzt protokollierter Ereigniscode (z. B. `RENAMED`, `CLEANUP_DONE`, `PERM_DENIED`) |
| `Deployment` | `Acmp` oder `Gpo` |
| `ScriptVersion` | z. B. `1.2.0` |
| `TargetName` | Zielname (erst nach einer Umbenennung) |

Weitere Quelle: der Marker `HKLM\SOFTWARE\HostRename` (`Completed`, `ComputerName`) für „fertig“. Wie ACMP-Custom-Fields definiert und aus Registrywerten gefüllt werden: in ACMP prüfen. Das lokale Log ist `C:\ProgramData\HostRename\rename-local.csv`; es bleibt erhalten, wenn kein zentrales Log genutzt wird.

## 7. Checkliste für Aufbau und Rollout

1. Delegation setzen; keine GPO-Verknüpfung für diese Geräte.
2. Dateirepository füllen (3 Skripte).
3. Client-Command nach Abschnitt 4 bauen, zuerst mit `-WhatIf` und `-CentralLogPath ''`.
4. Gerätetests ([testplan.md](testplan.md), T3) durchführen, Ablauf, Texte und Neustart-Frist anpassen.
5. Probelauf auf allen Geräten (T4), dann Wellen (T5).
