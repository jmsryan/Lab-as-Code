# Hypervisor Networking Deployment Guide

## Purpose

This guide translates the **networking design** into **repeatable Ansible steps**.
It documents prerequisites, required variables, and a safe apply workflow for
rolling this configuration onto a different server.

This guide assumes the architectural intent described in:
- `docs/hypervisor-networking.md`
- `docs/hypervisor-design.md`
- `docs/automation-boundaries.md`

---

## Scope

- Applies to the `hypervisor-networking` Ansible role using `systemd-networkd`
- Covers bridge + VLAN-aware trunk configuration
- Designed for homelab portability (safe-by-default, explicit apply)

---

## Prerequisites

### Network topology
- Switch port to the hypervisor is configured as a **VLAN trunk**
- One **infrastructure VLAN** provides host connectivity
- Optional workload VLANs are trunked to the host

### Host OS expectations
- `systemd-networkd` is installed and available
- `NetworkManager` and `ifupdown` are **not** actively managing interfaces
- The host has basic DHCP connectivity on the infrastructure VLAN

> DHCP-only on the server VLAN is an intentional design choice.

---

## Inventory Format (Private)

The `inventory/` directory is intentionally gitignored for privacy. Create your
private inventory using the format documented in:

- `docs/ansible-inventory.md`

---

## Required Variables

These variables are **required** by `hypervisor-networking`:

- `net_phys_iface` — physical NIC to enslave into the bridge
- `net_bridge_name` — bridge device name (default `br0`)
- `net_server_vlan` — VLAN ID used by the host itself (PVID)
- `net_allowed_vlans` — list of VLAN IDs trunked to the host

Optional behavior flags:

- `hypervisor_networking_apply` — apply networkd immediately (default `false`)
- `hypervisor_networking_cleanup` — remove non-approved networkd configs (default `true`)

> Cleanup is **destructive**: any `/etc/systemd/network/*.network|*.netdev|*.link`
> not created by this role will be removed.

---

## Safe Apply Workflow

1) **Stage only (default)**
- Run the playbook once with `hypervisor_networking_apply: false`.
- This writes configs under `/etc/systemd/network/` without restarting networking.

2) **Review staged files**
- Verify the new `.network` and `.netdev` files reflect your VLAN plan.

3) **Apply**
- Set `hypervisor_networking_apply: true` and re-run the playbook.
- The role restarts `systemd-networkd` and ends the play if networking changes.

4) **Reconnect**
- If the IP changes, re-run against the new address.

> Consider out-of-band access or console access before the apply step.

---

## Validation Checklist

After applying:
- `networkctl status` shows the bridge and VLAN interfaces as **managed**
- `ip addr show` confirms an address on the server VLAN subinterface
- `ip route show` confirms a default route via the infrastructure gateway
- Guest VMs attached to the bridge land on the expected VLANs

---

## Common Pitfalls

- **No DHCP on server VLAN** → host never receives an IP address
- **NetworkManager active** → `networkd` role aborts safely
- **Forgot to enable apply** → configs staged but no changes on the host
- **Cleanup enabled on a host with other networkd configs** → unexpected deletions

---

## Quickstart Checklist

- Confirm switch port is a trunk and DHCP exists on the server VLAN
- Create private inventory at `ansible/inventory/hosts.yml`
- Set `net_phys_iface`, `net_bridge_name`, `net_server_vlan`, `net_allowed_vlans`
- Run playbook with `hypervisor_networking_apply: false` to stage configs
- Review staged files under `/etc/systemd/network/`
- Re-run with `hypervisor_networking_apply: true` to apply and restart networking
- Reconnect at the new address if the IP changes

---

## Related Files

- `ansible/roles/hypervisor-networking/`
- `ansible/roles/networkd/`
- `docs/hypervisor-networking.md`
- `docs/ansible-inventory.md`
