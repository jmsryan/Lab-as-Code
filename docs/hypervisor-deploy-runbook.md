# Hypervisor Deploy Runbook

## Purpose

This runbook is the **top-level, end-to-end procedure** for rebuilding the
hypervisor from a wiped disk to a fully converged, networked KVM host. It
sequences the manual bootstrap and the per-role deploy guides into one ordered
path with a verification gate at every stage.

It exists to make a full rebuild repeatable and safe: each phase has a
checkpoint that must pass before the next begins, and the final phase doubles as
the acceptance test for DHCP-only DNS (dnsmasq-provided hostname resolution).

This runbook drives the existing guides rather than restating them:

- `docs/hypervisor-bootstrap.md` — manual bootstrap (Phase 0)
- `docs/cloud-init-bootstrap-sop.md` — cloud-init USB media prep detail (Phase 0)
- `docs/ansible-inventory.md` — private inventory format (Phase 1)
- `docs/hypervisor-networking-deploy.md` — networking role workflow (Phase 3)
- `docs/hypervisor-virtualization-deploy.md` — KVM role workflow (Phase 2)

---

## Scope

- Covers a **full rebuild** of a single hypervisor host, bare metal to
  converged.
- Sequences `identity`, `baseline`, `security`, `kvm`, `networkd`, and
  `hypervisor-networking` in the correct order with safety gates.
- Does **not** cover VM creation (Terraform, a later release).
- Assumes the architectural intent in `docs/hypervisor-design.md` and
  `docs/automation-boundaries.md`.

---

## Naming and Inventory Model

Inventory is **name-based throughout**: `ansible_host` is always an FQDN, never
a DHCP lease IP. cloud-init registers the host in dnsmasq under its bootstrap
name (`local-hostname` in `cloud-init/meta-data`) before Ansible ever runs, so
name resolution works from the first boot.

There is exactly **one** inventory change across the whole rebuild: at the
Phase 2 boundary the host's name flips from the cloud-init bootstrap name to the
permanent `system_hostname` set by the `identity` role. After that the name is
stable — including across the Phase 3 IP move, where dnsmasq simply re-points the
A record to the new lease. This is the operational payoff of the DHCP-only DNS
design: no lease-IP hunting on re-runs.

```
Phase 0  Wipe + cloud-init bootstrap (manual)
  └─ gate: ssh svc-ansible@<bootstrap-fqdn> ; hostname = cloud-init local-hostname
Phase 1  Controller prep (inventory ansible_host = bootstrap FQDN + collections)
  └─ gate: ansible hypervisor -m ping  → pong
Phase 2  Base convergence  (identity → baseline → security → kvm ; networking SKIPPED)
  ├─ identity sets system_hostname → host re-registers under new name
  ├─ update inventory ansible_host: bootstrap FQDN → system_hostname FQDN
  └─ gate: hostname == system_hostname ; ping still pong ; chrony/libvirtd active ;
           /dev/kvm ; virsh pool-list default active
Phase 3  Networking migration + bridge  (RISKY — needs console/OOB)
  ├─ stage:  --tags networking  -e hypervisor_networking_apply=false
  │     └─ gate: staged 10-<iface>.network is DHCP-only (direct change proof)
  ├─ apply:  --tags networking  -e hypervisor_networking_apply=true
  ├─ reconnect on br0.<vlan> — SAME FQDN, no inventory edit (dnsmasq re-points A)
  └─ re-run: --tags networking  → verify-and-disarm cancels rollback timer
Phase 4  DNS / hostname acceptance test
  └─ host resolves names via dnsmasq AND is itself resolvable by system_hostname
```

All Ansible commands run from the `ansible/` directory.

---

## Phase 0 — Wipe & Bootstrap (manual)

Follow `docs/hypervisor-bootstrap.md`. In brief:

1. Install minimal Debian with DHCP networking.
2. Prepare the `CIDATA` USB: run `cloud-init/write-usb.sh` from a macOS
   workstation, which formats the drive FAT32 labelled `CIDATA` and copies
   `cloud-init/user-data` and `cloud-init/meta-data` to its root. See
   `docs/cloud-init-bootstrap-sop.md` for the full procedure, including
   `instance-id` handling for reused drives/hosts.
3. Install `cloud-init`, then reboot with the `CIDATA` USB inserted so it runs.

