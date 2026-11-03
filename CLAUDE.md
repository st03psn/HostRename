# HostRename – Handover to Claude Code

This file summarizes what is needed to continue the work: goal, decisions with rationale, pitfalls, test status and open points. The operations documentation is in `README.md` (German: `README.de.md`); the parameters are in the scripts' built-in help (`Get-Help .\Prepare-HostRename.ps1 -Full`).

## What this is about

HostRename automatically renames domain-joined Windows clients (AD, German system language in the pilot) by GPO, using a name template (`{Name}`, `{Serial}`, prefix, suffix, future ID for an unusable or duplicate serial number). The client script runs as a scheduled task under SYSTEM, renames locally and the AD computer object (`Rename-Computer`), writes a central CSV log to a share and removes itself after success. There is no password: the permissions come from a delegation to SELF on the client OUs.

Status: **version 1.2.0** (3 November 2026). The target environment is **Windows PowerShell 5.1**; PowerShell 7 works in addition.

## ACMP as an alternative deployment method (1.2.0)

Next to GPO, HostRename can be deployed through the deployment tool ACMP (about 700 clients, mostly notebooks, DirectAccess and EAP-TLS WLAN). **Owner decision: GPO and ACMP are alternative deployment methods; never both active on the same device.** ACMP mode is `Invoke-HostRename.ps1 -Deployment Acmp` (local logs in `C:\ProgramData\HostRename`, `-Reboot` ignored with the warning `REBOOT_IGNORED` on every run, cleanup keeps the script file, central log optional via `-NoCentralLog`). Do not recommend `-CentralLogPath ''`: with `powershell.exe -File` it arrives as the two literal quote characters; the script treats `''`, `""`, blank and non-absolute paths as disabled (non-absolute with a `LOG_CHECK` warning). ACMP mode hardens its default log folder before any write (`Initialize-LocalDir`: refuse a reparse point or an owner other than SYSTEM/Administrators, also for files in it; then owner Administrators, inheritance removed, full control only SYSTEM/Administrators via icacls by SID; on failure `LOCAL_DIR` on stdout only, exit 1) and refuses a 32-bit process on 64-bit Windows (`PLATFORM`, exit 1 without reporting values; use `%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe`). An explicit `-LocalDir` and GPO mode are unchanged. Rename only over LAN cable or DirectAccess (gate default). Plan and decisions: `docs/acmp-deployment-plan.md`; build guide: `docs/acmp-guide.md`; rollout process and run verification (ACMP tests AC-A to AC-D): `docs/acmp-rollout.md`; device tests: `docs/test-plan.md`; schedule and test phases: `docs/roadmap.md` (German versions in `docs/de/`). The network gate and the certificate renewal are standalone, reusable building blocks. Recommended for ACMP: the wrapper `Invoke-AcmpHostRename.ps1` runs the whole Client Command flow (state check incl. permanent, gate, rename, certificate, cleanup) in one script run per ACMP invocation by calling the other scripts unchanged in-process; the Client Command then only reacts to 3010 (reboot dialog) and 20 (LAN cable dialog). Hand-over for a first ACMP tester: `docs/acmp-starter-kit.md` (German: `docs/de/acmp-starterkit.md`).

## Repo

Everything deliberately sits in the root directory: scripts and tests find each other through `$PSScriptRoot`, and `Prepare-HostRename.ps1` writes `HostRename.Checks.psd1` next to them. Do not move into subfolders without updating code and README.

