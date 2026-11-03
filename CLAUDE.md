# HostRename – Handover to Claude Code

This file summarizes what is needed to continue the work: goal, decisions with rationale, pitfalls, test status and open points. The operations documentation is in `README.md` (German: `README.de.md`); the parameters are in the scripts' built-in help (`Get-Help .\Prepare-HostRename.ps1 -Full`).

## Quick facts

- **Repository:** https://github.com/st03psn/HostRename (MIT). Default branch `main`; work happens on feature branches with a PR, merged after green CI.
- **Website:** https://st03psn.github.io/HostRename/ (EN) and `/de/` (DE), built from `site/` by the workflow `pages.yml` (GitHub Pages source "GitHub Actions" is enabled).
- **Layout:** root = core + GPO (`Invoke-HostRename.ps1`, `Prepare-HostRename.ps1`), `tests/` core tests, `components/` tool-neutral building blocks (network gate, certificate renewal), `deployments/acmp/` everything ACMP (wrapper, docs, tests), `docs/` roadmap and history, `tools/` GPMC diagnostics, `site/` website, `.github/` CI, release, Pages, release notes.
- **Versions:** 1.1.9 = GPO solution, pilot-confirmed (commit `6605dc8`, scripts and docs in German). 1.2.0 = current `main`: English, ACMP as alternative deployment method, components, simulation; new parts tested in CI and simulation only (pre-release).
- **Releases:** workflow `release.yml` (manual) builds one ZIP per package (`gpo`, flat `acmp`) from `.github/release-notes/v<ver>.<pkg>.files` with notes `v<ver>.md`. Status at the time of writing: v1.2.0 to be published as pre-release; v1.1.9 needs the tag on `6605dc8` first (see "Checks and release").
- **CI:** `ci.yml` on every PR and push to `main`: parse, BOM/LF, PSScriptAnalyzer (errors), all AD-free Pester tests (Local, Network, Certificate, Acmp, Simulation) under Windows PowerShell 5.1 and PowerShell 7 on `windows-latest` with Pester 6. Pester 6 has no fallback for unmatched `-ParameterFilter` mocks; .NET Framework differs in places (e.g. X509 `GetNameInfo`).
- **What this session cannot do:** push tags or anything but its own branch, create/publish releases via its GitHub tools. The workflow token cannot create releases/tags on older commits (HTTP 403). Such steps are done by the owner (see release steps).

## What this is about

HostRename automatically renames domain-joined Windows clients (AD, German system language in the pilot) by GPO, using a name template (`{Name}`, `{Serial}`, prefix, suffix, future ID for an unusable or duplicate serial number). The client script runs as a scheduled task under SYSTEM, renames locally and the AD computer object (`Rename-Computer`), writes a central CSV log to a share and removes itself after success. There is no password: the permissions come from a delegation to SELF on the client OUs.

Status: **version 1.2.0** (3 November 2026). The target environment is **Windows PowerShell 5.1**; PowerShell 7 works in addition.

## ACMP as an alternative deployment method (1.2.0)

Next to GPO, HostRename can be deployed through the deployment tool ACMP (about 700 clients, mostly notebooks, DirectAccess and EAP-TLS WLAN). **Owner decision: GPO and ACMP are alternative deployment methods; never both active on the same device.** ACMP mode is `Invoke-HostRename.ps1 -Deployment Acmp` (local logs in `C:\ProgramData\HostRename`, `-Reboot` ignored with the warning `REBOOT_IGNORED` on every run, cleanup keeps the script file, central log optional via `-NoCentralLog`). Do not recommend `-CentralLogPath ''`: with `powershell.exe -File` it arrives as the two literal quote characters; the script treats `''`, `""`, blank and non-absolute paths as disabled (non-absolute with a `LOG_CHECK` warning). ACMP mode hardens its default log folder before any write (`Initialize-LocalDir`: refuse a reparse point or an owner other than SYSTEM/Administrators, also for files in it; then owner Administrators, inheritance removed, full control only SYSTEM/Administrators via icacls by SID; on failure `LOCAL_DIR` on stdout only, exit 1) and refuses a 32-bit process on 64-bit Windows (`PLATFORM`, exit 1 without reporting values; use `%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe`). An explicit `-LocalDir` and GPO mode are unchanged. Rename only over LAN cable or DirectAccess (gate default). Plan and decisions: `deployments/acmp/docs/acmp-deployment-plan.md`; build guide: `deployments/acmp/docs/acmp-guide.md`; rollout process and run verification (ACMP tests AC-A to AC-D): `deployments/acmp/docs/acmp-rollout.md`; device tests: `deployments/acmp/docs/test-plan.md`; schedule and test phases: `docs/roadmap.md` (German versions in `deployments/acmp/docs/de/` and `docs/de/`). The network gate and the certificate renewal are standalone, reusable building blocks (`components/`). Recommended for ACMP: the wrapper `deployments/acmp/Invoke-AcmpHostRename.ps1` runs the whole Client Command flow (state check incl. permanent, gate, rename, certificate, cleanup) in one script run per ACMP invocation by calling the other scripts unchanged in-process; the Client Command then only reacts to 3010 (reboot dialog) and 20 (LAN cable dialog). Hand-over for a first ACMP tester: `deployments/acmp/docs/acmp-starter-kit.md` (German: `deployments/acmp/docs/de/acmp-starterkit.md`).

