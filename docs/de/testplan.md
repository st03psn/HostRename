# Testplan: Gerätetests für HostRename 1.2.0 (Phasen T3 und T4)

[English version](../test-plan.md) · Hintergrund: [Roadmap](roadmap.md), [ACMP-Anleitung](acmp-anleitung.md), [ACMP-Umsetzungsplan](ACMP-Umsetzungsplan.md)

Stand: 3. November 2026

Alles Neue in 1.2.0 (ACMP-Modus, Netzwerk-Gate, Zertifikatserneuerung, optionales zentrales Log, Berichtswerte) ist bisher nur mit Mocks unter Linux getestet. Dieser Plan listet die Tests auf echten Geräten. Die Ergebnisse fließen in Code und Dokumentation zurück (Exit-Codes, Erkennung, Neustart-Frist, Ablauf).

## Regeln

- Eigene Testgeräte verwenden (die Umbenennung ist ohne Aufwand nicht rückgängig zu machen; zurückbenennen mit `Rename-Computer` und Zustand zurücksetzen, siehe README „Rollback“).
- Skripte so ausführen wie die Verteilung: als SYSTEM, mit `powershell.exe -NoProfile -ExecutionPolicy Bypass -File ...` (siehe unten).
- Immer zuerst `-WhatIf`.
- Platzhalter: `<Vorlage>` = Name der Zertifikatsvorlage, `<SSID>` = SSID des Firmen-WLANs. Echte Werte nur in privaten Notizen festhalten.

Hilfsmittel, um etwas als SYSTEM auszuführen (Sysinternals PsExec, erhöhte Eingabeaufforderung):

```powershell
psexec -s powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Test\Test-DeploymentNetwork.ps1 -CorporateSsid "<SSID>"
```

Alternative ohne PsExec: ein einmaliger geplanter Task als SYSTEM, der die Ausgabe in eine Datei schreibt:

```powershell
$a = New-ScheduledTaskAction -Execute powershell.exe -Argument '-NoProfile -ExecutionPolicy Bypass -Command "& C:\Test\Test-DeploymentNetwork.ps1 -CorporateSsid <SSID> *> C:\Test\gate.txt"'
Register-ScheduledTask -TaskName GateTest -Action $a -User SYSTEM -RunLevel Highest | Start-ScheduledTask
# danach: Get-Content C:\Test\gate.txt; Unregister-ScheduledTask GateTest -Confirm:$false
```

Die Skripte in `C:\Test` sind Kopien der drei Skripte. Spalte „Ergebnis“ ausfüllen (OK / Abweichung + Notiz).

## T3-A: Netzwerk-Gate (`Test-DeploymentNetwork.ps1`)

| ID | Voraussetzung | Schritte | Erwartetes Ergebnis | Ergebnis |
| --- | --- | --- | --- | --- |
| G1 | Kabel im Firmen-LAN, WLAN aus | `.\Test-DeploymentNetwork.ps1 -CorporateSsid "<SSID>" -Verbose` | `RESULT=LAN EXIT=0` | |
| G2 | Extern, DirectAccess verbunden, kein Kabel | wie G1 | `RESULT=DIRECTACCESS EXIT=0`; `DA=ConnectedRemotely` | |
| G3 | Nur Firmen-WLAN, kein Kabel | wie G1 | `RESULT=WLAN EXIT=20` | |
| G4 | Kabel und Firmen-WLAN gleichzeitig | wie G1 | `RESULT=LAN EXIT=0` (LAN gewinnt) | |
| G5 | Heim-WLAN, kein DA (offline von der Domäne) | wie G1 | `EXIT=21` | |
| G6 | Kabel in einem fremden Netz (nicht Domäne), kein DA | wie G1 | `EXIT=21` (oder `22` mit `RESULT=OTHER`, wenn ein DC antwortet) | |
| G7 | Wie G1, DA installiert aber inaktiv | wie G1 | `RESULT=LAN EXIT=0`; DA nicht genutzt | |
| G8 | Kabel im Firmen-LAN | `.\Test-DeploymentNetwork.ps1 -Allow Lan` mit DA (Aufbau wie G2) | `EXIT=22` | |
| G9 | Nur Firmen-WLAN | `-CorporateSsid ""` (keine SSID angegeben) | `EXIT=20` nur, wenn das Profil domänenauthentifiziert ist; Ergebnis notieren | |
| G10 | Fälle G1, G2, G3, G5 | jeweils **als SYSTEM** ausführen (PsExec oder geplanter Task, siehe oben) | gleiche Exit-Codes wie im Benutzerkontext. Hinweis: Als SYSTEM kann Windows die SSID zurückhalten (WinRT-Standortdatenschutz); das Gate fällt dann auf das domänenauthentifizierte Profil zurück. Notieren, ob `WLAN=` die SSID zeigt | |
| G11 | beliebig | Zusammenfassungszeile (`RESULT=... EXIT=...`) jedes Falls notieren | die Zeile ist genau eine Zeile auf stdout | |