- `Prepare-HostRename.ps1`: setup/removal of share, delegation, GPO, optional cleanup GPO. Configuration through variables in the block "ADJUST HERE" (no configuration file).
- `Invoke-HostRename.ps1`: client script, `-Deployment Gpo|Acmp`. Exit codes: 0 nothing to do/-WhatIf, 3010 renamed (reboot required), 1 error, 2 name too long (skip), 4 no permission, 5 no usable serial number. 3010 lies numerically in ACMP's own code range (from 1001): how ACMP treats it is device test A1. Writes reporting values (`LastRun`, `LastExitCode`, `LastEvent`, `Deployment`, `ScriptVersion`) to `HKLM\SOFTWARE\HostRenameState`.
- `Test-DeploymentNetwork.ps1`: network gate (exit 0 allowed path, 20 corporate WLAN only, 21 no domain connection, 22 path not allowed/unknown, 1 error; one summary line `RESULT=... EXIT=...`). Standalone.
- `Invoke-AcmpHostRename.ps1`: ACMP wrapper (one run = the whole flow of `docs/acmp-guide.md` section 4; calls the three client scripts from `$PSScriptRoot` with `& <script> @params`, reads `$LASTEXITCODE`; exit codes 0, 3010, 20, 21, 22, 1, 2, 4, 5; last stdout line `HOSTRENAME PHASE=... EXIT=... STEP=... MESSAGE="..."`; single `exit` in `Exit-AcmpHostRename`; requires exactly one of `-NoCentralLog`/`-CentralLogPath`; `-WhatIf` = gate + `Invoke-HostRename -WhatIf` only). Does not set `$ErrorActionPreference` and prefixes its variables with `Acmp` because the called scripts run in its scope chain.
- `Update-ComputerCertificate.ps1`: certificate renewal (`-Template` mandatory, `-RemoveOld` optional; exit 0/1; summary line; exits 1 while a rename awaits the reboot). Standalone.
- `HostRename.Dc.Tests.ps1`, `.Client.Tests.ps1`, `.Local.Tests.ps1`: Pester 5.3+. Dc and Client read `HostRename.Checks.psd1`, which setup writes from the variables (in `.gitignore`, never commit). `HostRename.Checks.beispiel.psd1` shows the structure.
- `HostRename.Network.Tests.ps1`, `.Certificate.Tests.ps1`, `.Acmp.Tests.ps1`: Pester 5.3+, mocks only, no AD needed (run on any platform, also in CI).
- `HostRename.Simulation.Tests.ps1`: Pester 5.3+, end-to-end simulation of the ACMP Client Command (S1–S12 doc flow, W1–W9 wrapper): runs the real scripts as a whole (and the state-check and status snippets extracted from `docs/acmp-guide.md` / `docs/acmp-rollout.md`) in a simulated environment (registry in memory, mocked CIM/AD/network/certificate store); never changes the machine. Not a substitute for the device tests.
- `tools/Test-GpoReport.ps1`: diagnostics for the GPMC report (see pitfalls). Standalone, not part of the release package.
- `.gitattributes`: LF in all text files. The `.ps1`/`.psd1` files are **UTF-8 with BOM** (without BOM, Windows PowerShell 5.1 reads them as ANSI). Create new PowerShell files the same way.
- `LICENSE` (MIT), `SECURITY.md`, issue and PR templates and a CI workflow exist; the CI workflow is yet to be adapted.
- `docs/`: `acmp-deployment-plan.md`, `acmp-guide.md`, `acmp-rollout.md`, `acmp-starter-kit.md`, `test-plan.md`, `roadmap.md`, `development-history.md`; German versions in `docs/de/` (`ACMP-Umsetzungsplan.md`, `acmp-anleitung.md`, `acmp-rollout.md`, `acmp-starterkit.md`, `testplan.md`, `roadmap.md`, `entwicklungsverlauf.md`) and `README.de.md`.

## Owner's working rules (binding)

- **Language:** English is primary for scripts (comments, help, messages), README and docs; German versions exist as `README.de.md` and `docs/de/`. Chat answers to the owner remain German.
- **Add nothing without a request.** Ask before optional changes. Examples from the history so far: an admin group was removed again on request, a configuration file for the Prepare variables was offered and not wanted, the text of the reboot message "is fine as it is".
- **Be honest about what is untested.** Do not present as confirmed anything that has not run on Windows/AD. Anything beyond the pilot-confirmed points below was checked in a Linux sandbox with mocks (PowerShell 7, no Pester, no AD); the mocks are not part of the repo.
- **Keep code and README in sync.** The README is pure operations documentation: no development history and no troubleshooting stories, changes only as a short list at the end ("Changes"). Keep the German versions in sync as well.
- Releases only with verified documentation.
- Security: delegation instead of a password, no additional admin group, advise against "Everyone" on NTFS. No environment data (OUs, server names, domains) in the repo.

## Architecture and decisions

