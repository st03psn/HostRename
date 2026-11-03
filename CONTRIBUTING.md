# Contributing / Mitwirken

*[Deutsch weiter unten](#deutsch)*

## English

Thanks for your interest in HostRename!

1. **Open an issue first** for larger changes so we can discuss the approach.
2. Fork the repository and create a branch: `feature/<short-description>` or `fix/<short-description>`.
3. Follow the code style:
   - Use approved verbs (`Get-Verb`) and full cmdlet names – no aliases.
   - Add comment-based help (`.SYNOPSIS`, `.DESCRIPTION`, `.PARAMETER`, `.EXAMPLE`) to every function.
   - Support `-WhatIf`/`-Confirm` (`SupportsShouldProcess`) for anything that changes the system.
   - 4 spaces indentation, UTF-8 encoding (see `.editorconfig`).
4. Make sure the checks pass locally:
   ```powershell
   Invoke-ScriptAnalyzer -Path .\src -Recurse -Settings .\PSScriptAnalyzerSettings.psd1
   Invoke-Pester -Path .\tests
   ```
5. Add a Pester test for new behaviour and an entry under `Unreleased` in `CHANGELOG.md`.
6. Open a pull request and fill in the template.

**Never test renames on production machines** – use a VM or `-WhatIf`.

## Deutsch

Danke für dein Interesse an HostRename!

1. **Bei größeren Änderungen zuerst ein Issue eröffnen**, um den Ansatz abzustimmen.
2. Repository forken und einen Branch anlegen: `feature/<kurzbeschreibung>` oder `fix/<kurzbeschreibung>`.
3. Code-Stil einhalten:
   - Zugelassene Verben (`Get-Verb`) und vollständige Cmdlet-Namen verwenden – keine Aliase.
   - Jede Funktion mit kommentarbasierter Hilfe versehen (`.SYNOPSIS`, `.DESCRIPTION`, `.PARAMETER`, `.EXAMPLE`).
   - Für systemverändernde Aktionen `-WhatIf`/`-Confirm` unterstützen (`SupportsShouldProcess`).
   - 4 Leerzeichen Einrückung, UTF-8-Kodierung (siehe `.editorconfig`).
4. Prüfungen lokal ausführen:
   ```powershell
   Invoke-ScriptAnalyzer -Path .\src -Recurse -Settings .\PSScriptAnalyzerSettings.psd1
   Invoke-Pester -Path .\tests
   ```
5. Für neues Verhalten einen Pester-Test und einen Eintrag unter `Unreleased` in `CHANGELOG.md` ergänzen.
6. Pull Request öffnen und die Vorlage ausfüllen.

**Umbenennungen niemals auf Produktivsystemen testen** – eine VM oder `-WhatIf` verwenden.
