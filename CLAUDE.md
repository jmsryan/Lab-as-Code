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

# Run only the kvm role. Ansible does NOT auto-tag roles by name, and only
# kvm (and the two networking roles) carry tags in site.yml — identity,
# baseline, and security are untagged and cannot be selected individually.
# A --tags value matching nothing exits 0 with an empty PLAY RECAP.
ansible-playbook site.yml --tags kvm

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
4. **hypervisor-networking** — configures a VLAN-aware Linux bridge (`br0`) with the physical NIC enslaved; stages configs under `/etc/systemd/network/`; apply is gated behind `hypervisor_networking_apply: false` by default

**networkd** is not listed in `site.yml`. It is a dependency of `hypervisor-networking` (`roles/hypervisor-networking/meta/main.yml`), which passes it `networkd_stage_primary: false` and `networkd_apply: false`. Listing it separately would invoke it a second time with different parameters — Ansible only deduplicates a role when its parameters match — and that run would stage a `10-<iface>.network` competing with the bridge config. Dependencies inherit the parent's tags, so it stays gated behind `never` + `networking`.

The **networkd** role migrates a host from its legacy network stack (ifupdown + dhcpcd, NetworkManager) to systemd-networkd. It is config-agnostic and reusable on any server:
- **standalone** (default): stages a DHCP `.network` for the default-route NIC and performs the cutover itself
- **supplied** (`networkd_stage_primary: false`): another role stages the config and imports `networkd/tasks/handoff.yml` via `import_role` + `tasks_from` at the moment of cutover

### Networking Two-Phase Design

The networking roles are gated behind the `networking` tag and skipped by a default `site.yml` run. Pass `--tags networking` to include them.

Both roles gate the connection-breaking step behind a variable, not a tag. Tags alone are not a safety mechanism: role-level tags are additive, so a task tagged `risky` inside a role tagged `networking` is still selected by `--tags networking`.

- **Stage** (`--tags networking`): writes `.network`/`.netdev` files, archives the current config, stages the rollback script. Nothing is stopped, started, masked, or restarted.
- **Apply** (`--tags networking` + `-e hypervisor_networking_apply=true`): arms a dead-man switch, hands ownership over from the legacy stack, restarts systemd-networkd, and ends the play because the IP may change.

There is exactly **one** cutover. `hypervisor-networking` stages the bridge config first, then imports networkd's `handoff.yml`, so the host goes from ifupdown straight to the final bridge topology without an intermediate state where systemd-networkd and dhcpcd both hold the NIC.

The handoff stops and disables `networking.service`, stops `ifup@<iface>.service`, masks the `ifup@.service` template so udev cannot re-trigger it, and stops the dhcpcd process directly — dhcpcd has no systemd unit on Debian 13. `/etc/systemd/network.legacy-stack` records what was taken away so the rollback script restores only that.

### Cleanup Behavior

`hypervisor_networking_cleanup: true` (default) removes any `/etc/systemd/network/*.network|*.netdev|*.link` files not created by the role. Backups are taken before deletion. Disable this when the host has other valid networkd configs.

## Key Design Constraints

- No real hostnames, IPs, or VLAN IDs in the public repo — operational values live only in private inventory
- The hypervisor is a Layer-2 participant only; no routing, NAT, or inter-VLAN filtering on-host
- Host IP addressing is DHCP-only on the infrastructure/server VLAN subinterface
- DNS and hostname resolution are provided externally by the upstream DHCP server (dnsmasq) — no DNS/resolver configuration is staged anywhere in this repo; the `identity` role's `system_hostname` is what gets registered
- `gather_facts: false` in `site.yml` — roles gather selectively; `networkd` pulls only the `network` subset