- **Delegation:** to SELF (`S-1-5-10`) on computer objects under the client OUs, 8 rights: write `cn`, `name`, `sAMAccountName`, `displayName`, Account Restrictions, Reset password, validated writes DNS host name and SPN. Always compare principals **by SID**, never by name (German: "NT-AUTORITÄT\SELF").
- **Share** `\\<Server>\HostRename$` (`C:\HostRename`): `scripts` read-only, `log` with `(OI)(CI)(WD,AD,WEA,WA,RA,RC,S)` for domain computers. The share is created only locally on the file server, delegation and GPO on an admin PC or DC (`$ShareServer` must be the file server).
- **GPO** `COMP - HostRename` (link is created disabled): GPP **Files** (action **R**eplace) copies the script to `C:\Program Files\HostRename`; GPP **Scheduled Task** `HostRename` (SYSTEM, `S-1-5-18`, S4U) with trigger **boot + 5 min** and **registration without delay**, action **C**reate; item-level targeting: marker does not exist. The XML is generated by hand (no GPMC) and follows GPMC examples.
- **Registry:** `HKLM\SOFTWARE\HostRename` (marker, works through its mere existence: Completed, ComputerName) and `HKLM\SOFTWARE\HostRenameState` (TargetName, Template; OriginalName, Applied, FutureId evidence only; since 1.2.0 also the reporting values LastRun, LastExitCode, LastEvent, Deployment, ScriptVersion, written at the end of every run and never read by the logic). Deliberately separate: if the state were in the marker key, the GPO would stop applying script and task right after the rename, before the cleanup.
- **Cleanup** (`-Cleanup`): first flush the logs and deliver them centrally, then set the marker, delete task and script, then the local logs. If delivery fails, the task stays (`CLEANUP_DEFERRED`). The optional cleanup GPO deletes the registry keys via GPP Registry (action D); protection: only keys whose last part starts with `HostRename`, and only if the main GPO no longer exists (`-Force` overrides this).
- **Reboot** only with `-Reboot` (`$Reboot`): `shutdown.exe /r /t <RebootDelaySeconds> /c <text> /d p:4:1`. With a delay > 0, `/f` is implied, so open programs are closed. The message text is hard-coded.
- **Version number:** `$ScriptVersion` in the client script appears in the log's START entry and must match the version in `.NOTES` of all scripts (checked by `HostRename.Local.Tests.ps1`).

## Pitfalls (learned the hard way, do not try again)

1. **GPMC report:** A `<Delay>` in the `RegistrationTrigger` makes the "Settings" tab of the GPO fail with "Unknown error while creating the HTML report" (proven: candidate test, all variants with a delay fail, the same trigger without a delay is displayed). The GPO works on the clients anyway. Hence the registration trigger **without** delay. Before changing the task XML, check the report in the GPMC or run `tools/Test-GpoReport.ps1` (troubleshooting) or `-Candidates` (trigger constructions). The order of elements in the task XML follows the GPMC (e.g. `Repetition` last in the `CalendarTrigger`).
2. **GPP action Update on the task:** The task did not start after a reboot. Plausible, unproven cause: the GPO rewrites it at boot, after the boot trigger. Hence the default **Create**. Consequence: changes to the task definition (rule, reboot switch, paths) do not reach existing tasks; on devices that are not finished yet, delete the task once (`Unregister-ScheduledTask -TaskName HostRename -Confirm:$false`). The script itself keeps updating the file copy.
3. **GPP Files with action Update** failed when overwriting (event 4117, `0x50`). Hence **Replace**.
4. **Account name in the task:** "NT AUTHORITY\System" does not work on German clients (event 1085). Always `SYSTEM` or the SID.
5. **NTFS on `log`:** The right "read attributes" (`RA`) is required, "write" alone was not enough. A delegation without Reset password and Account Restrictions ends with "access denied".
6. **PowerShell quirks:** `#Requires` must come **after** the comment-based help, otherwise the help is not recognized. In Pester, `$Matches` is unreliable after `Should -Match` (use `[regex]::Match` instead). No PS7-only constructs in the scripts.
7. The GPO's CSE list is entered sorted (Files before Scheduled Tasks); the processing order on the client has not been verified.
8. **Existence of `HostRenameState` is not "done".** Since 1.2.0 the key exists after every run (reporting values), also after errors and "nothing to do". "Done" is decided by the marker key `HKLM\SOFTWARE\HostRename` (set by the cleanup) or, for "renamed", by `TargetName` in `HostRenameState`. This applies to the ACMP flow, custom fields and any new check or documentation.

