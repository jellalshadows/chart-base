# ADR-0056: KEDA: a curated ScaledObject block with a triggers map, in place of the HPA

- **Status:** Accepted
- **Date:** 2026-10-12
- **Since:** 0.10.0
- **Related:** [ADR-0012](0012-no-capabilities-gating.md), [ADR-0015](0015-pdb-and-topology-spread-by-default.md), [ADR-0027](0027-required-keys-in-the-schema.md), [ADR-0044](0044-guards-fail-the-render-helm-lint-reports-them.md), [ADR-0050](0050-existing-claim-on-a-deployment-and-strategy-rollingupdate-null.md) (amended), [ADR-0053](0053-externalsecret-datafrom-template-files-and-an-envfrom-switch.md), [ADR-0054](0054-env-externalsecretkeyref-references-the-components-own-secret.md), [ADR-0055](0055-hpa-behavior-and-metrics-are-validated-pass-throughs.md)

## Context

KEDA (`keda.sh/v1alpha1` ScaledObject) scales a Deployment on external events, to and from zero, through an HPA it
creates and owns, `keda-hpa-<name>`. What the chart can rely on was measured with KEDA v2.21.0's operator and
admission webhooks run out of cluster against kube-apiserver 1.33.0 and 1.37.0 (KEDA 2.21 is tested on Kubernetes 1.34
to 1.36 and only warns outside them), with the KEDA chart 2.21.0's CRDs, Helm 4.3.0 and 3.22.0:

- The CRD stores what the chart renders (an explicit `scaleTargetRef`, `metadata: {}`, numbers and booleans rendered as
  strings, a `behavior` of one direction), and adds `fallback.behavior: static`. KEDA's operator drops a
  `useCachedMetrics: false` from the stored object at its first reconcile (its default).
- KEDA's own defaults are `minReplicaCount` 0 (scale to zero) and `maxReplicaCount` 100; a `metadata` value must be a
  string; the webhook denies a second autoscaler of the workload, `useCachedMetrics: true` on `cron` and `memory` (and
  on `cpu`, the same check in its source), only `cpu` and `memory` triggers with `minReplicaCount` 0, a `fallback` with only `cpu` and `memory`
  triggers, and a name whose `keda-hpa-<name>` exceeds 63 characters; it only warns for `cooldownPeriod` and
  `pollingInterval` next to a minimum of 1 or more; the operator rejects a `cpu` or `memory` trigger without a
  `metricType` of `Utilization` or `AverageValue`, and `Utilization` on another trigger; nobody checks `containerName`.
- A one-upgrade switch from an HPA to a ScaledObject fails at the webhook (`the workload '<name>' of type
  'apps/v1.Deployment' is already managed by the hpa '<name>'`), and leaves the release `failed`.
- A rendered `spec.replicas` conflicts under Helm 4's server-side apply once the count has been changed through the
  scale subresource, as an autoscaler changes it, while Helm owned the field (measured with `kubectl scale` as the
  other manager: `Apply failed with 1 conflict: ... with subresource "scale" ...: .spec.replicas`), and Helm 3 resets
  the count at every upgrade.
- `...FromEnv` parameters read the first container's environment: its `envFrom` Secrets and `env` `secretKeyRef`
  entries are resolved (measured), except under KEDA's restricted Secret access (`KEDA_RESTRICT_SECRET_ACCESS`), which
  skips the namespace's Secrets (measured).

## Decision

