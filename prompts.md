I’m uploading the app source. Use COMPETITION PATCH POLICY below.

COMPETITION PATCH POLICY

Treat this as a live scored competition service. Prioritize availability and scoring over ideal security rewrites.

Default mode: REVIEW FIRST. Do not rewrite major logic unless I approve it.

Safe/minimal fixes you may recommend:
- parameterized queries instead of string-formatted SQL
- input validation that preserves expected behavior
- path traversal prevention
- command-injection prevention
- file-upload restrictions that do not disable required upload functionality
- logging/audit additions that do not expose passwords or break responses
- removing debug mode
- fixing authorization checks where behavior is clearly wrong

Risky changes requiring my explicit approval:
- changing password storage from plaintext to hashes
- forcing password resets
- changing login/session behavior
- changing database schema
- deleting users
- disabling routes/features
- changing ports
- disabling SSH/password auth
- enabling firewall rules
- changing domain/SSSD/LDAP/Kerberos behavior
- changing response formats that scoring may check

For every finding, give me:
1. vulnerability
2. evidence
3. exploit impact
4. minimal safe patch
5. what could break
6. exact test commands
7. rollback plan

Start with review only. Identify vulnerabilities and classify them. Do not change password storage, auth flow, database schema, routes, response formats, firewall, SSH, or domain behavior unless I approve. Safe fixes like SQL parameterization are okay to recommend as minimal patches.