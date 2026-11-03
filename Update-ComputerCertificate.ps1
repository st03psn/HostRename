<#
.SYNOPSIS
    Requests a new machine certificate from an AD CS template when the existing one does not carry the
    current DNS name of the computer (e.g. after a rename), and optionally removes the outdated ones.

.DESCRIPTION
    Reusable building block, meant to run as SYSTEM (e.g. from ACMP) after a computer rename, while the device
    is connected over LAN or DirectAccess. Since the full enforcement of KB5014754 (strong certificate mapping),
    EAP-TLS WLAN authentication with a machine certificate that still carries the old computer name fails.
    This script makes sure that LocalMachine\My holds a valid certificate of the given template for the
    expected DNS name.

    FLOW
      1. Determine the expected DNS name (-ExpectedDnsName or <host name>.<machine domain>). If a computer
         rename is still pending (no restart yet), stop with exit code 1: the CA would issue the certificate
         for the new name while the device still runs under the old one.
      2. Find the certificates of the template in LocalMachine\My (see TEMPLATE DETECTION).
      3. If one of them contains the expected DNS name in its Subject Alternative Name, has a private key and
         is valid for more than -MinValidDays days, nothing is requested (RESULT=NOT_NEEDED).
      4. Otherwise a new certificate is requested with Get-Certificate (PKI module) in the machine context.
         Only the status "Issued" counts as success. The new certificate must contain the expected DNS name
         and have a private key, otherwise exit code 1.
      5. Only with -RemoveOld and only after step 3 or 4 confirmed a valid certificate for the expected name:
         remove the other certificates of the same template whose SAN does not contain the expected DNS name
         (including their private keys). Certificates of other templates are never touched.

    TEMPLATE DETECTION
      A certificate counts as issued from -Template if one of these applies:
        - Extension 1.3.6.1.4.1.311.20.2 (template name, version 1 templates) equals -Template.
        - Extension 1.3.6.1.4.1.311.21.7 (template information, version 2+ templates) contains the template
          OID, and that OID is known: read from Active Directory (msPKI-Cert-Template-OID of the template in
          the configuration partition) or taken from a certificate just issued from the template.
        - The formatted text of extension 1.3.6.1.4.1.311.21.7 shows "<Template>(<OID>)".

    LIMITATIONS
      - Extension 1.3.6.1.4.1.311.21.7 only contains the OID, not the template name. If the OID cannot be read
        from AD and the formatted text shows the display name (usual case) instead of the template name,
        existing version 2+ certificates are not recognised. Then a new certificate is requested once; after
        that the OID is known from the new certificate and -RemoveOld works as intended.
      - The DNS names are read from the SAN (dNSName entries) with a small DER parser, independent of the
        system language. Only if there is no SAN extension (or it cannot be parsed) the first DNS name from
        X509Certificate2.GetNameInfo (usually the subject CN) is used.
      - A request that ends as "Pending" (CA manager approval) is not tracked; the next run submits a new one.
      - Whether the CA adds the SID extension (1.3.6.1.4.1.311.25.2) for strong mapping is not checked.
      - Windows only (PKI module, certificate provider, CIM, registry). On other systems the script ends with
        exit code 1.

    OUTPUT
      Progress lines go to the host; the last line on stdout is a summary for the deployment tool, e.g.
      RESULT=RENEWED EXIT=0 TEMPLATE=Workstation DNS=pc0815.corp.example THUMBPRINT=... NOTAFTER=2027-11-03 REMOVED=1 MESSAGE="..."
      RESULT is RENEWED, NOT_NEEDED, WHATIF or ERROR.

.PARAMETER Template
    Name of the certificate template (the template name, not the display name), e.g. "Workstation".

.PARAMETER ExpectedDnsName
    DNS name the certificate must contain. Default: <host name>.<machine domain> (Win32_ComputerSystem).
    Comparisons are case-insensitive; a trailing dot is ignored.