## Repo

Layout (owner decision, November 2026): core and GPO in the root, tool-neutral building blocks in `components/`, one folder per deployment tool besides GPO under `deployments/<tool>/` (today `acmp`; e.g. Intune later), cross-cutting documents in `docs/`. Move files only with `git mv`. Overview pages: `components/README.md`, `deployments/README.md`, `deployments/acmp/README.md` (each with `README.de.md`); the READMEs have a "Repository layout" section.

- **Root (core + GPO, pilot-confirmed; behaviour must not change):**
  - `Prepare-HostRename.ps1`: setup/removal of share, delegation, GPO, optional cleanup GPO. Configuration through variables in the block "ADJUST HERE" (no configuration file). Writes `HostRename.Checks.psd1` next to itself (`$PSScriptRoot`, i.e. the root) and finds `Invoke-HostRename.ps1` next to itself.
  - `Invoke-HostRename.ps1`: client script, `-Deployment Gpo|Acmp`. Exit codes: 0 nothing to do/-WhatIf, 3010 renamed (reboot required), 1 error, 2 name too long (skip), 4 no permission, 5 no usable serial number. 3010 lies numerically in ACMP's own code range (from 1001): how ACMP treats it is device test A1. Writes reporting values (`LastRun`, `LastExitCode`, `LastEvent`, `Deployment`, `ScriptVersion`) to `HKLM\SOFTWARE\HostRenameState`.
  - `HostRename.Checks.beispiel.psd1`: structure of `HostRename.Checks.psd1` (in `.gitignore`, never commit).
- **`tests/`:** `HostRename.Dc.Tests.ps1`, `.Client.Tests.ps1`, `.Local.Tests.ps1` (Pester 5.3+). Defaults: scripts and `HostRename.Checks.psd1` in the parent folder (repo/package root). Dc and Client read `HostRename.Checks.psd1`, which setup writes from the variables. Local covers syntax and `.NOTES` version equality of **all** `.ps1` under the root, recursively (hidden folders such as `.git` skipped).
- **`tools/Test-GpoReport.ps1`:** diagnostics for the GPMC report (see pitfalls). Standalone, not part of any release package.
- **`components/`** (tool-neutral, standalone, called unchanged by deployment wrappers):
  - `Test-DeploymentNetwork.ps1`: network gate (exit 0 allowed path, 20 corporate WLAN only, 21 no domain connection, 22 path not allowed/unknown, 1 error; one summary line `RESULT=... EXIT=...`).
  - `Update-ComputerCertificate.ps1`: certificate renewal (`-Template` mandatory, `-RemoveOld` optional; exit 0/1; summary line; exits 1 while a rename awaits the reboot).
  - `tests/HostRename.Network.Tests.ps1`, `tests/HostRename.Certificate.Tests.ps1`: Pester 5.3+, mocks only, no AD (any platform, CI). Default script folder: parent of `tests/`.
