# ACMP starter kit: first test of HostRename in ACMP

Build guide: [acmp-guide.md](acmp-guide.md) · Rollout and run verification: [acmp-rollout.md](acmp-rollout.md) · Device tests: [test-plan.md](test-plan.md)

As of: 3 November 2026 · Version 1.2.0

A hand-over for a tester who has ACMP but has never seen this project. It contains only what is needed for the first tests; the background is in the linked documents.

## 1. What this is

HostRename renames domain-joined Windows clients by a name template (for example `DE` + serial number) and renames their AD computer object at the same time; the device does this itself as SYSTEM, with a delegated permission on its own AD object (no password). Under ACMP, one Client Command runs the wrapper `Invoke-AcmpHostRename.ps1` again and again: it checks the state, checks the network (LAN cable or DirectAccess only), renames, asks for a reboot (exit code 3010), renews the WLAN certificate after the reboot if configured, and marks the device as done. The Client Command only has to transfer four scripts, start the wrapper and show a dialog for two exit codes.

> **Test status: nothing has run in ACMP yet.** The scripts were tested only in a simulation with mocks (Linux, PowerShell 7). Your tests are the first real ones. ACMP menu and command names below are generic and marked "verify in ACMP": please note the real names.

## 2. Values to fill in

The owner provides these values before the test. Use them identically in every Client Command.

| Value | Placeholder | Filled in by owner |
| --- | --- | --- |
| Name template | `<NameTemplate>` (e.g. `DE{Serial}`) | |
| Central log | yes / no; if yes: `<UNC path>` (e.g. `\\<Server>\HostRename$\log\rename-log.csv`) | |
| Corporate WLAN SSID(s) | `<CorporateSsid>` (comma-separated) | |
| Certificate template name (WLAN devices only; template name, not display name) | `<CertificateTemplate>` | |
| Test OU | `<OU DN>` | |
| Test devices | LAN: `<name>` · DirectAccess (optional): `<name>` · WLAN user: `<name>` | |

## 3. Prerequisites checklist

- [ ] **Delegation** set on the test OU, by a domain admin on an admin PC or DC, in an elevated PowerShell; first with `-WhatIf`:

  ```powershell
  .\Prepare-HostRename.ps1 -Action Setup -Component Delegation -OuDN '<OU DN>' -WhatIf
  .\Prepare-HostRename.ps1 -Action Setup -Component Delegation -OuDN '<OU DN>'
  ```

- [ ] With a central log only: the share exists (`-Component Share`, run on the file server; see [README](../README.md)).
- [ ] **No HostRename GPO** linked to the test devices (GPO and ACMP are never used on the same device).
- [ ] 2–3 **dedicated test devices** in the test OU: one on LAN cable, optionally one on DirectAccess, one WLAN user (uses the corporate WLAN with a machine certificate). Nobody depends on their names.
- [ ] The files from the repository, unchanged (UTF-8 with BOM; do not open and save them in an editor): `Invoke-AcmpHostRename.ps1`, `Invoke-HostRename.ps1`, `Test-DeploymentNetwork.ps1`, `Update-ComputerCertificate.ps1`.

## 4. Build the Client Command "HostRename – Rename"

ACMP background (from the Aagon documentation; verify in ACMP): a Client Command is created and edited in the **Create/Edit** phase, tried on test clients in the **Test** phase, then goes through **Synchronise** and **Release** before it can be assigned in the **Execute** phase.

