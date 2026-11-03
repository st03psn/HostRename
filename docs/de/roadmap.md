# Roadmap: Version 1.2.0 – ACMP als alternativer Verteilungsweg

[English version](../roadmap.md) · Hintergrund: [Entwicklungsverlauf](entwicklungsverlauf.md), [ACMP-Umsetzungsplan](../../deployments/acmp/docs/de/ACMP-Umsetzungsplan.md)

## Ziel

HostRename lässt sich entweder per **GPO** (unverändert wie in 1.1.9) oder per **ACMP** verteilen. ACMP benennt nur über LAN-Kabel oder DirectAccess um. Danach erneuert es das WLAN-Computerzertifikat und meldet den Status zurück. Die neuen Bausteine (Netzwerk-Gate, Zertifikatserneuerung) sind für andere Verteilungen wiederverwendbar.

## Aufteilung auf die Modelle

Jede Aufgabe bekommt das Modell, das sie braucht. Mechanisches geht an das günstigste Modell, das es zuverlässig kann. Entwurf und sicherheitsrelevanter Code gehen an das stärkste Modell. Jedes Ergebnis wird durch Tests und ein abschließendes unabhängiges Review geprüft.

| Modell | Einsatz | Grund |
| --- | --- | --- |
| **Opus** | Planung, Koordination, neue Skripte mit Windows-/PKI-/Netzwerk-Feinheiten (Netzwerk-Gate, Zertifikatserneuerung), abschließendes Review, Release | Braucht Urteilsvermögen: Randfälle, Kompatibilität mit PS 5.1, Lokalisierung, Sicherheit |
| **Sonnet** | Übersetzung von Skripten und Doku, klar spezifizierte Codeänderungen (ACMP-Modus), Testfälle, Betriebsdoku | Viel Umfang mit klaren Regeln; gute Qualität bei geringeren Kosten |
| **Haiku** | Rein mechanische Aufgaben (Versionsnummer an allen Stellen, Vorlagen und CI-Konfiguration anpassen) | Kleine, regelbasierte Änderungen; das Ergebnis prüfen die Local-Tests |

## Arbeitspakete

| Nr. | Arbeitspaket | Modell | Abhängig von | Automatische Prüfung |
| --- | --- | --- | --- | --- |
| 1 | Paket 1.1.9 importieren, Konflikte mit dem Grundgerüst auflösen | Opus | – | Local-Tests 43/63 unter Linux (die 20 Fehler betreffen nur Windows) |
| 2 | Entwicklungsverlauf dokumentieren, diese Roadmap schreiben | Opus | 1 | – |
| 3 | Client-Skript und Local-/Client-Tests ins Englische übersetzen | Sonnet | 1 | Local-Tests unverändert, Syntaxprüfung |
| 4 | Setup-Skript, Dc-Tests, `tools/` und Beispiel-psd1 ins Englische übersetzen | Sonnet | 1 | Syntaxprüfung, Hilfe lesbar |
| 5 | README (EN + DE), CLAUDE.md (EN), ACMP-Plan (EN + DE) | Sonnet | 1 | Review |
| 6 | Neu: Netzwerk-Gate `Test-DeploymentNetwork.ps1` + Tests | Opus | 1 | Pester (Mocks) |
| 7 | Neu: Zertifikatserneuerung `Update-ComputerCertificate.ps1` + Tests | Opus | 1 | Pester (echte Testzertifikate, Mocks) |
| 8 | ACMP-Modus im Client-Skript (`-Deployment Acmp`) + Tests | Sonnet | 3 | Pester (Mocks) |
| 9 | ACMP-Anleitung (Client Command, Exit-Code-Vertrag, Bericht) und Testplan für die Gerätetests | Sonnet | 6, 7, 8 | Review |
| 10 | Version 1.2.0 überall, CI auf Windows-Runner, Vorlagen/CONTRIBUTING anpassen | Haiku | 3–8 | Local-Tests prüfen die Versionsgleichheit |
| 11 | Unabhängiges Review der Gesamtänderung, Korrekturen | Opus | 1–10 | Alle Tests |
| 12 | Commit, PR, Merge nach `main` | Opus | 11 | CI |

## Testphasen

Testen ist Teil des Plans. Gerätetests lassen sich nicht vollständig vorab planen; der Testplan ([testplan.md](../../deployments/acmp/docs/de/testplan.md)) listet die Fälle, und die Ergebnisse fließen in Code und Doku zurück.

| Phase | Was | Wo | Wer |
| --- | --- | --- | --- |
| T1 | Syntax, Local-Tests, neue Pester-Tests (Mocks) | Linux-Sandbox (PowerShell 7) | Claude, automatisch |
| T2 | Dieselben Tests plus die Windows-spezifischen Local-Tests, PSScriptAnalyzer | GitHub Actions `windows-latest` (Windows PowerShell 5.1 und 7) | CI, automatisch bei jedem Push |
| T3 | Gerätetests: Gate an LAN/DA/WLAN/offline; Umbenennen über LAN und DA; WLAN vor/nach Neustart und nach Zertifikatserneuerung; 802.1X am LAN-Port; ACMP-Verhalten (Exit-Codes, Dialoge, Dublette) | Testgeräte | Inhaber (nach [testplan.md](../../deployments/acmp/docs/de/testplan.md)) |
| T4 | Trockenlauf `-WhatIf` über ACMP auf allen rund 700 Geräten, danach die Funde bereinigen | Produktion | Inhaber |
| T5 | Rollout in Wellen: etwa 20 → etwa 100 → Rest | Produktion | Inhaber |

