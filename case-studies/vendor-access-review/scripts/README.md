# Vendor Account Review scripts

Two PowerShell scripts that produce a monthly report of every user account under one Active Directory OU, with each account's real last logon, grouped by the OU directly under the search base. The report is a single HTML file that can be emailed through Microsoft Graph with certificate sign-in, so no password or client secret for Graph is stored.

The background and design reasoning are in the [case study](../README.md). This page is about running the scripts yourself.

| File | What it does |
|---|---|
| `Get-VendorLastLogonReport.ps1` | The report. Read-only against Active Directory. Writes an HTML report and a log, and optionally emails the report. |
| `Test-VendorReportPrereqs.ps1` | A preflight check. Run it on the server, as the account that will run the report, before the first scheduled run and after any change to the server. |

## When this is useful

You keep accounts for outside parties (vendors, contractors, partners) in Active Directory, one OU per party:

```
OU=Vendors,DC=example,DC=com          <- the search base
├── OU=Contoso                        <- one section in the report
│   └── OU=Field Techs                <- rolls up into Contoso, shown in a Sub-OU column
└── OU=Fabrikam\, Inc                 <- another section (a comma in a name is escaped)
```

Each month you want a list per party showing who still has an account and when it was last used, so each party can confirm which accounts to keep. Each section of the report can be copied out and sent on its own.

Nothing in the scripts is vendor-specific. Point `-SearchBase` at any parent OU whose child OUs you want reported separately.

## What the report shows

For every enabled or disabled user account under the search base, at any depth:

| Column | Source |
|---|---|
| Name | `displayName`, or the object name (CN) if that is empty |
| Username | `sAMAccountName` |
| Enabled | Yes / No |
| Last logon | The newest of `lastLogon` from **every** domain controller and the replicated `lastLogonTimestamp`; "Never" if neither has a value |
| Days since | Whole days since that last logon |
| Sub-OU | Only shown in a section that has accounts in deeper OUs |

Accounts sitting directly in the search base, rather than in a child OU, get their own section.

`lastLogon` is not replicated between domain controllers, and `lastLogonTimestamp` can lag by up to about 14 days, so the script asks each domain controller. If one cannot be reached, the report and the email say so, because some last-logon dates may then be understated.

The script never changes, disables or deletes anything in Active Directory. Removing access stays a deliberate human decision.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7, on a domain-joined Windows Server or workstation.
- The **ActiveDirectory** module (RSAT). The run-as account needs read access to the user objects, including their logon attributes. Domains normally grant this through the Pre-Windows 2000 Compatible Access group; if that group has been emptied as hardening, grant **Read Logon Information** on the OU for descendant user objects.
- For email only:
  - The **Microsoft.Graph.Authentication** module (on Windows PowerShell 5.1 it needs .NET Framework 4.7.2 or later).
  - A Microsoft 365 tenant where you can create an app registration and run Exchange Online PowerShell.
  - A mailbox to send from. A dedicated shared mailbox is best.
  - Outbound HTTPS (port 443) to `login.microsoftonline.com` and `graph.microsoft.com`.

## Quick start: a local report, no email

1. Copy both scripts into one folder, for example `C:\Scripts\VendorLogonReport\`.
2. If you downloaded them, remove the downloaded-file mark: `Get-ChildItem C:\Scripts\VendorLogonReport\*.ps1 | Unblock-File`
3. Open `Get-VendorLastLogonReport.ps1` and set the two values at the top of the `param()` block:
   - `$SearchBase`: the distinguished name of your parent OU, for example `'OU=Vendors,DC=corp,DC=example'`. To get it exactly: `(Get-ADOrganizationalUnit -Filter "Name -eq 'Vendors'").DistinguishedName`
   - `$OutputFolder`: where reports and logs go.
4. Run it:

```powershell
.\Get-VendorLastLogonReport.ps1 -NoEmail -Verbose
```

The report appears in the output folder as `Vendor_Account_Review_<date>_<time>.html`, and the run log in `Logs\`. On a workstation where scripts are blocked by the default execution policy, run it as `powershell.exe -ExecutionPolicy Bypass -File .\Get-VendorLastLogonReport.ps1 -NoEmail`. The script stops with a clear error if the search base is still the placeholder, the OU does not exist, or it finds no accounts (it refuses to produce an empty report).

## Full setup: scheduled and emailed

The preflight script refers to these step numbers when something fails. It always checks the email prerequisites too: if you only want local reports, expect FAIL lines for the Graph module and port 443 and ignore them.

### Step 1: Install the modules for all users

The scheduled task runs as a different account from yours, so install modules machine-wide. Run these in an elevated **Windows PowerShell** (`powershell.exe`), the engine the task uses: modules installed from PowerShell 7 go to a folder Windows PowerShell does not read.

```powershell
# ActiveDirectory module (Windows Server)
Install-WindowsFeature RSAT-AD-PowerShell

