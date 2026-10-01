# Future Work

Ideas that are understood well enough to write down but not yet settled —
either deliberately not implemented, or implemented and awaiting validation on
real hardware. Each entry records the problem, the approach, and what still has
to be proven before it can be called done.

For how this work is sequenced against the project's larger goals, see
[roadmap.md](roadmap.md). MAC pinning below is Stage 0 of that roadmap — its
canonical description lives here, not there.

---

## Pin the bridge MAC to the physical NIC

**Problem.** The host's IP address changes across the networking cutover. That
change is the single largest source of friction in Phase 3 of
`hypervisor-deploy-runbook.md`: the play has to end mid-run, the operator has to
find the new lease, and a failed cutover is indistinguishable from a cutover
that merely moved.

**Cause.** `systemd-networkd` assigns a randomly generated MAC when it creates
the bridge netdev. Because that MAC is explicitly set at creation, the kernel's
usual behaviour — a bridge adopting the MAC of its first enslaved port — does
not apply. `br0.<vlan>` inherits the bridge's MAC rather than the physical
NIC's, so the DHCP server sees a new client and issues a different lease.

Observed on the hypervisor before pinning: the physical NIC kept its burned-in
address, while `br0` and `br0.<vlan>` shared a different, generated one.

**Approach.** `MACAddress=` in the `[NetDev]` section of the bridge `.netdev`,
templated from the physical NIC's address, plus `ClientIdentifier=mac` in the
`[DHCPv4]` section of the VLAN `.network`.

**Payoff.** SSH survives the cutover, no inventory edit, no lease hunt — and the
play could verify in-run instead of ending and requiring a reconnect. It removes
most of the original justification for the dead-man switch that was deleted.

**Status.** Implemented in `roles/hypervisor-networking`
(`templates/bridge.netdev.j2`, `templates/vlan.network.j2`, and the MAC
resolution tasks in `tasks/main.yml`). **Not yet validated across a cutover.**
Netdev properties are fixed when the device is created, so `networkctl reload`
will not change the MAC of an existing bridge — on a host already running the
bridge, the pin applies at the next boot. On a fresh install no bridge exists
yet, so the pin applies at the cutover itself. The 2026-09-29 rebuild is in the
second case: bridge staged, not cut over.

**Resolved since this was first written:**

- `br0.<vlan>` inherits the bridge's MAC and needs no `MACAddress=` of its own.
  It already tracks the bridge's randomly generated address today, so pinning
  the bridge propagates to the subinterface.
- The physical NIC's MAC is available at render time — the `networkd` role runs
  first as a dependency and gathers the `network` subset. A `set_fact` resolves
  it and an assert fails the run if it comes back empty, rather than staging a
  `.netdev` that systemd would refuse to load.
- `ClientIdentifier=mac` was included rather than held back as a contingency.
  networkd defaults to `ClientIdentifier=duid` and derives that DUID from
  `/etc/machine-id`, so a matching MAC on its own would still present a new
  identifier after a rebuild — precisely the Stage 0 case this is meant to fix.

**Still to prove.** Whether the DHCP server returns the prior lease. The first
boot after this lands changes the host's DHCP identity, so the address should be
expected to move once and then hold. Have console access available for it.

---

## The handoff may drop the host's address before networkd starts

**Blocks the next cutover.** Found by reading the code against the host on
2026-09-30; not yet reproduced.

**Problem.** `networkd/tasks/handoff.yml` stops `ifup@<iface>.service` before
it stops dhcpcd. That unit's `ExecStop` is `ifdown <iface>`, and ifupdown's
teardown for a DHCP interface on Debian 13 is `dhcpcd -k <iface>`. Per
dhcpcd(8), `-k` releases the lease and de-configures the interface
*regardless of* `persistent`. If that holds, the host loses its IPv4 address
mid-handoff — before the dhcpcd step's "host keeps its current address"
safety argument applies, and before `systemd-networkd` is restarted. The play
would then lose its connection with neither stack holding the NIC.

A second, smaller dependency sits behind the first: the dhcpcd step's own
safety (`dhcpcd -x`, then `pkill`) relies on `persistent` in
`/etc/dhcpcd.conf`, because dhcpcd de-configures on exit without it. Debian's
packaged file sets it; no role enforces it.

**Unexplained.** The 2026-08-15 cutover succeeded with this same ordering. Why
is not known, and should be understood before the ordering is changed.

**Approach (to evaluate).** Stop dhcpcd with `-x` while `persistent` holds —
asserting `persistent` first — and keep `ifdown` from running at all, for
example by masking `ifup@.service` and stopping the instance without its
`ExecStop`, rather than letting `systemctl stop` run it. Prove it in a VM
before the hypervisor (see ADR-0002 in [roadmap.md](roadmap.md)).

**Evidence.** On the host: `systemctl cat ifup@.service` shows
`ExecStop=/usr/sbin/ifdown %I`; the `ifup` binary carries `dhcpcd -k %iface%`
as its DHCP teardown. dhcpcd(8): "dhcpcd de-configures the interface when it
exits unless this option [`-p, --persistent`] is enabled"; `-k` "release[s]
its lease and de-configure[s] the interface regardless of the -p,
--persistent option."

---

## DNS after the cutover

**Decide before the next cutover.**

`systemd-resolved` is not installed, and `/etc/resolv.conf` is written by
dhcpcd. systemd-networkd does not write `resolv.conf` itself — it hands
DHCP-learned DNS servers to systemd-resolved — so after the cutover nothing
keeps `resolv.conf` in step with DHCP. The file dhcpcd left behind is all the
host has.

The design rule is "DNS provided externally via DHCP; no local resolver
configuration." Installing `systemd-resolved` arguably satisfies it — it
configures nothing, only consumes what DHCP offers — but it is a new package
on a minimal-surface host and should be a deliberate choice. Runbook Phase 4
currently assumes it.

---

## IPv6 firewall coverage

Tracked in `ansible/roles/security/defaults/main.yml`. The `security` role has
no IPv6 rules, and the exposure is currently held closed at the other end by
`IPv6AcceptRA=no` on the server VLAN subinterface — declining connectivity
rather than securing it.

When firewall tasks are added they must cover both families (nftables
`inet`/`ip6` tables, or `ufw` with `IPV6=yes` and matching rules), and
`IPv6AcceptRA` should flip back to `yes` in the same change.
