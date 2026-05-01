# Hypervisor Virtualization Architecture

## Purpose

This document describes the **qualitative virtualization model** of the
hypervisor.

It defines how the hypervisor:
- exposes hardware virtualization to guest workloads
- organizes VM storage
- grants operators access to the virtualization control plane
- coordinates with the networking layer without owning it

## Release Status

Pre-release v0.2.0 (May 2026). Scope: hypervisor virtualization stack ready
for Terraform-driven VM lifecycle.

This document intentionally focuses on **design intent and responsibility
boundaries**, not implementation-specific values or environment secrets.

A competent engineer should be able to reconstruct the virtualization
approach using this document together with the hypervisor design,
networking, and automation boundary documents.

---

## Design Goals

The hypervisor virtualization model is designed to be:

- **Minimal**
  Install only what is required to run guests; defer optional capabilities
  until a workload demands them.

- **Boundary-Respecting**
  Host-side virtualization (this layer) and VM lifecycle (Terraform) do not
  share state. Networking is owned by a separate role and is consumed here,
  not redefined.

- **Operator-Friendly**
  A single operator account can drive both Ansible convergence and
  interactive `virsh` use without privilege escalation gymnastics.

- **Reversible**
  Every choice — pool backend, default network handling, package set — can
  be replaced later by editing the role, without rebuilding the host.

---

## Role of the Hypervisor

The hypervisor is treated as a **virtualization substrate**, not an
orchestration platform.

Specifically, it is **not** responsible for:
- creating, destroying, or sizing virtual machines
- managing VM-internal configuration or operating systems
- providing image build, registry, or distribution services
- enforcing per-workload network policy

Those responsibilities are delegated:
- VM lifecycle → Terraform
- VM-internal state → cloud-init for first boot, Ansible thereafter
- Network policy → external switching and routing infrastructure

---

## Virtualization Stack

### Choice of KVM + libvirt

The platform uses **KVM** as the type-1-style hypervisor and **libvirt** as
the management API.

This pairing is chosen because it is:
- shipped and maintained in the Debian base repositories
- the de facto standard for Linux virtualization in homelab and production
- supported by the `dmacvicar/libvirt` Terraform provider used elsewhere in
  this repository
- inspectable and scriptable through `virsh` without any vendor tooling

No alternative hypervisor (Xen, VMware, Proxmox) is layered on top. The
goal is to keep the host a plain Debian system whose virtualization
capability is just another package set.

---

### Hardware Acceleration Requirement

The role asserts that `/dev/kvm` exists before continuing. Without
hardware virtualization extensions enabled in firmware, libvirt would
silently fall back to software emulation, which is unusable for real
workloads.

This is treated as a **prerequisite**, not a degradation path.

---

## Storage Model

### Default Pool

A single libvirt storage **pool** named `default` backs all VM disks.

Key characteristics:
- the pool is a plain directory pool
- it lives on the host root filesystem at the libvirt-stock path
- it is autostarted on boot so that Terraform operations do not require a
  manual `pool-start` after host reboot

This is an intentional MVP choice. A directory pool requires no extra
provisioning, no LVM, and no separate filesystem, while remaining a
first-class libvirt concept that more sophisticated backends can replace
later.

---

### Future Pool Backends (Out of Scope)

Anticipated future backends — none in scope today:

- **LVM-backed pool** — for thin provisioning and per-VM volumes that bypass
  the host filesystem
- **ZFS-backed pool** — for snapshot/clone semantics and compression
- **Network-backed pool** (NFS, iSCSI) — for shared storage across multiple
  hypervisors

The role is structured so that swapping the pool definition is a localized
change.

---

## Operator Access Model

Operator access to libvirt is governed by **Unix group membership**, not by
sudo escalation:

- Members of the `libvirt` group can manage system-level domains via the
  libvirt Unix socket.
- Members of the `kvm` group have direct access to `/dev/kvm` for tools
  that bypass libvirt.

