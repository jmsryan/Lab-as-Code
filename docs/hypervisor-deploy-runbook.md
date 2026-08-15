# Hypervisor Deploy Runbook

## Purpose

This runbook is the **top-level, end-to-end procedure** for rebuilding the
hypervisor from a wiped disk to a converged MVP host. It sequences the manual
bootstrap and the per-role deploy guides into one ordered path with a
verification gate at every stage.

It exists to make a full rebuild repeatable and safe: each phase has a
checkpoint that must pass before the next begins. The MVP path (Phases 0-2.5)
is self-contained and includes its own DHCP-DNS registration proof (Phase
2.5) — it does not depend on the bridge/VLAN networking migration. Phases 3
and 4 cover that migration; they are implemented but **not yet validated on
real hardware**, and are optional/deferred until bridge work resumes.

**Status:** Phases 0-2.5 (the full MVP path) have been run end-to-end on real
hardware and confirmed working, including the Phase 2.5 DNS registration
checkpoint. Phases 3-4 (bridge/VLAN) remain implemented-but-unvalidated, as
above.

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
- The MVP path is `identity` → `baseline` → `security` → `kvm` (Phases 0-2.5)
  — a solid hostname/DHCP/sudo/break-glass posture with no bridge/VLAN work.
  **Confirmed working end-to-end on real hardware.**
- `networkd` and `hypervisor-networking` (Phases 3-4) are covered too, but are
  optional and deferred: built and gated behind `--tags networking`, not
  required for MVP, and not yet exercised against real hardware.
- Does **not** cover VM creation (Terraform, a later release).
- Assumes the architectural intent in `docs/hypervisor-design.md` and
  `docs/automation-boundaries.md`.

---

## Naming and Inventory Model

Inventory is **name-based throughout**: `ansible_host` is always an FQDN, never
a static IP or a DHCP-lease IP. Real hostnames/domains only ever live in the
gitignored `ansible/inventory/hosts.yml` — never in this repo's tracked docs
or example files, which use placeholders only.

`ansible_host` is set **once**, to the **permanent** name (matching
`system_hostname`'s domain), and is never edited again. The catch: that name
doesn't resolve until the `identity` role has run once and Phase 2.5 confirms
dnsmasq has registered it. cloud-init's bootstrap name (`local-hostname` in
`cloud-init/meta-data`) resolves immediately, though, so Phases 1 and the
first Phase 2 run reach the host by overriding the connection target on the
command line — `-e ansible_host=<bootstrap-fqdn>` — instead of writing a
transient value into inventory. Once Phase 2.5 confirms the permanent name
resolves, the override is dropped and every command after that (including
the optional, deferred Phase 3 IP move, where dnsmasq re-points the same A
record to the new lease) just uses plain `ansible-playbook site.yml`. Net
result: **zero** inventory edits across the whole rebuild.

