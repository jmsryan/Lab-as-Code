# Implementation Notes & Observations

This document captures **non-architectural lessons learned** during
implementation.

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

## (future entries go here)