## T3-B: Umbenennung (`Invoke-HostRename.ps1`, ACMP-Modus)

`-Deployment Acmp -CentralLogPath ''` verwenden, außer das zentrale Log ist selbst Testgegenstand. Danach prüfen: `Get-ItemProperty HKLM:\SOFTWARE\HostRenameState`, `C:\ProgramData\HostRename\rename-local.csv`.

| ID | Voraussetzung | Schritte | Erwartetes Ergebnis | Ergebnis |
| --- | --- | --- | --- | --- |
| R1 | Kabel, Delegation gesetzt, Testgerät | `.\Invoke-HostRename.ps1 -Deployment Acmp -NameTemplate "<Regel>" -CentralLogPath '' -WhatIf`; `echo $LASTEXITCODE` | Exit 0, Ereignis `WHATIF` mit dem Zielnamen; kein `LastRun` geschrieben | |
| R2 | R1 bestanden | wie oben ohne `-WhatIf` | Exit 3010, Ereignis `RENAMED`; `HostRenameState`: `TargetName`, `LastExitCode=3010`, `LastEvent`, `Deployment=Acmp`, `ScriptVersion=1.2.0`; Marker `HKLM\SOFTWARE\HostRename` fehlt; kein Neustart gestartet | |
| R3 | nach R2, vor dem Neustart | erneut ausführen | Exit 3010 (Umbenennung ausstehend, Ereignis `PENDING_REBOOT`) | |
| R4 | vor dem Neustart | `-Reboot` ergänzen | Ereignis `REBOOT_IGNORED`, kein Neustart | |
| R5 | nach R2 | Neustart, dann mit `-Cleanup` ausführen | Exit 0; Marker `HKLM\SOFTWARE\HostRename` existiert; Skriptdatei und Ordner noch vorhanden; lokale Logs bleiben (kein zentrales Log) | |
| R6 | DirectAccess, kein Kabel | R1, dann R2 | wie R2 | |
| R7 | R6 erledigt | **nicht neu starten**; nach mehreren Stunden prüfen: DA-Tunnel, ACMP-Verbindung, Log-Share erreichbar (`Test-Path \\<Server>\HostRename$\log`), Domänenanmeldung des Computerkontos (`nltest /sc_verify:<Domäne>`) | notieren, was wann ausfällt (Grundlage für die Neustart-Frist) | |
| R8 | R7 | Neustart über DA | DA verbindet sich wieder, Gerät erreicht die Domäne; Zeit bis zur Verbindung notieren | |
| R9 | zentrales Log gewünscht | R2 mit `-CentralLogPath "\\<Server>\HostRename$\log\rename-log.csv"` und später `-Cleanup` | Einträge im zentralen CSV (START-Meldung `HostRename 1.2.0: deployment Acmp, ...`); nach dem Cleanup sind die lokalen Logs entfernt | |
| R10 | R2 mit `-CentralLogPath ''` und `-Cleanup` | `C:\ProgramData\HostRename` prüfen | lokale Logs bleiben; keine Verschiebung (`CLEANUP_DEFERRED` fehlt) | |
| R11 | jeder Lauf | nach jedem Lauf | `HostRenameState` existiert nach jedem Lauf (auch nach Fehlern und „nichts zu tun“); der Marker nur nach dem Cleanup | |

## T3-C: WLAN-Verhalten und Zertifikat

Ziel: klären, ob die Umbenennung das EAP-TLS-WLAN bricht (starke Zertifikatszuordnung, KB5014754) und ob die Erneuerung es behebt.