.PARAMETER RemoveOld
    Removes other certificates of the same template from LocalMachine\My whose SAN does not contain the
    expected DNS name, together with their private keys. Only after a valid certificate for the expected name
    was confirmed. Without this switch no certificate is removed.

.PARAMETER MinValidDays
    An existing matching certificate that is valid for more than this number of days counts as current, and no
    new certificate is requested (default 30).

.EXAMPLE
    .\Update-ComputerCertificate.ps1 -Template Workstation -WhatIf
    Shows whether a certificate would be requested, without changing anything.

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Update-ComputerCertificate.ps1 -Template Workstation -RemoveOld
    Requests a certificate if needed and removes the certificates of the template with the old name.

.OUTPUTS
    Exit codes:
      0       certificate renewed, renewal not needed, or -WhatIf (see RESULT in the summary line)
      1       error, retry later (no domain, pending rename, enrollment failed/pending/denied, new certificate
              does not match, removal failed)

.NOTES
    Product          HostRename
    Version          1.2.0
    Date             2026-11-03
    Execution        SYSTEM (e.g. ACMP) or manually as administrator, after the restart following a rename
    Encoding         UTF-8 with BOM (required by Windows PowerShell 5.1)

.LINK
    docs/ACMP-Umsetzungsplan.md
#>
#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Template,

    [string]$ExpectedDnsName = '',

    [switch]$RemoveOld,

    [ValidateRange(0, 3650)]
    [int]$MinValidDays = 30
)

$OidSan              = '2.5.29.17'
$OidTemplateName     = '1.3.6.1.4.1.311.20.2'
$OidTemplateInfo     = '1.3.6.1.4.1.311.21.7'

#region Helpers

function Write-Log {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )
    Write-Host ('{0} {1,-5} {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message)
}

function ConvertTo-NormalizedDnsName {
    # Lower case, without surrounding blanks and trailing dot
    param([string]$Name)
    if ($null -eq $Name) { return '' }
    return $Name.Trim().TrimEnd('.').ToLowerInvariant()
}

#endregion

#region DER parsing (language independent, no Windows dependency)

function Get-DerElement {
    # Reads tag and length of the DER element at $Offset. Returns Tag, ValueOffset, Length, NextOffset.
    param(
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [int]$Offset = 0
    )
    if ($Offset -lt 0 -or $Offset + 2 -gt $Bytes.Length) { throw "DER: truncated data at offset $Offset." }
    $tag = [int]$Bytes[$Offset]
    if (($tag -band 0x1F) -eq 0x1F) { throw "DER: multi-byte tag at offset $Offset is not supported." }
    $lengthByte = [int]$Bytes[$Offset + 1]
    $pos = $Offset + 2
    if ($lengthByte -lt 0x80) {
        $length = [long]$lengthByte
    }
    elseif ($lengthByte -eq 0x80) {
        throw "DER: indefinite length at offset $Offset is not allowed."
    }
    else {
        $count = $lengthByte -band 0x7F
        if ($count -gt 4) { throw "DER: length field at offset $Offset is too long." }
        if ($pos + $count -gt $Bytes.Length) { throw "DER: truncated length at offset $Offset." }
        $length = [long]0
        for ($i = 0; $i -lt $count; $i++) {
            $length = $length * 256 + [long]$Bytes[$pos]
            $pos++
        }
    }
    if ($pos + $length -gt $Bytes.Length) { throw "DER: element at offset $Offset exceeds the data (length $length)." }
    [pscustomobject]@{
        Tag         = $tag
        ValueOffset = $pos
        Length      = [int]$length
        NextOffset  = $pos + [int]$length
    }
}

