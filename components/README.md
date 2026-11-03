# HostRename – components

[Deutsche Version](README.de.md) · [Main README](../README.md)

Tool-neutral building blocks. They are not tied to a deployment tool or to the rename: each runs standalone as SYSTEM (or manually), changes nothing it is not asked to, ends with an exit code and prints one summary line as its last line on stdout. A deployment folder (for example [deployments/acmp](../deployments/acmp/README.md)) calls them unchanged.

| Script | Purpose | Exit codes | Summary line |
| --- | --- | --- | --- |
| `Test-DeploymentNetwork.ps1` | Network gate: over which path does the device reach the domain (wired LAN, DirectAccess, corporate WLAN), and is that path allowed (`-Allow`, default `Lan, DirectAccess`; `-CorporateSsid`, `-DomainName`)? Changes nothing on the device | `0` allowed path and a DC is reachable · `20` corporate WLAN only (ask for a LAN cable) · `21` no domain connection · `22` path not allowed or unknown · `1` error | `RESULT=<LAN\|DIRECTACCESS\|WLAN\|OTHER\|NONE\|ERROR> EXIT=<n> ...` |
| `Update-ComputerCertificate.ps1` | Certificate renewal: requests a machine certificate from the template `-Template` when no valid one carries the current DNS name (after a rename); `-RemoveOld` then removes the outdated certificates of the same template | `0` renewed, not needed or `-WhatIf` · `1` error, retry later (also while a rename still awaits its reboot) | `RESULT=<RENEWED\|NOT_NEEDED\|WHATIF\|ERROR> EXIT=<n> ...` |

All parameters, the detection rules and edge cases are in the built-in help:

```powershell
Get-Help .\components\Test-DeploymentNetwork.ps1 -Full
Get-Help .\components\Update-ComputerCertificate.ps1 -Full
```

## Tests

Pester 5.3+, mocks only (no AD, no CA, runs on any platform):

```powershell
Invoke-Pester -Path .\components\tests -Output Detailed
```

| File | Checks |
| --- | --- |
| `tests/HostRename.Network.Tests.ps1` | gate: detection of LAN, DirectAccess, WLAN and domain reachability (mocked), decision, exit codes, result line |
| `tests/HostRename.Certificate.Tests.ps1` | certificate renewal: SAN parsing, template detection, renewal and removal decisions with a mocked store and enrollment |

**Test status:** both building blocks are new in 1.2.0 and tested only with mocks and in the end-to-end simulation of the ACMP flow (locally and in CI on Windows PowerShell 5.1 and PowerShell 7). They have not run on real devices (LAN, DirectAccess, WLAN, AD CS) yet; the device tests are in [deployments/acmp/docs/test-plan.md](../deployments/acmp/docs/test-plan.md).
