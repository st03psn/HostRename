# Entwicklungsverlauf

[English version](../development-history.md)

Dieses Dokument hält fest, wie HostRename entstanden ist. Es steht bewusst nicht in der README, die reine Betriebsdokumentation ist.

Die frühe Entwicklung fand außerhalb dieses Repositorys statt (in Chat-Sitzungen und einer Linux-Sandbox mit Mocks). Vor dem 3. November 2026 gibt es deshalb keine Commit-Historie. Alles bis Version 1.1.9 ist aus den Übergabenotizen (`CLAUDE.md`), der Änderungstabelle der README und den Dateidaten des gelieferten Pakets rekonstruiert.

## Phase 1 – Aufbau der GPO-Lösung (bis Version 1.1.4)

Ziel: domänengebundene Windows-Clients automatisch nach einer Namensvorlage umbenennen, ohne Passwort im Skript.

Ergebnisse:

- **Client-Skript** `Invoke-HostRename.ps1`: läuft als Scheduled Task unter SYSTEM und benennt Computer und AD-Objekt mit `Rename-Computer` um. Es ist idempotent und schreibt in ein zentrales CSV-Log auf einem Share; ist der Share nicht erreichbar, landen die Einträge in `pending.csv`. Exit-Codes: 0, 3010, 1, 2, 4, 5.
- **Namensvorlagen** `{Name}` und `{Serial}` mit Längenangaben (`{Serial:-8}`), dazu Prefix und Suffix. Regeln für zu lange Namen (`TruncateEnd`, `TruncateStart`, `Skip`). Eine aus der MachineGuid abgeleitete *Zukunfts-ID* ersetzt unbrauchbare oder doppelte Seriennummern.
- **Setup-Skript** `Prepare-HostRename.ps1`: legt Share, AD-Delegation an SELF (8 Rechte, Vergleich per SID) und GPO an und baut sie zurück. Die GPO nutzt GPP Files und einen GPP Scheduled Task; das XML wird von Hand erzeugt. Eine Bereinigungs-GPO ist optional.
- **Bereinigung** (`-Cleanup`): erst die Logs zustellen, dann den Marker setzen, dann Task und Skript entfernen. Scheitert die Zustellung, wird die Bereinigung zurückgestellt (`CLEANUP_DEFERRED`).
- **Pester-Tests** in drei Stufen: Local (ohne AD), Dc und Client.

Lehren aus dieser Phase (ausführlich in `CLAUDE.md`, Abschnitt „Fallstricke“):

- Die Delegation braucht *Reset password* und *Account Restrictions*, sonst scheitert die Umbenennung mit „Zugriff verweigert“.
- Auf dem Log-Ordner ist das NTFS-Recht *Attribute lesen* (`RA`) nötig.
- Auf deutschen Clients muss das Task-Konto `SYSTEM` oder seine SID sein, nie „NT AUTHORITY\System“ (Ereignis 1085).
- `#Requires` muss nach der kommentarbasierten Hilfe stehen.

## Phase 2 – Stabiler Task-Start (Versionen 1.1.5 bis 1.1.9)

Problem: Im Pilot startete der Scheduled Task nach einem Neustart nicht zuverlässig.

Erkenntnisse:

- Mit der GPP-Aktion *Update* startete der Task nach einem Neustart nicht. Plausible, aber nicht bewiesene Ursache: Die GPO schreibt den Task beim Hochfahren neu, nachdem der Systemstart-Trigger schon ausgelöst hat. Die Aktion für den Task ist deshalb jetzt **Create**.
- GPP Files mit *Update* konnte die Datei nicht überschreiben (Ereignis 4117, `0x50`). Die Aktion für die Datei ist deshalb jetzt **Replace**.
- Ein `<Delay>` im Registrierungs-Trigger lässt den GPMC-HTML-Bericht scheitern („Unbekannter Fehler“). Belegt ist das durch einen Kandidatentest (`tools/Test-GpoReport.ps1 -Candidates`). Der Registrierungs-Trigger hat deshalb **keine Verzögerung** mehr.

Version **1.1.9** (30. Oktober 2026) führt das zusammen: Registrierungs-Trigger ohne Verzögerung, Systemstart-Trigger + 5 Minuten, GPP-Aktion Create, kein täglicher Trigger. Neu sind die Schalter `$RegistrationTrigger` und `$RepeatInterval`.

Pilotstand (Windows 11, deutsche Systemsprache): Der Inhaber hat bestätigt, dass **alles Umgesetzte funktioniert**. Das umfasst Delegation, Umbenennen, das sprachunabhängige Task-Konto, Replace, Selbstlöschung, Log-Zustellung und Bereinigung, den Task-Start in der Konstruktion von 1.1.9, das Anfügen an das zentrale Log mit dem Rechteset des Setups, die Dc- und Client-Tests, den GPMC-Bericht, den Roundtrip für das Item-Level-Targeting und die Bereinigungs-GPO.

## Phase 3 – Planung der ACMP-Verteilung (3. November 2026)

Ausgangslage: rund 700 Clients, davon etwa 90 % Notebooks. Unterwegs verbinden sie sich über DirectAccess, im Büro über EAP-TLS-WLAN mit Computerzertifikaten. Die Verteilung soll auf ACMP umgestellt werden.

