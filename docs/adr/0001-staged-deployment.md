# 0001 — Deploy in Stages, Not a Single Convergence Pass

- **Status:** Accepted
- **Date:** 2026-09-30
- **Supersedes:** [roadmap.md](../roadmap.md) Stage 0, steps 3–4

## Context

The hypervisor was designed to converge in one `ansible-playbook site.yml`
run: identity, baseline, security, networking, and KVM, top to bottom, with
nothing left for an operator to do.

The networking cutover breaks that model. Handing the NIC from ifupdown to
systemd-networkd and enslaving it to the bridge can move the host's address,
so `hypervisor-networking` ends the play (`meta: end_play`) immediately after
the cutover. Everything after it in `site.yml` — currently the `kvm` role —
never runs in the same pass. The roadmap treated this as a defect: Stage 0
planned to remove `end_play` and flip `hypervisor_networking_apply` to `true`
so a single run could survive severing its own connection.

Two things changed:

- **Experience with staged platform deployments.** Building Azure landing zones
  in Azure DevOps with Bicep, connectivity is deployed as its own pipeline
  stage, after governance and identity, behind its own approval and checks —
  because a mistake there has the largest blast radius. Each stage is
  validated before the next begins, and stages pass explicit outputs forward.
  The cutover here is the same kind of step, and the single-pass design was
  fighting it rather than isolating it.
- **Terraform is next.** The VM layer and a Kubernetes cluster are about to be
  built on top of the hypervisor. Whatever shape the deployment has when that
  work starts is the shape Terraform will depend on, and the shape CI/CD will
  later have to drive. Restructuring after that point means redoing both.

## Decision Drivers

1. **Understanding of best practice has evolved.** Ansible's own sample layout
   is a `site.yml` that imports per-tier playbooks, each runnable on its own,
   and Red Hat's good-practices guide asks for roles that are idempotent and
   check-mode safe. Staged pipelines with gates between stages are the norm in
   CI/CD generally. The single-pass goal predates that understanding.
2. **Modularity allows later enhancements without refactoring the run.** With
   stages as discrete units, cross-cutting additions — logging, monitoring,
   joining the host to Tailscale, a new pre-flight check — become a new stage
   or a change to one stage, not a rework of the whole run.
3. **CI/CD should be easy to add later.** Pipeline stages should map onto
   existing units of work, not require carving them out of a monolith.
4. **Avoid rework once Terraform depends on this.** Settle the structure
   before the VM layer is built on top of it.
5. **Isolate the one disruptive step.** The cutover is the only operation that
   can make the host unreachable. It should be its own stage with its own
   gate, not a step in the middle of everything else.

## Considered Options

### 1. Keep a single pass; engineer around `end_play`

The plan in roadmap Stage 0: pin the bridge MAC so the address survives
(done), remove `end_play`, verify in-run, and default the apply flag to
`true`.

- Good: one command, one run, no orchestration.
- Bad: every run carries the cutover's blast radius, and the riskiest step has
  no gate of its own.
- Bad: depends on the connection surviving a cutover, which is not yet proven.
- Bad: CI would still need to split the run later to add an approval in front
  of the cutover.

### 2. Staged playbooks, driven by a thin script until CI exists

Split the run into stage playbooks along existing boundaries. Keep `site.yml`
as a wrapper. A short script runs the stages in order until a pipeline
replaces it.

- Good: usable today, from a workstation, with no secrets decision.
- Good: each stage can be checked and tested on its own.
- Good: a pipeline later maps one-to-one onto the stages.
- Bad: more files, and a script that is intended to be discarded.

### 3. Go straight to a CI pipeline

- Good: no interim script.
- Bad: blocked on roadmap Stage 2 (secrets and inventory), and on the runner
  decision in Stage 5. Terraform work would wait on both.

## Decision

**Option 2.** The organizing principle:

> **The stage is the durable unit. The orchestrator is replaceable.**

The script and the eventual pipeline are two runners over the same stages.
Replacing one with the other changes the runner, not the stages.

