# Guide: building the ACMP Client Command "HostRename"

[Deutsche Version](de/acmp-anleitung.md) · Background: [ACMP deployment plan](acmp-deployment-plan.md) · Rollout and run verification: [acmp-rollout.md](acmp-rollout.md) · Tests: [test plan](test-plan.md)

As of: 3 November 2026 · Version 1.2.0

> **Test status:** Everything described here is new in 1.2.0. The scripts were tested only with mocks, in an end-to-end simulation and in CI (Windows PowerShell 5.1 and PowerShell 7, without AD or ACMP). Nothing has been confirmed yet on real Windows devices or in ACMP. Which ACMP editor elements exist and how they are named is **not known** here: those places are marked "verify in ACMP". The suggested flow is a starting point to be adjusted during the device tests ([test-plan.md](test-plan.md)).

GPO and ACMP are **alternative** deployment methods. Never run both on the same device: do not link the HostRename GPO for devices that get the Client Command.

## Recommended: the wrapper `Invoke-AcmpHostRename.ps1`

`Invoke-AcmpHostRename.ps1` implements the whole flow of section 4 (state check, gate, rename, certificate, cleanup) in **one script run per ACMP invocation**. It calls `Invoke-HostRename.ps1`, `Test-DeploymentNetwork.ps1` and `Update-ComputerCertificate.ps1` unchanged from its own folder, in the same PowerShell process, passes their output through and ends with one summary line and one exit code. The Client Command then needs no state check, no step sequence and no evaluation of intermediate exit codes. Like everything in 1.2.0, the wrapper has run only in the simulation (`HostRename.Simulation.Tests.ps1`), not yet in ACMP.

**What the Client Command contains** (ACMP menu names: verify in ACMP):

1. Transfer the four scripts into one folder on the client: `Invoke-AcmpHostRename.ps1`, `Invoke-HostRename.ps1`, `Test-DeploymentNetwork.ps1`, `Update-ComputerCertificate.ps1` (the last one is only used with `-CertificateTemplate`; transferring it always does no harm).
2. Run the wrapper as SYSTEM in the **64-bit** Windows PowerShell (command lines below).
3. Condition on the exit code: **3010** → reboot dialog, reboot by ACMP; **20** → dialog "connect LAN cable"; **any other code** → end. The next scheduled run continues where the device stands.

Every run re-reads the state from the registry, so the same Client Command is simply run again (at agent start, logon or daily) until the device is done; on a done device the wrapper ends at once with exit code 0.

```powershell
# LAN/DirectAccess devices (no certificate step)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-AcmpHostRename.ps1 -NameTemplate "DE{Serial}" -NoCentralLog -CorporateSsid "CORP-WLAN"
# WLAN devices: after the reboot renew the WLAN machine certificate, then clean up
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-AcmpHostRename.ps1 -NameTemplate "DE{Serial}" -NoCentralLog -CorporateSsid "CORP-WLAN" -CertificateTemplate "<TemplateName>" -RemoveOldCertificates
# with central log: -CentralLogPath "\\<Server>\HostRename$\log\rename-log.csv" instead of -NoCentralLog
# dry run (Client Command "HostRename – Dry run"): the same line plus -WhatIf
# 32-bit ACMP agent on 64-bit Windows: the same lines with the 64-bit PowerShell
%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-AcmpHostRename.ps1 -NameTemplate "DE{Serial}" -NoCentralLog -CorporateSsid "CORP-WLAN"
```

Parameters: the naming parameters of `Invoke-HostRename.ps1` (`-NameTemplate`, `-Prefix`, `-Suffix`, `-OnTooLong`, `-OnSerialProblem`, `-FutureIdLength`) and the gate parameters (`-Allow`, `-CorporateSsid`, `-DomainName`) are passed through unchanged (section 3). **Exactly one** of `-NoCentralLog` or `-CentralLogPath <UNC path>` is required; otherwise the wrapper ends with exit code 1, so the placeholder default of `Invoke-HostRename.ps1` cannot be used by accident. `-CorporateSsid` lets the gate recognize the corporate WLAN so that a device on WLAN only gets exit code 20 (cable dialog). `-CertificateTemplate` (template name, not display name) adds the certificate step after the reboot; `-RemoveOldCertificates` passes `-RemoveOld`. `-WhatIf` runs only the gate and `Invoke-HostRename.ps1 -WhatIf` (no certificate, no cleanup) and writes nothing; in the dry-run Client Command, show no dialogs. Details: `Get-Help .\Invoke-AcmpHostRename.ps1 -Full`.