1. **Create** a new Client Command `HostRename – Rename` (verify in ACMP: where Client Commands are created).
2. **Transfer the files.** Add the four scripts so that they are copied into the same folder on the client, for example the project directory `%PROJECTDIR%`. Verify in ACMP: the exact file-transfer command, whether `%PROJECTDIR%` is the right target, and whether the ACMP client deletes this temporary folder after the run (the scripts do not need to stay; every run transfers them again).
3. **Run the wrapper** as SYSTEM in the **64-bit** Windows PowerShell (verify in ACMP: the command that runs a program or PowerShell, and whether it runs 32-bit). Working folder = the folder of the scripts. LAN/DirectAccess devices:

   ```text
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PROJECTDIR%\Invoke-AcmpHostRename.ps1" -NameTemplate "<NameTemplate>" -NoCentralLog -CorporateSsid "<CorporateSsid>"
   ```

   WLAN devices (adds the certificate renewal after the reboot):

   ```text
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PROJECTDIR%\Invoke-AcmpHostRename.ps1" -NameTemplate "<NameTemplate>" -NoCentralLog -CorporateSsid "<CorporateSsid>" -CertificateTemplate "<CertificateTemplate>" -RemoveOldCertificates
   ```

   With a central log, replace `-NoCentralLog` by `-CentralLogPath "<UNC path>"`. If the ACMP agent runs 32-bit, use `%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe` instead of `powershell.exe` (otherwise the wrapper ends with exit 1 and `[ERROR] PLATFORM`).
4. **Store the output and the exit code** (verify in ACMP: how stdout and the exit code of the command are captured into variables or the job log). The last output line is the summary line `HOSTRENAME PHASE=... EXIT=... STEP=... MESSAGE="..."`.
5. **Evaluate the exit code** with conditions:
   - **3010** → reboot dialog to the user, then reboot by ACMP. Text suggestion: "Ihr Gerät wurde umbenannt und muss neu gestartet werden. Bitte speichern Sie Ihre Arbeit und lassen Sie das LAN-Kabel bis nach dem Neustart angeschlossen."
   - **20** → message to the user: "Bitte LAN-Kabel anschließen. Die Umbenennung Ihres Geräts ist nur über das Firmennetz per Kabel oder über DirectAccess möglich. Die Aktion wird später automatisch wiederholt."
   - **anything else** → end without a dialog.
   Verify in ACMP: the dialog and reboot commands, whether dialogs reach the logged-on user while the command runs as SYSTEM, and how a reboot deadline is set.
6. **Do not mark codes other than 0 as "failed" in a way that stops repetition**: 1, 20, 21 and 22 mean "try again later". 2, 4 and 5 are permanent; the wrapper keeps returning them without doing anything until the device is released (section 8).
7. **Repetition**: the Client Command must run again on the same device (after the reboot, and while it waits for a cable). Use a schedule such as agent start plus daily (verify in ACMP). On a finished device the wrapper ends at once with exit 0.
8. Create a second Client Command `HostRename – Dry run` with the same command line plus `-WhatIf`, without dialogs and without reboot.
9. **Test, Synchronise, Release** (verify in ACMP), then assign only to the test devices.

## 5. First test sequence

Record the result of each test in the table in section 7.

