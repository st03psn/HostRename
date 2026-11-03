# Umsetzungsplan: HostRename über ACMP verteilen

Stand: 3. November 2026 · Status: Entscheidungen getroffen, Umsetzung läuft (Version 1.2.0)

[English version](../acmp-deployment-plan.md)

Aufbauanleitung: [acmp-anleitung.md](acmp-anleitung.md) · Gerätetestplan: [testplan.md](testplan.md)

## Ausgangslage

- Rund 700 Clients, davon etwa 90 % Notebooks. Viele sind selten per Kabel im Firmennetz.
- Außerhalb: DirectAccess (DA) mit Benutzername und Kennwort, ohne Computerzertifikate.
- In der Firma meist WLAN mit EAP-TLS und Computerzertifikaten.
- Verteilung über ACMP statt GPO: Der ACMP-Agent läuft als SYSTEM, kann gezielt Clients ansprechen, Dateien transportieren, Dialoge zeigen und Neustarts steuern.

## Ziele

1. Umbenennen über ACMP, ohne GPO, ohne Scheduled Task, ohne OU-Filter.
2. Kein Umbenennen im EAP-TLS-WLAN; stattdessen ein Hinweis an den Benutzer, das LAN-Kabel zu nutzen.
3. ACMP wertet den Exit-Code aus und kündigt den Neustart in einem vertrauten Dialog an.
4. Der Ablauf ist so gebaut, dass er für andere Eingriffe wiederverwendbar ist (Netzwerkbedingung, Exit-Code-Vertrag, Neustart-Dialog, Abschlussmeldung).

## Fachliche Bewertung der Netzwerkwege

**Kabel im Firmennetz:** unkritisch, sofern der LAN-Port nicht ebenfalls 802.1X mit Computerzertifikaten verlangt (zu prüfen, siehe Phase 0).

**DirectAccess:** wahrscheinlich tragfähig, die Vorabprüfungen des Skripts (DC, Secure Channel, Rechte) greifen. Risiko ist die Zeit zwischen Umbenennen und Neustart: Das Gerät arbeitet lokal noch mit dem alten Namen, das AD-Objekt hat schon den neuen. Anmeldungen des Computerkontos können in dieser Zeit scheitern, und davon hängt bei DA der Tunnel ab. Deshalb den Neustart zeitnah erzwingen (Frist, siehe Neustart-Regeln). Im bisherigen Pilot konnte ein umbenanntes Gerät vor dem Neustart noch auf den Log-Share schreiben, das ist ein Hinweis, aber kein Beleg für DA.

**EAP-TLS-WLAN:** wahrscheinlich das erwartete Henne-Ei-Problem. Seit der vollen Durchsetzung von KB5014754 braucht die Zertifikatsanmeldung eine starke Zuordnung; die SID-Erweiterung im Zertifikat bestätigt dabei ein Konto, das zuvor über eine unterstützte Zuordnung (z. B. den Namen) gefunden wurde. Nach dem Umbenennen gibt es zum alten Namen im Zertifikat kein Konto mehr. Folgen:
- Schon **vor dem Neustart** kann eine erneute WLAN-Anmeldung (Reauthentifizierung, Wechsel des Access Points) scheitern.
- **Nach dem Neustart** meldet sich das Gerät mit altem Zertifikat an und bekommt kein Netz, also auch kein neues Zertifikat.
- Daraus folgt: Umbenennen nur über Kabel oder DA, und das Gerät braucht nach dem Neustart ein **neues Computerzertifikat** mit dem neuen Namen, bevor es wieder ins WLAN geht.

Ob es in dieser Umgebung tatsächlich so kommt (oder ob die Zuordnung doch über die SID gelingt), klärt Phase 0 an einem Testgerät. Bis dahin ist es eine begründete Annahme.

## Lösungsbausteine

### 1. Netzwerk-Gate (`Test-DeploymentNetwork.ps1`, neu, wiederverwendbar)

Stellt fest, über welchen Weg das Gerät gerade mit der Domäne verbunden ist, und gibt das als Exit-Code zurück. Konfigurierbar, welche Wege erlaubt sind (`-Allow Lan, DirectAccess`) und welche SSIDs als Firmen-WLAN mit EAP-TLS gelten (`-CorporateSsid`).