function ConvertFrom-DerOid {
    # Decodes the content octets of an OBJECT IDENTIFIER into dotted notation.
    param(
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [int]$Offset = 0,
        [int]$Length = -1
    )
    if ($Length -lt 0) { $Length = $Bytes.Length - $Offset }
    if ($Length -lt 1 -or $Offset + $Length -gt $Bytes.Length) { throw 'DER: invalid OBJECT IDENTIFIER length.' }
    $arcs = New-Object System.Collections.Generic.List[string]
    $value = [uint64]0
    $digits = 0
    $first = $true
    for ($i = $Offset; $i -lt $Offset + $Length; $i++) {
        $b = [int]$Bytes[$i]
        $value = $value * 128 + [uint64]($b -band 0x7F)
        $digits++
        if ($digits -gt 9) { throw 'DER: OBJECT IDENTIFIER arc too large.' }
        if (($b -band 0x80) -eq 0) {
            if ($first) {
                if ($value -lt 40)     { $arcs.Add('0'); $arcs.Add([string]$value) }
                elseif ($value -lt 80) { $arcs.Add('1'); $arcs.Add([string]($value - 40)) }
                else                   { $arcs.Add('2'); $arcs.Add([string]($value - 80)) }
                $first = $false
            }
            else {
                $arcs.Add([string]$value)
            }
            $value = [uint64]0
            $digits = 0
        }
    }
    if ($digits -ne 0) { throw 'DER: OBJECT IDENTIFIER ends in the middle of an arc.' }
    return ($arcs -join '.')
}

function Get-SanDnsName {
    <#
    Returns all dNSName entries ([2] IA5String) of a Subject Alternative Name extension.
    $RawData is X509Extension.RawData (the DER SEQUENCE OF GeneralName). Other name types (IP address,
    e-mail, UPN, ...) are skipped. Throws on malformed data.
    #>
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$RawData)
    $outer = Get-DerElement -Bytes $RawData -Offset 0
    if ($outer.Tag -ne 0x30) { throw ('DER: SubjectAltName does not start with a SEQUENCE (tag 0x{0:X2}).' -f $outer.Tag) }
    if ($outer.NextOffset -ne $RawData.Length) { throw 'DER: unexpected data after the SubjectAltName SEQUENCE.' }
    $pos = $outer.ValueOffset
    while ($pos -lt $outer.NextOffset) {
        $element = Get-DerElement -Bytes $RawData -Offset $pos
        if ($element.NextOffset -gt $outer.NextOffset) { throw 'DER: GeneralName exceeds the SubjectAltName SEQUENCE.' }
        if ($element.Tag -eq 0x82) {
            [System.Text.Encoding]::ASCII.GetString($RawData, $element.ValueOffset, $element.Length)
        }
        $pos = $element.NextOffset
    }
}

function ConvertFrom-TemplateNameExtension {
    # Extension 1.3.6.1.4.1.311.20.2 (version 1 templates): a string, usually BMPString.
    param([Parameter(Mandatory = $true)][byte[]]$RawData)
    $element = Get-DerElement -Bytes $RawData -Offset 0
    switch ($element.Tag) {
        0x1E    { $encoding = [System.Text.Encoding]::BigEndianUnicode }   # BMPString
        0x0C    { $encoding = [System.Text.Encoding]::UTF8 }               # UTF8String
        0x13    { $encoding = [System.Text.Encoding]::ASCII }              # PrintableString
        0x16    { $encoding = [System.Text.Encoding]::ASCII }              # IA5String
        default { throw ('DER: unexpected string type 0x{0:X2} in the template name extension.' -f $element.Tag) }
    }
    return $encoding.GetString($RawData, $element.ValueOffset, $element.Length)
}

