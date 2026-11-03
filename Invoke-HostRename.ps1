<#
.SYNOPSIS
    HostRename - client script: renames a domain-joined Windows device and its AD computer object.

.DESCRIPTION
    Runs on the client as a scheduled task (SYSTEM) and renames the computer with Rename-Computer, which also
    renames the AD computer object. The script is idempotent: it can run any number of times and renames each
    device only once. With -WhatIf it only shows the target name and changes nothing.

    NAME TEMPLATE
      {Name}          previous host name
      {Serial}        serial number (BIOS, otherwise system product, otherwise baseboard; A-Z and 0-9 only).
                      Manufacturer placeholders ("To Be Filled By O.E.M."), values shorter than 4 characters
                      and values consisting of a single repeated character are discarded.
      Length          {Serial:8} = first 8, {Serial:-8} = last 8 characters (likewise {Name:4}, {Name:-4})
      No template     -Prefix and -Suffix form "Prefix{Name}Suffix"
      Target name     at most 15 characters from A-Z, 0-9, _ and -; no - at the start or end; not digits only
      Too long        Only the placeholder values are shortened, the last one first; fixed characters stay (-OnTooLong)

    PROCEDURE
      1. Done?        If the name matches the template or the remembered target name
                      (HKLM:\SOFTWARE\HostRenameState), there is nothing to do; with -Cleanup the cleanup runs.
                      A different template triggers a new rename.
      2. Check central log: name resolution, port 445, write permission. The result is only written to the
                      local log (LOG_CHECK); the rename continues in any case.
      3. Determine serial number (only with {Serial}). If it is unusable or the target name is already taken
                      in AD, a future ID replaces the placeholder (-OnSerialProblem).
      4. Preliminary checks: domain membership, secure channel, write permissions on the device's own AD object
                      (allowedAttributesEffective), name collision in AD, DNS resolution (warning only).
      5. Build the target name and shorten it if necessary.
      6. Rename, verify in AD (warning only), remember state, optionally schedule a reboot (-Reboot).
      7. With -Cleanup: deliver log entries to the share, set the registry marker, remove task and script
                      and, once everything has arrived, the local log files together with the empty folder.
                      Until then the cleanup is deferred and made up for on the next run.

    FUTURE ID
      If the serial number is unusable or the target name is already taken in AD, a generated ID replaces the
      {Serial} placeholder (-OnSerialProblem GenerateId, default). It is short (-FutureIdLength, default
      8 characters from A-Z without I and O plus 2-9), is calculated stably from the MachineGuid and, on a
      collision, is recalculated with the next counter value (up to 5 attempts). With -OnSerialProblem Skip
      the device is skipped instead (exit code 5) or, on a collision, the run is aborted.

    LOGGING
      Every event is written to the central CSV log on the share (-CentralLogPath) and to the local log
      (-LocalDir). If the share is unreachable, the entries stay in pending.csv and are delivered on the
      next run; the reason is recorded in the local log as LOG_DELIVERY.

    REQUIREMENTS
      - Run as SYSTEM or with administrator rights in 64-bit PowerShell.
      - AD permissions: the computer account (SELF) needs write permissions on its own object (cn, name,
        sAMAccountName, displayName, Account Restrictions, Reset password, and the Validated Writes for DNS
        host name and SPN), or -DomainCredential is used. Prepare-HostRename.ps1 sets them up via delegation.
      - Central log: domain computers need to write and append data as well as read and write attributes on
        the log folder, but not read the contents.

.PARAMETER NameTemplate
    Name template with {Name} and/or {Serial}; takes precedence over -Prefix and -Suffix. Examples:
      'DE{Serial}'          PC349219 -> DE<serial number>
      'NG-{Name}'           PC349219 -> NG-PC349219 (equivalent to -Prefix "NG-")
      'DE-{Serial:-8}'      DE- plus the last 8 characters of the serial number
      '{Serial}-{Name:-4}'  serial number, hyphen, the last 4 characters of the old name
    Fixed characters: A-Z, 0-9, _ and -.

.PARAMETER Prefix
    Prefix before the previous name, e.g. "NG-" (at most 10 characters; A-Z, 0-9, hyphen).

.PARAMETER Suffix
    Suffix after the previous name, e.g. "-W11" (at most 10 characters; A-Z, 0-9, hyphen).

.PARAMETER OnTooLong
    Behavior if the name resulting from the template would be longer than 15 characters:
      TruncateEnd     shorten placeholder values at the end [default]
      TruncateStart   shorten placeholder values at the start (keeps e.g. trailing sequence numbers)
      Skip            do not rename (exit code 2)

.PARAMETER OnSerialProblem
    Behavior if the template contains {Serial} but the serial number is unusable or the target name
    already exists in AD:
      GenerateId      use a generated future ID instead of the serial number [default]
      Skip            do not rename (exit code 5 or COLLISION)

.PARAMETER FutureIdLength
    Length of the generated future ID, 4 to 12 characters (default: 8).

.PARAMETER CentralLogPath
    Full path of the central CSV file on the share. The default value is a placeholder; the GPO passes the
    real path from Prepare-HostRename.ps1.

.PARAMETER DomainCredential
    Optional: domain account with permission to rename the AD object. If omitted, the context of the
    executing account applies (SYSTEM = computer account).

.PARAMETER Reboot
    Schedules a reboot with a warning period (-RebootDelaySeconds) after a successful rename.

