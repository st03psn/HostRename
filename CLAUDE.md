# HostRename – Übergabe an Claude Code

Diese Datei fasst zusammen, was für die Weiterarbeit nötig ist: Ziel, Entscheidungen samt Begründung, Fallstricke, Prüfstand und offene Punkte. Die Betriebsdokumentation steht in `README.md`, die Parameter in der eingebauten Hilfe der Skripte (`Get-Help .\Prepare-HostRename.ps1 -Full`).

## Worum es geht

HostRename benennt domänengebundene Windows-Clients (AD, im Pilot mit deutscher Systemsprache) per GPO automatisch um, nach einer Namensvorlage (`{Name}`, `{Serial}`, Prefix, Suffix, Zukunfts-ID bei unbrauchbarer oder doppelter Seriennummer). Das Client-Skript läuft als Scheduled Task unter SYSTEM, benennt lokal und das AD-Computerobjekt um (`Rename-Computer`), schreibt ein zentrales CSV-Log auf einen Share und räumt sich nach Erfolg selbst weg. Es gibt kein Passwort: Die Rechte kommen per Delegation an SELF auf den Client-OUs.

Stand: **Version 1.1.9** (30. Oktober 2026). Zielumgebung ist die **Windows PowerShell 5.1**; PowerShell 7 funktioniert zusätzlich.

## Nächstes Vorhaben: Verteilung über ACMP

Der Nutzer möchte die Umbenennung künftig über das Deployment-Tool ACMP verteilen statt per GPO (rund 700 Clients, meist Notebooks, DirectAccess und EAP-TLS-WLAN). Der Plan steht in `docs/ACMP-Umsetzungsplan.md` und ist **ein Entwurf**: Zuerst Phase 0 (Klärung an Testgeräten) mit dem Nutzer abschließen und die offenen Entscheidungen einholen, erst danach Code ändern. Neue Skripte (Netzwerk-Gate, Zertifikatserneuerung) als eigenständige, wiederverwendbare Bausteine anlegen.

## Repo

Alles liegt bewusst im Wurzelverzeichnis: Skripte und Tests finden einander über `$PSScriptRoot`, und `Prepare-HostRename.ps1` schreibt `HostRename.Checks.psd1` daneben. Nicht in Unterordner verschieben, ohne Code und README mitzuziehen.

- `Prepare-HostRename.ps1`: Setup/Rückbau von Share, Delegation, GPO, optional Bereinigungs-GPO. Konfiguration über Variablen im Block „HIER ANPASSEN“ (keine Konfigurationsdatei).
- `Invoke-HostRename.ps1`: Client-Skript. Exit-Codes: 0 nichts zu tun/-WhatIf, 3010 umbenannt (Neustart nötig), 1 Fehler, 2 Name zu lang (Skip), 4 keine Berechtigung, 5 keine verwendbare Seriennummer.
- `HostRename.Dc.Tests.ps1`, `.Client.Tests.ps1`, `.Local.Tests.ps1`: Pester 5.3+. Dc und Client lesen `HostRename.Checks.psd1`, die das Setup aus den Variablen schreibt (in `.gitignore`, nie committen). `HostRename.Checks.beispiel.psd1` zeigt den Aufbau.
- `tools/Test-GpoReport.ps1`: Diagnose für den GPMC-Bericht (siehe Fallstricke). Eigenständig, nicht Teil des Release-Pakets.
- `.gitattributes`: LF in allen Textdateien. Die `.ps1`/`.psd1` sind **UTF-8 mit BOM** (ohne BOM liest Windows PowerShell 5.1 sie als ANSI). Neue PowerShell-Dateien genauso anlegen.

## Arbeitsregeln des Nutzers (verbindlich)

- Antworten, Kommentare und Hilfetexte auf **Deutsch**.
- **Nichts ohne Auftrag einbauen.** Vor optionalen Änderungen fragen. Beispiele aus dem bisherigen Verlauf: Eine Admin-Gruppe wurde auf Wunsch wieder entfernt, eine Konfigurationsdatei für die Prepare-Variablen wurde angeboten und nicht gewünscht, der Text der Neustart-Meldung „passt so“.
- **Ehrlich über Nicht-Getestetes.** Nichts als bestätigt darstellen, was nicht auf Windows/AD gelaufen ist. Der bisherige Entwicklungsstand wurde in einer Linux-Sandbox mit Mocks geprüft (PowerShell 7, kein Pester, kein AD); die Mocks sind nicht Teil des Repos.
- **Code und README synchron halten.** Die README ist reine Betriebsdokumentation: keine Entwicklungsverläufe und keine Fehlersuch-Geschichten, Änderungen nur als kurze Liste am Ende („Änderungen“).
- Releases nur mit geprüfter Doku.
- Sicherheit: Delegation statt Passwort, keine zusätzliche Admin-Gruppe, „Jeder“ auf NTFS abraten. Keine Umgebungsdaten (OUs, Servernamen, Domänen) im Repo.

## Architektur und Entscheidungen

