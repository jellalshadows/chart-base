# ADR-0057: Common labels and annotations, Service annotations and `extraObjects`

- **Status:** Accepted
- **Date:** 2026-11-02
- **Since:** 0.11.0
- **Related:** [ADR-0004](0004-env-in-configmap-secrets-through-externalsecret.md), [ADR-0007](0007-jobs-as-helm-hooks.md) (amended), [ADR-0009](0009-no-name-overrides.md), [ADR-0010](0010-chart-version-never-restarts-pods.md) (amended), [ADR-0012](0012-no-capabilities-gating.md), [ADR-0028](0028-podlabels-cannot-override-selector-labels.md), [ADR-0041](0041-job-component-networkpolicy-is-a-hook.md) (amended), [ADR-0043](0043-job-component-rbac-is-a-hook.md), [ADR-0044](0044-guards-fail-the-render-helm-lint-reports-them.md), [ADR-0049](0049-volumes-are-a-map-of-typed-entries-mounted-in-the-main-container.md) (amended), [ADR-0053](0053-externalsecret-datafrom-template-files-and-an-envfrom-switch.md) (amended)

## Context

The last release before 1.0 adds what any company needs around the chart's objects: its own labels and annotations on
every object (a team, a cost center, an owner, an Argo CD sync option), the annotations a cloud load balancer reads on a
Service, and an escape hatch for an object the chart does not offer (a ConfigMap, a cert-manager Certificate, a
SealedSecret). The facts that shape the contract:

- Every labels map the chart writes renders `chart-base.labels` (object metadata, and the ExternalSecret's
  `template.metadata.labels`), `chart-base.podLabels` (the pod templates and the CronJob's job template) or
  `chart-base.selectorLabels` (every selector, the default topology spread's `labelSelector` and an `ephemeral` claim
  template). Selectors are immutable ([ADR-0010](0010-chart-version-never-restarts-pods.md),
  [ADR-0028](0028-podlabels-cannot-override-selector-labels.md)).
- A label on a pod template is a pod template change: it rolls a Deployment's pods. ADR-0010 forbids a chart bump that
  does so; a values change may.
- External Secrets copies the ExternalSecret's own labels and annotations to the Secret only when there is no template,
  and the template's `metadata.labels` and `annotations` when there is one, executing those values as templates
  (External Secrets v2.11.0, `pkg/controllers/externalsecret/externalsecret_controller_template.go`, source reading).
  A label value has no `{` (alphanumerics, `-`, `_`, `.`), so executing a label returns it unchanged; an annotation
  value may hold `{{`.
- A `helm.sh/hook` annotation turns an object into a Helm hook: on `38a354b`, `ingress.annotations: {helm.sh/hook:
  pre-install}` installs with Helm 4.3.0 and 3.22.0 on kube-apiserver 1.37.0, `helm get hooks` lists the Ingress,
  `helm get manifest` does not, and the Ingress stays after `helm uninstall` (measured at prototyping).
- A Service's name is a DNS-1035 label: kube-apiserver 1.33.0 and 1.37.0 reject a Service named `vending-api.x`, and
  accept a ConfigMap, ServiceAccount, Role, RoleBinding, NetworkPolicy, PersistentVolumeClaim, PodDisruptionBudget,
  HorizontalPodAutoscaler, Ingress, Lease, LimitRange, ResourceQuota and ExternalSecret so named, and a Pod whose
  `configMap` volume and `envFrom` name it (`kubectl create --dry-run=server`, measured at prototyping).
- Helm's kube client decodes any object with a non-null top-level `items` as a list and installs its items (Helm v4.1.3
  `pkg/kube/client.go`, v3.20.1, and apimachinery v0.37.0 `unstructured/helpers.go`, source reading).