## Test status

**Confirmed in the pilot** (Windows 11, German system language): delegation and renaming (with Reset password and Account Restrictions), language-independent task account, replacement of the script copy (Replace), self-deletion of task and marker, cleanup of the local files after delivery of the logs. In addition, the owner has confirmed that everything implemented so far works: the task start in the current construction (immediately after creation and 5 min after boot), appending to the central log with exactly the permission set applied by setup, the Dc and Client Pester tests, the GPMC settings report of the current GPO, the item-level-targeting roundtrip test and the cleanup GPO. The Local tests ran through in 5.1 (62 of 63; the one failure was a test bug and has been fixed).

Everything added in 1.2.0 (ACMP mode, ACMP wrapper `Invoke-AcmpHostRename.ps1`, network gate, certificate renewal, optional central log, reporting values) is **tested with mocks only** (Linux, PowerShell 7) and untested on real Windows/ACMP until the device tests in `docs/test-plan.md` have run. The GPO path is unchanged by design, but the 1.2.0 client script still needs a regression test in the pilot. Documentation must keep saying so.

## Open points (touch only on request or after asking)

- In theory the task can start before the GPO has created the script copy; the follow-up run (boot + 5 min) catches that.
- The return value of `shutdown.exe` is not checked; if a reboot is already scheduled, the log still says "reboot scheduled". The owner decided that the reboot stays as it is.
- Repo topics: `LICENSE` (MIT), `SECURITY.md`, issue/PR templates and a CI workflow exist; the CI workflow is yet to be adapted. Feasible are a syntax check and PSScriptAnalyzer; not the Pester tests against AD.
- Left unanswered: whether `$TaskItemAction`, `$ShareAccessMode`, `-OuDN` and the Reset-password rights stay as they are. Do not change until clarified.
- Accepted residual findings: PSScriptAnalyzer reports `PSAvoidUsingWriteHost` (Prepare), `PSUseSingularNouns` and `PSReviewUnusedParameter`, among others, for the production scripts. Strict mode is not enabled (identical in the mocks with all scenarios, but never switched on for real).
- The online documentation (a separate document that was so far reconciled by hand with the README) is not reachable for Claude Code; from now on the repo is authoritative.

## Checks and release

Check before every commit:

```powershell
# Syntax of all scripts
Get-ChildItem -Recurse -Include *.ps1 | ForEach-Object {
    $e = $null; [void][System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$e)
    if ($e) { "$($_.Name): $($e.Message)" }
}
Invoke-Pester -Path .\HostRename.Local.Tests.ps1, .\HostRename.Network.Tests.ps1, .\HostRename.Certificate.Tests.ps1, .\HostRename.Acmp.Tests.ps1, .\HostRename.Simulation.Tests.ps1 -Output Detailed   # Pester 5.3+ (Install-Module Pester -MinimumVersion 5.3)
Invoke-ScriptAnalyzer -Path . -Recurse
```

The Dc and Client tests need `HostRename.Checks.psd1`, so run `.\Prepare-HostRename.ps1 -Action Setup` first (in a test environment, with `-WhatIf` first).

Release (example version `x.y.z`):
1. Adjust the version in `.NOTES` of all scripts and test files (including `Test-DeploymentNetwork.ps1`, `Update-ComputerCertificate.ps1` and the Network/Certificate/Acmp tests), `$ScriptVersion` in `Invoke-HostRename.ps1`, the comment `(Version x.y.z)` in `HostRename.Checks.beispiel.psd1`, the README header line (`Version x.y.z · As of`), the example "HostRename x.y.z: deployment Gpo, template …" in the README, the guide/test-plan header lines and the changes list. Do the same in `README.de.md` and the German docs.
2. Run the Local tests (they check version equality).
3. Commit, tag `vx.y.z`, attach the ZIP as a release asset.

## First steps

1. Read `README.md` (operations documentation) and the section "Security and known limitations".
2. Run the Local tests on Windows and record the result.
3. Read `docs/roadmap.md`, `docs/acmp-deployment-plan.md`, `docs/acmp-guide.md` and `docs/test-plan.md` before working on ACMP.
