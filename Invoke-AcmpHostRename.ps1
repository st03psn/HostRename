<#
.SYNOPSIS
    HostRename - ACMP wrapper: runs the whole flow of the ACMP Client Command in one script run.

.DESCRIPTION
    Implements the flow of docs/acmp-guide.md, section 4 in ONE run per ACMP invocation, so that the Client
    Command only has to transfer the files, start this script in the 64-bit PowerShell and react to its exit code
    (3010: reboot dialog, 20: LAN cable dialog, everything else: end).

    The existing scripts are called unchanged from the folder of this script ($PSScriptRoot), in the same
    process (& <script> @parameters); their exit code is read from $LASTEXITCODE and their output passes through
    to stdout. They stay standalone and reusable:
      Invoke-HostRename.ps1            rename (-Deployment Acmp) and cleanup
      Test-DeploymentNetwork.ps1       network gate
      Update-ComputerCertificate.ps1   certificate renewal (only with -CertificateTemplate)

    FLOW PER RUN
      1. Platform     32-bit process on 64-bit Windows: [ERROR] PLATFORM, exit 1, nothing else runs.
      2. Parameters   exactly one of -NoCentralLog or -CentralLogPath; otherwise exit 1.
      3. State check  (read-only, same rules as the step-1 snippet in docs/acmp-guide.md)
                        marker HKLM:\SOFTWARE\HostRename exists          -> done, exit 0
                        HostRenameState\LastExitCode is 2, 4 or 5        -> permanent, exit with that code
                                                                            (nothing else runs)
                        HostRenameState\TargetName = computer name       -> phase "after reboot"
                        otherwise                                        -> phase "rename"
      4. Gate         Test-DeploymentNetwork.ps1 (-Allow, -CorporateSsid, -DomainName if given);
                      exit code other than 0 -> exit with the gate code (20, 21, 22 or 1).
      5. Rename       (phase "rename") Invoke-HostRename.ps1 -Deployment Acmp with the naming and log parameters:
                        3010      -> exit 3010 (reboot required)
                        0         -> name already fits: continue with step 6 in the same run
                        1         -> exit 1 (retry)
                        2, 4, 5   -> exit with that code (permanent)
      6. Certificate  (only with -CertificateTemplate) Update-ComputerCertificate.ps1 -Template ... [-RemoveOld];
                      exit 1 -> exit 1, no cleanup (retry on the next run).
      7. Cleanup      Invoke-HostRename.ps1 -Deployment Acmp ... -Cleanup (same parameters as step 5):
                      0 -> exit 0. If the marker is still missing (cleanup deferred because the central log was
                      unreachable), still exit 0; the summary says so and the next run completes the cleanup.

    DRY RUN (-WhatIf)
      Steps 1 to 4, then Invoke-HostRename.ps1 -Deployment Acmp ... -WhatIf, in both phases. No certificate step,
      no cleanup. Nothing is written by this script or by the scripts it calls (no log, no reporting values).

    OUTPUT
      The output of the called scripts passes through to stdout. Before every called script one line
      "HOSTRENAME STEP=<step> RUN=<script>" is printed. The LAST line is always one summary line:
        HOSTRENAME PHASE=<phase> EXIT=<n> STEP=<step> MESSAGE="<text>"
      PHASE   Done, Permanent, Gate, Rename, RebootRequired, Certificate, Cleanup, DryRun, Error
      STEP    Platform, Parameters, StateCheck, Gate, Rename, Certificate, Cleanup (the step that decided)
      Exception: a parameter of this script that PowerShell itself cannot bind (e.g. a non-numeric
      -FutureIdLength) ends with PowerShell's own error message before the script starts.

    EXIT CODES (contract for the ACMP Client Command)
      0       done, or nothing (more) to do in this run; also dry run without findings
      3010    renamed or rename pending: reboot required (reboot dialog, reboot by ACMP)
      20      only the corporate WLAN: dialog "connect LAN cable", retry later
      21      no domain connection: end silently, retry later
      22      network path not allowed or unknown: end silently, retry later
      1       error: retry on the next run (details in the output and the local log)
      2       name too long (-OnTooLong Skip): permanent
      4       no permission on the own AD object (delegation): permanent
      5       no usable serial number (-OnSerialProblem Skip): permanent
      Permanent codes (2, 4, 5) are stored by Invoke-HostRename.ps1 in HKLM:\SOFTWARE\HostRenameState\LastExitCode;
      every following run ends at the state check with the same code until the value is removed (release):
        Remove-ItemProperty -Path HKLM:\SOFTWARE\HostRenameState -Name LastExitCode
      An unexpected exception in this script ends with exit code 1 and the summary line (PHASE=Error).
      Any other exit code of a called script is reported as 1.

    REQUIREMENTS
      - Runs as SYSTEM, started by the ACMP agent in the 64-bit Windows PowerShell:
          powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-AcmpHostRename.ps1 ...
        A 32-bit agent starts %SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe instead.
      - Invoke-HostRename.ps1 and Test-DeploymentNetwork.ps1 (and, with -CertificateTemplate,
        Update-ComputerCertificate.ps1) in the same folder as this script, unchanged (UTF-8 with BOM).
      - Delegation of the rename rights to SELF on the client OUs (Prepare-HostRename.ps1 -Component Delegation).