| ID | Voraussetzung | Schritte | Erwartetes Ergebnis | Ergebnis |
| --- | --- | --- | --- | --- |
| W1 | Umbenennung per Kabel erledigt (R2), **vor dem Neustart** | Kabel ziehen, WLAN neu verbinden lassen (WLAN aus/an, Access-Point-Wechsel) | notieren: funktioniert die WLAN-Authentifizierung noch (Reauthentifizierung)? | |
| W2 | R5 erledigt (neu gestartet), altes Zertifikat noch vorhanden | nur WLAN | notieren: verbindet oder nicht (Annahme: nicht) | |
| C1 | R2 erledigt, noch vor dem Neustart | `.\Update-ComputerCertificate.ps1 -Template <Vorlage>` | Exit 1, Zusammenfassung `RESULT=ERROR` (Umbenennung ausstehend) | |
| C2 | nach dem Neustart, per Kabel | `.\Update-ComputerCertificate.ps1 -Template <Vorlage> -WhatIf` | Exit 0, `RESULT=WHATIF`, nichts verändert | |
| C3 | C2 | wie oben ohne `-WhatIf` | Exit 0, `RESULT=RENEWED`; neues Zertifikat in `Cert:\LocalMachine\My` mit dem neuen DNS-Namen im SAN und privatem Schlüssel | |
| C4 | C3 | erneut ausführen | Exit 0, `RESULT=NOT_NEEDED` | |
| C5 | nach dem Neustart, über DirectAccess | C2, C3 | wie C2, C3 (Enrollment über DA funktioniert) | |
| C6 | altes und neues Zertifikat der Vorlage vorhanden | mit `-RemoveOld` | altes Zertifikat (alter Name) entfernt, neues bleibt; Zertifikate anderer Vorlagen unberührt | |
| C7 | C3 oder C6 erledigt | Kabel trennen, nur WLAN | WLAN verbindet mit dem neuen Zertifikat | |
| C8 | vorhandenes Zertifikat der Version 2+ | ersten Lauf prüfen | notieren, ob das vorhandene Zertifikat erkannt wurde (siehe Einschränkungen in `Get-Help .\Update-ComputerCertificate.ps1 -Full`) | |
| C9 | Kabelport | verlangt der LAN-Port 802.1X mit Computerzertifikat? Nach der Umbenennung anstecken (vor und nach dem Neustart) | notieren: Port funktioniert oder nicht; wenn nicht, gilt das Henne-Ei-Problem auch im LAN | |

## T3-D: ACMP-Verhalten

| ID | Voraussetzung | Schritte | Erwartetes Ergebnis | Ergebnis |
| --- | --- | --- | --- | --- |
| A1 | Test-Client-Command mit einem Skript, das `exit 3010` ausführt | über ACMP starten | notieren: wird 3010 unverändert durchgereicht und ist in einer Bedingung nutzbar? | |
| A2 | dasselbe mit `exit 20`, `exit 1`, `exit 5` | über ACMP starten | notieren: Exit-Codes 1 bis 99 werden durchgereicht | |
| A3 | ein Client-Command, der als SYSTEM läuft | einen Dialog zeigen (z. B. „Bitte LAN-Kabel anschließen“) | notieren: erscheint der Dialog in der Sitzung des angemeldeten Benutzers? | |
| A4 | Testclient durch den Client-Command umbenennen (R2) | vor und nach dem Neustart die ACMP-Konsole ansehen | notieren: dasselbe Client-Objekt oder Duplikat? Historie, Container-/Gruppenregeln nach Namen, Inventar | |
| A5 | R2 und R5 laufen über ACMP | Custom Fields aus den Werten von `HostRenameState` (`LastRun`, `LastExitCode`, `LastEvent`, `Deployment`, `ScriptVersion`, `TargetName`) und dem Marker definieren | Werte kommen in ACMP an; „fertig“ wird aus dem Marker oder `TargetName` abgeleitet, **nicht** aus der Existenz von `HostRenameState` | |
| A6 | Client-Command vollständig (Anleitung, Abschnitt 4) | per Kabel ausführen | vollständiger Ablauf: Gate, Umbenennung, Neustart-Dialog, Neustart, Gate, Zertifikat, Cleanup | |
| A7 | nur Firmen-WLAN | Client-Command ausführen | Gate Exit 20, Dialog gezeigt, keine Umbenennung | |
| A8 | Neustart-Dialog | Verschiebe-Grenze festlegen | Neustart-Frist festhalten (offene Entscheidung) | |

## T3-E: GPO-Regression (Client-Skript 1.2.0 im GPO-Modus)

Der GPO-Weg ist konstruktionsbedingt unverändert, aber das Client-Skript 1.2.0 ist im GPO-Modus noch nicht auf einem Gerät gelaufen. Ein Pilotgerät verwenden (kein ACMP-Gerät).

