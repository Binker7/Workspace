<#
.SYNOPSIS
    Preflight check for the Vendor Account Review scheduled task. Run it on the host, as the
    task's run-as account, before the first scheduled run and after any change to the host.

.DESCRIPTION
    Checks everything the main script needs on the real server, in the real security context:
    PowerShell and .NET versions, execution policy, Mark of the Web on the script, modules,
    Reports folder write access, Active Directory access through every domain controller,
    the certificate and its private key, and outbound HTTPS to Microsoft 365.

    Settings (OU, folder, certificate, IDs) are read from the main script's parameter block,
    so there is one place to change them.

    Changes nothing, with these exceptions: it creates the Reports and Logs folders if they are
    missing, writes and deletes one temporary file to prove the Reports folder is writable,
    and writes its results to <OutputFolder>\Logs.
    It never sends email. -TestGraphSignIn signs in to Microsoft Graph and signs out again.

.PARAMETER ScriptPath
    Path to Get-VendorLastLogonReport.ps1.

.PARAMETER TestGraphSignIn
    Also sign in to Microsoft Graph with the certificate (no mail is sent). Use once the
    app registration and certificate upload are done.

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Scripts\VendorLogonReport\Test-VendorReportPrereqs.ps1

.NOTES
    Exit code 0 = no FAIL results. Exit code 1 = at least one FAIL.
#>
[CmdletBinding()]
param(
    [string]$ScriptPath = 'C:\Scripts\VendorLogonReport\Get-VendorLastLogonReport.ps1',
    [switch]$TestGraphSignIn
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$selfPath = $PSCommandPath
$results = New-Object System.Collections.Generic.List[object]

function Add-Result {
    param([string]$Check, [ValidateSet('PASS','WARN','FAIL','INFO')][string]$Result, [string]$Detail)
    $results.Add([pscustomobject]@{ Check = $Check; Result = $Result; Detail = $Detail })
}

function Test-Step {
    # Runs one check; an unexpected error becomes a FAIL instead of stopping the preflight.
    param([string]$Check, [scriptblock]$Body)
    try { & $Body } catch { Add-Result $Check 'FAIL' $_.Exception.Message }
}

#region Read settings from the main script ---------------------------------------------------
$settings = @{}
Test-Step 'Main script' {
    if (-not (Test-Path -LiteralPath $ScriptPath)) { throw "Not found: $ScriptPath" }
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw "Script has $($errors.Count) parse error(s): $($errors[0].Message)" }
    foreach ($p in $ast.ParamBlock.Parameters) {
        if ($p.DefaultValue) {
            $name = $p.Name.VariablePath.UserPath
            try { $settings[$name] = $p.DefaultValue.SafeGetValue() } catch { $settings[$name] = $null }
        }
    }
    Add-Result 'Main script' 'PASS' "Parsed; settings read from its parameter block."
}
if ($settings.Count -eq 0) {
    $results | Format-Table -Wrap -AutoSize Check, Result, Detail | Out-String -Width 200
    Write-Output 'Stopped: the main script could not be read, so there are no settings to test.'
    exit 1
}
$searchBase   = $settings['SearchBase']
$outputFolder = $settings['OutputFolder']
$thumb        = $settings['CertificateThumbprint']
#endregion

#region Context ------------------------------------------------------------------------------
Test-Step 'Run-as identity' {
    $id = "$env:USERDOMAIN\$env:USERNAME"
    try { $id = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name } catch { <# keep the environment-variable value #> }
    Add-Result 'Run-as identity' 'INFO' "$id (this must be the task's run-as account for the results to count)"
}

Test-Step 'PowerShell version' {
    $v = $PSVersionTable.PSVersion
    if ($v -ge [version]'5.1') { Add-Result 'PowerShell version' 'PASS' "$v ($($PSVersionTable.PSEdition))" }
    else { Add-Result 'PowerShell version' 'FAIL' "$v; 5.1 or later required" }
}

Test-Step '.NET Framework' {
    if ($PSVersionTable.PSEdition -eq 'Core') { Add-Result '.NET Framework' 'PASS' 'PowerShell 7 does not use .NET Framework.'; return }
    $release = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -Name Release).Release
    if ($release -ge 461808) { Add-Result '.NET Framework' 'PASS' "Release $release (4.7.2 or later)" }
    else { Add-Result '.NET Framework' 'FAIL' "Release $release; Microsoft Graph PowerShell needs 4.7.2 or later (461808)" }
}

