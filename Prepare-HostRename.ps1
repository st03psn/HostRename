<#
.SYNOPSIS
    HostRename - Preparation: creates or removes the share, AD delegation and GPO.

.DESCRIPTION
    A single place for the entire server side of HostRename. All paths and names are variables in the
    "ADJUST HERE" block at the top of the script.

    COMPONENTS (-Component, default: all three)
      Share        Folders and NTFS permissions, share, rename-log.csv with header row, copy of Invoke-HostRename.ps1
                   Run on: file server or DC, local administrator, elevated PowerShell
      Delegation   SELF may rename computer objects under the client OUs ($ClientOuDN, individual ones via -OuDN):
                   write cn, name, sAMAccountName, displayName and Account Restrictions, Reset password, and
                   the validated writes for DNS host name and SPN (computer objects only, descendants only)
                   Run on: DC or admin PC with RSAT, domain admin
      Gpo          GPO with file copy (GPP Files, action Replace) and scheduled task (GPP) with the triggers
                   Registration (start immediately after creation) and system startup (5 minute delay), optionally daily with repetition; item-level targeting on the registry marker;
                   the link is initially not created, or created disabled
                   Run on: DC or admin PC with RSAT, domain admin

    ACTIONS (-Action)
      Setup        First checks the renaming rule ($NameTemplate or $Prefix and $Suffix) and shows
                   example names, then creates everything (order: Share, Delegation, Gpo) and writes
                   HostRename.Checks.psd1 for the tests.
      Remove       Removes in the order Gpo, Delegation, Share:
                     Gpo          links in the domain, then the GPO
                     Delegation   the ACEs of SELF (ACL backup in the AclBackup folder beforehand)
                     Share        the share; folders and logs stay unless -RemoveData is used
                                  (the log file is copied to $LogArchiveDir first)

      CleanupGpo   Optional, only at the very end: cleanup GPO that deletes the HostRename registry keys
                   ($CleanupRegistryKeys) on the clients. It is not created together with Gpo and only if the main GPO
                   no longer exists. Not part of the default of -Component.
                   Run on: DC or admin PC with RSAT, domain admin

    -WhatIf only shows what the script would do. Remove asks for confirmation before deleting (except with -Force).
    If an OU is missing in AD, the delegation interactively asks for another OU (empty input = abort).
    Under PowerShell 7 the script restarts itself in Windows PowerShell 5.1, because the AD and
    GPO modules and the AD: drive are only reliably available there.

.PARAMETER Action
    Setup or Remove.

.PARAMETER Component
    Share, Delegation, Gpo and CleanupGpo, individually or combined (default: Share, Delegation, Gpo). Share
    works locally and runs on the file server; Delegation, Gpo and CleanupGpo run on an admin PC with
    RSAT or a DC. Example for separate machines: run only Share on the file server, then run
    Delegation and Gpo on the admin PC.

.PARAMETER OuDN
    Delegation only: distinguished name(s) of individual OUs on which the delegation is set or removed.
    Without it, all OUs from $ClientOuDN apply. This allows adding or withdrawing individual OUs later,
    including OUs that are not listed in $ClientOuDN.

.PARAMETER RemoveData
    Only with Remove and Share: additionally deletes $ShareRoot (the log file is copied to $LogArchiveDir
    first).

.PARAMETER Force
    No prompts: neither the safety prompt for Remove nor the prompt for a missing OU.

.EXAMPLE
    .\Prepare-HostRename.ps1 -Action Setup -WhatIf

    Dry run: checks the renaming rule and shows what would be created.

.EXAMPLE
    .\Prepare-HostRename.ps1 -Action Setup

    Creates the share, delegation and GPO.

.EXAMPLE
    .\Prepare-HostRename.ps1 -Action Setup -Component Share

    Share only (e.g. on a separate file server).

.EXAMPLE
    .\Prepare-HostRename.ps1 -Action Setup -Component Delegation -OuDN 'OU=Notebooks,DC=contoso,DC=com'

    Additionally sets the delegation on a single OU.

.EXAMPLE
    .\Prepare-HostRename.ps1 -Action Setup -Component Delegation, Gpo

    On the admin PC or DC when the share is on a file server and was created there with -Component Share.
    $ShareServer must point to the file server.

.EXAMPLE
    .\Prepare-HostRename.ps1 -Action Setup -Component CleanupGpo

    Right at the end, after all renames are done and the main GPO has been removed: creates the
    cleanup GPO that deletes the registry keys on the clients.

.EXAMPLE
    .\Prepare-HostRename.ps1 -Action Remove

    Removes GPO, delegation and share; folders and logs stay.

.EXAMPLE
    .\Prepare-HostRename.ps1 -Action Remove -RemoveData -Force

    Removes everything without prompting, including the folders (the log file is archived first).

.NOTES
    Product          HostRename
    Version          1.1.9
    Date             2026-10-30
    Run on           Elevated Windows PowerShell 5.1 on the DC or file server as domain admin and local administrator
    Encoding         UTF-8 with BOM (required for Windows PowerShell 5.1)

.LINK
    README.md
#>
#Requires -Version 5.1

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Setup', 'Remove')]
    [string]$Action,

    [ValidateSet('Share', 'Delegation', 'Gpo', 'CleanupGpo')]
    [string[]]$Component = @('Share', 'Delegation', 'Gpo'),

    [string[]]$OuDN = @(),

    [switch]$RemoveData,

    [switch]$Force
)

# The AD/GPO modules, the AD: drive and live GPO objects only exist in Windows PowerShell 5.1.
# Under PowerShell 7 the script therefore restarts itself in 5.1 (with the same parameters).
if ($PSVersionTable.PSEdition -eq 'Core' -and $env:OS -eq 'Windows_NT') {
    $ps51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $relaunch = "& '{0}' -Action {1} -Component {2}" -f $PSCommandPath.Replace("'", "''"), $Action, ($Component -join ',')
    if ($OuDN)             { $relaunch += ' -OuDN ' + (($OuDN | ForEach-Object { "'" + $_.Replace("'", "''") + "'" }) -join ',') }
    if ($RemoveData)       { $relaunch += ' -RemoveData' }
    if ($Force)            { $relaunch += ' -Force' }
    if ($WhatIfPreference) { $relaunch += ' -WhatIf' }
    Write-Host 'PowerShell 7 detected - restarting Prepare-HostRename.ps1 in Windows PowerShell 5.1 ...' -ForegroundColor DarkGray
    & $ps51 -NoProfile -ExecutionPolicy Bypass -Command "$relaunch; exit `$LASTEXITCODE"
    exit $LASTEXITCODE
}

# =====================  ADJUST HERE  =====================

# --- Share (created on the machine where -Component Share runs) -----------------------------------
$ShareServer         = $env:COMPUTERNAME                      # Server name in the GPO's UNC paths (with a separate file server, its name)
$ShareRoot           = 'C:\HostRename'                        # Root folder on the server
$ShareName           = 'HostRename$'                          # Name of the (hidden) share
# Share permissions; the NTFS permissions additionally restrict each folder in any case:
#   Restricted = Administrators Full Control, Domain Computers Change
#   Everyone   = Everyone Full Control; permissions are controlled by NTFS alone (classic approach)
$ShareAccessMode     = 'Restricted'
$ScriptsFolderName   = 'scripts'                              # Subfolder with the client script (Domain Computers: read)
$LogFolderName       = 'log'                                  # Subfolder with the central log (Domain Computers: append only)
$LogFileName         = 'rename-log.csv'                       # central log file
$LogArchiveDir       = 'C:\HostRename-LogArchive'             # Remove -RemoveData: the log file is copied here first

# --- Client script -----------------------------------------------------------------------------------
$ScriptName          = 'Invoke-HostRename.ps1'                # must be located next to this script (is copied to $ScriptsFolderName)
$LocalFolder         = 'C:\Program Files\HostRename'          # Target folder on the client; standard users cannot modify anything under Program Files
# Lock down the folder ACL via icacls before each run: only needed if $LocalFolder is in a location
# writable by users (e.g. C:\ProgramData); not required under Program Files.
$HardenLocalFolder   = $false

