# Ansible Inventory Format (Private)

## Purpose

The `inventory/` directory is intentionally **gitignored** to avoid publishing
operational identity and network details. This document describes the expected
format and required variables without exposing real values.

---

## Location

The default inventory path is:

- `ansible/inventory/hosts.yml`

This is configured in `ansible/ansible.cfg`.

An example file (with placeholders only) lives at:

- `docs/ansible-inventory.example.yml`

---

## Minimal Inventory Example (No Real Values)

```yaml
all:
  hosts:
    hypervisor:
      ansible_host: "<HOST_IP>"
      system_hostname: "<HOSTNAME>"
      system_timezone: "<TIMEZONE>"
      net_phys_iface: "<NIC_NAME>"
      net_bridge_name: "br0"
      net_server_vlan: <VLAN_ID>
      net_allowed_vlans: [<VLAN_ID>, <VLAN_ID>, <VLAN_ID>]
```

---

## Variable Notes

- `ansible_host` is the address used by Ansible to connect
- `system_hostname` and `system_timezone` are used by the base roles
- `net_phys_iface` must be the physical NIC name (e.g., `eno1`)
- `net_bridge_name` defaults to `br0` but can be changed
- `net_server_vlan` is the host's own VLAN (PVID)
- `net_allowed_vlans` must include `net_server_vlan`

---

## Privacy Guidance

- Keep inventory under `ansible/inventory/` only on trusted machines
- Avoid committing any real hostnames, IPs, or VLAN identifiers
- If you share this repo, include **only** the format, not values