# Microsoft Graph authentication module (email only)
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12   # Windows PowerShell 5.1 needs this for the PowerShell Gallery
Install-Module Microsoft.Graph.Authentication -Scope AllUsers
```

On a Windows client, install RSAT through **Settings > Optional features** instead.

### Step 2: Place and lock down the scripts

1. Put both scripts in one folder and set `$SearchBase` and `$OutputFolder` as in the quick start.
2. Run `Unblock-File` on both scripts if they were downloaded.
3. Restrict the folder. A new folder under `C:\` inherits Modify for Authenticated Users, and anyone who can edit the script can run code as the task's account. Remove inheritance and keep only administrators and SYSTEM:

   ```powershell
   icacls C:\Scripts\VendorLogonReport /inheritance:r /grant:r "Administrators:(OI)(CI)F" "SYSTEM:(OI)(CI)F"
   ```

   Then, after step 2a, give the run-as account Read & execute on the folder and Modify on the output folder (use your `$OutputFolder` path and create it first with `New-Item -ItemType Directory <path> -Force`; a gMSA name ends in `$`):

   ```powershell
   icacls C:\Scripts\VendorLogonReport /grant "DOMAIN\svc-example$:(OI)(CI)RX"
   icacls C:\Scripts\VendorLogonReport\Reports /grant "DOMAIN\svc-example$:(OI)(CI)M"
   ```

4. Run a test from an elevated prompt (after the lock-down, only elevated administrators can use the folder): `.\Get-VendorLastLogonReport.ps1 -NoEmail`.

### Step 2a: Create the run-as account

Use a group managed service account (gMSA) if you can: Windows manages its password and nobody can sign in with it. Otherwise use a dedicated service account with a long password.

```powershell
# Once per domain, if gMSAs have never been used there (Domain Admins; takes effect after replication)
Add-KdsRootKey -EffectiveImmediately

# Create the gMSA and allow this server's computer account to use it
New-ADServiceAccount -Name 'svc-example' -DNSHostName 'svc-example.yourdomain.com' `
    -PrincipalsAllowedToRetrieveManagedPassword 'REPORTSERVER$'

# On the server that runs the report
Install-ADServiceAccount 'svc-example$'
Test-ADServiceAccount 'svc-example$'      # must return True
```

Whichever account you use, give it the **Log on as a batch job** right on the server (Local Security Policy, or a GPO), and the folder rights from step 2.

### Step 3: Create the certificate

The script signs in to Microsoft Graph with a certificate, so no password or client secret is stored. Run this elevated on the server that will run the report:

```powershell
$cert = New-SelfSignedCertificate -Subject 'CN=Vendor Account Review' `
    -CertStoreLocation 'Cert:\LocalMachine\My' `
    -KeyExportPolicy NonExportable -KeySpec Signature `
    -KeyAlgorithm RSA -KeyLength 2048 -HashAlgorithm SHA256 `
    -NotAfter (Get-Date).AddYears(1)
Export-Certificate -Cert $cert -FilePath C:\Scripts\VendorLogonReport\VendorAccountReview.cer   # public part only
$cert.Thumbprint
```

`NonExportable` means the private key cannot be copied off this server. Keep the certificate in `LocalMachine\My`: that is the store the preflight checks (the report script also looks in `CurrentUser\My`). Note the thumbprint and set a reminder to renew before the expiry date; the report email starts warning 30 days before it.

### Step 4: Let the run-as account read the private key

1. Open `certlm.msc` > **Personal** > **Certificates**.
2. Right-click the certificate > **All Tasks** > **Manage Private Keys**.
3. Add the run-as account (a gMSA or service account) with **Read** only. For a gMSA, choose **Service Accounts** in the object types and enter the name with its trailing `$`.

Without this, sign-in fails with "Keyset does not exist" even though the certificate is visible.

### Step 5: Register the app and scope it to one mailbox

You need the ExchangeOnlineManagement module (`Install-Module ExchangeOnlineManagement`) and the Exchange Administrator role, plus a role that can create app registrations in Entra ID (for example Application Administrator).

