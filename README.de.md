# HostRename

[🇬🇧 English version](README.md)

**HostRename** ist ein PowerShell-Tool zum Umbenennen des Computernamens (Hostname) von Windows-Rechnern – lokal oder remote, in Arbeitsgruppen oder in einer Active-Directory-Domäne.

> **Status:** frühe Entwicklungsphase. Die folgenden Funktionen beschreiben den geplanten Umfang; noch ist nicht alles umgesetzt. Was bereits verfügbar ist, steht im [CHANGELOG](CHANGELOG.md).

## Funktionen (geplant)

- Umbenennen des lokalen oder eines entfernten Windows-Rechners
- Unterstützung für Arbeitsgruppen- und AD-Domänenrechner (mit Domänen-Anmeldedaten)
- Prüfung des neuen Namens (NetBIOS-Grenze von 15 Zeichen, erlaubte Zeichen, keine rein numerischen Namen)
- Unterstützung von `-WhatIf` / `-Confirm` für sichere Testläufe
- Optionaler automatischer Neustart nach dem Umbenennen
- Massenumbenennung per CSV-Datei (`OldName,NewName`)
- Protokollierung aller Aktionen

## Voraussetzungen

- Windows 10 / 11 oder Windows Server 2016 und neuer
- Windows PowerShell 5.1 oder PowerShell 7.x
- Administratorrechte auf dem Zielrechner
- Bei Domänenrechnern: ein Konto, das Computerobjekte im AD umbenennen darf
- Für Remote-Umbenennungen: aktiviertes WinRM / PowerShell Remoting auf dem Ziel

## Installation

```powershell
git clone https://github.com/st03psn/HostRename.git
cd HostRename
```

Falls die Skriptausführung blockiert ist, für die aktuelle Sitzung erlauben:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

## Verwendung

> Die Schnittstelle ist noch nicht final; die Beispiele zeigen die geplante Nutzung.

```powershell
# Lokalen Rechner umbenennen und neu starten
.\src\HostRename.ps1 -NewName "PC-VERTRIEB-01" -Restart

# Testlauf
.\src\HostRename.ps1 -NewName "PC-VERTRIEB-01" -WhatIf

# Domänenrechner remote umbenennen
.\src\HostRename.ps1 -ComputerName "ALTER-PC" -NewName "PC-VERTRIEB-01" -DomainCredential (Get-Credential)

# Massenumbenennung per CSV
.\src\HostRename.ps1 -CsvPath .\rename.csv
```

Intern baut HostRename auf dem eingebauten Cmdlet `Rename-Computer` auf.

## Namensregeln

| Regel | Detail |
|-------|--------|
| Länge | 1–15 Zeichen (NetBIOS-Grenze) |
| Zeichen | Buchstaben `A–Z`, Ziffern `0–9`, Bindestrich `-` |
| Nicht erlaubt | Rein numerische Namen, Bindestrich am Anfang/Ende, Leerzeichen, `\ / : * ? " < > \| . ,` |

## Projektstruktur

```
HostRename/
├── src/          # PowerShell-Skripte / Modul
├── tests/        # Pester-Tests
├── .github/      # Issue-/PR-Vorlagen, CI-Workflow
├── CHANGELOG.md
├── CONTRIBUTING.md
├── SECURITY.md
└── LICENSE
```

## Entwicklung

```powershell
Install-Module PSScriptAnalyzer, Pester -Scope CurrentUser
Invoke-ScriptAnalyzer -Path .\src -Recurse
Invoke-Pester -Path .\tests
```

Details siehe [CONTRIBUTING.md](CONTRIBUTING.md).

## Mitwirken

Issues und Pull Requests sind willkommen. Bitte vorher [CONTRIBUTING.md](CONTRIBUTING.md) lesen.

## Sicherheit

Sicherheitslücken bitte vertraulich melden – siehe [SECURITY.md](SECURITY.md).

## Lizenz

[MIT](LICENSE) © 2026 st03psn
