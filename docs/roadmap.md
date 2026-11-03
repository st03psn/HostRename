# Roadmap: version 1.2.0 – ACMP as an alternative deployment method

[Deutsche Version](de/roadmap.md) · Background: [development history](development-history.md), [ACMP deployment plan](../deployments/acmp/docs/acmp-deployment-plan.md)

## Goal

HostRename can be deployed either through **GPO** (unchanged, as in 1.1.9) or through **ACMP**. ACMP renames only over LAN cable or DirectAccess. It renews the WLAN machine certificate after the rename and reports the status back. The new building blocks (network gate, certificate renewal) are reusable for other deployments.

## How the work is split between models

Each task gets the model it needs. Mechanical work goes to the cheapest model that is reliable for it. Design and security-relevant code goes to the strongest model. Every result is checked by tests and a final independent review.

| Model | Used for | Why |
| --- | --- | --- |
| **Opus** | Planning, coordination, new scripts with Windows/PKI/network subtleties (network gate, certificate renewal), final review, release | Needs judgement: edge cases, PS 5.1 compatibility, localisation, security |
| **Sonnet** | Translations of scripts and documentation, well-specified code changes (ACMP mode), test cases, operations documentation | Large volume with clear rules; good quality at lower cost |
| **Haiku** | Purely mechanical tasks (version bump in all places, adapting templates and CI configuration) | Small, rule-based edits; results are verified by the Local tests |

## Work packages

| # | Work package | Model | Depends on | Automated check |
| --- | --- | --- | --- | --- |
| 1 | Import the 1.1.9 package, resolve conflicts with the scaffolding | Opus | – | Local tests 43/63 on Linux (the 20 failures are Windows-only) |
| 2 | Document the development history, write this roadmap | Opus | 1 | – |
| 3 | Translate the client script and the Local/Client tests to English | Sonnet | 1 | Local tests unchanged, parse check |
| 4 | Translate the setup script, Dc tests, `tools/` and the sample psd1 to English | Sonnet | 1 | Parse check, help readable |
| 5 | README (EN + DE), CLAUDE.md (EN), ACMP plan (EN + DE) | Sonnet | 1 | Review |
| 6 | New: network gate `Test-DeploymentNetwork.ps1` + tests | Opus | 1 | Pester (mocks) |
| 7 | New: certificate renewal `Update-ComputerCertificate.ps1` + tests | Opus | 1 | Pester (real test certificates, mocks) |
| 8 | ACMP mode in the client script (`-Deployment Acmp`) + tests | Sonnet | 3 | Pester (mocks) |
| 9 | ACMP guide (client command, exit-code contract, reporting) and test plan for device tests | Sonnet | 6, 7, 8 | Review |
| 10 | Version 1.2.0 everywhere, CI on Windows runner, adapt templates/CONTRIBUTING | Haiku | 3–8 | Local tests check version equality |
| 11 | Independent review of the whole change, fixes | Opus | 1–10 | All tests |
| 12 | Commit, PR, merge to `main` | Opus | 11 | CI |

## Test phases

Testing is part of the plan. Device tests cannot be planned in full upfront; the test plan ([test-plan.md](../deployments/acmp/docs/test-plan.md)) lists the cases, and its results feed back into code and documentation.

| Phase | What | Where | Who |
| --- | --- | --- | --- |
| T1 | Syntax, Local tests, new Pester tests (mocks) | Linux sandbox (PowerShell 7) | Claude, automatic |
| T2 | Same tests plus Windows-only Local tests, PSScriptAnalyzer | GitHub Actions `windows-latest` (Windows PowerShell 5.1 and 7) | CI, automatic on every push |
| T3 | Device tests: gate on LAN/DA/WLAN/offline; rename over LAN and DA; WLAN behaviour before/after reboot and after certificate renewal; 802.1X on LAN ports; ACMP behaviour (exit codes, dialogs, duplicate client) | Test devices | Owner (following [test-plan.md](../deployments/acmp/docs/test-plan.md)) |
| T4 | Dry run `-WhatIf` over ACMP on all ~700 devices, then clean up the findings | Production | Owner |
| T5 | Rollout in waves: about 20 → about 100 → rest | Production | Owner |

Results from T3 that require changes (e.g. other exit codes, different detection) go back into the work packages 6–9 as fixes.

## Not automatable here

- Anything that needs AD, AD CS, DirectAccess, real WLAN/802.1X or ACMP. That code is tested with mocks only, and the documentation says so.
- Building the ACMP client command in the ACMP console. The guide describes it step by step.
- The reboot deadline in ACMP. It is decided during T3.

## Status (3 November 2026)

| # | Status | Notes |
| --- | --- | --- |
| 1–2 | done | Baseline imported, history and roadmap written |
| 3–5 | done | Scripts and docs in English; code tokens unchanged by the translation; German versions in `README.de.md` and `docs/de/` |
| 6 | done | Network gate, mock-tested |
| 7 | done | Certificate renewal, mock-tested with real test certificates |
| 8 | done | ACMP mode, optional central log (`-NoCentralLog`), reporting values |
| 9 | done | ACMP guide and device test plan |
| 10 | done | Version 1.2.0, CI, templates |
| 11 | done | Independent review. Fixed: unsafe disabling of the central log, user-writable ACMP log folder (now hardened), 32-bit process detection, IPv6 address handling, documentation errors |
| 12 | done | PR to `main` |

Test status of the automated phases:

- **T1 (Linux, PowerShell 7, Pester 5 and 6):** Local 49 passed, 20 failed, 5 skipped. The failures are Windows-only tests that are covered by T2. Network 89 passed, 1 skipped. Certificate 69 passed. Acmp 83 passed. Simulation 39 passed.
- **T2 (GitHub Actions, Windows PowerShell 5.1 and 7):** green, including the Windows-only Local tests. The simulation is in the CI run list; its first CI run is still pending.
- **Simulation (`HostRename.Simulation.Tests.ps1`, part of T1 and T2):** runs the real scripts and the documented state-check and status snippets chained like the ACMP Client Command across all phases (LAN, DirectAccess, WLAN with certificate renewal, waiting at the gate, no delegation, collision, unusable serial number, name already matching, 32-bit process, prepared log folder, GPO regression). The environment is simulated (registry in memory; CIM, AD, network, certificate store and CA mocked); the central log is not simulated. It shows that the scripts and the documented flow fit together; it is no substitute for the device tests in T3.

**Next: T3 device tests by the owner** following [test-plan.md](../deployments/acmp/docs/test-plan.md). Nothing in 1.2.0 has run on a real domain client, DirectAccess, WLAN/AD CS or ACMP yet.