.PARAMETER RebootDelaySeconds
    Warning period for the reboot in seconds (default: 900).

.PARAMETER Cleanup
    After completion, removes the scheduled task (-TaskName), this script, the local log files and the
    empty folder. Intended only for runs via scheduled task; do NOT specify it for manual runs, otherwise
    the script file (e.g. on the share) is deleted.

.PARAMETER TaskName
    Name of the scheduled task that is removed with -Cleanup (default: HostRename).

.PARAMETER LocalDir
    Local folder for rename-local.csv and pending.csv (default: <Program Files>\HostRename). Standard users
    must not create or change anything there, so SYSTEM does not write to a folder that users can
    manipulate. The GPO passes the folder into which it copies the script.

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-HostRename.ps1 -Prefix "NG-" -WhatIf

    Dry run without changes: shows the target name for this device.

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-HostRename.ps1 -Prefix "NG-" -Reboot

    Renames and restarts after 15 minutes.

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-HostRename.ps1 -NameTemplate "DE{Serial}" -WhatIf

    Preview of a rename by serial number: PC349219 -> DE<serial number>.

.OUTPUTS
    No pipeline output. The exit code describes the result:
      0       nothing to do (name already matches the template) or -WhatIf
      3010    renamed or rename pending, reboot required
      1       error (details in the log)
      2       skipped: name too long (-OnTooLong Skip)
      4       no permission to rename on the device's own AD object
      5       no usable serial number (template with {Serial}, only with -OnSerialProblem Skip)

.NOTES
    Product          HostRename
    Version          1.1.9
    Date             2026-10-30
    Execution        Scheduled task as SYSTEM (deployed via GPO) or manually as administrator
    Encoding         UTF-8 with BOM (required for Windows PowerShell 5.1)

.LINK
    README.md
#>
#Requires -Version 5.1

[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidatePattern('^$|^[A-Za-z0-9_{}:-]+$')]
    [string]$NameTemplate = '',

    [ValidatePattern('^$|^[A-Za-z0-9][A-Za-z0-9-]{0,9}$')]
    [string]$Prefix = '',

    [ValidatePattern('^$|^[A-Za-z0-9-]{1,10}$')]
    [string]$Suffix = '',

    [ValidateSet('TruncateStart', 'TruncateEnd', 'Skip')]
    [string]$OnTooLong = 'TruncateEnd',

    [ValidateSet('GenerateId', 'Skip')]
    [string]$OnSerialProblem = 'GenerateId',

    [ValidateRange(4, 12)]
    [int]$FutureIdLength = 8,

    [string]$CentralLogPath = '\\FILESERVER\HostRename$\log\rename-log.csv',

    [pscredential]$DomainCredential,

    [switch]$Reboot,

    [int]$RebootDelaySeconds = 900,

    [switch]$Cleanup,

    [string]$TaskName = 'HostRename',

    [string]$LocalDir = ''
)

$ErrorActionPreference = 'Stop'
$ScriptVersion = '1.1.9'   # must match the version in .NOTES (checked by HostRename.Local.Tests.ps1)
$MaxLen     = 15
if (-not $LocalDir) {
    $programFiles = if ($env:ProgramW6432) { $env:ProgramW6432 } else { $env:ProgramFiles }
    $LocalDir = Join-Path $programFiles 'HostRename'
}
$LocalLog   = Join-Path $LocalDir 'rename-local.csv'
$PendingLog = Join-Path $LocalDir 'pending.csv'
$CsvHeader  = 'Timestamp;Level;Event;ComputerName;TargetName;Serial;MachineGuid;Message'
$regCN      = 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName'
$MarkerKey  = 'HKLM:\SOFTWARE\HostRename'   # must match $MarkerRegistryKey in Prepare-HostRename.ps1
$StateKey   = 'HKLM:\SOFTWARE\HostRenameState'   # remembers original name and target name (idempotency for templates with {Name} + {Serial})

try {
    if (-not (Test-Path $LocalDir)) { New-Item -ItemType Directory -Path $LocalDir -Force | Out-Null }
}
catch {
    # e.g. manual run without administrator rights: fall back to the temp folder
    $LocalDir   = Join-Path $env:TEMP 'HostRename'
    $LocalLog   = Join-Path $LocalDir 'rename-local.csv'
    $PendingLog = Join-Path $LocalDir 'pending.csv'
    New-Item -ItemType Directory -Path $LocalDir -Force | Out-Null
}