- **Delegation:** an SELF (`S-1-5-10`) auf Computerobjekten unter den Client-OUs, 8 Rechte: Schreiben `cn`, `name`, `sAMAccountName`, `displayName`, Account Restrictions, Reset password, Validated Writes DNS-Hostname und SPN. Prinzipale immer **per SID** vergleichen, nie per Namen (deutsch: „NT-AUTORITÄT\SELF“).
- **Share** `\\<Server>\HostRename$` (`C:\HostRename`): `scripts` nur lesen, `log` mit `(OI)(CI)(WD,AD,WEA,WA,RA,RC,S)` für Domänencomputer. Der Share wird nur lokal auf dem Fileserver angelegt, Delegation und GPO auf Admin-PC oder DC (`$ShareServer` muss der Fileserver sein).
- **GPO** `COMP - HostRename` (Link wird deaktiviert angelegt): GPP **Files** (Aktion **R**eplace) kopiert das Skript nach `C:\Program Files\HostRename`; GPP **Scheduled Task** `HostRename` (SYSTEM, `S-1-5-18`, S4U) mit Trigger **Systemstart + 5 Min.** und **Registrierung ohne Delay**, Aktion **C**reate; Item-Level-Targeting: Marker nicht vorhanden. Das XML wird von Hand erzeugt (kein GPMC) und folgt GPMC-Beispielen.
- **Registry:** `HKLM\SOFTWARE\HostRename` (Marker, wirkt allein durch Existenz: Completed, ComputerName) und `HKLM\SOFTWARE\HostRenameState` (TargetName, Template; OriginalName, Applied, FutureId nur Nachweis). Bewusst getrennt: Läge der Zustand im Marker-Schlüssel, würde die GPO schon nach der Umbenennung aufhören, Skript und Task anzuwenden, vor der Bereinigung.
- **Bereinigung** (`-Cleanup`): erst Logs flushen und zentral zustellen, dann Marker setzen, Task und Skript löschen, danach lokale Logs. Schlägt die Zustellung fehl, bleibt der Task (`CLEANUP_DEFERRED`). Optionale Bereinigungs-GPO löscht die Registry-Schlüssel per GPP-Registry (Aktion D); Schutz: nur Schlüssel, deren letzter Teil mit `HostRename` beginnt, und nur wenn die Haupt-GPO nicht mehr existiert (`-Force` hebt das auf).
- **Neustart** nur mit `-Reboot` (`$Reboot`): `shutdown.exe /r /t <RebootDelaySeconds> /c <Text> /d p:4:1`. Bei Wartezeit > 0 ist `/f` impliziert, offene Programme werden also geschlossen. Der Meldungstext ist fest codiert.
- **Versionsangabe:** `$ScriptVersion` im Client-Skript steht im START-Eintrag des Logs und muss zur Version in `.NOTES` aller Skripte passen (prüft `HostRename.Local.Tests.ps1`).

## Fallstricke (so gelernt, nicht erneut ausprobieren)

1. **GPMC-Bericht:** Ein `<Delay>` im `RegistrationTrigger` lässt den Reiter „Einstellungen“ der GPO mit „Unbekannter Fehler bei der Erstellung des HTML-Berichts“ scheitern (belegt: Kandidatentest, alle Varianten mit Delay scheitern, derselbe Trigger ohne Delay wird angezeigt). Die GPO wirkt auf den Clients trotzdem. Deshalb der Registrierungs-Trigger **ohne** Delay. Vor Änderungen am Task-XML den Bericht in der GPMC prüfen oder `tools/Test-GpoReport.ps1` (Fehlersuche) bzw. `-Candidates` (Trigger-Konstruktionen) laufen lassen. Die Reihenfolge der Elemente im Task-XML folgt der GPMC (z. B. `Repetition` zuletzt im `CalendarTrigger`).
2. **GPP-Aktion Update beim Task:** Der Task startete nach einem Neustart nicht. Plausible, nicht bewiesene Ursache: Die GPO schreibt ihn beim Hochfahren neu, nach dem Systemstart-Trigger. Daher Standard **Create**. Folge: Änderungen an der Task-Definition (Regel, Neustart-Schalter, Pfade) erreichen vorhandene Tasks nicht; auf noch nicht fertigen Geräten den Task einmal löschen (`Unregister-ScheduledTask -TaskName HostRename -Confirm:$false`). Das Skript selbst aktualisiert die Dateikopie weiter.
3. **GPP-Files mit Aktion Update** scheiterte beim Überschreiben (Ereignis 4117, `0x50`). Daher **Replace**.
4. **Kontoname im Task:** „NT AUTHORITY\System“ funktioniert auf deutschen Clients nicht (Ereignis 1085). Immer `SYSTEM` bzw. die SID.
5. **NTFS auf `log`:** Das Recht „Attribute lesen“ (`RA`) ist nötig, „Schreiben“ allein reichte nicht. Delegation ohne Reset password und Account Restrictions endet mit „Zugriff verweigert“.
6. **PowerShell-Eigenheiten:** `#Requires` muss **nach** dem Comment-Based-Help stehen, sonst wird die Hilfe nicht erkannt. In Pester ist `$Matches` nach `Should -Match` nicht verlässlich (stattdessen `[regex]::Match`). Keine PS7-only-Konstrukte in den Skripten.
7. Die CSE-Liste der GPO wird sortiert eingetragen (Files vor Scheduled Tasks); die Reihenfolge der Verarbeitung auf dem Client ist nicht geprüft.

