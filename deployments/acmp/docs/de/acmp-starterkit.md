# ACMP-Starter-Kit: erster Test von HostRename

[English version](../acmp-starter-kit.md) · Bauanleitung: [acmp-anleitung.md](acmp-anleitung.md) · Rollout und Prüfung eines Laufs: [acmp-rollout.md](acmp-rollout.md) · Gerätetests: [testplan.md](testplan.md)

Stand: 3. November 2026 · Version 1.2.0

Eine Übergabe für Tester, die ACMP haben, aber dieses Projekt noch nie gesehen haben. Sie enthält nur, was für die ersten Tests nötig ist; der Hintergrund steht in den verlinkten Dokumenten.

## 1. Worum es geht

HostRename benennt domänenverbundene Windows-Clients nach einer Namensvorlage um (zum Beispiel `DE` + Seriennummer) und benennt zugleich ihr AD-Computerobjekt um; das Gerät erledigt das selbst als SYSTEM, mit einer delegierten Berechtigung auf sein eigenes AD-Objekt (kein Passwort). Unter ACMP führt ein Client-Command immer wieder den Wrapper `Invoke-AcmpHostRename.ps1` aus: Er prüft den Zustand, prüft das Netzwerk (nur LAN-Kabel oder DirectAccess), benennt um, fordert einen Neustart an (Exit-Code 3010), erneuert nach dem Neustart bei entsprechender Konfiguration das WLAN-Zertifikat und markiert das Gerät als fertig. Der Client-Command muss nur vier Skripte übertragen, den Wrapper starten und für zwei Exit-Codes einen Dialog zeigen.

> **Teststand: In ACMP ist noch nichts gelaufen.** Die Skripte wurden nur in einer Simulation mit Mocks getestet (Linux, PowerShell 7). Ihre Tests sind die ersten echten. Die ACMP-Menü- und Befehlsnamen unten sind allgemein gehalten und mit „in ACMP prüfen“ markiert: Bitte die echten Namen notieren.

## 2. Werte, die du in deiner Umgebung ermittelst

Diese Werte ermittelst du vor dem ersten Test selbst in deiner Umgebung. Niemand trägt sie vorab für dich ein. Halte sie in deinen eigenen Notizen fest, nicht im Repository, und verwende sie in jedem Client-Command identisch.

| Wert | Platzhalter | So findest du ihn |
| --- | --- | --- |
| Namensvorlage | `<NameTemplate>` | Bei der Stelle erfragen, die die Namenskonvention festlegt. Für den ersten Test geht eine gut erkennbare Testvorlage, z. B. `TST{Serial:-8}` (Präfix `TST` plus die letzten 8 Zeichen der Seriennummer). Wird die Vorlage später geändert, werden die Testgeräte erneut umbenannt; das ist unproblematisch. Syntax: README, Abschnitt „Namensvorlagen“ |
| Zentrales Log | `-NoCentralLog` oder `-CentralLogPath <UNC-Pfad>` | Für den ersten Test `-NoCentralLog`: kein Share nötig, das lokale Log bleibt auf dem Gerät. Ein zentrales Log nur verwenden, wenn ein Share mit `Prepare-HostRename.ps1 -Component Share` eingerichtet wurde |
| SSID(s) des Firmen-WLANs | `<CorporateSsid>` | Auf einem Gerät, das mit dem Firmen-WLAN verbunden ist: `netsh wlan show interfaces` (Zeile „SSID“) oder der Netzwerkname in der Windows-Netzwerkliste. Mehrere SSIDs durch Komma getrennt |
| Name der Zertifikatvorlage (nur WLAN-Geräte) | `<CertificateTemplate>` | Der **Vorlagenname**, nicht der Anzeigename. Auf einem Gerät mit WLAN-Computerzertifikat: `certutil -store My`, beim Zertifikat für das WLAN nach „Vorlage=“/„Template=“ suchen; oder auf der CA: `certutil -CATemplates`. Im Zweifel den Zertifikatsschritt im ersten Test (T-F) weglassen |
| Test-OU | `<OU DN>` | Die OU, in der die Testgeräte liegen: auf einem Testgerät `([adsisearcher]"(&(objectCategory=computer)(name=$env:COMPUTERNAME))").FindOne().Properties.distinguishedname`, ohne den Teil `CN=<Gerät>,`. Auf dieser OU muss die Delegation gesetzt sein (Abschnitt 3) |
| Testgeräte | LAN · DirectAccess (optional) · WLAN-Benutzer | Eigene Geräte, die umbenannt werden dürfen; am besten eins je Weg |