```
Phase 0    Wipe + cloud-init bootstrap (manual)
  └─ gate: ssh svc-ansible@<bootstrap-fqdn> ; hostname = cloud-init local-hostname
Phase 1    Controller prep (inventory ansible_host = permanent FQDN, unresolved yet + collections)
  └─ gate: ansible hypervisor -m ping -e ansible_host=<bootstrap-fqdn>  → pong
Phase 2    Base convergence (identity → baseline → security → kvm ; networking SKIPPED)
  ├─ run with -e ansible_host=<bootstrap-fqdn> (permanent name doesn't resolve yet)
  ├─ identity sets system_hostname → deletes the installer's personal sudo user → ensures dhclient sends hostname
  └─ gate: hostname == system_hostname ; ping still pong ; chrony/libvirtd active ;
           /dev/kvm ; virsh pool-list default active
Phase 2.5  DNS registration checkpoint (MVP's DNS proof — no bridge required)
  ├─ reboot host (or renew DHCP lease from console) so dnsmasq re-registers the new name
  └─ gate: another host resolves system_hostname via dnsmasq → drop the -e override from here on
── MVP ends here ──────────────────────────────────────────────────────────
Phase 3    Networking migration + bridge (OPTIONAL, DEFERRED, RISKY — needs console/OOB)
  ├─ stage:  --tags networking  -e hypervisor_networking_apply=false
  │     └─ gate: staged 10-<iface>.network is DHCP-only (direct change proof)
  ├─ apply:  --tags networking  -e hypervisor_networking_apply=true
  ├─ reconnect on br0.<vlan> — SAME FQDN, no inventory edit (dnsmasq re-points A)
  └─ re-run: --tags networking  → verify-and-disarm cancels rollback timer
Phase 4    Post-migration DNS re-verification (OPTIONAL, DEFERRED)
  └─ host still resolves names via dnsmasq AND is itself resolvable by system_hostname
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
4. **Reboot a second time**, once cloud-init reports `done`. It installs
   `packages:` during the previous boot, after systemd would have activated
   them — leaving `dbus` installed but inactive, which makes `hostnamectl`
   fail and aborts the `identity` role's first task. See
   `docs/hypervisor-bootstrap.md` Step 5a.

cloud-init's `meta-data` sets `local-hostname` (currently `hv-01`), so the host
advertises that name via DHCP and dnsmasq registers it — the host is reachable
by name immediately, before any Ansible run.

**Checkpoint:**

- `ssh svc-ansible@<bootstrap-fqdn>` (the `local-hostname` from
  `cloud-init/meta-data`, e.g. `hv-01` or `hv-01.<domain>`) succeeds with the
  automation SSH key.
- On the host, `hostname` shows that same bootstrap name — the `identity` role
  has not run yet.
- `systemctl is-active dbus` returns `active` and `cloud-init status` is
  `done`, not `error` — proves the second reboot happened and cloud-init
  finished cleanly.

> If DNS has not propagated yet, the raw DHCP-lease IP is an acceptable fallback
> for this first connection only. Everything after Phase 1 is name-based.

---

## Phase 1 — Controller Prep

1. Create the private inventory at `ansible/inventory/hosts.yml` per
   `docs/ansible-inventory.md`. Set `ansible_host` to the **permanent** FQDN
   (matching the `system_hostname` you're about to set — e.g.
   `hypervisor.<your-domain>`), not the cloud-init bootstrap name. It won't
   resolve yet; that's expected, and you never edit this file again for
   naming reasons. Also set `system_hostname` and `system_timezone` — that's
   everything the MVP path (Phases 0-2.5) needs. `net_phys_iface`,
   `net_bridge_name`, `net_server_vlan`, and `net_allowed_vlans` are only
   required if/when you run the optional, deferred Phase 3
   (`--tags networking`).
2. Install required collections:

   ```bash
   cd ansible
   ansible-galaxy collection install -r requirements.yml
   ```

**Checkpoint:**

```bash
ansible hypervisor -m ping -e ansible_host=<bootstrap-fqdn>
```

Returns `pong` — proves name-based reach and key auth are working, via the
cloud-init bootstrap name (the only one that resolves at this point).

---

## Phase 2 — Base Convergence (safe; no networking changes)

The default `site.yml` run applies `identity → baseline → security → kvm`. The
two networking roles are gated behind `never` + `networking` and are **skipped**
by a default run.

`ansible_host` in inventory is the permanent FQDN, which doesn't resolve
until *after* this run and Phase 2.5. So this first run (and this run only)
needs the `-e ansible_host=` override pointed at the cloud-init bootstrap
name:

```bash
cd ansible
ansible-playbook site.yml --check -e ansible_host=<bootstrap-fqdn>    # dry run
ansible-playbook site.yml -e ansible_host=<bootstrap-fqdn>            # apply
ansible-playbook site.yml -e ansible_host=<bootstrap-fqdn>            # apply again
```

> **Run this twice.** On a freshly bootstrapped host, some `kvm`-role tasks
> depend on state this same run just created (packages just installed,
> `libvirtd` just started/enabled) and don't fully converge on the first
> pass — they show as skipped or incomplete, then complete on the second
> run. This is expected, not a bug; a third run should then show zero
> changes. See "Optional Regression" below.

> If you deliberately set `system_hostname` equal to the cloud-init bootstrap
> name (e.g. both `hv-01`), the permanent name already resolves and you can
> skip the override entirely, even on this first run.

The `identity` role changes the host's name from the cloud-init bootstrap name
to `system_hostname`, deletes the installer's personal sudo user (see
`docs/hypervisor-bootstrap.md` Step 3), and ensures dhclient will advertise
the new hostname on its next lease renewal. The `security` role hardens SSH
and leaves root's console password untouched (break-glass).

**Checkpoint:**

- On the host, `hostname` equals `system_hostname`. The controller still
  reaches it via the `-e ansible_host=<bootstrap-fqdn>` override
  (`ansible hypervisor -m ping -e ansible_host=<bootstrap-fqdn>` → `pong`) —
  the permanent FQDN doesn't resolve yet. That's Phase 2.5, below, since it
  needs a DHCP lease renewal this playbook run deliberately doesn't force.
- `systemctl is-active chrony libvirtd` reports both `active`.
- `/dev/kvm` exists.
- `virsh pool-list --all` shows the `default` pool active with autostart on.
- `virsh net-list --all` does **not** list the `default` NAT network.
- The installer's personal user is gone:

  ```bash
  ansible hypervisor -m command -a "getent passwd <personal-account>" -e ansible_host=<bootstrap-fqdn>
  # expect: empty output / non-zero rc
  ```

- Root break-glass access works from console but not SSH (still via the
  bootstrap name at this point — the permanent FQDN isn't resolvable until
  Phase 2.5):

  ```bash
  # from the controller or any remote machine:
  ssh root@<bootstrap-fqdn>        # expect: Permission denied / connection refused
  ssh svc-ansible@<bootstrap-fqdn> # expect: success, unaffected
  ```

  ```bash
  # on host, via physical/virtual console only:
  # log in as root using the password set during OS install (Step 3) — expect success
  ```

> Per `docs/hypervisor-virtualization-deploy.md`: `virsh` without sudo requires
> the admin user to re-login after this run — group membership only applies on
> the next session. Log out and back in (or reconnect SSH) before expecting
> `virsh list` to work unprivileged.

---

## Phase 2.5 — DNS Registration Checkpoint (MVP)

This is the MVP's DNS proof — it does not require the bridge/VLAN migration
in Phase 3. `identity` set the new hostname and made sure dhclient is
configured to advertise it, but the change only takes effect on the next
DHCP lease renewal. Renewing automatically from within the same Ansible run,
over the same interface Ansible is connected through, carries the same
category of connectivity risk the bridge migration is deferred to avoid — so
this step is manual, from console/out-of-band, not part of `site.yml`:

```bash
# on host, via console/OOB — NOT over the live Ansible SSH session:
sudo reboot
# — or, without a reboot —
sudo dhclient -r <iface> && sudo dhclient <iface>
```

> **Don't just wait for it.** Left alone, dhclient only renews (and re-sends
> the hostname) at the DHCP server's lease interval — commonly up to 24
> hours, and it depends entirely on your DHCP server's configured lease
> time. A reboot or the manual renewal above is the reliable way to get the
> new hostname into dnsmasq promptly; without one, the host can look
> unreachable-by-name for a long time even though nothing is actually wrong.

**Checkpoint:**

```bash
# from another host on the network, after the reboot/renewal:
getent hosts <system_hostname>
# or
resolvectl query <system_hostname>
```

Either resolves to the host's current lease IP — proof that `identity`'s
hostname change and dhclient's `send host-name` config actually registered
with dnsmasq.

**MVP ends here — confirmed working end-to-end on real hardware.** Phases 3
and 4 below are optional, deferred bridge/VLAN work — skip them unless
you're specifically picking that back up.

---

## Phase 3 — Networking Migration + Bridge (OPTIONAL, DEFERRED, RISKY)

> This phase is implemented but has not been validated end-to-end on real
> hardware. Treat it as a starting point to test carefully, not a proven path.

> **Have console or out-of-band access before starting, and confirm you can log
> in as root on it before you begin.** The host IP moves to the server-VLAN
> subinterface and connectivity drops mid-play. Root over SSH is blocked
> unconditionally, so the console password set in Phase 0 is the only way back
> in if the rollback also fails.
>
> One dead-man rollback timer covers this: `hypervisor_networking_rollback_window`,
> default `600` seconds. There is a single cutover — `hypervisor-networking`
> stages the bridge config and then imports `networkd`'s `handoff.yml`, so the
> host goes from ifupdown straight to the bridge with no intermediate state.
> Everything in steps 3–5 (reconnect, find the new lease, re-run to disarm) has
> to fit inside that window. Raise it for a first attempt:
> `-e hypervisor_networking_rollback_window=1200`.

### 1. Stage (safe — no restart)

```bash
cd ansible
ansible-playbook site.yml --tags networking -e hypervisor_networking_apply=false
```

This stages the bridge/VLAN/physical-NIC units, archives the current config,
and writes the rollback script. Nothing is stopped, started, masked, or
restarted — the cutover is gated on `hypervisor_networking_apply`, not on the
tag.

`networkd` runs here as a dependency with `networkd_stage_primary: false`, so
it deliberately renders **no** unit of its own. A `10-<iface>.network` would
match the same interface at a lower numeric prefix and win over the bridge's
`30-<iface>.network`.

**Checkpoint — the staged set is exactly the approved five, and DHCP-only:**

```bash
ls /etc/systemd/network/
# 10-br0.netdev  20-br0.network  21-br0.<vlan>.netdev
# 22-br0.<vlan>.network  30-<iface>.network      <- and nothing else

