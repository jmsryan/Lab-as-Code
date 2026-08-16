# Future Work

Ideas that are understood well enough to write down but deliberately not
implemented. Each entry records the problem, the proposed approach, and what
still has to be proven before it lands.

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

**Proposal.** Set `MACAddress=` in the `[NetDev]` section of the bridge
`.netdev`, templated from the physical NIC's address
(`ansible_{{ net_phys_iface }}.macaddress`). DHCP should then return the same
lease, and the host should keep its address through the cutover.

**Payoff.** SSH survives the cutover, no inventory edit, no lease hunt — and the
play could verify in-run instead of ending and requiring a reconnect. It removes
most of the original justification for the dead-man switch that was deleted.

**Unproven.** The mechanism is sound but untested here. Worth confirming:

- whether `br0.<vlan>` picks up the pinned bridge MAC, or needs its own
  `MACAddress=` on the VLAN netdev
- whether the DHCP server keys on MAC alone or also on client-identifier, which
  `dhcpcd` and `systemd-networkd` may generate differently even with a matching
  MAC (`ClientIdentifier=mac` in `[DHCPv4]` is the lever if so)
- that the physical NIC's MAC is gathered before the bridge template renders

---

## IPv6 firewall coverage

Tracked in `ansible/roles/security/defaults/main.yml`. The `security` role has
no IPv6 rules, and the exposure is currently held closed at the other end by
`IPv6AcceptRA=no` on the server VLAN subinterface — declining connectivity
rather than securing it.

When firewall tasks are added they must cover both families (nftables
`inet`/`ip6` tables, or `ufw` with `IPV6=yes` and matching rules), and
`IPv6AcceptRA` should flip back to `yes` in the same change.
