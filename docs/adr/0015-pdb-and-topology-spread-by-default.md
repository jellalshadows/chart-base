# ADR-0015: PDB and topology spread on by default

- **Status:** Accepted
- **Date:** 2026-09-27
- **Since:** 0.1.0

## Context

A Deployment with no PodDisruptionBudget has no protection against voluntary disruptions — a node
drain (upgrade, autoscaler scale-down, cordon-and-drain maintenance) can evict every one of its pods at
once, with nothing stopping it. A Deployment with no topology spread constraints has no protection
against the scheduler happening to place every replica on the same node or in the same zone, which
turns an involuntary disruption (a single node or zone failure) into a full outage of the component.
Both are opt-in Kubernetes features: a chart that leaves them off by default only protects the
consumers who remember to turn them on, for every component, in every umbrella — which in practice
means most components run unprotected, because resilience is easy to forget under a deadline and cheap
to skip when nothing has broken yet.

At the same time, a badly configured PDB can make drains *worse*, not better: `minAvailable` on a
single-replica component effectively blocks it from ever being drained cleanly (there is no way to keep
one pod available while evicting it), and the default `unhealthyPodEvictionPolicy` (`IfHealthyBudget`)
refuses to evict a pod that is not `Ready` if doing so would violate the budget — which can leave an
already-unhealthy pod stuck on a node that needs to drain. chart-base's defaults are chosen specifically
to give every Deployment disruption protection without ever becoming the reason a drain cannot
complete.

## Decision

- `pdb.enabled: true` by default (`values.yaml`); `templates/pdb.yaml` renders a `PodDisruptionBudget`
  (`policy/v1`) for every Deployment (`workload.type: deployment`) unless a consumer sets
  `pdb.enabled: false`. CronJobs and Jobs never get a PDB — they are not continuously running workloads
  a drain could meaningfully protect.
- Both `pdb.minAvailable` and `pdb.maxUnavailable` default to `null`. When neither is set,
  `templates/pdb.yaml` falls back to `maxUnavailable: 1`; the schema (`values.schema.json`) forbids
  setting both at once.
- `pdb.unhealthyPodEvictionPolicy` defaults to `AlwaysAllow` (`values.yaml`), rendered verbatim onto the
  PDB spec.
- Why `maxUnavailable: 1` and not `minAvailable`: `maxUnavailable: 1` still lets a single-replica
  component's one pod be evicted by a drain — the PDB only ever blocks a *second* concurrent eviction,
  never the first — whereas `minAvailable` on a single-replica component (`minAvailable: 1` would be
  the only sensible value) can never be satisfied while evicting its one pod, and blocks the drain
  outright. `AlwaysAllow` compounds the same goal from the other side: it lets a drain evict pods that
  are not currently `Ready` even if that pushes the component under its budget, instead of the default
  `IfHealthyBudget`, which can refuse to evict an already-unhealthy pod and leave a node unable to
  finish draining. Together, the defaults give every Deployment disruption protection that can never
  become the reason a node drain gets stuck.
- Topology spread constraints default to on for Deployments: when `topologySpreadConstraints` is left
  `null` (the default), `templates/_pod.tpl` renders two constraints, one per topology key
  (`topology.kubernetes.io/zone` and `kubernetes.io/hostname`), each with `maxSkew: 1`,
  `whenUnsatisfiable: ScheduleAnyway`, `labelSelector` set to the component's selector labels, and
  `matchLabelKeys: [pod-template-hash]` (so each Deployment revision is spread independently of the
  others). `whenUnsatisfiable: ScheduleAnyway` means the scheduler still places a pod that cannot
  satisfy the spread rather than leaving it `Pending` — the constraint is a preference the scheduler
  tries to honor, not a hard requirement that can block scheduling.
- `topologySpreadConstraints: []` renders no constraints at all, and any explicit non-`null` list
  replaces the chart's defaults entirely rather than merging with them.

## Consequences

- Every Deployment gets both protections without its author having to know PDBs or topology spread
  constraints exist, and neither default can be the reason a node drain fails to complete.
- Trade-off: `maxUnavailable: 1` protects only against a *second* pod being evicted concurrently — a
  single-replica component still loses its only pod (briefly unavailable) on every drain that touches
  its node, which is the accepted cost of never blocking that drain. A consumer that genuinely needs a
  single-replica component to survive every drain with zero downtime needs more than one replica, not a
  different PDB setting.
- `AlwaysAllow` means the PDB offers no protection at all for a pod that is already not `Ready` — by
  design, since the alternative (`IfHealthyBudget`) is exactly the behavior that can wedge a drain.
- `ScheduleAnyway` topology spread is a best-effort preference: under real capacity pressure, the
  scheduler can still place every replica on the same node or zone, and the chart does not surface a
  warning when that happens.

## Alternatives considered

### Opt-in PDB and topology spread (off by default)

Leaves every component unprotected until its author remembers to turn both on — in practice, most
components in most umbrellas, since resilience is easy to defer and nothing visibly breaks until a
drain or a zone failure actually happens.

### `minAvailable` instead of `maxUnavailable: 1`

Blocks drains of any single-replica component outright, since there is no way to keep a pod available
while evicting the only one that exists — the opposite of the resilience-without-blocking-drains goal
these defaults are meant to achieve.

## References

- `values.yaml` (`pdb`, `topologySpreadConstraints`)
- `templates/pdb.yaml`
- `templates/_pod.tpl`
- `values.schema.json` (`pdb`)
- [Kubernetes: Specifying a Disruption Budget for your Application](https://kubernetes.io/docs/tasks/run-application/configure-pdb/)
- [Kubernetes: Pod Topology Spread Constraints](https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints/)
