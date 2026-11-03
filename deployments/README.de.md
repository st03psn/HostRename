# HostRename – Verteilwerkzeuge

[English version](README.md) · [Haupt-README](../README.de.md)

Der GPO-Weg gehört zum Kern (Wurzelverzeichnis: `Prepare-HostRename.ps1` baut Share, Delegation und GPO). Jedes andere Verteilwerkzeug bekommt hier einen eigenen Ordner. GPO und jedes andere Verteilwerkzeug sind Alternativen: nie mehr als eines auf demselben Gerät.

| Ordner | Werkzeug | Stand |
| --- | --- | --- |
| [acmp/](acmp/README.de.md) | ACMP (Aagon) Client-Command | 1.2.0, nur mit Mocks und in einer Simulation getestet; Gerätetests ausstehend |

## Was ein Deployment-Ordner enthält

```
deployments/<werkzeug>/
  <wrapper>.ps1     optional: führt den ganzen Ablauf des Werkzeugs in einem Skriptlauf aus (z. B. Invoke-AcmpHostRename.ps1)
  README.md         Einstiegsseite (+ README.de.md): was, Paketinhalt, Links, ehrlicher Erprobungsstand
  docs/             Anleitung, Rollout, Testplan für dieses Werkzeug (+ docs/de/)
  tests/            Pester-Tests für den Wrapper und den werkzeugspezifischen Ablauf (wo möglich ohne AD)
```

Regeln:

- **Kernskripte bleiben unverändert.** Ein Wrapper ruft `Invoke-HostRename.ps1` (Wurzel) und die Bausteine in [components/](../components/README.de.md) so auf, wie sie sind, im selben Prozess oder als Kindprozess, und liest ihre Exit-Codes. Werkzeugspezifisches Verhalten des Client-Skripts gehört nur dann hinter einen Wert `-Deployment <Werkzeug>`, wenn das Werkzeug es wirklich braucht (wie bei ACMP: lokaler Logordner, kein Neustart durch das Skript, Cleanup behält die Skriptdatei).
- **Flaches Paket.** Das Release-Paket eines Werkzeugs ist flach: Alle nötigen Skripte liegen in einem Ordner, so wie das Werkzeug sie auf den Client überträgt. Ein Wrapper sucht seine Geschwisterskripte deshalb zuerst im eigenen Ordner (`$PSScriptRoot`) und greift nur dann auf den Repository-Aufbau zurück (Wurzel und `components/`, zwei Ebenen höher), wenn ein Skript dort fehlt.
- **Tests finden die Skripte von ihrem eigenen Ordner aus** (`$PSScriptRoot`, dann hoch bis zur Wurzel des Repositorys); damit sie in der CI laufen, müssen sie ohne AD auf jeder Plattform laufen.
- **Dokumentation** auf Englisch mit deutscher Fassung in `docs/de/`; keine Umgebungsdaten (OUs, Servernamen, Domänen).

## Ein Werkzeug hinzufügen (zum Beispiel Intune)

1. `deployments/<werkzeug>/` anlegen mit `README.md`/`README.de.md`, `docs/` (+ `docs/de/`) und `tests/`; einen Wrapper nur, wenn das Werkzeug den Ablauf nicht selbst abbilden kann.
2. Die Tests in die Liste `Run.Path` in `.github/workflows/ci.yml` aufnehmen.
3. Eine Release-Dateiliste `.github/release-notes/v<version>.<werkzeug>.files` anlegen (flach: `quelle => ziel`), damit das Release ein eigenes `HostRename-<version>-<werkzeug>.zip` bekommt.
4. Den Ordner in die Tabelle oben, in „Aufbau des Repositorys“ der Haupt-READMEs und in `CLAUDE.md` eintragen.
