# Roadmap: Version 1.2.0 – ACMP als alternativer Verteilungsweg

[English version](../roadmap.md) · Hintergrund: [Entwicklungsverlauf](entwicklungsverlauf.md), [ACMP-Umsetzungsplan](ACMP-Umsetzungsplan.md)

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

Testen ist Teil des Plans. Gerätetests lassen sich nicht vollständig vorab planen; der Testplan ([test-plan.md](test-plan.md)) listet die Fälle, und die Ergebnisse fließen in Code und Doku zurück.

| Phase | Was | Wo | Wer |
| --- | --- | --- | --- |
| T1 | Syntax, Local-Tests, neue Pester-Tests (Mocks) | Linux-Sandbox (PowerShell 7) | Claude, automatisch |
| T2 | Dieselben Tests plus die Windows-spezifischen Local-Tests, PSScriptAnalyzer | GitHub Actions `windows-latest` (Windows PowerShell 5.1 und 7) | CI, automatisch bei jedem Push |
| T3 | Gerätetests: Gate an LAN/DA/WLAN/offline; Umbenennen über LAN und DA; WLAN vor/nach Neustart und nach Zertifikatserneuerung; 802.1X am LAN-Port; ACMP-Verhalten (Exit-Codes, Dialoge, Dublette) | Testgeräte | Inhaber (nach [test-plan.md](test-plan.md)) |
| T4 | Trockenlauf `-WhatIf` über ACMP auf allen rund 700 Geräten, danach die Funde bereinigen | Produktion | Inhaber |
| T5 | Rollout in Wellen: etwa 20 → etwa 100 → Rest | Produktion | Inhaber |

Ergebnisse aus T3, die Änderungen erfordern (z. B. andere Exit-Codes oder eine andere Erkennung), fließen als Korrekturen in die Arbeitspakete 6–9 zurück.

## Hier nicht automatisierbar

- Alles, was AD, AD CS, DirectAccess, echtes WLAN/802.1X oder ACMP braucht. Dieser Code ist nur mit Mocks getestet, und die Doku sagt das.
- Der Bau des ACMP Client Commands in der ACMP-Konsole. Die Anleitung beschreibt ihn Schritt für Schritt.
- Die Neustart-Frist in ACMP. Sie wird in T3 festgelegt.

## Status

Wird am Ende der Arbeiten an 1.2.0 aktualisiert, siehe Abschnitt am Ende dieser Datei.
