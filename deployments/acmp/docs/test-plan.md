# Test plan: device tests for HostRename 1.2.0 (phases T3 and T4)

[Deutsche Version](de/testplan.md) · Background: [roadmap](../../../docs/roadmap.md), [ACMP guide](acmp-guide.md), [ACMP rollout and run verification](acmp-rollout.md) (ACMP-level tests AC-A to AC-D), [ACMP deployment plan](acmp-deployment-plan.md)

As of: 3 November 2026

Everything new in 1.2.0 (ACMP mode, ACMP wrapper, network gate, certificate renewal, optional central log, reporting values) is tested so far only with mocks, in an end-to-end simulation and in CI (Windows PowerShell 5.1 and PowerShell 7, without AD or ACMP). This plan lists the tests on real devices. Results feed back into code and documentation (exit codes, detection, reboot deadline, flow).

## Rules

- Use dedicated test devices (rename is irreversible without effort; rename back with `Rename-Computer` and reset the state, see README "Rollback").
- Run scripts as the deployment does: as SYSTEM, with `powershell.exe -NoProfile -ExecutionPolicy Bypass -File ...` (see below).
- Always run `-WhatIf` first.
- Placeholders: `<Template>` = certificate template name, `<SSID>` = corporate WLAN SSID. Record real values only in your private notes.

Helper to run something as SYSTEM (Sysinternals PsExec, elevated prompt):

```powershell
psexec -s powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Test\Test-DeploymentNetwork.ps1 -CorporateSsid "<SSID>"
```

Alternative without PsExec: a one-time scheduled task running as SYSTEM that writes the output to a file:

```powershell
$a = New-ScheduledTaskAction -Execute powershell.exe -Argument '-NoProfile -ExecutionPolicy Bypass -Command "& C:\Test\Test-DeploymentNetwork.ps1 -CorporateSsid <SSID> *> C:\Test\gate.txt"'
Register-ScheduledTask -TaskName GateTest -Action $a -User SYSTEM -RunLevel Highest | Start-ScheduledTask
# afterwards: Get-Content C:\Test\gate.txt; Unregister-ScheduledTask GateTest -Confirm:$false
```

Scripts in `C:\Test` below are copies of the three scripts. Fill in the "Result" column (OK / deviation + note).

## T3-A: network gate (`Test-DeploymentNetwork.ps1`)

| ID | Precondition | Steps | Expected result | Result |
| --- | --- | --- | --- | --- |
| G1 | Cable in corporate LAN, WLAN off | `.\Test-DeploymentNetwork.ps1 -CorporateSsid "<SSID>" -Verbose` | `RESULT=LAN EXIT=0` | |
| G2 | Off site, DirectAccess connected, no cable | same | `RESULT=DIRECTACCESS EXIT=0`; `DA=ConnectedRemotely` | |
| G3 | Corporate WLAN only, no cable | same | `RESULT=WLAN EXIT=20` | |
| G4 | Cable and corporate WLAN at once | same | `RESULT=LAN EXIT=0` (LAN wins) | |
| G5 | Home WLAN, no DA (offline from the domain) | same | `EXIT=21` | |
| G6 | Cable in a foreign network (not domain), no DA | same | `EXIT=21` (or `22` with `RESULT=OTHER` if a DC answers) | |
| G7 | As G1, DA installed but inactive | same | `RESULT=LAN EXIT=0`; DA not used | |
| G8 | Cable in corporate LAN | `.\Test-DeploymentNetwork.ps1 -Allow Lan` on DA (G2 setup) | `EXIT=22` | |
| G9 | Corporate WLAN only | `-CorporateSsid ""` (no SSID given) | `EXIT=20` only if the profile is domain-authenticated; note the result | |
| G10 | Cases G1, G2, G3, G5 | run each **as SYSTEM** (PsExec or scheduled task, see above) | same exit codes as in the user context. Note: as SYSTEM, Windows may withhold the SSID (WinRT location privacy); the gate then falls back to the domain-authenticated profile. Record whether `WLAN=` shows the SSID | |
| G11 | any | note the summary line (`RESULT=... EXIT=...`) of each case | line is exactly one line on stdout | |

