<#
.SYNOPSIS
    HostRename - tests for Update-ComputerCertificate.ps1 (certificate renewal after a rename).

.DESCRIPTION
    Loads the functions of Update-ComputerCertificate.ps1 via the AST (the script body is not executed) and
    tests them with self-signed test certificates generated in memory. Needs no AD, no CA and no certificate
    store; runs on Windows and Linux (PowerShell 7). Nothing is written to a certificate store.

    TESTS
      1. DER parsing: SAN dNSName entries (built with SubjectAlternativeNameBuilder), OIDs, template extensions
      2. Certificate evaluation: template detection, Test-CertificateMatch, Select-ObsoleteCertificate
      3. Orchestration (Invoke-CertificateUpdate) with mocked store, AD lookup and enrollment
      4. Script: syntax, help, and on non-Windows systems a clean exit code 1

    NOT TESTED HERE
      Get-Certificate against a real AD CS, reading/removing in the real LocalMachine\My store, the AD lookup of
      the template OID, Get-ExpectedDnsName (CIM) and Get-PendingComputerName (registry).

.PARAMETER ScriptFolder
    Folder containing Update-ComputerCertificate.ps1 (default: the parent folder of the folder of this test file,
    i.e. components\).

.EXAMPLE
    Invoke-Pester -Path .\components\tests\HostRename.Certificate.Tests.ps1 -Output Detailed

.NOTES
    Product          HostRename
    Version          1.2.0
    Date             2026-11-03
    Execution        any user, Windows or Linux (Pester 5.3+)
    Encoding         UTF-8 with BOM (required for Windows PowerShell 5.1)

.LINK
    Update-ComputerCertificate.ps1
#>
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.3.0' }
#Requires -Version 5.1
param(
    [string]$ScriptFolder = ''
)

