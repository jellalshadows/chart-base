# Roadmap to 1.0

The goal is a finished 1.0 of chart-base, validated by the first real domain umbrella that consumes it. The positioning the 1.0 has to earn, and that the comparison matrix in the README must back, is: *the production-safe generic chart for alias-based umbrellas: production defaults on, every integration opt-in, a strict schema, alias-safe, tested end to end in clusters that enforce Pod Security `restricted`*. Listing on Artifact Hub and other promotion come after 1.0.

The differentiators the 1.0 must preserve: alias-safety (charts that are not alias-safe break when aliased twice in one umbrella), a strict schema at every level, Pod Security `restricted` and resilience on by default, `helm.sh/chart` kept out of the pod template, the config checksum computed over `.data` only, Job hooks whose supporting resources are hooks too, and a missing CRD failing the render instead of being skipped.

## Principles

These apply to every release.

- **Integrations are off by default.** Anything that needs another system (Prometheus Operator, KEDA, NetworkPolicy, Gateway API, External Secrets Operator, ...) is activated only with an explicit `enabled: true`.
- **Posture is on by default.** Pod Security `restricted`, PodDisruptionBudget, topology spread, preStop, `progressDeadlineSeconds` and mandatory resource requests. Lowering the posture is explicit, key by key.
- **The contract is curated.** Every new key comes with a schema using `additionalProperties: false`, `required` wherever a `null` would silently change a default, and `fail` guards for cross-key rules. A new key is additive (minor); changing a default, renaming a key or rejecting or changing a value that an earlier release accepted is a breaking change (`feat!`, or `fix!` when it fixes released behaviour, as the first PR of 0.7.0).
- **One workload per alias.** No feature introduces several workloads or several Services per alias, because that would break alias-safety.
- **Every feature ships complete.** helm-unittest tests written test-first (negative cases included), a scenario in `ci/` (or an extension of an existing one), a check in `e2e.sh` against the real system in kind whenever an operator or CRD is installed in the e2e, updated snapshots, rows in the values table, and its documentation in the repository: new ADRs in `docs/adr/` with context, decision, consequences and rejected alternatives, plus updates to this roadmap, to the affected guides and runbooks, and to the summarized decision in the README.
- **Every new CI dependency is pinned and maintained.** Each operator or CRD installed in CI is pinned by version and kept current by Renovate, and the rejected list in [Out of scope](#out-of-scope) is respected.

## Releases

Each numbered release row is one squash-merged `feat:` PR, which is a minor release while the chart is pre-1.0, except 0.7.0: it is two PRs released together by one Release PR, first a `fix!:` PR with the fixes of released defects, then the volumes `feat:` PR. The docs backfill row is a `docs:` PR that makes no release, and the signing row changes only the publish job, with no contract change.

| Release | Scope | Contract (summary) | Tested in the e2e with | Status |
|---|---|---|---|---|
| Docs backfill (no release) | ADRs for every 0.1.0 decision, this roadmap, guides and runbooks, and a link check in CI. Excluded from the chart package and from release-please. | `docs/` | n/a | Done |
| 0.2.0 | Environment references, `envFrom` and component-level `reloadOnChange` (`feat!`) | `env` (map, references only through `valueFrom`: fieldRef/resourceFieldRef/secretKeyRef/configMapKeyRef; literals stay in `config`), `envFrom` to existing ConfigMaps/Secrets (rendered before the chart's own, so explicit config wins), a duplicate guard against `config`/`externalSecret.data`; **`externalSecret.reloadOnChange` becomes a component-level `reloadOnChange`** (breaking), covering the ESO Secret plus referenced Secrets and ConfigMaps through Reloader. Existing Secrets (for example those created by CNPG or Strimzi) may be referenced by name only. | A shared Secret is created; the CronJob run verifies fieldRef, resourceFieldRef, prefixed `envFrom` and `config` | Released (2026-09-29) |
| Signing (CI only) | Sign the OCI chart with cosign keyless | Signature by digest in the `publish` job, no contract change; verification documented (`cosign verify`) | n/a | Done |
| 0.3.0 | Rollout and pod runtime knobs, service links off (`feat!`) | `strategy`, `minReadySeconds`, `revisionHistoryLimit`, `cronjob.startingDeadlineSeconds`/`suspend`, `priorityClassName`, `runtimeClassName`, `dnsConfig`, `hostAliases`, `lifecycle` (one preStop: `lifecycle.preStop` requires `preStopSleepSeconds: 0`); **`enableServiceLinks` defaults to `false`** (breaking: Deployments roll once on upgrade; CronJob and Job pods pick it up at their next run) | A PriorityClass created in the e2e (the `full` pod gets its priority); the CronJob run sees `KUBERNETES_SERVICE_HOST` but no link to the `deployment` scenario's Service | Released (2026-09-30) |
| 0.4.0 | Prometheus monitoring (ServiceMonitor, PodMonitor, PrometheusRule) | `metrics: {enabled, port, path, interval, scrapeTimeout, labels}` renders a ServiceMonitor when there is a Service and a PodMonitor when there is not (Deployments only; `port` must name an entry of `ports`); `prometheusRule: {enabled, labels, groups}` on every workload type, structure validated, PromQL not; no default `release` label, and the chart's own label keys rejected in `labels` | The Prometheus Operator CRDs only (no operator): the `full` scenario's ServiceMonitor and PrometheusRule and the `worker` scenario's PodMonitor are accepted with their `release: e2e` label and their endpoint port | Released (2026-09-30) |
| 0.5.0 | Opt-in NetworkPolicy with sibling-component references | `networkPolicy: {enabled, ingress: {fromComponents, fromNamespaces, metricsFromNamespaces, routeTrafficAllowedElsewhere, extra}, egress: {enabled, dns, toComponents, toCIDRs, extra}}`: one policy per component, siblings by alias, ingress isolated, egress only with `egress.enabled` (DNS allowed by default), `metricsFromNamespaces` opens only `metrics.port`; on a `job` component a hook of its phase; the render fails on a route (unless `routeTrafficAllowedElsewhere`) or metrics without a source and on egress destinations listed while egress is off; off by default | kindnet (real enforcement in kind 0.24 and later): an umbrella of three components under a namespace default-deny; a deny check first, then a sibling, a monitoring namespace and DNS by Service name allowed and other ports and destinations denied, with `agnhost connect`; the pre-deploy Job reaches the cluster DNS through its hook policy; then, with the default-deny deleted, the chart's own isolation | Released (2026-10-02) |
| 0.6.0 | Existing ServiceAccount and namespaced RBAC (`feat!`) | `serviceAccount.name` (an existing ServiceAccount, only with `create: false`, never `default`); **`serviceAccount.annotations` fail with `create: false`** (breaking: 0.5.0 ignored them); `rbac: {rules, clusterRoles}`: a Role and a RoleBinding `<fullname>` for the rules and one RoleBinding `<fullname>.<ClusterRole>` per existing ClusterRole, for the pods' ServiceAccount in the release namespace; on a `job` component hooks of its phase; in the schema, no `*`, the standard verbs only, no `nonResourceURLs`; the render fails on RBAC for the namespace's `default` ServiceAccount, on RBAC without `automountToken: true` unless no ClusterRole is bound and `use` is the only verb of every rule (an OpenShift SCC grant), on the ClusterRole named `cluster-admin` (other ClusterRoles are granted as they are), and, in a rule with `resourceNames`, on `deletecollection` and on `create` on a resource when that rule grants neither `patch` nor `update` | `kubectl auth can-i` as the ServiceAccounts, a "yes" and a "no" per rule (a subresource without its parent, the listed verbs and names only, `view` in its namespace only); a pod of an existing ServiceAccount that says no token gets one and calls the API (200 allowed, 403 denied); a pre-deploy Job calls the API through its hook Role and RoleBinding | Released (2026-10-06) |
| 0.7.0 | Fixes of released defects (`fix!`), then extra volumes | **Fixes (breaking):** a `null` or empty key of a map-form `configFiles` file and a `null` file are removed in every values layer, and a `null` resource quantity is absent; `configFiles.mountPath` compared normalized (no `/tmp`, no `/`, no token directory with `automountToken: true`) and rendered quoted; the keys an enabled block needs are required, an enabled ExternalSecret needs a `data` entry, a main-container probe port name must be declared in `ports`; the entries of `httpRoute.parentRefs` and `httpRoute.matches` are closed. **Then (`feat:`):** `volumes: {<name>: {type: emptyDir/configMap/secret/persistentVolumeClaim/ephemeral, mountPath, subPath, readOnly, ...}}`, each mounted in the main container, a `null` entry or field absent; mount paths compared normalized and unique among the container's mounts, `/` and the token directory reserved, a ConfigMap or Secret file never beneath a ConfigMap or Secret mount; reserved volume names; an existing claim declares `claimAccessMode`, and on a Deployment a `ReadWriteOnce` claim needs one pod at a time; the mounted ConfigMaps and Secrets feed the Reloader; `strategy.rollingUpdate: null` is absent and `rollingUpdate` next to `Recreate` is a guard | kind's local-path-provisioner: an existing claim kept across CronJob runs, an ephemeral claim per pod (owned by it, deleted with it), a tmpfs `emptyDir`, a Secret directory beneath the config-files mount, one ConfigMap key as a file, the Reloader feed, and two in-place strategy changes of a Deployment with a claim | Released (2026-10-08) |
| 0.8.0 | Native sidecars and init containers | `initContainers` and `sidecars`: maps keyed by the container name, rendered into the pod's `initContainers` in one start order (`order`, default 0 for an init container and 1000 for a sidecar; a sidecar with `restartPolicy: Always`), a `null` entry or optional field absent at any depth (not inside a list or an env variable's `valueFrom`, a probe's `httpGet` or `exec`; a required field stays a schema error); each entry `image`, `resources` (requests required), `command`, `args`, `securityContext` (merged over the chart's hardened default, not the component's), `env` (references; `inheritEnv` for exactly the main container's) and `volumeMounts`, a sidecar also pod-internal `ports` and closed `probes`; names, ports, probe port names, mounts and UID 0 guarded; a sidecar on a `job`/`cronjob` needs `job.activeDeadlineSeconds`; the entries' references feed the Reloader; `volumes.<name>.mountPath` optional for a volume another container mounts; with a sidecar the HPA's built-in targets are `ContainerResource` of the main container | kind: the start order (an init container placed after a sidecar reaches it at its first attempt), an `emptyDir` filled by an init container and read-only in the main container, a hook Job that completes with a sidecar, the fronting-proxy recipe through the Service and a NetworkPolicy named port with the bypass denied, the HPA's stored metrics | Released (2026-10-09) |
| 0.9.0 | ExternalSecret `dataFrom`, templates and file mounts | `externalSecret.dataFrom`, `.template`, `.mountPath` (reuses the volumes); still one ExternalSecret per component | ESO fake provider (`dataFrom` extract) | Planned |
| 0.10.0 | HPA behavior and custom metrics, and KEDA ScaledObject | `autoscaling.behavior`, `autoscaling.metrics`; `keda: {enabled, minReplicaCount, maxReplicaCount, triggers}`; a guard makes HPA and KEDA mutually exclusive; omits `spec.replicas`. With an empty `autoscaling.metrics` the built-in targets keep 0.8.0's rule (`ContainerResource` of the main container once there is a sidecar, [ADR-0052](adr/0052-hpa-targets-measure-the-main-container-with-sidecars.md)); a non-empty list is rendered as written | KEDA (`cron` trigger) | Planned |
| 0.11.0 | GRPCRoute and HTTPRoute rules | `grpcRoute: {...}`, `httpRoute.rules` (replaces `matches`), `ports[].appProtocol` | Gateway API CRDs (already in CI) | Planned |
| 0.12.0 | Common labels, Service annotations and `extraObjects` | Labels and annotations common to every object, `service.annotations`, `extraObjects` with guards (name prefixed with `<fullname>`, no foreign namespace) | n/a | Planned |
| 0.13.0 | StatefulSet workload type | `workload.type: statefulset`, `statefulset: {volumeClaimTemplates, podManagementPolicy, persistentVolumeClaimRetentionPolicy}`, headless Service, 52-character name guard; its claim templates share the `volumes` name space ([ADR-0049](adr/0049-volumes-are-a-map-of-typed-entries-mounted-in-the-main-container.md)), and their shape belongs to the 0.13.0 design | kind's local-path-provisioner | Planned |

## Open decisions

- **A chart-wide "a `null` entry means absent" rule** (a 0.12.0 candidate, decided with that design). Today the rule
  holds per map only: in 0.7.0 `configFiles.files`, the content of a map-form file, `resources`, `volumes` and
  `strategy.rollingUpdate` ([ADR-0045](adr/0045-null-in-configfiles-and-resources-is-absent.md), [ADR-0049](adr/0049-volumes-are-a-map-of-typed-entries-mounted-in-the-main-container.md),
  [ADR-0050](adr/0050-existing-claim-on-a-deployment-and-strategy-rollingupdate-null.md)), in 0.8.0 `initContainers` and `sidecars` for optional fields at any depth but inside a list, an env
  variable's `valueFrom` and a probe's `httpGet` or `exec` (a required field such as a mount's `mountPath` stays an error) ([ADR-0051](adr/0051-init-containers-and-sidecars-are-two-maps-in-one-start-order.md)). What stays without it once the maps of 0.7.0 to 0.10.0 are converted: one
  entry of a typed map (`config`, the main container's `env`, `podLabels`, `podAnnotations`, `ingress.annotations`,
  `serviceAccount.annotations`, `metrics.labels`, `prometheusRule.labels`, `nodeSelector`,
  `networkPolicy.egress.dns.podSelector`) and an optional member of a closed object (`lifecycle.<hook>`,
  `strategy.rollingUpdate.maxSurge` and `.maxUnavailable`, `dnsConfig.nameservers`, `.searches`, `.options`), schema errors today; a key inside a
  pass-through object (`probes.<probe>.<key>`, `affinity.<key>`, the keys of `podSecurityContext` and
  `securityContext` that `values.yaml` does not define), rendered as `null` today, so converting it changes the
  manifest; `httpRoute.matches` (0.11.0 replaces it); the maps that 0.11.0 and 0.12.0 add. Converting a map
  converts its template readers and guards with
  it.
- **`ingress.className: null`** renders an Ingress without a class ([upgrade guide](upgrading.md)): close it with
  `required`, or support "no class" on purpose, at the 1.0 contract freeze.
- **One rule for the ServiceAccount token directory as a mount path**: `configFiles.mountPath` rejects it only while
  `serviceAccount.automountToken` is true ([ADR-0046](adr/0046-configfiles-mountpath-compared-normalized-rendered-as-written.md)); `volumes` (0.7.0,
  [ADR-0049](adr/0049-volumes-are-a-map-of-typed-entries-mounted-in-the-main-container.md)) and the mounts that later releases add reserve it always. Unify at the 1.0
  contract freeze.
- **A per-volume Reloader opt-out** (`volumes.<name>.reloadOnChange`): every rotation of a mounted ConfigMap or Secret
  restarts the Deployment, and `reloadOnChange: false` also stops the restarts for `env`/`envFrom` Secrets
  ([ADR-0049](adr/0049-volumes-are-a-map-of-typed-entries-mounted-in-the-main-container.md)). Decide with the first real umbrella (1.0 criterion 2): adding the key is
  additive, removing it is not.

- **Follow-ups of 0.8.0** ([ADR-0051](adr/0051-init-containers-and-sidecars-are-two-maps-in-one-start-order.md)), each additive: a per-entry `automountToken: false` (today every
  init container and sidecar gets the token when the pod does); an entry-level `config` for literal variables (the
  first real case: cloud-sql-proxy's `CSQL_PROXY_*` settings, today passed in `args`); `lifecycle` on an entry; a
  sidecar port exposed in the Service.
- **Checks that would reject values that render today** (a breaking release, or the 1.0 contract freeze): a
  `lifecycle` hook's `httpGet.port` given by a name that `ports` does not declare (a `preStop` hook then fails with only
  a `FailedPreStopHook` event: kubelet source reading); a `subPath` of the main container's `configMap` or `secret`
  mount that names no `items[].path` (an empty directory is mounted; 0.8.0 checks it for init containers and sidecars);
  UID 0 with `runAsNonRoot: true` on the main container (0.8.0 checks it for init containers and sidecars); the main
  container's `probes` closed like a sidecar's (`definitions.probe`: no `host`, no misspelt field; until the 1.0 contract
  freeze the chart has two probe contracts, [ADR-0051](adr/0051-init-containers-and-sidecars-are-two-maps-in-one-start-order.md)).

The decision whether NetworkPolicy becomes on by default after 0.5.0 was taken with 0.5.0: it stays off.
On a CNI that does not enforce it, a policy changes nothing, and its rules depend on facts of each cluster (the
namespaces of the Gateway and of Prometheus, the cluster DNS); turning it on would make them mandatory configuration
([ADR-0040](adr/0040-networkpolicy-per-component-with-sibling-references.md)).

## 1.0.0 criteria

1. All twelve feature releases above (0.2.0 to 0.13.0) and the cosign signing step are published, each with its e2e green on Kubernetes 1.33 and 1.37 (or the supported versions current at that time).
2. The chart is validated by the first real domain umbrella, deployed with helmfile. Whatever that use reveals is fixed before 1.0.
3. The contract is frozen: selector labels and key names. From 1.0 on, only additive changes (`feat:`) or explicit majors.
4. The README carries a comparison matrix (dated, with the versions checked) that backs the positioning above, re-verified against the current versions of the other charts before it is published.

## Out of scope

Rejected features, with the reason:

- **DaemonSet.** It conflicts with Pod Security `restricted`.
- **SealedSecrets, plain Secrets and SecretProviderClass.** They would add a second path for secrets next to External Secrets Operator.
- **cert-manager Certificate.** TLS is terminated at the Gateway.
- **ClusterRole and ClusterRoleBinding.** Cluster-scoped RBAC breaks multi-tenancy.
- **A chart-created PersistentVolumeClaim for Deployments.** It causes Multi-Attach errors; use an `ephemeral` volume or a StatefulSet. An existing claim can be mounted (`volumes`, 0.7.0); on a Deployment, one declared `ReadWriteOnce` requires one pod at a time ([ADR-0050](adr/0050-existing-claim-on-a-deployment-and-strategy-rollingupdate-null.md)).
- **Several workloads, or non-native containers, per alias.** It breaks the one-workload-per-alias model.
- **Helm tests.** The e2e already validates the chart and Argo CD does not run them.
- **`nameOverride` and `fullnameOverride`.** See [ADR-0009](adr/0009-no-name-overrides.md).
- **Gating on `.Capabilities`.** See [ADR-0012](adr/0012-no-capabilities-gating.md).
- **Resource presets.** See [ADR-0014](adr/0014-resource-requests-required.md).
- **`diagnosticMode`.** `kubectl debug` already covers diagnosis.

Only with real demand, and only after 1.0: VPA, Argo Rollouts, KEDA ScaledJob, TLS/TCP/UDP Routes and ListenerSet.

## How each release is made

1. **Short design.** A short design review of the exact contract of the release (keys, defaults, guards, what the e2e proves), approved by the owner. The open decisions marked above are taken here.
2. **Verified plan.** An implementation plan with the complete code, prototyped and verified beforehand.
3. **Implementation with reviews.** The plan is implemented task by task, with a review of every step and a final review of the whole branch.
4. **Pull request.** A PR with green CI, including the real kind e2e, is merged; release-please then opens the release PR.
5. **Release.** The owner merges the release PR, and the publish is verified. The status of the release in this roadmap is updated as part of that release.