- A curated `keda` block, not the whole ScaledObject: `enabled`, `minReplicaCount` (default 1, not KEDA's 0),
  `maxReplicaCount` (default 10), `pollingInterval`, `cooldownPeriod`, `initialCooldownPeriod`, `fallback`
  (`{failureThreshold, replicas}`), `behavior` (rendered under `advanced.horizontalPodAutoscalerConfig.behavior`, the
  definition of `autoscaling.behavior`) and `triggers`. `enabled`, `minReplicaCount` and `maxReplicaCount` are required
  inside the block ([ADR-0027](0027-required-keys-in-the-schema.md)): a `null` would hand the component KEDA's defaults.
  The block is not in the root `required` list, and every reader takes a missing block or `keda: null` as KEDA off. The
  bounds are those of KEDA chart 2.21.0's CRD.
- One ScaledObject `<fullname>` per component, on a `deployment` only (the schema rule that rejects
  `autoscaling.enabled` on a `cronjob` or a `job` rejects `keda.enabled` too). Its `scaleTargetRef` is written by
  `chart-base.scaleTargetRef` (`apps/v1`, `Deployment`, `<fullname>`), the HPA's helper. `minReplicaCount` and
  `maxReplicaCount` are always rendered from the value.
- `triggers` is a map keyed by the trigger's name (rendered as its `name`, in key order): `{type, metadata, metricType,
  authenticationRef: {name, kind}, useCachedMetrics}`. It is the map 0.10.0 converts: a `null` entry is absent, and
  so are a `null` optional field and a `null` metadata key of an entry (`chart-base.keda` prunes a deep copy; a `null`
  `type` or `metadata` stays a schema error). Metadata
  values are strings, numbers or booleans, rendered as strings (a number through `toJson`, so no `1e+07`); a metadata
  that pruning empties is rendered `{}`; `useCachedMetrics` is rendered only when `true`.
- Authentication by reference only: `authenticationRef` names an existing TriggerAuthentication or
  ClusterTriggerAuthentication, and the component's own secrets reach a scaler through `...FromEnv` parameters, which
  name a variable of the main container (with `externalSecret.envFrom: false`, an `env` entry with
  `externalSecretKeyRef`, [ADR-0054](0054-env-externalsecretkeyref-references-the-components-own-secret.md)).
- `spec.replicas` is not rendered while `keda.enabled`, as with `autoscaling.enabled`.
- Guards, while `keda.enabled` (a disabled block may keep its values): the autoscaling and KEDA blocks are exclusive;
  `<fullname>` at most 54 characters; `minReplicaCount` at most `maxReplicaCount`; at least one non-null trigger; a
  `cpu` or `memory` trigger needs `metricType` `Utilization` or `AverageValue`, and its `metadata.containerName`, if set,
  names the main container or a non-null sidecar; `Utilization` only on `cpu` and `memory`; no `useCachedMetrics: true`
  on `cron`, `cpu` and `memory`; not only `cpu` and `memory` triggers at `minReplicaCount: 0`; a `fallback` needs a
  trigger other than `cpu` and `memory`, and `fallback.replicas` at most `maxReplicaCount`; `cooldownPeriod` and
  `initialCooldownPeriod` only with `minReplicaCount: 0` (KEDA reads them only on the step to zero). A remedy never
  points where another guard waits: next to only `cpu` and `memory` triggers, the period guard does not offer scale to
  zero, and the zero guard names the periods to remove.
- 0.7.0's guard for a `ReadWriteOnce` or `ReadWriteOncePod` claim on a Deployment
  ([ADR-0050](0050-existing-claim-on-a-deployment-and-strategy-rollingupdate-null.md)) covers KEDA: with
  `keda.enabled` it reads `maxReplicaCount`, never `replicas`, and its remedy is `keda.maxReplicaCount: 1` with the same
  strategy rule. The claims it reads are one variable of `templates/validate.yaml`, which the fallback guard reads too:
  next to such a claim its message offers only to lower `fallback.replicas` (raising `maxReplicaCount` would fail the
  claim guard: measured by the plan review), and it names the claim.
- No KEDA annotation on the chart's HPA, and no handover key: switching between the HPA and KEDA is documented
  (the upgrade guide). Never `transfer-hpa-ownership`.

## Consequences

- It amends [ADR-0050](0050-existing-claim-on-a-deployment-and-strategy-rollingupdate-null.md): with `keda.enabled`
  its claim rule requires `keda.maxReplicaCount: 1` and no longer reads `replicas` (`replicas: 3` with
  `maxReplicaCount: 1` renders).
- HPA to KEDA takes `kubectl delete hpa <fullname>` before the upgrade (the count is kept; measured), or two upgrades:
  `autoscaling.enabled: false` (which renders `replicas`: set it to the current count), then `keda.enabled: true`
  (`replicas` leaves the manifest and the API server sets the count to 1 until KEDA or its HPA raises it; measured).
  KEDA to the HPA works in one upgrade while the workload has a pod (measured); at zero the HPA never scales it up
  (`ScalingActive` False, `ScalingDisabled`: Kubernetes source, asserted by the kind e2e).
- `keda.minReplicaCount` (1) is not `autoscaling.minReplicas` (2): a component moved from the HPA restates its minimum.
  A `cpu` or `memory` trigger without `metadata.containerName` is pod-wide, while the built-in HPA targets measure the
  main container once a sidecar exists ([ADR-0052](0052-hpa-targets-measure-the-main-container-with-sidecars.md)).
- A cluster without KEDA's CRDs fails the whole release at install (`no matches for kind "ScaledObject"`), as
  [ADR-0012](0012-no-capabilities-gating.md) says for every CRD kind. KEDA's operator must outlive the ScaledObjects: its
  finalizer holds `helm uninstall --wait`.
- With Helm 4 `--wait`, a ScaledObject that is not Ready fails the upgrade at the timeout (Helm 3 does not look); a
  `fallback` keeps it Ready while its trigger source is down (both measured by the 0.10.0 research); a scaler that
  connects when it is built (rabbitmq, measured) makes it not Ready while the source cannot be reached.
- `keda-hpa-<fullname>` is not in the release; it carries the ScaledObject's labels and annotations, and equals a sibling
  alias's own HPA only for contrived names (release `keda`, aliases `api` on KEDA and `hpa-keda-api` on the HPA: both
  `keda-hpa-keda-api`), when KEDA's operator would take that HPA over (inferred from the names; not run). No guard.
- Not validated: a scaler's metadata (KEDA has 80 scalers), the variables a `...FromEnv` names, credentials,
  `tolerance`. The PDB is not checked against the minimum
  ([ADR-0015](0015-pdb-and-topology-spread-by-default.md)): with `minReplicaCount: 0` the workload often runs one pod,
  and any integer `minAvailable` of 1 or more then blocks a node drain.
- These are render-time guards: `helm template`, install and upgrade fail on them;
  [ADR-0044](0044-guards-fail-the-render-helm-lint-reports-them.md) applies.

## Alternatives considered

### The roadmap's four keys only

`pollingInterval`, the cooldowns, `fallback` and `behavior` are what a consumer tunes per environment; without them a
consumer would need a second object.

### A pass-through of the whole ScaledObject spec

The chart would not see the triggers, so neither the trigger guards nor the RWO-claim guard could read them, and a
`null` from an overlay would reach the CRD (it rejects a non-string metadata value).

### `triggers` as KEDA's list

An overlay replaces a list whole, so a threshold that differs per environment would repeat every trigger; a map lets
an overlay change one parameter or remove a trigger with `null`, and its keys are the unique names KEDA's webhook
requires.

### KEDA's own `minReplicaCount` default (0)

A component that sets only `enabled` and its triggers would disappear while they are idle, and a `cpu`-only object
with 0 is denied by the webhook. Scale to zero is something the consumer writes.

### An annotation on every chart HPA (`validations.keda.sh/hpa-ownership: "false"`)

It makes HPA to KEDA one upgrade, but it puts a KEDA setting on the HPA of every consumer who never uses KEDA, and it
turns KEDA's own check off for that HPA. An opt-in key is additive later.

### A chart-rendered TriggerAuthentication, ScaledJob

Out of this release; additive later.

## References

- `templates/scaledobject.yaml`, `templates/_keda.tpl` (`chart-base.keda`), `templates/_autoscaling.tpl`
  (`chart-base.scaleTargetRef`), `templates/deployment.yaml`, `templates/validate.yaml`, `values.schema.json`
  (`keda`, `definitions.kedaTrigger`); `tests/keda_test.yaml`, `tests/keda_guards_test.yaml`,
  `tests/volumes_guards_test.yaml`; `ci/keda-values.yaml`; `.github/scripts/e2e.sh`, `.github/scripts/alias-contract.sh`.
- KEDA v2.21.0: `apis/keda/v1alpha1/scaledobject_webhook.go`, `scaledobject_types.go`, `scaletriggers_types.go`,
  `pkg/scalers/cpu_memory_scaler.go`, `pkg/scaling/resolver/scale_resolvers.go`; KEDA chart 2.21.0's CRDs.
- Kubernetes v1.33.12 and v1.37.0: `pkg/controller/podautoscaler/horizontal.go`.
