# Cloud-init Bootstrap Media SOP

## Purpose

This is the standalone procedure for preparing a **clean cloud-init `CIDATA`
USB drive** from a macOS workstation using `cloud-init/write-usb.sh`. It
expands on Step 2 of `docs/hypervisor-bootstrap.md` ("Prepare cloud-init
Bootstrap Media") with the tool-specific detail: what the script does, how to
verify the media it produces, and — critically — how to make sure a reused
drive or a reused host actually gets a **clean** first boot instead of being
silently skipped by cloud-init's caching.

---

## Scope

- Covers `cloud-init/write-usb.sh`, run on a macOS workstation (it shells out
  to `diskutil`; no Linux/Windows equivalent is provided here).
- Produces the `CIDATA`-labeled FAT32 volume that the NoCloud datasource scans
  for on first boot.
- Does not cover editing the *content* of `cloud-init/user-data` /
  `cloud-init/meta-data` beyond the identity fields called out below — see
  those files directly for the full bootstrap config (SSH key, packages,
  timezone).

---

## Prerequisites

- macOS workstation with the repo checked out
- A spare USB thumb drive (its **entire contents will be erased**)
- `cloud-init/user-data` and `cloud-init/meta-data` reviewed for the target
  host (see "Before You Run It" below)

> `cloud-init` itself is **not** preinstalled on a minimal Debian netinst
> install — it only ships by default on Debian's official cloud images. It
> must be installed manually on the target host (`apt install cloud-init`)
> before this media has any effect; see Step 4 of
> `docs/hypervisor-bootstrap.md`.

---

## Before You Run It: What Makes This a *Clean* Bootstrap

cloud-init's NoCloud datasource treats `meta-data`'s `instance-id` as the
signal for "first boot." It only runs `user-data` when the `instance-id` on
the media differs from the one it already has cached in
`/var/lib/cloud/data/instance-id` on the target system:

> "if you are making updates to user-data you will also have to change the
> `instance-id`, or start the disk fresh"
> — [cloud-init NoCloud datasource reference](https://docs.cloud-init.io/en/latest/reference/datasources/nocloud.html)

Practical implications:

- **New host, fresh install** — the default `instance-id: hv-01` in
  `cloud-init/meta-data` is fine as-is; there's no prior cache to collide with.
- **Rebuilding the same host from a wiped disk** — also fine; a wiped disk has
  no `/var/lib/cloud` state to compare against.
- **Re-running cloud-init against a host that still has its old
  `/var/lib/cloud` state** (e.g. testing bootstrap media against an
  already-bootstrapped VM without reinstalling the OS) — bump `instance-id` in
  `cloud-init/meta-data` first, or cloud-init will see the same ID and skip
  `user-data` entirely. Alternatively, run `cloud-init clean --logs --reboot`
  on that host to clear its cached state
  ([`cloud-init clean` reference](https://docs.cloud-init.io/en/latest/reference/cli.html)).
- **Editing `user-data`** (SSH key, packages, timezone) for the same
  `instance-id` — bump `instance-id` too, otherwise the edits are silently
  ignored on a host that already ran that ID once.

If none of the edge cases above apply — the common case, a fresh OS install —
no `meta-data` edit is needed before running the script.

---

## Workflow

1. **Review identity fields.** Confirm `cloud-init/meta-data`'s
   `local-hostname` matches the target host, and bump `instance-id` if any of
   the reuse cases above apply.
2. **Plug in the USB drive.**
3. **Run the script:**

   ```bash
   cd cloud-init
   ./write-usb.sh
   ```

4. **Pick the drive** from the listed external/removable disks.
5. **Confirm** by typing the exact disk identifier shown (e.g. `disk4`) — this
   is a deliberate second gate since the operation erases the whole disk.
6. The script formats the disk FAT32 with volume label `CIDATA`, copies
   `user-data` and `meta-data` (plus `network-config`/`vendor-data` if present)
   to its root, and ejects it.

---

## Validation Checklist

- Script output shows `user-data`, `meta-data`, and `network-config` copied.
  `network-config` disables cloud-init's network configuration; without it
  cloud-init generates a fallback that breaks IPv4 on every boot. See
  "Networking Must Be Explicitly Disabled" in
  `docs/automation-boundaries.md`.
- Re-inserting the drive on macOS shows a volume named `CIDATA` containing
  exactly those files at its root (`ls /Volumes/CIDATA`).
- On first boot with this media inserted, `cloud-init status --wait` on the
  target host reports `done`, and the `final_message` from `user-data`
  ("cloud-init has finished... Ready for Ansible.") appears in
  `/var/log/cloud-init-output.log`.
- `ssh svc-ansible@<local-hostname>` succeeds with the automation key.

---

## Common Pitfalls

- **Reused drive/host, no `instance-id` bump** → cloud-init sees the same ID
  as before and silently skips `user-data`; nothing looks broken, the host
  just never gets configured.
- **Wrong drive selected** → the script's disk-identifier confirmation prompt
  exists specifically to catch this; read the size/name line before typing
  the identifier.
- **`user-data` edited but `meta-data` `instance-id` left unchanged** — same
  root cause as above.
- **Script run on non-macOS** → it hard-fails immediately; there is no
  Linux/Windows path implemented here.
- **SSH pubkey auth rejected with the correct key** → check
  `journalctl -u ssh` on the host for `User svc-ansible not allowed because
  account is locked`. cloud-init's `users` module defaults `lock_passwd:
  true` when no `passwd`/`hashed_passwd` is set, which locks the account in
  `/etc/shadow`; Debian's `sshd` runs `UsePAM yes`, and PAM's account phase
  (`pam_unix.so`) blocks *all* logins — pubkey included — for a locked
  account, not just password auth. `cloud-init/user-data` sets
  `lock_passwd: false` on the `svc-ansible` user for exactly this reason. If
  a host was bootstrapped before that line existed, unblock it in place with
  `usermod -p '*' svc-ansible` (sets an unmatchable hash rather than leaving
  an empty password field, unlike `usermod -U`/`passwd -u` on a bare `!`
  entry) — no need to re-bootstrap.

---

## Related Files

- `cloud-init/write-usb.sh`
- `cloud-init/user-data`, `cloud-init/meta-data`, `cloud-init/network-config`
- `docs/hypervisor-bootstrap.md` (Step 2 references this SOP)
- `docs/hypervisor-deploy-runbook.md` (Phase 0 references this SOP)