## T3-B: rename (`Invoke-HostRename.ps1`, ACMP mode)

Use `-Deployment Acmp -NoCentralLog` unless the central log is under test. Run in a 64-bit PowerShell (except R12). Check afterwards: `Get-ItemProperty HKLM:\SOFTWARE\HostRenameState`, `C:\ProgramData\HostRename\rename-local.csv` (readable only for administrators and SYSTEM).

| ID | Precondition | Steps | Expected result | Result |
| --- | --- | --- | --- | --- |
| R1 | Cable, delegation set, test device | `.\Invoke-HostRename.ps1 -Deployment Acmp -NameTemplate "<rule>" -NoCentralLog -WhatIf`; `echo $LASTEXITCODE` | exit 0, event `WHATIF` with the target name on stdout (`-WhatIf` writes no log file); no `LastRun` written | |
| R2 | R1 passed | same without `-WhatIf` | exit 3010, event `RENAMED` in the local log; `HostRenameState`: `TargetName`, `LastExitCode=3010`, `LastEvent` (usually `AD_VERIFY`, the last event of the run), `Deployment=Acmp`, `ScriptVersion=1.2.0`; marker `HKLM\SOFTWARE\HostRename` missing; no reboot started | |
| R3 | after R2, before reboot | run again | exit 3010 (rename pending, event `PENDING_REBOOT`) | |
| R4 | after R2, before reboot | run again with `-Reboot` | exit 3010; warning `REBOOT_IGNORED` in the local log (before `PENDING_REBOOT`); no reboot | |
| R5 | after R2 | reboot, then run with `-Cleanup` | exit 0; marker `HKLM\SOFTWARE\HostRename` exists; script file and folder still present; local logs kept (no central log) | |
| R6 | DirectAccess, no cable | R1, then R2 | as R2 | |
| R7 | R6 done | **do not reboot**; after several hours check: DA tunnel up, ACMP connection, log share reachable (`Test-Path \\<Server>\HostRename$\log`), domain logon of the computer account (`nltest /sc_verify:<domain>`) | note which stop working and after how long (basis for the reboot deadline) | |
| R8 | R7 | reboot over DA | DA reconnects, device reaches the domain; note the time to reconnect | |
| R9 | central log wanted | R2 with `-CentralLogPath "\\<Server>\HostRename$\log\rename-log.csv"` and `-Cleanup` later | entries in the central CSV (START message `HostRename 1.2.0: deployment Acmp, ...`); after cleanup the local logs are removed | |
| R10 | R2 with `-NoCentralLog` and `-Cleanup` | check `C:\ProgramData\HostRename` | local logs kept; no deferral (`CLEANUP_DEFERRED` absent) | |
| R11 | any run | after each run | `HostRenameState` exists after every run (also after errors and "nothing to do"); marker exists only after cleanup | |
| R12 | 64-bit Windows | run R1 without `-WhatIf` in the 32-bit PowerShell: `%SystemRoot%\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-HostRename.ps1 -Deployment Acmp ...` | exit 1, `[ERROR] PLATFORM` on stdout; no new values in `HostRenameState` or `HKLM\SOFTWARE\WOW6432Node\HostRenameState`; no local log | |
| R13 | after any run | `icacls C:\ProgramData\HostRename` and `icacls C:\ProgramData\HostRename\rename-local.csv` | owner `Administrators`; no inherited entries; only `SYSTEM` and `Administrators` with full control | |
| R14 | test device; delete `C:\ProgramData\HostRename` as administrator | as a **standard user**: `mkdir C:\ProgramData\HostRename`; then run R1 without `-WhatIf` as SYSTEM | exit 1, `[ERROR] LOCAL_DIR ... owner ...` on stdout; nothing written into the folder; `LastExitCode=1`, `LastEvent=LOCAL_DIR`. Afterwards delete the folder as administrator | |
| R15 | as R14, folder deleted | as administrator: `mklink /J C:\ProgramData\HostRename C:\Temp\x` (target exists), then run as SYSTEM | exit 1, `[ERROR] LOCAL_DIR ... reparse point`; nothing written to `C:\Temp\x`. Afterwards remove the junction (`rmdir C:\ProgramData\HostRename`) | |
| R16 | cmd.exe as SYSTEM | `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-HostRename.ps1 -Deployment Acmp -NameTemplate "<rule>" -CentralLogPath '' -WhatIf` | runs like R1 (`LOG_CHECK`: central log disabled); no file named `''` in the working directory | |

