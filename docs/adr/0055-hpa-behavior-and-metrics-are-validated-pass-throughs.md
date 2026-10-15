# ADR-0055: The HPA's `behavior` and `metrics` are validated pass-throughs, and a non-empty `metrics` list replaces the built-in targets

- **Status:** Accepted
- **Date:** 2026-10-12
- **Since:** 0.10.0
- **Related:** [ADR-0011](0011-strict-draft-07-schema.md), [ADR-0014](0014-resource-requests-required.md), [ADR-0027](0027-required-keys-in-the-schema.md), [ADR-0036](0036-rollout-and-runtime-knobs-are-validated-pass-throughs.md), [ADR-0044](0044-guards-fail-the-render-helm-lint-reports-them.md), [ADR-0052](0052-hpa-targets-measure-the-main-container-with-sidecars.md) (amended), [ADR-0056](0056-keda-scaledobject-a-curated-block-with-a-triggers-map.md)

## Context

Until 0.9.0 the chart's HorizontalPodAutoscaler had two built-in targets, `autoscaling.targetCPUUtilizationPercentage`
and `targetMemoryUtilizationPercentage`, and no way to scale on another metric or to shape the scaling. Kubernetes'
`autoscaling/v2` has both: `spec.behavior` (per direction a stabilization window, a select policy and rate policies)
and `spec.metrics` (five source types). What the API server does with them was measured on kube-apiserver 1.33.0 and
1.37.0 (the 0.10.0 research, 109 manifests): it accepts a target `type` that disagrees with its value field
(`type: Value` with `averageValue`), a `Resource` named `foo`, a `ContainerResource` that names a container the pod does
not have, and `metrics: []`, which it stores as CPU at 80% without a word; `behavior.*.tolerance` is
dropped without a word on 1.33 and 1.34 (an alpha gate, off) and stored from 1.35 (source reading of each release's
`kube_features.go`). A misspelt field of a pass-through reaches the cluster as a warning under Helm 3 (client-side
apply drops it) and fails under Helm 4 (server-side apply), measured. With sidecars, 0.8.0's built-in targets measure
the main container ([ADR-0052](0052-hpa-targets-measure-the-main-container-with-sidecars.md)); a native sidecar is a
running container of the pod, which the kubelet's resource metrics and metrics-server report by name (source reading of
the kubelet's CRI stats provider at v1.33.12 and v1.37.0 and of metrics-server 0.9.0; the kind e2e asserts it).

## Decision

- `autoscaling.behavior` is `spec.behavior` in Kubernetes' own shape, closed at every level (`definitions.hpaBehavior`):
  `scaleUp` and `scaleDown`, each with `stabilizationWindowSeconds` (0 to 3600), `selectPolicy` (`Max`, `Min`,
  `Disabled`) and `policies` (at least one; `type` `Pods` or `Percent`, `value` 1 or more, `periodSeconds` 1 to 1800),
  integers only, rendered with `toYaml`. `null` (the default) renders nothing; `behavior: {}` and an empty direction fail
  (`minProperties`), being values that do nothing. `tolerance` is not offered. `behavior` is not a converted map: a
  `null` inside it (`scaleUp: null`, `policies: null`) is a schema error.
- `autoscaling.metrics` is Kubernetes' list, validated per `type`: each item has the block of its type and no other
  (`Resource`, `ContainerResource`, `Pods`, `Object`, `External`), the target type is tied to its value field
  (`Utilization` and `averageUtilization` for `Resource` and `ContainerResource` only; `AverageValue` and
  `averageValue`; `Value` and `value` for `Object` and `External` only), a resource name is `cpu` or `memory`, a quantity
  is a string or a number, a selector is the chart's label selector. The list is rendered as written, never switched to
  `ContainerResource`. A `null` item or a `null` inside an item is a schema error: the list is not converted (an overlay
  replaces a list whole).
- A non-empty `metrics` is the WHOLE list: the built-in targets are not rendered. `targetCPUUtilizationPercentage`
  stays required with its default and is not used then; `targetMemoryUtilizationPercentage` set next to a non-empty list
  fails the render while `autoscaling.enabled` (its remedy, `targetMemoryUtilizationPercentage: null`, works from every
  values layer: measured by the alias contract). `[]` and `null` render the built-in targets, through 0.8.0's helper, so
  the rendered `spec.metrics` is never empty.