Test-Step 'Execution policy' {
    $list = Get-ExecutionPolicy -List
    $gpo = @($list | Where-Object { $_.Scope -in 'MachinePolicy','UserPolicy' -and "$($_.ExecutionPolicy)" -ne 'Undefined' })
    $effective = Get-ExecutionPolicy
    $detail = "Effective: $effective. " + (($list | ForEach-Object { "$($_.Scope)=$($_.ExecutionPolicy)" }) -join ', ')
    if ($gpo | Where-Object { "$($_.ExecutionPolicy)" -in 'AllSigned','Restricted' }) {
        Add-Result 'Execution policy' 'FAIL' "Group Policy enforces a policy that blocks unsigned scripts; -ExecutionPolicy Bypass cannot override it. Sign the script or get an exception. $detail"
    } elseif ($gpo) {
        Add-Result 'Execution policy' 'WARN' "Set by Group Policy, so -ExecutionPolicy Bypass is ignored. Script must be unblocked (see Mark of the Web). $detail"
    } else { Add-Result 'Execution policy' 'PASS' $detail }
}

Test-Step 'Mark of the Web' {
    $blocked = @()
    foreach ($f in @($ScriptPath, $selfPath)) {
        if ($f -and (Test-Path -LiteralPath $f)) {
            $zone = Get-Item -LiteralPath $f -Stream 'Zone.Identifier' -ErrorAction SilentlyContinue
            if ($zone) { $blocked += (Split-Path $f -Leaf) }
        }
    }
    if ($blocked) { Add-Result 'Mark of the Web' 'FAIL' "Downloaded-file mark present on: $($blocked -join ', '). Run Unblock-File on each." }
    else { Add-Result 'Mark of the Web' 'PASS' 'Scripts are not marked as downloaded.' }
}
#endregion

#region Modules and folder -------------------------------------------------------------------
foreach ($m in 'ActiveDirectory', 'Microsoft.Graph.Authentication') {
    Test-Step "Module $m" {
        $mod = Get-Module -ListAvailable -Name $m | Sort-Object Version -Descending | Select-Object -First 1
        if ($mod) { Add-Result "Module $m" 'PASS' "$($mod.Version) at $($mod.ModuleBase)" }
        else { Add-Result "Module $m" 'FAIL' 'Not visible to this account. Install with -Scope AllUsers (README, Setup step 1).' }
    }
}