## T3-C: WLAN behavior and certificate

Goal: clarify whether the rename breaks EAP-TLS WLAN (strong certificate mapping, KB5014754) and whether the renewal fixes it.

| ID | Precondition | Steps | Expected result | Result |
| --- | --- | --- | --- | --- |
| W1 | rename done over cable (R2), **before reboot** | unplug cable, make the WLAN reconnect (toggle WLAN, change access point) | note: does WLAN authentication still work (re-authentication)? | |
| W2 | R5 done (rebooted), old certificate still present | WLAN only | note: connects or not (expected assumption: no) | |
| C1 | R2 done, still before reboot | `.\Update-ComputerCertificate.ps1 -Template <Template>` | exit 1, summary `RESULT=ERROR` (rename pending) | |
| C2 | after reboot, over cable | `.\Update-ComputerCertificate.ps1 -Template <Template> -WhatIf` | exit 0, `RESULT=WHATIF`, nothing changed | |
| C3 | C2 | same without `-WhatIf` | exit 0, `RESULT=RENEWED`; new certificate in `Cert:\LocalMachine\My` with the new DNS name in the SAN and a private key | |
| C4 | C3 | run again | exit 0, `RESULT=NOT_NEEDED` | |
| C5 | after reboot, over DirectAccess | C2, C3 | as C2, C3 (enrollment over DA works) | |
| C6 | old and new certificate of the template exist | with `-RemoveOld` | old certificate (old name) removed, new kept; certificates of other templates untouched | |
| C7 | C3 or C6 done | disconnect cable, WLAN only | WLAN connects with the new certificate | |
| C8 | existing version 2+ certificate | check the first run | note whether the existing certificate was recognized (see limitations in `Get-Help .\Update-ComputerCertificate.ps1 -Full`) | |
| C9 | cable port | does the LAN port require 802.1X with a computer certificate? Plug in after the rename (before and after reboot) | note: port works or not; if not, the chicken-and-egg problem applies to the LAN as well | |

## T3-D: ACMP behavior

