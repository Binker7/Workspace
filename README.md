# Workspace

Write-ups of systems I have designed, built and deployed as an IT administrator.

Each case study covers the problem, the design decisions and why I made them, how I tested the system, and how it was deployed and documented. They are sanitized: no organization names, hostnames, IP addresses, tenant or application IDs, account names, configuration exports or regulated data. Where code is included, it is a generalized version with placeholders in place of every real setting, and a README on how to use it.

## Case studies

| Project | Summary | Skills |
|---|---|---|
| [Vendor Access Review Automation](case-studies/vendor-access-review/) | Monthly report (scheduling pending) of every vendor account's last sign-in in Active Directory, grouped by vendor and emailed through Microsoft Graph with certificate authentication and mailbox-scoped permissions. | PowerShell, Active Directory, Microsoft Graph, Entra ID, Exchange Online RBAC, Task Scheduler, test design |