1. Create the sender mailbox if you do not have one. A shared mailbox needs no licence and no password: `New-Mailbox -Shared -Name 'Vendor Review' -PrimarySmtpAddress 'vendor-review@yourdomain.com'` (Exchange Online PowerShell).
2. In the Microsoft Entra admin center, create an **App registration** (single tenant, no redirect URI).
3. Under **Certificates & secrets** > **Certificates**, upload `VendorAccountReview.cer`.
4. Note the **Application (client) ID** and **Directory (tenant) ID**, and, from **Enterprise applications**, the app's **Object ID**. The Enterprise applications Object ID is different from the one shown under App registrations.
5. **Do not** add the Microsoft Graph `Mail.Send` application permission in Entra ID. That grant lets the app send as every mailbox in the tenant. Instead, scope it in Exchange Online with RBAC for Applications:

```powershell
Connect-ExchangeOnline

New-ServicePrincipal -AppId '<APP-CLIENT-ID>' -ObjectId '<ENTERPRISE-APP-OBJECT-ID>' -DisplayName 'Vendor Account Review'

New-ManagementScope -Name 'Vendor Account Review sender' `
    -RecipientRestrictionFilter "PrimarySmtpAddress -eq 'vendor-review@yourdomain.com'"

New-ManagementRoleAssignment -App '<APP-CLIENT-ID>' -Role 'Application Mail.Send' `
    -CustomResourceScope 'Vendor Account Review sender'

# Check: the sender should be in scope, any other mailbox should not
Test-ServicePrincipalAuthorization -Identity '<APP-CLIENT-ID>' -Resource 'vendor-review@yourdomain.com'
Test-ServicePrincipalAuthorization -Identity '<APP-CLIENT-ID>' -Resource 'someone-else@yourdomain.com'
```

Permission changes can take from 30 minutes to 2 hours to apply to a live app. If the sender mailbox is a dedicated mailbox, block interactive sign-in on its account.

### Step 6: Fill in the email settings

In the `param()` block of `Get-VendorLastLogonReport.ps1`, replace every `<...>` placeholder (edit the file from an elevated editor; the folder is limited to administrators):

| Setting | Value |
|---|---|
| `$TenantId` | Directory (tenant) ID |
| `$ClientId` | Application (client) ID |
| `$CertificateThumbprint` | Thumbprint from step 3 |
| `$MailFrom` | The mailbox scoped in step 5 |
| `$MailTo` | One or more recipients, for example `@('it-team@yourdomain.com')` |

Set these as defaults in the script rather than as task arguments: the preflight reads only the defaults, and a list passed to `-MailTo` through `powershell.exe -File` arrives as one string.

Then run the preflight with the Graph sign-in test **as the run-as account**. A service account with a password can do this in a PowerShell window opened with `runas /user:DOMAIN\<service-account> powershell.exe`:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Scripts\VendorLogonReport\Test-VendorReportPrereqs.ps1 -TestGraphSignIn
```

A gMSA cannot sign in interactively, so run the preflight as a one-off scheduled task under the gMSA (create it as in step 7 but name it `Vendor Account Review Preflight`, use that name in `Set-ScheduledTask`, make the preflight script with `-TestGraphSignIn` the action, and delete the task afterwards), then read the results in `<OutputFolder>\Logs\Preflight_<date>_<time>.txt`.

Fix every **FAIL** before going on. **WARN** lines are explained in the Detail column.

### Step 7: Schedule it and do the first real run

1. Create the task and name it `Vendor Account Review`:
   - **Trigger:** monthly, for example **Monthly** > **On: First Monday** at 07:00.
   - **Action:** `powershell.exe` with arguments `-NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\VendorLogonReport\Get-VendorLastLogonReport.ps1"`.
   - **Run as, service account with a password:** choose "Run whether user is logged on or not" and store the password. Do **not** tick "Do not store password": that runs the task without network credentials, so it cannot reach Active Directory or Microsoft 365.
   - **Run as, gMSA:** the Task Scheduler window cannot save a gMSA. Save the task as yourself, then switch it to the gMSA from step 2a in PowerShell:

     ```powershell
     $principal = New-ScheduledTaskPrincipal -UserId 'DOMAIN\svc-example$' -LogonType Password
     Set-ScheduledTask -TaskName 'Vendor Account Review' -Principal $principal
     ```

     Make later changes with `Set-ScheduledTask` too: saving the task in the window again asks for a password the gMSA does not have.

   Either way, the account needs the **Log on as a batch job** right (step 2a).
