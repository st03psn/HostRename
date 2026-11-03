<#
.SYNOPSIS
    HostRename - Diagnostics: narrows down on copies of the GPO which part causes the GPMC report error, and tests constructions for the immediate start.

.DESCRIPTION
    The GPMC report ("Settings" tab) of the GPO shows the German GPMC message "Unbekannter Fehler bei der Erstellung des HTML-Berichts"
    (unknown error while creating the HTML report), although the GPO works on the clients. This script finds out which part of the GPO
    triggers the error. The real GPO is left untouched: the script creates several copies of it (TEST-HostRename-V0 to V10), changes
    exactly one point in each copy, generates the HTML report and deletes the copies again.

    VARIANTS
      V0  unchanged (control; must show the error, otherwise the cmdlet report does not reproduce the GPMC problem)
      V1  task description without brackets
      V2  without registration trigger
      V3  account "NT AUTHORITY\System" instead of SYSTEM and SID
      V4  file copy with action Update instead of Replace
      V5  V1, V2 and V3 together
      V6  without item-level targeting (marker condition)
      V7  file copy only (task removed)
      V8  task only (file copy removed)
      V9  without repetition on the daily trigger
      V10 registration trigger without delay (Delay element removed)

    EVALUATION
      The variant in which the report works again names the cause. If several work, the change of the first (smallest) variant is
      effective; V5 shows whether several points together are needed to trigger the error. V7 and V8 narrow down which of the two
      preferences contains the error. If no variant works, the cause is not among these points, possibly in the GPMC itself: in that
      case check the "Settings" tab of any other GPO.

    CANDIDATES FOR THE IMMEDIATE START (-Candidates)
      With -Candidates the script, instead of the troubleshooting, tests which constructions that start the task shortly after its
      creation the GPMC report tolerates. For this it replaces the triggers in the copies (TEST-HostRename-K0 to K7):
        K0  system startup trigger only, action Create (default 1.1.7 and 1.1.8; control, must work)
        K1  system startup + registration trigger (2 minutes), action Create
        K2  registration trigger only (2 minutes), action Create
        K3  registration trigger before the system startup trigger, action Create
        K4  system startup + registration trigger without delay, action Create (default since 1.1.9)
        K5  like K1, but action Update (the form up to version 1.1.5)
        K6  system startup task plus an Immediate Task (ImmediateTaskV2)
        K7  Immediate Task only (scheduled task removed)
      The candidates with "Report OK" are usable for the immediate start. The GPO itself is not modified.

    If V0 already produces no error, the cmdlet report does not reproduce the GPMC problem. In that case start with -Keep and look at the
    "Settings" tab of the copies in the GPMC; delete the copies afterwards:
      Get-GPO -All | Where-Object DisplayName -like 'TEST-HostRename-*' | Remove-GPO

.PARAMETER SourceGpo
    Name of the GPO to be tested (default: COMP - HostRename).

.PARAMETER Keep
    Do not delete the copies, so that their report can be viewed in the GPMC.

.PARAMETER Candidates
    Instead of the troubleshooting, test the candidates for the immediate start (K0 to K7, see description).

.EXAMPLE
    .\Test-GpoReport.ps1

    Tests the GPO "COMP - HostRename" and cleans up the copies afterwards.

.EXAMPLE
    .\Test-GpoReport.ps1 -SourceGpo 'COMP - HostRename' -Keep

    Keeps the copies so they can be opened in the GPMC.

.EXAMPLE
    .\Test-GpoReport.ps1 -Candidates

    Tests which constructions for the immediate start the GPMC report tolerates.

.NOTES
    Product          HostRename
    Version          1.2.0
    Date             2026-11-03
    Run on           Elevated Windows PowerShell 5.1 on a DC or admin PC (GroupPolicy and ActiveDirectory modules),
                     account with the right to create and delete GPOs (domain admin)
    Encoding         UTF-8 with BOM (required for Windows PowerShell 5.1)

#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$SourceGpo = 'COMP - HostRename',
    [switch]$Keep,
    [switch]$Candidates
)

$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSEdition -eq 'Core') {
    throw 'Please run in Windows PowerShell 5.1 (GroupPolicy module): powershell.exe -ExecutionPolicy Bypass -File .\Test-GpoReport.ps1'
}
Import-Module GroupPolicy, ActiveDirectory

$srv  = (Get-ADDomain).PDCEmulator
$dom  = (Get-ADDomain).DNSRoot
$utf8 = New-Object System.Text.UTF8Encoding($false)

