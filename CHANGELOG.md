## Unreleased

- Validates the MVP path from a wiped disk (2026-09-29): a fresh install taken
  through every runbook gate, Phases 0-2.5, converged with no failures on the
  first `site.yml` run and reported `changed=0` on the second, and again after
  the DNS-registration reboot. Console-only root break-glass confirmed: root
  refused over SSH, accepted at the console. Closes roadmap Stage 0 step 1 for the default
  run (networking staged, not cut over).
- `security` role: renders the whole `sshd_config` from a template, validated
  with `sshd -t`, in place of patching the file. On a fresh host cloud-init
  leaves a one-line `sshd_config` behind, so sshd had no sftp subsystem and
  Ansible fell back to piped file transfer. See `docs/implementation-notes.md`.
- Docs: the runbook drops the `--check` dry run on a fresh host (check mode
  cannot install `python3-apt`); the bootstrap procedure no longer tells you
  to `systemctl enable cloud-init` (the unit was renamed in cloud-init 24.3)
  and covers the installer's "Volume group name already in use" stop.

## v0.2.0 - 2026-08-13 (pre-release)

Scope: MVP hypervisor host. Hostname/DHCP-DNS registration, svc-ansible-only
sudo, console-only root break-glass, and a working KVM/libvirt stack —
confirmed working end-to-end on real hardware (`docs/hypervisor-deploy-runbook.md`
Phases 0-2.5).

What this release does:
- Confirms the MVP path (bootstrap → base convergence → DNS registration
  checkpoint) working end-to-end on real hardware, for the first time.
- `identity` role: ensures dhclient advertises the current hostname via DHCP
  (option 12), and removes any local human-range account other than
  `svc-ansible` (`identity_prune_human_users`, default `true`) — deletes the
  personal sudo user the Debian installer creates alongside root, so
  `svc-ansible` is the only account with sudo/shell access.
- `security` role: `security_lock_root` now defaults to `false`, preserving
  root's console password as an Ansible-unmanaged, console-only break-glass
  credential; `PermitRootLogin no` continues to block root over SSH
  unconditionally regardless of this setting.
- `kvm` role: fixes `kvm_admin_users`, which relied on the `ansible_user`
  magic variable — undefined in this repo's setup, since the connection user
  comes from `ansible.cfg`'s `remote_user`, not an inventory-level
  `ansible_user` — and failed the play. Now hardcodes `svc-ansible`.
- Adds `docs/hypervisor-deploy-runbook.md`: a top-level, end-to-end rebuild
  runbook restructured around the confirmed MVP path (Phases 0-2.5), with a
  new Phase 2.5 DNS registration checkpoint. Reframes the bridge/VLAN
  migration (Phases 3-4) as optional, deferred, and not yet validated on
  real hardware, and documents that a fresh host commonly needs two
  `site.yml` passes to fully converge, and that DHCP hostname propagation
  can take up to ~24h without a manual renewal/reboot.
- Updates `docs/hypervisor-design.md`, `docs/automation-boundaries.md`,
  `docs/hypervisor-bootstrap.md`, and `docs/ansible-inventory.md`/`.example.yml`
  to describe the break-glass/sudo model and a permanent-FQDN +
  `-e ansible_host=<bootstrap-fqdn>` override pattern for inventory — no
  static or DHCP-lease IP, and no mid-rebuild inventory edits.

What this release does not do yet:
- Configure the hypervisor bridge/VLAN networking (implemented, gated behind
  `--tags networking`, not yet validated on real hardware) or any host
  firewall rules.
- Provide guest VM networking — libvirt's default NAT network is disabled by
  default and the bridge meant to replace it is deferred, so a VM needing
  network access has no path yet.
- Manage VM lifecycles (Terraform, a later release).
- Install or configure an overlay networking client for remote management.
- Define automated update/maintenance policy or reboot coordination.
- Provide secrets management beyond the sample key.

## v0.1.0 - 2026-01-26 (pre-release)

Scope: hypervisor initial configuration.

What this release does:
- Documents the hypervisor architecture, networking model, automation boundaries, bootstrap steps, and implementation notes.
- Establishes a baseline Ansible role with core packages, SSH server, and time synchronization.
- Establishes an identity Ansible role with a permanent hostname, the `svc-ansible` automation user, and passwordless sudo.
- Establishes a security Ansible role that hardens SSH, enforces an allowlist for SSH users, and locks the root account by default.

What this release does not do yet:
- Configure the hypervisor bridge/VLAN networking or any host firewall rules.
- Install or configure the virtualization stack (KVM/libvirt) or manage VM lifecycles.
- Install or configure an overlay networking client for remote management.
- Define automated update/maintenance policy or reboot coordination.
- Provide secrets management, inventory conventions, or environment-specific values beyond the sample key.