BeforeAll {
    $ScriptFolder = if ($ScriptFolder) { $ScriptFolder } else { Split-Path -Parent $PSScriptRoot }
    $script:CertScript = Join-Path $ScriptFolder 'Update-ComputerCertificate.ps1'

    # Load all functions of the script without running its body
    $tk = $null; $er = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:CertScript, [ref]$tk, [ref]$er)
    $fns = $ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            -not ($a.Parent -is [System.Management.Automation.Language.FunctionDefinitionAst]) }, $false)
    . ([scriptblock]::Create((($fns | ForEach-Object { $_.Extent.Text }) -join "`n")))

    $script:Domain  = 'corp.example'
    $script:OidV2   = '1.3.6.1.4.1.311.21.8.16187918.14945684.15749023.11519519.4925321.197.13392918.13544906'
    $script:OidOther = '1.3.6.1.4.1.311.21.8.16187918.14945684.15749023.11519519.4925321.197.1111111.2222222'

    function ConvertTo-DerLength {
        param([int]$Length)
        if ($Length -lt 0x80) { return , [byte[]]@($Length) }
        if ($Length -lt 0x100) { return , [byte[]]@(0x81, $Length) }
        return , [byte[]]@(0x82, [byte]($Length -shr 8), [byte]($Length -band 0xFF))
    }
    function New-DerElement {
        param([byte]$Tag, [byte[]]$Value)
        return , [byte[]](@($Tag) + (ConvertTo-DerLength $Value.Length) + $Value)
    }
    function New-TemplateNameExtension {
        # 1.3.6.1.4.1.311.20.2 as BMPString (as on version 1 templates)
        param([string]$Name, [byte]$Tag = 0x1E)
        if ($Tag -eq 0x1E) { $bytes = [System.Text.Encoding]::BigEndianUnicode.GetBytes($Name) }
        else { $bytes = [System.Text.Encoding]::UTF8.GetBytes($Name) }
        return , (New-DerElement -Tag $Tag -Value $bytes)
    }
    function New-TemplateInfoExtension {
        # 1.3.6.1.4.1.311.21.7: SEQUENCE { OID, INTEGER major, INTEGER minor }
        param([string]$Oid, [int]$Major = 100, [int]$Minor = 4)
        $oidDer = [System.Security.Cryptography.CryptoConfig]::EncodeOID($Oid)   # complete TLV, from .NET
        $content = [byte[]]($oidDer + (New-DerElement -Tag 0x02 -Value @([byte]$Major)) + (New-DerElement -Tag 0x02 -Value @([byte]$Minor)))
        return , (New-DerElement -Tag 0x30 -Value $content)
    }
    function New-TestCertificate {
        # Self-signed certificate with SAN, optional template extensions; has a private key
        param(
            [string[]]$DnsName = @(),
            [string]$Subject = 'CN=test',
            [string]$TemplateName = '',
            [string]$TemplateOid = '',
            [int]$NotBeforeDays = -1,
            [int]$NotAfterDays = 365,
            [switch]$NoSan
        )
        $key = [System.Security.Cryptography.ECDsa]::Create([System.Security.Cryptography.ECCurve+NamedCurves]::nistP256)
        $req = New-Object System.Security.Cryptography.X509Certificates.CertificateRequest($Subject, $key, [System.Security.Cryptography.HashAlgorithmName]::SHA256)
        if (-not $NoSan) {
            $san = New-Object System.Security.Cryptography.X509Certificates.SubjectAlternativeNameBuilder
            foreach ($n in $DnsName) { $san.AddDnsName($n) }
            $san.AddIpAddress([System.Net.IPAddress]::Parse('192.0.2.10'))
            $req.CertificateExtensions.Add($san.Build($false))
        }
        if ($TemplateName) {
            $req.CertificateExtensions.Add((New-Object System.Security.Cryptography.X509Certificates.X509Extension('1.3.6.1.4.1.311.20.2', (New-TemplateNameExtension $TemplateName), $false)))
        }
        if ($TemplateOid) {
            $req.CertificateExtensions.Add((New-Object System.Security.Cryptography.X509Certificates.X509Extension('1.3.6.1.4.1.311.21.7', (New-TemplateInfoExtension $TemplateOid), $false)))
        }
        $now = [DateTimeOffset]::Now
        return $req.CreateSelfSigned($now.AddDays($NotBeforeDays), $now.AddDays($NotAfterDays))
    }
    function New-Info {
        # Info object as produced by ConvertTo-CertificateInfo, for the pure functions
        param([string]$Thumbprint, [string[]]$DnsNames, [string]$TemplateName = '', [string]$TemplateOid = '',
            [int]$NotAfterDays = 365, [int]$NotBeforeDays = -1, [bool]$HasPrivateKey = $true)
        [pscustomobject]@{
            Thumbprint = $Thumbprint; Subject = "CN=$Thumbprint"
            NotBefore = (Get-Date).AddDays($NotBeforeDays); NotAfter = (Get-Date).AddDays($NotAfterDays)
            HasPrivateKey = $HasPrivateKey; DnsNames = $DnsNames
            TemplateName = $TemplateName; TemplateOid = $TemplateOid; TemplateText = ''
        }
    }
    function Get-SanRaw {
        param([string[]]$DnsName, [switch]$Mixed)
        $b = New-Object System.Security.Cryptography.X509Certificates.SubjectAlternativeNameBuilder
        if ($Mixed) { $b.AddEmailAddress('admin@corp.example'); $b.AddIpAddress([System.Net.IPAddress]::Parse('192.0.2.1')) }
        foreach ($n in $DnsName) {
            $b.AddDnsName($n)
            if ($Mixed) { $b.AddUserPrincipalName("$n@corp.example") }
        }
        if ($Mixed) { $b.AddUri([uri]'https://corp.example/') }
        return , $b.Build($false).RawData
    }
}

Describe 'Get-SanDnsName (DER, SubjectAlternativeNameBuilder)' {
    It 'reads a single dNSName' {
        @(Get-SanDnsName -RawData (Get-SanRaw 'pc0815.corp.example')) | Should -Be @('pc0815.corp.example')
    }
    It 'reads all dNSName entries in order and skips e-mail, IP, UPN and URI' {
        $raw = Get-SanRaw -DnsName 'PC0815.corp.example', 'pc0815', 'alias.corp.example' -Mixed
        @(Get-SanDnsName -RawData $raw) | Should -Be @('PC0815.corp.example', 'pc0815', 'alias.corp.example')
    }
    It 'handles long-form lengths (SAN larger than 255 bytes)' {
        $names = 1..40 | ForEach-Object { 'host{0:D3}.subdomain.corp.example' -f $_ }
        $raw = Get-SanRaw -DnsName $names
        $raw.Length | Should -BeGreaterThan 255
        $raw[1] | Should -Be 0x82
        @(Get-SanDnsName -RawData $raw) | Should -Be $names
    }
    It 'returns nothing if the SAN contains no dNSName' {
        $b = New-Object System.Security.Cryptography.X509Certificates.SubjectAlternativeNameBuilder
        $b.AddIpAddress([System.Net.IPAddress]::Parse('192.0.2.1'))
        @(Get-SanDnsName -RawData $b.Build($false).RawData).Count | Should -Be 0
    }
    It 'reads the SAN of a generated certificate' {
        $cert = New-TestCertificate -DnsName 'pc1.corp.example', 'pc1'
        $ext = $cert.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.17' }
        @(Get-SanDnsName -RawData $ext.RawData) | Should -Be @('pc1.corp.example', 'pc1')
    }
    It 'throws on truncated data' {
        $raw = Get-SanRaw 'pc0815.corp.example'
        $cut = [byte[]]$raw[0..($raw.Length - 3)]
        { Get-SanDnsName -RawData $cut } | Should -Throw
    }
    It 'throws if the data does not start with a SEQUENCE' {
        { Get-SanDnsName -RawData ([byte[]]@(0x04, 0x02, 0x41, 0x42)) } | Should -Throw
    }
    It 'throws on data after the SEQUENCE' {
        $raw = [byte[]]((Get-SanRaw 'a.example') + [byte]0x00)
        { Get-SanDnsName -RawData $raw } | Should -Throw
    }
}

