# Automation Boundaries & Responsibility Model

## Purpose

This document defines the **explicit responsibility boundaries** between
automation tools used in the hypervisor platform.

## Release Status

Pre-release v0.1.0 (January 26, 2026). Scope: hypervisor initial configuration.

The goal is to ensure:
- deterministic system bootstrap
- clear ownership of long-lived state
- zero configuration drift
- safe public documentation without leaking operational details

This document describes **design intent**, not environment-specific values.

---

## Core Principle

**cloud-init has no long-term authority over system state.**

All state introduced by cloud-init is:
- temporary
- non-authoritative
- expected to be replaced by Ansible

After initial convergence, **Ansible is the sole source of truth** for the
hypervisor’s configuration and identity.

---

## Tool Overview

| Tool        | Role Summary                                               |
|-------------|------------------------------------------------------------|
| cloud-init  | Non-authoritative bootstrap to enable Ansible              |
| Ansible     | Authoritative configuration and permanent system state     |
| Terraform   | Infrastructure and virtual machine lifecycle management    |

---

## cloud-init Boundary

### Purpose

`cloud-init` exists **only** to guarantee that a freshly installed system
is reachable by configuration management tooling.

It establishes *temporary bootstrap state* and immediately hands off
authority to Ansible.

---

### Responsibilities (In Scope)

cloud-init may perform the following actions **only to enable Ansible**:

- Assign a **temporary bootstrap hostname**
- Create a temporary automation user
- Install required access packages (e.g., SSH server)
- Configure SSH key-based access
- Disable password-based authentication
- Disable root login
- Perform minimal package installation required for remote access

> Any configuration introduced by cloud-init is intentionally non-authoritative
> and is expected to be replaced during Ansible convergence.

---

### Explicit Non-Responsibilities (Out of Scope)

cloud-init **does not**:

- Define permanent system identity
- Preserve configuration across reboots
- Own users, groups, or access policy long-term
- Harden services
- Configure firewall rules
- Configure networking topology
- Manage VLANs or bridges
- Install or configure virtualization tooling
- Enforce update or maintenance policy
- Act as a configuration management system

---

### Determinism & Safety Requirements

- cloud-init configuration must be deterministic
- cloud-init must not rely on implicit OS installer behavior
- Required access components (e.g., SSH server) must be explicitly installed
- cloud-init artifacts must be safe to publish in a public repository

---

### Networking Must Be Explicitly Disabled

"Configure networking topology" being out of scope is not self-enforcing.
Given no `network-config` in the seed, cloud-init **generates a fallback**
for the primary NIC and renders it to
`/etc/network/interfaces.d/50-cloud-init` — silently taking ownership of
network state that belongs to Ansible.

The fallback enables both address families, emitting an `inet6 dhcp` stanza.
Debian 13 ships no DHCPv6 client (`isc-dhcp-client` was dropped from the
release; `dhcpcd-base` backs ifupdown's IPv4 only), so on every boot:

1. DHCPv4 succeeds — address, subnet route, and default route are installed
2. the `inet6` stanza fails with `No DHCPv6 client software found!`
3. `ifup` exits 1, so systemd fails `ifup@<nic>.service`
4. systemd SIGTERMs `dhcpcd`, which **removes the working address and routes**

The host boots with no IPv4 connectivity, and Ansible cannot reach it to
converge.

`cloud-init/network-config` closes this at the seed, which is the only layer
that can: the failure lands on first boot, before Ansible has a network to
arrive over. With the seed in place cloud-init never renders a network
config, so there is no state for Ansible to correct — and no Ansible task
enforces this, deliberately. Networking changes in this repo stay gated
behind `--tags networking`; a remediation task in a default-run role would
route around that gate to guard a condition that cannot recur.

Hosts seeded before this file existed carry a stale
`/etc/network/interfaces.d/50-cloud-init` and need a one-time manual
removal.

---

## Ansible Boundary

### Purpose

Ansible is the **authoritative configuration management system** for the
hypervisor.

Once Ansible has converged successfully, it fully owns:
- system identity
- access control
- configuration state
- compliance

---

### Responsibilities (In Scope)

Ansible is responsible for defining and enforcing:

- Permanent hostname
- Authoritative users and groups
- SSH configuration and access policy
- Package installation and removal
- Service configuration and enablement
- Host firewall configuration
- Network configuration (bridges, VLAN awareness)
- Virtualization stack configuration (KVM, libvirt)
- Overlay networking client installation and configuration
- Update and maintenance policies

Ansible is expected to **overwrite** any temporary state introduced by
cloud-init.

---

### Explicit Non-Responsibilities (Out of Scope)

Ansible **does not**:

- Perform first-boot access bootstrapping
- Create or destroy virtual machines
- Manage VM lifecycle or infrastructure objects
- Act as an interactive administration tool
- Perform ad-hoc or emergency configuration changes outside code
- Set, know, or manage the root account's password — the console-only
  break-glass credential is deliberately outside the authority of all three
  tools (cloud-init, Ansible, Terraform); it is set once by hand at install
  time and never appears in git, inventory, or vault

---

## Terraform Boundary

### Purpose

Terraform manages **infrastructure objects**, not operating system state.

In this platform, Terraform owns the **virtual machine lifecycle** and related
resource relationships.

---

### Responsibilities (In Scope)

Terraform is responsible for:

- Defining virtual machines
- Defining virtual hardware characteristics
- Attaching networks and storage
- Creating and destroying VMs predictably

---

### Explicit Non-Responsibilities (Out of Scope)

Terraform **does not**:

- Configure host or guest operating systems
- Manage users, authentication, or access
- Install or configure software inside systems
- Enforce configuration compliance
- Replace Ansible or cloud-init

---

## Boundary Enforcement Rules

- Any configuration that must persist belongs to **Ansible**
- DNS and hostname resolution are owned by external network infrastructure (upstream DHCP/dnsmasq), not by any tool in this platform
- cloud-init state must always be considered disposable
- Bootstrap logic must not leak into Ansible
- Long-lived configuration must not leak into cloud-init
- VM lifecycle logic must not leak into Ansible
- Public repositories must not contain operational identity values
- Operational identity values must live only in **private inventory**

Boundary violations are considered **design defects**, not implementation details.

---

## Summary

This platform enforces a strict separation between:

- **temporary bootstrap access** (cloud-init)
- **authoritative configuration and identity** (Ansible)
- **infrastructure lifecycle** (Terraform)

This model enables:
- reproducible rebuilds
- safe public documentation
- clear operational ownership
- long-lived system stability