function ConvertFrom-TemplateInfoExtension {
    # Extension 1.3.6.1.4.1.311.21.7 (version 2+ templates):
    # SEQUENCE { templateID OBJECT IDENTIFIER, templateMajorVersion INTEGER, templateMinorVersion INTEGER OPTIONAL }
    param([Parameter(Mandatory = $true)][byte[]]$RawData)
    $outer = Get-DerElement -Bytes $RawData -Offset 0
    if ($outer.Tag -ne 0x30) { throw 'DER: template information does not start with a SEQUENCE.' }
    $oidElement = Get-DerElement -Bytes $RawData -Offset $outer.ValueOffset
    if ($oidElement.Tag -ne 0x06) { throw 'DER: template information does not contain an OBJECT IDENTIFIER.' }
    $oid = ConvertFrom-DerOid -Bytes $RawData -Offset $oidElement.ValueOffset -Length $oidElement.Length
    $versions = New-Object System.Collections.Generic.List[long]
    $pos = $oidElement.NextOffset
    while ($pos -lt $outer.NextOffset) {
        $element = Get-DerElement -Bytes $RawData -Offset $pos
        if ($element.Tag -eq 0x02 -and $element.Length -ge 1 -and $element.Length -le 4) {
            $v = [long]0
            for ($i = 0; $i -lt $element.Length; $i++) { $v = $v * 256 + [long]$RawData[$element.ValueOffset + $i] }
            $versions.Add($v)
        }
        $pos = $element.NextOffset
    }
    $major = $null; $minor = $null
    if ($versions.Count -ge 1) { $major = $versions[0] }
    if ($versions.Count -ge 2) { $minor = $versions[1] }
    [pscustomobject]@{ Oid = $oid; MajorVersion = $major; MinorVersion = $minor }
}

#endregion

#region Certificate evaluation (pure, testable on any platform)

function ConvertTo-CertificateInfo {
    # Reduces an X509Certificate2 to the properties the decisions need.
    param([Parameter(Mandatory = $true, ValueFromPipeline = $true)][System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate)
    process {
        $dnsNames = @()
        $sanParsed = $false
        $templateName = $null; $templateOid = $null; $templateText = $null
        foreach ($ext in $Certificate.Extensions) {
            $oid = $ext.Oid.Value
            try {
                if ($oid -eq $OidSan) {
                    $dnsNames = @(Get-SanDnsName -RawData $ext.RawData)
                    $sanParsed = $true
                }
                elseif ($oid -eq $OidTemplateName) {
                    $templateName = ConvertFrom-TemplateNameExtension -RawData $ext.RawData
                }
                elseif ($oid -eq $OidTemplateInfo) {
                    $templateText = $ext.Format($false)
                    $templateOid = (ConvertFrom-TemplateInfoExtension -RawData $ext.RawData).Oid
                }
            }
            catch {
                Write-Log -Level WARN -Message ("Certificate {0}: extension {1} could not be read: {2}" -f $Certificate.Thumbprint, $oid, $_.Exception.Message)
            }
        }
        if (-not $sanParsed) {
            # No (readable) SAN: first DNS name according to .NET, usually the subject CN
            $name = $Certificate.GetNameInfo([System.Security.Cryptography.X509Certificates.X509NameType]::DnsName, $false)
            if ($name) { $dnsNames = @($name) }
        }
        [pscustomobject]@{
            Thumbprint    = $Certificate.Thumbprint
            Subject       = $Certificate.Subject
            NotBefore     = $Certificate.NotBefore
            NotAfter      = $Certificate.NotAfter
            HasPrivateKey = $Certificate.HasPrivateKey
            DnsNames      = @($dnsNames | ForEach-Object { ConvertTo-NormalizedDnsName $_ } | Where-Object { $_ })
            TemplateName  = $templateName
            TemplateOid   = $templateOid
            TemplateText  = $templateText
        }
    }
}

function Test-TemplateMatch {
    # Is the certificate (info object) issued from $Template? See TEMPLATE DETECTION in the help.
    param(
        [Parameter(Mandatory = $true)]$Certificate,
        [Parameter(Mandatory = $true)][string]$Template,
        [string[]]$TemplateOid = @()
    )
    if ($Certificate.TemplateName -and $Certificate.TemplateName -eq $Template) { return $true }
    if ($Certificate.TemplateOid) {
        if (@($TemplateOid) -contains $Certificate.TemplateOid) { return $true }
        if ($Certificate.TemplateText) {
            $pattern = '(?i)(^|[\s=:,])' + [regex]::Escape($Template) + '\s*\(\s*' + [regex]::Escape($Certificate.TemplateOid) + '\s*\)'
            if ([regex]::IsMatch($Certificate.TemplateText, $pattern)) { return $true }
        }
    }
    return $false
}

function Get-TemplateCertificate {
    <#
    Returns info objects (ConvertTo-CertificateInfo) of the certificates issued from $Template.
    $Certificate: X509Certificate2 or info objects; without it, LocalMachine\My is read.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Template,
        [string[]]$TemplateOid = @(),
        [object[]]$Certificate
    )
    if (-not $PSBoundParameters.ContainsKey('Certificate')) { $Certificate = @(Get-MachineCertificate) }
    foreach ($c in @($Certificate)) {
        if ($null -eq $c) { continue }
        if ($c -is [System.Security.Cryptography.X509Certificates.X509Certificate2]) { $info = ConvertTo-CertificateInfo -Certificate $c }
        else { $info = $c }
        if (Test-TemplateMatch -Certificate $info -Template $Template -TemplateOid $TemplateOid) { $info }
    }
}