Erkennung sprachunabhängig (Lehre aus dem Pilot: deutsche Systemsprache), also **keine** Auswertung von `netsh`-Texten:
- Kabel: aktiver physischer Adapter mit Medientyp 802.3 (`Get-NetAdapter`), Profil `DomainAuthenticated` (`Get-NetConnectionProfile`). Docking-Stationen und USB-LAN-Adapter zählen als Kabel.
- DirectAccess: `Get-DAConnectionStatus` (Status „ConnectedRemotely“); nur auf DA-Clients vorhanden, Fehlen abfangen.
- WLAN und SSID: über die WinRT-Klasse `Windows.Networking.Connectivity.NetworkInformation` (verbundene SSID), Abgleich mit `-CorporateSsid`.
- Domäne erreichbar: DC per DNS-Auflösung und Port (wie die Vorabprüfungen im Client-Skript).

| Exit-Code | Bedeutung | Reaktion in ACMP |
| --- | --- | --- |
| 0 | erlaubter Weg (Kabel bzw. DA), Domäne erreichbar | weiter |
| 20 | nur Firmen-WLAN (EAP-TLS) | Benutzerdialog „Bitte LAN-Kabel anschließen“, Abbruch, später erneut |
| 21 | keine Domänenverbindung (offline, fremdes Netz ohne DA) | still beenden, später erneut |
| 22 | Weg erkannt, aber nicht erlaubt (z. B. DA, wenn nur Kabel erlaubt ist) | still beenden, später erneut |

Das Gate gehört nicht in das Client-Skript, sondern bleibt eigenständig: So lässt es sich vor jede andere Aktion setzen (andere Software, Zertifikatstausch, Domänen-Neuaufnahme).

### 2. Client-Skript im ACMP-Modus (`Invoke-HostRename.ps1`, kleine Änderung)

Die Logik bleibt, ebenso die Exit-Codes (0, 3010, 1, 2, 4, 5). Anzupassen:
- Bei `-Cleanup` darf das Skript seine eigene Datei nicht löschen, wenn es nicht aus `$LocalFolder` läuft (unter ACMP liegt es in dessen Ablage). Vorschlag: Schalter `-KeepScript` oder Erkennung über den Pfad. Den Task entfernt die Bereinigung ohnehin nur, wenn er existiert.
- Kein `-Reboot`: Den Neustart steuert ACMP.
- Lokale Logs über `-LocalDir` an einen festen Ort (im ACMP-Modus `C:\ProgramData\HostRename`; umgesetzt als geschützter Ordner: Prüfung von Besitzer und Analysepunkt, ACL nur SYSTEM und Administratoren, weil Standardbenutzer in ProgramData Ordner anlegen dürfen).
- Nur 64-Bit-PowerShell (umgesetzt: ein 32-Bit-Prozess auf 64-Bit-Windows endet mit Exit 1, bevor etwas geschrieben wird; ein 32-Bit-Agent ruft `%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe` auf).
- Ohne zentrales Log: `-NoCentralLog` (umgesetzt; `-CentralLogPath ''` ist mit `powershell.exe -File` unzuverlässig).
- Zentrales CSV-Log optional beibehalten (über DA erreichbar?), Rückmeldung zusätzlich über ACMP (siehe 5).

### 3. Zertifikatserneuerung (`Update-ComputerCertificate.ps1`, neu, wiederverwendbar)

Läuft nach dem Neustart, nur über Kabel oder DA:
- Neues Computerzertifikat aus der Vorlage für das WLAN anfordern (Vorlagenname als Parameter), z. B. mit `Get-Certificate -Template <Name> -CertStoreLocation Cert:\LocalMachine\My`.
- Prüfen, dass der neue DNS-Name im Zertifikat steht.
- Alte Zertifikate derselben Vorlage mit altem Namen entfernen, damit das WLAN nicht das falsche wählt.
- Exit-Codes: 0 erneuert bzw. nicht nötig, 1 Fehler (später erneut).

