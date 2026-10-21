<#
.SYNOPSIS
    Monthly vendor account review: last logon for every user account under the Vendors OU,
    grouped by vendor OU, written to one HTML report and (optionally) emailed via Microsoft Graph.

.DESCRIPTION
    READ-ONLY. The script changes nothing in Active Directory or Exchange.

    1. Reads every user account under -SearchBase (all depths).
    2. Queries lastLogon on EVERY domain controller (the attribute does not replicate) and takes
       the newest of those values and the replicated lastLogonTimestamp, so a DC that cannot be
       reached is covered by lastLogonTimestamp.
    3. Groups accounts by the OU directly beneath -SearchBase (the vendor). Accounts in deeper
       sub-OUs roll up to their vendor and show the sub-OU in a column. Accounts sitting directly
       in -SearchBase get their own section.
    4. Writes one HTML report (a heading and table per vendor, ready to copy into an email).
    5. Emails the report as an attachment through Microsoft Graph (app-only, certificate auth).
       Skip with -NoEmail for testing.

    Failures are visible: the script exits with code 1 and, where Graph is reachable, emails a
    failure notice. Every run is logged to <OutputFolder>\Logs.

.PARAMETER NoEmail
    Write the report and log only. Use for the first runs and for testing.

.EXAMPLE
    .\Get-VendorLastLogonReport.ps1 -NoEmail
    Produces the report locally without sending anything.

.NOTES
    Requires: Windows PowerShell 5.1 or PowerShell 7
              ActiveDirectory module (RSAT)
              Microsoft.Graph.Authentication module (email only)
    Run as:   A dedicated service account or gMSA with read access to the user objects and their logon attributes
              and read access to the certificate private key.
    Setup:    See README.md next to this script.
