# Roadmap to 1.0

The goal is a finished 1.0 of chart-base, validated by the first real domain umbrella that consumes it. The positioning the 1.0 has to earn, and that the comparison matrix in the README must back, is: *the production-safe generic chart for alias-based umbrellas: production defaults on, every integration opt-in, a strict schema, alias-safe, tested end to end in clusters that enforce Pod Security `restricted`*. Listing on Artifact Hub and other promotion come after 1.0.

The differentiators the 1.0 must preserve: alias-safety (charts that are not alias-safe break when aliased twice in one umbrella), a strict schema at every level, Pod Security `restricted` and resilience on by default, `helm.sh/chart` kept out of the pod template, the config checksum computed over `.data` only, Job hooks whose supporting resources are hooks too, and a missing CRD failing the render instead of being skipped.

## Principles

These apply to every release.

- **Integrations are off by default.** Anything that needs another system (Prometheus Operator, KEDA, NetworkPolicy, Gateway API, External Secrets Operator, ...) is activated only with an explicit `enabled: true`.
- **Posture is on by default.** Pod Security `restricted`, PodDisruptionBudget, topology spread, preStop, `progressDeadlineSeconds` and mandatory resource requests. Lowering the posture is explicit, key by key.
- **The contract is curated.** Every new key comes with a schema using `additionalProperties: false`, `required` wherever a `null` would silently change a default, and `fail` guards for cross-key rules. A new key is additive (minor); changing a default or renaming a key is a `feat!`.
- **One workload per alias.** No feature introduces several workloads or several Services per alias, because that would break alias-safety.
- **Every feature ships complete.** helm-unittest tests written test-first (negative cases included), a scenario in `ci/` (or an extension of an existing one), a check in `e2e.sh` against the real system in kind whenever an operator or CRD is installed in the e2e, updated snapshots, rows in the values table, and its documentation in the repository: new ADRs in `docs/adr/` with context, decision, consequences and rejected alternatives, plus updates to this roadmap, to the affected guides and runbooks, and to the summarized decision in the README.
- **Every new CI dependency is pinned and maintained.** Each operator or CRD installed in CI is pinned by version and kept current by Renovate, and the rejected list in [Out of scope](#out-of-scope) is respected.

## Releases

Each row is one squash-merged `feat:` PR, which is a minor release while the chart is pre-1.0.

| Release | Scope | Contract (summary) | Tested in the e2e with | Status |
|---|---|---|---|---|
| Docs backfill (no release) | ADRs for every 0.1.0 decision, this roadmap, guides and runbooks, and a link check in CI. Excluded from the chart package and from release-please. | `docs/` | n/a | In progress |
| 0.2.0 | Environment references, `envFrom` and component-level `reloadOnChange` (`feat!`) | `env` (map, references only through `valueFrom`: fieldRef/resourceFieldRef/secretKeyRef/configMapKeyRef; literals stay in `config`), `envFrom` to existing ConfigMaps/Secrets (rendered before the chart's own, so explicit config wins), a duplicate guard against `config`/`externalSecret.data`; **`externalSecret.reloadOnChange` becomes a component-level `reloadOnChange`** (breaking), covering the ESO Secret plus referenced Secrets and ConfigMaps through Reloader. Existing Secrets (for example those created by CNPG or Strimzi) may be referenced by name only. | A shared Secret is created; the CronJob run verifies fieldRef, resourceFieldRef, prefixed `envFrom` and `config` | Planned |
| Signing (CI only) | Sign the OCI chart with cosign keyless | Signature by digest in the `publish` job, no contract change; verification documented (`cosign verify`) | n/a | Planned |
| 0.3.0 | Rollout and pod runtime knobs | `strategy`, `minReadySeconds`, `revisionHistoryLimit`, `cronjob.startingDeadlineSeconds`/`suspend`, `priorityClassName`, `runtimeClassName`, `dnsConfig`, `hostAliases`, `lifecycle`, `enableServiceLinks` | A PriorityClass created in the e2e | Planned |
| 0.4.0 | Prometheus monitoring (ServiceMonitor, PodMonitor, PrometheusRule) | `metrics: {enabled, port, path, interval, scrapeTimeout}` renders a ServiceMonitor when there is a Service and a PodMonitor when there is not; `prometheusRule: {enabled, groups}` | Prometheus Operator CRDs | Planned |
| 0.5.0 | Opt-in NetworkPolicy with sibling-component references | `networkPolicy: {enabled, ingress: {fromComponents, fromNamespaces, extra}, egress: {dns, toComponents, toCIDRs, extra}}`; allows the metrics port from the monitoring namespace | kindnet (real enforcement in kind 0.24 and later): allow and deny checks with `agnhost connect` | Planned |
| 0.6.0 | Existing ServiceAccount and namespaced RBAC | `serviceAccount.name` (only with `create: false`); `rbac.rules` renders a Role and RoleBinding; guard: `rbac.rules` requires `automountToken: true` | n/a | Planned |
| 0.7.0 | Extra volumes | `volumes: {<name>: {type: emptyDir/configMap/secret/persistentVolumeClaim/ephemeral, mountPath, readOnly, subPath...}}`; guards: mountPath must not be `/tmp` nor `configFiles.mountPath` | kind's local-path-provisioner | Planned |
| 0.8.0 | Native sidecars and init containers | `sidecars` / `initContainers` (maps) that inherit `securityContext`; `resources.requests` are mandatory; native sidecars (`restartPolicy: Always`) | n/a (a Job with a sidecar must complete) | Planned |
| 0.9.0 | ExternalSecret `dataFrom`, templates and file mounts | `externalSecret.dataFrom`, `.template`, `.mountPath` (reuses the volumes); still one ExternalSecret per component | ESO fake provider (`dataFrom` extract) | Planned |
| 0.10.0 | HPA behavior and custom metrics, and KEDA ScaledObject | `autoscaling.behavior`, `autoscaling.metrics`; `keda: {enabled, minReplicaCount, maxReplicaCount, triggers}`; a guard makes HPA and KEDA mutually exclusive; omits `spec.replicas` | KEDA (`cron` trigger) | Planned |
| 0.11.0 | GRPCRoute and HTTPRoute rules | `grpcRoute: {...}`, `httpRoute.rules` (replaces `matches`), `ports[].appProtocol` | Gateway API CRDs (already in CI) | Planned |
| 0.12.0 | Common labels, Service annotations and `extraObjects` | Labels and annotations common to every object, `service.annotations`, `extraObjects` with guards (name prefixed with `<fullname>`, no foreign namespace) | n/a | Planned |
| 0.13.0 | StatefulSet workload type | `workload.type: statefulset`, `statefulset: {volumeClaimTemplates, podManagementPolicy, persistentVolumeClaimRetentionPolicy}`, headless Service, 52-character name guard | kind's local-path-provisioner | Planned |

## Open decisions

- **`enableServiceLinks` default.** To be decided in the 0.3.0 design. Defaulting it to `false` would be a breaking change (`feat!`) that restarts every pod once; the alternative is to keep the Kubernetes default and only expose the key.
- **NetworkPolicy on by default.** Whether NetworkPolicy should become on by default after 0.5.0 is still undecided.

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
- **PersistentVolumeClaim for Deployments.** It causes Multi-Attach errors; use an `ephemeral` volume or a StatefulSet.
- **Several workloads, or non-native containers, per alias.** It breaks the one-workload-per-alias model.
- **Helm tests.** The e2e already validates the chart and Argo CD does not run them.
- **`nameOverride` and `fullnameOverride`.** See [ADR-0009](adr/0009-no-name-overrides.md).
- **Gating on `.Capabilities`.** See [ADR-0012](adr/0012-no-capabilities-gating.md).
- **Resource presets.** See [ADR-0014](adr/0014-resource-requests-required.md).
- **`diagnosticMode`.** Rejected together with the three items above.

Only with real demand, and only after 1.0: VPA, Argo Rollouts, KEDA ScaledJob, TLS/TCP/UDP Routes and ListenerSet.

## How each release is made

1. **Short design.** A short design review of the exact contract of the release (keys, defaults, guards, what the e2e proves), approved by the owner. The open decisions marked above are taken here.
2. **Verified plan.** An implementation plan with the complete code, prototyped and verified beforehand.
3. **Implementation with reviews.** The plan is implemented task by task, with a review of every step and a final review of the whole branch.
4. **Pull request.** A PR with green CI, including the real kind e2e, is merged; release-please then opens the release PR.
5. **Release.** The owner merges the release PR, and the publish is verified. The status of the release in this roadmap is updated as part of that release.