Ob der Schritt nötig ist und welche Vorlage gilt, klärt Phase 0.

### 4. ACMP Client Command „HostRename“

Ablauf in einem Client Command (Bausteine aus dem Editor: Dateien/File Repository, eigene Skripte, Bedingungen, Ablaufsteuerung, Dialoge):

1. Skripte aus dem File Repository auf den Client übertragen.
2. Zustand lesen: Existiert der Marker-Schlüssel `HKLM\SOFTWARE\HostRename`, ist das Gerät fertig und der Lauf endet. `TargetName` in `HKLM\SOFTWARE\HostRenameState` zeigt, dass die Umbenennung stattgefunden hat. Niemals die bloße Existenz von `HostRenameState` als Kriterium nehmen: Seit 1.2.0 existiert der Schlüssel nach jedem Lauf wegen der Berichtswerte.
3. Gate ausführen. 20: Dialog „LAN-Kabel“; 21/22: still beenden.
4. `Invoke-HostRename.ps1` ausführen (Parameter für Vorlage, Prefix usw. im Client Command).
5. Exit-Code auswerten:
   - 3010: Neustart-Dialog mit Frist (siehe unten), Neustart durch ACMP. Hinweis im Dialog: Kabel bis nach dem Neustart angeschlossen lassen.
   - 0: Name passt schon, weiter mit 6.
   - 1: Fehler, beim nächsten Lauf erneut; nach mehreren Fehlschlägen in den Bericht.
   - 2, 4, 5: dauerhaftes Problem (Name zu lang, keine Rechte, keine Seriennummer), nicht wiederholen, in den Bericht.
6. Nach dem Neustart (nächster Lauf, wieder über das Gate): Zertifikat erneuern (nur für WLAN-Geräte), dann `Invoke-HostRename.ps1 -Cleanup` (ACMP-Modus), Status melden.

Die Exit-Codes der Skripte sind 0 bis 5, 20 bis 22 und 3010. ACMP verwendet eigene Codes ab 100 und ab 1001; alle Skriptcodes außer 3010 bleiben darunter. 3010 überschneidet sich zahlenmäßig mit dem Bereich von ACMP: in ACMP prüfen, wie es behandelt wird (Gerätetest A1).

**Neustart-Regeln (zu entscheiden):** Verschieben nur begrenzt (z. B. bis Arbeitsende, höchstens X Stunden), danach Neustart mit Vorwarnung. Begründung: Zwischenzustand alter/neuer Name, bei DA Risiko für den Tunnel. Prüfen, ob der vorhandene ACMP-Neustart-Dialog (Windows Update Management) dafür nutzbar ist.

### 5. Rückmeldung und Bericht

- ACMP-Benutzerdefinierte Felder (z. B. Phase, Zielname, letzter Exit-Code, Zeitpunkt) aus der Registry des Clients füllen und daraus einen Bericht für die 700 Geräte bauen.
- Das zentrale CSV-Log bleibt als Nachweis, wenn der Share erreichbar ist.

### 6. Was aus der GPO-Lösung bleibt

- **Delegation bleibt nötig:** Auch unter ACMP benennt das Gerät mit seinem eigenen Computerkonto um (SYSTEM), also mit den Rechten aus `-Component Delegation`.
- **Share** nur, wenn das zentrale Log bleibt.
- **GPO nicht verknüpfen** für Geräte, die über ACMP laufen; sonst laufen beide Wege gleichzeitig auf einem Gerät.

## Vorgehen

### Phase 0: Klärung an Testgeräten (keine Voraussetzung; Teil der Testphasen, siehe `docs/roadmap.md`)