- A `ContainerResource` entry must name a container of the component, while `autoscaling.enabled`: the main container
  (the alias) or a non-null `sidecars` key, read from `chart-base.containers`' pruned map. An init container is not one:
  it has exited before a metric is read. The message lists the containers.
- The HPA's `scaleTargetRef` is written by one helper, `chart-base.scaleTargetRef`, which the KEDA ScaledObject uses too
  ([ADR-0056](0056-keda-scaledobject-a-curated-block-with-a-triggers-map.md)); the HPA renders byte-identical.
- `autoscaling.minReplicas` keeps `minimum: 1`: scale to zero is KEDA's job.

## Consequences

- It amends [ADR-0052](0052-hpa-targets-measure-the-main-container-with-sidecars.md): "with a sidecar, the built-in
  targets measure the main container" holds for an empty `metrics` only. A `Resource` entry of the list on a component
  with sidecars measures the whole pod on purpose (the main container's and the sidecars' requests and usage); a
  `ContainerResource` entry with `container: <alias>` measures the main container.
- A component that moves from the built-in targets to a list restates its CPU target in the list.
- An override file merges into a lower layer's `behavior`: it can change a field of a direction, and it cannot remove
  one direction; `behavior: null` removes the block (measured by the alias contract). On Helm 4.3 a `null` direction in
  the umbrella's own values is dropped while nothing is passed for the alias, and fails the schema on Helm 3.22 and in
  every other layer (measured).
- The API server stores a rendered behavior and metrics list as rendered, plus its defaults for a direction that sets
  `selectPolicy` alone, and a number quantity as a string (kube-apiserver 1.33.0 and 1.37.0, Helm 4.3.0 and 3.22.0,
  measured). The e2e checks the stored behavior of the `full` scenario; the non-empty list is unit-tested only.
- What the HPA controller does with them (the arithmetic, the stabilization) is source reading, not run.
- These are render-time guards: `helm template`, install and upgrade fail on them;
  [ADR-0044](0044-guards-fail-the-render-helm-lint-reports-them.md) applies.

## Alternatives considered

### Curated knobs (`scaleDownStabilizationSeconds` and the like)

They would cover the common case with fewer keys, but every other field of `behavior` would need a key of its own, and
Kubernetes' documentation and examples would not apply as written.

### An unvalidated pass-through (`type: object`, `type: array`)

The sibling charts do this. Under Helm 3 a typo reaches the cluster as a warning and the field is dropped; a target
type that disagrees with its value is accepted by the API and never scales.

### `metrics` adding to the built-in targets

The CPU target always has a value (it is required), so a list could never drop it; the HPA scales to the largest
proposal of its metrics, so a CPU target the consumer did not mean would win. A list that is the whole list says what
it renders.

### `tolerance`, or `tolerance` behind `.Capabilities`

A value that does nothing on the chart's floor (1.33). The chart does not gate on `.Capabilities`
([ADR-0012](0012-no-capabilities-gating.md)). It is additive when the floor reaches 1.35.

### `minReplicas: 0` on the HPA

The API accepts it only on 1.37, only with `Object` or `External` metrics. KEDA scales to zero
([ADR-0056](0056-keda-scaledobject-a-curated-block-with-a-triggers-map.md)).

## References

- `templates/hpa.yaml`, `templates/_autoscaling.tpl` (`chart-base.scaleTargetRef`, `chart-base.utilizationMetric`),
  `templates/validate.yaml`, `values.schema.json` (`definitions.hpaBehavior`, `hpaScalingRules`, `hpaMetric`);
  `tests/scaling_test.yaml`, `tests/autoscaling_guards_test.yaml`; `.github/scripts/alias-contract.sh`,
  `.github/scripts/e2e.sh` (the `full` scenario).
- Kubernetes v1.33.12 and v1.37.0: `pkg/apis/autoscaling/validation/validation.go`, `pkg/apis/autoscaling/v2/defaults.go`,
  `pkg/controller/podautoscaler/horizontal.go`, `replica_calculator.go`, `metrics/client.go`, `pkg/features/kube_features.go`,
  `pkg/kubelet/stats/cri_stats_provider.go`; metrics-server v0.9.0 `pkg/scraper/client/resource/decode.go`.
