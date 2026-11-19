# ADR-0071: A StatefulSet workload type with a claim per pod

- **Status:** Accepted
- **Date:** 2026-11-19
- **Since:** 1.6.0
- **Related:** [ADR-0008](0008-names-are-release-alias-and-never-truncated.md) (amended), [ADR-0015](0015-pdb-and-topology-spread-by-default.md) (amended), [ADR-0036](0036-rollout-and-runtime-knobs-are-validated-pass-throughs.md) (amended), [ADR-0037](0037-one-prestop-hook.md) (amended), [ADR-0038](0038-one-metrics-endpoint-servicemonitor-or-podmonitor.md) (amended), [ADR-0049](0049-volumes-are-a-map-of-typed-entries-mounted-in-the-main-container.md) (amended), [ADR-0050](0050-existing-claim-on-a-deployment-and-strategy-rollingupdate-null.md) (amended), [ADR-0056](0056-keda-scaledobject-a-curated-block-with-a-triggers-map.md) (amended), [ADR-0062](0062-a-pdb-never-blocks-a-drain-at-the-replica-floor.md) (amended), [ADR-0017](0017-progress-deadline-240s.md), [ADR-0058](0058-the-1-0-contract-and-how-it-stays-frozen.md), [ADR-0064](0064-from-1-0-0-a-new-key-is-optional.md), [ADR-0069](0069-grpcroute-httproute-rules-and-appprotocol.md), [ADR-0070](0070-a-null-means-absent-chart-wide.md)

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
    A `rollingUpdate` next to `OnDelete`, an empty one included, fails a guard: Kubernetes rejects it;
  - `persistentVolumeClaimRetentionPolicy`: `whenDeleted` and `whenScaled`, each `Retain` or `Delete` (absent:
    Kubernetes' `Retain`).

  A member is set when it is not `null` and not left empty by its `null`s (`chart-base.statefulset` reads a pruned
  copy). A set member on another workload type fails a guard. These are template guards, not schema conditionals on a
  key of the new block, which would hold vacuously after a `--reuse-values` upgrade from a release without it
  ([ADR-0069](0069-grpcroute-httproute-rules-and-appprotocol.md)); the schema's own rules condition on `workload.type`
  only.
- **Claim templates are a new `volumes` entry type, `volumeClaimTemplate`** (the `volumes` name space,
  [ADR-0049](0049-volumes-are-a-map-of-typed-entries-mounted-in-the-main-container.md)). It takes the fields of an
  `ephemeral` entry (`size`, required; `accessMode`, `ReadWriteOnce` by default; `storageClassName`) and its shape:
  one helper, `chart-base.claimTemplate`, writes both claim templates, and an `ephemeral` volume renders the same. The
  entry renders an item of `volumeClaimTemplates`, named after the volume and labelled as an `ephemeral` claim
  template (the selector labels and `commonLabels`), never a pod volume; each pod mounts its own claim,
  `<volume>-<StatefulSet name>-<ordinal>`, by the volume's name, in the main container, an init container or a sidecar,
  like any volume. A template guard allows the type on a `statefulset` only, and its message names the alternatives
  (an `ephemeral` entry, a `persistentVolumeClaim` entry). The guards of an `ephemeral` entry apply: a `null` size, a
  size of zero, a field of another type, and a volume that every container mounts read-only. The field-ownership
  message names `volumeClaimTemplate` among a field's owners on a `statefulset` only, so the messages of the other
  workload types are unchanged.
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
- **`commonLabels` is fixed on a release with a claim template.** The claim templates carry `commonLabels`, as an
  `ephemeral` claim template does, and the API server refuses any change of a StatefulSet's claim templates: changing
  `commonLabels` then fails the upgrade. The same holds for adding or removing a `volumeClaimTemplate` entry, or
  changing its size, access mode or class. The upgrade guide gives the procedure (delete the StatefulSet with
  `--cascade=orphan`, then upgrade). Leaving `commonLabels` off the claim templates would have avoided this and broken
  the rule that `commonLabels` reaches every labels map the chart writes
  ([ADR-0057](0057-common-labels-and-annotations-service-annotations-and-extraobjects.md)); the rule was kept.
- A Deployment, a CronJob and a Job render as on 1.5.0, guards and messages included (measured: every 1.5.0 `ci/`
  scenario and a probe set of the features this decision touches, on Helm 4.3.0 and 3.22.0).
- The kind e2e installs `ci/statefulset-values.yaml` and checks the headless Service, one Bound claim per pod on
  kind's local-path class, the Ready pods, and that a pod's claim outlives the pod.
- **Out, recorded:** a DaemonSet (it conflicts with Pod Security `restricted`); a second Service, for example a
  ClusterIP one next to the headless one (one Service per alias, its name in the contract); guards on the immutable
  fields (they need `lookup`); `ordinals` and `updateStrategy.rollingUpdate.maxUnavailable` (`MaxUnavailableStatefulSet`
  is an alpha feature gate, off at the 1.33 floor); `volumeClaimTemplates` as a pass-through list.

## Alternatives considered

### Claim templates as `statefulset.volumeClaimTemplates`

The cut row named the block. A second place for volumes would split the name space that the mounts, the guards, the
mount-path rules and the containers' `volumeMounts` share, and a template there would need its own mount mechanism.
Rejected for the `volumes` entry type.

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
