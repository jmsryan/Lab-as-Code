# Roadmap — From MVP Hypervisor to "Push Go"

## Purpose

This document sequences the work between the current MVP hypervisor and the
project's north star: **push a button, and the lab builds itself.**

It exists because the remaining work looks like a set of independent projects —
CI, a Terraform layer, guest configuration, secrets — when it is actually a
dependency chain. The ordering is not obvious, and getting it wrong means
building automation on top of a foundation that cannot be automated.

This document describes **design intent and sequencing**, not environment
values and not dates.

## Release Status

Pre-release v0.2.0 (August 13, 2026). The MVP hypervisor path (bootstrap →
base convergence → DNS registration) is confirmed on real hardware. The
networking cutover to the VLAN-aware bridge has been performed manually and
survives a reboot, but has not yet met the project's validation bar of a full
idempotent run.

Everything from Stage 1 onward in this document is unbuilt.

---

## The Goal

One triggered action brings up the whole lab: the hypervisor converges, virtual
machines are created, and guests are configured — without an operator finding
IP addresses, editing inventory, or babysitting a console.

Two limits are accepted up front rather than designed around:

- **The physical install stays manual.** PXE netboot and JetKVM virtual media
  were both considered and declined. A machine that can reinstall itself over
  the network is a larger risk than the rebuild is a chore, and rebuilds are
  rare.
- **A fresh-host networking cutover still wants console availability.** Not
  because it is expected to fail, but because the failure mode is total.

---

## Bootstrap Seams

The organizing idea of this roadmap. A **seam** is a point where automation
cannot be self-hosting — where something outside the system must intervene
because the system cannot yet act on its own behalf.

Seams are what make the ordering non-obvious. Everything between two seams can
be automated as a unit; nothing can automate a seam from the inside.

### Seam A — bare metal to an Ansible-manageable host

USB installer plus cloud-init seed, as documented in
[hypervisor-bootstrap.md](hypervisor-bootstrap.md) and
[cloud-init-bootstrap-sop.md](cloud-init-bootstrap-sop.md).

**Stays manual by decision.** Everything downstream begins from a booted host
with `svc-ansible` reachable over SSH.

### Seam B — hypervisor to a CI runner

**Only exists if CI runs on a self-hosted runner inside the lab.**

The runner is a virtual machine. That machine must exist before the CI it hosts
exists, so it cannot be created by that CI. Worse, a runner living *on* the
hypervisor cannot rebuild the hypervisor — it would be destroying the thing it
runs on, mid-run.

Candidate crossings: `terraform apply` from a workstation, a one-off
`virt-install`, or a dedicated small machine that is not the hypervisor.

Choosing Tailscale from GitHub-hosted runners instead removes this seam
entirely, at the cost of an ephemeral cloud node joining the lab network. That
decision is deferred to Stage 5.

---

## Stage Dependency Map

```
Seam A  (manual: installer + cloud-init seed)
   │
   ▼
Stage 0 ── hypervisor converges unattended ──┬──▶ Stage 3 ──▶ Stage 4
   │                                          │   Terraform    guests
   │                                          │
Stage 1 ── static CI ─────┐                   │
                          ├──▶ Stage 5 ◀──────┘
Stage 2 ── secrets ───────┘   apply from CI
                              (Seam B lands here)
                                   │
                                   ▼
                              Stage 6 — "push go"
```

Stages 1 and 2 are startable today and depend on nothing else. Stage 0 gates
everything that touches a real host.

---

## Stage 0 — Close the Hypervisor Gaps

**Unlocks:** every other stage. Nothing here is optional.

**Blocked by:** nothing.

The governing constraint: **no automation can drive a play that severs its own
connection and requires a human to find the new address.** Today `site.yml`
does exactly that at the networking cutover. Until it stops, "unattended" is
not achievable at any layer above it.

Work, in order:

1. **A full `site.yml` run on a fresh install that reports zero changes.** This
   is the project's own validation bar. The runbook currently notes that a
   fresh host commonly needs two passes to converge; a third should be clean.
   Until that is true, CI has nothing meaningful to assert against.
