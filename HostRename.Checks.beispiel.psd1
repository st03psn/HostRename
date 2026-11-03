@{
    # HostRename - Beispiel für die Test-Konfiguration (Version 1.1.9)
    #
    # Die echte Datei HostRename.Checks.psd1 schreibt Prepare-HostRename.ps1 (-Action Setup) aus seinen Variablen.
    # Diese Beispieldatei wird nicht verwendet; sie zeigt nur den Aufbau (zum manuellen Kopieren, falls die Tests
    # ohne Setup laufen sollen). Die Werte müssen zu Prepare-HostRename.ps1 und der GPO passen.
    # Kodierung: UTF-8 mit BOM.

    GpoName           = 'COMP - HostRename'
    ClientOuDN        = @('OU=Clients,DC=contoso,DC=com')      # mehrere OUs möglich
    SourceShareFolder = '\\FILESERVER\HostRename$\scripts'
    ScriptName        = 'Invoke-HostRename.ps1'
    LocalFolder       = 'C:\Program Files\HostRename'
    CentralLogPath    = '\\FILESERVER\HostRename$\log\rename-log.csv'
    NameTemplate      = ''        # leer = Prefix/Suffix verwenden, sonst z. B. 'DE{Serial}'
    Prefix            = 'NG-'
    Suffix            = ''
    NameLike          = 'NG-*'    # Muster für den Namen nach der Umbenennung (bei 'DE{Serial}': 'DE*')
    OnTooLong         = 'TruncateEnd'   # TruncateEnd | TruncateStart | Skip
    OnSerialProblem   = 'GenerateId'    # GenerateId | Skip (nur Vorlagen mit {Serial})
    FutureIdLength    = 8
    RegistrationTrigger = $true   # Start sofort nach dem Anlegen (ohne Verzögerung); $false = ohne diesen Trigger
    RepeatInterval    = ''        # Wiederholung des täglichen Triggers (z. B. 'PT1H'); Standard: leer = ohne
    TaskName          = 'HostRename'
    CleanupGpoName    = 'COMP - HostRename Cleanup'
    CleanupRegKeys    = @('SOFTWARE\HostRename', 'SOFTWARE\HostRenameState')      # von der Bereinigungs-GPO gelöschte HKLM-Schlüssel
    MarkerRegistryKey = 'SOFTWARE\HostRename'

    ExpectCleanup     = $true     # entspricht $CleanupAfterSuccess
    ExpectHardening   = $false    # entspricht $HardenLocalFolder
    PilotGroup        = ''        # Sicherheitsfilter-Gruppe der GPO; leer = nicht prüfen
}