# --- AD delegation -----------------------------------------------------------------------------------
# OUs (or containers) holding the computer objects to be renamed; multiple allowed.
$ClientOuDN          = @(
    'OU=Clients,DC=contoso,DC=com'
    # 'OU=Notebooks,DC=contoso,DC=com'
)
$AclBackupDir        = if ($PSScriptRoot) { Join-Path $PSScriptRoot 'AclBackup' } else { Join-Path $env:TEMP 'AclBackup' }

# --- GPO ---------------------------------------------------------------------------------------------
$GpoName             = 'COMP - HostRename'
$LinkTargetOU        = ''                                     # empty = do not link; otherwise the DN of the OU (the link is created DISABLED)
$SecurityFilterGroup = ''                                     # e.g. 'GG-HostRename-Pilot' (group with computer accounts); empty = all

# --- Cleanup GPO (optional, only after all renames are finished) -------------------------------------
# Deletes the HostRename registry keys on the clients. Link and security filter as for the main GPO.
$CleanupGpoName      = 'COMP - HostRename Cleanup'
# HKLM keys that the cleanup GPO deletes (marker and state). Keep only 'SOFTWARE\HostRename'
# if the state is to be preserved.
$CleanupRegistryKeys = @(
    'SOFTWARE\HostRename'
    'SOFTWARE\HostRenameState'
)

# --- Renaming rule (passed to the task) --------------------------------------------------------------
# Use either $NameTemplate OR $Prefix/$Suffix; the template takes precedence.
#   Placeholders {Name} = current host name, {Serial} = serial number (BIOS etc.; A-Z/0-9 only)
#   with length  {Serial:8} = first 8 characters, {Serial:-8} = last 8 characters (likewise {Name:4}, {Name:-4})
#   Examples     'DE{Serial}'          PC349219 -> DE<serial number>
#                'NG-{Name}'           PC349219 -> NG-PC349219   (equivalent to $Prefix = 'NG-')
#                'DE-{Serial:-8}'      DE- plus the last 8 characters of the serial number
#                '{Serial}-{Name:-4}'  serial number, hyphen, last 4 characters of the old name
$NameTemplate        = ''
$Prefix              = 'NG-'                                  # only without $NameTemplate: prefix before the current name
$Suffix              = ''                                     # only without $NameTemplate: suffix after the current name
# Only for templates with {Serial}: if the serial number is unusable or the target name is already taken in AD,
# a generated future ID (derived stably from the MachineGuid) replaces the serial number.
$OnSerialProblem     = 'GenerateId'                           # GenerateId | Skip (skip the device, exit code 5 or COLLISION)
$FutureIdLength      = 8                                      # Length of the future ID, 4 to 12 (characters A-Z without I/O, and 2-9)
$OnTooLong           = 'TruncateEnd'                          # TruncateEnd | TruncateStart | Skip (for more than 15 characters)
$Reboot              = $false                                 # $true = restart after the rename (with advance warning)
$RebootDelaySeconds  = 900                                    # Advance warning time for the restart, in seconds
$CleanupAfterSuccess = $true                                  # Remove task, script and local logs from the client after the rename
$MarkerRegistryKey   = 'SOFTWARE\HostRename'                  # HKLM marker; must match $MarkerKey in Invoke-HostRename.ps1

# --- Scheduled Task ----------------------------------------------------------------------------------
$TaskName            = 'HostRename'
$TaskRunAs           = 'SYSTEM'                               # Account of the task, language-independent ("NT AUTHORITY\System" fails on German clients)
$TaskUserId          = 'S-1-5-18'                             # the same account as a SID in the task XML
$BootDelay           = 'PT5M'                                 # Delay after system startup (ISO 8601); the task starts once per restart
# Registration trigger ("At task creation/modification"): the task starts immediately when the GPO creates it. It is deliberately created
# WITHOUT a delay: with the <Delay> element the GPO's GPMC report fails (verified with Test-GpoReport.ps1 -Candidates); without a
# delay it is displayed. With action Create it fires once on creation, with Update on every processing of the GPO.
$RegistrationTrigger = $true
# Additional daily trigger (time of day, e.g. '12:00') for devices that run for days without restarting. Empty = system startup only.
$DailyTriggerTime    = ''
# Repetition of the daily trigger over 24 hours (ISO 8601, e.g. 'PT1H'). It only takes effect together with a daily trigger
# (with an empty $DailyTriggerTime it begins at 00:00) and starts a task created only after boot at the latest after this
# interval. Empty = no repetition.
$RepeatInterval      = ''
# GPP action for the task:
#   C = Create   [default] only create if missing. The task stays unchanged across the restart, so that the "system startup" trigger
#                can fire. Changes to the task definition (rule, restart switch, paths) do NOT reach existing tasks: in that case delete the
#                task once on the devices that are not finished yet. The script itself is still replaced on every processing.
#   U = Update   Changes reach existing tasks. Observed: the task did not start after a restart because the GPO rewrites it at
#                boot (presumably after the system startup trigger). Can be compensated with $RepeatInterval.
#   R = Replace  delete and recreate (for the triggers the same as Update)
$TaskItemAction      = 'C'

# --- Configuration for the Pester tests --------------------------------------------------------------
$WriteChecksConfig   = $true                                  # Setup writes HostRename.Checks.psd1 from the values in this block
$ChecksConfigPath    = if ($PSScriptRoot) { Join-Path $PSScriptRoot 'HostRename.Checks.psd1' } else { Join-Path $env:TEMP 'HostRename.Checks.psd1' }
# ===========================================================

# Derived paths (do not change)
$DelegationOus     = @(if ($OuDN) { $OuDN } else { $ClientOuDN })     # -OuDN takes precedence over $ClientOuDN
$ShareUnc          = '\\' + $ShareServer + '\' + $ShareName
$SourceShareFolder = $ShareUnc + '\' + $ScriptsFolderName
$CentralLogPath    = $ShareUnc + '\' + $LogFolderName + '\' + $LogFileName

$ErrorActionPreference = 'Stop'

# ---- Helper functions --------------------------------------------------------------------------------
function Write-Step([string]$Text) { Write-Host "`n== $Text" -ForegroundColor Cyan }
function Write-Ok([string]$Text)   { Write-Host "   $Text" -ForegroundColor Green }
function Write-Info([string]$Text) { Write-Host "   $Text" -ForegroundColor DarkGray }

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function ConvertTo-XmlText([string]$Text) { [System.Security.SecurityElement]::Escape($Text) }
function New-GppUid {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Only generates a GUID string, does not change system state.')]
    param()
    '{' + [guid]::NewGuid().ToString().ToUpper() + '}'
}
function Write-Utf8File {
    param([string]$Path, [string]$Content)
    $dir = Split-Path $Path -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
}
function ConvertTo-PsLiteral([string]$Text) { "'" + $Text.Replace("'", "''") + "'" }

function ConvertTo-SidString {
    # Always compare principals by SID: names such as "NT AUTHORITY\SELF" differ depending on the system
    # language (German: "NT-AUTORITÄT\SELF").
    param($Identity)
    if ($Identity -is [System.Security.Principal.SecurityIdentifier]) { return $Identity.Value }
    try { return $Identity.Translate([System.Security.Principal.SecurityIdentifier]).Value } catch { return '' }
}

function Get-DomainSidValue {
    # SID of the domain this computer is a member of (without the AD module)
    $domainName = (Get-CimInstance Win32_ComputerSystem).Domain
    (New-Object Security.Principal.SecurityIdentifier(([ADSI]"LDAP://$domainName").objectSid[0], 0)).Value
}

