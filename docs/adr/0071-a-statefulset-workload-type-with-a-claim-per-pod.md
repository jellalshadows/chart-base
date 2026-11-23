# ADR-0071: A StatefulSet workload type with a claim per pod

- **Status:** Accepted
- **Date:** 2026-11-19
- **Since:** 1.6.0
- **Amended in:** 1.6.1, which brought the code in line with two lines of this decision: a member left empty by its `null`s at every depth is not set (the member rule), and the `strategy` guards are Deployment-only ("Ignored on a `statefulset`"), the `Recreate` one included.
- **Related:** [ADR-0008](0008-names-are-release-alias-and-never-truncated.md) (amended), [ADR-0015](0015-pdb-and-topology-spread-by-default.md) (amended), [ADR-0036](0036-rollout-and-runtime-knobs-are-validated-pass-throughs.md) (amended), [ADR-0037](0037-one-prestop-hook.md) (amended), [ADR-0038](0038-one-metrics-endpoint-servicemonitor-or-podmonitor.md) (amended), [ADR-0049](0049-volumes-are-a-map-of-typed-entries-mounted-in-the-main-container.md) (amended), [ADR-0050](0050-existing-claim-on-a-deployment-and-strategy-rollingupdate-null.md) (amended), [ADR-0056](0056-keda-scaledobject-a-curated-block-with-a-triggers-map.md) (amended), [ADR-0057](0057-common-labels-and-annotations-service-annotations-and-extraobjects.md) (amended), [ADR-0062](0062-a-pdb-never-blocks-a-drain-at-the-replica-floor.md) (amended), [ADR-0017](0017-progress-deadline-240s.md), [ADR-0058](0058-the-1-0-contract-and-how-it-stays-frozen.md), [ADR-0064](0064-from-1-0-0-a-new-key-is-optional.md), [ADR-0069](0069-grpcroute-httproute-rules-and-appprotocol.md), [ADR-0070](0070-a-null-means-absent-chart-wide.md)

## Context

