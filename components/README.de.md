# HostRename – Bausteine

[English version](README.md) · [Haupt-README](../README.de.md)

Werkzeugneutrale Bausteine. Sie hängen weder an einem Verteilwerkzeug noch an der Umbenennung: Jeder läuft eigenständig als SYSTEM (oder von Hand), ändert nichts, worum er nicht gebeten wird, endet mit einem Exit-Code und gibt als letzte Zeile auf stdout eine Zusammenfassungszeile aus. Ein Deployment-Ordner (zum Beispiel [deployments/acmp](../deployments/acmp/README.de.md)) ruft sie unverändert auf.

| Skript | Zweck | Exit-Codes | Zusammenfassungszeile |
| --- | --- | --- | --- |
| `Test-DeploymentNetwork.ps1` | Netzwerk-Gate: Über welchen Weg erreicht das Gerät die Domäne (LAN-Kabel, DirectAccess, Firmen-WLAN), und ist dieser Weg erlaubt (`-Allow`, Standard `Lan, DirectAccess`; `-CorporateSsid`, `-DomainName`)? Ändert nichts am Gerät | `0` erlaubter Weg und ein DC erreichbar · `20` nur Firmen-WLAN (um LAN-Kabel bitten) · `21` keine Domänenverbindung · `22` Weg nicht erlaubt oder unbekannt · `1` Fehler | `RESULT=<LAN\|DIRECTACCESS\|WLAN\|OTHER\|NONE\|ERROR> EXIT=<n> ...` |
| `Update-ComputerCertificate.ps1` | Zertifikatserneuerung: fordert ein Computerzertifikat der Vorlage `-Template` an, wenn kein gültiges den aktuellen DNS-Namen trägt (nach einer Umbenennung); `-RemoveOld` entfernt danach die veralteten Zertifikate derselben Vorlage | `0` erneuert, nicht nötig oder `-WhatIf` · `1` Fehler, später erneut versuchen (auch solange eine Umbenennung noch auf den Neustart wartet) | `RESULT=<RENEWED\|NOT_NEEDED\|WHATIF\|ERROR> EXIT=<n> ...` |

Alle Parameter, die Erkennungsregeln und Sonderfälle stehen in der eingebauten Hilfe:

```powershell
Get-Help .\components\Test-DeploymentNetwork.ps1 -Full
Get-Help .\components\Update-ComputerCertificate.ps1 -Full
```

## Tests

Pester 5.3+, nur Mocks (kein AD, keine CA, läuft auf jeder Plattform):

```powershell
Invoke-Pester -Path .\components\tests -Output Detailed
```

| Datei | Prüft |
| --- | --- |
| `tests/HostRename.Network.Tests.ps1` | Gate: Erkennung von LAN, DirectAccess, WLAN und Domänenerreichbarkeit (gemockt), Entscheidung, Exit-Codes, Ergebniszeile |
| `tests/HostRename.Certificate.Tests.ps1` | Zertifikatserneuerung: SAN-Auswertung, Vorlagenerkennung, Entscheidungen zu Erneuerung und Entfernen mit gemocktem Speicher und Enrollment |

**Erprobungsstand:** Beide Bausteine sind neu in 1.2.0 und nur mit Mocks getestet. Auf echten Geräten (LAN, DirectAccess, WLAN, AD CS) sind sie noch nicht gelaufen; die Gerätetests stehen in [deployments/acmp/docs/de/testplan.md](../deployments/acmp/docs/de/testplan.md).