By default the role grants this membership to the same SSH user Ansible
connects as. This keeps the operational story simple: the same identity
that converges the host can also drive `virsh` interactively.

> Group membership only takes effect on the user's **next login session**.

---

## Network Coupling

The virtualization layer **consumes** the host bridge, it does not define
it. Specifically:

- The bridge `br0` is created and managed by the `hypervisor-networking`
  role using systemd-networkd.
- The KVM role does not configure any bridges, VLAN-aware filters, or
  netfilter rules.
- libvirt's built-in NAT network (`default` / `virbr0`) is **undefined** by
  the role, because the platform attaches all guests directly to `br0`.
  Leaving the NAT network in place would duplicate DHCP, hide VMs behind a
  NAT, and clutter the host's interface list.

This preserves the invariant from the networking design:

> the hypervisor is *of* the infrastructure network, not *between* networks.

---

## Coupling to Terraform

VM creation does **not** happen in Ansible. The role's job ends at
"libvirt is up, the pool is ready, the operator can talk to it."

Terraform, using the `dmacvicar/libvirt` provider, then:
- pulls cloud images into the storage pool
- defines `libvirt_domain` resources
- attaches each domain to `br0` (optionally with a VLAN tag)

This split keeps host configuration idempotent and slow-changing while VM
lifecycle remains fast, declarative, and disposable.

---

## Explicit Non-Responsibilities

The KVM role **does not**:

- Create, modify, or delete virtual machines
- Pull or build VM images
- Configure VM-internal users, packages, or services
- Tune CPU pinning, hugepages, or NUMA topology
- Enable nested virtualization
- Configure swtpm / vTPM
- Manage Secure Boot certificates
- Run libvirt over TLS for remote access (libvirt is reached over SSH from
  the operator workstation and from Terraform)

These are deliberate omissions for MVP. Each can be added as a focused
follow-up without redesigning the role.

---

## Failure and Recovery Considerations

The virtualization stack is designed so that:
- reinstalling the host and re-running Ansible reproduces an identical
  control plane
- VM disks live entirely inside the storage pool path; backing the pool
  directory backs the VMs
- losing libvirt's runtime state (`/var/run/libvirt/`) is recoverable by
  re-running the role and Terraform

Because no host-side state outside of `/var/lib/libvirt/images` is
authoritative, the host can be rebuilt without manual recovery steps
beyond restoring the pool directory.

---

## Relationship to Automation

This virtualization model is intentionally aligned with the automation
boundaries:

- **cloud-init**
  - does not install or configure the virtualization stack
  - exists only on guests, not for hypervisor convergence

- **Ansible**
  - installs the KVM/libvirt packages
  - manages the storage pool definition and lifecycle
  - manages operator group membership

- **Terraform**
  - defines and destroys virtual machines against the prepared host
  - attaches VMs to the bridge owned by the networking role

No single tool crosses layers or assumes hidden responsibilities.

---

## Implementation & Deployment Notes

This document is intentionally qualitative. For **deployment details**, see:

- `docs/hypervisor-virtualization-deploy.md`

Key implementation constraints:

- The role uses `community.libvirt` Ansible modules rather than shelling
  out to `virsh`, so changes are reported correctly under `--check`.
- The storage pool autostarts so that Terraform survives host reboots.
- The default NAT network is removed by default; opt back in by setting
  `kvm_disable_default_network: false`.
- Hardware virtualization is asserted, not assumed.

---

## Summary

The hypervisor virtualization architecture treats KVM/libvirt as a
**plain capability of the host**, sized to the MVP and bounded by clear
responsibilities.

By:
- choosing a stock, distribution-supported stack
- using a single directory-backed storage pool
- delegating networking to the networking role and VM lifecycle to
  Terraform
- granting operator access through group membership rather than sudo

the design achieves a host that is easy to reason about, easy to rebuild,
and ready for declarative VM management without further host-side work.