2. Right-click the task > **Run**. Check that the email arrives with the report attached, the log ends with "Run completed successfully", and the task's **Last Run Result** is `0x0`.

This first run is the only test of the complete path (the run-as account, the private key, the Graph sign-in and the Exchange scope together), so do it before relying on the schedule.

## Settings reference

All settings are parameters with defaults at the top of `Get-VendorLastLogonReport.ps1`. Edit the defaults for the scheduled task. You can override them on the command line for a one-off run, but the preflight reads only the defaults, so it will not see overrides.

| Parameter | Default | Meaning |
|---|---|---|
| `SearchBase` | placeholder | Parent OU. Each OU directly under it becomes a report section. The script replaces it with the DN as Active Directory returns it, so spacing differences do not matter. |
| `OutputFolder` | `C:\Scripts\VendorLogonReport\Reports` | Reports go here, logs in `Logs\` beneath it. |
| `RetentionDays` | `400` | Reports and logs older than this are deleted after a successful run. `0` keeps everything. Only files matching the script's own name patterns (`Vendor_Account_Review_*.html`, `VendorLogonReport_*.log`) are touched. |
| `TenantId`, `ClientId`, `CertificateThumbprint`, `MailFrom`, `MailTo` | placeholders | Email settings (step 6). |
| `NoEmail` | off | Write the report and log only. |

## Exit codes and failure alerts

| Exit code | Meaning |
|---|---|
| 0 | Report written (and emailed unless `-NoEmail`). |
| 1 | The run failed. The log says why. Unless `-NoEmail` was used, the script also tries to email a failure notice. |

A broken email path cannot report its own failure, so also watch the task's **Last Run Result** in Task Scheduler, or alert on non-zero exit codes with your monitoring tool.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Every account shows "Never" | The run-as account cannot read logon attributes (Pre-Windows 2000 Compatible Access emptied) | Grant Read Logon Information on the OU for descendant user objects (see Requirements). |
| "SearchBase is still the placeholder" | `$SearchBase` not set | Set it (quick start, step 3). |
| "No user accounts found" | Wrong OU, or the account cannot see it | Check the DN; run the preflight as the run-as account. |
| Report notes a domain controller could not be queried | DC offline or firewalled | Last logon for some accounts may be understated by up to about 14 days. Check the DC, then rerun. |
| "Certificate ... not found" | Wrong thumbprint, or the certificate is in another store | Compare with `Get-ChildItem Cert:\LocalMachine\My`. |
| "Keyset does not exist" | Run-as account cannot read the private key | Step 4. |
| Graph returns 403 on send | Exchange scope missing, not yet applied, or `MailFrom` is outside it | Step 5; allow up to 2 hours after a change. |
| Works when you run it, fails as a task | Different account, "Do not store password", or a module installed only for you | Steps 1 and 7; run the preflight as the task account. |
| "cannot be loaded because running scripts is disabled" or the script is blocked | Execution policy from Group Policy, or the downloaded-file mark | `Unblock-File`; a Group Policy setting overrides `-ExecutionPolicy Bypass`, so sign the script or get an exception. |
| Email warns the certificate expires soon | Under 30 days left | Create a new certificate (step 3), grant the run-as account Read on its private key (step 4), upload it to the app alongside the old one, update the thumbprint, run the preflight and the task once, then remove the old certificate from the app. |

## Testing without a domain

The report script calls only standard cmdlets (`Get-ADUser`, `Get-ADDomainController`, `Get-ADOrganizationalUnit`, `Connect-MgGraph`, `Invoke-MgGraphRequest`, `Disconnect-MgGraph`), so its report logic can be tested on any machine with PowerShell 7 by putting stub modules named `ActiveDirectory` and `Microsoft.Graph.Authentication`, defining those cmdlets, first on `$env:PSModulePath`, and passing `-OutputFolder` a local path. Have the stubs return a few fake users in nested OUs and throw for one domain controller, then run with `-NoEmail`. To test the email path, make the Graph stubs record the request instead of sending it and run without `-NoEmail`; this needs Windows, because the script looks the certificate up in the `Cert:` drive. The preflight script reads the Windows registry and file streams, so test it on Windows.

## Limitations

- Only user accounts are reported, not computers or service principals.
- `lastLogon` records interactive and network logons against Active Directory. Sign-ins that never touch a domain controller (for example cloud-only sign-ins to Microsoft 365) do not appear.
- The report is a point-in-time snapshot; it does not keep history beyond the retained HTML files.