# ---- Device identity (stable keys for searching the log) --------------------
$script:CurrentName = $env:COMPUTERNAME
$script:TargetName  = ''
$script:Serial      = ''
$script:MachineGuid = ''
try { $script:Serial      = (Get-CimInstance -ClassName Win32_BIOS).SerialNumber }
catch { Write-Verbose "Serial number (BIOS) not readable, the log stays without a serial number: $($_.Exception.Message)" }
try { $script:MachineGuid = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Cryptography').MachineGuid }
catch { Write-Verbose "MachineGuid not readable, the log stays without a MachineGuid: $($_.Exception.Message)" }

# ---- Logging -----------------------------------------------------------------
function ConvertTo-CsvField {
    param([string]$Value)
    '"' + (($Value -replace '[\r\n]+', ' ') -replace '"', '""') + '"'
}

function Send-PendingLog {
    # Appends all lines not yet delivered to the central CSV.
    # Exclusive write access (FileShare.Read) + retry so that parallel devices do not overwrite each other.
    if (-not (Test-Path $PendingLog)) { return }
    $lines = @(Get-Content -Path $PendingLog -Encoding UTF8 | Where-Object { $_ })
    if ($lines.Count -eq 0) { return }

    $lastError = ''
    for ($i = 1; $i -le 6; $i++) {
        try {
            $fs = [System.IO.File]::Open($CentralLogPath,
                    [System.IO.FileMode]::Append,
                    [System.IO.FileAccess]::Write,
                    [System.IO.FileShare]::Read)
            try {
                $sw = New-Object System.IO.StreamWriter($fs, (New-Object System.Text.UTF8Encoding($true)))
                # Position instead of Length: after opening in append mode the position is at the end of the file; 0 = empty file.
                # Length would need the "Read attributes" right, which computer accounts intentionally do not have on the log folder.
                if ($fs.Position -eq 0) { $sw.WriteLine($CsvHeader) }
                foreach ($l in $lines) { $sw.WriteLine($l) }
                $sw.Flush()
            }
            finally { $fs.Dispose() }
            Remove-Item -Path $PendingLog -Force
            return
        }
        catch {
            $lastError = $_.Exception.Message
            Start-Sleep -Milliseconds (Get-Random -Minimum 300 -Maximum 1500)
        }
    }
    # Share unreachable/locked: entries stay in pending.csv and are delivered on the next run.
    # Record the reason locally once per run (otherwise the error stays invisible). -LocalOnly prevents recursion.
    if (-not $script:deliveryWarned) {
        $script:deliveryWarned = $true
        Write-RenameLog -Level WARN -EventName LOG_DELIVERY -Message "Central log '$CentralLogPath' not writable: $lastError - entries stay in pending.csv and are delivered on the next run." -LocalOnly
    }
}

function Write-RenameLog {
    param(
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level,
        [string]$EventName,
        [string]$Message,
        [switch]$LocalOnly
    )
    $ts  = Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz'
    $row = (@($ts, $Level, $EventName, $script:CurrentName, $script:TargetName,
              $script:Serial, $script:MachineGuid, $Message) |
            ForEach-Object { ConvertTo-CsvField ([string]$_) }) -join ';'

    if (-not (Test-Path $LocalLog)) { Set-Content -Path $LocalLog -Value $CsvHeader -Encoding UTF8 }
    Add-Content -Path $LocalLog -Value $row -Encoding UTF8
    Write-Output ('{0} [{1}] {2}: {3}' -f $ts, $Level, $EventName, $Message)

    if (-not $LocalOnly) {
        Add-Content -Path $PendingLog -Value $row -Encoding UTF8
        Send-PendingLog
    }
}

# ---- AD helper functions ------------------------------------------------------
function ConvertTo-LdapEscaped {
    param([string]$Value)
    $Value.Replace('\', '\5c').Replace('*', '\2a').Replace('(', '\28').Replace(')', '\29')
}

function Test-AdComputerExists {
    param([string]$Name)
    $n = ConvertTo-LdapEscaped $Name
    $searcher = [adsisearcher]"(&(objectCategory=computer)(|(sAMAccountName=$n`$)(name=$n)))"
    return [bool]$searcher.FindOne()
}

function Test-AdRenamePermission {
    <#
      Uses the constructed AD attribute allowedAttributesEffective to check which attributes the
      executing account (SYSTEM = computer account, or -DomainCredential) may WRITE on the computer
      object. AD itself evaluates the ACL (including SELF and groups). cn and sAMAccountName are
      decisive for a rename. The Validated Writes (DNS host name, SPN) cannot be checked reliably
      this way; if they are missing, Rename-Computer reports the error.
    #>
    param(
        [Parameter(Mandatory)][string]$ComputerName,
        [Parameter(Mandatory)][string]$DomainName,
        [pscredential]$Credential
    )
    $required = @('cn', 'sAMAccountName')
    $relevant = @('cn', 'name', 'sAMAccountName', 'displayName', 'dNSHostName', 'servicePrincipalName')

    $n      = ConvertTo-LdapEscaped $ComputerName
    $filter = "(&(objectCategory=computer)(sAMAccountName=$n`$))"
    if ($Credential) {
        $root     = New-Object System.DirectoryServices.DirectoryEntry("LDAP://$DomainName", $Credential.UserName, $Credential.GetNetworkCredential().Password)
        $searcher = New-Object System.DirectoryServices.DirectorySearcher($root, $filter)
    }
    else {
        $searcher = [adsisearcher]$filter
    }
    [void]$searcher.PropertiesToLoad.AddRange(@('distinguishedName', 'allowedAttributesEffective'))
    $res = $searcher.FindOne()

    if (-not $res) {
        return [pscustomobject]@{ Found = $false; Inconclusive = $false; Dn = $null; Writable = @(); Missing = $required }
    }

    $dn       = [string]$res.Properties['distinguishedname'][0]
    $writable = @($res.Properties['allowedattributeseffective'] | ForEach-Object { [string]$_ })
    $missing  = @($required | Where-Object { $writable -notcontains $_ })

    [pscustomobject]@{
        Found        = $true
        Inconclusive = ($writable.Count -eq 0)    # empty = result cannot be evaluated
        Dn           = $dn
        Writable     = @($writable | Where-Object { $relevant -contains $_ })
        Missing      = $missing
    }
}

# ---- Cleanup --------------------------------------------------------------------
function Test-LogPending {
    if (-not (Test-Path $PendingLog)) { return $false }
    return (@(Get-Content -Path $PendingLog -Encoding UTF8 | Where-Object { $_ }).Count -gt 0)
}

function Invoke-Cleanup {
    # Removes the scheduled task, the script, local log files and the (empty) folder.
    # Returns: $true = cleaned up, $false = deferred/failed.
    # Errors here must never affect the result of the rename.
    try {
        # 1) First deliver all log entries to the share - afterwards no task remains that could deliver them later
        Send-PendingLog
        if (Test-LogPending) {
            Write-RenameLog -Level WARN -EventName CLEANUP_DEFERRED -Message 'Log entries have not yet arrived on the share - cleanup will be made up for on the next run.' -LocalOnly
            return $false
        }

        # 2) Log the start of the cleanup centrally and make sure the entry has arrived
        Write-RenameLog -Level INFO -EventName CLEANUP -Message "Removing scheduled task '$TaskName', script and local log files."
        if (Test-LogPending) {
            Write-RenameLog -Level WARN -EventName CLEANUP_DEFERRED -Message 'Log entries have not yet arrived on the share - cleanup will be made up for on the next run.' -LocalOnly
            return $false
        }

        # 3) Set the marker: if the marker exists, the GPO does not recreate script and task
        New-Item -Path $MarkerKey -Force | Out-Null
        Set-ItemProperty -Path $MarkerKey -Name 'Completed'    -Value (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz')
        Set-ItemProperty -Path $MarkerKey -Name 'ComputerName' -Value ([string]$script:TargetName)

        # 4) Remove the task first (an orphaned task would be worse than an orphaned file)
        if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        }

        # 5) Remove the script
        $scriptDir = $null
        if ($PSCommandPath -and (Test-Path $PSCommandPath)) {
            $scriptDir = Split-Path -Path $PSCommandPath -Parent
            Remove-Item -Path $PSCommandPath -Force
        }
        Write-RenameLog -Level INFO -EventName CLEANUP_DONE -Message "Scheduled task '$TaskName' and script were removed."

        # 6) Remove local log files and empty folders - but only if everything (including CLEANUP_DONE) has arrived on the share.
        #    Otherwise the local logs are kept as evidence.
        if (-not (Test-LogPending)) {
            Remove-Item -Path $LocalLog, $PendingLog -Force -ErrorAction SilentlyContinue
            foreach ($dir in @($scriptDir, $LocalDir) | Where-Object { $_ } | Select-Object -Unique) {
                if ((Test-Path $dir) -and -not (Get-ChildItem -Path $dir -Force -ErrorAction SilentlyContinue)) {
                    Remove-Item -Path $dir -Force -ErrorAction SilentlyContinue
                }
            }
        }
        return $true
    }
    catch {
        Write-RenameLog -Level WARN -EventName CLEANUP_FAILED -Message "Cleanup failed: $($_.Exception.Message)"
        return $false
    }
}

# ---- Check central log ---------------------------------------------------------------
function Test-CentralLog {
    # Checks in three stages whether the central log is reachable and writable for this account, without writing anything:
    #   1) name resolution of the server  2) TCP port 445 (SMB)  3) open the file for appending (share and NTFS permission)
    # Returns Ok, the stage that failed and an error message. The result is for diagnostics in the local log only.
    param([string]$Path = $CentralLogPath)
    $res = [pscustomobject]@{ Ok = $false; Stage = ''; Error = '' }

    if ($Path -match '^\\\\([^\\]+)\\') {
        $server = $Matches[1]
        try { $null = [System.Net.Dns]::GetHostAddresses($server) }
        catch { $res.Stage = 'NameResolution'; $res.Error = "Server '$server' cannot be resolved ($($_.Exception.Message))"; return $res }

        $tcp = New-Object System.Net.Sockets.TcpClient
        try {
            $iar = $tcp.BeginConnect($server, 445, $null, $null)
            if (-not $iar.AsyncWaitHandle.WaitOne(3000, $false)) { $res.Stage = 'SmbPort'; $res.Error = "Port 445 on '$server' is not responding (timeout after 3 s)"; return $res }
            $tcp.EndConnect($iar)
        }
        catch { $res.Stage = 'SmbPort'; $res.Error = "Port 445 on '$server' is unreachable ($($_.Exception.Message))"; return $res }
        finally { $tcp.Close() }
    }

    try {
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
        $fs.Dispose()
        $res.Ok = $true
    }
    catch [System.UnauthorizedAccessException] {
        $res.Stage = 'Access'; $res.Error = "Access denied: check the share and NTFS write permission for domain computers ($($_.Exception.Message))"
    }
    catch [System.IO.DirectoryNotFoundException] {
        $res.Stage = 'Path'; $res.Error = "Folder or share not found ($($_.Exception.Message))"
    }
    catch {
        $res.Stage = 'Open'; $res.Error = $_.Exception.Message
    }
    return $res
}

# ---- Secure channel -------------------------------------------------------------
function Test-SecureChannel {
    # Test-ComputerSecureChannel exists in Windows PowerShell 5.1 and in newer PowerShell 7 versions;
    # otherwise fall back to nltest (exit code 0 = secure channel OK).
    param([string]$Domain)
    if (Get-Command Test-ComputerSecureChannel -ErrorAction SilentlyContinue) { return [bool](Test-ComputerSecureChannel) }
    $null = & nltest.exe "/sc_verify:$Domain" 2>&1
    return ($LASTEXITCODE -eq 0)
}

# ---- Name template ---------------------------------------------------------------
function Get-DeviceSerial {
    # Returns the first usable serial number (A-Z/0-9 only): BIOS, then system product, then baseboard.
    # Discarded are values that are too short (< 4 characters), manufacturer placeholders and single-character values.
    $placeholder = @('TOBEFILLEDBYOEM', 'DEFAULTSTRING', 'SYSTEMSERIALNUMBER', 'SERIALNUMBER', 'NONE', 'NA', 'UNKNOWN',
                     'NOTAVAILABLE', 'NOTSPECIFIED', 'OEM', 'OEMSTRING', '123456789', '1234567890', '0123456789')
    $sources = @(
        @{ Name = 'BIOS';                  Get = { (Get-CimInstance -ClassName Win32_BIOS).SerialNumber } },
        @{ Name = 'ComputerSystemProduct'; Get = { (Get-CimInstance -ClassName Win32_ComputerSystemProduct).IdentifyingNumber } },
        @{ Name = 'BaseBoard';             Get = { (Get-CimInstance -ClassName Win32_BaseBoard).SerialNumber } }
    )
    $rejected = @()
    foreach ($src in $sources) {
        $raw   = try { [string](& $src.Get) } catch { '' }
        $clean = ($raw -replace '[^A-Za-z0-9]', '').ToUpper()
        $valid = ($clean.Length -ge 4) -and ($placeholder -notcontains $clean) -and (@($clean.ToCharArray() | Select-Object -Unique).Count -gt 1)
        if ($valid) { return [pscustomobject]@{ Value = $clean; Source = $src.Name; Raw = $raw; Rejected = $rejected } }
        $rejected += ('{0}: "{1}"' -f $src.Name, $raw)
    }
    [pscustomobject]@{ Value = $null; Source = $null; Raw = ''; Rejected = $rejected }
}

function New-FutureId {
    # Short, stable future ID from a seed value (MachineGuid): same input = same ID, so that repeated
    # runs produce the same name. Alphabet without ambiguous characters (no I, O, 0, 1). -Attempt produces a
    # different ID on a collision. Digits-only IDs are avoided (computer names must not consist of digits only).
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Only generates a string, does not change any system state (like New-Guid).')]
    param(
        [Parameter(Mandatory)][string]$Seed,
        [ValidateRange(4, 12)][int]$Length = 8,
        [int]$Attempt = 0
    )
    $alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'          # 32 characters: 256 is divisible by 32, hence uniformly distributed
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        for ($inner = 0; $inner -lt 20; $inner++) {
            $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes(('{0}|{1}|{2}' -f $Seed, $Attempt, $inner)))
            $id = -join (0..($Length - 1) | ForEach-Object { $alphabet[$bytes[$_] % 32] })
            if ($id -notmatch '^[0-9]+$') { return $id }
        }
        return $id
    }
    finally { $sha.Dispose() }
}