# ---- Variants ----------------------------------------------------------------------------------------------------------
# Each variant changes exactly one point (V5: three together). $t = ScheduledTasks.xml, $f = Files.xml.
# A return value of 'DROP-TASKS' or 'DROP-FILES' removes the respective file from the copy.
$noBraces = { param($t, $f) $n = $t.SelectSingleNode("//*[local-name()='Description']"); $n.InnerText = $n.InnerText -replace '[{}\[\]]', '' }
$noRegTr  = { param($t, $f) $n = $t.SelectSingleNode('//RegistrationTrigger'); if ($n) { [void]$n.ParentNode.RemoveChild($n) } }
$oldAcct  = { param($t, $f) $t.SelectSingleNode('//Properties').SetAttribute('runAs', 'NT AUTHORITY\System'); $t.SelectSingleNode('//UserId').InnerText = 'NT AUTHORITY\System' }
$noRegDly = { param($t, $f) foreach ($n in @($t.SelectNodes('//RegistrationTrigger/Delay'))) { [void]$n.ParentNode.RemoveChild($n) } }
$noRepeat = { param($t, $f) foreach ($n in @($t.SelectNodes('//Repetition'))) { [void]$n.ParentNode.RemoveChild($n) } }
$noIlt    = { param($t, $f) foreach ($d in @($t, $f)) { foreach ($n in @($d.SelectNodes('//Filters'))) { [void]$n.ParentNode.RemoveChild($n) } } }
$variants = [ordered]@{
    'V0 unchanged (control)'                          = { param($t, $f) }
    'V1 description without brackets'                = $noBraces
    'V2 without registration trigger'               = $noRegTr
    'V3 account "NT AUTHORITY\System" instead of SYSTEM/SID' = $oldAcct
    'V4 file copy with action Update instead of Replace' = { param($t, $f) $e = $f.SelectSingleNode('//File'); $e.SetAttribute('image', '2'); $e.SelectSingleNode('Properties').SetAttribute('action', 'U') }
    'V5 V1 + V2 + V3 together'                       = { param($t, $f) & $noBraces $t $f; & $noRegTr $t $f; & $oldAcct $t $f }
    'V6 without item-level targeting'               = $noIlt
    'V7 file copy only (task removed)'              = { param($t, $f) 'DROP-TASKS' }
    'V8 task only (file copy removed)'              = { param($t, $f) 'DROP-FILES' }
    'V9 without repetition on the daily trigger'    = $noRepeat
    'V10 registration without delay (Delay removed)' = $noRegDly
}

# ---- Candidates for the immediate start (-Candidates) ------------------------------------------------------------------------
# Each candidate replaces the triggers of the copy and sets the GPP action; K6 and K7 add an Immediate Task (ImmediateTaskV2).
$bootXml   = '<BootTrigger><Enabled>true</Enabled><Delay>PT5M</Delay></BootTrigger>'
$regXml    = '<RegistrationTrigger><Enabled>true</Enabled><Delay>PT2M</Delay></RegistrationTrigger>'
$regNoDly  = '<RegistrationTrigger><Enabled>true</Enabled></RegistrationTrigger>'
$setTrig   = { param($t, $xml, $action) $t.SelectSingleNode('//TaskV2/Properties/Task/Triggers').InnerXml = $xml; $t.SelectSingleNode('//TaskV2/Properties').SetAttribute('action', $action) }
$addNow    = {
    # Immediate Task modeled on a file written by the GPMC: own element name and CLSID, image 0, time trigger with the
    # placeholders %LocalTimeXmlEx% (the GPP extension inserts the time when applying) and DeleteExpiredTaskAfter PT0S.
    param($t)
    $src = $t.SelectSingleNode('//TaskV2')
    $imm = $t.CreateElement('ImmediateTaskV2')
    $imm.SetAttribute('clsid', '{9756B581-76EC-4169-9AFC-0CA8D43ADB5F}')
    $imm.SetAttribute('name', 'HostRename-Sofort')
    $imm.SetAttribute('image', '0')
    $imm.SetAttribute('changed', $src.GetAttribute('changed'))
    $imm.SetAttribute('uid', '{' + [guid]::NewGuid().ToString().ToUpper() + '}')
    $imm.SetAttribute('userContext', '0')
    $imm.SetAttribute('removePolicy', '0')
    $imm.InnerXml = $src.InnerXml
    $p = $imm.SelectSingleNode('Properties')
    $p.SetAttribute('name', 'HostRename-Sofort'); $p.SetAttribute('action', 'C')
    $imm.SelectSingleNode('Properties/Task/Triggers').InnerXml = '<TimeTrigger><StartBoundary>%LocalTimeXmlEx%</StartBoundary><EndBoundary>%LocalTimeXmlEx%</EndBoundary><Enabled>true</Enabled></TimeTrigger>'
    $del = $t.CreateElement('DeleteExpiredTaskAfter'); $del.InnerText = 'PT0S'
    [void]$imm.SelectSingleNode('Properties/Task/Settings').AppendChild($del)
    [void]$src.ParentNode.InsertAfter($imm, $src)
}
$candidateVariants = [ordered]@{
    'K0 system startup only (control), Create'       = { param($t, $f) & $setTrig $t $bootXml 'C' }
    'K1 system startup + registration (2 min), Create' = { param($t, $f) & $setTrig $t ($bootXml + $regXml) 'C' }
    'K2 registration only (2 min), Create'         = { param($t, $f) & $setTrig $t $regXml 'C' }
    'K3 registration before system startup, Create' = { param($t, $f) & $setTrig $t ($regXml + $bootXml) 'C' }
    'K4 system startup + registration without delay' = { param($t, $f) & $setTrig $t ($bootXml + $regNoDly) 'C' }
    'K5 like K1, but action Update (form up to 1.1.5)' = { param($t, $f) & $setTrig $t ($bootXml + $regXml) 'U' }
    'K6 system startup task + Immediate Task'       = { param($t, $f) & $setTrig $t $bootXml 'C'; & $addNow $t }
    'K7 Immediate Task only (task removed)'         = { param($t, $f) & $setTrig $t $bootXml 'C'; & $addNow $t; $x = $t.SelectSingleNode('//TaskV2'); [void]$x.ParentNode.RemoveChild($x) }
}