.PARAMETER NameTemplate
    Passed to Invoke-HostRename.ps1 (e.g. "DE{Serial}"). Use the same value in every run.

.PARAMETER Prefix
    Passed to Invoke-HostRename.ps1.

.PARAMETER Suffix
    Passed to Invoke-HostRename.ps1.

.PARAMETER OnTooLong
    Passed to Invoke-HostRename.ps1 (TruncateEnd, TruncateStart, Skip).

.PARAMETER OnSerialProblem
    Passed to Invoke-HostRename.ps1 (GenerateId, Skip).

.PARAMETER FutureIdLength
    Passed to Invoke-HostRename.ps1 (4 to 12).

.PARAMETER NoCentralLog
    No central log (passed to Invoke-HostRename.ps1). Exactly one of -NoCentralLog and -CentralLogPath is
    required, so that the placeholder default path of Invoke-HostRename.ps1 is never used by accident.

.PARAMETER CentralLogPath
    UNC path of the central CSV log (passed to Invoke-HostRename.ps1). A blank value or the literal '' or ""
    counts as missing; use -NoCentralLog instead.

.PARAMETER Allow
    Passed to Test-DeploymentNetwork.ps1 (Lan, DirectAccess, Wlan; default of the gate: Lan, DirectAccess).
    A comma list from powershell.exe -File ("Lan,DirectAccess") arrives as one string; the gate splits it.

.PARAMETER CorporateSsid
    Passed to Test-DeploymentNetwork.ps1: SSID(s) of the corporate WLAN, comma-separated.

.PARAMETER DomainName
    Passed to Test-DeploymentNetwork.ps1 (default of the gate: the domain of this computer).

.PARAMETER CertificateTemplate
    Template name (not the display name) of the WLAN machine certificate. If given, Update-ComputerCertificate.ps1
    -Template <name> runs after the rename (after the reboot), before the cleanup. Only for WLAN devices.

.PARAMETER RemoveOldCertificates
    Passes -RemoveOld to Update-ComputerCertificate.ps1. Only together with -CertificateTemplate.

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-AcmpHostRename.ps1 -NameTemplate "DE{Serial}" -NoCentralLog -CorporateSsid "CORP-WLAN" -WhatIf

    Dry run: gate and the target name of this device, nothing is changed or written.

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-AcmpHostRename.ps1 -NameTemplate "DE{Serial}" -NoCentralLog -CorporateSsid "CORP-WLAN"

    LAN/DirectAccess devices: rename (exit 3010), after the reboot cleanup (exit 0), afterwards always exit 0.

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-AcmpHostRename.ps1 -NameTemplate "DE{Serial}" -CentralLogPath "\\<Server>\HostRename$\log\rename-log.csv" -CorporateSsid "CORP-WLAN" -CertificateTemplate "<TemplateName>" -RemoveOldCertificates

    WLAN devices with central log: after the reboot the machine certificate is renewed for the new name, then the
    cleanup runs.

.OUTPUTS
    Lines on stdout (see OUTPUT); the last one is the summary line. The exit code follows EXIT CODES.

.NOTES
    Product          HostRename
    Version          1.2.0
    Date             2026-11-03
    Execution        ACMP agent as SYSTEM, 64-bit Windows PowerShell 5.1 (PowerShell 7 works in addition)
    Encoding         UTF-8 with BOM (required for Windows PowerShell 5.1)

.LINK
    docs/acmp-guide.md