function Resolve-NameTemplate {
    # Builds the target name from the template. Placeholders: {Name}, {Serial}, optionally with :N (first N) or :-N (last N).
    # Names that are too long: only the placeholder values are shortened (last placeholder first, at least 1 character remains).
    param(
        [Parameter(Mandatory)][string]$Template,
        [Parameter(Mandatory)][string]$CurrentName,
        [string]$Serial = '',
        [int]$MaxLength = 15,
        [string]$OnTooLong = 'TruncateEnd'
    )
    $res  = [pscustomobject]@{ Ok = $false; Name = ''; Full = ''; Truncated = $false; Code = ''; Error = '' }
    $segs = New-Object System.Collections.ArrayList
    $pos  = 0
    $rx   = [regex]::Matches($Template, '\{(?<tok>NAME|SERIAL)(?::(?<n>-?\d+))?\}', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    foreach ($m in $rx) {
        if ($m.Index -gt $pos) { [void]$segs.Add(@{ Kind = 'lit'; Text = $Template.Substring($pos, $m.Index - $pos) }) }
        $val = if ($m.Groups['tok'].Value -ieq 'NAME') { [string]$CurrentName } else { [string]$Serial }
        if ($m.Groups['n'].Success) {
            $n = [int]$m.Groups['n'].Value
            if ($n -ne 0 -and [math]::Abs($n) -lt $val.Length) {
                $val = if ($n -gt 0) { $val.Substring(0, $n) } else { $val.Substring($val.Length + $n) }
            }
        }
        [void]$segs.Add(@{ Kind = 'tok'; Text = $val })
        $pos = $m.Index + $m.Length
    }
    if ($pos -lt $Template.Length) { [void]$segs.Add(@{ Kind = 'lit'; Text = $Template.Substring($pos) }) }

    foreach ($sg in $segs) {
        if ($sg.Kind -eq 'lit' -and $sg.Text -match '[{}]') {
            $res.Code  = 'TEMPLATE'
            $res.Error = "Unknown placeholder in template '$Template' (allowed: {Name}, {Serial}, each with :N or :-N)."
            return $res
        }
        if ($sg.Kind -eq 'tok' -and [string]::IsNullOrEmpty($sg.Text)) {
            $res.Code  = 'TEMPLATE'
            $res.Error = "A placeholder in template '$Template' yields an empty value."
            return $res
        }
    }

    $join = { ($segs | ForEach-Object { $_.Text }) -join '' }
    $full = & $join
    $res.Full = $full.ToUpper()

    if ($full.Length -gt $MaxLength) {
        $res.Truncated = $true
        if ($OnTooLong -eq 'Skip') {
            $res.Code  = 'TOO_LONG'
            $res.Error = "Target name '$($res.Full)' has $($full.Length) characters (max. $MaxLength). Skipped."
            return $res
        }
        for ($i = $segs.Count - 1; $i -ge 0; $i--) {
            $excess = (& $join).Length - $MaxLength
            if ($excess -le 0) { break }
            $sg = $segs[$i]
            if ($sg.Kind -ne 'tok') { continue }
            $cut = [math]::Min($excess, $sg.Text.Length - 1)
            if ($cut -le 0) { continue }
            $sg.Text = if ($OnTooLong -eq 'TruncateEnd') { $sg.Text.Substring(0, $sg.Text.Length - $cut) } else { $sg.Text.Substring($cut) }
            $trimmed = $sg.Text.Trim('-')                       # no hyphen at the cut edges
            if ($trimmed) { $sg.Text = $trimmed }
        }
        $full = & $join
        if ($full.Length -gt $MaxLength) {
            $res.Code  = 'TRUNCATE'
            $res.Error = "Target name is still too long after shortening ($($full.Length) characters, max. $MaxLength). Template '$Template' contains too many fixed characters."
            return $res
        }
    }

    $name = $full.ToUpper()
    if ($name -notmatch '^[A-Z0-9_]([A-Z0-9_-]*[A-Z0-9_])?$' -or $name -match '^[0-9]+$') {
        $res.Code  = 'NAME_INVALID'
        $res.Error = "Target name '$name' is invalid (allowed: A-Z, 0-9, _ and -; must not start or end with -; not digits only)."
        return $res
    }
    $res.Ok   = $true
    $res.Name = $name
    $res
}

function Get-RenameState {
    if (Test-Path $StateKey) { Get-ItemProperty -Path $StateKey } else { $null }
}

function Set-RenameState {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Helper function: the confirmation prompt (ShouldProcess) happens in the main flow before the rename.')]
    param([string]$Original, [string]$Target, [string]$Template, [string]$FutureId = '')
    New-Item -Path $StateKey -Force | Out-Null
    Set-ItemProperty -Path $StateKey -Name 'FutureId'     -Value $FutureId
    Set-ItemProperty -Path $StateKey -Name 'OriginalName' -Value $Original
    Set-ItemProperty -Path $StateKey -Name 'TargetName'   -Value $Target
    Set-ItemProperty -Path $StateKey -Name 'Template'     -Value $Template
    Set-ItemProperty -Path $StateKey -Name 'Applied'      -Value (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz')
}

# ---- Main logic ----------------------------------------------------------------
try {
    $active  = (Get-ItemProperty "$regCN\ActiveComputerName").ComputerName   # currently effective
    $pending = (Get-ItemProperty "$regCN\ComputerName").ComputerName         # effective after reboot
    $script:CurrentName = $active

    # 0) Determine the name template: -NameTemplate takes precedence, otherwise "Prefix{Name}Suffix"
    $Template = if ($NameTemplate) { $NameTemplate } elseif ($Prefix -or $Suffix) { '{0}{{Name}}{1}' -f $Prefix, $Suffix } else { '' }
    if (-not $Template) {
        Write-RenameLog -Level ERROR -EventName CONFIG -Message 'Neither -NameTemplate nor -Prefix/-Suffix specified - nothing to do.'
        exit 1
    }
    $Template   = $Template.ToUpper()
    $usesName   = $Template -match '\{NAME(:-?\d+)?\}'
    $usesSerial = $Template -match '\{SERIAL(:-?\d+)?\}'
    $serialInfo = if ($usesSerial) { Get-DeviceSerial } else { $null }
    $state      = Get-RenameState

    # 1) Already done or rename pending? (no DC connection needed)
    $done = $false
    if ($state -and ($state.Template -ieq $Template) -and $state.TargetName -and ($pending -ieq $state.TargetName)) {
        $done = $true                                           # target name set by HostRename with exactly this template
    }
    elseif (-not $usesSerial -and $Template -match '^(?<pre>[A-Z0-9_-]*)\{NAME\}(?<suf>[A-Z0-9_-]*)$') {
        # Prefix/suffix mode: devices that have already been renamed are recognized by the pattern
        $pre = $Matches['pre']; $suf = $Matches['suf']
        if ($pre -or $suf) {
            $done = (-not $pre -or $pending.StartsWith($pre, [StringComparison]::OrdinalIgnoreCase)) -and
                    (-not $suf -or $pending.EndsWith($suf, [StringComparison]::OrdinalIgnoreCase))
        }
    }
    elseif (-not $usesName -and $serialInfo -and $serialInfo.Value) {
        # Template without {Name} (e.g. DE{Serial}): the target name is independent of the old name
        $probe = Resolve-NameTemplate -Template $Template -CurrentName $active -Serial $serialInfo.Value -MaxLength $MaxLen -OnTooLong $OnTooLong
        $done  = $probe.Ok -and ($pending -ieq $probe.Name)
    }

    if ($done) {
        $script:TargetName = $pending
        if ($active -ne $pending) {
            Write-RenameLog -Level WARN -EventName PENDING_REBOOT -Message "Rename to '$pending' is already pending - reboot required."
            if ($Cleanup) { [void](Invoke-Cleanup) }
            exit 3010
        }
        # Log locally only, so the central log is not cluttered on every start
        Write-RenameLog -Level INFO -EventName ALREADY_DONE -Message "Host name already matches template '$Template' - nothing to do." -LocalOnly
        if ($Cleanup) { [void](Invoke-Cleanup) }
        exit 0
    }

    Write-RenameLog -Level INFO -EventName START -Message "HostRename ${ScriptVersion}: template '$Template', mode for names that are too long: $OnTooLong"

    # 1a) Check the central log. Diagnostics only: the rename also runs without a central log, the entries are then delivered later
    #     and the cleanup waits. The result is only written to the local log, because the central one may be unusable.
    $logCheck = Test-CentralLog
    if ($logCheck.Ok) { Write-RenameLog -Level INFO -EventName LOG_CHECK -Message "Central log '$CentralLogPath' is reachable and writable." -LocalOnly }
    else              { Write-RenameLog -Level WARN -EventName LOG_CHECK -Message "Central log '$CentralLogPath' not usable (stage: $($logCheck.Stage)): $($logCheck.Error). Entries stay in pending.csv and will be delivered later." -LocalOnly }

    if ($active -ne $pending) {
        Write-RenameLog -Level ERROR -EventName PRECHECK -Message "Another rename ('$pending') is pending. Please reboot first."
        exit 1
    }

    # 1b) Check the serial number (only if the template uses it); on problems use a future ID if applicable
    $serialValue = ''
    $idUsed      = $false
    $futureId    = ''
    # Seed of the ID: must be stable across renames (MachineGuid, otherwise BIOS UUID) - never the computer name
    $idSeed      = $script:MachineGuid
    if ($usesSerial -and -not $idSeed) { $idSeed = try { [string](Get-CimInstance -ClassName Win32_ComputerSystemProduct).UUID } catch { '' } }
    if ($usesSerial) {
        if ($serialInfo.Value) {
            $serialValue = $serialInfo.Value
            Write-RenameLog -Level INFO -EventName SERIAL -Message "Serial number '$serialValue' (source: $($serialInfo.Source))."
        }
        elseif ($OnSerialProblem -eq 'GenerateId' -and -not $idSeed) {
            Write-RenameLog -Level ERROR -EventName SERIAL_INVALID -Message "No usable serial number ($($serialInfo.Rejected -join '; ')) and no MachineGuid/UUID for a stable ID. Skipped."
            exit 5
        }
        elseif ($OnSerialProblem -eq 'GenerateId') {
            $futureId    = New-FutureId -Seed $idSeed -Length $FutureIdLength -Attempt 0
            $serialValue = $futureId
            $idUsed      = $true
            Write-RenameLog -Level WARN -EventName SERIAL_FALLBACK -Message "No usable serial number ($($serialInfo.Rejected -join '; ')) - using generated ID '$futureId' (from the MachineGuid)."
        }
        else {
            Write-RenameLog -Level ERROR -EventName SERIAL_INVALID -Message "No usable serial number found ($($serialInfo.Rejected -join '; ')). Skipped."
            exit 5
        }
    }

    # 2) Check domain and secure channel
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem
    if (-not $cs.PartOfDomain) {
        Write-RenameLog -Level ERROR -EventName PRECHECK -Message 'Device is not a member of a domain.'
        exit 1
    }
    if (-not (Test-SecureChannel -Domain $cs.Domain)) {
        Write-RenameLog -Level ERROR -EventName PRECHECK -Message "Secure channel to domain '$($cs.Domain)' is not intact or DC is unreachable."
        exit 1
    }

    # 2b) Check the permission to rename on the device's own AD object (before anything is changed)
    $perm = Test-AdRenamePermission -ComputerName $active -DomainName $cs.Domain -Credential $DomainCredential
    $permContext = if ($DomainCredential) { $DomainCredential.UserName } else { 'computer account (SELF)' }
    if (-not $perm.Found) {
        Write-RenameLog -Level ERROR -EventName PERM_CHECK -Message "Computer object '$active`$' was not found in AD - permission check not possible."
        exit 1
    }
    elseif ($perm.Inconclusive) {
        Write-RenameLog -Level WARN -EventName PERM_CHECK -Message "Write permissions on '$($perm.Dn)' could not be determined (context: $permContext). Continuing; an error will be logged during the rename."
    }
    elseif ($perm.Missing.Count -gt 0) {
        Write-RenameLog -Level ERROR -EventName PERM_DENIED -Message "No write permissions on: $($perm.Missing -join ', ') on object '$($perm.Dn)' (context: $permContext). Check the delegation (Prepare-HostRename.ps1 -Action Setup -Component Delegation) or use -DomainCredential."
        exit 4
    }
    else {
        Write-RenameLog -Level INFO -EventName PERM_CHECK -Message "Permission to rename present on '$($perm.Dn)' (context: $permContext; writable: $($perm.Writable -join ', '))."
    }

    # 3) Build the target name from the template, shorten if necessary
    $plan = Resolve-NameTemplate -Template $Template -CurrentName $active -Serial $serialValue -MaxLength $MaxLen -OnTooLong $OnTooLong
    if (-not $plan.Ok) {
        $script:TargetName = $plan.Full
        Write-RenameLog -Level ERROR -EventName $plan.Code -Message $plan.Error
        if ($plan.Code -eq 'TOO_LONG') { exit 2 } else { exit 1 }
    }
    $newName = $plan.Name
    $script:TargetName = $newName
    if ($plan.Truncated) {
        Write-RenameLog -Level WARN -EventName TRUNCATE -Message "Template '$Template' produced '$($plan.Full)' ($($plan.Full.Length) characters), shortened to '$newName' (mode: $OnTooLong)."
    }
    if ($newName -ieq $active) {
        Write-RenameLog -Level INFO -EventName ALREADY_DONE -Message "Host name '$active' already matches the result of the template - nothing to do." -LocalOnly
        if ($Cleanup) { [void](Invoke-Cleanup) }
        exit 0
    }

    # 4) Collision check in AD (also applies to shortened names). On a duplicate serial number or colliding ID
    #    a (further) future ID is used: stable from the MachineGuid, with the next counter value on a collision.
    $idAttempt = if ($idUsed) { 0 } else { -1 }
    while (Test-AdComputerExists $newName) {
        if (-not $usesSerial -or $OnSerialProblem -ne 'GenerateId' -or -not $idSeed -or $idAttempt -ge 4) {
            Write-RenameLog -Level ERROR -EventName COLLISION -Message "Computer object '$newName' already exists in AD. Aborting."
            exit 1
        }
        $idAttempt++
        $oldName  = $newName
        $futureId = New-FutureId -Seed $idSeed -Length $FutureIdLength -Attempt $idAttempt
        $plan     = Resolve-NameTemplate -Template $Template -CurrentName $active -Serial $futureId -MaxLength $MaxLen -OnTooLong $OnTooLong
        if (-not $plan.Ok) {
            Write-RenameLog -Level ERROR -EventName $plan.Code -Message $plan.Error
            exit 1
        }
        $newName           = $plan.Name
        $script:TargetName = $newName
        $idUsed            = $true
        Write-RenameLog -Level WARN -EventName SERIAL_FALLBACK -Message "Target name '$oldName' already exists in AD (duplicate serial number?) - using generated ID '$futureId' -> '$newName' (attempt $($idAttempt + 1))."
        if ($newName -ieq $active) {
            Write-RenameLog -Level INFO -EventName ALREADY_DONE -Message "Host name '$active' already matches the result of the template (generated ID) - nothing to do." -LocalOnly
            if ($Cleanup) { [void](Invoke-Cleanup) }
            exit 0
        }
    }

    # 5) DNS check (warning only, since stale records are common)
    try {
        $ips = [System.Net.Dns]::GetHostAddresses("$newName.$($cs.Domain)") | ForEach-Object { $_.IPAddressToString }
        Write-RenameLog -Level WARN -EventName DNS_EXISTS -Message "Target name '$newName' already resolves in DNS: $($ips -join ', ') (possibly a stale record)."
    }
    catch { Write-Verbose "No DNS record for '$newName.$($cs.Domain)' (this is the expected case): $($_.Exception.Message)" }

    # 6) Rename (local + AD object)
    if ($PSCmdlet.ShouldProcess($active, "Rename to '$newName'")) {
        $rp = @{ NewName = $newName; Force = $true; ErrorAction = 'Stop' }
        if ($DomainCredential) { $rp.DomainCredential = $DomainCredential }
        Rename-Computer @rp
        Write-RenameLog -Level INFO -EventName RENAMED -Message "Successfully renamed: '$active' -> '$newName' (effective locally after reboot)."
        try   { Set-RenameState -Original $active -Target $newName -Template $Template -FutureId $(if ($idUsed) { $futureId } else { '' }) }
        catch { Write-RenameLog -Level WARN -EventName STATE -Message "State could not be saved: $($_.Exception.Message)" }

        # 7) Verification in AD
        try {
            $newOk = Test-AdComputerExists $newName
            $oldOk = Test-AdComputerExists $active
            if ($newOk -and -not $oldOk) { Write-RenameLog -Level INFO -EventName AD_VERIFY -Message "AD object '$newName' exists, '$active' no longer does." }
            else { Write-RenameLog -Level WARN -EventName AD_VERIFY -Message "AD check inconclusive (new exists: $newOk, old still exists: $oldOk). Wait for replication if necessary." }
        }
        catch { Write-RenameLog -Level WARN -EventName AD_VERIFY -Message "AD verification not possible: $($_.Exception.Message)" }

        if ($Reboot) {
            # Intentionally German: this notification is shown to the German-speaking end users (wording approved by the owner).
            $msg = "Der Computername wird geändert. Das Gerät startet in $([math]::Round($RebootDelaySeconds / 60)) Minuten neu. Bitte Arbeit speichern."
            & shutdown.exe /r /t $RebootDelaySeconds /c $msg /d p:4:1
            Write-RenameLog -Level INFO -EventName REBOOT -Message "Reboot scheduled in $RebootDelaySeconds seconds."
        }
        if ($Cleanup) { [void](Invoke-Cleanup) }
        exit 3010
    }
    else {
        Write-RenameLog -Level INFO -EventName WHATIF -Message "'$active' would be renamed to '$newName' (no changes made)."
        exit 0
    }
}
catch {
    $m = $_.Exception.Message
    # 'verweigert' is intentionally German: the error text is localized (German Windows: "Zugriff verweigert")
    if ($m -match 'denied|verweigert') {
        $m += ' | Hint: check the AD permissions (delegation for SELF on the OU, including "Reset password", or -DomainCredential). Details: C:\Windows\debug\NetSetup.LOG'
    }
    Write-RenameLog -Level ERROR -EventName RENAME_FAILED -Message $m
    exit 1
}
finally {
    Send-PendingLog   # deliver any entries that are still open
}
