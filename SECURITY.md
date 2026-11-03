# Security Policy / Sicherheitsrichtlinie

## English

Please **do not** report security vulnerabilities through public GitHub issues.

Use GitHub's private reporting instead: **Security → Report a vulnerability** in this repository. Include a description, steps to reproduce and the affected version. You will receive a response as soon as possible.

**Do not include environment data** in a report (or in any issue or pull request): no domain names, OUs, server or computer names, IP addresses, user names or unredacted logs. Replace them with placeholders such as `<domain>`, `<OU>` or `<server>`.

Only the latest release receives security fixes.

### Security design in brief

- **No passwords are stored.** Renaming works through delegation to `NT AUTHORITY\SELF`: each computer account may change only its own AD object, limited to the client OU. The delegation is removable with `Prepare-HostRename.ps1 -Action Remove -Component Delegation`.
- **No extra administrator group.** HostRename does not add any account to a privileged group.
- The client task runs as SYSTEM, so the script share must be writable by administrators only. See "Security and known limitations" in `README.md`.

## Deutsch

Sicherheitslücken bitte **nicht** über öffentliche GitHub-Issues melden.

Stattdessen die private Meldefunktion von GitHub nutzen: **Security → Report a vulnerability** in diesem Repository. Bitte Beschreibung, Schritte zur Reproduktion und betroffene Version angeben. Du erhältst so schnell wie möglich eine Rückmeldung.

**Keine Umgebungsdaten angeben** – weder in einer Meldung noch in einem Issue oder Pull Request: keine Domänennamen, OUs, Server- oder Computernamen, IP-Adressen, Benutzernamen oder ungeschwärzte Logs. Stattdessen Platzhalter wie `<domain>`, `<OU>` oder `<server>` verwenden.

Sicherheitskorrekturen gibt es nur für die jeweils neueste Version.

### Sicherheitskonzept in Kürze

- **Es werden keine Passwörter gespeichert.** Die Umbenennung funktioniert über die Delegation an `NT AUTHORITY\SELF`: Jedes Computerkonto darf nur sein eigenes AD-Objekt ändern, begrenzt auf die Client-OU. Die Delegation lässt sich mit `Prepare-HostRename.ps1 -Action Remove -Component Delegation` entfernen.
- **Keine zusätzliche Administratorgruppe.** HostRename nimmt kein Konto in eine privilegierte Gruppe auf.
- Die Client-Aufgabe läuft als SYSTEM; deshalb darf nur die Administration auf die Skriptfreigabe schreiben. Siehe „Sicherheit und bekannte Einschränkungen“ in `README.de.md`.