Describe 'DER: OID and template extensions' {
    It 'decodes OID <Oid>' -ForEach @(
        @{ Oid = '1.3.6.1.4.1.311.21.7' }
        @{ Oid = '2.5.29.17' }
        @{ Oid = '1.2.840.113549.1.1.11' }
        @{ Oid = '1.3.6.1.4.1.311.21.8.16187918.14945684.15749023.11519519.4925321.197.13392918.13544906' }
    ) {
        $der = [System.Security.Cryptography.CryptoConfig]::EncodeOID($Oid)
        ConvertFrom-DerOid -Bytes $der -Offset 2 -Length ($der.Length - 2) | Should -Be $Oid
    }
    It 'throws on an OID that ends in the middle of an arc' {
        { ConvertFrom-DerOid -Bytes ([byte[]]@(0x2B, 0x86)) } | Should -Throw
    }
    It 'reads the template name as BMPString' {
        ConvertFrom-TemplateNameExtension -RawData (New-TemplateNameExtension 'Machine-WLAN') | Should -BeExactly 'Machine-WLAN'
    }
    It 'reads the template name as UTF8String' {
        ConvertFrom-TemplateNameExtension -RawData (New-TemplateNameExtension 'Machine-WLAN' -Tag 0x0C) | Should -BeExactly 'Machine-WLAN'
    }
    It 'reads OID and versions from the template information' {
        $info = ConvertFrom-TemplateInfoExtension -RawData (New-TemplateInfoExtension -Oid $script:OidV2 -Major 100 -Minor 4)
        $info.Oid | Should -Be $script:OidV2
        $info.MajorVersion | Should -Be 100
        $info.MinorVersion | Should -Be 4
    }
}

Describe 'ConvertTo-CertificateInfo' {
    It 'collects DNS names (lower case), template name and OID, private key' {
        $cert = New-TestCertificate -DnsName 'PC1.Corp.Example', 'pc1' -TemplateName 'Machine-WLAN' -TemplateOid $script:OidV2
        $i = ConvertTo-CertificateInfo -Certificate $cert
        $i.DnsNames | Should -Be @('pc1.corp.example', 'pc1')
        $i.TemplateName | Should -BeExactly 'Machine-WLAN'
        $i.TemplateOid | Should -Be $script:OidV2
        $i.HasPrivateKey | Should -BeTrue
        $i.Thumbprint | Should -Be $cert.Thumbprint
    }
    It 'falls back to GetNameInfo (subject CN) without SAN' {
        $cert = New-TestCertificate -NoSan -Subject 'CN=pc9.corp.example'
        (ConvertTo-CertificateInfo -Certificate $cert).DnsNames | Should -Be @('pc9.corp.example')
    }
    It 'reports no private key for a certificate loaded without key' {
        $cert = New-TestCertificate -DnsName 'pc1.corp.example'
        $pub = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(, $cert.RawData)
        (ConvertTo-CertificateInfo -Certificate $pub).HasPrivateKey | Should -BeFalse
    }
}