function Test-CertificateMatch {
    # True if the certificate contains the expected DNS name, has a private key and is valid for more than
    # $MinValidDays days from $Now.
    param(
        [Parameter(Mandatory = $true)]$Certificate,
        [Parameter(Mandatory = $true)][string]$ExpectedDnsName,
        [int]$MinValidDays = 0,
        [datetime]$Now = (Get-Date)
    )
    $expected = ConvertTo-NormalizedDnsName $ExpectedDnsName
    if (-not $expected) { return $false }
    if (-not $Certificate.HasPrivateKey) { return $false }
    if ($Certificate.NotBefore -gt $Now) { return $false }
    if ($Certificate.NotAfter -le $Now.AddDays($MinValidDays)) { return $false }
    $names = @($Certificate.DnsNames | ForEach-Object { ConvertTo-NormalizedDnsName $_ })
    return ($names -contains $expected)
}

function Select-ObsoleteCertificate {
    <#
    Returns the certificates (info objects) that -RemoveOld may remove: same template, not kept, and the SAN
    does not contain the expected DNS name (expired ones included). Returns nothing unless at least one kept
    certificate is in the list and contains the expected DNS name, so the only valid certificate is never
    removed.
    #>
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Certificate,
        [Parameter(Mandatory = $true)][string]$Template,
        [string[]]$TemplateOid = @(),
        [Parameter(Mandatory = $true)][string]$ExpectedDnsName,
        [string[]]$KeepThumbprint = @()
    )
    $expected = ConvertTo-NormalizedDnsName $ExpectedDnsName
    $keep = @($KeepThumbprint | Where-Object { $_ } | ForEach-Object { $_.ToUpperInvariant() })
    if (-not $expected -or $keep.Count -eq 0) { return }

    $keptValid = @($Certificate | Where-Object {
            $_ -and $keep -contains ([string]$_.Thumbprint).ToUpperInvariant() -and
            @($_.DnsNames | ForEach-Object { ConvertTo-NormalizedDnsName $_ }) -contains $expected
        })
    if ($keptValid.Count -eq 0) { return }

    foreach ($c in $Certificate) {
        if ($null -eq $c) { continue }
        if ($keep -contains ([string]$c.Thumbprint).ToUpperInvariant()) { continue }
        if (-not (Test-TemplateMatch -Certificate $c -Template $Template -TemplateOid $TemplateOid)) { continue }
        $names = @($c.DnsNames | ForEach-Object { ConvertTo-NormalizedDnsName $_ })
        if ($names -contains $expected) { continue }
        $c
    }
}

#endregion

#region System access (Windows only, mocked in the tests)