### Stages

Illustrative; boundaries follow the existing roles and the existing
stage/apply split in the networking roles.

| Stage | Contents | Risk |
|---|---|---|
| Base | `identity`, `baseline`, `security` | Low; rerun freely |
| Network stage | `hypervisor-networking` with apply off — writes config only | Low |
| Network cutover | `hypervisor-networking` with apply on; ends the play by design | **High**; gated |
| Reachability | `wait_for_connection`, then a check-mode rerun of earlier stages | None; read-only |
| Virtualization | `kvm` | Low |
| VM layer | `terraform apply` (future) | Varies |

`site.yml` remains as an `import_playbook` wrapper so a manual full run still
works.

### Rules that keep the orchestrator replaceable

1. **One stage is one command.** The script runs each stage in order and stops
   on a non-zero exit. No branching, retries, or state tracking in shell.
2. **Gates live in Ansible, not in the orchestrator.** Reachability, zero-change
   check-mode reruns, and pre-flight assertions are tasks in playbooks, so a
   pipeline calls them exactly as the script does.
3. **The cutover approval is the only deliberate difference.** The script asks
   for interactive confirmation; the pipeline will use a protected environment
   with a required reviewer. Both stand in for the same precondition: console
   access is available.
4. **No inputs a pipeline cannot supply.** Inventory, variables, and keys reach
   the stages the way CI will provide them. Nothing depends on a workstation's
   shell environment.

## Consequences

### Positive

- `end_play` stops being a defect. The cutover ending its play is the stage
  boundary; the next stage opens a fresh connection and proves reachability
  before doing anything.
- The validation bar becomes per-stage: **every stage reports zero changes on
  its second run.** That is stricter than "a fresh install converges on the
  third full run," and it is something a pipeline can assert.
- Stages can be tested in isolation, in whatever environment is cheapest for
  each. (Planned as ADR-0002; see [roadmap.md](../roadmap.md).)
- Stages have explicit outputs. The handoff Terraform needs from the
  hypervisor — libvirt connection URI, bridge name, storage pool, available
  VLANs — becomes a defined interface rather than facts Terraform discovers on
  its own, which keeps the tool boundary in
  [automation-boundaries.md](../automation-boundaries.md) intact.

### Negative

- More files and an orchestration layer for a single host.
- The script is throwaway by design. Kept to a thin sequencer, its cost is
  small and none of its contents need porting.
- Two ways to run everything (`site.yml` and the staged runner) must be kept
  in agreement.

### Deliberate departure from convention

CI/CD guidance commonly recommends keeping a tested rollback playbook. This
project does not have one for the cutover, by design. Restoring
`/etc/systemd/network` cannot undo a cutover: stopping systemd-networkd leaves
the bridge and VLAN netdevs in place with the physical NIC still enslaved, and
handing the NIC back to ifupdown produces a host running both stacks at once,
with an IP on a bridge port. That state is harder to diagnose than an
unreachable host. Recovery remains an out-of-band console procedure
([hypervisor-deploy-runbook.md](../hypervisor-deploy-runbook.md), Phase 3
step 5), and the approval gate in front of the cutover is the mitigation.

## Revisit When

CI runs the real-host stages and the script has nothing left to do. Delete the
script then, and record it here.

## References

- Ansible — [Sample Ansible setup](https://docs.ansible.com/ansible/latest/tips_tricks/sample_setup.html)
  (`site.yml` importing per-tier playbooks)
- Red Hat Communities of Practice — [Automation Good Practices](https://redhat-cop.github.io/automation-good-practices/)
  (idempotency, check mode, playbook structure)
- Ansible — [`wait_for_connection` module](https://docs.ansible.com/ansible/latest/collections/ansible/builtin/wait_for_connection_module.html)
- GitHub — [Deployments and environments](https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments)
  (required reviewers, environment-scoped secrets)
- Michael Nygard — [Documenting Architecture Decisions](https://cognitect.com/blog/2011/11/15/documenting-architecture-decisions)