grep -rn 'Address=\|Gateway=\|DNS=\|Domains=' /etc/systemd/network
# no output — addressing is DHCP-only on the VLAN subinterface
```

**Checkpoint — the safety net is real before you rely on it:**

```bash
ansible-playbook tests/test-hypervisor-networking-rollback.yml
```

Preflight only, no network disruption. Confirms the rollback script is present
with mode `0700`, the archive exists, `systemd-run` is available, and a timer
can actually be armed and cancelled. Do not proceed to step 3 if this fails.

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

> There is only one timer, and this pass is what disarms it. If the verify
> assertions fail, the play stops with the timer still armed and the rollback
> fires on schedule — that is the intended behaviour. Do not re-run until it
> has fired and the host is reachable on its old address again.

### 5. If it goes wrong

The rollback fires on its own at the end of the window. To trigger it
immediately from the console instead of waiting:

```bash
/usr/local/sbin/networkd-hypervisor-rollback
```

That restores the archived config, disables systemd-networkd, unmasks
`ifup@.service`, re-enables `networking.service`, and raises the NIC with
`ifup --force`. If even that fails, the fully manual equivalent is:

```bash
systemctl disable --now systemd-networkd
systemctl unmask ifup@.service
systemctl enable --now networking
ifup --force <iface>
ip -4 addr show <iface>
```

`ifup --force` matters: `ifup -a` processes only interfaces marked `auto`, and
the NIC is `allow-hotplug`, so the plain service start will not raise it on its
own once udev has stopped re-firing for an already-present device.

---

## Phase 4 — Post-Migration DNS Re-Verification (OPTIONAL, DEFERRED)

Phase 2.5 already proved DHCP-DNS registration works on the MVP path. This
phase is a regression check that the same mechanism still holds after the
Phase 3 bridge/VLAN move — not the introduction of DNS validation.

On the host:

- `resolvectl status` — the DNS server on `br0.<vlan>` is the dnsmasq/router IP
  learned via DHCP; `/etc/resolv.conf` points at the systemd-resolved stub
  (`127.0.0.53`), with nothing static pinned.
- Forward resolution: `resolvectl query <known-lab-hostname>` resolves to an
  address.
- Reverse resolution: `resolvectl query <a-lab-ip>` returns a name (dnsmasq
  PTR).

From another host or the router:

- The hypervisor's own `system_hostname` still resolves to its current lease
  IP after the move — confirming networkd's `SendHostname=yes` default keeps
  the DHCP-DNS registration Phase 2.5 already proved, now on the bridge/VLAN
  subinterface instead of the primary NIC.

---

## Validation Checklist

- Phase 0: SSH by bootstrap name works; `hostname` = cloud-init `local-hostname`.
- Phase 1: `ansible hypervisor -m ping -e ansible_host=<bootstrap-fqdn>` → `pong`.
- Phase 2: `hostname` = `system_hostname`; ping still `pong` after the FQDN
  switch; `chrony` and `libvirtd` active; `/dev/kvm` present; `default` pool
  active; no `default` NAT network; installer's personal user is gone;
  `ssh root@<host>` rejected while console root login and `ssh svc-ansible@<host>`
  both succeed.
- Phase 2.5 (MVP complete here): after reboot/lease renewal, another host
  resolves `system_hostname` via dnsmasq.
- Phase 3 (optional/deferred): staged `10-<iface>.network` is DHCP-only;
  bridge and VLAN subif come up after apply; rollback timers disarmed.
- Phase 4 (optional/deferred): host still resolves lab names via dnsmasq
  (forward + reverse) and is itself resolvable by `system_hostname` after the
  bridge move.

---

## Optional Regression

- Idempotency: on a freshly bootstrapped host, Phase 2's first-run
  convergence commonly takes **two** `site.yml` runs (see the note under
  Phase 2) — a *third* run should then make zero changes across `identity`,
  `baseline`, `security`, and `kvm`. On an already-converged host, a single
  re-run making zero changes is the expected result.
- Rollback safety test (run from `ansible/`) — covers the optional/deferred
  Phase 3 machinery specifically, not the MVP path:

  ```bash
  ansible-playbook tests/test-hypervisor-networking-rollback.yml
  ```

  This runs the preflight checks. The live test is `never`-gated; add
  `--tags live-fire` to exercise it. Full path:
  `ansible/tests/test-hypervisor-networking-rollback.yml`.

---

## Common Pitfalls

- **Only ran `site.yml` once on a fresh host** → some `kvm`-role tasks depend
  on state that same run just created and show as skipped/incomplete rather
  than converged. Run it twice on first convergence (see Phase 2).
- **Skipped Phase 2.5, or rebooted/renewed and then didn't wait for it** →
  dnsmasq still resolves the *old* hostname (or nothing). Without a manual
  reboot/renewal, the DHCP client won't re-send the new hostname until the
  DHCP server's own lease interval elapses — commonly up to 24 hours — so this
  is the most common way the host looks broken when it isn't. On Debian 13
  that client is `dhcpcd`, so the no-reboot renewal is `dhcpcd -n <iface>`.
- **Ran `site.yml` without the second post-cloud-init reboot** → the first
  task (`identity : Set permanent hostname`) fails with `Failed to connect to
  system scope bus via local transport`. `dbus` was installed by cloud-init
  after systemd would have started it, so it is inactive. Reboot (Phase 0
  step 4) and re-run; `systemctl start dbus.socket dbus.service` is an
  equivalent in-place fix.
- **Personal account has an active session during Phase 2** → the account
  deletion task in `identity` uses no `force:`, so it fails loudly (not
  silently) if the installer's personal user still has a live session or
  owned process. Log out of that account/close its sessions before running
  `site.yml`.
- **Forgot `--tags networking`** → the (optional, deferred) networking roles
  never run; the host stays on plain DHCP, which is the expected MVP state.
- **Applied networking without console/OOB access** → an unexpected IP move can
  lock you out until the dead-man timer rolls back. Extra caution warranted
  since this path is unvalidated on real hardware.
- **Dropped `-e ansible_host=<bootstrap-fqdn>` before Phase 2.5** → any
  command run without the override between the first Phase 2 apply and the
  Phase 2.5 DNS checkpoint fails to connect, since inventory's `ansible_host`
  (the permanent FQDN) doesn't resolve yet.
- **Kept using `-e ansible_host=<bootstrap-fqdn>` after Phase 2.5** →
  harmless (still reaches the host via its old name, if that DNS entry is
  still around), but unnecessary — drop it once the permanent name resolves.
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
