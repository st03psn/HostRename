# HostRename – deployment tools

[Deutsche Version](README.de.md) · [Main README](../README.md)

The GPO path is part of the core (repository root: `Prepare-HostRename.ps1` builds share, delegation and GPO). Every other deployment tool gets its own folder here. GPO and any other deployment tool are alternatives: never more than one on the same device.

| Folder | Tool | Status |
| --- | --- | --- |
| [acmp/](acmp/README.md) | ACMP (Aagon) Client Command | 1.2.0, tested with mocks and in a simulation only; device tests pending |

## What a deployment folder contains

```
deployments/<tool>/
  <wrapper>.ps1     optional: runs the tool's whole flow in one script run (e.g. Invoke-AcmpHostRename.ps1)
  README.md         entry page (+ README.de.md): what, package contents, links, honest test status
  docs/             guide, rollout, test plan for this tool (+ docs/de/)
  tests/            Pester tests for the wrapper and the tool-specific flow (AD-free where possible)
```

Rules:

- **Core scripts stay unchanged.** A wrapper calls `Invoke-HostRename.ps1` (root) and the building blocks in [components/](../components/README.md) as they are, in-process or as a child process, and reads their exit codes. Tool-specific behaviour of the client script belongs behind a `-Deployment <Tool>` value only if the tool really needs it (as for ACMP: local log folder, no reboot by the script, cleanup keeps the script file).
- **Flat package.** The release package of a tool is flat: all scripts it needs lie in one folder, the way the tool transfers them to the client. A wrapper therefore looks for its sibling scripts in its own folder first (`$PSScriptRoot`) and falls back to the repository layout (root and `components/`, two levels up) only when a script is missing there.
- **Tests find the scripts from their own folder** (`$PSScriptRoot`, then up to the repository root); they must run on any platform without AD if they are to run in CI.
- **Documentation** in English with a German counterpart in `docs/de/`; no environment data (OUs, server names, domains).

## Adding a tool (for example Intune)

1. Create `deployments/<tool>/` with `README.md`/`README.de.md`, `docs/` (+ `docs/de/`) and `tests/`; add a wrapper only if the tool cannot express the flow itself.
2. Add the tests to the `Run.Path` list in `.github/workflows/ci.yml`.
3. Add a release file list `.github/release-notes/v<version>.<tool>.files` (flat: `source => target`), so the release gets its own `HostRename-<version>-<tool>.zip`.
4. Add the folder to the table above, to "Repository layout" in the main READMEs and to `CLAUDE.md`.
