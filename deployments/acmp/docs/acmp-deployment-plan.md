# Implementation plan: deploying HostRename via ACMP

[Deutsche Version](de/ACMP-Umsetzungsplan.md)

As of: 3 November 2026 · Status: decisions taken, implementation in progress (version 1.2.0)

Step-by-step build guide: [acmp-guide.md](acmp-guide.md) · Device test plan: [test-plan.md](test-plan.md)

## Starting point

- About 700 clients, roughly 90% of them notebooks. Many are rarely connected by cable to the corporate network.
- Off site: DirectAccess (DA) with user name and password, without computer certificates.
- In the office mostly WLAN with EAP-TLS and computer certificates.
- Deployment via ACMP instead of GPO: the ACMP agent runs as SYSTEM, can target specific clients, transport files, show dialogs and control reboots.

## Goals

1. Rename via ACMP, without GPO, without a scheduled task, without an OU filter.
2. No renaming on EAP-TLS WLAN; instead, a notice asking the user to use the LAN cable.
3. ACMP evaluates the exit code and announces the reboot in a familiar dialog.
4. The flow is built so it can be reused for other interventions (network condition, exit code contract, reboot dialog, completion message).

## Assessment of the network paths

**Cable on the corporate network:** uncritical, provided the LAN port does not also require 802.1X with computer certificates (to be checked, see phase 0).

**DirectAccess:** probably viable; the script's pre-checks (DC, secure channel, permissions) apply. The risk is the time between renaming and reboot: the device still works locally with the old name while the AD object already has the new one. Logons of the computer account can fail during that time, and with DA the tunnel depends on them. The reboot should therefore be enforced promptly (deadline, see reboot rules). In the pilot so far, a renamed device could still write to the log share before the reboot; this is an indication, but no proof for DA.

**EAP-TLS WLAN:** probably the expected chicken-and-egg problem. Since full enforcement of KB5014754, certificate logon requires a strong mapping; the SID extension in the certificate confirms an account that was previously found through a supported mapping (e.g. the name). After renaming, no account exists for the old name in the certificate. Consequences:
- Even **before the reboot**, a new WLAN logon (reauthentication, access point change) can fail.
- **After the reboot**, the device authenticates with the old certificate and gets no network, and therefore no new certificate either.
- It follows that renaming happens only over cable or DA, and after the reboot the device needs a **new computer certificate** with the new name before it returns to the WLAN.

Whether this actually happens in this environment (or whether the mapping succeeds via the SID after all) is clarified on a test device. Until then it is a reasoned assumption.

## Solution building blocks

### 1. Network gate (`Test-DeploymentNetwork.ps1`, new, reusable)

Determines over which path the device is currently connected to the domain and returns that as an exit code. Configurable: which paths are allowed (`-Allow Lan, DirectAccess`) and which SSIDs count as corporate WLAN with EAP-TLS (`-CorporateSsid`).

Detection is language independent (lesson from the pilot: German system language), so **no** parsing of `netsh` text:
- Cable: active physical adapter with media type 802.3 (`Get-NetAdapter`), profile `DomainAuthenticated` (`Get-NetConnectionProfile`). Docking stations and USB LAN adapters count as cable.
- DirectAccess: `Get-DAConnectionStatus` (status "ConnectedRemotely"); only present on DA clients, handle its absence.
- WLAN and SSID: via the WinRT class `Windows.Networking.Connectivity.NetworkInformation` (connected SSID), compared with `-CorporateSsid`.
- Domain reachable: DC via DNS resolution and port (like the pre-checks in the client script).

| Exit code | Meaning | Reaction in ACMP |
| --- | --- | --- |
| 0 | allowed path (cable or DA), domain reachable | continue |
| 20 | corporate WLAN (EAP-TLS) only | user dialog "Please connect the LAN cable", abort, retry later |
| 21 | no domain connection (offline, foreign network without DA) | end silently, retry later |
| 22 | path detected but not allowed (e.g. DA when only cable is allowed) | end silently, retry later |

The gate does not belong in the client script but stays standalone: this way it can be put in front of any other action (other software, certificate swap, domain rejoin).

### 2. Client script in ACMP mode (`Invoke-HostRename.ps1`, small change)