2. **Pin the bridge MAC to the physical NIC** so the cutover stops renumbering
   the host. Written up in [future-work.md](future-work.md) — that remains the
   canonical description; it is not duplicated here.
3. **Remove `meta: end_play` from the cutover** once the connection survives it,
   and let the role verify in-run instead of deferring to a reconnect.
4. **Flip `hypervisor_networking_apply` to `true`** by default. This is the last
   step, not the first — flipping it before (2) and (3) only moves where the run
   stops, since the play would still end before the `kvm` role.

---

## Stage 1 — CI That Needs No Lab Access

**Unlocks:** a safety net for every later stage.

**Blocked by:** nothing. Startable today.

Static validation on GitHub-hosted runners: `ansible-lint`,
`ansible-playbook --syntax-check`, and YAML linting. No secrets, no inventory,
no network path to the lab. Gate pull requests on it.

This is deliberately first among the CI work because it is free — it requires
none of the decisions the later stages hinge on — and because every subsequent
stage is safer to iterate on once broken YAML cannot reach `main`.

**Honest limit:** `--check` against a real host is *not* in this stage. Check
mode needs inventory, credentials, and a route to the lab, all of which arrive
later. Static validation catches syntax and lint, not behavior.

---

## Stage 2 — Secrets and Inventory

**Unlocks:** any CI that touches a real host.

**Blocked by:** nothing. Startable today, and independent of the runner
decision — CI needs credentials regardless of where it runs.

`ansible/inventory/` is gitignored, so CI currently has no inventory at all.
Two things must reach a runner without landing in the public repository:

- **The inventory itself**, which holds operational identity values that
  [automation-boundaries.md](automation-boundaries.md) forbids from git.
- **`svc-ansible`'s private key.**

Candidate approaches, none yet chosen:

| Approach | Notes |
|----------|-------|
| `ansible-vault` | Encrypted inventory committed to the repo; vault password as a CI secret. Fewest moving parts, no external dependency. |
| SOPS / age | Finer-grained encryption, better diffs on encrypted files, more setup. |
| 1Password service account | Already the source of truth for the SSH key in daily use; keeps one secrets system rather than two. |

The decision matters less than making it once and documenting it — this is the
boundary where a mistake leaks operational values permanently.

**This stage requires an explicit boundary decision, not just a tool choice.**
[automation-boundaries.md](automation-boundaries.md) currently states that
public repositories must not contain operational identity values, and that
those values must live **only** in private inventory. Committing a
vault-encrypted inventory puts ciphertext of those values in a public
repository. That is defensible — the plaintext never leaves the operator — but
it is a departure from the rule as written, and it should be decided and
recorded deliberately rather than arrived at by accident. The SOPS and
1Password options avoid the question entirely by keeping nothing in git.

---

## Stage 3 — Terraform VM Layer

**Unlocks:** the lab actually having contents.

**Blocked by:** Stage 0 (VMs attach to the bridge that Stage 0 makes reliable).

Entirely greenfield. [automation-boundaries.md](automation-boundaries.md)
already defines the boundary — Terraform owns virtual machine lifecycle and
nothing inside the operating system — but there is no code.

Scope: the libvirt provider, VM definitions, virtual hardware, and attachment to
the VLAN-aware bridge. Guests get a disposable cloud-init bootstrap for the same
reason the hypervisor does: to make them reachable by Ansible, and nothing more.

**Open sub-decision:** `*.tfstate` is gitignored today, which is correct for a
workstation and unworkable for CI. Shared or remote state is required before
Stage 5, and the choice of backend is its own decision.

---

## Stage 4 — Guest Configuration

**Unlocks:** the workloads the lab exists for.

**Blocked by:** Stage 3.

Extend inventory to guests and reuse the existing roles where the boundary
holds — `identity`, `baseline`, and `security` are written to be host-agnostic
and should not need forking.

**This stage surfaces a contradiction that must be resolved rather than
inherited.** [README.md](../README.md) describes the project as reaching "docker
applications," while [hypervisor-design.md](hypervisor-design.md) §2 scopes
application workloads and container orchestration explicitly **out**.

