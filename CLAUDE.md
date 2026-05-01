# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Declarative homelab configuration from bare-metal KVM hypervisor to VM workloads. Three tools own distinct layers with no overlap:

| Tool | Responsibility |
|------|---------------|
| cloud-init | Non-authoritative first-boot bootstrap to enable Ansible |
| Ansible | Authoritative host configuration — sole long-term source of truth |
| Terraform | VM lifecycle management (not yet in repo) |

**Key principle**: cloud-init state is disposable. Ansible owns all persistent state. Never let responsibilities bleed across tool boundaries.

## Running Ansible

All commands run from the `ansible/` directory:

```bash
# Install required collections (once)
ansible-galaxy collection install -r requirements.yml

# Dry-run check mode against hypervisor
ansible-playbook site.yml --check

# Full playbook run
ansible-playbook site.yml

# Run a single role
ansible-playbook site.yml --tags identity

# Stage networking config only (safe, no restart)
ansible-playbook site.yml --tags networking -e hypervisor_networking_apply=false

# Apply networking (restarts systemd-networkd — risky)
ansible-playbook site.yml --tags networking -e hypervisor_networking_apply=true

# Lint
ansible-lint
```

## Inventory (Private)

`ansible/inventory/` is gitignored. Create `ansible/inventory/hosts.yml` with:

```yaml
all:
  hosts:
    hypervisor:
      ansible_host: "<HOST_IP>"
      system_hostname: "<HOSTNAME>"
      system_timezone: "<TIMEZONE>"
      net_phys_iface: "<NIC_NAME>"      # e.g., eno1
      net_bridge_name: "br0"
      net_server_vlan: <VLAN_ID>
      net_allowed_vlans: [<VLAN_ID>, ...]
```

See `docs/ansible-inventory.md` for full variable notes and `docs/ansible-inventory.example.yml` for a placeholder template.

## Role Architecture

The `ansible/site.yml` playbook applies these roles in order to the `hypervisor` host group:

1. **identity** — permanent hostname and system identity (replaces cloud-init bootstrap identity)
2. **baseline** — base packages and OS configuration
3. **security** — firewall (default-deny inbound), SSH hardening, unattended security updates
4. **networkd** — migrates host from ifupdown/NetworkManager to systemd-networkd; idempotent short-circuit if networkd already owns the host; includes a rollback dead-man switch (tagged `risky rollback dev never`)
5. **hypervisor-networking** — configures a VLAN-aware Linux bridge (`br0`) with the physical NIC enslaved; stages configs under `/etc/systemd/network/`; apply is gated behind `hypervisor_networking_apply: false` by default

### Networking Two-Phase Design

The networking roles (`networkd` and `hypervisor-networking`) are gated behind the `networking` tag and are skipped by a default `site.yml` run. Pass `--tags networking` to include them.

The `hypervisor-networking` role is itself split into safe/risky phases:
- **Default** (`--tags networking`): stages `.network`/`.netdev` files without restarting networking
- **Apply** (`--tags networking` + `-e hypervisor_networking_apply=true`): restarts systemd-networkd and ends the play if the IP changes

The `networkd` role has a rollback mechanism using `at` jobs (tagged `rollback dev never` — not run by default).

### Cleanup Behavior

`hypervisor_networking_cleanup: true` (default) removes any `/etc/systemd/network/*.network|*.netdev|*.link` files not created by the role. Backups are taken before deletion. Disable this when the host has other valid networkd configs.

## Key Design Constraints

- No real hostnames, IPs, or VLAN IDs in the public repo — operational values live only in private inventory
- The hypervisor is a Layer-2 participant only; no routing, NAT, or inter-VLAN filtering on-host
- Host IP addressing is DHCP-only on the infrastructure/server VLAN subinterface
- `gather_facts: false` in `site.yml` — roles use selective fact gathering via the `networkd/detect.yml` task