Describe 'Get-TemplateCertificate / Test-TemplateMatch' {
    BeforeAll {
        $script:cV1      = New-TestCertificate -DnsName 'a.corp.example' -TemplateName 'Machine-WLAN'
        $script:cV2      = New-TestCertificate -DnsName 'b.corp.example' -TemplateOid $script:OidV2
        $script:cOther   = New-TestCertificate -DnsName 'c.corp.example' -TemplateName 'WebServer'
        $script:cOtherV2 = New-TestCertificate -DnsName 'd.corp.example' -TemplateOid $script:OidOther
        $script:cNone    = New-TestCertificate -DnsName 'e.corp.example'
        $script:all = @($script:cV1, $script:cV2, $script:cOther, $script:cOtherV2, $script:cNone)
    }
    It 'finds the v1 template by name (case-insensitive)' {
        $r = @(Get-TemplateCertificate -Template 'machine-wlan' -Certificate $script:all)
        $r.Thumbprint | Should -Be @($script:cV1.Thumbprint)
    }
    It 'finds the v2 template by known OID' {
        $r = @(Get-TemplateCertificate -Template 'Machine-WLAN' -TemplateOid $script:OidV2 -Certificate $script:all)
        $r.Thumbprint | Should -Be @($script:cV1.Thumbprint, $script:cV2.Thumbprint)
    }
    It 'does not find v2 certificates without known OID (documented limitation)' {
        @(Get-TemplateCertificate -Template 'Machine-WLAN' -Certificate @($script:cV2)).Count | Should -Be 0
    }
    It 'matches the formatted text Template=name(oid) only with the exact template name' {
        $i = New-Info -Thumbprint 'T1' -DnsNames 'x' -TemplateOid $script:OidV2
        $i.TemplateText = "Template=Machine-WLAN($($script:OidV2)), Major Version Number=100, Minor Version Number=4"
        Test-TemplateMatch -Certificate $i -Template 'Machine-WLAN' | Should -BeTrue
        Test-TemplateMatch -Certificate $i -Template 'WLAN' | Should -BeFalse
        $i.TemplateText = "Vorlage=Computer WLAN($($script:OidV2))"
        Test-TemplateMatch -Certificate $i -Template 'Machine-WLAN' | Should -BeFalse
    }
    It 'ignores other templates and certificates without template' {
        $r = @(Get-TemplateCertificate -Template 'Machine-WLAN' -TemplateOid $script:OidV2 -Certificate $script:all)
        $r.Thumbprint | Should -Not -Contain $script:cOther.Thumbprint
        $r.Thumbprint | Should -Not -Contain $script:cOtherV2.Thumbprint
        $r.Thumbprint | Should -Not -Contain $script:cNone.Thumbprint
    }
}

Describe 'Test-CertificateMatch' {
    BeforeAll { $script:now = Get-Date }
    It '<Label>' -ForEach @(
        @{ Label = 'match';                                Names = @('pc1.corp.example'); After = 365; Before = -1; Key = $true;  Min = 30; Expected = 'pc1.corp.example';  Result = $true }
        @{ Label = 'case-insensitive, trailing dot';       Names = @('PC1.corp.example'); After = 365; Before = -1; Key = $true;  Min = 30; Expected = 'Pc1.Corp.Example.'; Result = $true }
        @{ Label = 'second SAN entry matches';             Names = @('pc1', 'pc1.corp.example'); After = 365; Before = -1; Key = $true; Min = 30; Expected = 'pc1.corp.example'; Result = $true }
        @{ Label = 'old name';                             Names = @('old.corp.example'); After = 365; Before = -1; Key = $true;  Min = 30; Expected = 'pc1.corp.example';  Result = $false }
        @{ Label = 'short name only';                      Names = @('pc1');              After = 365; Before = -1; Key = $true;  Min = 30; Expected = 'pc1.corp.example';  Result = $false }
        @{ Label = 'expires within MinValidDays';          Names = @('pc1.corp.example'); After = 10;  Before = -1; Key = $true;  Min = 30; Expected = 'pc1.corp.example';  Result = $false }
        @{ Label = 'expires soon, MinValidDays 0';         Names = @('pc1.corp.example'); After = 10;  Before = -1; Key = $true;  Min = 0;  Expected = 'pc1.corp.example';  Result = $true }
        @{ Label = 'expired';                              Names = @('pc1.corp.example'); After = -1;  Before = -400; Key = $true; Min = 0; Expected = 'pc1.corp.example';  Result = $false }
        @{ Label = 'not yet valid';                        Names = @('pc1.corp.example'); After = 365; Before = 2;  Key = $true;  Min = 0;  Expected = 'pc1.corp.example';  Result = $false }
        @{ Label = 'no private key';                       Names = @('pc1.corp.example'); After = 365; Before = -1; Key = $false; Min = 0;  Expected = 'pc1.corp.example';  Result = $false }
        @{ Label = 'no DNS names';                         Names = @();                   After = 365; Before = -1; Key = $true;  Min = 0;  Expected = 'pc1.corp.example';  Result = $false }
    ) {
        $i = New-Info -Thumbprint 'T' -DnsNames $Names -NotAfterDays $After -NotBeforeDays $Before -HasPrivateKey $Key
        Test-CertificateMatch -Certificate $i -ExpectedDnsName $Expected -MinValidDays $Min -Now $script:now | Should -Be $Result
    }
    It 'accepts a real certificate converted with ConvertTo-CertificateInfo' {
        $i = ConvertTo-CertificateInfo -Certificate (New-TestCertificate -DnsName 'pc1.corp.example')
        Test-CertificateMatch -Certificate $i -ExpectedDnsName 'PC1.CORP.EXAMPLE' -MinValidDays 30 | Should -BeTrue
    }
}

