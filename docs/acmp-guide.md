# Guide: building the ACMP Client Command "HostRename"

[Deutsche Version](de/acmp-anleitung.md) · Background: [ACMP deployment plan](acmp-deployment-plan.md) · Tests: [test plan](test-plan.md)

As of: 3 November 2026 · Version 1.2.0

> **Test status:** Everything described here is new in 1.2.0. The scripts were tested only with mocks (Linux, PowerShell 7). Nothing has been confirmed yet on real Windows devices or in ACMP. Which ACMP editor elements exist and how they are named is **not known** here: those places are marked "verify in ACMP". The suggested flow is a starting point to be adjusted during the device tests ([test-plan.md](test-plan.md)).

GPO and ACMP are **alternative** deployment methods. Never run both on the same device: do not link the HostRename GPO for devices that get the Client Command.

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
- For the certificate step: the **template name** (not the display name) of the WLAN machine certificate. It is not known yet and must be determined first.

## 2. File repository

Put these files into ACMP's file repository (verify in ACMP: where and how files are managed and transferred to the client):

| File | Needed for |
| --- | --- |
| `Invoke-HostRename.ps1` | rename, cleanup |
| `Test-DeploymentNetwork.ps1` | network gate |
| `Update-ComputerCertificate.ps1` | certificate renewal (only if WLAN devices are in scope) |

The scripts are UTF-8 with BOM. Keep the encoding and do not edit them in the repository. The cleanup in ACMP mode never deletes the script file or its folder: the file belongs to ACMP's cache.

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
| `-CentralLogPath` | path of the central CSV log; `''` (empty) disables it. Without a central log the local log files are kept as the only evidence |
| `-LocalDir` | local log folder (ACMP mode default: `C:\ProgramData\HostRename`) |
| `-Cleanup` | final run: set the marker, deliver logs, remove the local logs (if a central log is used) |
| `-WhatIf` | only shows the target name, changes nothing, writes no reporting values |

```powershell
# dry run
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-HostRename.ps1 -Deployment Acmp -NameTemplate "DE{Serial}" -CentralLogPath '' -WhatIf
# rename without central log
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-HostRename.ps1 -Deployment Acmp -NameTemplate "DE{Serial}" -CentralLogPath ''
# rename with central log
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-HostRename.ps1 -Deployment Acmp -NameTemplate "DE{Serial}" -CentralLogPath "\\<Server>\HostRename$\log\rename-log.csv"
# final run after the reboot
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-HostRename.ps1 -Deployment Acmp -NameTemplate "DE{Serial}" -CentralLogPath '' -Cleanup
```

Use the **same** template in all calls (a different template triggers a new rename). Do not pass `-Reboot`: ACMP controls the reboot. Without `-CentralLogPath`, the default is a placeholder path (`\\FILESERVER\...`), so always pass either a real path or `''`.

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

## 4. Flow of the Client Command

```text
1  state check        done?            -> end
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
if (Test-Path 'HKLM:\SOFTWARE\HostRename') { exit 0 }   # done: the Client Command ends here
$t = (Get-ItemProperty 'HKLM:\SOFTWARE\HostRenameState' -ErrorAction SilentlyContinue).TargetName
if ($t -and $env:COMPUTERNAME -ieq $t) { 'phase=after-reboot' } else { 'phase=rename' }
```

Using the name comparison is optional: `Invoke-HostRename.ps1` is idempotent. If the name already matches, it returns 0 (nothing to do) or, while a reboot is pending, 3010 again.

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

`Invoke-HostRename.ps1 -Deployment Acmp -Cleanup` delivers the logs (only with a central log), sets the marker `HKLM\SOFTWARE\HostRename` and removes a scheduled task if one exists (there is none under ACMP). The script file and its folder stay. With a central log, the local logs are removed after delivery; without one, they stay in `C:\ProgramData\HostRename`. After this run, step 1 reports "done" from then on.

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
| 100 and above, 1001 and above | ACMP itself | ACMP's own codes | do not collide with the script codes (all below 100); how ACMP maps them: verify in ACMP |

Whether and how ACMP passes through the exit code of a PowerShell script (especially 3010) is one of the device tests (test plan, ACMP section).

### Suggested dialog texts (examples, adjust to your company)

| Situation | Text |
| --- | --- |
| Exit 20 (WLAN only) | "Bitte LAN-Kabel anschließen. Die Umbenennung Ihres Geräts ist nur über das Firmennetz per Kabel oder über DirectAccess möglich. Die Aktion wird später automatisch wiederholt." |
| Exit 3010 (reboot) | "Ihr Gerät wurde umbenannt und muss neu gestartet werden. Bitte speichern Sie Ihre Arbeit und lassen Sie das LAN-Kabel bis nach dem Neustart angeschlossen." |
| Done | "Die Umbenennung ist abgeschlossen." |

Whether dialogs can appear in the user session while the Client Command runs as SYSTEM is one of the device tests.

## 6. Reporting via ACMP custom fields

`Invoke-HostRename.ps1` writes after every run (not with `-WhatIf`) these values to `HKLM\SOFTWARE\HostRenameState`. They are for reporting only; the script logic never reads them.

| Registry value | Content |
| --- | --- |
| `LastRun` | time of the last run (`yyyy-MM-ddTHH:mm:sszzz`) |
| `LastExitCode` | exit code of the last run (DWORD) |
| `LastEvent` | last event code logged (e.g. `RENAMED`, `CLEANUP_DONE`, `PERM_DENIED`) |
| `Deployment` | `Acmp` or `Gpo` |
| `ScriptVersion` | e.g. `1.2.0` |
| `TargetName` | target name (only after a rename) |

Further useful source: the marker `HKLM\SOFTWARE\HostRename` (`Completed`, `ComputerName`) for "done". How ACMP custom fields are defined and filled from registry values: verify in ACMP. The local log is `C:\ProgramData\HostRename\rename-local.csv`; it is kept if no central log is used.

## 7. Checklist for building and rollout

1. Set the delegation; no GPO link for these devices.
2. Fill the file repository (3 scripts).
3. Build the Client Command per section 4, first with `-WhatIf` and `-CentralLogPath ''`.
4. Run the device tests ([test-plan.md](test-plan.md), T3), adjust flow, texts and reboot deadline.
5. Dry run on all devices (T4), then waves (T5).