Both are defensible — the design document is scoped to the *hypervisor
platform*, not the lab as a whole — but the repository currently states both
without reconciling them. Guests need their own scope and boundary document,
and the README's claim should be made precise at the same time.

---

## Stage 5 — Resolve the Runner Fork, Wire Apply into CI

**Unlocks:** automation that changes real infrastructure.

**Blocked by:** Stages 0, 2, and whichever of 3–4 is being applied.

Deliberately last among the enabling work, so the decision is made when there is
something worth applying automatically — rather than committing to an
architecture before its requirements are known.

| Model | Consequence |
|-------|-------------|
| Self-hosted runner in the lab | No inbound firewall exposure, no tunnel dependency. Introduces **Seam B**, and the runner must not live on the hypervisor it manages. |
| Tailscale from hosted runners | No always-on hardware, no Seam B. Adds an external dependency and admits an ephemeral cloud node to the lab network. |

Whichever wins, apply-from-CI should stay gated behind an explicit trigger
rather than firing on every push to `main`. See "Blast radius" below.

---

## Stage 6 — "Push Go"

**Unlocks:** the goal.

**Blocked by:** all of the above.

An orchestration workflow sequencing hypervisor convergence → `terraform apply`
→ guest convergence, with each stage's failure stopping the next.

Residual limits, stated plainly so the finished system is not oversold:

- **Seam A remains manual.** "Push go" starts from a running hypervisor.
- **A fresh-host networking cutover still wants console availability**, even
  once it is reliable.

---

## Cross-Cutting Concerns

### The recursion problem

Automation that manages the machine it runs on cannot manage that machine's
destruction or rebuild. This is Seam B, and it is a property of the
architecture rather than a bug to be fixed. The mitigation is placement: a
runner that must survive a hypervisor rebuild cannot live on the hypervisor.

### Blast radius

`site.yml` no longer skips networking. A default run stages the bridge
configuration **and** runs the cleanup that deletes any unit in
`/etc/systemd/network` outside the approved set.

Unattended, plus automated, plus networking is precisely the combination that
produces an unreachable host — and it is the failure class this project has
already paid for once. Concretely:

- Apply-from-CI should require an explicit trigger, not a push to `main`.
- The networking cutover in particular should stay operator-initiated with
  console access confirmed, until it has a long track record.
- The gap between staging and cutover carries its own hazard on a fresh host:
  bridge configuration sits on disk while ifupdown still owns the NIC, and
  `systemd-networkd` can be socket-activated even while disabled.

### Idempotency as the admission gate

CI runs things repeatedly and without supervision. Anything that is not
idempotent will eventually run twice in a way nobody intended.

**Nothing gets automated before it converges cleanly by hand.** This is why
Stage 0 is a prerequisite rather than a parallel track, and why the project's
validation bar is a zero-change full run rather than "it worked once."

---

## Open Decisions

| Decision | Needed by | Notes |
|----------|-----------|-------|
| Secrets mechanism | Stage 2 | vault / SOPS / 1Password service account |
| Terraform state backend | Stage 3 | local state is unworkable for CI |
| Self-hosted runner vs. Tailscale | Stage 5 | determines whether Seam B exists |
| Guest platform scope | Stage 4 | reconciles README against `hypervisor-design.md` §2 |

---

## Summary

| Stage | Deliverable | Blocked by | Startable today |
|-------|-------------|------------|-----------------|
| 0 | Hypervisor converges unattended | — | Yes |
| 1 | Static CI (lint, syntax) | — | Yes |
| 2 | Secrets and inventory model | — | Yes |
| 3 | Terraform VM layer | 0 | No |
| 4 | Guest configuration | 3 | No |
| 5 | Apply from CI | 0, 2, 3–4 | No |
| 6 | Orchestrated "push go" | all | No |

The chain is longer than it looks, and Stage 0 is the one that gates everything.
A hypervisor that cannot converge without an operator finding its new IP address
cannot be the foundation of anything unattended.