**Exit codes of the wrapper**

| Exit code | `PHASE` in the summary line | Meaning | Reaction in the Client Command |
| --- | --- | --- | --- |
| 0 | `Done`, `Cleanup`, `DryRun` | done, or nothing more to do in this run (`Cleanup`: cleanup deferred, the next run completes it) | end |
| 3010 | `RebootRequired` | renamed or rename pending, reboot required | reboot dialog, reboot by ACMP |
| 20 | `Gate` | only the corporate WLAN | dialog "connect LAN cable", end |
| 21, 22 | `Gate` | no domain connection / path not allowed or unknown | end silently, retry later |
| 1 | `Error`, `Gate`, `Rename`, `Certificate`, `Cleanup` | error (also `PLATFORM`, missing parameter or script, certificate not renewed) | end, retry later; after several failures check the output |
| 2, 4, 5 | `Permanent` | name too long / no permission (delegation) / no usable serial number | end; manual action, then release (section 4, step 1) |

The last line of the output is always the summary line, for example:

```text
HOSTRENAME PHASE=RebootRequired EXIT=3010 STEP=Rename MESSAGE="Renamed or rename pending: reboot required."
```

`STEP` names the step that decided (`Platform`, `Parameters`, `StateCheck`, `Gate`, `Rename`, `Certificate`, `Cleanup`). Before every called script the wrapper prints `HOSTRENAME STEP=<step> RUN=<script>`, followed by that script's own output (gate line `RESULT=...`, events of `Invoke-HostRename.ps1`, certificate line `RESULT=...`). A device with a permanent error (2, 4, 5) ends at the state check with the same code on every run until `LastExitCode` is removed (section 4, step 1). Reporting (section 6) and the status Client Command ([acmp-rollout.md](acmp-rollout.md), section 4.3) stay as they are.

## 1. Prerequisites

- **Delegation** stays necessary: under ACMP the device also renames with its own computer account (SYSTEM). Set it once on an admin PC or DC, as a domain admin, in an elevated PowerShell:

  ```powershell
  .\Prepare-HostRename.ps1 -Action Setup -Component Delegation
  # a single OU in addition or instead of $ClientOuDN:
  .\Prepare-HostRename.ps1 -Action Setup -Component Delegation -OuDN 'OU=Notebooks,DC=contoso,DC=com'
  ```

  The OU list is `$ClientOuDN` in the block "ADJUST HERE" of `Prepare-HostRename.ps1`.
- **Share** (`-Component Share`) only if the central CSV log is to be used. Without a central log, no share is needed.
- **No GPO** for these devices (do not create the main GPO, or do not link it to the OUs of ACMP devices).
- Devices run Windows PowerShell 5.1 (always present); call the scripts with `powershell.exe -NoProfile -ExecutionPolicy Bypass -File ...`.
- **64-bit PowerShell is required.** If the ACMP agent is a 32-bit process, `powershell.exe` resolves to the 32-bit `SysWOW64` copy and registry writes to `HKLM\SOFTWARE` land in `WOW6432Node` (the device would never count as "done"). `Invoke-HostRename.ps1 -Deployment Acmp` therefore refuses to run in a 32-bit process on 64-bit Windows: it prints `[ERROR] PLATFORM: ...` on stdout and ends with exit code 1 before writing anything (no log, no reporting values). In that case call `%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe` instead of `powershell.exe` (`Sysnative` is only visible to 32-bit processes). Whether the ACMP agent runs as 32 or 64 bit: verify in ACMP (device test A1).
- For the certificate step: the **template name** (not the display name) of the WLAN machine certificate. It is not known yet and must be determined first.

## 2. File repository

Put these files into ACMP's file repository (verify in ACMP: where and how files are managed and transferred to the client):

