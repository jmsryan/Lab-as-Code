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

Observed on the hypervisor: `eno1` at `b8:ca:3a:b1:a2:7f`, `br0` and `br0.20`
both at `46:c8:22:77:df:a5`.

**Approach.** `MACAddress=` in the `[NetDev]` section of the bridge `.netdev`,
templated from the physical NIC's address, plus `ClientIdentifier=mac` in the
`[DHCPv4]` section of the VLAN `.network`.

**Payoff.** SSH survives the cutover, no inventory edit, no lease hunt — and the
play could verify in-run instead of ending and requiring a reconnect. It removes
most of the original justification for the dead-man switch that was deleted.

**Status.** Implemented in `roles/hypervisor-networking`
(`templates/bridge.netdev.j2`, `templates/vlan.network.j2`, and the MAC
resolution tasks in `tasks/main.yml`). **Not yet validated.** The pinned address
cannot take effect on a running host: netdev properties are fixed when the
device is created, so `networkctl reload` will not change the MAC of an existing
bridge. It applies at the next boot.

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

## IPv6 firewall coverage

Tracked in `ansible/roles/security/defaults/main.yml`. The `security` role has
no IPv6 rules, and the exposure is currently held closed at the other end by
`IPv6AcceptRA=no` on the server VLAN subinterface — declining connectivity
rather than securing it.

When firewall tasks are added they must cover both families (nftables
`inet`/`ip6` tables, or `ufw` with `IPV6=yes` and matching rules), and
`IPv6AcceptRA` should flip back to `yes` in the same change.
