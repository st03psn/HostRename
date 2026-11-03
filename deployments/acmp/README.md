# HostRename via ACMP

[Deutsche Version](README.de.md)

HostRename can be deployed by the deployment tool ACMP (Aagon) instead of the GPO: an ACMP Client Command runs the scripts on the client as SYSTEM, ACMP controls the reboot (exit code 3010 is the signal), and renaming happens only over LAN cable or DirectAccess (network gate). On WLAN devices, the machine certificate is renewed after the rename and reboot. **GPO and ACMP are alternative deployment methods: never both on the same device.**

Recommended: the wrapper `Invoke-AcmpHostRename.ps1` runs the whole Client Command flow (state check, gate, rename, certificate, cleanup) in one script run per ACMP invocation; the Client Command then only transfers the scripts, starts the wrapper in the 64-bit PowerShell and reacts to its exit code (3010 reboot dialog, 20 LAN cable dialog). All parameters and exit codes: `Get-Help .\Invoke-AcmpHostRename.ps1 -Full`.

## Package contents

The release has its own ACMP package, `HostRename-<version>-acmp.zip`. It is **flat**: the scripts lie in one folder, as ACMP transfers them into its cache on the client.

| File | Purpose | Goes into ACMP's file repository |
| --- | --- | --- |
| `Invoke-AcmpHostRename.ps1` | wrapper: the whole flow in one run | yes |
| `Invoke-HostRename.ps1` | client script (`-Deployment Acmp`): rename, cleanup | yes |
| `Test-DeploymentNetwork.ps1` | network gate (tool-neutral building block) | yes |
| `Update-ComputerCertificate.ps1` | certificate renewal (tool-neutral building block; only if WLAN devices are in scope) | yes |
| `Prepare-HostRename.ps1` | sets the delegation once on an admin PC or DC (`-Action Setup -Component Delegation`); the share only if the central log is used | no |
| `docs/`, `README.md`, `README.de.md`, `LICENSE`, `SECURITY.md` | documentation | no |

The scripts are UTF-8 with BOM; transfer them unchanged. In this repository, the wrapper lives here, `Invoke-HostRename.ps1` and `Prepare-HostRename.ps1` in the root and the building blocks in `components/`; the wrapper finds them there too when run from the repository (its own folder always wins).

## Documentation

| Document | Content |
| --- | --- |
| [docs/acmp-guide.md](docs/acmp-guide.md) | building the Client Command step by step, parameters, exit-code contract |
| [docs/acmp-starter-kit.md](docs/acmp-starter-kit.md) | hand-over for a first ACMP test by someone new to the project |
| [docs/acmp-rollout.md](docs/acmp-rollout.md) | rollout process (containers, waves, acceptance criteria) and run verification (ACMP tests AC-A to AC-D) |
| [docs/test-plan.md](docs/test-plan.md) | device tests: gate, certificate, ACMP, and a regression block for the GPO path |
| [docs/acmp-deployment-plan.md](docs/acmp-deployment-plan.md) | background and decisions |

German versions are in [docs/de/](docs/de/acmp-anleitung.md). Operations documentation of the core (delegation, share, logging, registry): the [main README](../../README.md).

## Tests

Pester 5.3+, no AD needed (any platform):

```powershell
Invoke-Pester -Path .\deployments\acmp\tests -Output Detailed
```

| File | Checks |
| --- | --- |
| `tests/HostRename.Acmp.Tests.ps1` | ACMP mode of `Invoke-HostRename.ps1` (mocks): `-Deployment`, local folder, disabled central log, cleanup decisions, reporting values |
| `tests/HostRename.Simulation.Tests.ps1` | end-to-end simulation of the Client Command and the wrapper with the real scripts (copied flat into a simulated ACMP cache) and the documented snippets; changes nothing on the machine |

## Test status

Everything here is new in 1.2.0 and **tested with mocks and in the simulation only** (locally and in CI on Windows PowerShell 5.1 and PowerShell 7, without AD or ACMP). Nothing has run on real Windows devices, over DirectAccess, with WLAN/AD CS or in ACMP yet; how ACMP treats exit code 3010 is device test A1. The device tests are in [docs/test-plan.md](docs/test-plan.md).
