# Vendor Access Review Automation

**Status:** deployed October 2026; unattended scheduled operation pending final approval.
**Stack:** PowerShell (Windows PowerShell 5.1 compatible), Active Directory, Microsoft Graph, Entra ID, Exchange Online, Windows Task Scheduler.

## Problem
External vendors held many accounts in on-premises Active Directory, grouped by vendor into organizational units (OUs). IT needed a monthly list of each vendor's accounts with their last sign-in, in a form that could be sent straight to each vendor for confirmation, so stale access gets removed.

## First attempt and pivot
The organization's existing audit platform was the first route. Its logon records identify an account only as `DOMAIN\username`, with no OU path, so they cannot be filtered by vendor OU. I confirmed that limit in the product before changing course, then built a dedicated script rather than force the audit tool to do something it does not support.

## Design
| Concern | Choice | Why |
|---|---|---|
| Accurate last logon | Query `lastLogon` on every domain controller and take the newest, combined with `lastLogonTimestamp` | `lastLogon` does not replicate; `lastLogonTimestamp` can lag by up to 14 days |
| One list per vendor | Group by the OU directly under the parent OU; deeper sub-OUs roll up with a Sub-OU column | Each vendor's section can be copied out and sent on its own |
| Output | One HTML report with a heading and table per vendor | Pastes cleanly into Outlook; no Office needed on the server |
| Email | Microsoft Graph `sendMail`, app-only, certificate authentication | `Send-MailMessage` is obsolete, and no password is stored anywhere |
| Least privilege | Exchange Online RBAC for Applications scopes the app to one dedicated sender mailbox; no `Mail.Send` grant in Entra ID | An Entra ID grant would let the app send as any mailbox. Exchange's authorization test confirmed the sender in scope and a comparison mailbox out of scope |
| Safety | Read-only against Active Directory; never disables or deletes accounts | Removal stays a deliberate human change after vendor review |
| Failure visibility | Exit codes for Task Scheduler, a log per run, a failure email, refusal to send an empty report, warnings when a domain controller is unreachable or the certificate is within 30 days of expiry | A scheduled job that fails silently is worse than none |

## Testing
- **Mocked end-to-end suite** (PowerShell 7 with mock Active Directory, Graph and certificate-store modules): 23 recorded test results across two rounds, covering an unreachable domain controller, a missing or expiring certificate, Graph 403 and sign-in failures, an empty OU, a same-minute rerun, log retention that deletes only its own files, and 10,000 accounts against Graph's 3 MB attachment limit.
- **Static analysis:** PSScriptAnalyzer with Windows PowerShell 5.1 compatibility profiles for Server 2016 and 2019.
- **Defects caught before deployment:** a format-string bug in the report header, unsafe property reads under strict mode, rounding in "days since last logon", and a function name that collided with a built-in cmdlet in some PowerShell versions.
- **Preflight checker:** a separate read-only script, run on the real server as the task's own account, that checks PowerShell and .NET versions, execution policy and Group Policy, downloaded-file marks, module visibility, folder rights, every domain controller, the certificate's private key, outbound HTTPS and an optional Graph sign-in.

## Deployment
- Step-confirmed rollout: each step's output checked before the next.
- File hashes verified against the tested build.
- Script folder restricted to administrators and SYSTEM; permissions audited during deployment.
- Verified live: report run against the real directory (account count matched an independent query), Graph sign-in with the certificate, and a test email delivered to the IT distribution list.
- Security checks: certificate private key confirmed non-exportable; interactive sign-in blocked on the sender mailbox's account.
- Windows behaviours that break scheduled scripts, researched and documented: S4U ("Do not store password") tasks have no network access, Group Policy execution policy overrides `-ExecutionPolicy`, Mark of the Web blocks downloaded scripts under RemoteSigned, and the PowerShell Gallery requires TLS 1.2.
- Certificate renewal procedure with zero-downtime overlap and rollback.

## Documentation
Two documents, split by audience:
- **Operations guide**, written so any technician can pick the system up cold: component inventory, how each run works, the monthly procedure, a symptom/cause/fix table that maps every preflight result and log message to a fix, change procedures, certificate renewal with rollback, decommissioning, security posture and known limitations.
- **Build and deployment record:** a ten-step install runbook with expected results and "if not" branches, the decision log, test evidence and change log.

Each draft of the operations guide went to an independent AI reviewer working only from the scripts and recorded deployment facts; fixes were applied until no blockers remained.

## What I would point to in an interview
- Proving the audit tool could not do it before pivoting.
- Why `lastLogon` must be read from every domain controller.
- How the mail permission was scoped, and why the obvious Entra ID permission would have been a security hole.
- The silent-failure gap (a broken email path cannot report itself) and how it is mitigated.

## Skills
PowerShell automation for Windows Server (5.1 compatibility, strict mode, error handling, logging, exit codes) · Active Directory internals · Microsoft Graph and Entra ID app registration with certificate authentication · Exchange Online RBAC for Applications · Task Scheduler and Windows security contexts · Test design with mocks, static analysis and preflight checks · Change discipline · Technical writing for technicians and leadership

The script itself was written on the job and belongs to the employer, so it is not published here.