- **`deployments/acmp/`** (everything ACMP-specific):
  - `Invoke-AcmpHostRename.ps1`: ACMP wrapper (one run = the whole flow of `deployments/acmp/docs/acmp-guide.md` section 4; calls the three client scripts with `& <script> @params`, reads `$LASTEXITCODE`; exit codes 0, 3010, 20, 21, 22, 1, 2, 4, 5; last stdout line `HOSTRENAME PHASE=... EXIT=... STEP=... MESSAGE="..."`; single `exit` in `Exit-AcmpHostRename`; requires exactly one of `-NoCentralLog`/`-CentralLogPath`; `-WhatIf` = gate + `Invoke-HostRename -WhatIf` only). Does not set `$ErrorActionPreference` and prefixes its variables with `Acmp` because the called scripts run in its scope chain. Script lookup: its own folder (`$PSScriptRoot`, the flat ACMP package/cache) always wins; only if a script is missing there, the repository layout two levels up (`Invoke-HostRename.ps1` in the root, gate/certificate in `components/`).
  - `docs/`: `acmp-guide.md`, `acmp-rollout.md`, `acmp-starter-kit.md`, `test-plan.md` (device tests: gate, certificate, ACMP and the GPO regression block), `acmp-deployment-plan.md`; German in `docs/de/` (`acmp-anleitung.md`, `acmp-rollout.md`, `acmp-starterkit.md`, `testplan.md`, `ACMP-Umsetzungsplan.md`).
  - `tests/HostRename.Acmp.Tests.ps1` (mocks) and `tests/HostRename.Simulation.Tests.ps1`: end-to-end simulation of the ACMP Client Command (S1–S12 doc flow, W1–W9 wrapper): copies the real scripts **flat** into a simulated ACMP cache and runs them as a whole (plus the state-check and status snippets extracted from `deployments/acmp/docs/acmp-guide.md` / `deployments/acmp/docs/acmp-rollout.md`, EN/DE equality) in a simulated environment (registry in memory, mocked CIM/AD/network/certificate store); never changes the machine. Not a substitute for the device tests. Default `-ScriptFolder` of both: the repo root (three levels up).
- **Flat-package rule for deployments:** the release package of a deployment tool is flat (all scripts in one folder, as the tool transfers them); its wrapper must work from that flat folder first and may fall back to the repo layout only. A new tool gets `deployments/<tool>/` with README (EN/DE), `docs/` (+ `docs/de/`), `tests/`, its tests in the CI `Run.Path` list, and a release list `v<version>.<tool>.files` (see `deployments/README.md`).
- **`docs/`:** cross-cutting only: `roadmap.md`, `development-history.md`; German `docs/de/roadmap.md`, `docs/de/entwicklungsverlauf.md`. History texts are not rewritten (they mention old paths as they were).
- `.gitattributes`: LF in all text files. The `.ps1`/`.psd1` files are **UTF-8 with BOM** (without BOM, Windows PowerShell 5.1 reads them as ANSI). Create new PowerShell files the same way.
- `LICENSE` (MIT), `SECURITY.md`, `CONTRIBUTING.md`, issue and PR templates; `.github/workflows/`: `ci.yml` (parse, BOM/LF, PSScriptAnalyzer errors, AD-free Pester tests from their folders on 5.1 and 7), `release.yml`, `pages.yml`; `.github/release-notes/`; `site/` (marketing site).

## Owner's working rules (binding)

- **Language:** English is primary for scripts (comments, help, messages), README and docs; German versions exist as `README.de.md` and `docs/de/`. Chat answers to the owner remain German.
- **Add nothing without a request.** Ask before optional changes. Examples from the history so far: an admin group was removed again on request, a configuration file for the Prepare variables was offered and not wanted, the text of the reboot message "is fine as it is".
- **Be honest about what is untested.** Do not present as confirmed anything that has not run on Windows/AD. Anything beyond the pilot-confirmed points below is verified only by Pester tests with mocks, the end-to-end simulation and CI (Windows PowerShell 5.1 and 7 on GitHub runners, no AD, no ACMP).
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
- **Version number:** `$ScriptVersion` in the client script appears in the log's START entry and must match the version in `.NOTES` of all scripts (checked by `tests/HostRename.Local.Tests.ps1`).

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

Everything added in 1.2.0 (ACMP mode, ACMP wrapper `Invoke-AcmpHostRename.ps1`, network gate, certificate renewal, optional central log, reporting values) is **tested only with mocks, the end-to-end simulation and CI** (Windows PowerShell 5.1 and 7 on GitHub runners) and untested on real devices/ACMP until the device tests in `deployments/acmp/docs/test-plan.md` have run. The GPO path is unchanged by design, but the 1.2.0 client script still needs a regression test in the pilot. Documentation must keep saying so.

## Open points (touch only on request or after asking)

