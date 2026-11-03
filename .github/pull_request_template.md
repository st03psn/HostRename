## Summary / Zusammenfassung

<!-- What does this PR change and why? / Was ändert dieser PR und warum? -->

## Related issue / Zugehöriges Issue

Closes #

## Checklist / Checkliste

- [ ] Parse check passes: all `*.ps1` files parse without errors / Parse-Prüfung: alle `*.ps1` ohne Fehler
- [ ] AD-free Pester tests pass (`HostRename.Local.Tests.ps1`, `HostRename.Network.Tests.ps1`, `HostRename.Certificate.Tests.ps1`, `HostRename.Acmp.Tests.ps1`, `HostRename.Simulation.Tests.ps1`) / Pester-Tests ohne AD bestehen
- [ ] `Invoke-ScriptAnalyzer -Path . -Recurse -Severity Error` reports no errors / keine Fehler
- [ ] Tested on Windows PowerShell 5.1 where possible / Auf Windows PowerShell 5.1 getestet, soweit möglich
- [ ] Files are UTF-8 with BOM (`.ps1`, `.psd1`) and LF line endings / Dateien UTF-8 mit BOM und LF-Zeilenenden
- [ ] README.md and README.de.md updated if behaviour changed (operations part; short entry in the list of changes at the end) / README.md und README.de.md aktualisiert, falls sich das Verhalten geändert hat
- [ ] Release only: version updated in all places (see `CLAUDE.md`, "Checks and release") / nur bei Release: Version an allen Stellen angepasst
- [ ] No environment data in code, tests, docs or this PR (OUs, server names, domains, IP addresses, user names) / keine Umgebungsdaten

## Test status / Teststatus

<!-- Be honest: what was tested, where, and what was NOT tested on real Windows / AD (e.g. "not run on a domain-joined client", "Dc/Client tests not run"). -->
<!-- Ehrlich angeben: was wo getestet wurde und was NICHT auf echtem Windows/AD getestet wurde. -->

- Tested on / getestet auf:
- Not tested / nicht getestet:
