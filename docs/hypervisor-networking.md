# Hypervisor Networking Architecture

## Purpose

This document describes the **qualitative networking model** of the hypervisor.

It defines how the hypervisor:
- connects to the physical network
- participates in VLANs
- exposes connectivity to guest virtual machines
- avoids taking on routing or security responsibilities

## Release Status

Pre-release v0.1.0 (January 26, 2026). Scope: hypervisor initial configuration.

This document intentionally focuses on **design intent and traffic flow**, not
implementation-specific values or environment secrets.

A competent engineer should be able to reconstruct the networking approach
using this document in conjunction with the hypervisor design and automation
boundary artifacts.

---

## Design Goals

The hypervisor networking model is designed to be:

- **Simple**  
  Minimal moving parts and no implicit behavior.

- **Predictable**  
  Network behavior should be obvious from first principles.

- **Layered**  
  The hypervisor participates only at Layer 2; routing and security occur
  elsewhere.

- **Cloud-Parallel**  
  The model mirrors common public-cloud networking concepts where possible.

---

## Network Role of the Hypervisor

The hypervisor is treated as a **network participant**, not a network appliance.

Specifically, it is **not** responsible for:
- routing between networks
- firewalling traffic between workloads
- enforcing security policy between VLANs

Those responsibilities are intentionally delegated to external infrastructure
(e.g., routers, firewalls, or dedicated network services).

---

## Physical Network Integration

### Switch Connectivity

The hypervisor connects to the physical network via a **trunked switch port**.

This port provides:
- one primary infrastructure network
- multiple optional workload networks

The trunk model allows the hypervisor to:
- host workloads on multiple networks
- without embedding network policy into the host itself

---

### Infrastructure Network

One VLAN is designated as the **infrastructure (server) network**.

This network provides:
- connectivity for the hypervisor itself
- default connectivity for most guest virtual machines
- east–west communication between server workloads

This VLAN represents a **shared trust domain** appropriate for server-to-server
communication.

---

### Workload Isolation Networks

Additional VLANs may exist to support workloads that require:
- separation from the infrastructure network
- different routing or firewall policies
- controlled exposure to other network zones

Examples include:
- user-facing services
- guest-accessible services
- IoT-facing services

The hypervisor does not interpret or enforce the purpose of these networks; it
simply provides access to them when explicitly requested.

---

## Host Networking Model

### Bridge-Based Design

The hypervisor uses a **single Linux bridge** as its primary network abstraction.

Key characteristics:
- the physical NIC is attached to the bridge
- the bridge is VLAN-aware
- the bridge forwards both tagged and untagged traffic

This model provides:
- a unified attachment point for guest VMs
- minimal complexity
- clear separation between Layer 2 forwarding and higher-level concerns

---

### Host IP Addressing

The hypervisor itself:
- has an IP address only on the infrastructure network
- does not require IP addresses on other VLANs
- does not originate traffic on workload networks unless explicitly required

This reinforces the principle that:
> the hypervisor is *of* the infrastructure network, not *between* networks.

---

## Guest Virtual Machine Networking

### Default VM Connectivity

By default:
- guest VMs attach to the hypervisor bridge
- no VLAN tag is applied
- traffic is placed on the infrastructure network

This provides:
- straightforward connectivity
- no guest OS VLAN awareness
- behavior similar to attaching a VM to a standard server subnet

This is the **common case**.

---

### VLAN-Tagged VM Connectivity

For workloads requiring isolation:
- a VLAN tag may be applied at the hypervisor level
- tagging is handled by the virtualization layer
- the guest OS sees a normal Ethernet interface

This approach:
- avoids complexity inside guest operating systems
- keeps VLAN semantics explicit and visible in infrastructure code
- mirrors public-cloud subnet attachment models

---

## Inter-VLAN Traffic Policy

The hypervisor does **not**:
- route traffic between VLANs
- NAT traffic
- apply firewall rules between VLANs

Any inter-VLAN communication:
- must traverse external routing infrastructure
- is subject to external firewall and security policy

This ensures:
- clear security boundaries
- predictable traffic flow
- no “hidden” paths through the hypervisor

---

## Failure and Recovery Considerations

The networking model is designed so that:
- loss of the hypervisor does not alter network topology
- rebuilding the hypervisor does not require network reconfiguration
- VLAN semantics are preserved entirely outside the host

Because network policy is externalized, the hypervisor can be safely rebuilt
without impacting routing or security controls.

---

## Relationship to Automation

This networking model is intentionally aligned with the automation boundaries:

- **cloud-init**
  - does not configure networking topology
  - relies only on basic infrastructure connectivity

- **Ansible**
  - configures the bridge and VLAN awareness
  - enforces the intended network participation of the host

- **Terraform**
  - attaches virtual machines to the appropriate networks
  - defines VLAN usage per workload

No single tool crosses layers or assumes hidden responsibilities.

---

## Implementation & Deployment Notes

This document is intentionally qualitative. For **deployment details**, see:

- `docs/hypervisor-networking-deploy.md`

Key implementation constraints:

- Networking is implemented with **systemd-networkd** (not NetworkManager).
- The server VLAN interface is configured for **DHCP** by default.
- The Ansible role stages configs by default and requires an explicit apply flag.
- The role may remove non-approved networkd configs during cleanup.

---

## Summary

The hypervisor networking architecture treats the host as a **Layer 2 participant
with explicit, limited responsibility**.

By:
- centralizing routing and security elsewhere
- using a simple, bridge-based model
- making VLAN usage explicit but optional

the design achieves clarity, stability, and portability across environments.

This qualitative model is intended to be sufficient for reconstruction without
access to implementation-specific configuration.