Describe 'Select-ObsoleteCertificate' {
    BeforeAll {
        $script:exp = 'pc-new.corp.example'
        $script:new      = New-Info -Thumbprint 'NEW'   -DnsNames 'pc-new.corp.example' -TemplateName 'Machine-WLAN'
        $script:oldSame  = New-Info -Thumbprint 'OLD'   -DnsNames 'pc-old.corp.example' -TemplateName 'Machine-WLAN'
        $script:oldV2    = New-Info -Thumbprint 'OLDV2' -DnsNames 'pc-old.corp.example' -TemplateOid $script:OidV2
        $script:other    = New-Info -Thumbprint 'OTHER' -DnsNames 'pc-old.corp.example' -TemplateName 'WebServer'
        $script:expired  = New-Info -Thumbprint 'EXP'   -DnsNames 'pc-old.corp.example' -TemplateName 'Machine-WLAN' -NotAfterDays -5 -NotBeforeDays -400
        $script:second   = New-Info -Thumbprint 'NEW2'  -DnsNames 'PC-NEW.corp.example' -TemplateName 'Machine-WLAN' -NotAfterDays 20
    }
    It 'selects a certificate of the same template with the old name' {
        $r = @(Select-ObsoleteCertificate -Certificate @($script:new, $script:oldSame) -Template 'Machine-WLAN' -ExpectedDnsName $script:exp -KeepThumbprint 'NEW')
        $r.Thumbprint | Should -Be @('OLD')
    }
    It 'selects v2 certificates only with known template OID' {
        @(Select-ObsoleteCertificate -Certificate @($script:new, $script:oldV2) -Template 'Machine-WLAN' -ExpectedDnsName $script:exp -KeepThumbprint 'NEW').Count | Should -Be 0
        $r = @(Select-ObsoleteCertificate -Certificate @($script:new, $script:oldV2) -Template 'Machine-WLAN' -TemplateOid $script:OidV2 -ExpectedDnsName $script:exp -KeepThumbprint 'NEW')
        $r.Thumbprint | Should -Be @('OLDV2')
    }
    It 'never selects certificates of another template' {
        @(Select-ObsoleteCertificate -Certificate @($script:new, $script:other) -Template 'Machine-WLAN' -ExpectedDnsName $script:exp -KeepThumbprint 'NEW').Count | Should -Be 0
    }
    It 'selects an expired certificate of the template with the old name' {
        $r = @(Select-ObsoleteCertificate -Certificate @($script:new, $script:expired) -Template 'Machine-WLAN' -ExpectedDnsName $script:exp -KeepThumbprint 'NEW')
        $r.Thumbprint | Should -Be @('EXP')
    }
    It 'returns nothing if only the kept certificate exists' {
        @(Select-ObsoleteCertificate -Certificate @($script:new) -Template 'Machine-WLAN' -ExpectedDnsName $script:exp -KeepThumbprint 'NEW').Count | Should -Be 0
    }
    It 'returns nothing without kept thumbprint (only an old certificate)' {
        @(Select-ObsoleteCertificate -Certificate @($script:oldSame) -Template 'Machine-WLAN' -ExpectedDnsName $script:exp).Count | Should -Be 0
    }
    It 'returns nothing if the kept certificate does not contain the expected name' {
        @(Select-ObsoleteCertificate -Certificate @($script:new, $script:oldSame) -Template 'Machine-WLAN' -ExpectedDnsName 'other.corp.example' -KeepThumbprint 'NEW').Count | Should -Be 0
    }
    It 'returns nothing if the kept certificate is not in the list' {
        @(Select-ObsoleteCertificate -Certificate @($script:oldSame) -Template 'Machine-WLAN' -ExpectedDnsName $script:exp -KeepThumbprint 'NEW').Count | Should -Be 0
    }
    It 'keeps further certificates with the expected name (case-insensitive) and compares thumbprints case-insensitively' {
        $r = @(Select-ObsoleteCertificate -Certificate @($script:new, $script:second, $script:oldSame, $script:other) -Template 'Machine-WLAN' -ExpectedDnsName $script:exp -KeepThumbprint 'new')
        $r.Thumbprint | Should -Be @('OLD')
    }
    It 'returns nothing for an empty list' {
        @(Select-ObsoleteCertificate -Certificate @() -Template 'Machine-WLAN' -ExpectedDnsName $script:exp -KeepThumbprint 'NEW').Count | Should -Be 0
    }
}

