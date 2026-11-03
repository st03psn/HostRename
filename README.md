# HostRename

[🇩🇪 Deutsche Version](README.de.md)

**HostRename** is a PowerShell tool for renaming the computer name (hostname) of Windows machines – locally or remotely, standalone or domain-joined.

> **Status:** early development. The features below describe the planned scope; not everything is implemented yet. See the [CHANGELOG](CHANGELOG.md) for what is available.

## Features (planned)

- Rename the local or a remote Windows computer
- Support for workgroup and Active Directory domain-joined machines (with domain credentials)
- Validation of the new name (NetBIOS limit of 15 characters, allowed characters, no purely numeric names)
- `-WhatIf` / `-Confirm` support for safe dry runs
- Optional automatic restart after the rename
- Batch renaming from a CSV file (`OldName,NewName`)
- Logging of all actions

## Requirements

- Windows 10 / 11 or Windows Server 2016 or later
- Windows PowerShell 5.1 or PowerShell 7.x
- Administrative privileges on the target machine
- For domain-joined machines: an account allowed to rename computer objects in AD
- For remote renames: WinRM / PowerShell Remoting enabled on the target

## Installation

```powershell
git clone https://github.com/st03psn/HostRename.git
cd HostRename
```

If script execution is blocked, allow it for the current session:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

## Usage

> The interface is not final yet; the examples show the intended usage.

```powershell
# Rename the local computer and restart
.\src\HostRename.ps1 -NewName "PC-SALES-01" -Restart

# Dry run
.\src\HostRename.ps1 -NewName "PC-SALES-01" -WhatIf

# Rename a domain-joined remote computer
.\src\HostRename.ps1 -ComputerName "OLD-PC" -NewName "PC-SALES-01" -DomainCredential (Get-Credential)

# Batch rename from CSV
.\src\HostRename.ps1 -CsvPath .\rename.csv
```

Under the hood, HostRename builds on the built-in `Rename-Computer` cmdlet.

## Naming rules

| Rule | Detail |
|------|--------|
| Length | 1–15 characters (NetBIOS limit) |
| Characters | Letters `A–Z`, digits `0–9`, hyphen `-` |
| Not allowed | Purely numeric names, leading/trailing hyphen, spaces, `\ / : * ? " < > \| . ,` |

## Project structure

```
HostRename/
├── src/          # PowerShell scripts / module
├── tests/        # Pester tests
├── .github/      # Issue/PR templates, CI workflow
├── CHANGELOG.md
├── CONTRIBUTING.md
├── SECURITY.md
└── LICENSE
```

## Development

```powershell
Install-Module PSScriptAnalyzer, Pester -Scope CurrentUser
Invoke-ScriptAnalyzer -Path .\src -Recurse
Invoke-Pester -Path .\tests
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for details.

## Contributing

Issues and pull requests are welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md) first.

## Security

Please report vulnerabilities privately – see [SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE) © 2026 st03psn