Der Entwurf `docs/de/ACMP-Umsetzungsplan.md` benennt das zentrale Risiko: Nach der Umbenennung passt das Zertifikat des Geräts zu keinem Konto mehr (starke Zuordnung, KB5014754). Das WLAN funktioniert dann erst wieder, wenn ein neues Zertifikat ausgestellt ist. Umbenannt werden darf deshalb nur über LAN-Kabel oder DirectAccess. Bausteine: Netzwerk-Gate, ACMP-Modus im Client-Skript, Zertifikatserneuerung und ein ACMP Client Command.

## Phase 4 – Repository und Version 1.2.0 (ab 3. November 2026)

- Repository auf GitHub mit MIT-Lizenz angelegt. Zuerst wurde das allgemeine Grundgerüst (README, Vorlagen, CI) gemergt ([st03psn/HostRename#1](https://github.com/st03psn/HostRename/pull/1)).
- Das Paket 1.1.9 als Ausgangsstand importiert. Die Konventionen des Projekts haben Vorrang vor dem Grundgerüst: Dateien bleiben im Wurzelverzeichnis, LF-Zeilenenden, UTF-8 mit BOM.
- Entscheidungen des Inhabers:
  - Englisch ist die Hauptsprache für Skripte und Doku; deutsche Fassungen gibt es als Alternative.
  - GPO und ACMP sind alternative Verteilungswege.
  - Umbenannt werden darf über LAN und DirectAccess.
  - Lokale Logs liegen im ACMP-Modus unter `C:\ProgramData\HostRename`.
  - Das zentrale CSV-Log bleibt als Option.
  - Alte Zertifikate werden nur per Schalter entfernt.
  - Gerätetests sind Teil der Testphasen statt Vorbedingung.
- Die Arbeiten für 1.2.0 stehen in [roadmap.md](roadmap.md).

## Phase 5 – Wrapper, Simulation, Neugliederung und Releases (3. November 2026)

- **Korrekturen aus dem Review:** sicheres Abschalten des zentralen Logs (`''`, leere und nicht absolute Pfade), abgesicherter ACMP-Log-Ordner (Prüfung von Besitzer und Analysepunkt, geschützte ACL) und Ablehnung eines 32-Bit-Prozesses auf 64-Bit-Windows.
- **Rollout-Doku:** ACMP-Rollout und Prüfung eines Laufs (ACMP-Tests AC-A bis AC-D), EN + DE.
- **End-to-End-Simulation** (`HostRename.Simulation.Tests.ps1`): kopiert die echten Skripte flach in einen simulierten ACMP-Cache und führt sie mit den Snippets für Zustandsprüfung und Status aus der Doku aus (Registry im Speicher; CIM, AD, Netzwerk und Zertifikatsspeicher gemockt). Danach geändert: Dauerhafte Fehler (2, 4, 5) führen nicht mehr zu endlosen Wiederholungen (die Zustandsprüfung endet mit `phase=permanent`, bis der Wert `LastExitCode` entfernt wird), und die Cleanup-Ereignisse gehen auch auf stdout. Unter Windows PowerShell 5.1 liefert X509 `GetNameInfo` des .NET Framework den Subject-CN statt des ersten DNS-Namens im SAN, deshalb prüft der Test das SAN direkt (die Skripte werten das SAN selbst aus und waren nicht betroffen).
- **ACMP-Wrapper** `Invoke-AcmpHostRename.ps1`: führt den ganzen Ablauf des Client-Commands in einem Skriptlauf je ACMP-Aufruf aus und ruft dazu die unveränderten Skripte im selben Prozess auf; der Client-Command reagiert nur noch auf 3010 und 20. Die Simulation deckt ihn mit den Fällen W1–W9 ab. Ein **Starterkit** (EN + DE) übergibt den ersten ACMP-Test an einen Tester, der das Projekt nicht kennt; die Umgebungswerte ermittelt der Tester selbst.
- **Neugliederung:** Kern und GPO bleiben im Wurzelverzeichnis; Tests des Kerns in `tests/`, werkzeugneutrale Bausteine in `components/`, alles zu ACMP in `deployments/acmp/`, übergreifende Dokumente in `docs/`. Das ACMP-Release-Paket ist flach; der Wrapper sucht seine Skripte deshalb zuerst im eigenen Ordner und erst dann im Repository-Aufbau.
- **Website** (`site/`, EN + DE) über GitHub Pages veröffentlicht.
- **Releases:** Ein manueller Release-Workflow baut je Dateiliste ein ZIP (`gpo`, flaches `acmp`; Einzelliste im alten Format für v1.1.9). Erkenntnis: Das Workflow-Token bekommt HTTP 403, wenn es ein Tag auf einem älteren Commit anlegen muss; für v1.1.9 (Commit `6605dc8`) scheiterte sogar das Anlegen des Entwurfs. Der Workflow legt deshalb standardmäßig Entwürfe an, akzeptiert ein vorhandenes Tag auf dem Quell-Commit und vervollständigt ein Release, das der Inhaber von Hand veröffentlicht hat. Das Tag für v1.1.9 hat der Inhaber über einen Hilfs-Branch in der Weboberfläche angelegt. Veröffentlicht: **v1.1.9** (aktuelles Voll-Release, im Pilot bestätigte GPO-Lösung, deutsch) und **v1.2.0** (Pre-Release, englisch, Pakete für GPO und ACMP).
- Noch offen: die Gerätetests (T3); nichts Neues aus 1.2.0 ist bisher auf einem echten Gerät oder in ACMP gelaufen.