| File | Needed for |
| --- | --- |
| `Invoke-AcmpHostRename.ps1` | wrapper: the whole flow in one run (recommended) |
| `Invoke-HostRename.ps1` | rename, cleanup |
| `Test-DeploymentNetwork.ps1` | network gate |
| `Update-ComputerCertificate.ps1` | certificate renewal (only if WLAN devices are in scope) |

All four files lie flat in one folder in the ACMP release package `HostRename-<version>-acmp.zip`; take them from there (in the source repository they live in `deployments/acmp/`, the root and `components/`). The scripts are UTF-8 with BOM. Keep the encoding and do not edit them in the repository. The cleanup in ACMP mode never deletes the script file or its folder: the file belongs to ACMP's cache.

## 3. Parameters per script

All calls run as SYSTEM through `powershell.exe -NoProfile -ExecutionPolicy Bypass -File <script> ...`. Details: `Get-Help .\<script>.ps1 -Full`.

### `Test-DeploymentNetwork.ps1` (gate)

| Parameter | Meaning |
| --- | --- |
| `-Allow` | allowed paths: `Lan`, `DirectAccess`, `Wlan` (default `Lan, DirectAccess`). With `-File`, a comma list such as `-Allow Lan,DirectAccess` arrives as one string; the script accepts that |
| `-CorporateSsid` | SSID(s) of the corporate EAP-TLS WLAN (comma-separated); without it, exit 20 only occurs for a domain-authenticated WLAN |
| `-DomainName` | domain whose DCs must be reachable (default: own domain) |
| `-Quiet` | no result line on stdout, exit code only |

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-DeploymentNetwork.ps1 -CorporateSsid "CORP-WLAN"
```

The script prints exactly one summary line, e.g. `RESULT=LAN EXIT=0 DOMAIN=... DC=... LAN=DomainAuthenticated ...`. Capture it in the ACMP log (verify in ACMP).

### `Invoke-HostRename.ps1` (rename)

Parameters relevant for ACMP:

| Parameter | Meaning |
| --- | --- |
| `-Deployment Acmp` | ACMP mode: local logs in `C:\ProgramData\HostRename`, `-Reboot` is ignored (event `REBOOT_IGNORED`), `-Cleanup` keeps the script file and folder |
| `-NameTemplate` / `-Prefix` / `-Suffix` | renaming rule, as in the README, e.g. `-NameTemplate "DE{Serial}"` |
| `-OnTooLong`, `-OnSerialProblem`, `-FutureIdLength` | as in the README (name too long, unusable serial number) |
| `-NoCentralLog` | no central log: only the local log is written, nothing waits for delivery, the local log files are kept as the only evidence |
| `-CentralLogPath` | UNC path of the central CSV log (only if a central log is used). A value that is not an absolute path disables the central log with the warning `LOG_CHECK` in the local log |
| `-LocalDir` | local log folder; leave it out in ACMP mode (default `C:\ProgramData\HostRename`, protected, see below). An explicit folder is used as given: it must not be writable for standard users |
| `-Cleanup` | final run: set the marker, deliver logs, remove the local logs (if a central log is used) |
| `-WhatIf` | only shows the target name, changes nothing, writes no reporting values |

```powershell
# dry run
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-HostRename.ps1 -Deployment Acmp -NameTemplate "DE{Serial}" -NoCentralLog -WhatIf
# rename without central log
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-HostRename.ps1 -Deployment Acmp -NameTemplate "DE{Serial}" -NoCentralLog
# rename with central log
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-HostRename.ps1 -Deployment Acmp -NameTemplate "DE{Serial}" -CentralLogPath "\\<Server>\HostRename$\log\rename-log.csv"
# final run after the reboot
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-HostRename.ps1 -Deployment Acmp -NameTemplate "DE{Serial}" -NoCentralLog -Cleanup
# 32-bit ACMP agent on 64-bit Windows: same calls with the 64-bit PowerShell
%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-HostRename.ps1 -Deployment Acmp -NameTemplate "DE{Serial}" -NoCentralLog
```

Use the **same** template in all calls (a different template triggers a new rename). Do not pass `-Reboot`: ACMP controls the reboot (if it is passed anyway, the warning `REBOOT_IGNORED` appears in the local log on every run). Without `-CentralLogPath`, the default is a placeholder path (`\\FILESERVER\...`), so always pass either `-NoCentralLog` or a real UNC path. Do not use `-CentralLogPath ''`: with `powershell.exe -File` the two quote characters arrive literally (or, in some consoles, the empty argument is dropped). The script treats `''`, `""` and blank values as "no central log", but `-NoCentralLog` is the documented way.

**Protected log folder.** Standard users may create folders in `C:\ProgramData`. Before writing anything, the script therefore checks the default folder `C:\ProgramData\HostRename`: if it exists, it must not be a junction or symbolic link and must be owned by SYSTEM or Administrators; files in it must not be reparse points and must be owned by SYSTEM or Administrators. Otherwise the script prints `[ERROR] LOCAL_DIR: ...` on stdout, does not use the folder and ends with exit code 1 (the reporting values are still written). An administrator then removes the folder; the next run recreates it. On every run the script sets owner Administrators, removes inheritance and grants full control only to SYSTEM and Administrators (folder and files, by SID with `icacls`). Standard users can therefore no longer read the local logs.

### `Update-ComputerCertificate.ps1` (certificate renewal)

| Parameter | Meaning |
| --- | --- |
| `-Template` | **mandatory**: template name of the WLAN machine certificate |
| `-ExpectedDnsName` | DNS name the certificate must contain (default: `<host name>.<machine domain>`) |
| `-RemoveOld` | remove other certificates of the same template whose SAN lacks the expected name, including private keys; only after a valid new one is confirmed. Without it, nothing is removed |
| `-MinValidDays` | an existing matching certificate valid longer than this counts as current (default 30) |
| `-WhatIf` | shows whether a certificate would be requested |

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Update-ComputerCertificate.ps1 -Template <TemplateName> -WhatIf
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Update-ComputerCertificate.ps1 -Template <TemplateName> -RemoveOld
```

