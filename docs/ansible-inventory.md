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
      ansible_host: "<PERMANENT_FQDN>"
      system_hostname: "<HOSTNAME>"
      system_timezone: "<TIMEZONE>"

      # Required on every run: a default site.yml run stages the bridge
      # config, and hypervisor-networking asserts these are defined
      net_phys_iface: "<NIC_NAME>"
      net_bridge_name: "br0"
      net_server_vlan: <VLAN_ID>
      net_allowed_vlans: [<VLAN_ID>, <VLAN_ID>, <VLAN_ID>]
```

---

## Variable Notes

- `ansible_host` is the address used by Ansible to connect. Always an FQDN,
  never a static or DHCP-lease IP. Set it once to the **permanent** name
  (matching `system_hostname`'s domain) and never edit it again — it won't
  actually resolve until the `identity` role has run once and set that
  hostname. Until then, reach the host by overriding on the command line
  instead: `ansible-playbook site.yml -e ansible_host=<bootstrap-fqdn>` (the
  cloud-init `local-hostname`). See `docs/hypervisor-deploy-runbook.md`
  Phases 1, 2, and 2.5 for the exact sequence.
- `system_hostname` and `system_timezone` are used by the base roles
- `system_hostname` is also what the DHCP client advertises upstream, so it's what the network's DNS (dnsmasq) resolves the host by — after a hostname change, this only takes effect once the DHCP lease is renewed (reboot, or manual renewal from console); see `docs/hypervisor-deploy-runbook.md` Phase 2.5
- `net_phys_iface`, `net_bridge_name`, `net_server_vlan`, `net_allowed_vlans` are consumed by `hypervisor-networking`, which runs on every default `site.yml` run to stage the bridge config (the cutover itself stays gated on `hypervisor_networking_apply`). The role asserts all four, so a run fails without them
- `net_phys_iface` must be the physical NIC name (e.g., `eno1`)
- `net_bridge_name` defaults to `br0` but can be changed
- `net_server_vlan` is the host's own VLAN (PVID)
- `net_allowed_vlans` must include `net_server_vlan`

---

## Privacy Guidance

- Keep inventory under `ansible/inventory/` only on trusted machines
- Avoid committing any real hostnames, IPs, or VLAN identifiers
- If you share this repo, include **only** the format, not values