cloud-init's `meta-data` sets `local-hostname` (currently `hv-01`), so the host
advertises that name via DHCP and dnsmasq registers it — the host is reachable
by name immediately, before any Ansible run.

**Checkpoint:**

- `ssh svc-ansible@<bootstrap-fqdn>` (the `local-hostname` from
  `cloud-init/meta-data`, e.g. `hv-01` or `hv-01.<domain>`) succeeds with the
  automation SSH key.
- On the host, `hostname` shows that same bootstrap name — the `identity` role
  has not run yet.

> If DNS has not propagated yet, the raw DHCP-lease IP is an acceptable fallback
> for this first connection only. Everything after Phase 1 is name-based.

---

## Phase 1 — Controller Prep

1. Create the private inventory at `ansible/inventory/hosts.yml` per
   `docs/ansible-inventory.md`. Set `ansible_host` to the **bootstrap FQDN**
   (the cloud-init `local-hostname`), plus:
   - `system_hostname`, `system_timezone`
   - `net_phys_iface` (physical NIC, e.g. `eno1`)
   - `net_bridge_name: br0`
   - `net_server_vlan` (host PVID)
   - `net_allowed_vlans` (list of trunked VLAN IDs — **must include**
     `net_server_vlan`)
2. Install required collections:

   ```bash
   cd ansible
   ansible-galaxy collection install -r requirements.yml
   ```

**Checkpoint:**

- `ansible hypervisor -m ping` returns `pong` — proves name-based reach and key
  auth are working.

---

## Phase 2 — Base Convergence (safe; no networking changes)

The default `site.yml` run applies `identity → baseline → security → kvm`. The
two networking roles are gated behind `never` + `networking` and are **skipped**
by a default run.

```bash
cd ansible
ansible-playbook site.yml --check    # dry run
ansible-playbook site.yml            # apply
```

The `identity` role changes the host's name from the cloud-init bootstrap name
to `system_hostname`, and the host re-registers in dnsmasq under the new name.

- If `system_hostname` **differs** from the cloud-init `local-hostname`
  (`hv-01`), **update inventory `ansible_host` to the `system_hostname` FQDN
  now** and confirm `ansible hypervisor -m ping` still returns `pong`.
- If the operator set `system_hostname: hv-01`, no inventory change is needed.

**Checkpoint:**

- On the host, `hostname` equals `system_hostname`, and the controller reaches
  it by the new FQDN (`ansible hypervisor -m ping` → `pong`). This already
  exercises dnsmasq registration over the ifupdown/dhclient path; Phase 4 is the
  formal DNS acceptance.
- `systemctl is-active chrony libvirtd` reports both `active`.
- `/dev/kvm` exists.
- `virsh pool-list --all` shows the `default` pool active with autostart on.
- `virsh net-list --all` does **not** list the `default` NAT network.

> Per `docs/hypervisor-virtualization-deploy.md`: `virsh` without sudo requires
> the admin user to re-login after this run — group membership only applies on
> the next session. Log out and back in (or reconnect SSH) before expecting
> `virsh list` to work unprivileged.

---

## Phase 3 — Networking Migration + Bridge (RISKY)

> **Have console or out-of-band access before starting.** The host IP moves to
> the server-VLAN subinterface and connectivity may drop mid-play. Two
> independent dead-man rollback timers cover this:
> - the `networkd` migration arms a **hardcoded 5-minute** timer;
> - the `hypervisor-networking` bridge arms a **10-minute** timer
>   (`hypervisor_networking_rollback_window`, default `600`).

### 1. Stage (safe — no restart)

```bash
cd ansible
ansible-playbook site.yml --tags networking -e hypervisor_networking_apply=false
```

This runs the `networkd` migration — which renders the DHCP-only
`primary.network.j2` and migrates the primary NIC under its own 5-minute
rollback — and stages the bridge/VLAN configs without restarting networking.

Because the freshly bootstrapped host is still on ifupdown/DHCP, the `networkd`
role does **not** short-circuit and renders the template end-to-end.

**Checkpoint — direct change proof (DHCP-only DNS):** on the host,

```bash
cat /etc/systemd/network/10-<iface>.network
```

shows only a `[Match] Name=…` block and `[Network] DHCP=yes` — no `Address=`,
`Gateway=`, `DNS=`, or `Domains=` lines. Confirm nothing static leaked into the
primary NIC unit:

