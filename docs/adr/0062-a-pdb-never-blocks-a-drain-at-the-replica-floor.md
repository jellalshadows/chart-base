# ADR-0062: A PodDisruptionBudget never blocks a drain at the replica floor

- **Status:** Accepted — amended by [ADR-0071](0071-a-statefulset-workload-type-with-a-claim-per-pod.md) (1.6.0)
- **Date:** 2026-11-17
- **Since:** 0.12.0
- **Related:** [ADR-0015](0015-pdb-and-topology-spread-by-default.md) (amended), [ADR-0044](0044-guards-fail-the-render-helm-lint-reports-them.md), [ADR-0055](0055-hpa-behavior-and-metrics-are-validated-pass-throughs.md), [ADR-0056](0056-keda-scaledobject-a-curated-block-with-a-triggers-map.md), [ADR-0057](0057-common-labels-and-annotations-service-annotations-and-extraobjects.md), [ADR-0058](0058-the-1-0-contract-and-how-it-stays-frozen.md)

## Context

The chart renders a PodDisruptionBudget for every Deployment by default, `maxUnavailable: 1` (ADR-0015), and renders
`pdb.minAvailable` or `pdb.maxUnavailable` as given. A budget that allows no eviction stalls every node drain and
cluster upgrade on the component: the failure a production-safe default exists to prevent, and one the chart already
refuses for a rollout (`maxSurge` and `maxUnavailable` both 0). Measured with the 0.11.0 chart on Helm 4.3.0 and 3.22.0,
all exit 0: `replicas: 2` with `minAvailable: 2`; the HPA's `minReplicas: 2` with `minAvailable: 2`; KEDA's
`minReplicaCount: 0` with `minAvailable: 1` (the consuming guide documented this trap); `replicas: 1` with
`minAvailable: "50%"`; `maxUnavailable: 0`. After 1.0 a check on values that render is a major (ADR-0058).

## Decision

A guard in `templates/validate.yaml`, on a Deployment with `pdb.enabled`, in all three scaling modes (a check for KEDA
alone would suggest the others are checked):

1. **The replica floor** is `max(keda.minReplicaCount, 1)` with KEDA (a pod runs while a trigger is active, whatever
   the minimum), `autoscaling.minReplicas` with the HPA, otherwise `replicas`. At `replicas: 0` there is no pod to
   protect and nothing is checked.
2. **It fails** when an integer `pdb.minAvailable` is at or above the floor; when a percentage `minAvailable` gives
   `ceil(p × floor / 100)` at or above it; or when `pdb.maxUnavailable` is `0` or `"0%"` (any other percentage rounds
   up to at least one pod). `minAvailable` wins over `maxUnavailable`, as in `templates/pdb.yaml`. A string that is not
   a percentage is not checked: the API server rejects it.
3. **The message names the floor's source and the remedies**: a lower `minAvailable` (its largest value at that floor,
   as a count and as a percentage), `pdb.minAvailable: null` for `pdb.maxUnavailable` (1 by default), and, for a budget
   that blocks evictions on purpose, `pdb.enabled: false` with a PodDisruptionBudget in `extraObjects` (its kind list
   does not deny one, and the chart checks nothing below its `metadata`). For example: `chart-base[api]: pdb.minAvailable
   is 2 and the replica floor is 2 (replicas): the PodDisruptionBudget allows no eviction at the floor, so every node
   drain and cluster upgrade stalls on this component. Set pdb.minAvailable to at most 1 (a percentage: at most 50%),
   or pdb.minAvailable: null to use pdb.maxUnavailable (1 by default); for a budget that blocks evictions on purpose,
   set pdb.enabled: false and write a PodDisruptionBudget in extraObjects`.
4. **Rounding.** The disruption controller scales both percentages against the expected pod count rounding up
   (the 1.0 design's source reading of `pkg/controller/disruption/disruption.go`, `getExpectedPodCount`, which scales
   them with `intstr.GetScaledValueFromIntOrPercent` and `roundUp: true`; not measured here: the 1.0 Docker campaign evicts
   through the API with each accepted value and with the 0.11.0 render of each rejected one).

This amends ADR-0015: the budget's values are checked against the floor.

## Consequences

- A budget that would stall a drain fails at render with its key, the floor, where the floor comes from and the
  remedies; `helm lint` prints it as an INFO line (ADR-0044).
- The upgrade from 0.11.0 can fail for values that rendered: each shape above. The upgrade guide gives the floor per
  mode and the remedies.
- The floor is the minimum, not the current count: an HPA at 5 pods with `minReplicas: 2` and `minAvailable: 2` would
  allow evictions until it scales down, and is rejected anyway, because it blocks every drain once it does.
- A deliberately blocking budget is still possible, outside the chart's PDB. Two budgets over one pod make the
  eviction API refuse every eviction of it, which is why the remedy turns the chart's budget off.

## Alternatives considered

### A check for KEDA alone

The trap the guide documented, but one mode checked suggests the others are; the arithmetic is the same.

### The current replica count as the floor

The count moves with the autoscaler; a budget that is safe at 5 pods blocks at the minimum, where a drain needs it.

### A warning instead of a failure

Helm has no warning channel a pipeline reads; the chart's guards fail the render.

### An opt-out key for a blocking budget

`extraObjects` already renders a PodDisruptionBudget the chart does not check; a key would freeze a second way.

## References

- `templates/validate.yaml` (the PDB guard), `templates/pdb.yaml`.
- `tests/scaling_test.yaml`.
- [Consuming guide, "Autoscaling: the HPA and KEDA"](../guides/consuming.md#autoscaling-the-hpa-and-keda).