1. **WLAN:** Testgerät per Kabel umbenennen, neu starten, dann nur WLAN: Verbindet es sich? Danach neues Zertifikat anfordern: verbindet es sich dann? Vorlagenname für das WLAN-Zertifikat festhalten.
2. **Vor dem Neustart:** Testgerät per Kabel umbenennen, Kabel ziehen, WLAN neu verbinden lassen: Bricht die Anmeldung schon ab?
3. **DirectAccess:** Testgerät über DA umbenennen, nach einigen Stunden ohne Neustart: Tunnel, ACMP-Verbindung und Log-Share noch erreichbar? Dann Neustart: kommt DA wieder hoch?
4. **LAN-Port:** Verlangt der Kabelport 802.1X mit Computerzertifikat? Falls ja, gilt das Henne-Ei-Problem auch dort.
5. **ACMP:** Wie wird der Exit-Code eines PowerShell-Skripts übernommen? Können Dialoge im Benutzerkontext erscheinen, während der Client Command als SYSTEM läuft? Wie verhält sich ACMP nach dem Umbenennen (gleicher Client oder Dublette, Historie, Container-Regeln nach Namen)?
6. **Weitere Namensabhängigkeiten** prüfen: EDR/Virenschutz-Konsole, MDM, WSUS, Lizenzserver, DNS-Altlasten (alter A-Eintrag), Druck- und Dateiberechtigungen auf Computernamen.

### Phase 1: Skripte anpassen und testen

- Gate neu, mit Pester-Tests (Erkennung per Mocks, Exit-Codes).
- Client-Skript: ACMP-Modus für die Bereinigung; bestehende Tests anpassen, neue Tests für den Modus.
- Zertifikatsskript neu, mit Tests (soweit ohne CA möglich).
- README um einen Abschnitt „Verteilung über ACMP“ ergänzen.

### Phase 2: ACMP Client Command bauen

Client Command nach Abschnitt 4, Dialogtexte abstimmen, Test an je einem Gerät pro Fall: Kabel, DA, Firmen-WLAN (Hinweisdialog), offline.

### Phase 3: Trockenlauf auf allen Geräten

`Invoke-HostRename.ps1 -WhatIf` über ACMP auf allen rund 700 Geräten: Zielnamen, Dubletten, fehlende Seriennummern, zu lange Namen. Die Funde vor dem Echtlauf bereinigen.

### Phase 4: Rollout in Wellen

Pilot (rund 20 Geräte, alle Fälle), dann rund 100, dann der Rest. Weiter erst, wenn Fehlerquote und Helpdesk-Aufkommen passen. Über den Bericht nachverfolgen, welche Geräte hängen (z. B. nie per Kabel oder DA online).

### Phase 5: Abschluss

Alle Geräte fertig: Client Command deaktivieren, Delegation entfernen (`-Action Remove -Component Delegation`), Reste per Bericht prüfen.

## Wiederverwendung für andere Software

Der Rahmen besteht aus vier austauschbaren Teilen: Gate mit erlaubten Wegen, eigentliche Aktion, Exit-Code-Vertrag (0 fertig, 3010 Neustart, 1 später erneut, 2–9 dauerhaftes Problem, 20–29 Netzwerk) und Neustart-Dialog mit Frist. Für eine andere Software wird nur die Aktion getauscht; Gate und Dialoge bleiben. Den Vertrag als ACMP-Vorlage anlegen, damit jeder neue Client Command dieselbe Auswertung nutzt.

## Entscheidungen

- **Erlaubte Wege zum Umbenennen:** LAN-Kabel und DirectAccess (Vorgabe des Netzwerk-Gates, konfigurierbar).
- **Neustart-Frist:** noch offen, wird in der Testphase festgelegt (ACMP-Seite).
- **Zertifikatsvorlage für das WLAN:** noch unbekannt, daher Pflichtparameter; alte Zertifikate werden nur mit dem Schalter `-RemoveOld` entfernt.
- **Zentrales CSV-Log:** bleibt als Option zusätzlich zur ACMP-Rückmeldung.
- **Lokale Logs im ACMP-Modus:** `C:\ProgramData\HostRename` (vom Skript vor jedem Lauf geschützt; ein ausdrücklich angegebenes `-LocalDir` darf für Standardbenutzer nicht beschreibbar sein).
- **GPO-Weg:** bleibt erhalten; GPO und ACMP sind alternative Verteilwege und nie gleichzeitig auf demselben Gerät aktiv.
- **Phase 0 ist keine Voraussetzung mehr:** Der Nutzer kann sie nicht vorab einplanen; Geräteprüfungen sind Teil der Testphasen in `docs/roadmap.md`.
