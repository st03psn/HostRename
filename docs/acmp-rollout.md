# ACMP: deployment process and run verification

[Deutsche Version](de/acmp-rollout.md) · Build guide: [acmp-guide.md](acmp-guide.md) · Device tests: [test-plan.md](test-plan.md) · Schedule: [roadmap.md](roadmap.md)

As of: 3 November 2026 · Version 1.2.0

This document describes **how HostRename is rolled out through ACMP**, from preparation to completion, and **how to check that a run worked**. [acmp-guide.md](acmp-guide.md) explains how to build the Client Command. [test-plan.md](test-plan.md) lists the individual device tests (T3), and this document refers to them by ID.

> **Test status:** Nothing in 1.2.0 has run in ACMP or on a real device yet. ACMP terms (Client Command, container, custom field, query, schedule) describe what is needed. Where the ACMP console works differently or names things differently, the places are marked "verify in ACMP". Adjust this document after the first ACMP tests (section 5, block AC-A).

## 1. Overview

```text
Phase             Who / where            Exit criterion
---------------   --------------------   ---------------------------------------------------------------
0 Prepare         admin, AD + ACMP       delegation set, file repository filled, custom fields defined
1 Build           ACMP console           Client Commands created, AC-A tests passed on 1 test device
2 Function test   3–5 test devices       AC-B and AC-C tests passed (LAN, DA, WLAN only, offline, errors)
3 Dry run         all devices, -WhatIf   findings cleaned up (duplicates, serials, too long, permissions)
4 Pilot           about 20 devices       acceptance criteria in section 6 met
5 Waves           about 100, then rest   acceptance criteria per wave met
6 Completion      admin                  all devices done or explained, Client Command off, delegation removed
```

The GPO path stays an alternative. **Never** link the HostRename GPO to OUs whose devices get the ACMP Client Command.

## 2. Building blocks in ACMP

### 2.1 Client Commands

Use three Client Commands so that inventory, dry run and the real run are clearly separated. Names are suggestions.

| Client Command | Purpose | Changes the device | Content |
| --- | --- | --- | --- |
| **HostRename – Status** | collect the state into custom fields | no | read-only script (section 4.2), runs on all devices in scope, including after completion |
| **HostRename – Dry run** | phase 3 | no | gate + `Invoke-HostRename.ps1 -Deployment Acmp ... -WhatIf` |
| **HostRename – Rename** | phases 4–5 | yes | full flow of [acmp-guide.md](acmp-guide.md), section 4: state check, gate, rename, reboot dialog, after the reboot gate, certificate, cleanup |

All three use **the same parameters** (template, `-NoCentralLog` or `-CentralLogPath`, `-CorporateSsid`). A different template triggers a new rename.

Version the Client Commands, for example by putting the script version in the name or description. Change a Client Command only between waves.

### 2.2 Custom fields

They are filled by **HostRename – Status**, or by a status step at the end of **HostRename – Rename**. How custom fields are defined and filled in ACMP: verify in ACMP.

| Custom field | Source | Use |
| --- | --- | --- |
| `HR_Done` | marker `HKLM\SOFTWARE\HostRename` exists (`1`/`0`) | done |
| `HR_TargetName` | `HKLM\SOFTWARE\HostRenameState\TargetName` | rename has happened |
| `HR_LastExitCode` | `...\HostRenameState\LastExitCode` | **primary status** of the last run of `Invoke-HostRename.ps1` |
| `HR_LastEvent` | `...\HostRenameState\LastEvent` | hint only (last logged event, not the result) |
| `HR_LastRun` | `...\HostRenameState\LastRun` | age of the information |
| `HR_Version` | `...\HostRenameState\ScriptVersion` | which script version ran |
| `HR_Phase` | derived (section 4.2) | for containers and reports |
| `HR_Gate` | last summary line of `Test-DeploymentNetwork.ps1` | why a device is waiting (WLAN only, offline) |
| `HR_Cert` | last summary line of `Update-ComputerCertificate.ps1` | certificate state (WLAN devices only) |