- In theory the task can start before the GPO has created the script copy; the follow-up run (boot + 5 min) catches that.
- The return value of `shutdown.exe` is not checked; if a reboot is already scheduled, the log still says "reboot scheduled". The owner decided that the reboot stays as it is.
- The Dc and Client tests (AD/GPO) cannot run in CI; they run only in a test domain.
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
Invoke-Pester -Path .\tests\HostRename.Local.Tests.ps1, .\components\tests, .\deployments\acmp\tests -Output Detailed   # Pester 5.3+ (Install-Module Pester -MinimumVersion 5.3)
Invoke-ScriptAnalyzer -Path . -Recurse
```

The Dc and Client tests (`tests/`) need `HostRename.Checks.psd1` in the root, so run `.\Prepare-HostRename.ps1 -Action Setup` first (in a test environment, with `-WhatIf` first).

Release (example version `x.y.z`):
1. Adjust the version in `.NOTES` of all scripts and test files in all folders (root, `tests/`, `tools/`, `components/` incl. tests, `deployments/acmp/` incl. tests), `$ScriptVersion` in `Invoke-HostRename.ps1`, the comment `(Version x.y.z)` in `HostRename.Checks.beispiel.psd1`, the README header line (`Version x.y.z · As of`), the example "HostRename x.y.z: deployment Gpo, template …" in the README, the guide/test-plan header lines in `deployments/acmp/docs/` and the changes list. Do the same in `README.de.md` and the German docs.
2. Run the Local tests (they check version equality of all `.ps1` in the repo, recursively).
3. Add `.github/release-notes/vx.y.z.md` (release notes EN + DE, with a package section per ZIP) and one file list per package: `.github/release-notes/vx.y.z.<package>.files` (today `gpo` and `acmp`). Each line is `source` (path or glob, copied to the same relative path) or `source => target` (path without glob; target relative inside the package; a folder is copied with its contents); `#` starts a comment; a missing source fails the build. `gpo`: root scripts, sample psd1, READMEs, LICENSE, SECURITY.md, `tests/` (same layout as the repo). `acmp`: **flat** (`deployments/acmp/Invoke-AcmpHostRename.ps1 => Invoke-AcmpHostRename.ps1`, `Invoke-HostRename.ps1`, `components/<script> => <script>`, `Prepare-HostRename.ps1`, `deployments/acmp/README*.md => README*.md`, `deployments/acmp/docs => docs`, LICENSE, SECURITY.md). Never tools/, CLAUDE.md, CONTRIBUTING.md, .github/, site/. The legacy single list `vx.y.z.files` (one package `HostRename-x.y.z.zip`) still works and is used by v1.1.9; both formats for one version fail. Commit and merge to `main`, then run the workflow **Release** (Actions > Release > Run workflow: version `x.y.z`, optional `source_ref` to package an older commit, pre-release yes/no). It checks `$ScriptVersion` in the source, builds `HostRename-x.y.z-<package>.zip` per list (each ZIP contains a folder of the same name), and creates the GitHub release with all ZIPs, by default as a **draft** (input `draft`): the workflow token gets HTTP 403 when it has to create a tag on an older commit, so the owner publishes the draft on GitHub (Releases > Edit > Publish release), which creates the tag `vx.y.z` on the source commit. For an older commit even the draft fails with 403 (v1.1.9 on `6605dc8`). Then the owner creates the tag first, either locally (`git tag vx.y.z <sha>`, `git push origin vx.y.z`) or in the browser: open `https://github.com/st03psn/HostRename/tree/<sha>`, create a branch there via the branch selector (e.g. `release-x.y.z`), then Releases > Draft a new release > tag `vx.y.z` (new) with that branch as target > Publish. Afterwards run the workflow with `source_ref=<sha>` and `draft=false`: an existing tag is accepted if it points to the source commit, and an existing published release is completed (ZIPs, title, notes, latest/pre-release). The helper branch can be deleted afterwards. A published full release becomes "Latest". Planned: v1.1.9 (GPO, pilot-confirmed, source commit 6605dc8, German) as full release and v1.2.0 as pre-release.
4. Marketing site: `site/` (EN `index.html`, DE `de/index.html`), published by the workflow **Pages** on every push to `main` that touches `site/` (one-time setting: Settings > Pages > Source "GitHub Actions"). Keep its facts and version in sync with the README.

## First steps

1. Read `README.md` (operations documentation) and the section "Security and known limitations".
2. Run the Local tests on Windows and record the result.
3. Read `docs/roadmap.md`, `deployments/acmp/README.md`, `deployments/acmp/docs/acmp-deployment-plan.md`, `deployments/acmp/docs/acmp-guide.md` and `deployments/acmp/docs/test-plan.md` before working on ACMP.
