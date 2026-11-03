@{
    # HostRename - Example test configuration (Version 1.1.9)
    #
    # The real file HostRename.Checks.psd1 is written by Prepare-HostRename.ps1 (-Action Setup) from its variables.
    # This example file is not used; it only shows the structure (to copy manually if the tests are to
    # run without Setup). The values must match Prepare-HostRename.ps1 and the GPO.
    # Encoding: UTF-8 with BOM.

    GpoName           = 'COMP - HostRename'
    ClientOuDN        = @('OU=Clients,DC=contoso,DC=com')      # multiple OUs possible
    SourceShareFolder = '\\FILESERVER\HostRename$\scripts'
    ScriptName        = 'Invoke-HostRename.ps1'
    LocalFolder       = 'C:\Program Files\HostRename'
    CentralLogPath    = '\\FILESERVER\HostRename$\log\rename-log.csv'
    NameTemplate      = ''        # empty = use Prefix/Suffix, otherwise e.g. 'DE{Serial}'
    Prefix            = 'NG-'
    Suffix            = ''
    NameLike          = 'NG-*'    # Pattern for the name after the rename (for 'DE{Serial}': 'DE*')
    OnTooLong         = 'TruncateEnd'   # TruncateEnd | TruncateStart | Skip
    OnSerialProblem   = 'GenerateId'    # GenerateId | Skip (templates with {Serial} only)
    FutureIdLength    = 8
    RegistrationTrigger = $true   # Start immediately after creation (without delay); $false = without this trigger
    RepeatInterval    = ''        # Repetition of the daily trigger (e.g. 'PT1H'); default: empty = none
    TaskName          = 'HostRename'
    CleanupGpoName    = 'COMP - HostRename Cleanup'
    CleanupRegKeys    = @('SOFTWARE\HostRename', 'SOFTWARE\HostRenameState')      # HKLM keys deleted by the cleanup GPO
    MarkerRegistryKey = 'SOFTWARE\HostRename'

    ExpectCleanup     = $true     # corresponds to $CleanupAfterSuccess
    ExpectHardening   = $false    # corresponds to $HardenLocalFolder
    PilotGroup        = ''        # Security filter group of the GPO; empty = do not check
}