## Prüfstand

**Im Pilot bestätigt** (Windows 11, deutsche Systemsprache): Delegation und Umbenennen (mit Reset password und Account Restrictions), sprachunabhängiges Task-Konto, Ersetzen der Skriptkopie (Replace), Selbstlöschung von Task und Marker, Aufräumen der lokalen Dateien nach Zustellung der Logs. Die Local-Tests liefen in 5.1 durch (62 von 63; der eine Fehler war ein Testfehler und ist behoben).

**Nicht belegt:**
- Die Dc- und Client-Tests nach den Änderungen am Registrierungs-Trigger (angepasst, aber nie mit Pester auf Windows gelaufen) sowie das Ergebnis früherer Dc-Läufe.
- Der GPMC-Bericht der aktuellen GPO (nur der Kandidat „Systemstart + Registrierung ohne Delay, Create“ war im Test sauber).
- Das Anfügen an das zentrale Log mit exakt dem vom Setup gesetzten Rechteset (nach `icacls <Datei> /reset`), der Roundtrip-Test für das Item-Level-Targeting und die Bereinigungs-GPO (das Registry-XML ist weder gegen eine echte GPMC noch gegen einen Client geprüft).
- Der Start des Tasks in der aktuellen Konstruktion: Der Nutzer berichtet zuletzt, die Lösung getestet zu haben und dass sie funktioniert; die Einzelheiten sind nicht festgehalten. Der Abschnitt „Erprobungsstand“ der README ist deshalb eventuell veraltet: **beim Nutzer nachfragen, was genau bestätigt ist**, und die README danach anpassen.

## Offene Punkte (nur auf Wunsch oder nach Rückfrage anfassen)

- Der Task kann theoretisch starten, bevor die GPO die Skriptkopie angelegt hat; der Folgelauf (Systemstart + 5 Min.) fängt das ab.
- Der Rückgabewert von `shutdown.exe` wird nicht geprüft; ist schon ein Neustart geplant, steht trotzdem „Neustart geplant“ im Log. Der Nutzer hat entschieden, dass der Neustart so bleibt.
- Repo-Themen: Es gibt noch keine `LICENSE` (Lizenz und Sichtbarkeit sind Entscheidung des Nutzers) und keine CI. Möglich wären Syntaxprüfung und PSScriptAnalyzer; die Pester-Tests gegen AD nicht.
- Unbeantwortet geblieben: ob `$TaskItemAction`, `$ShareAccessMode`, `-OuDN` und die Reset-password-Rechte so bleiben. Bis zur Klärung nicht ändern.
- Akzeptierte Restmeldungen: PSScriptAnalyzer meldet bei den Produktivskripten u. a. `PSAvoidUsingWriteHost` (Prepare), `PSUseSingularNouns` und `PSReviewUnusedParameter`. Strict Mode ist nicht aktiviert (in den Mocks mit allen Szenarien identisch, aber nie scharf geschaltet).
- Die Online-Doku (ein separates Dokument, das bisher von Hand mit der README abgeglichen wurde) ist für Claude Code nicht erreichbar; ab jetzt ist das Repo führend.

## Prüfen und Release

Prüfen vor jedem Commit:

```powershell
# Syntax aller Skripte
Get-ChildItem -Recurse -Include *.ps1 | ForEach-Object {
    $e = $null; [void][System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$e)
    if ($e) { "$($_.Name): $($e.Message)" }
}
Invoke-Pester -Path .\HostRename.Local.Tests.ps1 -Output Detailed        # Pester 5.3+ (Install-Module Pester -MinimumVersion 5.3)
Invoke-ScriptAnalyzer -Path . -Recurse
```

Die Dc- und Client-Tests brauchen `HostRename.Checks.psd1`, also vorher `.\Prepare-HostRename.ps1 -Action Setup` (in einer Testumgebung, mit `-WhatIf` zuerst).

Release (Beispiel Version `x.y.z`):
1. Version in `.NOTES` aller Skripte, `$ScriptVersion` in `Invoke-HostRename.ps1`, Kommentar `(Version x.y.z)` in `HostRename.Checks.beispiel.psd1`, Kopfzeile der README (`Version x.y.z · Stand`), Beispiel „HostRename x.y.z: Vorlage …“ in der README und die Änderungsliste anpassen.
2. Local-Tests laufen lassen (prüfen die Versionsgleichheit).
3. Commit, Tag `vx.y.z`, ZIP als Release-Asset anhängen.

## Erste Schritte

1. `README.md` lesen (Betriebsdokumentation) und den Abschnitt „Sicherheit und bekannte Einschränkungen“.
2. Die Local-Tests auf Windows laufen lassen und das Ergebnis festhalten.
3. Den Nutzer fragen, welche der unter „Nicht belegt“ genannten Punkte er inzwischen getestet hat, und den „Erprobungsstand“ der README danach aktualisieren.