```bash
grep -rn 'Address=\|Gateway=\|DNS=\|Domains=' /etc/systemd/network
```

### 2. Apply (risky — restarts networkd)

```bash
ansible-playbook site.yml --tags networking -e hypervisor_networking_apply=true
```

The role restarts `systemd-networkd` and ends the play, warning that the IP may
change.

### 3. Reconnect

The host is now DHCP on `br0.<vlan>` and its lease IP changes. Because inventory
already targets the `system_hostname` FQDN (set in Phase 2), **no inventory edit
is needed** — dnsmasq re-points the A record to the new lease and re-runs resolve
automatically. Allow a few seconds for the new lease / DNS update before
reconnecting.

### 4. Re-run to verify and disarm

```bash
ansible-playbook site.yml --tags networking
```

The `hypervisor-networking` role's verify-and-disarm block confirms the bridge,
the VLAN subinterface address, and the default route are healthy, then cancels
the 10-minute rollback timer.

> The `networkd` role's own 5-minute timer is disarmed inline during the apply
> run itself, so only the `hypervisor-networking` timer needs this second pass.

---

## Phase 4 — DNS / Hostname Acceptance Test

This phase confirms the DHCP-only DNS change end to end.

On the host:

- `resolvectl status` — the DNS server on `br0.<vlan>` is the dnsmasq/router IP
  learned via DHCP; `/etc/resolv.conf` points at the systemd-resolved stub
  (`127.0.0.53`), with nothing static pinned.
- Forward resolution: `resolvectl query <known-lab-hostname>` resolves to an
  address.
- Reverse resolution: `resolvectl query <a-lab-ip>` returns a name (dnsmasq
  PTR).

From another host or the router:

- The hypervisor's own `system_hostname` resolves to its current lease IP. This
  is the end-to-end proof that networkd's `SendHostname=yes` default registered
  the `identity`-role hostname in dnsmasq (DHCP option 12).

---

## Validation Checklist

- Phase 0: SSH by bootstrap name works; `hostname` = cloud-init `local-hostname`.
- Phase 1: `ansible hypervisor -m ping` → `pong`.
- Phase 2: `hostname` = `system_hostname`; ping still `pong` after the FQDN
  switch; `chrony` and `libvirtd` active; `/dev/kvm` present; `default` pool
  active; no `default` NAT network.
- Phase 3: staged `10-<iface>.network` is DHCP-only; bridge and VLAN subif come
  up after apply; rollback timers disarmed.
- Phase 4: host resolves lab names via dnsmasq (forward + reverse) and is itself
  resolvable by `system_hostname`.

---

## Optional Regression

- Idempotency: `ansible-playbook site.yml` a second time makes zero changes
  across `identity`, `baseline`, `security`, and `kvm`.
- Rollback safety test (run from `ansible/`):

  ```bash
  ansible-playbook tests/test-hypervisor-networking-rollback.yml
  ```

  This runs the preflight checks. The live test is `never`-gated; add
  `--tags live-fire` to exercise it. Full path:
  `ansible/tests/test-hypervisor-networking-rollback.yml`.

---

## Common Pitfalls

- **Forgot `--tags networking`** → the networking roles never run; the host
  stays on ifupdown.
- **Applied networking without console/OOB access** → an unexpected IP move can
  lock you out until the dead-man timer rolls back.
- **`system_hostname` changed but inventory `ansible_host` not updated** →
  re-runs after Phase 2 fail to connect under the old name.
- **`virsh` still asks for sudo** → the admin user has not re-logged in since the
  `kvm` role added group membership.
- **Cleanup on a host with other valid networkd configs** →
  `hypervisor_networking_cleanup` (default `true`) removes non-approved
  `/etc/systemd/network/*` files; disable it if the host has other configs.

---

## Related Files

- `ansible/site.yml`
- `ansible/roles/identity/`, `ansible/roles/baseline/`, `ansible/roles/security/`
- `ansible/roles/networkd/`, `ansible/roles/hypervisor-networking/`,
  `ansible/roles/kvm/`
- `cloud-init/user-data`, `cloud-init/meta-data`, `cloud-init/write-usb.sh`
- `docs/hypervisor-bootstrap.md`
- `docs/cloud-init-bootstrap-sop.md`
- `docs/hypervisor-networking-deploy.md`
- `docs/hypervisor-virtualization-deploy.md`
- `docs/ansible-inventory.md`
</content>