#>
[CmdletBinding()]
param(
    # --- Scope -----------------------------------------------------------------------------
    [string]$SearchBase = '<OU=Vendors,DC=example,DC=com>',   # parent OU; one sub-OU per vendor

    # --- Output ----------------------------------------------------------------------------
    [string]$OutputFolder = 'C:\Scripts\VendorLogonReport\Reports',
    [int]$RetentionDays   = 400,      # reports and logs older than this are removed; 0 = keep all

    # --- Email (Microsoft Graph, app-only) -------------------------------------------------
    [string]$TenantId              = '<TENANT-ID>',
    [string]$ClientId              = '<APP-CLIENT-ID>',
    [string]$CertificateThumbprint = '<CERT-THUMBPRINT>',
    [string]$MailFrom              = '<sender-mailbox@yourdomain>',
    [string[]]$MailTo              = @('<you@yourdomain>'),

    [switch]$NoEmail
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$runStamp  = Get-Date -Format 'yyyy-MM-dd_HHmm'
$logFolder = Join-Path $OutputFolder 'Logs'
$logFile   = Join-Path $logFolder "VendorLogonReport_$runStamp.log"
$script:GraphConnected = $false

#region Helpers ---------------------------------------------------------------------------------
function Write-RunLog {
    param([string]$Message, [ValidateSet('INFO','WARN','ERROR')][string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Add-Content -Path $logFile -Value $line
    Write-Verbose $line
}

function ConvertFrom-FileTimeSafe {
    # lastLogon / lastLogonTimestamp: 0 or empty means never.
    param($Value)
    if ($null -eq $Value) { return $null }
    $n = [int64]$Value
    if ($n -le 0) { return $null }
    return [DateTime]::FromFileTime($n)
}

function Split-DistinguishedName {
    # Splits a DN on unescaped commas. Returns RDNs in DN order (leaf first).
    param([string]$DN)
    return [regex]::Split($DN, '(?<!\\),')
}

function Get-RdnValue {
    # 'OU=Contoso' -> 'Contoso' ; removes DN escape backslashes.
    param([string]$Rdn)
    $value = $Rdn.Substring($Rdn.IndexOf('=') + 1)
    return ($value -replace '\\(.)', '$1')
}

function Get-VendorPlacement {
    # Returns @{ Vendor; SubOU } for a user DN relative to $SearchBase.
    param([string]$UserDN, [string]$BaseDN)
    $rdns   = Split-DistinguishedName $UserDN
    $parent = ($rdns | Select-Object -Skip 1) -join ','
    if ($parent -ieq $BaseDN) {
        return @{ Vendor = '(Accounts directly in the search base OU)'; SubOU = '' }
    }
    $suffix = ',' + $BaseDN
    if (-not $parent.EndsWith($suffix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "DN '$UserDN' is not under '$BaseDN'."
    }
    $relative = $parent.Substring(0, $parent.Length - $suffix.Length)
    $ous = @(Split-DistinguishedName $relative | ForEach-Object { Get-RdnValue $_ })
    [array]::Reverse($ous)                                  # top-down: vendor first
    $subOU = ''
    if ($ous.Count -gt 1) { $subOU = ($ous[1..($ous.Count - 1)]) -join '/' }
    return @{ Vendor = $ous[0]; SubOU = $subOU }
}

function ConvertTo-HtmlSafe { param([string]$Text) [System.Net.WebUtility]::HtmlEncode($Text) }

function Get-PropValue {
    # Reads a property that may be absent from the object (safe under StrictMode).
    param($Object, [string]$Name)
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

function Send-GraphMail {
    param([string]$Subject, [string]$HtmlBody, [string]$AttachmentPath)
    if (-not $script:GraphConnected) {
        Import-Module Microsoft.Graph.Authentication
        Connect-MgGraph -TenantId $TenantId -ClientId $ClientId `
            -CertificateThumbprint $CertificateThumbprint -NoWelcome
        $script:GraphConnected = $true
    }
    $message = @{
        subject      = $Subject
        body         = @{ contentType = 'HTML'; content = $HtmlBody }
        toRecipients = @($MailTo | ForEach-Object { @{ emailAddress = @{ address = $_ } } })
    }
    if ($AttachmentPath) {
        $message.attachments = @(@{
            '@odata.type' = '#microsoft.graph.fileAttachment'
            name          = (Split-Path $AttachmentPath -Leaf)
            contentType   = 'text/html'
            contentBytes  = [Convert]::ToBase64String([IO.File]::ReadAllBytes($AttachmentPath))
        })
    }
    $payload = @{ message = $message; saveToSentItems = $true } | ConvertTo-Json -Depth 10
    Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/v1.0/users/$MailFrom/sendMail" `
        -Body $payload -ContentType 'application/json' | Out-Null
}
#endregion

try {
    New-Item -ItemType Directory -Path $logFolder -Force | Out-Null
    Write-RunLog "Run started. SearchBase: $SearchBase. NoEmail: $NoEmail"

    #region Pre-flight ------------------------------------------------------------------------
    Import-Module ActiveDirectory
    if ($SearchBase -like '<*>') { throw 'SearchBase is still the placeholder. Set it to your vendor parent OU.' }

    if (-not $NoEmail) {
        $placeholders = @($TenantId, $ClientId, $CertificateThumbprint, $MailFrom) + $MailTo |
            Where-Object { $_ -like '<*>' }
        if ($placeholders) { throw 'Email settings still contain placeholders. Fill them in or run with -NoEmail.' }

        $cert = Get-ChildItem "Cert:\LocalMachine\My\$CertificateThumbprint" -ErrorAction SilentlyContinue
        if (-not $cert) { $cert = Get-ChildItem "Cert:\CurrentUser\My\$CertificateThumbprint" -ErrorAction SilentlyContinue }
        if (-not $cert) { throw "Certificate $CertificateThumbprint not found in LocalMachine\My or CurrentUser\My." }
        $certDaysLeft = [int][Math]::Floor(($cert.NotAfter - (Get-Date)).TotalDays)
        Write-RunLog "Certificate expires $($cert.NotAfter.ToString('yyyy-MM-dd')) ($certDaysLeft days)."
    }

    # Throws if the OU does not exist. Use the DN exactly as AD returns it, so the string
    # comparisons in Get-VendorPlacement match even if SearchBase was typed with spaces.
    $SearchBase = (Get-ADOrganizationalUnit -Identity $SearchBase).DistinguishedName
    $dcs  = @(Get-ADDomainController -Filter * | Sort-Object HostName)
    if ($dcs.Count -lt 1) { throw 'No domain controllers returned.' }
    Write-RunLog "Domain controllers: $($dcs.HostName -join ', ')"
    #endregion

    #region Select accounts -------------------------------------------------------------------
    $users = @(Get-ADUser -Filter * -SearchBase $SearchBase -SearchScope Subtree `
        -Properties DisplayName, Enabled, lastLogonTimestamp, DistinguishedName)
    if ($users.Count -lt 1) { throw "No user accounts found under $SearchBase. Refusing to send an empty report." }
    Write-RunLog "User accounts found: $($users.Count)"
    #endregion

    #region lastLogon from every DC -----------------------------------------------------------
    $latest = @{}                      # DN -> newest lastLogon (Int64 FileTime)
    $failedDCs = New-Object System.Collections.Generic.List[string]
    foreach ($dc in $dcs) {
        try {
            $dcUsers = Get-ADUser -Filter * -SearchBase $SearchBase -SearchScope Subtree `
                -Server $dc.HostName -Properties lastLogon
            foreach ($u in $dcUsers) {
                $value = [int64]0
                $raw = Get-PropValue $u 'lastLogon'
                if ($null -ne $raw) { $value = [int64]$raw }
                if (-not $latest.ContainsKey($u.DistinguishedName) -or $value -gt $latest[$u.DistinguishedName]) {
                    $latest[$u.DistinguishedName] = $value
                }
            }
            Write-RunLog "Queried $($dc.HostName): $(@($dcUsers).Count) accounts."
        }
        catch {
            $failedDCs.Add($dc.HostName)
            Write-RunLog "Could not query $($dc.HostName): $($_.Exception.Message)" 'WARN'
        }
    }
    #endregion

    #region Build rows -----------------------------------------------------------------------
    $now  = Get-Date
    $rows = foreach ($u in $users) {
        $place = Get-VendorPlacement -UserDN $u.DistinguishedName -BaseDN $SearchBase
        $fromDCs = [int64]0
        if ($latest.ContainsKey($u.DistinguishedName)) { $fromDCs = [int64]$latest[$u.DistinguishedName] }
        $fromTs = [int64]0
        $rawTs = Get-PropValue $u 'lastLogonTimestamp'
        if ($null -ne $rawTs) { $fromTs = [int64]$rawTs }
        $lastLogon = ConvertFrom-FileTimeSafe ([Math]::Max($fromDCs, $fromTs))

        $displayName = Get-PropValue $u 'DisplayName'
        if ([string]::IsNullOrWhiteSpace($displayName)) { $displayName = $u.Name }

        [pscustomobject]@{
            Vendor    = $place.Vendor
            SubOU     = $place.SubOU
            Name      = $displayName
            Username  = $u.SamAccountName
            Enabled   = if ($u.Enabled) { 'Yes' } else { 'No' }
            LastLogon = $lastLogon
            DaysSince = if ($lastLogon) { [int][Math]::Floor(($now - $lastLogon).TotalDays) } else { $null }
        }
    }
    #endregion

    #region Write HTML report -----------------------------------------------------------------
    $reportFile = Join-Path $OutputFolder "Vendor_Account_Review_$runStamp.html"
    $groups = $rows | Group-Object Vendor | Sort-Object @{ Expression = { $_.Name -notlike '(*' } }, Name

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<!DOCTYPE html><html><head><meta charset="utf-8"><title>Vendor Account Review</title>')
    [void]$sb.AppendLine('<style>body{font-family:Calibri,Arial,sans-serif;font-size:11pt;color:#222}
h1{font-size:16pt}h2{font-size:13pt;margin:22px 0 6px;border-bottom:1px solid #999}
table{border-collapse:collapse;margin-bottom:8px}th,td{border:1px solid #999;padding:3px 8px;text-align:left}
th{background:#e7e7e7}.note{color:#555;font-size:10pt}</style></head><body>')
    [void]$sb.AppendLine('<h1>Vendor Account Review</h1>')
    $intro = ('<p class="note">Generated {0}. Source OU: {1}. {2} accounts across {3} sections. ' +
        'Last logon is the newest value across all domain controllers.</p>') -f
        $now.ToString('yyyy-MM-dd HH:mm'), (ConvertTo-HtmlSafe $SearchBase), $users.Count, @($groups).Count
    [void]$sb.AppendLine($intro)
    if ($failedDCs.Count -gt 0) {
        [void]$sb.AppendLine(('<p class="note"><b>Warning:</b> could not query {0}. Last logon for some accounts may be ' +
            'understated by up to about 14 days.</p>') -f (ConvertTo-HtmlSafe ($failedDCs -join ', ')))
    }

    foreach ($g in $groups) {
        $hasSub = @($g.Group | Where-Object { $_.SubOU }).Count -gt 0
        [void]$sb.AppendLine(('<h2>{0} ({1})</h2>' -f (ConvertTo-HtmlSafe $g.Name), $g.Count))
        [void]$sb.Append('<table><tr><th>Name</th><th>Username</th><th>Enabled</th><th>Last logon</th><th>Days since</th>')
        if ($hasSub) { [void]$sb.Append('<th>Sub-OU</th>') }
        [void]$sb.AppendLine('</tr>')
        foreach ($r in ($g.Group | Sort-Object Name)) {
            $ll = if ($r.LastLogon) { $r.LastLogon.ToString('yyyy-MM-dd') } else { 'Never' }
            $ds = if ($null -ne $r.DaysSince) { $r.DaysSince } else { '' }
            [void]$sb.Append(('<tr><td>{0}</td><td>{1}</td><td>{2}</td><td>{3}</td><td>{4}</td>' -f
                (ConvertTo-HtmlSafe $r.Name), (ConvertTo-HtmlSafe $r.Username), $r.Enabled, $ll, $ds))
            if ($hasSub) { [void]$sb.Append(('<td>{0}</td>' -f (ConvertTo-HtmlSafe $r.SubOU))) }
            [void]$sb.AppendLine('</tr>')
        }
        [void]$sb.AppendLine('</table>')
    }
    [void]$sb.AppendLine('</body></html>')
    Set-Content -Path $reportFile -Value $sb.ToString() -Encoding UTF8
    Write-RunLog "Report written: $reportFile"
    #endregion

    #region Email -----------------------------------------------------------------------------
    if (-not $NoEmail) {
        $summary = '<p>Monthly vendor account review attached: {0} accounts across {1} vendor sections.</p>' -f
            $users.Count, @($groups).Count
        if ($failedDCs.Count -gt 0) {
            $summary += '<p><b>Warning:</b> could not query {0}. See the report note.</p>' -f (ConvertTo-HtmlSafe ($failedDCs -join ', '))
        }
        if ($certDaysLeft -le 30) {
            $summary += '<p><b>Action needed:</b> the Graph certificate expires in {0} days. Renew it or this report will stop sending.</p>' -f $certDaysLeft
        }
        Send-GraphMail -Subject ('Vendor Account Review - {0}' -f $now.ToString('MMMM yyyy')) -HtmlBody $summary -AttachmentPath $reportFile
        Write-RunLog "Email sent to $($MailTo -join ', ')."
    }
    #endregion

    #region Retention -------------------------------------------------------------------------
    if ($RetentionDays -gt 0) {
        $cutoff = $now.AddDays(-$RetentionDays)
        Get-ChildItem -Path $OutputFolder -Filter 'Vendor_Account_Review_*.html' -File |
            Where-Object { $_.LastWriteTime -lt $cutoff } | Remove-Item
        Get-ChildItem -Path $logFolder -Filter 'VendorLogonReport_*.log' -File |
            Where-Object { $_.LastWriteTime -lt $cutoff } | Remove-Item
    }
    #endregion

    Write-RunLog 'Run completed successfully.'
    $exitCode = 0
}
catch {
    $err = $_.Exception.Message
    try { Write-RunLog "Run FAILED: $err" 'ERROR' } catch { <# log unwritable; the error still reaches the exit code #> }
    if (-not $NoEmail) {
        try {
            Send-GraphMail -Subject 'Vendor Account Review - FAILED' -HtmlBody (
                '<p>The monthly vendor account review failed.</p><p>Error: {0}</p><p>Log: {1}</p>' -f
                (ConvertTo-HtmlSafe $err), (ConvertTo-HtmlSafe $logFile))
        } catch { try { Write-RunLog "Failure email could not be sent: $($_.Exception.Message)" 'ERROR' } catch { <# nothing more can be reported #> } }
    }
    Write-Error $err -ErrorAction Continue
    $exitCode = 1
}
finally {
    if ($script:GraphConnected) { try { Disconnect-MgGraph | Out-Null } catch { <# already disconnected #> } }
}
exit $exitCode