| ID | Voraussetzung | Schritte | Erwartetes Ergebnis | Ergebnis |
| --- | --- | --- | --- | --- |
| P1 | GPO verknüpft, Pilotgerät, Skript 1.2.0 auf dem Share | `gpupdate /force`; Task `HostRename` und Skriptkopie prüfen | Task und Skriptkopie angelegt; Task startet | |
| P2 | P1 | `Start-ScheduledTask -TaskName HostRename`; `C:\Program Files\HostRename\rename-local.csv` lesen | START-Meldung `HostRename 1.2.0: deployment Gpo, template ...`; Umbenennung, Exit 3010 | |
| P3 | P2 | Neustart; `HostRenameState` prüfen | Berichtswerte vorhanden, `Deployment=Gpo` | |
| P4 | P3 | Task läuft nach Boot + 5 min mit `-Cleanup` | Marker gesetzt, Task, Skript und lokale Logs entfernt; `CLEANUP_DONE` im zentralen Log | |
| P5 | P4 | `gpupdate /force` | GPO legt Task und Skript nicht neu an (Marker existiert) | |
| P6 | P1 | `HostRename.Client.Tests.ps1` (PreRun, PostRun) | besteht wie in 1.1.9 | |

## T3-F: weitere Namensabhängigkeiten

Nach einer Umbenennung auf einem Testgerät prüfen, was noch auf den alten Namen verweist:

| ID | System | Prüfung | Ergebnis |
| --- | --- | --- | --- |
| D1 | EDR / Virenschutz-Konsole | Gerät erscheint unter dem neuen Namen oder als Duplikat | |
| D2 | MDM / Intune (falls genutzt) | Gerätename, Compliance | |
| D3 | WSUS | Gerät meldet sich unter dem neuen Namen; kein Duplikat | |
| D4 | DNS | veralteter A-Eintrag des alten Namens (`Resolve-DnsName <alt>`); neuer Eintrag registriert | |
| D5 | Lizenzen / Lizenzserver | an den Computernamen gebunden? | |
| D6 | Drucker, Datei- und Druckberechtigungen | Berechtigungen am alten Namen? | |
| D7 | Sonstiges (Inventar, Backup, Monitoring, Zertifikate anderer Vorlagen) | auflisten, was namensgebunden ist | |

## T4: Probelauf auf allen Geräten

`Invoke-HostRename.ps1 -Deployment Acmp -NameTemplate "<Regel>" -CentralLogPath '' -WhatIf` über ACMP auf allen Geräten ausführen. Es ändert nichts und schreibt keine Berichtswerte.

Pro Gerät erfassen: ACMP-Exit-Code, das Ereignis `WHATIF` mit dem Zielnamen (aus dem lokalen Log `C:\ProgramData\HostRename\rename-local.csv` oder der ACMP-Ausgabe) und den Exit-Code des Gates, wo es Teil des Laufs ist.

Auswerten:

| Befund | Erkennung | Maßnahme |
| --- | --- | --- |
| Doppelte Zielnamen | Zielnamen gruppieren, Anzahl > 1 | Vorlage ändern oder bei `{Serial}` auf die Future-ID setzen |
| Fehlende oder unbrauchbare Seriennummern | Ereignis `SERIAL_FALLBACK` oder Exit 5 | Future-ID akzeptieren oder BIOS-Wert korrigieren |
| Zu lange Namen | Ereignis `TRUNCATE` oder Exit 2 | Kürzung prüfen oder Vorlage ändern |
| Name in AD schon vergeben | Ereignis `COLLISION` | in AD klären |
| Berechtigungsprobleme | Exit 4 oder `PERM_DENIED` | Delegation für die OU des Geräts prüfen |
| Nie online befindliche Geräte | keine Meldung im Zeitraum | Weg prüfen (nie im LAN oder über DA) |
| Name passt bereits | Exit 0 mit `ALREADY_DONE` | keine Maßnahme |

Die Befunde vor dem echten Lauf (T5) bereinigen.

## Ergebnisse zurückmelden

1. Spalte „Ergebnis“ ausfüllen (OK oder Abweichung mit kurzer Notiz).
2. Bei jeder Abweichung notieren: den Exit-Code, die Zusammenfassungszeile (`RESULT=... EXIT=...`) und einen kurzen Auszug aus dem lokalen Log (`rename-local.csv`, die Zeilen um das Problem).
3. Umgebungsdaten entfernen, bevor etwas an öffentlichen Stellen (Issues, Pull Requests) geteilt wird: Namen von Servern, Domänen, OUs, Geräten, SSIDs, Vorlagennamen und Seriennummern. Platzhalter wie `<Server>`, `<Vorlage>` verwenden.
4. Die ausgefüllte Tabelle privat an die Maintainer senden, wenn sie Umgebungsdaten enthält.
