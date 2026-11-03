# Contributing / Mitwirken

*[Deutsch weiter unten](#deutsch)*

## English

Thanks for your interest in HostRename!

### Project facts

- All scripts and Pester test files are in the **repository root** (`Invoke-HostRename.ps1`, `Prepare-HostRename.ps1`, `Test-DeploymentNetwork.ps1`, `Update-ComputerCertificate.ps1`, `HostRename.*.Tests.ps1`); `tools/` holds helper scripts.
- Target: **Windows PowerShell 5.1**. PowerShell 7 works in addition, but code must run on 5.1.
- Files: `.ps1` and `.psd1` are **UTF-8 with BOM** and use **LF** line endings (see `.gitattributes`). CI rejects files without BOM and files with CRLF. Do not let your editor convert line endings.
- Deployment methods: **GPO** or **ACMP** (alternatives, never both active on the same device).
- Supported environments: **AD domain-joined clients**. Workgroup is not supported.
- Documentation: **English is primary**; German versions are kept in sync (`README.de.md`, `docs/de/`).

### Workflow

1. **Open an issue first** for larger changes so we can discuss the approach.
2. Fork the repository and create a branch: `feature/<short-description>` or `fix/<short-description>`.
3. Follow the code conventions below.
4. Run the checks locally (see next section).
5. Add a Pester test for new behaviour, and an entry in the list of changes at the end of `README.md` and `README.de.md` if behaviour changed.
6. Open a pull request and fill in the template.

### Checks to run locally

Run from the repository root in Windows PowerShell 5.1 (and ideally PowerShell 7 as well). Pester 5.3 or newer is required:

```powershell
Install-Module Pester -MinimumVersion 5.3 -SkipPublisherCheck -Scope CurrentUser
Install-Module PSScriptAnalyzer -SkipPublisherCheck -Scope CurrentUser

# 1. Parse check of all scripts (must print nothing)
Get-ChildItem -Recurse -File -Include *.ps1 | ForEach-Object {
    $e = $null; [void][System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$e)
    if ($e) { "$($_.Name): $($e.Message)" }
}

# 2. Pester tests that do not need Active Directory
Import-Module Pester -MinimumVersion 5.3 -Force
Invoke-Pester -Path .\HostRename.Local.Tests.ps1, .\HostRename.Network.Tests.ps1, .\HostRename.Certificate.Tests.ps1, .\HostRename.Acmp.Tests.ps1 -Output Detailed

# 3. Static analysis (errors must be zero; warnings are accepted)
Invoke-ScriptAnalyzer -Path . -Recurse -Severity Error
```

CI runs the same checks on `powershell` (5.1) and `pwsh` (7), and additionally checks that `.ps1`/`.psd1` files start with a BOM and contain no CR characters.

**Dc and Client tests** (`HostRename.Dc.Tests.ps1`, `HostRename.Client.Tests.ps1`) need a real AD/GPO environment and the test configuration `HostRename.Checks.psd1`, which `Prepare-HostRename.ps1 -Action Setup` writes. Run them only in a **test domain**, never in production:

```powershell
.\Prepare-HostRename.ps1 -Action Setup -WhatIf   # first: show what would be changed
.\Prepare-HostRename.ps1 -Action Setup           # then, in the test domain only
```

These tests are **not** run in CI.

### Code conventions

- Use approved verbs (`Get-Verb`) and full cmdlet names – no aliases.
- Put the comment-based help (`.SYNOPSIS`, `.DESCRIPTION`, `.PARAMETER`, `.EXAMPLE`) **before** the `#Requires` statement.
- Support `-WhatIf`/`-Confirm` (`SupportsShouldProcess`) for anything that changes the system.
- No PowerShell 7-only syntax (no ternary `? :`, no `??`/`?.`, no `&&`/`||` pipeline chains, no `ForEach-Object -Parallel`), so the code runs on Windows PowerShell 5.1.
- Compare security principals (users, groups, computer accounts) by **SID**, never by name. Names are localized and can change.
- No environment data in the repository: no OUs, server or computer names, domain names, IP addresses or user names in code, tests, documentation or example output. Use neutral placeholders such as `example.com` or `<OU>`.
- Indentation and encoding as in the existing files; see the project facts above for BOM and line endings.

### Testing safety

**Never test renames on production machines.** Use a test VM, a test domain and `-WhatIf`.

## Deutsch

Danke für dein Interesse an HostRename!

### Projektfakten

- Alle Skripte und Pester-Testdateien liegen im **Wurzelverzeichnis des Repositorys** (`Invoke-HostRename.ps1`, `Prepare-HostRename.ps1`, `Test-DeploymentNetwork.ps1`, `Update-ComputerCertificate.ps1`, `HostRename.*.Tests.ps1`); im Ordner `tools/` liegen Hilfsskripte.
- Zielumgebung: **Windows PowerShell 5.1**. PowerShell 7 funktioniert zusätzlich, der Code muss aber unter 5.1 laufen.
- Dateien: `.ps1` und `.psd1` sind **UTF-8 mit BOM** und verwenden **LF**-Zeilenenden (siehe `.gitattributes`). Die CI lehnt Dateien ohne BOM und Dateien mit CRLF ab. Der Editor darf die Zeilenenden nicht umwandeln.
- Verteilungsmethoden: **GPO** oder **ACMP** (Alternativen, niemals beide auf demselben Gerät aktiv).
- Unterstützte Umgebung: **AD-domänenbeigetretene Clients**. Arbeitsgruppen werden nicht unterstützt.
- Dokumentation: **Englisch ist die Hauptsprache**; die deutschen Fassungen werden mitgepflegt (`README.de.md`, `docs/de/`).

### Vorgehen

1. **Bei größeren Änderungen zuerst ein Issue eröffnen**, um den Ansatz abzustimmen.
2. Repository forken und einen Branch anlegen: `feature/<kurzbeschreibung>` oder `fix/<kurzbeschreibung>`.
3. Die Code-Konventionen unten einhalten.
4. Prüfungen lokal ausführen (siehe nächster Abschnitt).
5. Für neues Verhalten einen Pester-Test ergänzen; bei geändertem Verhalten einen Eintrag in der Liste der Änderungen am Ende von `README.md` und `README.de.md`.
6. Pull Request öffnen und die Vorlage ausfüllen.

### Lokal auszuführende Prüfungen

Im Wurzelverzeichnis des Repositorys in Windows PowerShell 5.1 ausführen (idealerweise zusätzlich in PowerShell 7). Pester 5.3 oder neuer ist erforderlich:

```powershell
Install-Module Pester -MinimumVersion 5.3 -SkipPublisherCheck -Scope CurrentUser
Install-Module PSScriptAnalyzer -SkipPublisherCheck -Scope CurrentUser

# 1. Syntax-Prüfung aller Skripte (darf nichts ausgeben)
Get-ChildItem -Recurse -File -Include *.ps1 | ForEach-Object {
    $e = $null; [void][System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$e)
    if ($e) { "$($_.Name): $($e.Message)" }
}

# 2. Pester-Tests, die kein Active Directory brauchen
Import-Module Pester -MinimumVersion 5.3 -Force
Invoke-Pester -Path .\HostRename.Local.Tests.ps1, .\HostRename.Network.Tests.ps1, .\HostRename.Certificate.Tests.ps1, .\HostRename.Acmp.Tests.ps1 -Output Detailed

# 3. Statische Analyse (Fehler müssen null sein; Warnungen werden akzeptiert)
Invoke-ScriptAnalyzer -Path . -Recurse -Severity Error
```

Die CI führt dieselben Prüfungen mit `powershell` (5.1) und `pwsh` (7) aus und prüft zusätzlich, dass `.ps1`/`.psd1`-Dateien mit einem BOM beginnen und keine CR-Zeichen enthalten.

**Dc- und Client-Tests** (`HostRename.Dc.Tests.ps1`, `HostRename.Client.Tests.ps1`) brauchen eine echte AD/GPO-Umgebung und die Testkonfiguration `HostRename.Checks.psd1`, die `Prepare-HostRename.ps1 -Action Setup` schreibt. Nur in einer **Test-Domäne** ausführen, niemals in der Produktion:

```powershell
.\Prepare-HostRename.ps1 -Action Setup -WhatIf   # zuerst: anzeigen, was geändert würde
.\Prepare-HostRename.ps1 -Action Setup           # danach nur in der Test-Domäne
```

Diese Tests laufen **nicht** in der CI.

### Code-Konventionen

- Zugelassene Verben (`Get-Verb`) und vollständige Cmdlet-Namen verwenden – keine Aliase.
- Die kommentarbasierte Hilfe (`.SYNOPSIS`, `.DESCRIPTION`, `.PARAMETER`, `.EXAMPLE`) steht **vor** der `#Requires`-Anweisung.
- Für alles, was das System verändert, `-WhatIf`/`-Confirm` unterstützen (`SupportsShouldProcess`).
- Keine Syntax, die nur PowerShell 7 kennt (kein ternärer Operator `? :`, kein `??`/`?.`, keine `&&`/`||`-Pipeline-Ketten, kein `ForEach-Object -Parallel`), damit der Code unter Windows PowerShell 5.1 läuft.
- Sicherheitsprinzipale (Benutzer, Gruppen, Computerkonten) werden über die **SID** verglichen, niemals über den Namen. Namen sind lokalisiert und können sich ändern.
- Keine Umgebungsdaten im Repository: keine OUs, Server- oder Computernamen, Domänennamen, IP-Adressen oder Benutzernamen in Code, Tests, Dokumentation oder Beispielausgaben. Neutrale Platzhalter wie `example.com` oder `<OU>` verwenden.
- Einrückung und Kodierung wie in den bestehenden Dateien; BOM und Zeilenenden siehe Projektfakten oben.

### Testsicherheit

**Umbenennungen niemals auf Produktivsystemen testen.** Eine Test-VM, eine Test-Domäne und `-WhatIf` verwenden.