- Helm's schema library reports a `propertyNames` failure at an unrelated path, which moves between Helm versions (an
  extra object's reserved label: `at '/prometheusRule/enabled/name/ports'` on 4.3.0, `at
  '/prometheusRule/enabled/kind/labels'` on 3.22.0); the key is named, the map is not (measured by the design's
  critique). A schema rule fails `helm lint` directly and through an umbrella; a guard only prints an INFO line
  ([ADR-0044](0044-guards-fail-the-render-helm-lint-reports-them.md)).

## Decision

1. **`feat:`, not breaking.** The four keys are new (each a schema error on 0.10.0), none is required, every reader
   takes a missing key or `null` as empty, and their defaults (`{}`) render nothing: a values file of 0.10.0 renders
   the same bytes but for the `helm.sh/chart` label, and a direct install upgraded with `--reuse-values` from 0.10.x
   renders 0.10.x's manifests but for that label (measured: the seven `ci/` scenarios, the shared test values and the
   README recipes of 0.10.0, both Helm versions, and real upgrades from the published 0.10.0).
2. **`commonLabels`** (per alias; `global` is not read) join every labels map the chart writes: every object's
   `metadata.labels` (`extraObjects` included), the pod templates of the Deployment, the CronJob and the Job, the
   CronJob's `jobTemplate.metadata.labels`, an `ephemeral` volume's claim template (the selector labels and the common
   labels, never `chart-base.labels`, which carries `helm.sh/chart`) and the ExternalSecret's
   `template.metadata.labels` (so the Secret carries them with or without a template). Never a selector: every selector
   renders `chart-base.selectorLabels`, which does not change, and no pod, job or claim template carries `helm.sh/chart`
   or `app.kubernetes.io/managed-by`. Changing them rolls a Deployment's pods; bumping the chart with `{}` changes no
   pod template.
3. **`commonAnnotations`** join the metadata of every object the chart renders (`extraObjects` included), never a
   template's: not the pod templates (that is `podAnnotations`), not the CronJob's job template, not an `ephemeral`
   claim template, not the ExternalSecret's `template.metadata`. A change rolls nothing (the checksums hash the
   ConfigMaps' `data` only).
4. **Precedence and rendering.** In every labels and annotations map the chart writes, the chart's own keys come
   first, in their order (the labels, the hook annotations, the Reloader annotations; on the ServiceAccount, one sorted
   map, as before), then one map with sorted keys: the per-object map merged over the common map, the per-object value
   winning on a shared key, an empty one (`""`) included (`podLabels`, `metrics.labels`, `prometheusRule.labels`,
   `ingress.annotations`, `serviceAccount.annotations`, `service.annotations`, an extra object's own `metadata`). On a
   `job`'s ServiceAccount the hook annotations win over `serviceAccount.annotations`, which win over the common ones.
   `chart-base.labelsWith` and `chart-base.annotations` render them; `chart-base.overCommon` sets each per-object key
   over a deep copy of the common map (`merge` would fill an empty per-object value from it), never into `.Values`.
5. **`service.annotations`**: a map of strings on the component's Service, winning over `commonAnnotations`; not
   rendered, without a guard, when no Service is.
6. **The reserved keys are schema rules** (`propertyNames`). Labels: `definitions.extraLabels`, the seven keys the chart
   writes. Annotations: `definitions.extraAnnotations`, `helm.sh/hook*`, `meta.helm.sh/*`, `checksum/config-env` and
   `checksum/config-files`, for `service.annotations` and an extra object's own annotations; `commonAnnotations` also
   rejects `secret.reloader.stakater.com/reload` and `configmap.reloader.stakater.com/reload`, which the chart computes
   on the Deployment's metadata before the merged map (a common one would render the key twice). Values are strings.
7. **`extraObjects`** is a map keyed by the object's key, read through one accessor, `chart-base.extraObjects`: the
   non-null entries, each pruned of its `null` fields at any depth through maps (`chart-base.pruneNulls` on a deep copy;
   a list is kept as written, a map emptied by the pruning stays `{}`). `apiVersion` (an optional lowercase group, `/`,
   a version) and `kind` are required; every other top-level field is rendered as written with `toYaml`, never as a
   template.
8. **The name is `<fullname>.<key>`, in the release namespace.** The key is a DNS-1123 label (a guard, whose message
   reads as an override file applies it); `metadata` takes `labels` and `annotations` only (`additionalProperties:
   false`), so a `name`, `namespace`, `generateName` or `finalizers` fails the schema. A `<fullname>` never contains a
   `.`, so the part before the first `.` identifies the alias: two aliases never share an extra object's name, and an
   extra object never meets a chart object of another alias.
9. **Rejected kinds (guards, each with a remedy, then `set extraObjects.<key>: null`).** Compared by API group and kind,
   case-insensitively, any version, through one table, `chart-base.rejectedKinds` (52 entries): the built-in workloads
   (`Pod`, `ReplicationController`, `apps` `Deployment`, `ReplicaSet`, `StatefulSet`, `DaemonSet`, `batch` `Job`,
   `CronJob`: one workload per alias), `Service` (one Service per alias, and no alias-safe name), `Endpoints` and
   `discovery.k8s.io` `EndpointSlice`, `Secret` (its data would sit in the values,
   [ADR-0004](0004-env-in-configmap-secrets-through-externalsecret.md)), and the 40 cluster-scoped built-in kinds (every
   type marked `+genclient:nonNamespaced` in `k8s.io/api` v0.35.3 and v0.37.0, plus `CustomResourceDefinition` and
   `APIService`). Besides the table: `kind: List`, a kind ending in `List` and any object with a top-level `items`, and
   a `rbac.authorization.k8s.io` `RoleBinding` whose key is an entry of `rbac.clusterRoles` (the name of the chart's
   binding). **Below `apiVersion`, `kind` and `metadata` an extra object is an open pass-through:** the chart checks
   nothing else and gives it none of what it gives its own objects (no Reloader entry unless the component references
   it, no checksum, no validation of its content). It passes kinds the roadmap's "Out of scope" list rejects as chart
   features (a SealedSecret, a SecretProviderClass, a cert-manager Certificate, a PersistentVolumeClaim): the chart's
   integrated secret path stays External Secrets, and a plain `Secret` stays rejected.
10. **Values are rendered as written**: a `{{ ... }}` reaches the cluster as written (an extra ExternalSecret's
    `template.data`, a PrometheusRule's `{{ $value }}` stay intact).
11. **On a `job` component every extra object is a hook of the Job's phase**, with the annotations of its support
    resources (`helm.sh/hook` of `job.phase`, weight `-10`, `before-hook-creation,hook-succeeded`): created before the
    Job, with the new content, and deleted once the phase succeeds. On `deployment` and `cronjob` components extra
    objects are regular release objects.
12. **e2e**: the `full` scenario carries the four keys; every object of its release carries the common label and
    annotation in the cluster, the Service its own annotation, its pods and the Secret that External Secrets writes the
    common label, and the extra ConfigMap `full-chart-base.settings` exists.

This record amends [ADR-0007](0007-jobs-as-helm-hooks.md) and [ADR-0041](0041-job-component-networkpolicy-is-a-hook.md)
(a `job` component's extra objects are hooks of its phase, like its support resources), [ADR-0010](0010-chart-version-never-restarts-pods.md)
(the pod template's label set gains `commonLabels`, a values change),
[ADR-0049](0049-volumes-are-a-map-of-typed-entries-mounted-in-the-main-container.md) (an `ephemeral` claim template
carries the selector labels and the common labels, its own additive exit) and
[ADR-0053](0053-externalsecret-datafrom-template-files-and-an-envfrom-switch.md) (`template.metadata.labels` gains the
common labels, as it announced).

## Consequences

- A team label reaches every object, pod and claim of a component, and the Secret External Secrets writes; cost, log
  and policy tools can select the pods by it. Selectors never change.
- The placement is frozen: moving common labels off, or common annotations onto, a template later would roll every pod
  of every consumer on a chart bump (ADR-0010).
- A consumer renders a missing kind without a fork or a second chart, and keeps the alias contract: names follow the
  release and the alias, objects stay in the release namespace, and a `job` component's extra objects follow its phase.
- `extraObjects` is a pass-through: an extra autoscaler, PodDisruptionBudget, RoleBinding to a broad ClusterRole or
  ExternalSecret writing `<fullname>-secrets` is not caught. An extra autoscaler on the component's Deployment fights
  the chart even with the chart's autoscalers off (the chart then renders `spec.replicas`): use `autoscaling` or `keda`.
  Not detected either: a cluster-scoped custom kind, a custom workload kind, a cluster-scoped built-in kind added after
  Kubernetes 1.37 (the table is regenerated with the floor).
- `helm.sh/resource-policy: keep` in `commonAnnotations` keeps the regular objects on uninstall, never a `job`
  component's hooks (Helm deletes a hook without reading it, ADR-0042).
- A controller that copies an extra object's name into a label value (63 characters) or a DNS label may refuse its `.`
  or its length (up to 127 characters), at reconcile, not at install. A reference to an extra object from another field
  writes the full name, `<release>-<alias>.<key>`, which ties the values file to one release name.
- An extra object of a CRD kind needs its CRD in the cluster (the release fails otherwise,
  [ADR-0012](0012-no-capabilities-gating.md)), and `validate-manifests.sh` needs a schema location for it (no
  `-ignore-missing-schemas`).
- A reserved key's message names the key, not the map; the docs list which maps reject which keys. ADR-0044's gap
  reaches the new required fields: an `-f` `extraObjects.<key>.kind: null` passes an umbrella's `helm lint` and fails
  `helm template` (measured by the design's critique).

## Alternatives considered

### Common annotations on the pod templates

Pod annotations have readers of their own (mesh injection, scrape hints) that `podAnnotations` serves; an object
annotation on a pod does nothing but roll the pods when it changes, and adding it later would roll every pod on a chart
bump.

### Common labels off the claim template and the ExternalSecret's template

One rule ("every labels map, never a selector") is simpler to state and test than a list of exceptions, and the claims
and the Secret are what a storage or secret cost report reads.

### The reserved keys as guards

A guard's message could name the map, but a guard only prints an INFO line under `helm lint` (ADR-0044); the schema
rule fails `helm lint` directly and through an umbrella, as `podLabels`, `metrics.labels` and `prometheusRule.labels`
already do. This closes, for the new maps, the follow-up recorded in [0.6.0's release record](../releases/0.6.0.md)
(a reserved `podLabels` key reported at the wrong path, to move to a guard): the schema rule stays.

### `extraObjects` as a list, or a consumer-written name

A list is replaced whole by every overlay and has no stable key to derive the name from; a consumer-written name (even
prefix-checked) makes the chart no longer the one writer of names ([ADR-0009](0009-no-name-overrides.md)).

### Another separator (`-`, `--`, a hash)

`<release>-api` + `-x` collides with an alias `api-x`'s own objects; `--` with an alias that contains `--`; a hash
hides the key. The chart already uses `.` for the same reason (`<fullname>.<ClusterRole>` RoleBindings).

### `tpl` on extra objects

It would execute a consumer's string inside the chart, with every helper and the whole `.Values` reachable, and break
the objects whose own fields are templates. If ever, an opt-in per entry.

### An allowlist of built-in kinds, or a denylist of custom kinds

An allowlist refuses every namespaced kind the chart has not learnt; a denylist of custom kinds has no end, and the
chart cannot know a custom kind's scope without `lookup` (ADR-0012).

### Dropping the top-level `items` rule

The reason `List` is rejected applies to any object with a top-level `items`: one `hasKey` closes that bypass.

## References

- External Secrets v2.11.0, `pkg/controllers/externalsecret/externalsecret_controller_template.go` (the template's
  metadata, executed as templates; the ExternalSecret's own metadata copied without a template).
- Helm v4.1.3 `pkg/kube/client.go`, v3.20.1 `pkg/kube/client.go`, apimachinery v0.37.0
  `pkg/apis/meta/v1/unstructured/helpers.go` (an object with a top-level `items` is a list); Helm v4.1.3 and v3.20.1
  `pkg/action/hooks.go` (hooks sorted by weight, then name; deleted once the phase succeeds).
- `k8s.io/api` v0.35.3 and v0.37.0 (`+genclient:nonNamespaced`); `kubectl api-resources --namespaced=false` on
  kube-apiserver 1.33.0 and 1.37.0 (no built-in cluster-scoped kind outside the table).
- `templates/_labels.tpl` (`chart-base.labels`, `labelsWith`, `podLabels`, `overCommon`, `annotations`),
  `templates/_extraobjects.tpl` (`chart-base.extraObjects`, `chart-base.rejectedKinds`), `templates/extraobjects.yaml`,
  `templates/validate.yaml`, `values.schema.json` (`definitions.extraLabels`, `extraAnnotations`, `extraObject`),
  `tests/common_labels_test.yaml`, `tests/common_annotations_test.yaml`, `tests/extraobjects_test.yaml`,
  `tests/extraobjects_guards_test.yaml`, `.github/scripts/alias-contract.sh`, `.github/scripts/e2e.sh`.