Describe 'Invoke-CertificateUpdate (mocked store and enrollment)' {
    BeforeAll {
        $script:exp = 'pc-new.corp.example'
        $script:certCurrent = New-TestCertificate -DnsName 'pc-new.corp.example', 'pc-new' -TemplateName 'Machine-WLAN'
        $script:certOldV1   = New-TestCertificate -DnsName 'pc-old.corp.example', 'pc-old' -TemplateName 'Machine-WLAN'
        $script:certOldV2   = New-TestCertificate -DnsName 'pc-old.corp.example' -TemplateOid $script:OidV2
        $script:certNewV2   = New-TestCertificate -DnsName 'pc-new.corp.example' -TemplateOid $script:OidV2
        $script:certWrongV2 = New-TestCertificate -DnsName 'pc-old.corp.example' -TemplateOid $script:OidV2
        $script:certOther   = New-TestCertificate -DnsName 'pc-old.corp.example' -TemplateName 'WebServer'
        $script:certSoon    = New-TestCertificate -DnsName 'pc-new.corp.example' -TemplateName 'Machine-WLAN' -NotAfterDays 10
        $script:certNoKey   = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(, $script:certNewV2.RawData)
    }
    BeforeEach {
        $script:Store = New-Object System.Collections.Generic.List[object]
        $script:Removed = New-Object System.Collections.Generic.List[string]
        $script:Issue = $script:certNewV2
        $script:Status = 'Issued'
        Mock Write-Log { }
        Mock Get-ExpectedDnsName { 'PC-NEW.corp.example' }
        Mock Get-PendingComputerName { $null }
        Mock Resolve-TemplateOid { $null }
        Mock Get-MachineCertificate { $script:Store.ToArray() }
        Mock Request-TemplateCertificate {
            if ($script:Status -eq 'Issued') { $script:Store.Add($script:Issue) }
            [pscustomobject]@{ Status = $script:Status; Certificate = $(if ($script:Status -eq 'Issued') { $script:Issue } else { $null }); Message = 'mock' }
        }
        Mock Remove-MachineCertificate { $script:Removed.Add($Thumbprint) }
    }

    It 'NOT_NEEDED: valid certificate exists; nothing requested, nothing removed without -RemoveOld' {
        $script:Store.AddRange([object[]]@($script:certCurrent, $script:certOldV1))
        $r = Invoke-CertificateUpdate -Template 'Machine-WLAN'
        $r.Result | Should -Be 'NOT_NEEDED'
        $r.ExitCode | Should -Be 0
        $r.DnsName | Should -BeExactly $script:exp
        $r.Thumbprint | Should -Be $script:certCurrent.Thumbprint
        Should -Invoke Request-TemplateCertificate -Times 0 -Exactly
        Should -Invoke Remove-MachineCertificate -Times 0 -Exactly
    }
    It 'NOT_NEEDED with -RemoveOld: removes only the same template with the old name' {
        $script:Store.AddRange([object[]]@($script:certCurrent, $script:certOldV1, $script:certOther))
        $r = Invoke-CertificateUpdate -Template 'Machine-WLAN' -RemoveOld
        $r.Result | Should -Be 'NOT_NEEDED'
        $r.Removed | Should -Be 1
        @($script:Removed) | Should -Be @($script:certOldV1.Thumbprint)
        Should -Invoke Request-TemplateCertificate -Times 0 -Exactly
    }
    It 'RENEWED: certificate expiring within MinValidDays is renewed' {
        $script:Store.Add($script:certSoon)
        $r = Invoke-CertificateUpdate -Template 'Machine-WLAN' -MinValidDays 30
        $r.Result | Should -Be 'RENEWED'
        Should -Invoke Request-TemplateCertificate -Times 1 -Exactly
        $r2 = Invoke-CertificateUpdate -Template 'Machine-WLAN' -MinValidDays 5
        $r2.Result | Should -Be 'NOT_NEEDED'
    }
    It 'RENEWED: only an old certificate; without -RemoveOld it stays' {
        $script:Store.Add($script:certOldV1)
        $r = Invoke-CertificateUpdate -Template 'Machine-WLAN'
        $r.Result | Should -Be 'RENEWED'
        $r.ExitCode | Should -Be 0
        $r.Thumbprint | Should -Be $script:certNewV2.Thumbprint
        $r.Removed | Should -Be 0
        Should -Invoke Request-TemplateCertificate -Times 1 -Exactly -ParameterFilter { $Template -eq 'Machine-WLAN' }
        Should -Invoke Remove-MachineCertificate -Times 0 -Exactly
    }
    It 'RENEWED with -RemoveOld: learns the v2 OID from the new certificate and removes old v1 and v2 certificates, not other templates' {
        $script:Store.AddRange([object[]]@($script:certOldV1, $script:certOldV2, $script:certOther))
        $r = Invoke-CertificateUpdate -Template 'Machine-WLAN' -RemoveOld
        $r.Result | Should -Be 'RENEWED'
        $r.ExitCode | Should -Be 0
        $r.Removed | Should -Be 2
        @($script:Removed | Sort-Object) | Should -Be @(@($script:certOldV1.Thumbprint, $script:certOldV2.Thumbprint) | Sort-Object)
        $script:Removed | Should -Not -Contain $script:certNewV2.Thumbprint
        $script:Removed | Should -Not -Contain $script:certOther.Thumbprint
    }
    It 'uses the template OID from AD to recognise an existing v2 certificate' {
        Mock Resolve-TemplateOid { $script:OidV2 }
        $script:Store.AddRange([object[]]@($script:certNewV2, $script:certOldV2))
        $r = Invoke-CertificateUpdate -Template 'Machine-WLAN' -RemoveOld
        $r.Result | Should -Be 'NOT_NEEDED'
        @($script:Removed) | Should -Be @($script:certOldV2.Thumbprint)
        Should -Invoke Request-TemplateCertificate -Times 0 -Exactly
    }
    It 'ERROR: enrollment status <Status> gives exit code 1 and removes nothing' -ForEach @(
        @{ Status = 'Pending' }, @{ Status = 'Denied' }, @{ Status = 'Error' }
    ) {
        $script:Status = $Status
        $script:Store.Add($script:certOldV1)
        $r = Invoke-CertificateUpdate -Template 'Machine-WLAN' -RemoveOld
        $r.Result | Should -Be 'ERROR'
        $r.ExitCode | Should -Be 1
        $r.Message | Should -Match $Status
        Should -Invoke Remove-MachineCertificate -Times 0 -Exactly
    }
    It 'ERROR: issued certificate with the wrong DNS name; nothing removed' {
        $script:Issue = $script:certWrongV2
        $script:Store.Add($script:certOldV1)
        $r = Invoke-CertificateUpdate -Template 'Machine-WLAN' -RemoveOld
        $r.Result | Should -Be 'ERROR'
        $r.ExitCode | Should -Be 1
        $r.Message | Should -Match 'does not match'
        Should -Invoke Remove-MachineCertificate -Times 0 -Exactly
    }
    It 'ERROR: issued certificate without private key' {
        $script:Issue = $script:certNoKey
        $r = Invoke-CertificateUpdate -Template 'Machine-WLAN' -RemoveOld
        $r.ExitCode | Should -Be 1
        Should -Invoke Remove-MachineCertificate -Times 0 -Exactly
    }
    It 'WHATIF: neither requests nor removes' {
        $script:Store.Add($script:certOldV1)
        $r = Invoke-CertificateUpdate -Template 'Machine-WLAN' -RemoveOld -WhatIf
        $r.Result | Should -Be 'WHATIF'
        $r.ExitCode | Should -Be 0
        Should -Invoke Request-TemplateCertificate -Times 0 -Exactly
        Should -Invoke Remove-MachineCertificate -Times 0 -Exactly
    }
    It 'WhatIf with a current certificate: reports NOT_NEEDED and removes nothing' {
        $script:Store.AddRange([object[]]@($script:certCurrent, $script:certOldV1))
        $r = Invoke-CertificateUpdate -Template 'Machine-WLAN' -RemoveOld -WhatIf
        $r.Result | Should -Be 'NOT_NEEDED'
        $r.Removed | Should -Be 0
        Should -Invoke Remove-MachineCertificate -Times 0 -Exactly
    }
    It 'ERROR: removal fails -> exit code 1 (retry later)' {
        Mock Remove-MachineCertificate { throw 'access denied' }
        $script:Store.AddRange([object[]]@($script:certCurrent, $script:certOldV1))
        $r = Invoke-CertificateUpdate -Template 'Machine-WLAN' -RemoveOld
        $r.Result | Should -Be 'ERROR'
        $r.ExitCode | Should -Be 1
        $r.Message | Should -Match 'could not be removed'
    }
    It 'ERROR: pending rename stops before any request' {
        Mock Get-PendingComputerName { 'PC-NEXT' }
        $r = Invoke-CertificateUpdate -Template 'Machine-WLAN'
        $r.ExitCode | Should -Be 1
        $r.Message | Should -Match 'PC-NEXT'
        Should -Invoke Request-TemplateCertificate -Times 0 -Exactly
    }
    It 'ERROR: name cannot be determined (no domain)' {
        Mock Get-ExpectedDnsName { throw 'The computer is not joined to a domain.' }
        $r = Invoke-CertificateUpdate -Template 'Machine-WLAN'
        $r.ExitCode | Should -Be 1
        $r.Message | Should -Match 'not joined'
    }
    It 'uses -ExpectedDnsName instead of the computer name' {
        $script:Store.Add($script:certOldV1)
        $r = Invoke-CertificateUpdate -Template 'Machine-WLAN' -ExpectedDnsName 'PC-OLD.corp.example.'
        $r.Result | Should -Be 'NOT_NEEDED'
        $r.DnsName | Should -Be 'pc-old.corp.example'
        Should -Invoke Get-ExpectedDnsName -Times 0 -Exactly
    }
    It 'ERROR: store cannot be read' {
        Mock Get-MachineCertificate { throw 'store not available' }
        $r = Invoke-CertificateUpdate -Template 'Machine-WLAN'
        $r.ExitCode | Should -Be 1
        $r.Message | Should -Match 'store not available'
    }
}