## 3. Checkliste der Voraussetzungen

- [ ] **Delegation** auf der Test-OU gesetzt, durch einen Domänenadmin auf einem Admin-PC oder DC, in einer PowerShell mit erhöhten Rechten; zuerst mit `-WhatIf`:

  ```powershell
  .\Prepare-HostRename.ps1 -Action Setup -Component Delegation -OuDN '<OU DN>' -WhatIf
  .\Prepare-HostRename.ps1 -Action Setup -Component Delegation -OuDN '<OU DN>'
  ```

- [ ] Nur mit zentralem Log: die Freigabe existiert (`-Component Share`, auf dem Dateiserver ausführen; siehe [README](../../../../README.de.md)).
- [ ] **Keine HostRename-GPO** mit den Testgeräten verknüpft (GPO und ACMP werden nie auf demselben Gerät verwendet).
- [ ] 2–3 **dedizierte Testgeräte** in der Test-OU: eines am LAN-Kabel, optional eines über DirectAccess, ein WLAN-Benutzer (nutzt das Firmen-WLAN mit Computerzertifikat). Niemand ist auf ihre Namen angewiesen.
- [ ] Die Dateien aus dem ACMP-Release-Paket `HostRename-<version>-acmp.zip` (alle in einem Ordner), unverändert (UTF-8 mit BOM; nicht in einem Editor öffnen und speichern): `Invoke-AcmpHostRename.ps1`, `Invoke-HostRename.ps1`, `Test-DeploymentNetwork.ps1`, `Update-ComputerCertificate.ps1`.

## 4. Client-Command „HostRename – Rename“ aufbauen

ACMP-Hintergrund (aus der Aagon-Dokumentation; in ACMP prüfen): Ein Client-Command wird in der Phase **Erstellen/Bearbeiten** angelegt und bearbeitet, in der Phase **Test** auf Testclients ausprobiert und durchläuft dann **Synchronisieren** und **Freigeben**, bevor er in der Phase **Ausführen** zugewiesen werden kann.

1. Einen neuen Client-Command `HostRename – Rename` **anlegen** (in ACMP prüfen: wo Client-Commands angelegt werden).
2. **Dateien übertragen.** Die vier Skripte so hinzufügen, dass sie auf den Client in denselben Ordner kopiert werden, zum Beispiel das Projektverzeichnis `%PROJECTDIR%`. In ACMP prüfen: den genauen Befehl für die Dateiübertragung, ob `%PROJECTDIR%` das richtige Ziel ist und ob der ACMP-Client diesen temporären Ordner nach dem Lauf löscht (die Skripte müssen nicht bleiben; jeder Lauf überträgt sie neu).
3. **Den Wrapper ausführen** als SYSTEM in der **64-Bit**-Windows-PowerShell (in ACMP prüfen: den Befehl, der ein Programm oder PowerShell ausführt, und ob er 32-Bit läuft). Arbeitsordner = der Ordner der Skripte. LAN-/DirectAccess-Geräte:

   ```text
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PROJECTDIR%\Invoke-AcmpHostRename.ps1" -NameTemplate "<NameTemplate>" -NoCentralLog -CorporateSsid "<CorporateSsid>"
   ```

   WLAN-Geräte (fügt die Zertifikaterneuerung nach dem Neustart hinzu):

   ```text
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PROJECTDIR%\Invoke-AcmpHostRename.ps1" -NameTemplate "<NameTemplate>" -NoCentralLog -CorporateSsid "<CorporateSsid>" -CertificateTemplate "<CertificateTemplate>" -RemoveOldCertificates
   ```

   Mit zentralem Log `-NoCentralLog` durch `-CentralLogPath "<UNC path>"` ersetzen. Läuft der ACMP-Agent als 32-Bit-Prozess, statt `powershell.exe` den Pfad `%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe` verwenden (sonst endet der Wrapper mit Exit-Code 1 und `[ERROR] PLATFORM`).