#>
#Requires -Version 5.1

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$NameTemplate,

    [string]$Prefix,

    [string]$Suffix,

    [string]$OnTooLong,

    [string]$OnSerialProblem,

    [int]$FutureIdLength,

    [switch]$NoCentralLog,

    [string]$CentralLogPath,

    [string[]]$Allow,

    [string[]]$CorporateSsid,

    [string]$DomainName,

    [string]$CertificateTemplate,

    [switch]$RemoveOldCertificates
)

# No $ErrorActionPreference = 'Stop' here: the called scripts run in this process and would inherit it.
# All variables and function parameters of this script start with "Acmp": the called scripts run in a child
# scope of this script and could otherwise read a variable of the same name that they never assigned.
$AcmpBound     = $PSBoundParameters
$AcmpMarkerKey = 'HKLM:\SOFTWARE\HostRename'
$AcmpStateKey  = 'HKLM:\SOFTWARE\HostRenameState'
$AcmpDryRun    = [bool]$WhatIfPreference
$script:AcmpStep   = 'Platform'
$script:AcmpResult = $null
$script:AcmpOutput = @()
$script:AcmpExit   = 0

# ---- Helpers ---------------------------------------------------------------------------
function Test-Wow64Process {
    # True for a 32-bit process on 64-bit Windows (registry writes to HKLM:\SOFTWARE would land in WOW6432Node).
    [Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess
}

function Register-AcmpResult {
    # Records the result of this run; the single exit point (Exit-AcmpHostRename) prints and returns it.
    param([Parameter(Mandatory)][string]$AcmpPhase, [Parameter(Mandatory)][int]$AcmpCode, [string]$AcmpMessage = '')
    $script:AcmpResult = [pscustomobject]@{ Phase = $AcmpPhase; ExitCode = $AcmpCode; Step = $script:AcmpStep; Message = $AcmpMessage }
}

function Invoke-AcmpSubScript {
    # Runs a script from the folder of this script in this process. Its output passes through (and is kept in
    # $script:AcmpOutput); its exit code ends up in $script:AcmpExit (1 if it threw or ended without an exit code).
    param([Parameter(Mandatory)][string]$AcmpScript, [hashtable]$AcmpParameters = @{})
    $acmpPath = Join-Path $PSScriptRoot $AcmpScript
    $script:AcmpOutput = @()
    if (-not [System.IO.File]::Exists($acmpPath)) {
        throw "$AcmpScript not found in '$PSScriptRoot'. Transfer it together with Invoke-AcmpHostRename.ps1."
    }
    Write-Output ('HOSTRENAME STEP={0} RUN={1}' -f $script:AcmpStep, $AcmpScript)
    $acmpSentinel = -2147483648
    $global:LASTEXITCODE = $acmpSentinel
    try {
        & $acmpPath @AcmpParameters | ForEach-Object { $script:AcmpOutput += [string]$_; $_ }
        $acmpCode = $global:LASTEXITCODE
        if ($acmpCode -eq $acmpSentinel) {
            Write-Output "[ERROR] $AcmpScript ended without an exit code (see the messages above)."
            $acmpCode = 1
        }
    }
    catch {
        Write-Output "[ERROR] $AcmpScript failed: $($_.Exception.Message)"
        $acmpCode = 1
    }
    $script:AcmpExit = [int]$acmpCode
}

function Get-AcmpOutputLine {
    # Last line of the previous script output that matches the pattern ('' if none)
    param([Parameter(Mandatory)][string]$AcmpPattern)
    $acmpHit = @($script:AcmpOutput | Where-Object { $_ -match $AcmpPattern })
    if ($acmpHit.Count) { return $acmpHit[$acmpHit.Count - 1] }
    ''
}

function Exit-AcmpHostRename {
    # Single exit point: prints the summary line (always the last line) and ends with the exit code.
    $acmpR = $script:AcmpResult
    if (-not $acmpR) { $acmpR = [pscustomobject]@{ Phase = 'Error'; ExitCode = 1; Step = $script:AcmpStep; Message = 'No result recorded.' } }
    $acmpText = (([string]$acmpR.Message) -replace '[\r\n]+', ' ' -replace '"', "'").Trim()
    Write-Output ('HOSTRENAME PHASE={0} EXIT={1} STEP={2} MESSAGE="{3}"' -f $acmpR.Phase, $acmpR.ExitCode, $acmpR.Step, $acmpText)
    exit $acmpR.ExitCode
}

function Invoke-AcmpFlow {
    # The flow of docs/acmp-guide.md, section 4. Sets $script:AcmpResult and returns at the first decision.

    # 1. Platform: before anything else (a 32-bit process would read and write the WOW6432Node view)
    $script:AcmpStep = 'Platform'
    if (Test-Wow64Process) {
        Write-Output '[ERROR] PLATFORM: HostRename runs in a 32-bit PowerShell on 64-bit Windows; registry values would be redirected to WOW6432Node. Start %SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe from the 32-bit ACMP agent. Nothing was changed.'
        Register-AcmpResult Error 1 'PLATFORM: 32-bit PowerShell on 64-bit Windows; use %SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe'
        return
    }

    # 2. Parameters
    $script:AcmpStep = 'Parameters'
    $acmpLogPath = ([string]$CentralLogPath).Trim()
    $acmpHasLogPath = $AcmpBound.ContainsKey('CentralLogPath') -and $acmpLogPath -and $acmpLogPath -notin "''", '""'
    if ([bool]$NoCentralLog -eq [bool]$acmpHasLogPath) {
        $acmpWhy = if ($NoCentralLog) { 'both were given' } else { 'none was given (or -CentralLogPath is blank)' }
        Write-Output "[ERROR] PARAMETERS: pass exactly one of -NoCentralLog or -CentralLogPath <UNC path>; $acmpWhy."
        Register-AcmpResult Error 1 "Pass exactly one of -NoCentralLog or -CentralLogPath; $acmpWhy."
        return
    }
    if ($RemoveOldCertificates -and -not $CertificateTemplate) {
        Write-Output '[ERROR] PARAMETERS: -RemoveOldCertificates needs -CertificateTemplate.'
        Register-AcmpResult Error 1 '-RemoveOldCertificates needs -CertificateTemplate.'
        return
    }
    $acmpRename = @{ Deployment = 'Acmp' }
    foreach ($acmpN in 'NameTemplate', 'Prefix', 'Suffix', 'OnTooLong', 'OnSerialProblem', 'FutureIdLength') {
        if ($AcmpBound.ContainsKey($acmpN)) { $acmpRename[$acmpN] = $AcmpBound[$acmpN] }
    }
    if ($NoCentralLog) { $acmpRename['NoCentralLog'] = $true } else { $acmpRename['CentralLogPath'] = $acmpLogPath }
    $acmpGate = @{}
    foreach ($acmpN in 'Allow', 'CorporateSsid', 'DomainName') {
        if ($AcmpBound.ContainsKey($acmpN)) { $acmpGate[$acmpN] = $AcmpBound[$acmpN] }
    }

    # 3. State check (read-only; same rules as the step-1 snippet in docs/acmp-guide.md)
    $script:AcmpStep = 'StateCheck'
    if (Test-Path $AcmpMarkerKey) {
        Register-AcmpResult Done 0 "Done: marker $AcmpMarkerKey exists; nothing to do."
        return
    }
    $acmpState = Get-ItemProperty $AcmpStateKey -ErrorAction SilentlyContinue
    if ($acmpState.LastExitCode -in 2, 4, 5) {
        $acmpCode = [int]$acmpState.LastExitCode
        Register-AcmpResult Permanent $acmpCode "Permanent error from an earlier run (LastExitCode $acmpCode); nothing runs until the cause is fixed and the device is released: Remove-ItemProperty -Path HKLM:\SOFTWARE\HostRenameState -Name LastExitCode"
        return
    }
    $acmpAfterReboot = [bool]($acmpState.TargetName -and $env:COMPUTERNAME -ieq $acmpState.TargetName)

    # 4. Gate
    $script:AcmpStep = 'Gate'
    Invoke-AcmpSubScript 'Test-DeploymentNetwork.ps1' $acmpGate
    $acmpCode = $script:AcmpExit
    if ($acmpCode -ne 0) {
        $acmpWhat = [regex]::Match((Get-AcmpOutputLine '^RESULT='), '^RESULT=(\S+)').Groups[1].Value
        if (-not $acmpWhat) { $acmpWhat = 'unknown' }
        $acmpText = switch ($acmpCode) {
            20      { 'only the corporate WLAN: ask the user to connect a LAN cable; retry later' }
            21      { 'no domain connection; retry later' }
            22      { 'network path not allowed or unknown; retry later' }
            1       { 'gate error; retry later' }
            default { "unexpected gate exit code $acmpCode, reported as 1; retry later" }
        }
        if ($acmpCode -notin 1, 20, 21, 22) { $acmpCode = 1 }
        Register-AcmpResult Gate $acmpCode "Gate RESULT=${acmpWhat}: $acmpText."
        return
    }

    # Dry run: only the -WhatIf run of Invoke-HostRename.ps1 (both phases), no certificate, no cleanup
    if ($AcmpDryRun) {
        $script:AcmpStep = 'Rename'
        Invoke-AcmpSubScript 'Invoke-HostRename.ps1' ($acmpRename + @{ WhatIf = $true })
        $acmpCode = $script:AcmpExit
        if ($acmpCode -notin 0, 1, 2, 4, 5) { $acmpCode = 1 }
        $acmpWhat = [regex]::Match((Get-AcmpOutputLine 'WHATIF: '), 'WHATIF: (.*)$').Groups[1].Value
        if (-not $acmpWhat) {
            $acmpWhat = if ($script:AcmpExit -eq 0) { 'nothing to do' } else { "Invoke-HostRename.ps1 -WhatIf ended with exit code $($script:AcmpExit); see the output above" }
        }
        $acmpPhaseText = if ($acmpAfterReboot) { 'after reboot' } else { 'rename' }
        Register-AcmpResult DryRun $acmpCode "Dry run (phase $acmpPhaseText): $acmpWhat"
        return
    }

    # 5. Rename
    if (-not $acmpAfterReboot) {
        $script:AcmpStep = 'Rename'
        Invoke-AcmpSubScript 'Invoke-HostRename.ps1' $acmpRename
        $acmpCode = $script:AcmpExit
        if ($acmpCode -eq 3010) { Register-AcmpResult RebootRequired 3010 'Renamed or rename pending: reboot required.'; return }
        if ($acmpCode -in 2, 4, 5) {
            Register-AcmpResult Permanent $acmpCode "Permanent error (exit $acmpCode); fix the cause, then release the device by removing HostRenameState\LastExitCode."
            return
        }
        if ($acmpCode -eq 1) { Register-AcmpResult Rename 1 'Rename failed; retry on the next run (details above and in the local log).'; return }
        if ($acmpCode -ne 0) { Register-AcmpResult Rename 1 "Unexpected exit code $acmpCode from Invoke-HostRename.ps1, reported as 1; retry on the next run."; return }
        # 0: the name already fits; continue with certificate and cleanup in this run
    }

    # 6. Certificate (WLAN devices only)
    if ($CertificateTemplate) {
        $script:AcmpStep = 'Certificate'
        Invoke-AcmpSubScript 'Update-ComputerCertificate.ps1' @{ Template = $CertificateTemplate; RemoveOld = [bool]$RemoveOldCertificates }
        if ($script:AcmpExit -ne 0) {
            $acmpWhat = [regex]::Match((Get-AcmpOutputLine '^RESULT='), '^RESULT=(\S+)').Groups[1].Value
            if (-not $acmpWhat) { $acmpWhat = 'unknown' }
            Register-AcmpResult Certificate 1 "Certificate RESULT=${acmpWhat}: not renewed; no cleanup, retry on the next run."
            return
        }
    }

    # 7. Cleanup
    $script:AcmpStep = 'Cleanup'
    Invoke-AcmpSubScript 'Invoke-HostRename.ps1' ($acmpRename + @{ Cleanup = $true })
    $acmpCode = $script:AcmpExit
    if ($acmpCode -eq 0) {
        if (Test-Path $AcmpMarkerKey) { Register-AcmpResult Done 0 'Cleanup done: marker set; the device is done.' }
        else { Register-AcmpResult Cleanup 0 'Cleanup deferred (marker not set yet, e.g. central log unreachable); the next run completes it.' }
    }
    elseif ($acmpCode -eq 3010) { Register-AcmpResult RebootRequired 3010 'Reboot required (reported by the cleanup run).' }
    elseif ($acmpCode -in 2, 4, 5) { Register-AcmpResult Permanent $acmpCode "Permanent error (exit $acmpCode) in the cleanup run; fix the cause, then release the device by removing HostRenameState\LastExitCode." }
    else { Register-AcmpResult Cleanup 1 "Cleanup ended with exit code $acmpCode; retry on the next run." }
}

# ---- Main ------------------------------------------------------------------------------
try {
    Invoke-AcmpFlow
}
catch {
    Write-Output "[ERROR] Unexpected error in step $($script:AcmpStep): $($_.Exception.Message)"
    Register-AcmpResult Error 1 "Unexpected error in step $($script:AcmpStep): $($_.Exception.Message)"
}
Exit-AcmpHostRename