The logic stays, as do the exit codes (0, 3010, 1, 2, 4, 5). To adapt:
- With `-Cleanup`, the script must not delete its own file if it does not run from `$LocalFolder` (under ACMP it lives in ACMP's storage). Proposal: switch `-KeepScript` or detection via the path. The cleanup removes the task only if it exists anyway.
- No `-Reboot`: ACMP controls the reboot.
- Local logs via `-LocalDir` in a fixed location (in ACMP mode `C:\ProgramData\HostRename`; implemented as a protected folder: owner and reparse-point check, ACL only SYSTEM and Administrators, because standard users can create folders in ProgramData).
- 64-bit PowerShell only (implemented: a 32-bit process on 64-bit Windows ends with exit 1 before writing anything; a 32-bit agent calls `%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe`).
- Without a central log: `-NoCentralLog` (implemented; `-CentralLogPath ''` is unreliable with `powershell.exe -File`).
- Keep the central CSV log as an option (reachable via DA?), with feedback additionally via ACMP (see 5).

### 3. Certificate renewal (`Update-ComputerCertificate.ps1`, new, reusable)

Runs after the reboot, only over cable or DA:
- Request a new computer certificate from the WLAN template (template name as a parameter), e.g. with `Get-Certificate -Template <Name> -CertStoreLocation Cert:\LocalMachine\My`.
- Verify that the new DNS name is in the certificate.
- Remove old certificates of the same template with the old name, so the WLAN does not pick the wrong one (only with the switch `-RemoveOld`).
- Exit codes: 0 renewed or not needed, 1 error (retry later).

Whether the step is needed is clarified in the test phases; the template name is a mandatory parameter.

### 4. ACMP Client Command "HostRename"

Flow in one Client Command (building blocks from the editor: files/file repository, custom scripts, conditions, flow control, dialogs):

1. Transfer the scripts from the file repository to the client.
2. Read the state: if the marker key `HKLM\SOFTWARE\HostRename` exists, the device is done and the run ends. `TargetName` in `HKLM\SOFTWARE\HostRenameState` shows that the rename has happened. Never use the mere existence of `HostRenameState` as the criterion: since 1.2.0 it exists after every run because of the reporting values.
3. Run the gate. 20: "LAN cable" dialog; 21/22: end silently.
4. Run `Invoke-HostRename.ps1` (parameters for template, prefix etc. in the Client Command).
5. Evaluate the exit code:
   - 3010: reboot dialog with deadline (see below), reboot by ACMP. Hint in the dialog: keep the cable connected until after the reboot.
   - 0: name already fits, continue with 6.
   - 1: error, retry on the next run; after several failures, into the report.
   - 2, 4, 5: permanent problem (name too long, no permissions, no serial number), do not retry, into the report.
6. After the reboot (next run, again through the gate): renew the certificate (WLAN devices only), then `Invoke-HostRename.ps1 -Cleanup` (ACMP mode), report status.

Script exit codes are 0 to 5, 20 to 22 and 3010. ACMP uses its own codes from 100 and from 1001; all script codes except 3010 stay below that. 3010 overlaps numerically with ACMP's range: verify in ACMP how it is treated (device test A1).

**Reboot rules (open):** postpone only to a limited extent (e.g. until end of work, at most X hours), then reboot with advance warning. Reason: intermediate state of old/new name, risk to the tunnel with DA. Check whether the existing ACMP reboot dialog (Windows Update Management) can be used for this.

### 5. Feedback and report

- Fill ACMP custom fields (e.g. phase, target name, last exit code, time) from the client's registry and build a report for the 700 devices from them.
- The central CSV log stays as evidence when the share is reachable.

### 6. What remains from the GPO solution

- **Delegation stays necessary:** under ACMP too, the device renames with its own computer account (SYSTEM), that is, with the permissions from `-Component Delegation`.
- **Share** only if the central log stays.
- **Do not link the GPO** for devices that run through ACMP; otherwise both paths run on one device at the same time.

## Approach

### Phase 0: Clarification on test devices (not a precondition; part of the test phases, see `docs/roadmap.md`)

1. **WLAN:** rename a test device over cable, reboot, then WLAN only: does it connect? Then request a new certificate: does it connect now? Record the template name for the WLAN certificate.
2. **Before the reboot:** rename a test device over cable, unplug the cable, let the WLAN reconnect: does the logon already fail?
3. **DirectAccess:** rename a test device over DA; after some hours without a reboot: are the tunnel, the ACMP connection and the log share still reachable? Then reboot: does DA come back up?
4. **LAN port:** does the cable port require 802.1X with a computer certificate? If so, the chicken-and-egg problem applies there as well.
5. **ACMP:** how is the exit code of a PowerShell script taken over? Can dialogs appear in the user context while the Client Command runs as SYSTEM? How does ACMP behave after the rename (same client or duplicate, history, container rules by name)?
6. **Check other name dependencies:** EDR/antivirus console, MDM, WSUS, license server, DNS leftovers (old A record), print and file permissions on computer names.

### Phase 1: Adapt and test the scripts

- New gate, with Pester tests (detection via mocks, exit codes).
- Client script: ACMP mode for the cleanup; adapt existing tests, new tests for the mode.
- New certificate script, with tests (as far as possible without a CA).
- Add a section "Deployment via ACMP" to the README.

### Phase 2: Build the ACMP Client Command

Client Command as in section 4, agree on dialog texts, test on one device per case: cable, DA, corporate WLAN (notice dialog), offline.

### Phase 3: Dry run on all devices

`Invoke-HostRename.ps1 -WhatIf` via ACMP on all roughly 700 devices: target names, duplicates, missing serial numbers, names that are too long. Clean up the findings before the real run.

### Phase 4: Rollout in waves

Pilot (about 20 devices, all cases), then about 100, then the rest. Proceed only when error rate and helpdesk volume are acceptable. Use the report to track which devices are stuck (e.g. never online via cable or DA).

### Phase 5: Completion

All devices done: disable the Client Command, remove the delegation (`-Action Remove -Component Delegation`), check leftovers via the report.

## Reuse for other software

The framework consists of four interchangeable parts: gate with allowed paths, the actual action, exit code contract (0 done, 3010 reboot, 1 retry later, 2-9 permanent problem, 20-29 network) and reboot dialog with deadline. For other software only the action is swapped; gate and dialogs stay. Create the contract as an ACMP template so that every new Client Command uses the same evaluation.

## Decisions

- **Allowed paths for renaming:** LAN cable and DirectAccess (default of the network gate, configurable).
- **Reboot deadline:** still open, to be determined in the test phase (ACMP side).
- **WLAN certificate template:** not known yet, therefore a mandatory parameter; old certificates are only removed with a switch (`-RemoveOld`).
- **Central CSV log:** kept as an option in addition to ACMP reporting.
- **Local logs in ACMP mode:** `C:\ProgramData\HostRename` (protected by the script before every run; an explicit `-LocalDir` must not be writable for standard users).
- **GPO path:** kept; GPO and ACMP are alternative deployment methods, never both active on the same device.
- **Phase 0 is no longer a precondition:** the owner cannot plan it upfront; device tests are part of the test phases in `docs/roadmap.md`.