The last stdout line is a summary: `RESULT=RENEWED|NOT_NEEDED|WHATIF|ERROR EXIT=... TEMPLATE=... DNS=...`. While a rename is still waiting for the reboot, the script ends with exit code 1.

## 4. Alternative: individual steps (flow of the Client Command)

This is the flow the wrapper implements. Build it from individual steps only if the wrapper cannot be used.

```text
1  state check        done?            -> end
                      permanent error? -> end (until released)
2  gate               20 -> dialog "connect LAN cable", end (retry later)
                      21, 22 -> end silently (retry later)
3  rename             Invoke-HostRename.ps1 -Deployment Acmp ...
4  evaluate exit code 3010 -> reboot dialog, reboot by ACMP
                      0    -> continue with phase "after reboot"
                      1    -> end, retry on the next run
                      2,4,5 -> permanent, do not retry, report
   --- after the reboot (next run of the Client Command) ---
5  state check        marker missing, TargetName present -> continue
6  gate               same as above
7  certificate        only WLAN devices: Update-ComputerCertificate.ps1 -Template ... [-RemoveOld]
8  cleanup            Invoke-HostRename.ps1 -Deployment Acmp ... -Cleanup
9  report             custom fields from the registry
```

How the Client Command is rerun later (schedule, "retry later", repetition on failure) is an ACMP matter: verify in ACMP.

### Step 1: state check (deciding "done")

The device is **done** when the marker key `HKLM\SOFTWARE\HostRename` exists. The cleanup sets it as its last step. A rename has happened (and the device waits for reboot, certificate or cleanup) when `TargetName` exists in `HKLM\SOFTWARE\HostRenameState`.

> **Never use the mere existence of the key `HKLM\SOFTWARE\HostRenameState` as the "done" criterion.** Since 1.2.0 it exists after every run, because the script writes the reporting values there (`LastRun`, `LastExitCode`, ...), even after an error or "nothing to do".

Example (PowerShell, for a condition or script step; verify in ACMP how the result is evaluated):