Ergebnisse aus T3, die Änderungen erfordern (z. B. andere Exit-Codes oder eine andere Erkennung), fließen als Korrekturen in die Arbeitspakete 6–9 zurück.

## Hier nicht automatisierbar

- Alles, was AD, AD CS, DirectAccess, echtes WLAN/802.1X oder ACMP braucht. Dieser Code ist nur mit Mocks getestet, und die Doku sagt das.
- Der Bau des ACMP Client Commands in der ACMP-Konsole. Die Anleitung beschreibt ihn Schritt für Schritt.
- Die Neustart-Frist in ACMP. Sie wird in T3 festgelegt.

## Status (3. November 2026)

| Nr. | Status | Hinweise |
| --- | --- | --- |
| 1–2 | erledigt | Ausgangsstand importiert, Verlauf und Roadmap geschrieben |
| 3–5 | erledigt | Skripte und Doku auf Englisch; die Übersetzung hat keine Code-Tokens verändert; deutsche Fassungen in `README.de.md` und `docs/de/` |
| 6 | erledigt | Netzwerk-Gate, mit Mocks getestet |
| 7 | erledigt | Zertifikatserneuerung, mit Mocks und echten Testzertifikaten getestet |
| 8 | erledigt | ACMP-Modus, optionales zentrales Log (`-NoCentralLog`), Berichtswerte |
| 9 | erledigt | ACMP-Anleitung und Testplan für Gerätetests |
| 10 | erledigt | Version 1.2.0, CI, Vorlagen |
| 11 | erledigt | Unabhängiges Review. Behoben: unsicheres Abschalten des zentralen Logs, von Benutzern beschreibbarer ACMP-Log-Ordner (jetzt abgesichert), Erkennung eines 32-Bit-Prozesses, Umgang mit IPv6-Adressen, Fehler in der Doku |
| 12 | erledigt | PR nach `main` |
| 13 | erledigt (nach dem ursprünglichen Plan ergänzt) | ACMP-Rollout und Prüfung eines Laufs (`deployments/acmp/docs/de/acmp-rollout.md`, EN + DE) |
| 14 | erledigt (ergänzt) | End-to-End-Simulation des ACMP-Ablaufs (`HostRename.Simulation.Tests.ps1`, Fälle S1–S12 und W1–W9) |
| 15 | erledigt (ergänzt) | ACMP-Wrapper `Invoke-AcmpHostRename.ps1` und Starterkit für einen ersten ACMP-Tester (EN + DE); Cleanup-Ereignisse auf stdout; dauerhafte Fehler (2, 4, 5) stoppen den Client-Command bis zur Freigabe |
| 16 | erledigt (ergänzt) | Repository neu gegliedert: `tests/`, `components/`, `deployments/acmp/`; je Verteilverfahren ein Release-Paket (GPO, flaches ACMP-Paket) |
| 17 | erledigt (ergänzt) | Release-Workflow und Release Notes. Veröffentlicht: v1.1.9 (aktuelles Voll-Release, GPO-Lösung aus Commit `6605dc8`, deutsch) und v1.2.0 (Pre-Release, Pakete `gpo` und `acmp`) |
| 18 | erledigt (ergänzt) | Website online unter https://st03psn.github.io/HostRename/ (EN + DE), gebaut aus `site/` |

Teststand der automatischen Phasen:

- **T1 (Linux, PowerShell 7, Pester 5.9; nach der Neugliederung):** Local 51 bestanden, 20 fehlgeschlagen, 5 übersprungen. Die Fehler sind reine Windows-Tests, die T2 abdeckt. Network 89 bestanden, 1 übersprungen. Certificate 69 bestanden. Acmp 83 bestanden. Simulation 70 bestanden.
- **T2 (GitHub Actions, Windows PowerShell 5.1 und 7, Pester 6):** grün auf `main`, einschließlich der reinen Windows-Tests aus Local und der Simulation.
- **Simulation (`HostRename.Simulation.Tests.ps1`, Teil von T1 und T2):** führt die echten Skripte und die dokumentierten Snippets für Zustandsprüfung und Status so verkettet aus wie den ACMP-Client-Command, über alle Phasen (LAN, DirectAccess, WLAN mit Zertifikatserneuerung, Warten am Gate, fehlende Delegierung, Namenskollision, unbrauchbare Seriennummer, Name passt schon, 32-Bit-Prozess, vorbereiteter Log-Ordner, GPO-Regression). Die Umgebung ist simuliert (Registry im Speicher; CIM, AD, Netzwerk, Zertifikatsspeicher und CA gemockt); das zentrale Log wird nicht simuliert. Sie zeigt, dass die Skripte und der dokumentierte Ablauf zusammenpassen; die Gerätetests in T3 ersetzt sie nicht.

**Als Nächstes: T3, Gerätetests durch den Inhaber** (die Gerätetests entscheiden, ob v1.2.0 ein Voll-Release werden kann) nach [testplan.md](../../deployments/acmp/docs/de/testplan.md). Nichts aus 1.2.0 ist bisher auf einem echten Domänen-Client, über DirectAccess, mit WLAN/AD CS oder in ACMP gelaufen.
