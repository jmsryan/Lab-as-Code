# Hypervisor Virtualization Deployment Guide

## Purpose

This guide translates the **virtualization design** into **repeatable
Ansible steps**. It documents prerequisites, variables, a safe apply
workflow, and validation checks for rolling the KVM stack onto a fresh
hypervisor.

This guide assumes the architectural intent described in:
- `docs/hypervisor-virtualization.md`
- `docs/hypervisor-design.md`
- `docs/hypervisor-networking.md`
- `docs/automation-boundaries.md`

---

## Scope

- Applies to the `kvm` Ansible role
- Covers KVM + libvirt installation, default storage pool, and operator
  access
- Does **not** cover VM creation (that lives in the Terraform tree, added
  in a later release)
- Does **not** cover host networking (see `hypervisor-networking-deploy.md`)

---

## Prerequisites

### Hardware

- CPU with VT-x (Intel) or AMD-V virtualization extensions
- Virtualization explicitly enabled in firmware/BIOS
- `/dev/kvm` exposed to the kernel (the role asserts this)

### Host OS

- Debian 12 (bookworm) or newer
- The host has a working APT mirror

`br0` is **not** a prerequisite for this role: it installs and configures
libvirt without touching networking, and converges on a host that has not
cut over. Guests need `br0` to attach to, which is Terraform's concern.

### Ansible controller

- Required collections installed:

  ```bash
  cd ansible
  ansible-galaxy collection install -r requirements.yml
  ```

  This installs `community.libvirt` alongside the existing collections.

---

## Required Variables

The `kvm` role has **no required inventory variables**. All defaults are
sensible for a single-host MVP.

---

## Optional Variables

These variables can be overridden in inventory or via `-e`:

- `kvm_admin_users` — list of users added to the `libvirt` and `kvm`
  groups. Defaults to `[svc-ansible]`.
- `kvm_storage_pool_name` — libvirt pool name. Defaults to `default`.
- `kvm_storage_pool_path` — filesystem path backing the pool. Defaults to
  `/var/lib/libvirt/images`.
- `kvm_disable_default_network` — when `true` (default), the role removes
  libvirt's built-in NAT network. Set to `false` only if a guest needs an
  isolated NAT segment.

---

## Apply Workflow

The KVM role is **safe to apply directly**. It does not restart the host,
does not change networking, and is fully idempotent on re-run.

### First-time apply

```bash
cd ansible
ansible-playbook site.yml --tags kvm
```

Skip `--check` on a fresh host: it fails at the first `apt` task with
`python3-apt must be installed to use check mode`. It works normally once a
real run has completed.

### Subsequent runs

The role is included in the default `site.yml` run (no `--tags` filter
needed) once initial convergence is complete. It will be a no-op if the
host is already converged.

### Operator login refresh

Group membership for `kvm_admin_users` only takes effect on the user's
**next login session**. After the first successful run, log out and back
in — or reconnect SSH — before expecting `virsh list` to work without
sudo.

---

## Validation Checklist

After applying:

- `systemctl is-active libvirtd.socket` returns `active`. `libvirtd` itself
  is socket-activated and exits after two minutes idle, so `inactive` there is
  normal
- `ls /dev/kvm` exists and is readable by the `kvm` group
- `virsh pool-list --all` shows the `default` pool as **active** and
  **autostart enabled**
- `virsh net-list --all` does **not** show the `default` NAT network
  (assuming `kvm_disable_default_network` is left at its default)
- `id <admin user>` shows membership in both `libvirt` and `kvm`
- `virsh list --all` runs without sudo for the admin user (after a
  re-login)

---

## Common Pitfalls

- **Virtualization disabled in firmware** → role aborts on the
  `/dev/kvm` assertion. Reboot into firmware setup, enable VT-x/AMD-V,
  reboot, re-run.
- **Stale login session** → operator added to groups but `virsh` still
  prompts for sudo. Log out and back in.
- **Pool inactive after reboot** → indicates autostart did not get set.
  Re-run the role; the autostart task is idempotent and will correct it.
- **Default NAT network unexpectedly present** → either
  `kvm_disable_default_network` was set to `false`, or a previous run
  failed before reaching the cleanup task. Re-run.
- **Unable to attach VMs to `br0`** → the bridge is staged but the host has
  not cut over. See `hypervisor-deploy-runbook.md` Phase 3.

---

## Quickstart Checklist

- Confirm `/dev/kvm` exists on the host
- `ansible-galaxy collection install -r requirements.yml` on the controller
- `ansible-playbook site.yml --tags kvm` to apply (`--check` only after a
  first real run)
- Log out and back in as the admin user before using `virsh`
- Validate with `virsh pool-list --all` and `virsh net-list --all`

---

## Related Files

- `ansible/roles/kvm/`
- `ansible/requirements.yml`
- `docs/hypervisor-virtualization.md`
- `docs/hypervisor-networking.md`
- `docs/automation-boundaries.md`