```powershell
if (Test-Path 'HKLM:\SOFTWARE\HostRename') { 'phase=done'; exit 0 }   # done: the Client Command ends here
$s = Get-ItemProperty 'HKLM:\SOFTWARE\HostRenameState' -ErrorAction SilentlyContinue
if ($s.LastExitCode -in 2, 4, 5) { 'phase=permanent'; exit 0 }   # permanent error: end until released
if ($s.TargetName -and $env:COMPUTERNAME -ieq $s.TargetName) { 'phase=after-reboot' } else { 'phase=rename' }
```

The snippet always ends with exit code 0; the phase is in its output (`phase=done`, `phase=permanent`, `phase=after-reboot` or `phase=rename`). Using the name comparison is optional: `Invoke-HostRename.ps1` is idempotent. If the name already matches, it returns 0 (nothing to do) or, while a reboot is pending, 3010 again.

**Permanent errors.** After exit code 2, 4 or 5 the script has stored it in `LastExitCode`. Because the marker is absent, step 1 then ends with `phase=permanent` on every following run: the Client Command stops there and neither the gate nor the script runs again, so a device with a permanent error is not retried endlessly. To release a device after the cause is fixed (for example the delegation), delete the value, as administrator on the device or through a small ACMP Client Command:

```powershell
Remove-ItemProperty -Path HKLM:\SOFTWARE\HostRenameState -Name LastExitCode
```

The next run then proceeds with step 2. A later successful run overwrites `LastExitCode` anyway; if the cause is not fixed, the run ends with the same exit code again and the device is blocked again.

### Step 2 and 6: gate

| Exit code | Meaning | Reaction |
| --- | --- | --- |
| 0 | allowed path (LAN/DirectAccess), DC reachable | continue |
| 20 | only corporate WLAN | dialog asking for the LAN cable, end, retry later |
| 21 | no domain connection | end silently, retry later |
| 22 | path not allowed or unknown | end silently, retry later |
| 1 | unexpected error | end, retry later, report |

### Step 3 and 4: rename and exit-code evaluation

See the exit-code contract below. After 3010, show the reboot dialog and let ACMP reboot (suggested texts in section 5). The dialog should say: keep the cable connected until after the reboot.

The reboot deadline (how long a user may postpone) is **open** and will be decided during the device tests. Reason for promptness: between rename and reboot, the name of the computer and its AD account differ (risk for the DirectAccess tunnel and for WLAN logons). Check whether ACMP's existing reboot dialog can be used (verify in ACMP).

### Step 7: certificate (WLAN devices only)

Only on devices that use the EAP-TLS WLAN. Whether this step is needed at all is clarified in the device tests. How to select "WLAN devices" in ACMP (group, custom field, condition) is open: verify in ACMP. If the step ends with exit code 1, the Client Command ends and retries on the next run (without the cleanup).

### Step 8: cleanup

`Invoke-HostRename.ps1 -Deployment Acmp -Cleanup` delivers the logs (only with a central log), sets the marker `HKLM\SOFTWARE\HostRename` and removes a scheduled task if one exists (there is none under ACMP). The script file and its folder stay. With a central log, the local logs are removed after delivery; without one, they stay in `C:\ProgramData\HostRename`. After this run, step 1 reports "done" from then on. The cleanup events (`CLEANUP`, `CLEANUP_DONE`, `CLEANUP_DEFERRED`, `CLEANUP_FAILED`) appear on stdout, so they are part of the ACMP job output as well as the local log and `LastEvent`.

## 5. Exit-code contract

| Exit code | Source | Meaning | Reaction |
| --- | --- | --- | --- |
| 0 | all | done / nothing to do / `-WhatIf` / gate: allowed path | continue |
| 3010 | `Invoke-HostRename.ps1` | renamed (or rename pending), reboot required | reboot dialog, reboot by ACMP |
| 1 | all | error, details in the log | retry on the next run; after several failures into the report |
| 2 | `Invoke-HostRename.ps1` | name too long (`-OnTooLong Skip`) | permanent, do not retry, report |
| 4 | `Invoke-HostRename.ps1` | no permission on the own AD object | permanent, check the delegation, report |
| 5 | `Invoke-HostRename.ps1` | no usable serial number (`-OnSerialProblem Skip`) | permanent, do not retry, report |
| 20 | `Test-DeploymentNetwork.ps1` | only corporate WLAN | dialog "connect LAN cable", retry later |
| 21 | `Test-DeploymentNetwork.ps1` | no domain connection | silent, retry later |
| 22 | `Test-DeploymentNetwork.ps1` | path not allowed / unknown | silent, retry later |
| 100 and above, 1001 and above | ACMP itself | ACMP's own codes | how ACMP maps them: verify in ACMP |

