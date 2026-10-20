# Workspace

Write-ups of systems I have designed, built and run as an IT administrator.

Each case study covers the problem, the design decisions and why I made them, how I tested the system, and how it was deployed and documented. They are sanitized: no organization names, hostnames, IP addresses, tenant or application IDs, account names, configuration exports or patient data. Where code was written on the job, it belongs to the employer and is not published here unless I have permission to share a generic version.

## Case studies

| Project | Summary | Skills |
|---|---|---|
| [Vendor Access Review Automation](case-studies/vendor-access-review/) | Monthly report of every vendor account's last sign-in in Active Directory, grouped by vendor and emailed through Microsoft Graph with certificate authentication and mailbox-scoped permissions. | PowerShell, Active Directory, Microsoft Graph, Entra ID, Exchange Online RBAC, Task Scheduler, test design |

## How I work
- Confirm what a tool can and cannot do before building around it.
- Least privilege by default, and no stored passwords.
- Test failure paths, not only the happy path, and make scheduled jobs fail loudly.
- Deploy one verified step at a time, with a rollback.
- Document so another technician can pick the system up cold.

Some projects were built with an AI assistant (Claude) as a pair engineer. Design decisions, verification and deployment were mine.