function Initialize-AdContext {
    Import-Module ActiveDirectory -ErrorAction Stop
    $script:domain  = Get-ADDomain
    $script:pdc     = $script:domain.PDCEmulator     # all writes go to the same DC (avoids replication problems)
    $script:dnsRoot = $script:domain.DNSRoot
    Write-Info "Domain: $($script:dnsRoot) | PDC emulator: $($script:pdc)"
}

# ===========================================================================================
#  SHARE
# ===========================================================================================
function Invoke-ShareSetup {
    Write-Step "Share: $ShareUnc  ($ShareRoot)"

    $domainComputersSid  = (Get-DomainSidValue) + '-515'
    $domainComputersName = (New-Object Security.Principal.SecurityIdentifier $domainComputersSid).Translate([Security.Principal.NTAccount]).Value
    $adminsName          = (New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-544').Translate([Security.Principal.NTAccount]).Value
    $everyoneName        = (New-Object Security.Principal.SecurityIdentifier 'S-1-1-0').Translate([Security.Principal.NTAccount]).Value

    $scriptsDir = Join-Path $ShareRoot $ScriptsFolderName
    $logDir     = Join-Path $ShareRoot $LogFolderName
    $logFile    = Join-Path $logDir $LogFileName

    New-Item -ItemType Directory -Path $scriptsDir, $logDir -Force | Out-Null

    # Base: administrators and SYSTEM only (inheritance from the drive removed)
    & icacls.exe $ShareRoot /inheritance:r /grant '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F' | Out-Null
    # scripts: Domain Computers read/execute (GPP copies the script as the computer account), never write
    & icacls.exe $scriptsDir /grant:r "*${domainComputersSid}:(OI)(CI)RX" | Out-Null
    # log: Domain Computers may only create/append files, not read anything
    # Appending via .NET/SMB needs more than "write data/append data" (WD,AD). Verified in practice: with "W" alone and with WD,AD,WEA,WA,RC,S access was
    # denied; it works with "read attributes" (RA) added. Reading and deleting the contents remain forbidden (no RD, no D).
    & icacls.exe $logDir /grant:r "*${domainComputersSid}:(OI)(CI)(WD,AD,WEA,WA,RA,RC,S)" | Out-Null

    Write-Ok "Folders and NTFS permissions set ($scriptsDir, $logDir)"

    if (-not (Test-Path $logFile)) {
        # UTF-8 with BOM, identical in 5.1 and 7 (Excel recognizes umlauts); Set-Content -Encoding UTF8 writes no BOM in 7
        [System.IO.File]::WriteAllText($logFile, 'Timestamp;Level;Event;ComputerName;TargetName;Serial;MachineGuid;Message' + "`r`n", (New-Object System.Text.UTF8Encoding($true)))
        Write-Ok "Log file with header row created: $logFile"
    }
    else { Write-Info "Log file already exists: $logFile" }

    $localScript = if ($PSScriptRoot) { Join-Path $PSScriptRoot $ScriptName } else { $null }
    if ($localScript -and (Test-Path $localScript)) {
        Unblock-File -Path $localScript -ErrorAction SilentlyContinue      # remove the Mark-of-the-Web after download/ZIP
        Copy-Item -Path $localScript -Destination $scriptsDir -Force
        Write-Ok "Client script copied: $(Join-Path $scriptsDir $ScriptName)"
    }
    else { Write-Warning "'$ScriptName' is not next to this script - please copy it to '$scriptsDir' manually." }

    # Desired share permissions (account -> right); the NTFS permissions above restrict each folder in any case
    $wanted = if ($ShareAccessMode -eq 'Everyone') { @{ $everyoneName = 'Full' } } else { @{ $adminsName = 'Full'; $domainComputersName = 'Change' } }
    $modeText = if ($ShareAccessMode -eq 'Everyone') { "${everyoneName}: Full Control; permissions are controlled by NTFS" } else { "${adminsName}: Full Control, ${domainComputersName}: Change; NTFS restricts each folder" }
    if (-not (Get-SmbShare -Name $ShareName -ErrorAction SilentlyContinue)) {
        New-SmbShare -Name $ShareName -Path $ShareRoot -FullAccess @($wanted.Keys | Where-Object { $wanted[$_] -eq 'Full' }) -ChangeAccess @($wanted.Keys | Where-Object { $wanted[$_] -eq 'Change' }) | Out-Null
        Write-Ok "Share created: $ShareUnc ($modeText)"
    }
    else {
        # Existing share: bring the permissions to the desired state (idempotent)
        $changed = $false
        foreach ($acc in @(Get-SmbShareAccess -Name $ShareName)) {
            $key = @($wanted.Keys | Where-Object { $_ -ieq $acc.AccountName }) | Select-Object -First 1
            if (-not $key -or $wanted[$key] -ne [string]$acc.AccessRight -or [string]$acc.AccessControlType -ne 'Allow') {
                Revoke-SmbShareAccess -Name $ShareName -AccountName $acc.AccountName -Force | Out-Null; $changed = $true
            }
        }
        $present = @(Get-SmbShareAccess -Name $ShareName | Where-Object { [string]$_.AccessControlType -eq 'Allow' })
        foreach ($key in $wanted.Keys) {
            if (-not @($present | Where-Object { $_.AccountName -ieq $key -and [string]$_.AccessRight -eq $wanted[$key] })) {
                Grant-SmbShareAccess -Name $ShareName -AccountName $key -AccessRight $wanted[$key] -Force | Out-Null; $changed = $true
            }
        }
        if ($changed) { Write-Ok "Share '$ShareName' exists; permissions adjusted ($modeText)" }
        else          { Write-Info "Share '$ShareName' already exists - permissions unchanged ($modeText)." }
    }
}

function Invoke-ShareRemove {
    Write-Step "Remove share: $ShareName"
    if (Get-SmbShare -Name $ShareName -ErrorAction SilentlyContinue) {
        Remove-SmbShare -Name $ShareName -Force
        Write-Ok "Share '$ShareName' removed."
    }
    else { Write-Info "Share '$ShareName' does not exist." }

    if ($RemoveData) {
        $logFile = Join-Path (Join-Path $ShareRoot $LogFolderName) $LogFileName
        if (Test-Path $logFile) {
            New-Item -ItemType Directory -Path $LogArchiveDir -Force | Out-Null
            $archive = Join-Path $LogArchiveDir ('{0}_{1:yyyyMMdd-HHmmss}.csv' -f [IO.Path]::GetFileNameWithoutExtension($LogFileName), (Get-Date))
            Copy-Item -Path $logFile -Destination $archive -Force
            Write-Ok "Log file archived: $archive"
        }
        if (Test-Path $ShareRoot) {
            Remove-Item -Path $ShareRoot -Recurse -Force
            Write-Ok "Folder deleted: $ShareRoot"
        }
    }
    else { Write-Info "Folders and logs are kept under $ShareRoot (to delete them: -RemoveData)." }
}

# ===========================================================================================
#  DELEGATION
# ===========================================================================================
function Get-DelegationRules {
    $schemaNC = (Get-ADRootDSE -Server $script:pdc).schemaNamingContext
    function Get-SchemaGuid {
        param([string]$LdapName, [ValidateSet('attributeSchema', 'classSchema')][string]$SchemaClass)
        $o = Get-ADObject -Server $script:pdc -SearchBase $schemaNC `
                -Filter "lDAPDisplayName -eq '$LdapName' -and objectClass -eq '$SchemaClass'" -Properties schemaIDGUID
        if (-not $o) { throw "Schema object '$LdapName' ($SchemaClass) not found." }
        New-Object System.Guid (, [byte[]]$o.schemaIDGUID)
    }
    $computerClassGuid = Get-SchemaGuid -LdapName 'computer' -SchemaClass 'classSchema'

    $definitions = @(
        @{ Label = 'Write: cn';              Rights = 'WriteProperty'; Guid = (Get-SchemaGuid 'cn'             'attributeSchema') }
        @{ Label = 'Write: name';              Rights = 'WriteProperty'; Guid = (Get-SchemaGuid 'name'           'attributeSchema') }
        @{ Label = 'Write: sAMAccountName';    Rights = 'WriteProperty'; Guid = (Get-SchemaGuid 'sAMAccountName' 'attributeSchema') }
        @{ Label = 'Write: displayName';       Rights = 'WriteProperty'; Guid = (Get-SchemaGuid 'displayName'    'attributeSchema') }
        # Validated writes (Rights = Self); fixed GUIDs, identical in every AD
        @{ Label = 'Validated write: DNS host name';          Rights = 'Self'; Guid = [guid]'72e39547-7b18-11d1-adef-00c04fd8d5cd' }
        @{ Label = 'Validated write: service principal name'; Rights = 'Self'; Guid = [guid]'f3a64788-5306-11d1-a9c5-0000f80367c1' }
        # After the rename Windows resets the computer account password (the Kerberos keys depend on the name)
        @{ Label = 'Reset password';                          Rights = 'ExtendedRight';  Guid = [guid]'00299570-246d-11d0-a768-00aa006e0529' }
        @{ Label = 'Write: Account Restrictions';            Rights = 'WriteProperty';  Guid = [guid]'4c164200-20c0-11d0-a768-00aa006e0529' }
    )
    $selfSid = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-10')   # NT AUTHORITY\SELF
    $rules = foreach ($d in $definitions) {
        New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
            $selfSid,
            [System.DirectoryServices.ActiveDirectoryRights]$d.Rights,
            [System.Security.AccessControl.AccessControlType]::Allow,
            $d.Guid,
            [System.DirectoryServices.ActiveDirectorySecurityInheritance]::Descendents,   # descendant objects only ...
            $computerClassGuid)                                                          # ... and only computer objects
    }
    [pscustomobject]@{ Rules = @($rules); Definitions = $definitions; ComputerGuid = $computerClassGuid }
}

function Set-Delegation {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Helper function: the prompt (ShouldProcess) happens in the main flow before the call.')]
    param([ValidateSet('Grant', 'Revoke')][string]$Mode)
    $verb = if ($Mode -eq 'Grant') { 'set' } else { 'remove' }
    Write-Step ("Delegation ({0}): SELF on computer objects, {1} OU(s)" -f $verb, $DelegationOus.Count)
    Initialize-AdContext

    $del = Get-DelegationRules
    $failed = @()
    $used   = @()

    foreach ($ouDn in $DelegationOus) {
        Write-Host "   --- $ouDn" -ForegroundColor Cyan
        # Look up the OU in AD. If it is missing, (interactively) ask for another OU; empty input aborts the run.
        # With -Force or without a console there is no prompt: the OU is skipped and reported at the end.
        $target = $null
        $reason = ''
        try { $target = Get-ADObject -Server $script:pdc -Identity $ouDn } catch { $reason = $_.Exception.Message }
        while (-not $target) {
            Write-Warning "OU '$ouDn' was not found in AD. ($reason)"
            if ($Force -or -not [Environment]::UserInteractive) { break }
            $answer = Read-Host "Enter a different OU (distinguished name, domain: $($script:domain.DistinguishedName)) or press Enter to abort"
            if ([string]::IsNullOrWhiteSpace($answer)) { throw 'Aborted: no valid OU given. Nothing else was changed.' }
            $ouDn = $answer.Trim()
            Write-Host "   --- $ouDn" -ForegroundColor Cyan
            try { $target = Get-ADObject -Server $script:pdc -Identity $ouDn; $reason = '' } catch { $reason = $_.Exception.Message }
        }
        if (-not $target) { $failed += $ouDn; continue }
        $used += $ouDn

        $path = "AD:$ouDn"
        $acl  = Get-Acl -Path $path

        New-Item -ItemType Directory -Path $AclBackupDir -Force | Out-Null
        $safeName = $target.Name -replace '[^\w\- ]', '_'
        $backup = Join-Path $AclBackupDir ('ACL_{0}_{1:yyyyMMdd-HHmmss}.sddl' -f $safeName, (Get-Date))
        $acl.Sddl | Set-Content -Path $backup -Encoding ASCII
        Write-Info "ACL backup: $backup"

        foreach ($r in $del.Rules) {
            if ($Mode -eq 'Revoke') { [void]$acl.RemoveAccessRule($r) } else { $acl.AddAccessRule($r) }
        }
        Set-Acl -Path $path -AclObject $acl
        Write-Ok ("Delegation {0}." -f $(if ($Mode -eq 'Grant') { 'set' } else { 'removed' }))

        $selfAces = @((Get-Acl -Path $path).Access | Where-Object {
            (ConvertTo-SidString $_.IdentityReference) -eq 'S-1-5-10' -and
            $_.AccessControlType -eq 'Allow' -and
            $_.InheritedObjectType -eq $del.ComputerGuid })

        # Check: are all expected rights present (Grant) or all removed (Revoke)?
        $found = @($del.Definitions | Where-Object { $d = $_; @($selfAces | Where-Object { $_.ObjectType -eq $d.Guid }).Count -gt 0 }).Count
        if     ($Mode -eq 'Grant'  -and $found -lt $del.Definitions.Count) { Write-Warning "Only $found of $($del.Definitions.Count) rights found - check the delegation." }
        elseif ($Mode -eq 'Grant')                                           { Write-Ok "Check: all $found rights are present." }
        elseif ($Mode -eq 'Revoke'  -and $found -gt 0)                       { Write-Warning "$found rights are still present - check the removal." }
        else                                                                 { Write-Ok 'Check: all rights are removed.' }
    }
    # Carry the OUs actually used (including an interactively entered one) over into the test configuration
    $script:DelegationOus = @($used) + @($failed)
    if ($failed.Count) { throw "The following OUs were not found: $($failed -join '; ')" }
}

# ===========================================================================================
#  GPO
# ===========================================================================================
function Register-GpoExtension {
    # Adds the CSE pairs of the Preferences to gPCMachineExtensionNames and increments the version number
    # (AD and GPT.INI) so that the clients process the Preferences.
    param($Gpo, [string]$Sysvol, [string[]]$Pairs)
    $gpc = Get-ADObject -Identity $Gpo.Path -Server $script:pdc -Properties versionNumber, gPCMachineExtensionNames
    $existing = @()
    if ($gpc.gPCMachineExtensionNames) {
        $existing = [regex]::Matches($gpc.gPCMachineExtensionNames, '\[[^\]]+\]') | ForEach-Object { $_.Value }
    }
    $extString = (($existing + $Pairs) | Sort-Object -Unique) -join ''
    $newVer    = [int]$gpc.versionNumber + 1      # lower 16 bits = computer configuration
    Set-ADObject -Identity $Gpo.Path -Server $script:pdc -Replace @{ gPCMachineExtensionNames = $extString; versionNumber = $newVer }

    $gptIni = Join-Path $Sysvol 'GPT.INI'
    $lines  = if (Test-Path $gptIni) { @(Get-Content -Path $gptIni) } else { @('[General]') }
    if ($lines -match '^Version=') { $lines = $lines -replace '^Version=\d+', "Version=$newVer" }
    else                           { $lines += "Version=$newVer" }
    Set-Content -Path $gptIni -Value $lines -Encoding ASCII
    Write-Ok "CSE registered, version number set: $newVer"
}

function Set-GpoSecurityFilter {
    # Security filtering (optional): apply only for $SecurityFilterGroup
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Helper function: the prompt (ShouldProcess) happens in the main flow before the call.')]
    param($Gpo)
    if (-not $SecurityFilterGroup) { return }
    $authUsers = (New-Object Security.Principal.SecurityIdentifier('S-1-5-11')).Translate([Security.Principal.NTAccount]).Value.Split('\')[-1]
    Set-GPPermission -Guid $Gpo.Id -Server $script:pdc -TargetName $authUsers -TargetType Group -PermissionLevel GpoRead -Replace | Out-Null
    Set-GPPermission -Guid $Gpo.Id -Server $script:pdc -TargetName $SecurityFilterGroup -TargetType Group -PermissionLevel GpoApply | Out-Null
    Write-Ok "Security filtering: apply only for '$SecurityFilterGroup'."
}

function Set-GpoLink {
    # Link to $LinkTargetOU, initially DISABLED
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Helper function: the prompt (ShouldProcess) happens in the main flow before the call.')]
    param($Gpo, [string]$Name)
    if ($LinkTargetOU) {
        New-GPLink -Guid $Gpo.Id -Target $LinkTargetOU -LinkEnabled No -Server $script:pdc | Out-Null
        Write-Warning "GPO linked to '$LinkTargetOU' - link is DISABLED. To enable: Set-GPLink -Name '$Name' -Target '$LinkTargetOU' -LinkEnabled Yes"
    }
    else { Write-Info "Not linked. To link: New-GPLink -Name '$Name' -Target '<OU-DN>' -LinkEnabled Yes" }
}

function Invoke-GpoSetup {
    Write-Step "Create GPO: $GpoName"
    Import-Module GroupPolicy -ErrorAction Stop
    Initialize-AdContext

    if (Get-GPO -Name $GpoName -Server $script:pdc -ErrorAction SilentlyContinue) {
        Write-Warning "A GPO '$GpoName' already exists - skipped. To recreate it, first run: -Action Remove -Component Gpo"
        return
    }
    if (-not (Test-Path $SourceShareFolder)) {
        Write-Warning "Source folder '$SourceShareFolder' is not reachable from here (share already created?). The GPO is created anyway."
    }

    if ($TaskItemAction -notin @('C', 'U', 'R')) { throw "`$TaskItemAction '$TaskItemAction' is invalid (C, U or R)." }
    $gpo = New-GPO -Name $GpoName -Server $script:pdc -Comment "Copies $ScriptName from the share and creates the local scheduled task."
    $gpo.GpoStatus = 'UserSettingsDisabled'
    $gpoGuid = $gpo.Id.ToString('B').ToUpper()
    $sysvol  = "\\$($script:pdc)\SYSVOL\$($script:dnsRoot)\Policies\$gpoGuid"
    Write-Ok "GPO created: $GpoName $gpoGuid"

    # Item-level targeting: apply the item only if the marker key does NOT exist
    # (not="1" + KEYEXISTS). This keeps the GPO from recreating script and task after the cleanup.
    $iltXml = ''
    if ($CleanupAfterSuccess) {
        $iltXml = '<Filters><FilterRegistry bool="AND" not="1" hive="HKEY_LOCAL_MACHINE" key="{0}" type="KEYEXISTS" valueName="" valueType="REG_SZ" valueData="" min="0.0.0.0" max="0.0.0.0" gte="0" lte="0" /></Filters>' -f (ConvertTo-XmlText $MarkerRegistryKey)
    }

    # ---- GPP "Files": copy the script from the share
    # Action R (Replace): deletes the existing copy and creates it anew. With U (Update), overwriting an existing file on the client
    # failed with error 0x50 "file exists" (event 4117, Group Policy Files), and the client kept the old script version.
    $now        = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $fromPath   = Join-Path $SourceShareFolder $ScriptName
    $targetPath = Join-Path $LocalFolder $ScriptName

$filesXml = @"
<?xml version="1.0" encoding="utf-8"?>
<Files clsid="{215B2E53-57CE-475c-80FE-9EEC14635851}">
  <File clsid="{50BE44C8-567A-4ed1-B1D0-9234FE1F38AF}" name="$(ConvertTo-XmlText $ScriptName)" status="$(ConvertTo-XmlText $ScriptName)" image="1" changed="$now" uid="$(New-GppUid)">
    <Properties action="R" fromPath="$(ConvertTo-XmlText $fromPath)" targetPath="$(ConvertTo-XmlText $targetPath)" readOnly="0" archive="1" hidden="0" suppress="0" />
    $iltXml
  </File>
</Files>
"@
    Write-Utf8File -Path (Join-Path $sysvol 'Machine\Preferences\Files\Files.xml') -Content $filesXml

    # ---- GPP "Scheduled Task"
    $ruleArgs = @()
    if ($NameTemplate) { $ruleArgs += ('-NameTemplate "{0}"' -f $NameTemplate) }
    else {
        if ($Prefix) { $ruleArgs += ('-Prefix "{0}"' -f $Prefix) }
        if ($Suffix) { $ruleArgs += ('-Suffix "{0}"' -f $Suffix) }
    }
    if ($NameTemplate -match '\{SERIAL(:-?\d+)?\}') {
        $ruleArgs += ('-OnSerialProblem {0}' -f $OnSerialProblem)
        $ruleArgs += ('-FutureIdLength {0}' -f $FutureIdLength)
    }
    $ruleText = if ($NameTemplate) { $NameTemplate } else { '{0}{{Name}}{1}' -f $Prefix, $Suffix }
    $argParts = @('-NoProfile -ExecutionPolicy Bypass', ('-File "{0}"' -f $targetPath)) + $ruleArgs +
                @(('-OnTooLong {0}' -f $OnTooLong), ('-CentralLogPath "{0}"' -f $CentralLogPath), ('-LocalDir "{0}"' -f $LocalFolder))
    if ($Reboot) { $argParts += '-Reboot'; $argParts += ('-RebootDelaySeconds {0}' -f $RebootDelaySeconds) }
    if ($CleanupAfterSuccess) { $argParts += '-Cleanup'; $argParts += ('-TaskName "{0}"' -f $TaskName) }
    $taskArgs = ConvertTo-XmlText ($argParts -join ' ')

    # Actions: optionally lock down the local folder first (SIDs are language-independent:
    # S-1-5-18 = SYSTEM, S-1-5-32-544 = Administrators, S-1-5-32-545 = Users), then start the script.
    $actionsXml = ''
    if ($HardenLocalFolder) {
        $icaclsOwner = ConvertTo-XmlText ('"{0}" /setowner *S-1-5-32-544' -f $LocalFolder)
        $icaclsAcl   = ConvertTo-XmlText ('"{0}" /inheritance:r /grant:r *S-1-5-18:(OI)(CI)F *S-1-5-32-544:(OI)(CI)F *S-1-5-32-545:(OI)(CI)RX' -f $LocalFolder)
        $actionsXml += "<Exec><Command>icacls.exe</Command><Arguments>$icaclsOwner</Arguments></Exec>"
        $actionsXml += "<Exec><Command>icacls.exe</Command><Arguments>$icaclsAcl</Arguments></Exec>"
    }
    $actionsXml += "<Exec><Command>powershell.exe</Command><Arguments>$taskArgs</Arguments></Exec>"

    $triggers = "<BootTrigger><Enabled>true</Enabled><Delay>$BootDelay</Delay></BootTrigger>"
    # Daily trigger, optionally with repetition. Structure and element order as in a file written by the GPMC
    # (StartBoundary, Enabled, ScheduleByDay, Repetition last).
    # Registration trigger without <Delay>: with a delay the GPMC report fails (Test-GpoReport.ps1 -Candidates, K1 to K3 and K5 versus K4).
    if ($RegistrationTrigger) { $triggers += '<RegistrationTrigger><Enabled>true</Enabled></RegistrationTrigger>' }
    $dailyAt = if ($DailyTriggerTime) { $DailyTriggerTime } elseif ($RepeatInterval) { '00:00' } else { '' }
    if ($dailyAt) {
        $start  = '{0:yyyy-MM-dd}T{1}:00' -f (Get-Date), $dailyAt
        $repeat = if ($RepeatInterval) { "<Repetition><Interval>$RepeatInterval</Interval><Duration>P1D</Duration><StopAtDurationEnd>false</StopAtDurationEnd></Repetition>" } else { '' }
        $triggers += "<CalendarTrigger><StartBoundary>$start</StartBoundary><Enabled>true</Enabled><ScheduleByDay><DaysInterval>1</DaysInterval></ScheduleByDay>$repeat</CalendarTrigger>"
    }

    $taskNameXml = ConvertTo-XmlText $TaskName
    $taskImage   = @{ C = 0; R = 1; U = 2 }[$TaskItemAction]      # icon number of the GPP action (C=0, R=1, U=2)
$tasksXml = @"
<?xml version="1.0" encoding="utf-8"?>
<ScheduledTasks clsid="{CC63F200-7309-4ba0-B154-A71CD118DBCC}">
  <TaskV2 clsid="{D8896631-B747-47a7-84A6-C155337F3BC8}" name="$taskNameXml" image="$taskImage" changed="$now" uid="$(New-GppUid)">
    <Properties action="$TaskItemAction" name="$taskNameXml" runAs="$(ConvertTo-XmlText $TaskRunAs)" logonType="S4U">
      <Task version="1.2">
        <RegistrationInfo>
          <Author>GPO $(ConvertTo-XmlText $GpoName)</Author>
          <Description>Renames the host name according to the template '$(ConvertTo-XmlText $ruleText)' (idempotent). Log: $(ConvertTo-XmlText $CentralLogPath)</Description>
        </RegistrationInfo>
        <Principals>
          <Principal id="Author">
            <UserId>$(ConvertTo-XmlText $TaskUserId)</UserId>
            <LogonType>S4U</LogonType>
            <RunLevel>HighestAvailable</RunLevel>
          </Principal>
        </Principals>
        <Settings>
          <IdleSettings>
            <Duration>PT10M</Duration>
            <WaitTimeout>PT1H</WaitTimeout>
            <StopOnIdleEnd>true</StopOnIdleEnd>
            <RestartOnIdle>false</RestartOnIdle>
          </IdleSettings>
          <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
          <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
          <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
          <AllowHardTerminate>true</AllowHardTerminate>
          <StartWhenAvailable>true</StartWhenAvailable>
          <RunOnlyIfNetworkAvailable>true</RunOnlyIfNetworkAvailable>
          <AllowStartOnDemand>true</AllowStartOnDemand>
          <Enabled>true</Enabled>
          <Hidden>false</Hidden>
          <ExecutionTimeLimit>PT1H</ExecutionTimeLimit>
          <Priority>7</Priority>
        </Settings>
        <Triggers>$triggers</Triggers>
        <Actions Context="Author">$actionsXml</Actions>
      </Task>
    </Properties>
    $iltXml
  </TaskV2>
</ScheduledTasks>
"@
    Write-Utf8File -Path (Join-Path $sysvol 'Machine\Preferences\ScheduledTasks\ScheduledTasks.xml') -Content $tasksXml
    Write-Ok 'GPP files (Files, Scheduled Tasks) written to SYSVOL.'

    # ---- CSE registration + version number (so that clients process the Preferences)
    Register-GpoExtension -Gpo $gpo -Sysvol $sysvol -Pairs @(
        '[{7150F9BF-48AD-4DA4-A49C-29EF4A8369BA}{3A0DBA37-F8B2-4356-83DE-3E90BD5C261F}]',   # Preferences: Files
        '[{AADCED64-746C-4633-A97C-D61349046527}{CAB54552-DEEA-4691-817E-ED4A4D1AFC72}]'    # Preferences: Scheduled Tasks
    )

    Set-GpoSecurityFilter -Gpo $gpo
    Set-GpoLink -Gpo $gpo -Name $GpoName

    # ---- Self-test
    try {
        $report = Get-GPOReport -Guid $gpo.Id -ReportType Xml -Server $script:pdc
        $okFile = $report -match [regex]::Escape($ScriptName)
        $okTask = $report -match [regex]::Escape($TaskName)
        if ($okFile -and $okTask) { Write-Ok 'Self-test OK: the Files and Scheduled Task preferences are recognized by the GPO.' }
        else { Write-Warning "Self-test: preferences not fully found in the GPO report (Files: $okFile, Task: $okTask). Check the GPO in the GPMC." }
    }
    catch { Write-Warning "Selbsttest nicht möglich: $($_.Exception.Message)" }
}

function Invoke-CleanupGpoSetup {
    Write-Step "Create cleanup GPO: $CleanupGpoName"
    Import-Module GroupPolicy -ErrorAction Stop
    Initialize-AdContext

    if (Get-GPO -Name $CleanupGpoName -Server $script:pdc -ErrorAction SilentlyContinue) {
        Write-Warning "A GPO '$CleanupGpoName' already exists - skipped. To recreate it, first run: -Action Remove -Component CleanupGpo"
        return
    }

    # Safeguard: as long as the main GPO exists, it recreates script and task on already renamed devices as soon as the marker
    # is deleted; with templates using {Name} and {Serial} the devices would even be renamed again without a state key.
    if (Get-GPO -Name $GpoName -Server $script:pdc -ErrorAction SilentlyContinue) {
        $msg = "The main GPO '$GpoName' still exists. The cleanup GPO belongs at the very end, after all renames are finished and after the main GPO has been removed (-Action Remove -Component Gpo)."
        if (-not $Force) { throw $msg + ' With -Force it is created anyway.' }
        Write-Warning ($msg + ' Created anyway because of -Force.')
    }
    $keys = @($CleanupRegistryKeys | Where-Object { $_ -and $_.Trim() } | ForEach-Object { $_.Trim() })
    if (-not $keys) { throw '$CleanupRegistryKeys is empty: there would be nothing to delete.' }
    # Safeguard against typos: this GPO deletes entire keys including their contents on all clients. Only simple HKLM paths are allowed
    # (without hive prefix) whose last part begins with 'HostRename'; this way no branch such as SOFTWARE or SOFTWARE\Microsoft can be deleted.
    $badKeys = @($keys | Where-Object { $_ -notmatch '^[A-Za-z0-9_]+(\\[A-Za-z0-9_.-]+)*\\HostRename[A-Za-z0-9_.-]*$' -or $_ -match '^(HKLM|HKCU|HKCR|HKU|HKCC|HKEY_\w+)\\' })
    if ($badKeys) { throw "Invalid entry in `$CleanupRegistryKeys: $($badKeys -join ', '). Only HKLM keys without a hive prefix whose last part begins with 'HostRename' are allowed, e.g. 'SOFTWARE\HostRename'." }

    $gpo = New-GPO -Name $CleanupGpoName -Server $script:pdc -Comment 'Deletes the HostRename registry keys on the clients. Link only after all renames are finished and the main GPO has been removed.'
    $gpo.GpoStatus = 'UserSettingsDisabled'
    $gpoGuid = $gpo.Id.ToString('B').ToUpper()
    $sysvol  = "\\$($script:pdc)\SYSVOL\$($script:dnsRoot)\Policies\$gpoGuid"
    Write-Ok "GPO created: $CleanupGpoName $gpoGuid"

    # ---- GPP "Registry": one item per key with action D (Delete); without a value name the whole key is deleted
    $now   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $items = foreach ($k in $keys) {
        $leaf = ConvertTo-XmlText (($k.TrimEnd('\') -split '\\')[-1])
        $keyX = ConvertTo-XmlText $k
@"
  <Registry clsid="{9CD4B2F4-923D-47f5-A062-E897DD1DAD50}" name="$leaf" status="$leaf" image="3" changed="$now" uid="$(New-GppUid)">
    <Properties action="D" displayDecimal="0" default="0" hive="HKEY_LOCAL_MACHINE" key="$keyX" name="" type="REG_SZ" value="" />
  </Registry>
"@
    }
$regXml = @"
<?xml version="1.0" encoding="utf-8"?>
<RegistrySettings clsid="{A3CCFC41-DFDB-43a5-8D26-0FE8B954DA51}">
$($items -join "`n")
</RegistrySettings>
"@
    Write-Utf8File -Path (Join-Path $sysvol 'Machine\Preferences\Registry\Registry.xml') -Content $regXml
    Write-Ok "GPP file (Registry) written to SYSVOL: deletes $($keys.Count) key(s) under HKLM."

    Register-GpoExtension -Gpo $gpo -Sysvol $sysvol -Pairs @(
        '[{B087BE9D-ED37-454F-AF9C-04291E351182}{BEE07A6A-EC9F-4659-B8C9-0B1937907C83}]'    # Preferences: Registry
    )
    Set-GpoSecurityFilter -Gpo $gpo
    Set-GpoLink -Gpo $gpo -Name $CleanupGpoName
    Write-Info 'Enable or link only when all devices have been renamed and the main GPO has been removed.'

    # ---- Selbsttest
    try {
        $report  = Get-GPOReport -Guid $gpo.Id -ReportType Xml -Server $script:pdc
        $missing = @($keys | Where-Object { $report -notmatch [regex]::Escape($_) })
        if (-not $missing) { Write-Ok 'Self-test OK: the Registry preference is recognized by the GPO.' }
        else { Write-Warning "Self-test: keys not found in the GPO report: $($missing -join ', '). Check the GPO in the GPMC." }
    }
    catch { Write-Warning "Self-test not possible: $($_.Exception.Message)" }
}

function Remove-HostRenameGpo {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Helper function: the prompt (ShouldProcess) happens in the main flow before the call.')]
    param([string]$Name)
    Write-Step "Remove GPO: $Name"
    Import-Module GroupPolicy -ErrorAction Stop
    Initialize-AdContext

    $gpo = Get-GPO -Name $Name -Server $script:pdc -ErrorAction SilentlyContinue
    if (-not $gpo) { Write-Info "GPO '$Name' does not exist."; return }

    # Remove links in the domain (domain root and all OUs); site links are not covered
    $guid = $gpo.Id.ToString()
    $containers = @(Get-ADObject -Server $script:pdc -SearchBase $script:domain.DistinguishedName -SearchScope Subtree `
                        -LDAPFilter "(gPLink=*$guid*)" -Properties gPLink)
    foreach ($c in $containers) {
        Remove-GPLink -Guid $gpo.Id -Target $c.DistinguishedName -Server $script:pdc | Out-Null
        Write-Ok "Link removed: $($c.DistinguishedName)"
    }
    Remove-GPO -Guid $gpo.Id -Server $script:pdc
    Write-Ok "GPO deleted: $Name ($guid)"
}

function Invoke-GpoRemove        { Remove-HostRenameGpo -Name $GpoName }
function Invoke-CleanupGpoRemove { Remove-HostRenameGpo -Name $CleanupGpoName }

# ===========================================================================================
#  Check the renaming rule
# ===========================================================================================
function Test-NameRule {
    # Checks the format of the rule and runs it through with example values. For this, the function
    # Resolve-NameTemplate is loaded from Invoke-HostRename.ps1 so that Prepare and client use the same logic.
    Write-Step 'Check the renaming rule'
    if (-not $NameTemplate -and -not $Prefix -and -not $Suffix) { throw 'Renaming rule missing: set $NameTemplate or $Prefix/$Suffix.' }
    if ($Prefix -notmatch '^$|^[A-Za-z0-9][A-Za-z0-9-]{0,9}$')  { throw "`$Prefix '$Prefix' is invalid (max. 10 characters from A-Z, 0-9 and -; must not start with -)." }
    if ($Suffix -notmatch '^$|^[A-Za-z0-9-]{1,10}$')            { throw "`$Suffix '$Suffix' is invalid (max. 10 characters from A-Z, 0-9 and -)." }
    if ($NameTemplate -notmatch '^$|^[A-Za-z0-9_{}:-]+$')       { throw "`$NameTemplate '$NameTemplate' contains invalid characters (allowed: A-Z, 0-9, _, -, {Name}, {Serial})." }
    if ($NameTemplate -and ([regex]::Replace($NameTemplate, '\{(Name|Serial)(:-?\d+)?\}', '', 'IgnoreCase') -match '[{}]')) {
        throw "Unknown placeholder in `$NameTemplate '$NameTemplate' (allowed: {Name}, {Serial}, each optionally with :N or :-N)."
    }

    if ($OnSerialProblem -notin @('GenerateId', 'Skip')) { throw "`$OnSerialProblem '$OnSerialProblem' is invalid (GenerateId or Skip)." }
    if ($FutureIdLength -lt 4 -or $FutureIdLength -gt 12) { throw "`$FutureIdLength $FutureIdLength is invalid (4 to 12)." }

    $tpl = if ($NameTemplate) { $NameTemplate } else { '{0}{{Name}}{1}' -f $Prefix, $Suffix }
    $tpl = $tpl.ToUpper()
    $usesSerial = $tpl -match '\{SERIAL(:-?\d+)?\}'
    Write-Info "Template: $tpl (if the name is too long: $OnTooLong)"
    if ($usesSerial) { Write-Info "Serial number unusable or duplicate: $OnSerialProblem$(if ($OnSerialProblem -eq 'GenerateId') { " (ID with $FutureIdLength characters)" })" }

    $invoke = if ($PSScriptRoot) { Join-Path $PSScriptRoot $ScriptName } else { $null }
    if (-not $invoke -or -not (Test-Path $invoke)) { Write-Warning "'$ScriptName' not found next to this script - example calculation skipped."; return }
    $tk = $null; $er = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($invoke, [ref]$tk, [ref]$er)
    $fns = @($ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -in @('Resolve-NameTemplate', 'New-FutureId') }, $true))
    if ($fns.Count -lt 2) { Write-Warning "Resolve-NameTemplate/New-FutureId not found in '$ScriptName' - example calculation skipped."; return }
    . ([scriptblock]::Create((($fns | ForEach-Object { $_.Extent.Text }) -join "`r`n")))

    $cases = @(
        @{ Label = 'Example';      Name = 'PC349219';        Serial = 'PF2ABCDE' },
        @{ Label = 'Longest case'; Name = 'DESKTOP-AB12CD3'; Serial = 'ABCDEFGHIJ0123456789' }
    )
    foreach ($c in $cases) {
        $r = Resolve-NameTemplate -Template $tpl -CurrentName $c.Name -Serial $c.Serial -MaxLength 15 -OnTooLong $OnTooLong
        if ($r.Ok) {
            Write-Ok ('{0}: name {1}, serial number {2} -> {3}{4}' -f $c.Label, $c.Name, $c.Serial, $r.Name, $(if ($r.Truncated) { '  (truncated)' } else { '' }))
        }
        elseif ($r.Code -eq 'TOO_LONG') {
            Write-Warning ('{0}: {1}' -f $c.Label, $r.Error)
        }
        else { throw "The renaming rule '$tpl' is not usable ($($c.Label)): $($r.Error)" }
    }

    if ($usesSerial -and $OnSerialProblem -eq 'GenerateId') {
        $id = New-FutureId -Seed 'BEISPIEL-MACHINEGUID' -Length $FutureIdLength -Attempt 0
        $r  = Resolve-NameTemplate -Template $tpl -CurrentName 'PC349219' -Serial $id -MaxLength 15 -OnTooLong $OnTooLong
        if (-not $r.Ok) { throw "With a future ID ($FutureIdLength characters) the template '$tpl' does not produce a valid name: $($r.Error)" }
        Write-Ok ("Without a usable serial number (future ID): name PC349219 -> {0}{1}" -f $r.Name, $(if ($r.Truncated) { '  (truncated)' } else { '' }))
    }
    elseif ($usesSerial) { Write-Info 'Without a usable serial number the device is skipped (exit code 5).' }
}

function Test-LocalFolder {
    # Warning if the local target folder might be writable by standard users and is not hardened
    if (-not $HardenLocalFolder -and $LocalFolder -match '(?i)\\(ProgramData|Users|Temp)(\\|$)') {
        Write-Warning "`$LocalFolder '$LocalFolder' is in a location writable by users. Either use a folder under 'C:\Program Files' or set `$HardenLocalFolder = `$true."
    }
    elseif ($HardenLocalFolder -and $LocalFolder -match '(?i)\\Program Files') {
        Write-Info "Note: `$HardenLocalFolder is not required under 'Program Files' (the default ACL protects the folder)."
    }
}

# ===========================================================================================
#  Pester configuration
# ===========================================================================================
function Write-ChecksConfig {
    Write-Step "Configuration for the Pester tests: $ChecksConfigPath"
    $bool = { param($b) if ($b) { '$true' } else { '$false' } }
    # Pattern for the name after the rename (placeholders -> *), e.g. 'DE{Serial}' -> 'DE*'
    # OUs for the tests: with -OuDN (single OU added later) the remaining ones from $ClientOuDN stay in the check;
    # an interactively corrected OU is already in $DelegationOus.
    $configOus = if ($OuDN) { @($ClientOuDN) + @($DelegationOus) } else { @($DelegationOus) }
    $configOus = @($configOus | Where-Object { $_ } | Select-Object -Unique)
    $nameLike = if ($NameTemplate) { [regex]::Replace($NameTemplate, '\{(Name|Serial)(:-?\d+)?\}', '*', 'IgnoreCase').ToUpper() }
                else               { ($Prefix + '*' + $Suffix).ToUpper() }
$content = @"
@{
    # Generated by Prepare-HostRename.ps1 on $(Get-Date -Format 'yyyy-MM-dd HH:mm') - after changes run the script again with -Action Setup or adjust here

    GpoName           = $(ConvertTo-PsLiteral $GpoName)
    ClientOuDN        = @($((@($configOus) | ForEach-Object { ConvertTo-PsLiteral $_ }) -join ', '))
    SourceShareFolder = $(ConvertTo-PsLiteral $SourceShareFolder)
    ScriptName        = $(ConvertTo-PsLiteral $ScriptName)
    LocalFolder       = $(ConvertTo-PsLiteral $LocalFolder)
    CentralLogPath    = $(ConvertTo-PsLiteral $CentralLogPath)
    NameTemplate      = $(ConvertTo-PsLiteral $NameTemplate)
    Prefix            = $(ConvertTo-PsLiteral $Prefix)
    Suffix            = $(ConvertTo-PsLiteral $Suffix)
    NameLike          = $(ConvertTo-PsLiteral $nameLike)      # Pattern for the name after the rename
    OnTooLong         = $(ConvertTo-PsLiteral $OnTooLong)
    OnSerialProblem   = $(ConvertTo-PsLiteral $OnSerialProblem)
    RegistrationTrigger = $(& $bool $RegistrationTrigger)
    RepeatInterval    = $(ConvertTo-PsLiteral $RepeatInterval)
    FutureIdLength    = $FutureIdLength
    TaskName          = $(ConvertTo-PsLiteral $TaskName)
    CleanupGpoName    = $(ConvertTo-PsLiteral $CleanupGpoName)
    CleanupRegKeys    = @($((@($CleanupRegistryKeys) | ForEach-Object { ConvertTo-PsLiteral $_ }) -join ', '))
    MarkerRegistryKey = $(ConvertTo-PsLiteral $MarkerRegistryKey)

    ExpectCleanup     = $(& $bool $CleanupAfterSuccess)
    ExpectHardening   = $(& $bool $HardenLocalFolder)
    PilotGroup        = $(ConvertTo-PsLiteral $SecurityFilterGroup)
}
"@
    [System.IO.File]::WriteAllText($ChecksConfigPath, $content, (New-Object System.Text.UTF8Encoding($true)))   # UTF-8 with BOM (5.1 and 7)
    Write-Ok 'written.'
}

# ===========================================================================================
#  Main flow
# ===========================================================================================
if (-not (Test-IsAdmin)) { throw 'Please start in a PowerShell with "Run as administrator" (UAC token filtering).' }

$components = @(@('Share', 'Delegation', 'Gpo', 'CleanupGpo') | Where-Object { $Component -contains $_ })
if ($Action -eq 'Setup' -and $components -contains 'Gpo' -and $components -contains 'CleanupGpo') {
    throw 'Do not create the main GPO and the cleanup GPO in one run: the cleanup GPO belongs at the very end, after all renames are finished and the main GPO has been removed.'
}
if ($Action -eq 'Remove') { [array]::Reverse($components) }

Write-Host "HostRename Preparation: $Action -> $($components -join ', ')" -ForegroundColor White
if ($Action -eq 'Setup' -and $components -contains 'Gpo') { Test-NameRule; Test-LocalFolder }     # also with -WhatIf (read-only)
# Share and GPO on different machines: $ShareServer must be the file server, not the machine on which the GPO is created
if ($Action -eq 'Setup' -and $components -contains 'Gpo' -and $components -notcontains 'Share' -and $ShareServer -ieq $env:COMPUTERNAME -and -not (Get-SmbShare -Name $ShareName -ErrorAction SilentlyContinue)) {
    Write-Warning "`$ShareServer is '$ShareServer', i.e. this computer, but there is no share '$ShareName' here. If the share is on a file server, change `$ShareServer to that server before the GPO is created."
}
if ($Action -eq 'Setup' -and $components -contains 'Gpo' -and $ShareServer -ne $env:COMPUTERNAME -and $components -contains 'Share') {
    Write-Warning "The share is created on this computer ($env:COMPUTERNAME), but the GPO points to '$ShareServer'. Check `$ShareServer."
}

if ($Action -eq 'Remove' -and -not $Force -and -not $WhatIfPreference) {
    Write-Host "`nTo be removed: $($components -join ', ')" -ForegroundColor Yellow
    if ($components -contains 'Share' -and $RemoveData) { Write-Host "  Share folder $ShareRoot will be DELETED (the log file is archived to $LogArchiveDir)." -ForegroundColor Yellow }
    if ((Read-Host 'Continue? (y/N)') -notmatch '^(j|ja|y|yes)$') { Write-Host 'Aborted.'; return }
}

foreach ($c in $components) {
    switch ($c) {
        'Share' {
            if ($Action -eq 'Setup') { if ($PSCmdlet.ShouldProcess("$ShareRoot / $ShareName", 'Create share')) { Invoke-ShareSetup } }
            else                     { if ($PSCmdlet.ShouldProcess($ShareName, 'Remove share'))              { Invoke-ShareRemove } }
        }
        'Delegation' {
            if (-not $DelegationOus) { throw 'No OU specified: fill $ClientOuDN or use -OuDN.' }
            if ($Action -eq 'Setup') { if ($PSCmdlet.ShouldProcess($DelegationOus -join '; ', 'Set delegation'))   { Set-Delegation -Mode Grant } }
            else                     { if ($PSCmdlet.ShouldProcess($DelegationOus -join '; ', 'Remove delegation')) { Set-Delegation -Mode Revoke } }
        }
        'Gpo' {
            if ($Action -eq 'Setup') { if ($PSCmdlet.ShouldProcess($GpoName, 'Create GPO'))    { Invoke-GpoSetup } }
            else                     { if ($PSCmdlet.ShouldProcess($GpoName, 'Remove GPO')) { Invoke-GpoRemove } }
        }
        'CleanupGpo' {
            if ($Action -eq 'Setup') { if ($PSCmdlet.ShouldProcess($CleanupGpoName, 'Create cleanup GPO'))    { Invoke-CleanupGpoSetup } }
            else                     { if ($PSCmdlet.ShouldProcess($CleanupGpoName, 'Remove cleanup GPO')) { Invoke-CleanupGpoRemove } }
        }
    }
}

if ($Action -eq 'Setup' -and $WriteChecksConfig -and -not $WhatIfPreference) { Write-ChecksConfig }

Write-Host "`nDone." -ForegroundColor White
