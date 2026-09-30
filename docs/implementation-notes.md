# Implementation Notes & Observations

This document captures **non-architectural lessons learned** during
implementation.

## Release Status

Pre-release v0.1.0 (January 26, 2026). Scope: hypervisor initial configuration.

These notes document tool behavior, minor corrections, and practical
observations that do not rise to the level of architectural decisions.

---

## 2026-01-25 — SSH Server Not Present After Minimal Install

**Observation**  
A minimal Debian installation did not include an SSH server by default,
preventing remote access after initial boot.

**Impact**  
Manual intervention was required to install `openssh-server` to regain access.

**Resolution**  
The cloud-init bootstrap configuration was updated to explicitly install
the SSH server package, removing reliance on installer defaults.

**Notes**  
This change does not alter system architecture or trust boundaries. It ensures
deterministic bootstrap behavior.

---

## 2026-09-29 — sshd_config Left as a Stub by cloud-init

**Observation**  
The hypervisor's `/etc/ssh/sshd_config` was 8 lines long, with no `Subsystem
sftp` and no `Include`. Debian's stock file sat unused beside it as
`sshd_config.ucf-dist`. Ansible warned on every task that its sftp and scp
transfers failed, and fell back to piping files over `dd`.

**Impact**  
Nothing broke outright; SSH login and every play still worked. But the host
ran on a config nobody had written, and the security role's "authoritative"
policy was a patch over it.

**Cause**  
A follow-on from the 2026-01-25 entry above. cloud-init applies
`ssh_pwauth: false` before it installs `packages:`, so on a fresh host it
creates `sshd_config` holding only `PasswordAuthentication no`. When
`openssh-server` then installs, dpkg treats that file as a locally-modified
conffile, keeps it, and writes the maintainer's version to `.ucf-dist`. The
security role's `blockinfile`/`lineinfile` tasks then patched the stub.

**Resolution**  
The security role now renders the whole file from
`roles/security/templates/sshd_config.j2`, validated with `sshd -t` before it
is installed. It carries Debian's stock `Subsystem`, `AcceptEnv` and
`PrintMotd` lines, and deliberately has no `Include` of `sshd_config.d/`, so
a drop-in cannot override the policy.

**Notes**  
After the change is applied, an Ansible control connection that is still open
(`ControlPersist`, 60s) keeps the old sshd session, so the sftp warning can
appear for one more run. Closing it, or waiting 60 seconds, clears it.

---

## (future entries go here)