> Decide "done" **only** from the marker (`HR_Done`) and "renamed" only from `HR_TargetName`. The key `HostRenameState` exists after every run, also after errors and "nothing to do".

### 2.3 Containers (device groups)

Static containers control **who** gets the Client Command. Dynamic containers built from the custom fields show **where** a device stands. Verify in ACMP how dynamic containers or queries are defined.

| Container | Type | Content |
| --- | --- | --- |
| `HR-Test` | static | 3–5 test devices (one per path: LAN, DA, WLAN user, rarely online) |
| `HR-Pilot` | static | about 20 devices, mixed: locations, models, LAN/DA/WLAN users |
| `HR-Wave-1`, `HR-Wave-2`, … | static | about 100, then the rest |
| `HR-Open` | dynamic | `HR_Done = 0` and `HR_TargetName` empty |
| `HR-RebootPending` | dynamic | `HR_LastExitCode = 3010` |
| `HR-AfterReboot` | dynamic | `HR_TargetName` = current computer name and `HR_Done = 0` |
| `HR-Done` | dynamic | `HR_Done = 1` |
| `HR-Retry` | dynamic | `HR_LastExitCode = 1`, or gate 20/21/22 |
| `HR-Permanent` | dynamic | `HR_LastExitCode` in 2, 4, 5 (needs manual action; the Client Command ends at step 1 with `phase=permanent` until the device is released, see [acmp-guide.md](acmp-guide.md), section 4) |
| `HR-Stale` | dynamic | `HR_LastRun` older than N days and `HR_Done = 0` |

### 2.4 Schedule and repetition

- **HostRename – Status:** daily and at agent start, so that the custom fields stay current.
- **HostRename – Rename:** repeatedly on the wave container until the device is done, for example at every agent start or logon plus once a day. Step 1 of the flow ends the run immediately on done devices, so repeated runs are harmless.
- Which triggers ACMP offers and how "repeat until successful" is configured: verify in ACMP (test AC-A7).

## 3. Deployment process step by step

### Phase 0: prepare

1. Set the delegation (see [acmp-guide.md](acmp-guide.md), section 1). For a central log, also create the share.
2. Put `Invoke-HostRename.ps1`, `Test-DeploymentNetwork.ps1` and, for WLAN devices, `Update-ComputerCertificate.ps1` unchanged into the ACMP file repository.
3. Define the custom fields (section 2.2) and the containers (section 2.3).
4. Fix the parameters: template, central log or not, corporate SSID, certificate template name. Use them identically in all Client Commands.
5. Make sure the HostRename GPO is not linked to these OUs.

### Phase 1: build

1. Create the three Client Commands (section 2.1), first assigned only to `HR-Test`.
2. Run block **AC-A** (section 5): file transfer, 64-bit, exit codes, output, custom fields, dialogs, reboot, repetition.
3. Adjust the Client Commands to what AC-A shows (for example Sysnative for a 32-bit agent, or how 3010 is handled).

### Phase 2: function test on test devices

1. Run blocks **AC-B** (end-to-end per path) and **AC-C** (errors and interruptions) on `HR-Test`.
2. In parallel, the device tests from [test-plan.md](test-plan.md) that ACMP does not cover: WLAN before and after the reboot (W1, W2), certificate (C1–C9), DirectAccess over hours (R7, R8), name dependencies (D1–D7).
3. Decide the reboot deadline (A8) and finalize the dialog texts.

### Phase 3: dry run on all devices

1. Assign **HostRename – Dry run** to all devices in scope.
2. Collect the stdout output (`WHATIF` with the target name) and the exit codes. `-WhatIf` writes no local log and no reporting values.
3. Evaluate as in [test-plan.md](test-plan.md), T4: duplicate target names, `SERIAL_FALLBACK`, `TRUNCATE`, `COLLISION`, exit 4, devices that never report.
4. Clean up the findings. Repeat the dry run until no new findings appear.