The script codes are 0, 1, 2, 4, 5, 20 to 22 and 3010 (3 is not used). All except 3010 are below ACMP's own ranges; **3010 lies numerically in ACMP's range (1001 and above)**. Verify in ACMP how 3010 from a script is treated: passed through unchanged, usable in a condition, or interpreted as an ACMP code (device test A1).

Under `LOCAL_DIR` and `PLATFORM` (see above) exit code 1 has no entry in the local log; the reason is only on stdout (ACMP output).

### Suggested dialog texts (examples, adjust to your company)

| Situation | Text |
| --- | --- |
| Exit 20 (WLAN only) | "Bitte LAN-Kabel anschließen. Die Umbenennung Ihres Geräts ist nur über das Firmennetz per Kabel oder über DirectAccess möglich. Die Aktion wird später automatisch wiederholt." |
| Exit 3010 (reboot) | "Ihr Gerät wurde umbenannt und muss neu gestartet werden. Bitte speichern Sie Ihre Arbeit und lassen Sie das LAN-Kabel bis nach dem Neustart angeschlossen." |
| Done | "Die Umbenennung ist abgeschlossen." |

Whether dialogs can appear in the user session while the Client Command runs as SYSTEM is one of the device tests.

## 6. Reporting via ACMP custom fields

`Invoke-HostRename.ps1` writes after every run (not with `-WhatIf`, not in a 32-bit process) these values to `HKLM\SOFTWARE\HostRenameState`. They are for reporting only; the script logic never reads them.

| Registry value | Content |
| --- | --- |
| `LastRun` | time of the last run (`yyyy-MM-ddTHH:mm:sszzz`) |
| `LastExitCode` | exit code of the last run (DWORD): **the primary status** |
| `LastEvent` | the event code that was logged last in this run; a detail, not a status (see below) |
| `Deployment` | `Acmp` or `Gpo` |
| `ScriptVersion` | e.g. `1.2.0` |
| `TargetName` | target name (only after a rename) |

`LastEvent` is simply the last line written to the log, so it is not the "result" of the run: after a successful rename, `AD_VERIFY` follows `RENAMED`, and `LOG_DELIVERY` can follow when the central log is unreachable. Use `LastExitCode` for the status and `LastEvent` only as a hint. Realistic combinations:

| Situation | `LastExitCode` | typical `LastEvent` |
| --- | --- | --- |
| renamed, reboot pending | 3010 | `AD_VERIFY` (or `LOG_DELIVERY`) |
| rerun before the reboot | 3010 | `PENDING_REBOOT` |
| name already matches | 0 | `ALREADY_DONE` |
| final run with `-Cleanup` | 0 | `CLEANUP_DONE` (or `CLEANUP_DEFERRED`/`LOG_DELIVERY` while the central log is unreachable) |
| no permission on the own AD object | 4 | `PERM_DENIED` |
| other errors | 1 | e.g. `PRECHECK`, `RENAME_FAILED`, `COLLISION`, `LOCAL_DIR` |

Further useful source: the marker `HKLM\SOFTWARE\HostRename` (`Completed`, `ComputerName`) for "done". How ACMP custom fields are defined and filled from registry values: verify in ACMP. The local log is `C:\ProgramData\HostRename\rename-local.csv`; it is kept if no central log is used.

## 7. Checklist for building and rollout

1. Set the delegation; no GPO link for these devices.
2. Fill the file repository (4 scripts, including the wrapper).
3. Build the Client Command with the wrapper (section "Recommended: the wrapper"; alternatively per section 4), first with `-WhatIf` and `-NoCentralLog` (64-bit PowerShell, see section 1).
4. Run the device tests ([test-plan.md](test-plan.md), T3), adjust flow, texts and reboot deadline.
5. Dry run on all devices (T4), then waves (T5).