4. **Ausgabe und Exit-Code speichern** (in ACMP prüfen: wie stdout und der Exit-Code des Befehls in Variablen oder das Job-Protokoll übernommen werden). Die letzte Ausgabezeile ist die Zusammenfassungszeile `HOSTRENAME PHASE=... EXIT=... STEP=... MESSAGE="..."`.
5. **Den Exit-Code auswerten** mit Bedingungen:
   - **3010** → Neustart-Dialog an den Benutzer, dann Neustart durch ACMP. Textvorschlag: „Ihr Gerät wurde umbenannt und muss neu gestartet werden. Bitte speichern Sie Ihre Arbeit und lassen Sie das LAN-Kabel bis nach dem Neustart angeschlossen.“
   - **20** → Meldung an den Benutzer: „Bitte LAN-Kabel anschließen. Die Umbenennung Ihres Geräts ist nur über das Firmennetz per Kabel oder über DirectAccess möglich. Die Aktion wird später automatisch wiederholt.“
   - **alles andere** → Ende ohne Dialog.
   In ACMP prüfen: die Befehle für Dialog und Neustart, ob Dialoge den angemeldeten Benutzer erreichen, während der Befehl als SYSTEM läuft, und wie eine Neustart-Frist gesetzt wird.
6. **Andere Codes als 0 nicht so als „fehlgeschlagen“ markieren, dass die Wiederholung stoppt**: 1, 20, 21 und 22 bedeuten „später erneut versuchen“. 2, 4 und 5 sind dauerhaft; der Wrapper gibt sie weiter zurück, ohne etwas zu tun, bis das Gerät freigegeben wird (Abschnitt 8).
7. **Wiederholung**: Der Client-Command muss auf demselben Gerät erneut laufen (nach dem Neustart und solange es auf ein Kabel wartet). Einen Zeitplan wie Agent-Start plus täglich verwenden (in ACMP prüfen). Auf einem fertigen Gerät endet der Wrapper sofort mit Exit-Code 0.
8. Einen zweiten Client-Command `HostRename – Dry run` anlegen, mit derselben Befehlszeile plus `-WhatIf`, ohne Dialoge und ohne Neustart.
9. **Test, Synchronisieren, Freigeben** (in ACMP prüfen), dann nur den Testgeräten zuweisen.

## 5. Erste Testfolge

Das Ergebnis jedes Tests in die Tabelle in Abschnitt 7 eintragen.

| ID | Test | Gerät | Erwartetes Ergebnis |
| --- | --- | --- | --- |
| T-A1 | 64-Bit-Prüfung: ein Testbefehl führt `powershell.exe -NoProfile -Command "[Environment]::Is64BitProcess"` aus | beliebig | `True`; bei `False` den Sysnative-Pfad verwenden |
| T-A2 | Durchreichen des Exit-Codes: Testbefehle mit `exit 0`, `exit 20`, `exit 3010` | beliebig | jeder Code kommt unverändert in der Bedingung an; notieren, wie ACMP 3010 behandelt (er liegt in ACMPs eigenem Code-Bereich ab 1001) |
| T-A3 | Dialog: Testbefehl zeigt den LAN-Kabel-Text | LAN, Benutzer angemeldet | Dialog erscheint in der Benutzersitzung |
| T-B | Probelauf (`HostRename – Dry run`) | LAN | Exit-Code 0, Zusammenfassung `PHASE=DryRun`, eine Zeile `WHATIF: '<old>' would be renamed to '<new>'`; auf dem Gerät nichts geändert |
| T-C1 | Echter Lauf, erster | LAN | Exit-Code 3010, `PHASE=RebootRequired`, Neustart-Dialog |
| T-C2 | Echter Lauf erneut vor dem Neustart (wenn der Dialog verschoben wird) | LAN | wieder Exit-Code 3010, keine zweite Umbenennung (`PENDING_REBOOT` in der Ausgabe) |
| T-C3 | Nach dem Neustart, nächster Lauf | LAN | Exit-Code 0, `PHASE=Done STEP=Cleanup`; Computername ist der neue Name |
| T-C4 | Noch ein Lauf | LAN | Exit-Code 0 sofort, `PHASE=Done STEP=StateCheck`, keine Skriptausgabe |
| T-D | Echter Lauf nur im WLAN (Kabel gezogen) | WLAN-Benutzer | Exit-Code 20, `PHASE=Gate`, LAN-Kabel-Dialog, nichts umbenannt; mit eingestecktem Kabel benennt der nächste Lauf um (3010) |
| T-E | (optional) Echter Lauf über DirectAccess, außer Haus | DA | wie T-C; die Zeit zwischen Umbenennung und Neustart notieren und ob der DA-Tunnel bestehen bleibt |
| T-F | WLAN-Benutzer mit `-CertificateTemplate`: nach dem Neustart am Kabel | WLAN-Benutzer | `HOSTRENAME STEP=Certificate`, Zertifikatszeile `RESULT=RENEWED`, dann Cleanup, Exit-Code 0 `PHASE=Done`; danach funktioniert das WLAN ohne Kabel |