### Phase 4: pilot

1. Assign **HostRename – Rename** to `HR-Pilot`.
2. Track the progress daily through the containers (section 2.3) and the checks in section 4.
3. Continue only when the acceptance criteria in section 6 are met.

### Phase 5: waves

Same as the pilot with `HR-Wave-1`, `HR-Wave-2`, and so on. Before every wave: check `HR-Permanent` and `HR-Stale` of the previous wave, and note any changes to the Client Command.

### Phase 6: completion

1. All devices in `HR-Done`. Explain or handle the rest individually (`HR-Permanent`, `HR-Stale`).
2. Deactivate **HostRename – Rename**. Keep **HostRename – Status** for a while if reports are still needed.
3. Remove the delegation: `.\Prepare-HostRename.ps1 -Action Remove -Component Delegation`.
4. Optional: remove the registry keys on the clients (both `HKLM\SOFTWARE\HostRename*` keys) through a small Client Command, and remove `C:\ProgramData\HostRename` if no central log was used and the local logs are no longer needed.

## 4. How to check that a run worked

### 4.1 Evidence by level

Check from top to bottom. A run is OK only when all levels that apply agree.

| Level | Where | What to check |
| --- | --- | --- |
| 1 ACMP job | job / Client Command history of the device (verify in ACMP) | exit code of each step, stdout output (summary lines `RESULT=... EXIT=...`, events on stdout) |
| 2 Custom fields | ACMP inventory, containers | `HR_Done`, `HR_TargetName`, `HR_LastExitCode`, `HR_LastRun` current |
| 3 Device | registry, local log, computer name | `HKLM\SOFTWARE\HostRenameState`, marker `HKLM\SOFTWARE\HostRename`, `C:\ProgramData\HostRename\rename-local.csv`, `$env:COMPUTERNAME` |
| 4 AD / DNS | admin PC | computer object with the new name, no object with the old name; DNS A record of the new name |
| 5 Central log (optional) | share | lines with `ComputerName` or `MachineGuid` of the device |
| 6 Certificate / WLAN (WLAN devices) | device | new certificate with the new DNS name; WLAN connects |

### 4.2 Expected state per phase

| Phase of the device | `LastExitCode` | `TargetName` | Marker | Computer name | ACMP | Next step |
| --- | --- | --- | --- | --- | --- | --- |
| not yet started | – | – | – | old | – | rename runs when the gate allows |
| waiting for a path | unchanged | – | – | old | gate 20/21/22 | automatic on next run (20: user plugs in the cable) |
| renamed, reboot pending | 3010 | new | – | old (active), new (pending) | reboot dialog shown | user or deadline reboots |
| after reboot | 3010 or 0 | new | – | new | gate 0 | certificate (WLAN devices), cleanup |
| done | 0 | new (empty if the name already matched the template) | exists (`ComputerName` = new) | new | step 1 ends the run | none |
| retry | 1 | maybe | – | maybe | error in the job | automatic on next run; after several failures check the log |
| permanent | 2, 4 or 5 | – | – | old | Client Command ends at step 1 (`phase=permanent`) on every run | manual action: fix the cause, then release the device by deleting `LastExitCode` (see [acmp-guide.md](acmp-guide.md), section 4) |

### 4.3 Status script for the Client Command "HostRename – Status"

Read-only. It writes nothing and prints one line that ACMP can store or split into custom fields. Verify in ACMP how a script output or registry value fills a custom field. If ACMP can read registry values directly, use them instead and only derive `HR_Phase` here.