Up to 1.5.0 an alias renders a Deployment, a CronJob or a Job. A component that needs its own storage per pod (a
cache with a disk, a queue's local log, a small replicated store) has two options in the chart, and neither fits:

- an existing claim (`persistentVolumeClaim`) is one volume for every pod, and when it is `ReadWriteOnce` a
  Deployment that mounts it must run one pod at a time
  ([ADR-0050](0050-existing-claim-on-a-deployment-and-strategy-rollingupdate-null.md));
- an `ephemeral` claim is one per pod, but it is deleted with its pod, so a rollout loses the data.

A StatefulSet gives each pod a stable name (`<name>-<ordinal>`), a claim per pod from its claim templates that outlives
the pod, and a DNS name per pod through a headless Service. The StatefulSet type was planned as 0.13.0 and cut before
1.0 ([roadmap](../roadmap.md#cut-before-10)): stateful systems usually run under their own operators. The cut row
named what it would be: `workload.type: statefulset`, a `statefulset` block, a headless Service, a 52-character name
guard, and claim templates in the `volumes` name space. 1.6.0 ships it additively: from 1.0.0 a minor release adds,
and every value that renders on 1.5.0 renders the same manifest
([ADR-0058](0058-the-1-0-contract-and-how-it-stays-frozen.md),
[ADR-0064](0064-from-1-0-0-a-new-key-is-optional.md)).

Four facts decide the shape. Each was checked in the source, not assumed:

1. **The pods of a StatefulSet carry `controller-revision-hash: <StatefulSet name>-<hash>`.** The controller sets the
   label `apps.StatefulSetRevisionLabel`, which is `controller-revision-hash`, on every pod it creates, with the name of
   the update revision (`setPodRevision`). A ControllerRevision is named `<parent name>-<hash>`
   (`ControllerRevisionName`), and the hash is the decimal string of a 32-bit FNV hash passed through
   `rand.SafeEncodeString` (`HashControllerRevision`): at most 10 characters. A label value is at most 63 characters,
   so the StatefulSet's name is at most 52. The same label is the per-revision key a topology spread needs, as
   `pod-template-hash` is a Deployment's.
2. **The HPA and KEDA scale a StatefulSet.** The HPA controller reads and writes the target through the scale client
   (`scaleNamespacer.Scales(namespace).Get` and `.Update`), for any resource with a `/scale` subresource, and the
   StatefulSet registry has one (`ScaleREST`). KEDA's ScaledObject controller checks that the target "exists and
   exposes /scale subresource" (`checkTargetResourceIsScalable`) and scales it through the same client; its
   ScaledObject reference says that "to scale a different resource such as StatefulSet" the `apiVersion` and `kind`
   are given.
3. **Reloader restarts StatefulSets.** Its README lists StatefulSets among the workloads whose rollouts it triggers.
4. **Only a headless Service gives each pod a DNS name.** The DNS specification for Kubernetes publishes, for a
   headless Service, an `A` record `<hostname>.<service>.<namespace>.svc.<zone>` per ready endpoint that has a
   hostname; a ClusterIP Service gets one record for the Service. The StatefulSet controller sets each pod's
   `hostname` to the pod's name and its `subdomain` to `spec.serviceName` (`initIdentity`), and the EndpointSlice
   controller writes the hostname only when the subdomain is the Service's name (`ShouldSetHostname`).

None of the four turned out false, so no alternative ruling was needed.

## Decision

- **`workload.type: statefulset`** (a new enum value) renders an `apps/v1` StatefulSet `<release>-<alias>`, with the
  selector labels of every workload (frozen, [ADR-0058](0058-the-1-0-contract-and-how-it-stays-frozen.md)), the
  Deployment's pod template (`chart-base.podSpec`), its pod labels, the two config checksums and the two Reloader
  annotations. The Deployment's pod template annotations moved to a helper, `chart-base.podTemplateAnnotations`, that
  both workloads call; the Deployment renders the same. `replicas` is left out while the HPA or KEDA is on, as on a
  Deployment. `minReadySeconds` and `revisionHistoryLimit` apply (a StatefulSet has both fields).
- **The Service is headless.** On a `statefulset` the alias's one Service, under the same name, renders
  `clusterIP: None`, and the StatefulSet's `serviceName` names it. The API server allows a headless Service on type
  `ClusterIP` only, so a `NodePort` or `LoadBalancer` `service.type` fails a guard whose remedy sends traffic from
  outside the cluster through `httpRoute`, `grpcRoute` or `ingress`. With `service.enabled: false`, no `serviceName` is
  rendered (the field is optional in `apps/v1`), and the pods get no DNS name. No second Service: one alias has one
  Service, and its name is part of the contract.
- **A new optional block `statefulset`** (every member `null`, never `required`,
  [ADR-0064](0064-from-1-0-0-a-new-key-is-optional.md)), closed, each member nullable
  ([ADR-0070](0070-a-null-means-absent-chart-wide.md)):
  - `podManagementPolicy`: `OrderedReady` or `Parallel` (absent: Kubernetes' `OrderedReady`);
  - `updateStrategy`: `type` (`RollingUpdate` or `OnDelete`) and `rollingUpdate.partition` (an integer, at least 0).
    A `rollingUpdate` next to `OnDelete`, an empty one included, fails a guard: Kubernetes rejects it. It is the one
    member always rendered (see the next point);
  - `persistentVolumeClaimRetentionPolicy`: `whenDeleted` and `whenScaled`, each `Retain` or `Delete` (absent:
    Kubernetes' `Retain`).

  A member is set when it is not `null` and not left empty by its `null`s (`chart-base.statefulset` reads a pruned
  copy). A set member on another workload type fails a guard. These are template guards, not schema conditionals on a
  key of the new block, which would hold vacuously after a `--reuse-values` upgrade from a release without it
  ([ADR-0069](0069-grpcroute-httproute-rules-and-appprotocol.md)); the schema's own rules condition on `workload.type`
  only.
- **A StatefulSet always renders its `updateStrategy`, the Kubernetes defaults written out** (three rulings in review,
  each in Alternatives considered), so that Helm owns its keys from the first install:
  - `statefulset.updateStrategy` absent, `null`, `{}` or left empty by its `null`s, or `type: RollingUpdate` without
    `partition` (a `null` one included): `{type: RollingUpdate, rollingUpdate: {partition: 0}}`;
  - `rollingUpdate.partition: N` without `type`: `{type: RollingUpdate, rollingUpdate: {partition: N}}`;
  - rendering for Kubernetes 1.37 or later (`semverCompare ">=1.37.0-0" .Capabilities.KubeVersion.Version`, the style
    of the 1.33 floor guard), `rollingUpdate` also carries `maxUnavailable: 1`, next to the `partition`;
  - `type: OnDelete`: `{type: OnDelete}` alone, on every version; the guard against a `rollingUpdate` next to
    `OnDelete` stays.

  `maxUnavailable: 1` is a constant the chart writes, not a value: the schema still rejects
  `statefulset.updateStrategy.rollingUpdate.maxUnavailable`.

  The reason is the trap [ADR-0050](0050-existing-claim-on-a-deployment-and-strategy-rollingupdate-null.md) measured
  for a Deployment's switch to `Recreate`, predicted here from the Kubernetes source (the kind e2e pins the remedy).
  Without `updateStrategy` in the manifest, the API server stores `{type: RollingUpdate, rollingUpdate: {partition:
  0}}` (`SetDefaults_StatefulSet`), and no field manager owns `rollingUpdate`. A StatefulSet's `updateStrategy` has no
  `retainKeys` patch strategy, unlike a Deployment's `strategy` (`apps/v1` `types.go`). A later upgrade to `{type:
  OnDelete}` would then keep the stored `rollingUpdate`: under Helm 4's server-side apply because nobody owns it, under
  Helm 3's three-way merge because the previous manifest did not have it. The API server rejects the result with
  `` spec.updateStrategy.rollingUpdate: Invalid value: ...: only allowed for updateStrategy 'RollingUpdate' ``
  (`ValidateStatefulSetSpec`). With the defaults written out, Helm owns `rollingUpdate.partition`, and a switch to
  `OnDelete` removes it in one upgrade on Helm 4 (an owned key the new manifest lacks is removed) and on Helm 3 (the
  three-way patch deletes a key the previous manifest had). The written defaults equal the stored ones, so the
  StatefulSet behaves as with nothing rendered. The type is new in 1.6.0: no existing release changes.

  `maxUnavailable` follows from the same reason (from the Kubernetes source). Where the `MaxUnavailableStatefulSet`
  feature gate is on, `SetDefaults_StatefulSet` also stores `rollingUpdate.maxUnavailable: 1` (v1.37.0 `defaults.go`),
  and the gate is on by default from 1.37 (alpha from 1.24, beta and off from 1.35, beta and on from 1.37: v1.37.0
  `kube_features.go`). Left to the API server there, the stored object is `{rollingUpdate: {maxUnavailable: 1,
  partition: 0}, type: RollingUpdate}`, `maxUnavailable` has no owner, and the switch to `OnDelete` fails as above.
  Written by the chart, Helm owns it and removes it on the switch. Where the gate is off (1.33 to 1.36 by default), the
  API server drops a `maxUnavailable` on create and update unless the stored object already uses it
  (`dropStatefulSetDisabledFields`, v1.33.0 `pkg/registry/apps/statefulset/strategy.go`). A constant written there
  would never reach the live object, and every tool that compares the rendered manifest with the live object (Argo
  CD's diff, for example) would show the StatefulSet out of sync for good. So the chart writes it only when it renders
  for 1.37 or later: an install or upgrade renders for the cluster's version (Helm reads it from the API
  server), and Argo CD passes its cluster's version as `--kube-version`. After a cluster upgrade to 1.37, the next
  Helm upgrade writes `maxUnavailable: 1`, the value the API server already defaulted, and Helm takes ownership of it.
  A cluster below 1.37 with the gate turned on by hand is not covered: the API server defaults `maxUnavailable` there
  with no owner, as it would without the chart's constant.
- **Claim templates are a new `volumes` entry type, `volumeClaimTemplate`** (the `volumes` name space,
  [ADR-0049](0049-volumes-are-a-map-of-typed-entries-mounted-in-the-main-container.md)). It takes the fields of an
  `ephemeral` entry (`size`, required; `accessMode`, `ReadWriteOnce` by default; `storageClassName`) and its shape:
  one helper, `chart-base.claimTemplate`, writes both claim templates, and an `ephemeral` volume renders the same. The
  entry renders an item of `volumeClaimTemplates`, named after the volume, never a pod volume; each pod mounts its
  own claim,
  `<volume>-<StatefulSet name>-<ordinal>`, by the volume's name, in the main container, an init container or a sidecar,
  like any volume. A template guard allows the type on a `statefulset` only, and its message names the alternatives
  (an `ephemeral` entry, a `persistentVolumeClaim` entry). The guards of an `ephemeral` entry apply: a `null` size, a
  size of zero, a field of another type, and a volume that every container mounts read-only. The field-ownership
  message names `volumeClaimTemplate` among a field's owners on a `statefulset` only, so the messages of the other
  workload types are unchanged.
- **A claim template carries the two selector labels only, never `commonLabels`** (a ruling in review). The
  API server refuses any change of a StatefulSet's claim templates, their labels included, so a label that the values
  can change would fail every upgrade that changes it; the selector labels are frozen
  ([ADR-0058](0058-the-1-0-contract-and-how-it-stays-frozen.md)) and never do. It is the one labels map
  `commonLabels` does not reach, which amends
  [ADR-0057](0057-common-labels-and-annotations-service-annotations-and-extraobjects.md). An `ephemeral` claim template
  keeps `commonLabels`: it is part of the pod template, which may change. `chart-base.claimTemplate` stays the one
  writer: given a name (a StatefulSet's claim template), it leaves `commonLabels` out.
- **As on a Deployment:** the HTTPRoute, the GRPCRoute and the Ingress; the HPA and the KEDA ScaledObject, with the
  handover annotation ([ADR-0065](0065-an-opt-in-handover-from-the-chart-s-hpa-to-keda.md)), both pointed at the
  StatefulSet by `chart-base.scaleTargetRef`, the one writer of the target; the PodDisruptionBudget and its floor guard
  ([ADR-0062](0062-a-pdb-never-blocks-a-drain-at-the-replica-floor.md)); the ServiceMonitor or the PodMonitor; the
  built-in preStop sleep and its two guards ([ADR-0037](0037-one-prestop-hook.md)); `ports` required with
  `service.enabled`; the default topology spread, with `matchLabelKeys: [controller-revision-hash]`
  ([ADR-0015](0015-pdb-and-topology-spread-by-default.md)). `chart-base.longRunning` names the two types in one place.
- **Ignored on a `statefulset`, and documented:** `strategy` and `progressDeadlineSeconds`. A StatefulSet has no
  surge and no progress deadline ([ADR-0017](0017-progress-deadline-240s.md)); its rollout is `updateStrategy`. Their
  guards stay Deployment-only.
- **The existing-claim rule gets a StatefulSet branch**
  ([ADR-0050](0050-existing-claim-on-a-deployment-and-strategy-rollingupdate-null.md)). A `persistentVolumeClaim`
  entry declared `ReadWriteOnce` or `ReadWriteOncePod` needs one pod: `replicas` 0 or 1 and no HPA, or
  `keda.maxReplicaCount: 1`. There is no surge term: a StatefulSet's rolling update deletes a pod before it creates its
  replacement. The message offers a `volumeClaimTemplate` entry for a claim per pod.
- **The resource name is at most 52 characters on a `statefulset`**, as on a `cronjob`
  ([ADR-0008](0008-names-are-release-alias-and-never-truncated.md)): the `controller-revision-hash` label of its pods
  is `<name>-<hash of up to 10 characters>`.
- **Immutable fields are documented, not guarded.** On an update the API server accepts changes of `replicas`,
  `ordinals`, `template`, `updateStrategy`, `revisionHistoryLimit`, `persistentVolumeClaimRetentionPolicy` and
  `minReadySeconds` only. `serviceName`, `podManagementPolicy` and the claim templates, their labels included, cannot
  change: such an upgrade fails at the API server. A guard would need `lookup`, which `helm template` cannot run.
- **Messages.** Two messages name the kind on a `statefulset` (the HPA next to KEDA, and `metricsFromNamespaces` without
  metrics); on the other types they read as on 1.5.0. Two schema enum messages list the new values: `workload.type`
  and a volume's `type`.

## Consequences

- A component with its own storage per pod deploys from the chart: a StatefulSet, a headless Service with a DNS name
  per pod, and a claim per pod that keeps its data across rollouts and pod restarts.
- **The claims outlive the release by default.** With `persistentVolumeClaimRetentionPolicy` absent (Kubernetes'
  `Retain`), `helm uninstall` and a scale-down leave the claims, and their volumes, in place; a later install with the
  same names mounts them again. `Delete` removes them with the StatefulSet or the scaled-down pods: that choice is the
  consumer's, written in the values.
- **The claim templates are fixed once the StatefulSet exists.** Adding, removing or renaming a `volumeClaimTemplate`
  entry, or changing its size, access mode or class, fails the upgrade at the API server. The upgrade guide gives the
  procedure (delete the StatefulSet with `--cascade=orphan`, then upgrade). `commonLabels` stays free to change: the
  claim templates do not carry it, so a tool that selects claims by a common label (a backup, a cost report) selects
  them by the two selector labels instead.
- A Deployment, a CronJob and a Job render as on 1.5.0, guards and messages included (measured: every 1.5.0 `ci/`
  scenario and a probe set of the features this decision touches, on Helm 4.3.0 and 3.22.0).
- The kind e2e installs `ci/statefulset-values.yaml` and checks the headless Service, one Bound claim per pod on
  kind's local-path class, the Ready pods, that a pod's claim outlives the pod, and the stored `updateStrategy` key by
  key (`type` `RollingUpdate`, `rollingUpdate.partition` `0`; not an exact match, since `maxUnavailable` is stored only
  where the gate is on); it then switches the StatefulSet to `OnDelete` in one upgrade and checks that
  `spec.updateStrategy` is exactly `{"type":"OnDelete"}`.
- **A switch of `updateStrategy` takes one upgrade, in both directions.** `OnDelete` to `RollingUpdate` (with or
  without a `partition`) and back are ordinary upgrades, on Helm 4 and Helm 3. Every StatefulSet manifest carries an
  `updateStrategy`, also with the `statefulset` block absent.
- **The rendered StatefulSet depends on the Kubernetes version it is rendered for.** `helm template` without
  `--kube-version` renders for Helm's built-in version (v1.37.0 for Helm 4.3.0 and 3.22.0, measured), so its output
  carries `maxUnavailable: 1`; a pipeline that renders for a cluster below 1.37 passes `--kube-version`, as an install
  or an upgrade does on its own.
- **Out, recorded:** a DaemonSet (it conflicts with Pod Security `restricted`); a second Service, for example a
  ClusterIP one next to the headless one (one Service per alias, its name in the contract); guards on the immutable
  fields (they need `lookup`); `ordinals`, and `updateStrategy.rollingUpdate.maxUnavailable` as a value (the
  `MaxUnavailableStatefulSet` feature gate is off by default before 1.37, alpha at the 1.33 floor; the chart writes its
  default, 1, as a constant); `volumeClaimTemplates` as a pass-through list.

## Alternatives considered

### Claim templates as `statefulset.volumeClaimTemplates`

The cut row named the block. A second place for volumes would split the name space that the mounts, the guards, the
mount-path rules and the containers' `volumeMounts` share, and a template there would need its own mount mechanism.
Rejected for the `volumes` entry type.

### `commonLabels` on a claim template, as on an `ephemeral` one

It would keep ADR-0057's rule that `commonLabels` reaches every labels map the chart writes. But the API server refuses
any change of a StatefulSet's claim templates, so every later change of `commonLabels`, a routine values change, would
fail the upgrade of every statefulset with a claim template, until someone deletes the StatefulSet with
`--cascade=orphan`. Rejected: a claim template carries the two frozen selector labels only.

### Rendering no `updateStrategy` by default

It keeps the rule of the other members (absent is the Kubernetes default, nothing rendered) and a shorter manifest.
But the API server's default then has no field manager, and a later switch to `OnDelete` fails the upgrade (the
reason above): the remedy would be two upgrades, a `partition` first so that Helm owns `rollingUpdate`, then
`OnDelete`, as ADR-0050 documents for a Deployment that already exists, and where the `MaxUnavailableStatefulSet`
gate is on even that would leave the defaulted `maxUnavailable` unowned. The type is new, so nothing forces that trap
on it. Rejected for the defaults written out.

### `partition` written out, `maxUnavailable` left to the API server

It was the first ruling. It holds on 1.33 to 1.36, where the gate is off, but from 1.37 the API server defaults
`maxUnavailable` with no owner, and the one-upgrade switch to `OnDelete` fails again. Rejected for both keys
written out from 1.37.

### `maxUnavailable: 1` written on every Kubernetes version

It was the second ruling: one manifest for every version, and harmless to the API server, which drops the field where
the gate is off. But the dropped field then never reaches the live object, so below 1.37 every StatefulSet would
differ from its rendered manifest for good, in every tool that compares the two (Argo CD's diff, for example).
Rejected for the constant written from 1.37 only.

### `rollingUpdate: null` next to `OnDelete` in the rendered manifest

It would ask the API server to delete the unowned `rollingUpdate` on the switch. But server-side apply drops a `null`
from the applied configuration, so the stored `rollingUpdate` would stay; and a `null` in the chart's values is absent
by rule ([ADR-0070](0070-a-null-means-absent-chart-wide.md)), so the template would have to write it on its own.
Rejected.

### A ClusterIP Service next to a headless one

It keeps a virtual IP for clients that want one, but a second Service needs a second name, and the names of an alias
are frozen. Clients reach a headless Service by its name (DNS returns every ready pod) or one pod by its own name.
Rejected.

### A schema `if` on the members of `statefulset`

A conditional on a key of a new block holds vacuously when a `--reuse-values` upgrade lacks the block, so the rule
would not run. Rejected for template guards, as for `grpcRoute`.

### `matchLabelKeys: [pod-template-hash]` on a StatefulSet too

A StatefulSet's pods have no `pod-template-hash`: the key would match nothing, and the spread would count the pods of
every revision together during a rollout. Rejected for the label the StatefulSet controller writes.

## References

- `values.yaml` (`workload.type`, `statefulset`, `volumes`, `service`), `values.schema.json` (`statefulset`,
  `definitions.volume`), `templates/statefulset.yaml`, `templates/service.yaml`, `templates/_values.tpl`
  (`chart-base.longRunning`, `chart-base.statefulset`), `templates/_volumes.tpl` (`chart-base.claimTemplate`),
  `templates/_reloader.tpl` (`chart-base.podTemplateAnnotations`), `templates/_pod.tpl`, `templates/_autoscaling.tpl`,
  `templates/validate.yaml`
- `tests/statefulset_test.yaml`, `tests/contract_test.yaml`, `tests/volumes_guards_test.yaml`,
  `tests/service_test.yaml`, `ci/statefulset-values.yaml`, `.github/scripts/e2e.sh`
- [Kubernetes v1.33.0, `staging/src/k8s.io/api/apps/v1/types.go` (`ControllerRevisionHashLabelKey`, `StatefulSetRevisionLabel`)](https://github.com/kubernetes/kubernetes/blob/v1.33.0/staging/src/k8s.io/api/apps/v1/types.go#L27-L28)
- [Kubernetes v1.33.0, `staging/src/k8s.io/api/apps/v1/types.go` (`StatefulSetSpec.UpdateStrategy`, no `patchStrategy`)](https://github.com/kubernetes/kubernetes/blob/v1.33.0/staging/src/k8s.io/api/apps/v1/types.go#L237-L240)
  and [`DeploymentSpec.Strategy`, `patchStrategy:"retainKeys"`](https://github.com/kubernetes/kubernetes/blob/v1.33.0/staging/src/k8s.io/api/apps/v1/types.go#L394-L395)
- [Kubernetes v1.33.0, `pkg/apis/apps/v1/defaults.go` (`SetDefaults_StatefulSet`: `RollingUpdate`, partition 0)](https://github.com/kubernetes/kubernetes/blob/v1.33.0/pkg/apis/apps/v1/defaults.go#L100-L120)
- [Kubernetes v1.37.0, `pkg/apis/apps/v1/defaults.go` (`maxUnavailable` 1 where `MaxUnavailableStatefulSet` is on)](https://github.com/kubernetes/kubernetes/blob/v1.37.0/pkg/apis/apps/v1/defaults.go#L120-L123)
- [Kubernetes v1.37.0, `pkg/features/kube_features.go` (`MaxUnavailableStatefulSet`: alpha 1.24, beta off 1.35, beta on 1.37)](https://github.com/kubernetes/kubernetes/blob/v1.37.0/pkg/features/kube_features.go#L1839-L1843)
- [Kubernetes v1.33.0, `pkg/registry/apps/statefulset/strategy.go` (`dropStatefulSetDisabledFields`: `maxUnavailable` dropped where the gate is off)](https://github.com/kubernetes/kubernetes/blob/v1.33.0/pkg/registry/apps/statefulset/strategy.go#L126-L130)
- [Kubernetes v1.33.0, `pkg/controller/statefulset/stateful_set_utils.go` (`initIdentity`, `setPodRevision`)](https://github.com/kubernetes/kubernetes/blob/v1.33.0/pkg/controller/statefulset/stateful_set_utils.go#L437-L509)
- [Kubernetes v1.33.0, `pkg/controller/history/controller_history.go` (`ControllerRevisionName`, `HashControllerRevision`)](https://github.com/kubernetes/kubernetes/blob/v1.33.0/pkg/controller/history/controller_history.go#L53-L104)
- [Kubernetes v1.33.0, `pkg/controller/podautoscaler/horizontal.go` (the scale client)](https://github.com/kubernetes/kubernetes/blob/v1.33.0/pkg/controller/podautoscaler/horizontal.go#L1329-L1333)
- [Kubernetes v1.33.0, `pkg/registry/apps/statefulset/storage/storage.go` (`ScaleREST`)](https://github.com/kubernetes/kubernetes/blob/v1.33.0/pkg/registry/apps/statefulset/storage/storage.go#L46-L75)
- [Kubernetes v1.33.0, `pkg/apis/apps/validation/validation.go` (the fields an update may change; `OnDelete` with `rollingUpdate`)](https://github.com/kubernetes/kubernetes/blob/v1.33.0/pkg/apis/apps/validation/validation.go#L109-L210)
- [Kubernetes v1.33.0, `staging/src/k8s.io/endpointslice/util/controller_utils.go` (`ShouldSetHostname`)](https://github.com/kubernetes/kubernetes/blob/v1.33.0/staging/src/k8s.io/endpointslice/util/controller_utils.go#L116-L117)
- [Kubernetes DNS-Based Service Discovery specification, 2.4 Records for a Headless Service](https://github.com/kubernetes/dns/blob/master/docs/specification.md#24---records-for-a-headless-service)
- [KEDA v2.21.0, `controllers/keda/scaledobject_controller.go` (`checkTargetResourceIsScalable`)](https://github.com/kedacore/keda/blob/v2.21.0/controllers/keda/scaledobject_controller.go#L425-L444)
- [KEDA 2.21, ScaledObject specification (`scaleTargetRef`)](https://keda.sh/docs/2.21/reference/scaledobject-spec/)
- [Stakater Reloader, README](https://github.com/stakater/Reloader#readme)
- [Kubernetes: StatefulSets](https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/)