Describe 'Format-ResultLine' {
    It 'writes one summary line' {
        $r = [pscustomobject]@{ Result = 'RENEWED'; ExitCode = 0; Template = 'Machine-WLAN'; DnsName = 'pc1.corp.example'; Thumbprint = 'AB12'
            NotAfter = [datetime]'2027-11-03'; Removed = 1; Message = "New certificate `"x`"`nissued." }
        Format-ResultLine -Result $r | Should -BeExactly 'RESULT=RENEWED EXIT=0 TEMPLATE=Machine-WLAN DNS=pc1.corp.example THUMBPRINT=AB12 NOTAFTER=2027-11-03 REMOVED=1 MESSAGE="New certificate ''x'' issued."'
    }
}

Describe 'Script Update-ComputerCertificate.ps1' {
    It 'has no syntax errors' {
        $e = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($script:CertScript, [ref]$null, [ref]$e)
        $e | Should -BeNullOrEmpty
    }
    It 'is UTF-8 with BOM' {
        $bytes = [System.IO.File]::ReadAllBytes($script:CertScript)
        @($bytes[0..2]) | Should -Be @(0xEF, 0xBB, 0xBF)
    }
    It 'provides the comment-based help (before #Requires)' {
        $help = Get-Help $script:CertScript -Full
        $help.Synopsis | Should -Match 'machine certificate'
        @($help.parameters.parameter.name) | Should -Contain 'RemoveOld'
    }
    It 'ends with RESULT=ERROR and exit code 1 on a non-Windows system' -Skip:(-not ($IsLinux -or $IsMacOS)) {
        $exe = (Get-Process -Id $PID).Path
        $out = & $exe -NoProfile -NonInteractive -File $script:CertScript -Template 'Machine-WLAN' -ExpectedDnsName 'pc1.corp.example' 2>&1
        $LASTEXITCODE | Should -Be 1
        ($out | Select-Object -Last 1) | Should -Match '^RESULT=ERROR EXIT=1 '
    }
}