```powershell
# HostRename status (read-only). Output: one line, exit code 0.
$state  = Get-ItemProperty 'HKLM:\SOFTWARE\HostRenameState' -ErrorAction SilentlyContinue
$done   = Test-Path 'HKLM:\SOFTWARE\HostRename'
$target = if ($state) { [string]$state.TargetName } else { '' }
$active = $env:COMPUTERNAME
$phase  = if ($done) { 'Done' }
          elseif (-not $target) { if ($state -and $state.LastExitCode -in 2,4,5) { 'Permanent' } else { 'Open' } }
          elseif ($active -ieq $target) { 'AfterReboot' }
          else { 'RebootPending' }
'HR_PHASE={0} HR_DONE={1} HR_TARGET={2} HR_EXIT={3} HR_EVENT={4} HR_LASTRUN={5} HR_VERSION={6} NAME={7}' -f `
    $phase, [int]$done, $target, $state.LastExitCode, $state.LastEvent, $state.LastRun, $state.ScriptVersion, $active
exit 0
```

Run it, like all scripts, in the 64-bit PowerShell (see [acmp-guide.md](acmp-guide.md), section 1).

### 4.4 Checks on the admin side

```powershell
# AD: new name exists, old name is gone (RSAT ActiveDirectory module)
Get-ADComputer -Identity '<NewName>' -Properties whenChanged, DNSHostName | Select-Object Name, DNSHostName, whenChanged
Get-ADComputer -Filter "Name -eq '<OldName>'"            # expected: no result

# DNS: record of the new name, stale record of the old name
Resolve-DnsName '<NewName>' -Type A
Resolve-DnsName '<OldName>' -Type A -ErrorAction SilentlyContinue   # stale record: clean up or let scavenging do it

