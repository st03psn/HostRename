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