function Get-MachineCertificate {
    # All certificates in LocalMachine\My
    $store = New-Object System.Security.Cryptography.X509Certificates.X509Store('My', 'LocalMachine')
    $flags = [System.Security.Cryptography.X509Certificates.OpenFlags]'ReadOnly, OpenExistingOnly'
    $store.Open($flags)
    try { @($store.Certificates) }
    finally { $store.Close() }
}

function Remove-MachineCertificate {
    # Removes the certificate and its private key from LocalMachine\My
    param([Parameter(Mandatory = $true)][string]$Thumbprint)
    Remove-Item -Path ('Cert:\LocalMachine\My\' + $Thumbprint) -DeleteKey -ErrorAction Stop -WhatIf:$false -Confirm:$false
}

function Get-ExpectedDnsName {
    # <host name>.<machine domain> of the domain-joined computer
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
    if (-not $cs.PartOfDomain) { throw 'The computer is not joined to a domain.' }
    $hostName = $cs.DNSHostName
    if (-not $hostName) { $hostName = $env:COMPUTERNAME }
    if (-not $hostName -or -not $cs.Domain) { throw 'Host name or machine domain could not be determined.' }
    return (ConvertTo-NormalizedDnsName ('{0}.{1}' -f $hostName, $cs.Domain))
}

function Get-PendingComputerName {
    # New computer name if a rename waits for a restart, otherwise $null
    $base = 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName'
    $active  = (Get-ItemProperty -Path "$base\ActiveComputerName" -Name ComputerName -ErrorAction Stop).ComputerName
    $pending = (Get-ItemProperty -Path "$base\ComputerName" -Name ComputerName -ErrorAction Stop).ComputerName
    if ($pending -and $active -and $pending -ne $active) { return $pending }
    return $null
}

function Resolve-TemplateOid {
    # OID of the template from AD (msPKI-Cert-Template-OID); $null if it cannot be read
    param([Parameter(Mandatory = $true)][string]$Template)
    try {
        $rootDse = New-Object System.DirectoryServices.DirectoryEntry('LDAP://RootDSE')
        $config = [string]$rootDse.Properties['configurationNamingContext'].Value
        if (-not $config) { return $null }
        $base = New-Object System.DirectoryServices.DirectoryEntry("LDAP://CN=Certificate Templates,CN=Public Key Services,CN=Services,$config")
        $escaped = $Template -replace '\\', '\5c' -replace '\*', '\2a' -replace '\(', '\28' -replace '\)', '\29'
        $searcher = New-Object System.DirectoryServices.DirectorySearcher($base, "(&(objectClass=pKICertificateTemplate)(cn=$escaped))")
        [void]$searcher.PropertiesToLoad.Add('msPKI-Cert-Template-OID')
        $found = $searcher.FindOne()
        if ($found -and $found.Properties['mspki-cert-template-oid'].Count -gt 0) {
            return [string]$found.Properties['mspki-cert-template-oid'][0]
        }
        Write-Log -Level WARN -Message "Template '$Template' was not found in Active Directory."
    }
    catch {
        Write-Log -Level WARN -Message "Template OID could not be read from Active Directory: $($_.Exception.Message)"
    }
    return $null
}

function Request-TemplateCertificate {
    # Wraps Get-Certificate (PKI module). Returns Status (Issued, Pending, Denied, ..., Error), Certificate, Message.
    param([Parameter(Mandatory = $true)][string]$Template)
    try {
        Import-Module PKI -ErrorAction Stop
        $response = Get-Certificate -Template $Template -CertStoreLocation 'Cert:\LocalMachine\My' -ErrorAction Stop
        [pscustomobject]@{
            Status      = [string]$response.Status
            Certificate = $response.Certificate
            Message     = ''
        }
    }
    catch {
        [pscustomobject]@{
            Status      = 'Error'
            Certificate = $null
            Message     = $_.Exception.Message
        }
    }
}

#endregion

#region Orchestration

function Format-ResultLine {
    param([Parameter(Mandatory = $true)]$Result)
    $notAfter = ''
    if ($Result.NotAfter) { $notAfter = ([datetime]$Result.NotAfter).ToString('yyyy-MM-dd') }
    $message = ([string]$Result.Message) -replace '"', "'" -replace '\r?\n', ' '
    'RESULT={0} EXIT={1} TEMPLATE={2} DNS={3} THUMBPRINT={4} NOTAFTER={5} REMOVED={6} MESSAGE="{7}"' -f
    $Result.Result, $Result.ExitCode, $Result.Template, $Result.DnsName, $Result.Thumbprint, $notAfter, $Result.Removed, $message
}

function Invoke-CertificateUpdate {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][string]$Template,
        [string]$ExpectedDnsName = '',
        [switch]$RemoveOld,
        [int]$MinValidDays = 30
    )
    $ErrorActionPreference = 'Stop'
    $result = [pscustomobject]@{
        Result     = 'ERROR'
        ExitCode   = 1
        Template   = $Template
        DnsName    = ''
        Thumbprint = ''
        NotAfter   = $null
        Removed    = 0
        Message    = ''
    }
    try {
        # 1. Expected name; no request while a rename waits for the restart
        if ($ExpectedDnsName) { $expected = ConvertTo-NormalizedDnsName $ExpectedDnsName }
        else { $expected = Get-ExpectedDnsName }
        $result.DnsName = $expected
        Write-Log "Template '$Template', expected DNS name '$expected', MinValidDays $MinValidDays, RemoveOld $([bool]$RemoveOld)."
        $pendingName = Get-PendingComputerName
        if ($pendingName) {
            $result.Message = "Computer rename to '$pendingName' is pending. Restart first, then run again."
            Write-Log -Level ERROR -Message $result.Message
            return $result
        }

        # 2. Existing certificates of the template
        $oids = New-Object System.Collections.Generic.List[string]
        $resolved = Resolve-TemplateOid -Template $Template
        if ($resolved) { $oids.Add($resolved); Write-Log "Template OID from Active Directory: $resolved" }
        $now = Get-Date
        $existing = @(Get-TemplateCertificate -Template $Template -TemplateOid $oids.ToArray())
        foreach ($c in $existing) {
            if ($c.TemplateOid -and -not $oids.Contains($c.TemplateOid)) { $oids.Add($c.TemplateOid) }
            Write-Log ("Found {0} DNS={1} NotAfter={2:yyyy-MM-dd} PrivateKey={3}" -f $c.Thumbprint, (@($c.DnsNames) -join ','), $c.NotAfter, $c.HasPrivateKey)
        }
        $current = @($existing | Where-Object { Test-CertificateMatch -Certificate $_ -ExpectedDnsName $expected -MinValidDays $MinValidDays -Now $now })

        if ($current.Count -gt 0) {
            # 3. Current certificate available
            $best = $current | Sort-Object -Property NotAfter -Descending | Select-Object -First 1
            $keep = @($current | ForEach-Object { $_.Thumbprint })
            $result.Result = 'NOT_NEEDED'; $result.ExitCode = 0
            $result.Thumbprint = $best.Thumbprint; $result.NotAfter = $best.NotAfter
            $result.Message = "Valid certificate for '$expected' exists (more than $MinValidDays days left)."
            Write-Log $result.Message
        }
        else {
            # 4. Request a new certificate
            if (-not $PSCmdlet.ShouldProcess('Cert:\LocalMachine\My', "Request certificate from template '$Template' for '$expected'")) {
                $result.Result = 'WHATIF'; $result.ExitCode = 0
                $result.Message = 'No valid certificate for the expected name; request skipped (WhatIf).'
                Write-Log $result.Message
                return $result
            }
            Write-Log "No valid certificate for '$expected'; requesting one from template '$Template'."
            $response = Request-TemplateCertificate -Template $Template
            if ($response.Status -ne 'Issued' -or -not $response.Certificate) {
                $result.Message = "Enrollment not completed: status '$($response.Status)'. $($response.Message)".Trim()
                Write-Log -Level ERROR -Message $result.Message
                return $result
            }
            $newThumbprint = $response.Certificate.Thumbprint
            $newInfo = @(Get-MachineCertificate | Where-Object { $_.Thumbprint -eq $newThumbprint } | ConvertTo-CertificateInfo) | Select-Object -First 1
            if (-not $newInfo) {
                Write-Log -Level WARN -Message "Issued certificate $newThumbprint not found in LocalMachine\My; checking the returned object."
                $newInfo = ConvertTo-CertificateInfo -Certificate $response.Certificate
            }
            $result.Thumbprint = $newThumbprint; $result.NotAfter = $newInfo.NotAfter
            if (-not (Test-CertificateMatch -Certificate $newInfo -ExpectedDnsName $expected -MinValidDays 0 -Now (Get-Date))) {
                $result.Message = "Issued certificate $newThumbprint does not match: DNS names '$(@($newInfo.DnsNames) -join ',')', private key $($newInfo.HasPrivateKey), valid $($newInfo.NotBefore) - $($newInfo.NotAfter). Nothing removed."
                Write-Log -Level ERROR -Message $result.Message
                return $result
            }
            if ($newInfo.TemplateOid -and -not $oids.Contains($newInfo.TemplateOid)) { $oids.Add($newInfo.TemplateOid) }
            if ($newInfo.NotAfter -le (Get-Date).AddDays($MinValidDays)) {
                Write-Log -Level WARN -Message "The new certificate is valid for less than $MinValidDays days; the next run will request another one."
            }
            $keep = @($newThumbprint)
            $result.Result = 'RENEWED'; $result.ExitCode = 0
            $result.Message = "New certificate issued for '$expected'."
            Write-Log "$($result.Message) Thumbprint $newThumbprint, valid until $($newInfo.NotAfter)."
        }

        # 5. Remove outdated certificates of the template
        if ($RemoveOld) {
            $all = @(Get-MachineCertificate | ConvertTo-CertificateInfo)
            $obsolete = @(Select-ObsoleteCertificate -Certificate $all -Template $Template -TemplateOid $oids.ToArray() -ExpectedDnsName $expected -KeepThumbprint $keep)
            $failed = 0
            foreach ($c in $obsolete) {
                $label = "{0} (DNS={1}, NotAfter={2:yyyy-MM-dd})" -f $c.Thumbprint, (@($c.DnsNames) -join ','), $c.NotAfter
                if (-not $PSCmdlet.ShouldProcess("Cert:\LocalMachine\My\$($c.Thumbprint)", "Remove certificate $label with private key")) { continue }
                try {
                    Remove-MachineCertificate -Thumbprint $c.Thumbprint
                    $result.Removed++
                    Write-Log "Removed certificate $label."
                }
                catch {
                    $failed++
                    Write-Log -Level ERROR -Message "Certificate $label could not be removed: $($_.Exception.Message)"
                }
            }
            if ($obsolete.Count -eq 0) { Write-Log 'No outdated certificates of the template found.' }
            if ($failed -gt 0) {
                $result.Result = 'ERROR'; $result.ExitCode = 1
                $result.Message = "$($result.Message) $failed outdated certificate(s) could not be removed."
            }
        }
    }
    catch {
        $result.Result = 'ERROR'; $result.ExitCode = 1
        $result.Message = $_.Exception.Message
        Write-Log -Level ERROR -Message $result.Message
    }
    return $result
}

#endregion

$result = Invoke-CertificateUpdate -Template $Template -ExpectedDnsName $ExpectedDnsName -RemoveOld:$RemoveOld -MinValidDays $MinValidDays -WhatIf:$WhatIfPreference
Write-Output (Format-ResultLine -Result $result)
exit $result.ExitCode
