# Security

Please report a vulnerability privately through
[GitHub's private vulnerability reporting](https://github.com/Pacabase/system_ssh/security/advisories/new),
not in a public issue. You'll get a reply within a week.

`system_ssh` runs the system's `ssh` with only the options listed in the
README, and refuses a host that ssh would read as an option. It never reads
or stores keys, passwords or passphrases: authentication, host keys and
`~/.ssh/config` stay entirely with OpenSSH.
