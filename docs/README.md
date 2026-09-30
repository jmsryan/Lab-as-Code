# Documentation Index

Declarative homelab configuration, bare-metal KVM hypervisor to VM workloads.
This page is the entry point: it says what each document is for, and what is
actually true on the host today.

## Start here

| If you want to… | Read |
|---|---|
| Rebuild the hypervisor from a wiped disk | [hypervisor-deploy-runbook.md](hypervisor-deploy-runbook.md) |
| Understand why it is built this way | [hypervisor-design.md](hypervisor-design.md) |
| Know which tool owns which layer | [automation-boundaries.md](automation-boundaries.md) |
| Set up the private inventory | [ansible-inventory.md](ansible-inventory.md) |
| See what is planned but unbuilt | [roadmap.md](roadmap.md) |

The runbook is the driver. It sequences the bootstrap and per-role deploy
guides into one ordered path with a verification gate at each phase; the other
operational documents are its steps, not alternatives to it.

---

## Architecture — design intent

Implementation-agnostic. Describes *why*, and deliberately contains no
environment-specific values.

| Document | Scope |
|---|---|
| [hypervisor-design.md](hypervisor-design.md) | Umbrella spec: principles, platform scope, identity, security controls, configuration ownership |
| [automation-boundaries.md](automation-boundaries.md) | Responsibility split between cloud-init, Ansible, and Terraform, and the rules that keep them from bleeding |
| [hypervisor-networking.md](hypervisor-networking.md) | Traffic model: VLAN trunk, bridge, guest connectivity, and the routing/filtering the host explicitly does *not* do |
| [hypervisor-virtualization.md](hypervisor-virtualization.md) | KVM/libvirt model, storage pool, operator access, coupling to Terraform |

## Operations — ordered procedures

Follow these at a keyboard. Listed in execution order.

| Order | Document | Phase |
|---|---|---|
| 0 | [hypervisor-deploy-runbook.md](hypervisor-deploy-runbook.md) | Driver for everything below; end-to-end rebuild with per-phase gates |
| 1 | [hypervisor-bootstrap.md](hypervisor-bootstrap.md) | Manual bare-metal bootstrap to an Ansible-manageable host (Phase 0) |
| 2 | [cloud-init-bootstrap-sop.md](cloud-init-bootstrap-sop.md) | `CIDATA` USB media prep from macOS; expands bootstrap Step 2 (Phase 0) |
| 3 | [hypervisor-virtualization-deploy.md](hypervisor-virtualization-deploy.md) | `kvm` role workflow (Phase 2) |
| 4 | [hypervisor-networking-deploy.md](hypervisor-networking-deploy.md) | `hypervisor-networking` role, stage-then-apply workflow (Phase 3, risky) |

## Reference — exact input shapes

| Document | Scope |
|---|---|
| [ansible-inventory.md](ansible-inventory.md) | Required inventory variables and privacy guidance. `ansible/inventory/` is gitignored |
| [ansible-inventory.example.yml](ansible-inventory.example.yml) | Placeholder-only template to copy |

## Planning — not yet built

| Document | Scope |
|---|---|
| [roadmap.md](roadmap.md) | Sequenced dependency chain from today's MVP to a push-button build. Stage 0 gates everything |
| [future-work.md](future-work.md) | Understood but unsettled changes, each with problem, approach, and what must be proven |
| [implementation-notes.md](implementation-notes.md) | Dated lessons learned that do not rise to architectural decisions |

Release history lives in [CHANGELOG.md](../CHANGELOG.md).

---

## Current state

What is implemented in the repository versus what has been proven on real
hardware. "Validated" means the project's bar: a fresh install converges with
zero changes on a second run.

**Last full rebuild: 2026-09-29.** Wiped disk → Debian install → cloud-init →
`site.yml`, following the runbook through every gate from Phase 0 to Phase 2.5.
First run: no failures. Second run: `changed=0`. After the Phase 2.5 reboot, a
run against the permanent FQDN with no override: `changed=0`. Root was refused
over SSH and accepted at the console. The "Yes" rows below were all exercised
by that rebuild.

| Component | Implemented | Validated on hardware | Notes |
|---|---|---|---|
| cloud-init bootstrap | Yes | Yes | Runbook Phase 0 |
| `identity` role | Yes | Yes | Hostname, DHCP option 12, `svc-ansible`, prunes other human accounts |
| `baseline` role | Yes | Yes | Timezone, base packages, chrony |
| `security` role | **Partial** | Yes, for what exists | Authoritative `sshd_config` and root-account policy validated; firewall and unattended updates not built — see gaps below |
| `kvm` role | Yes | Yes | libvirt, storage pool, `virsh` without sudo; removes default NAT network |
| DHCP-DNS registration | Yes | Yes | Runbook Phase 2.5: permanent name resolved via dnsmasq after reboot |
| `networkd` migration | Yes | Once, manually | Legacy stack handoff; runs as a `hypervisor-networking` dependency |
| `hypervisor-networking` bridge/VLAN | Yes | **No** | Cutover performed 2026-08-15 and survived a reboot, but has not met the idempotent-run bar |
| Bridge MAC pinning | Yes | **No** | Applies only at next boot; netdev MAC is fixed at device creation. See future-work.md |
| Terraform VM lifecycle | No | — | Roadmap Stage 3; not in the repo |
| CI (static validation) | Yes | Yes | Lint and syntax only, no lab access. Roadmap Stage 1 |

### Known gaps in the `security` role

The role currently owns the whole `sshd_config` (templated, validated with
`sshd -t`), restricts SSH to `svc-ansible`, and manages root's account lock. It
does **not** yet implement:

- **Host firewall.** No default-deny inbound policy exists. `hypervisor-design.md`
  §8 describes this as design intent, not current state.
- **Unattended security updates.** No automatic update mechanism is configured.
  `hypervisor-design.md` §9 is likewise intent.
- **IPv6 coverage.** Tracked as a TODO in the role's defaults. Exposure is held
  closed at the other end by `IPv6AcceptRA=no` on the server VLAN subinterface —
  declining connectivity rather than securing it.

Both firewall and unattended-upgrade work must land before the role matches the
design document.