| ID | Test | Device | Expected result |
| --- | --- | --- | --- |
| T-A1 | 64-bit check: a test command runs `powershell.exe -NoProfile -Command "[Environment]::Is64BitProcess"` | any | `True`; if `False`, use the Sysnative path |
| T-A2 | Exit code passthrough: test commands with `exit 0`, `exit 20`, `exit 3010` | any | each code arrives unchanged in the condition; note how ACMP treats 3010 (it lies in ACMP's own code range from 1001) |
| T-A3 | Dialog: test command shows the LAN cable text | LAN, user logged on | dialog appears in the user session |
| T-B | Dry run (`HostRename – Dry run`) | LAN | exit 0, summary `PHASE=DryRun`, a line `WHATIF: '<old>' would be renamed to '<new>'`; nothing changed on the device |
| T-C1 | Real run, first | LAN | exit 3010, `PHASE=RebootRequired`, reboot dialog |
| T-C2 | Real run again before the reboot (if the dialog is postponed) | LAN | exit 3010 again, no second rename (`PENDING_REBOOT` in the output) |
| T-C3 | After the reboot, next run | LAN | exit 0, `PHASE=Done STEP=Cleanup`; computer name is the new name |
| T-C4 | One more run | LAN | exit 0 immediately, `PHASE=Done STEP=StateCheck`, no script output |
| T-D | Real run on WLAN only (cable unplugged) | WLAN user | exit 20, `PHASE=Gate`, LAN cable dialog, nothing renamed; with cable plugged in the next run renames (3010) |
| T-E | (optional) Real run over DirectAccess, off site | DA | as T-C; note the time between rename and reboot and whether the DA tunnel stays up |
| T-F | WLAN user with `-CertificateTemplate`: after the reboot on cable | WLAN user | `HOSTRENAME STEP=Certificate`, certificate line `RESULT=RENEWED`, then cleanup, exit 0 `PHASE=Done`; afterwards WLAN works without cable |

## 6. How to tell a run worked

- **Summary line** (last line of the job output): `PHASE` and `EXIT` as expected in section 5.
- **Registry on the device** (as administrator):

  ```powershell
  Get-ItemProperty HKLM:\SOFTWARE\HostRenameState    # LastExitCode, LastEvent, TargetName, OriginalName
  Test-Path HKLM:\SOFTWARE\HostRename                # True = done (marker); nothing else means "done"
  ```

- **Local log** (only readable as administrator or SYSTEM): `C:\ProgramData\HostRename\rename-local.csv`.
- **AD**: the computer object has the new name, no object with the old name remains (`Get-ADComputer`).

Details per phase and level: [acmp-rollout.md](acmp-rollout.md), section 4.

## 7. What to send back

Please fill in and send this table, plus the material listed below it. **Remove environment data** (domain, server, OU and device names, user names, IP addresses) or replace it with placeholders.

| ID | Date | Device type | Exit code | Summary line (`HOSTRENAME PHASE=...`) | OK / deviation | Note |
| --- | --- | --- | --- | --- | --- | --- |
| T-A1 | | | | – | | |
| T-A2 | | | | – | | how 3010 is treated |
| T-A3 | | | | – | | |
| T-B | | | | | | |
| T-C1 | | | | | | |
| T-C2 | | | | | | |
| T-C3 | | | | | | |
| T-C4 | | | | | | |
| T-D | | | | | | |
| T-E | | | | | | |
| T-F | | | | | | |

Also send:

- the full job output of every failed or surprising run, and the last 20 lines of the local log of that device;
- the real ACMP names of the commands you used (file transfer, run program/PowerShell, condition on exit code, message, reboot) and the variable that holds the exit code;
- answers: is the agent 32- or 64-bit? Does 3010 arrive unchanged? Do dialogs reach the user? Is `%PROJECTDIR%` cleaned up after the run?
- **the finished Client Command as an export file** (verify in ACMP: version history or context menu of the Client Command → Export), so it can be added to the repository and imported elsewhere.

## 8. How to undo on a test device

Release a device with a permanent error (exit 2, 4 or 5) after fixing the cause (for example the delegation), as administrator on the device:

```powershell
Remove-ItemProperty -Path HKLM:\SOFTWARE\HostRenameState -Name LastExitCode
```

Rename a test device back: first remove the device from the Client Command assignment (otherwise the next run renames it again), then, as administrator on the device, on LAN cable (the old name is in `HostRenameState\OriginalName`):

```powershell
Rename-Computer -NewName '<OldName>' -Restart
# after the reboot: remove the HostRename keys and the local logs
Remove-Item HKLM:\SOFTWARE\HostRename, HKLM:\SOFTWARE\HostRenameState -Recurse -ErrorAction SilentlyContinue
Remove-Item C:\ProgramData\HostRename -Recurse -ErrorAction SilentlyContinue
```

For a WLAN device, renew the machine certificate for the old name afterwards (run `Update-ComputerCertificate.ps1 -Template '<CertificateTemplate>' -RemoveOld` on cable). After the tests, remove the delegation if it is no longer needed: `.\Prepare-HostRename.ps1 -Action Remove -Component Delegation -OuDN '<OU DN>'`.