# Central log (if used): all lines of one device, by MachineGuid
Import-Csv '\\<Server>\HostRename$\log\rename-log.csv' -Delimiter ';' | Where-Object MachineGuid -eq '<Guid>' | Format-Table Timestamp, Level, Event, ComputerName, TargetName, Message
```

### 4.5 Checks on the device (helpdesk, test devices)

```powershell
Get-ItemProperty HKLM:\SOFTWARE\HostRenameState
Test-Path HKLM:\SOFTWARE\HostRename
Import-Csv C:\ProgramData\HostRename\rename-local.csv -Delimiter ';' | Select-Object -Last 15 | Format-Table Timestamp, Level, Event, Message
Get-ChildItem Cert:\LocalMachine\My | Select-Object Subject, NotAfter, @{n='DNS';e={$_.DnsNameList -join ','}}
```

The local log can be read only as administrator or SYSTEM (protected folder).

## 5. ACMP test plan

Fill in the "Result" column (OK, or deviation with a short note). Verification uses the levels from section 4.1 (L1 = ACMP job, L2 = custom fields, L3 = device, L4 = AD/DNS, L5 = central log, L6 = certificate/WLAN).

### AC-A: ACMP mechanics (1 test device, before any rename)

| ID | Test | Steps in ACMP | Expected result | Check | Result |
| --- | --- | --- | --- | --- | --- |
| AC-A1 | File transfer | Client Command copies the three scripts from the file repository and runs `Get-FileHash` on them | files present, hashes identical to the repository, BOM intact | L1 | |
| AC-A2 | 64-bit | script step `[Environment]::Is64BitProcess` | `True`; if `False`, use `%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe` and repeat | L1 | |
| AC-A3 | Exit codes | script steps with `exit 0`, `1`, `5`, `20`, `3010` | each code arrives unchanged and can be used in a condition; note how 3010 is treated (test-plan A1, A2) | L1 | |
| AC-A4 | Output | run `Test-DeploymentNetwork.ps1` | the summary line is visible in the job history | L1 | |
| AC-A5 | Custom fields | run **HostRename – Status** on a device without HostRename keys, then after creating a test value `HKLM:\SOFTWARE\HostRenameState\LastExitCode = 1` | fields filled (`HR_PHASE=Open`, `HR_EXIT=1`); containers `HR-Open` / `HR-Retry` show the device; afterwards remove the test value | L2 | |
| AC-A6 | Dialog | Client Command running as SYSTEM shows the "LAN cable" text | dialog appears in the logged-on user's session (test-plan A3) | L1 | |
| AC-A7 | Repetition | assign a Client Command with "repeat until successful" or a schedule | runs again at the configured trigger; stops when the condition says done | L1 | |
| AC-A8 | Reboot control | test reboot dialog with deadline | user can postpone within the deadline; reboot happens at the latest at the deadline | L1, L3 | |

### AC-B: end-to-end per path (test devices, **HostRename – Rename**)

| ID | Path | Steps | Expected result | Check | Result |
| --- | --- | --- | --- | --- | --- |
| AC-B1 | LAN | dry run, then Rename on a LAN device | dry run: exit 0, `WHATIF` with the target name. Rename: gate 0, exit 3010, reboot dialog; after the reboot: gate 0, cleanup exit 0, `HR_Done=1`, container `HR-Done` | L1–L4 | |
| AC-B2 | DirectAccess | as AC-B1 off site over DA | as AC-B1; note the time from rename to reboot and whether the tunnel stays up (test-plan R7, R8) | L1–L4 | |
| AC-B3 | WLAN user with cable | as AC-B1, with certificate step | as AC-B1, plus certificate `RESULT=RENEWED` before the cleanup; afterwards WLAN without cable works (test-plan C7) | L1–L4, L6 | |
| AC-B4 | WLAN only | Rename on a device with corporate WLAN only | gate 20, "LAN cable" dialog, no rename, `HR_LastExitCode` unchanged; after plugging in the cable, the next run renames | L1–L3 | |
| AC-B5 | Offline / foreign network | Rename on a device in a home network without DA | gate 21, no dialog, no rename; renames on the next run on LAN or DA | L1–L3 | |
| AC-B6 | Already done | run Rename again on an AC-B1 device | step 1 ends the run (marker exists), no script runs | L1, L3 | |
| AC-B7 | Name already fits | device whose name already matches the template | exit 0 (`ALREADY_DONE`), no reboot; cleanup sets the marker | L1–L3 | |
| AC-B8 | Central log (if used) | AC-B1 with `-CentralLogPath` | lines in the central CSV; after the cleanup the local logs are removed | L5, L3 | |
| AC-B9 | Client identity | look at the device in the ACMP console before and after AC-B1 | same client object, no duplicate; note history, container membership, inventory (test-plan A4) | L1, L2 | |

### AC-C: errors and interruptions

| ID | Situation | How to create it | Expected result | Check | Result |
| --- | --- | --- | --- | --- | --- |
| AC-C1 | No permission | test device in an OU without delegation | exit 4 (`PERM_DENIED`), no rename, container `HR-Permanent`; reruns end at step 1 with `phase=permanent` (no gate, no script); after fixing the delegation and deleting `LastExitCode` the next run proceeds and renames | L1–L3 | |
| AC-C2 | Name too long | test template that is too long with `-OnTooLong Skip` | exit 2, no rename, `HR-Permanent`; reruns end at step 1 with `phase=permanent`; after release (`LastExitCode` deleted) the run proceeds again | L1–L3 | |
| AC-C3 | Reboot postponed | postpone the reboot dialog up to the deadline | reboot at the latest at the deadline; until then reruns give 3010 (`PENDING_REBOOT`) | L1, L3 | |
| AC-C4 | Cable unplugged before the reboot | after 3010 unplug the cable, use WLAN | note: does WLAN still work until the reboot (test-plan W1)? After the reboot the device waits at gate 20 until a cable is connected | L1, L3, L6 | |
| AC-C5 | Device offline after the rename | after 3010 take the device offline for a day | the next run continues with the after-reboot phase; nothing is renamed twice | L1–L3 | |
| AC-C6 | Central log unreachable (if used) | block the share during the cleanup | exit 0, marker not set; `CLEANUP_DEFERRED` in the local log and as `HR_LastEvent` (the cleanup events also appear in the ACMP output); the next run completes the cleanup | L2, L3, L5 | |
| AC-C7 | Certificate fails | wrong template name | certificate exit 1, no cleanup, `HR-Retry`; after correcting the name, the next run completes | L1–L3, L6 | |
| AC-C8 | Protected folder | standard user pre-creates `C:\ProgramData\HostRename` (test-plan R14) | exit 1, `[ERROR] LOCAL_DIR` in the ACMP output; after an admin deletes the folder, the next run works | L1, L3 | |
| AC-C9 | Two runs at the same time | start Rename twice in quick succession (if ACMP allows it) | no double rename; the second run gives 3010 or ends at step 1 | L1, L3 | |

### AC-D: dry run and reporting at scale (phase 3)

| ID | Test | Expected result | Result |
| --- | --- | --- | --- |
| AC-D1 | Dry run on all devices | every reachable device reports an exit code and a `WHATIF` line | |
| AC-D2 | Evaluation | list of duplicates, serial fallbacks, truncations, collisions, permission errors (test-plan T4) | |
| AC-D3 | Status on all devices | custom fields filled on all devices; containers plausible (all `HR-Open` before the pilot) | |

## 6. Acceptance and abort criteria

### Continue to the next wave when

- every device of the wave is in `HR-Done` or explained (`HR-Permanent` with a reason, `HR-Stale` = never on LAN/DA);
- no device of the wave has lost its domain connection or WLAN for good;
- helpdesk calls caused by the rename are known and solved (for example missing WLAN until the certificate is renewed);
- no duplicates in ACMP and no unexpected name dependencies (test-plan D1–D7).

### Stop the rollout immediately when

- a device cannot log on to the domain after the reboot (secure channel broken) or loses DirectAccess for good;
- WLAN users without a cable are cut off on a large scale even though the certificate renewal is in the flow;
- ACMP creates duplicates or loses assignments (licenses, inventory) after the rename;
- a script exit code other than 0, 1, 2, 3, 4, 5, 20–22 or 3010 appears.

To stop, deactivate **HostRename – Rename** or remove the assignment. Devices that are already renamed stay renamed. Devices that are renamed but not yet rebooted keep that state: decide whether to reboot them or to rename them back.

### Renaming a single device back

On the device, as administrator: `Rename-Computer -NewName <OldName> -Restart` (the old name is in `HostRenameState\OriginalName`), then `Remove-Item HKLM:\SOFTWARE\HostRename, HKLM:\SOFTWARE\HostRenameState -Recurse -ErrorAction SilentlyContinue`. Remove the device from the wave container, otherwise it is renamed again. For WLAN devices the certificate must then be renewed for the old name.

## 7. Where to look when something goes wrong

| Symptom | First look | Typical cause |
| --- | --- | --- |
| Device stays in `HR-Open` | job history: gate line | never on LAN/DA (gate 20/21/22); Client Command not assigned |
| `HR_LastExitCode = 1` | ACMP output, local log | DC not reachable, secure channel, `LOCAL_DIR`, `PLATFORM` (32-bit) |
| Exit 4 | local log `PERM_CHECK` / `PERM_DENIED` | delegation missing for the device's OU; after fixing it, release the device: `Remove-ItemProperty -Path HKLM:\SOFTWARE\HostRenameState -Name LastExitCode` (otherwise the Client Command ends at step 1 with `phase=permanent`) |
| Stuck in `HR-RebootPending` | reboot dialog / deadline | user postpones, reboot not triggered by ACMP |
| Stuck in `HR-AfterReboot` | certificate line, local log `CLEANUP_DEFERRED` | certificate step fails, central log unreachable |
| WLAN does not work after the reboot | certificate store, `HR_Cert` | certificate not yet renewed (device needs cable or DA once) |
| Custom fields empty or old | `HR_LastRun`, Status Client Command | status not scheduled, 32-bit registry view |