## 6. Woran man erkennt, dass ein Lauf funktioniert hat

- **Zusammenfassungszeile** (letzte Zeile der Job-Ausgabe): `PHASE` und `EXIT` wie in Abschnitt 5 erwartet.
- **Registry auf dem Gerät** (als Administrator):

  ```powershell
  Get-ItemProperty HKLM:\SOFTWARE\HostRenameState    # LastExitCode, LastEvent, TargetName, OriginalName
  Test-Path HKLM:\SOFTWARE\HostRename                # True = fertig (Marker); nichts anderes bedeutet „fertig“
  ```

- **Lokales Log** (nur als Administrator oder SYSTEM lesbar): `C:\ProgramData\HostRename\rename-local.csv`.
- **AD**: Das Computerobjekt hat den neuen Namen, es bleibt kein Objekt mit dem alten Namen (`Get-ADComputer`).

Details je Phase und Stufe: [acmp-rollout.md](acmp-rollout.md), Abschnitt 4.

## 7. Was zurückzusenden ist

Bitte diese Tabelle ausfüllen und samt dem darunter aufgeführten Material senden. **Umgebungsdaten entfernen** (Domäne, Server-, OU- und Gerätenamen, Benutzernamen, IP-Adressen) oder durch Platzhalter ersetzen.

| ID | Datum | Gerätetyp | Exit-Code | Zusammenfassungszeile (`HOSTRENAME PHASE=...`) | OK / Abweichung | Hinweis |
| --- | --- | --- | --- | --- | --- | --- |
| T-A1 | | | | – | | |
| T-A2 | | | | – | | wie 3010 behandelt wird |
| T-A3 | | | | – | | |
| T-B | | | | | | |
| T-C1 | | | | | | |
| T-C2 | | | | | | |
| T-C3 | | | | | | |
| T-C4 | | | | | | |
| T-D | | | | | | |
| T-E | | | | | | |
| T-F | | | | | | |

Außerdem senden:

- die vollständige Job-Ausgabe jedes fehlgeschlagenen oder überraschenden Laufs und die letzten 20 Zeilen des lokalen Logs dieses Geräts;
- die echten ACMP-Namen der verwendeten Befehle (Dateiübertragung, Programm/PowerShell ausführen, Bedingung auf den Exit-Code, Meldung, Neustart) und die Variable, die den Exit-Code enthält;
- Antworten: Ist der Agent 32- oder 64-Bit? Kommt 3010 unverändert an? Erreichen Dialoge den Benutzer? Wird `%PROJECTDIR%` nach dem Lauf aufgeräumt?
- **den fertigen Client-Command als Exportdatei** (in ACMP prüfen: Versionsverlauf oder Kontextmenü des Client-Commands → Export), damit er ins Repository aufgenommen und anderswo importiert werden kann.

## 8. Rückgängigmachen auf einem Testgerät

Ein Gerät mit dauerhaftem Fehler (Exit-Code 2, 4 oder 5) nach Behebung der Ursache (zum Beispiel der Delegation) freigeben, als Administrator auf dem Gerät:

```powershell
Remove-ItemProperty -Path HKLM:\SOFTWARE\HostRenameState -Name LastExitCode
```

Ein Testgerät zurückbenennen: zuerst das Gerät aus der Zuweisung des Client-Commands entfernen (sonst benennt der nächste Lauf es erneut um), dann als Administrator auf dem Gerät, am LAN-Kabel (der alte Name steht in `HostRenameState\OriginalName`):

```powershell
Rename-Computer -NewName '<OldName>' -Restart
# nach dem Neustart: die HostRename-Schlüssel und die lokalen Logs entfernen
Remove-Item HKLM:\SOFTWARE\HostRename, HKLM:\SOFTWARE\HostRenameState -Recurse -ErrorAction SilentlyContinue
Remove-Item C:\ProgramData\HostRename -Recurse -ErrorAction SilentlyContinue
```

Bei einem WLAN-Gerät danach das Computerzertifikat für den alten Namen erneuern (`Update-ComputerCertificate.ps1 -Template '<CertificateTemplate>' -RemoveOld` am Kabel ausführen). Nach den Tests die Delegation entfernen, wenn sie nicht mehr gebraucht wird: `.\Prepare-HostRename.ps1 -Action Remove -Component Delegation -OuDN '<OU DN>'`.
