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
