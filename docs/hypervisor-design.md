# Hypervisor Architecture & Configuration Requirements

## Purpose

This document defines the **intended architecture, constraints, and operational model** for a KVM-based hypervisor designed to be:

- secure by default  
- low maintenance  
- automation-owned  
- cloud-parallel in concept  

This specification is **implementation-agnostic** and intentionally omits environment-specific secrets. It describes *design intent*, not live configuration.

---

## 1. Design Principles

- **Automation First**  
  All configuration is declarative and reproducible. Manual changes are considered configuration drift.

- **Minimal Attack Surface**  
  The hypervisor runs only the software required for virtualization and secure access.

- **Stability Over Features**  
  The system is designed to remain unchanged for long periods, except for security updates.

- **Rebuild, Don’t Repair**  
  Host failures are resolved by redeployment from code, not manual troubleshooting.

- **Cloud-Parallel Thinking**  
  Concepts and tooling mirror public cloud patterns where possible.

---

## 2. Platform Scope

### In Scope
- Bare-metal hypervisor
- Virtual machine hosting
- Secure management access
- VLAN-aware networking

### Out of Scope
- Application workloads
- Container orchestration
- Routing or firewall services
- UI-driven management tools

---

## 3. Operating System Baseline

- Minimal Linux distribution (stable release)
- No graphical environment
- LVM-backed root filesystem to allow future disk expansion
- Predictable network interface naming
- Standard system time synchronization

---

## 4. Identity & Access Model

- **User Model**
  - Single automation user
  - No long-lived human accounts

- **Authentication**
  - SSH key–only access
  - Password authentication disabled
  - Root login disabled

- **Access Domains**
  - Trusted internal infrastructure network
  - Secure overlay network for remote management

---

## 5. Networking Architecture

### 5.1 Physical Network Model

- Hypervisor connects to a trunked switch port
- One **primary infrastructure VLAN** provides:
  - host connectivity
  - default guest VM connectivity
- Additional VLANs exist for **workload isolation**, not host management

> VLAN identifiers and addressing are abstracted intentionally.

---

### 5.2 Host Network Configuration

- Single Linux bridge configured with VLAN awareness
- Physical NIC attached to bridge
- Host IP address assigned only within the infrastructure VLAN
- No host-level routing or NAT between VLANs

---

### 5.3 Guest Virtual Machine Networking

- **Default VM behavior**
  - Guest NIC attached to bridge
  - Untagged traffic placed on infrastructure VLAN
  - Full east–west communication permitted within that VLAN

- **Isolated workloads**
  - Guest NIC may be VLAN-tagged at the hypervisor layer
  - VLAN awareness handled by virtualization tooling
  - Guest OS remains unaware of VLAN tagging

---

### 5.4 Inter-VLAN Policy

- Hypervisor acts strictly as a layer-2 participant
- No inter-VLAN routing or filtering performed on host
- Network security boundaries enforced externally (router or firewall appliance)

---

## 6. Virtualization Stack

- **Core Components**
  - KVM
  - libvirt

- **Configuration**
  - `libvirtd` enabled and managed as a system service
  - Automation user granted virtualization permissions

- **Lifecycle Management**
  - Virtual machine lifecycle defined declaratively
  - No manual VM creation or UI-driven changes

---

## 7. Secure Remote Access

- Overlay networking client installed on hypervisor
- Used exclusively for management access
- No application traffic exposed via overlay by default

---

## 8. Host Security Controls

- Host firewall configured with:
  - default deny inbound policy
  - explicit allow rules for management access
- No unnecessary services listening on external interfaces
- Continuous reduction of attack surface

---

## 9. Update & Maintenance Strategy

- Automatic installation of security updates only
- No unattended feature upgrades
- Controlled reboot policy
- Long-lived host with minimal operational touchpoints

---

## 10. Configuration Ownership

| Tool        | Responsibility                                      |
|-------------|-----------------------------------------------------|
| cloud-init  | First-boot identity and access bootstrapping        |
| Ansible     | Ongoing host configuration and compliance           |
| Terraform   | Virtual machine lifecycle management                |

No tool overlaps responsibilities.

---

## 11. Non-Goals

This system is **not** intended to:

- Host application workloads directly
- Provide network perimeter security
- Be interactively administered
- Accumulate ad-hoc configuration changes

---

## Summary

This hypervisor is designed as an **immutable, automation-owned substrate** with explicit trust boundaries and cloud-aligned operational patterns. The focus is on predictability, security, and long-term maintainability rather than feature breadth or convenience tooling.