function Save-Xml($doc, $path) {      # UTF-8 without BOM; the document's XML declaration is preserved
    $w = New-Object Xml.XmlWriterSettings; $w.Encoding = $utf8; $w.Indent = $false
    $xw = [Xml.XmlWriter]::Create($path, $w); try { $doc.Save($xw) } finally { $xw.Dispose() }
}

# ---- Main flow -------------------------------------------------------------------------------------------------------------
if ($Candidates) { $set = $candidateVariants; $tag = 'K' } else { $set = $variants; $tag = 'V' }
$last = $set.Count - 1
$results = @()
$i = 0
foreach ($name in $set.Keys) {
    $copy = "TEST-HostRename-$tag$i"; $i++
    try {
        Copy-GPO -SourceName $SourceGpo -TargetName $copy -SourceDomainController $srv -TargetDomainController $srv | Out-Null
        $gpo   = Get-GPO -Name $copy -Server $srv
        $base  = "\\$srv\SYSVOL\$dom\Policies\$($gpo.Id.ToString('B').ToUpper())\Machine\Preferences"
        $tPath = "$base\ScheduledTasks\ScheduledTasks.xml"
        $fPath = "$base\Files\Files.xml"
        $t = New-Object Xml.XmlDocument; $t.Load($tPath)
        $f = New-Object Xml.XmlDocument; $f.Load($fPath)
        $drop = & $set[$name] $t $f
        Save-Xml $t $tPath; Save-Xml $f $fPath
        if ($drop -eq 'DROP-TASKS') { Remove-Item -Path $tPath -Force }
        if ($drop -eq 'DROP-FILES') { Remove-Item -Path $fPath -Force }

        $html = Join-Path $env:TEMP "$copy.html"
        try   { Get-GPOReport -Guid $gpo.Id -Server $srv -ReportType Html -Path $html -ErrorAction Stop; $ok = $true;  $text = 'Report OK' }
        catch { $ok = $false; $text = 'ERROR: ' + $_.Exception.Message }
        if ($ok -and -not $Keep) { Remove-Item -Path $html -Force -ErrorAction SilentlyContinue }
    }
    catch { $ok = $false; $text = 'ABORTED during preparation: ' + $_.Exception.Message }
    finally { if (-not $Keep -and (Get-GPO -Name $copy -Server $srv -ErrorAction SilentlyContinue)) { Remove-GPO -Name $copy -Server $srv } }

    $results += [pscustomobject]@{ Name = $name; Ok = $ok }
    '{0,-52} {1}' -f $name, $text
}

# ---- Summary ----------------------------------------------------------------------------------------------------
''
if ($Candidates) {
    $good = @($results | Select-Object -Skip 1 | Where-Object Ok | ForEach-Object { ($_.Name -split ' ')[0] })
    $bad  = @($results | Select-Object -Skip 1 | Where-Object { -not $_.Ok } | ForEach-Object { ($_.Name -split ' ')[0] })
    if (-not $results[0].Ok) { 'K0 (system startup trigger only) already produces an error: the control is invalid. Check the source GPO and the "Settings" tab of another GPO.' }
    else {
        'Report OK for     : ' + $(if ($good.Count) { $good -join ', ' } else { '(no candidate)' })
        'Report ERROR for  : ' + $(if ($bad.Count)  { $bad -join ', ' }  else { '(no candidate)' })
        'The candidates with "Report OK" can be used for the immediate start.'
    }
}
elseif ($results[0].Ok) {
    'V0 (unchanged) produces no error: the cmdlet report does not reproduce the GPMC problem.'
    ('Start with -Keep and look at the "Settings" tab of the copies TEST-HostRename-V0 to V{0} in the GPMC.' -f $last)
}
else {
    $good = @($results | Select-Object -Skip 1 | Where-Object Ok | ForEach-Object { ($_.Name -split ' ')[0] })
    if ($good.Count) { 'The report works in: ' + ($good -join ', ') + '  -> the change of the first of these variants names the cause.' }
    else             { 'The report works in no variant: the cause is not among these points, possibly in the GPMC itself (check the "Settings" tab of another GPO).' }
}
if ($Keep) { 'The copies TEST-HostRename-{0}0 to {0}{1} were kept. To delete them: Get-GPO -All | Where-Object DisplayName -like ''TEST-HostRename-*'' | Remove-GPO' -f $tag, $last }