| ID | Precondition | Steps | Expected result | Result |
| --- | --- | --- | --- | --- |
| A1 | test Client Command with a script that does `exit 3010` | run via ACMP | note: is 3010 passed through unchanged and usable in a condition, or treated as an ACMP code (3010 lies numerically in ACMP's own range from 1001)? Also note whether the agent starts a 32-bit or 64-bit `powershell.exe` (`[Environment]::Is64BitProcess`); if 32-bit, use `%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe` | |
| A2 | same with `exit 20`, `exit 1`, `exit 5` | run via ACMP | note: exit codes 1 to 99 are passed through | |
| A3 | a Client Command running as SYSTEM | show a dialog (e.g. "Bitte LAN-Kabel anschließen") | note: dialog appears in the logged-on user's session? | |
| A4 | rename a test client through the Client Command (R2) | before and after the reboot, look at the ACMP console | note: same client object or duplicate? history, container/group rules by name, inventory | |
| A5 | R2 and R5 run through ACMP | define custom fields from `HostRenameState` values (`LastRun`, `LastExitCode`, `LastEvent`, `Deployment`, `ScriptVersion`, `TargetName`) and the marker | values arrive in ACMP; "done" is derived from the marker or `TargetName`, **not** from the existence of `HostRenameState` | |
| A6 | Client Command complete (guide, section 4) | run over cable | full flow: gate, rename, reboot dialog, reboot, gate, certificate, cleanup | |
| A7 | corporate WLAN only | run the Client Command | gate exit 20, dialog shown, no rename | |
| A8 | reboot dialog | decide the postponement limit | record the reboot deadline (open decision) | |

## T3-E: GPO regression (1.2.0 client script in GPO mode)

The GPO path is unchanged by design, but the 1.2.0 client script has not run in GPO mode on a device yet. Use a pilot device (not an ACMP device).

| ID | Precondition | Steps | Expected result | Result |
| --- | --- | --- | --- | --- |
| P1 | GPO linked, pilot device, script 1.2.0 on the share | `gpupdate /force`; check task `HostRename` and script copy | task and script copy created; task starts | |
| P2 | P1 | `Start-ScheduledTask -TaskName HostRename`; read `C:\Program Files\HostRename\rename-local.csv` | START message `HostRename 1.2.0: deployment Gpo, template ...`; rename, exit 3010 | |
| P3 | P2 | reboot; check `HostRenameState` | reporting values present, `Deployment=Gpo` | |
| P4 | P3 | task runs after boot + 5 min with `-Cleanup` | marker set, task, script and local logs removed; `CLEANUP_DONE` in the central log | |
| P5 | P4 | `gpupdate /force` | GPO does not recreate task or script (marker exists) | |
| P6 | P1 | `tests\HostRename.Client.Tests.ps1` (PreRun, PostRun) | passes as in 1.1.9 | |

## T3-F: other name dependencies

After a rename, check on a test device what still refers to the old name:

| ID | System | Check | Result |
| --- | --- | --- | --- |
| D1 | EDR / antivirus console | device appears under the new name or as a duplicate | |
| D2 | MDM / Intune (if used) | device name, compliance | |
| D3 | WSUS | device reports under the new name; no duplicate | |
| D4 | DNS | stale A record of the old name (`Resolve-DnsName <old>`); new record registered | |
| D5 | licenses / license server | bound to the computer name? | |
| D6 | printers, file and print permissions | permissions bound to the old name? | |
| D7 | other (inventory, backup, monitoring, certificates of other templates) | list what is name-bound | |

## T4: dry run on all devices

Run `Invoke-HostRename.ps1 -Deployment Acmp -NameTemplate "<rule>" -NoCentralLog -WhatIf` through ACMP on all devices. It changes nothing, writes no reporting values and no local log file.

Collect per device: ACMP exit code, the event `WHATIF` with the target name from the **ACMP output (stdout)** (`-WhatIf` suppresses all file writes, so the local log does not contain it), and the exit code of the gate where it is part of the run.

Evaluate:

| Finding | How to detect | Action |
| --- | --- | --- |
| Duplicate target names | group target names, count > 1 | change the template or rely on the future ID for `{Serial}` |
| Missing or unusable serial numbers | event `SERIAL_FALLBACK` or exit 5 | accept the future ID or fix the BIOS value |
| Names too long | event `TRUNCATE` or exit 2 | check the truncation or change the template |
| Name already taken in AD | event `COLLISION` | resolve in AD |
| Permission problems | exit 4 or `PERM_DENIED` | check the delegation for the device's OU |
| Devices never online | no report within the period | check the path (never on LAN or DA) |
| Name already fits | exit 0 with `ALREADY_DONE` | no action |

Clean up the findings before the real run (T5).

## How to report results back

1. Fill the "Result" column (OK, or deviation with a short note).
2. For every deviation note: the exit code, the summary line (`RESULT=... EXIT=...`) and a short excerpt of the local log (`rename-local.csv`, the lines around the problem).
3. Remove environment data before sharing anything in public places (issues, pull requests): names of servers, domains, OUs, devices, SSIDs, template names and serial numbers. Use placeholders such as `<Server>`, `<Template>`.
4. Send the filled table to the maintainers privately if it contains environment data.