Test-Step 'Reports folder' {
    if (-not $outputFolder) { throw 'OutputFolder not set in the main script.' }
    $probe = Join-Path $outputFolder ("preflight_write_test_{0}.tmp" -f [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path (Join-Path $outputFolder 'Logs') -Force | Out-Null
    Set-Content -LiteralPath $probe -Value 'test'
    Remove-Item -LiteralPath $probe
    Add-Result 'Reports folder' 'PASS' "Writable: $outputFolder"
}
#endregion

#region Active Directory ---------------------------------------------------------------------
$adReady = $false
Test-Step 'Vendors OU' {
    if ("$searchBase" -like '<*>') { throw 'SearchBase is still the placeholder in the main script.' }
    Import-Module ActiveDirectory
    $null = Get-ADOrganizationalUnit -Identity $searchBase
    $n = @(Get-ADUser -Filter * -SearchBase $searchBase -SearchScope Subtree).Count
    $script:adReady = $true
    if ($n -gt 0) { Add-Result 'Vendors OU' 'PASS' "$n user accounts under $searchBase" }
    else { Add-Result 'Vendors OU' 'FAIL' "OU found but no user accounts are visible to this account under $searchBase" }
}

if ($adReady) {
    Test-Step 'Domain controllers' {
        $dcs = @(Get-ADDomainController -Filter * | Sort-Object HostName)
        if ($dcs.Count -lt 1) { throw 'No domain controllers returned.' }
        $bad = @()
        foreach ($dc in $dcs) {
            try { $null = @(Get-ADUser -Filter * -SearchBase $searchBase -SearchScope Subtree -Server $dc.HostName -Properties lastLogon) }
            catch { $bad += "$($dc.HostName) ($($_.Exception.Message))" }
        }
        if ($bad) { Add-Result 'Domain controllers' 'WARN' "Unreachable: $($bad -join '; '). Report will run but may understate last logon." }
        else { Add-Result 'Domain controllers' 'PASS' "All $($dcs.Count) answered: $($dcs.HostName -join ', ')" }
    }
}
#endregion

#region Email prerequisites ------------------------------------------------------------------
$placeholders = @($settings['TenantId'], $settings['ClientId'], $thumb, $settings['MailFrom']) + @($settings['MailTo']) |
    Where-Object { "$_" -like '<*>' }
if ($placeholders) {
    Add-Result 'Email settings' 'WARN' 'Still placeholders in the main script. Expected until email is configured (README, Setup step 6); email checks skipped.'
} else {
    Add-Result 'Email settings' 'PASS' "Sender $($settings['MailFrom']); recipients $(@($settings['MailTo']) -join ', ')"

    Test-Step 'Certificate' {
        $cert = Get-ChildItem "Cert:\LocalMachine\My\$thumb" -ErrorAction SilentlyContinue
        if (-not $cert) { throw "Thumbprint $thumb not found in LocalMachine\My." }
        $days = [int][Math]::Floor(($cert.NotAfter - (Get-Date)).TotalDays)
        if (-not $cert.HasPrivateKey) { throw 'Certificate has no private key on this host.' }
        $key = $null
        try { $key = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($cert) } catch { <# handled by the null check below #> }
        if (-not $key) { throw 'This account cannot open the private key. Grant Read under Manage Private Keys (README, Setup step 4).' }
        if ($days -le 30) { Add-Result 'Certificate' 'WARN' "Private key readable; expires in $days days ($($cert.NotAfter.ToString('yyyy-MM-dd')))." }
        else { Add-Result 'Certificate' 'PASS' "Private key readable; expires $($cert.NotAfter.ToString('yyyy-MM-dd')) ($days days)." }
    }
}

foreach ($endpoint in 'login.microsoftonline.com', 'graph.microsoft.com') {
    Test-Step "HTTPS to $endpoint" {
        $client = New-Object System.Net.Sockets.TcpClient
        try {
            $task = $client.ConnectAsync($endpoint, 443)
            if ($task.Wait(5000) -and $client.Connected) { Add-Result "HTTPS to $endpoint" 'PASS' 'Port 443 reachable.' }
            else { Add-Result "HTTPS to $endpoint" 'FAIL' 'No connection on port 443 within 5 seconds (firewall or proxy).' }
        } finally { $client.Dispose() }
    }
}

if ($TestGraphSignIn) {
    Test-Step 'Graph sign-in' {
        if ($placeholders) { throw 'Email settings are still placeholders.' }
        Import-Module Microsoft.Graph.Authentication
        Connect-MgGraph -TenantId $settings['TenantId'] -ClientId $settings['ClientId'] -CertificateThumbprint $thumb -NoWelcome
        try { Add-Result 'Graph sign-in' 'PASS' "Signed in as app $($settings['ClientId']). Sending permission is tested by the first real run (README, Setup step 7)." }
        finally { Disconnect-MgGraph | Out-Null }
    }
}
#endregion

#region Report -------------------------------------------------------------------------------
$fails = @($results | Where-Object { $_.Result -eq 'FAIL' }).Count
$warns = @($results | Where-Object { $_.Result -eq 'WARN' }).Count
$summary = "Preflight finished $(Get-Date -Format 'yyyy-MM-dd HH:mm'): $fails FAIL, $warns WARN."
$table = ($results | Format-Table -Wrap -AutoSize Check, Result, Detail | Out-String -Width 200).TrimEnd()

$out = "$summary`r`n$table"
Write-Output $out
if ($outputFolder) {
    try {
        $file = Join-Path (Join-Path $outputFolder 'Logs') ("Preflight_{0}.txt" -f (Get-Date -Format 'yyyy-MM-dd_HHmmss'))
        Set-Content -LiteralPath $file -Value $out
        Write-Output "Saved to $file"
    } catch { Write-Output "Could not save results: $($_.Exception.Message)" }
}
if ($fails -gt 0) { exit 1 } else { exit 0 }
#endregion
