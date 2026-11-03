# HostRename über ACMP

[English version](README.md)

HostRename kann statt über die GPO mit dem Verteilwerkzeug ACMP (Aagon) verteilt werden: Ein ACMP-Client-Command führt die Skripte als SYSTEM auf dem Client aus, ACMP steuert den Neustart (Exit-Code 3010 ist das Signal), und umbenannt wird nur über LAN-Kabel oder DirectAccess (Netzwerk-Gate). Auf WLAN-Geräten wird nach Umbenennung und Neustart das Computerzertifikat erneuert. **GPO und ACMP sind alternative Verteilverfahren: nie beide auf demselben Gerät.**

Empfohlen: Der Wrapper `Invoke-AcmpHostRename.ps1` führt den ganzen Ablauf des Client-Commands (Zustandsprüfung, Gate, Umbenennung, Zertifikat, Cleanup) in einem Skriptlauf je ACMP-Aufruf aus; der Client-Command überträgt dann nur die Skripte, startet den Wrapper in der 64-Bit-PowerShell und reagiert auf dessen Exit-Code (3010 Neustart-Dialog, 20 Dialog „LAN-Kabel“). Alle Parameter und Exit-Codes: `Get-Help .\Invoke-AcmpHostRename.ps1 -Full`.

## Paketinhalt

Das Release hat ein eigenes ACMP-Paket, `HostRename-<version>-acmp.zip`. Es ist **flach**: Die Skripte liegen in einem Ordner, so wie ACMP sie in seinen Cache auf dem Client überträgt.

| Datei | Zweck | Gehört ins Dateirepository von ACMP |
| --- | --- | --- |
| `Invoke-AcmpHostRename.ps1` | Wrapper: der ganze Ablauf in einem Lauf | ja |
| `Invoke-HostRename.ps1` | Client-Skript (`-Deployment Acmp`): Umbenennung, Cleanup | ja |
| `Test-DeploymentNetwork.ps1` | Netzwerk-Gate (werkzeugneutraler Baustein) | ja |
| `Update-ComputerCertificate.ps1` | Zertifikatserneuerung (werkzeugneutraler Baustein; nur wenn WLAN-Geräte betroffen sind) | ja |
| `Prepare-HostRename.ps1` | setzt einmalig auf einem Admin-PC oder DC die Delegation (`-Action Setup -Component Delegation`); den Share nur, wenn das zentrale Log genutzt wird | nein |
| `docs/`, `README.md`, `README.de.md`, `LICENSE`, `SECURITY.md` | Dokumentation | nein |

Die Skripte sind UTF-8 mit BOM; unverändert übertragen. In diesem Repository liegt der Wrapper hier, `Invoke-HostRename.ps1` und `Prepare-HostRename.ps1` im Wurzelverzeichnis und die Bausteine in `components/`; der Wrapper findet sie dort auch, wenn er aus dem Repository gestartet wird (sein eigener Ordner hat immer Vorrang).

## Dokumentation

| Dokument | Inhalt |
| --- | --- |
| [docs/de/acmp-anleitung.md](docs/de/acmp-anleitung.md) | Aufbau des Client-Commands Schritt für Schritt, Parameter, Exit-Code-Vertrag |
| [docs/de/acmp-starterkit.md](docs/de/acmp-starterkit.md) | Übergabe für einen ersten ACMP-Test durch jemanden, der das Projekt nicht kennt |
| [docs/de/acmp-rollout.md](docs/de/acmp-rollout.md) | Rollout-Prozess (Container, Wellen, Abnahmekriterien) und Prüfung der Läufe (ACMP-Tests AC-A bis AC-D) |
| [docs/de/testplan.md](docs/de/testplan.md) | Gerätetests: Gate, Zertifikat, ACMP und ein Regressionsblock für den GPO-Weg |
| [docs/de/ACMP-Umsetzungsplan.md](docs/de/ACMP-Umsetzungsplan.md) | Hintergrund und Entscheidungen |

Die englischen Fassungen liegen in [docs/](docs/acmp-guide.md). Betriebsdokumentation des Kerns (Delegation, Share, Logging, Registry): die [Haupt-README](../../README.de.md).

## Tests

Pester 5.3+, kein AD nötig (jede Plattform):

```powershell
Invoke-Pester -Path .\deployments\acmp\tests -Output Detailed
```

| Datei | Prüft |
| --- | --- |
| `tests/HostRename.Acmp.Tests.ps1` | ACMP-Modus von `Invoke-HostRename.ps1` (Mocks): `-Deployment`, lokaler Ordner, abgeschaltetes zentrales Log, Cleanup-Entscheidungen, Berichtswerte |
| `tests/HostRename.Simulation.Tests.ps1` | Ende-zu-Ende-Simulation des Client-Commands und des Wrappers mit den echten Skripten (flach in einen simulierten ACMP-Cache kopiert) und den dokumentierten Snippets; ändert nichts am Rechner |

## Erprobungsstand

Alles hier ist neu in 1.2.0 und **nur mit Mocks und in der Simulation getestet** (Linux, PowerShell 7, und CI). Nichts davon ist bisher auf echten Windows-Geräten, über DirectAccess, mit WLAN/AD CS oder in ACMP gelaufen; wie ACMP den Exit-Code 3010 behandelt, ist Gerätetest A1. Die Gerätetests stehen in [docs/de/testplan.md](docs/de/testplan.md).
