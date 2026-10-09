# ADR-0051: Init containers and sidecars are two maps in one start order, and nothing is inherited from the main container

- **Status:** Accepted
- **Date:** 2026-10-08
- **Since:** 0.8.0
- **Related:** [ADR-0011](0011-strict-draft-07-schema.md), [ADR-0013](0013-secure-by-default.md), [ADR-0014](0014-resource-requests-required.md), [ADR-0030](0030-env-takes-references-only.md), [ADR-0033](0033-component-level-reload-on-change.md), [ADR-0044](0044-guards-fail-the-render-helm-lint-reports-them.md), [ADR-0047](0047-when-enabled-keys-required-externalsecret-source-probe-port-names.md), [ADR-0049](0049-volumes-are-a-map-of-typed-entries-mounted-in-the-main-container.md) (amended), [ADR-0052](0052-hpa-targets-measure-the-main-container-with-sidecars.md)

## Context

Until 0.7.0 a component's pod had one container. A database proxy, a log shipper, a migration that runs before the
application, or a check that waits for a dependency could not be declared. The facts that shape the contract:

- **Kubernetes has one ordered list.** A native sidecar is an entry of `spec.initContainers` with
  `restartPolicy: Always`; the feature is GA and locked on in Kubernetes 1.33, and its gate is gone in 1.37 (source
  reading). The API forbids a probe on a plain init container (`may not be set for init containers without
  restartPolicy=Always`, measured on kube-apiserver 1.33.0 and 1.37.0). The next container starts once a sidecar has
  started: it runs, its `postStart` returned and its `startupProbe` passed (kubelet source reading; the e2e checks
  the order on kind).
- **Resources.** The scheduler reserves the larger of the regular containers plus the sidecars and, for each init
  container, that init container plus the sidecars started before it, so the order changes the reservation (measured
  through ResourceQuota usage on kube-apiserver 1.33.0 and 1.37.0 when 0.8.0 was designed: 500m against 550m). A pod
  is `Guaranteed` only when every container has limits equal to its requests, LimitRange defaults reach every
  container, and a namespace whose ResourceQuota tracks cpu or memory rejects an init container or a sidecar that does
  not set what the quota tracks (measured then too: a quota on `limits.cpu` needs a cpu limit on every one of them
  as well; the schema already requires the requests).
- **Pod Security `restricted`.** The four fields that `values.yaml` ships for `securityContext`, with the chart's
  `podSecurityContext`, are what every container needs: a pod with a plain init container and a sidecar that carry
  them is admitted on kube-apiserver 1.33.0 and 1.37.0 under `restricted:latest`, and the same pod with a sidecar
  whose `capabilities.drop` is `[]` is rejected on both (measured). A probe's `httpGet.host` or `tcpSocket.host`, on a
  sidecar or on the main container, is admitted on 1.33.0 and rejected on 1.37.0 (`probe or lifecycle host`, measured):
  baseline rejects both from policy v1.34.
- **Helm's merge functions.** `mergeOverwrite` of an override onto a copy of the default keeps an explicit `false`,
  `merge` loses it, and a list in the override replaces the default's list (`drop: []` replaces `[ALL]`; measured on
  Helm 4.3.0 and 3.22.0).
- **A repeated `env` name.** Helm 4.3 applies server-side by default, and the API server refuses a container with two
  variables of one name (`duplicate entries for key [name="POD_NAME"]`); Helm 3.22's client-side apply creates it with
  a warning (`hides previous definition`) and stores both (measured on kube-apiserver 1.33.0 and 1.37.0).
- **Ports.** The API only warns when two containers of a pod declare one port name or number, and a Service then picks
  one of the two silently (measured when 0.8.0 was designed). The kubelet resolves a probe's port name among the ports
  of the probed container only (`pkg/probe/util.go`, `ResolveContainerPort` and `findPortByName` at v1.33.12 and
  v1.37.0, source reading): a probe on a name declared by another container never runs. A port NUMBER reaches whatever
  listens on it in the pod: the containers share one network namespace.
- **A sidecar that exits before it has started** is restarted with back-off and keeps the pod Pending, so a Job's
  `backoffLimit` never triggers and a CronJob with `concurrencyPolicy: Forbid` skips every later run
  (`kuberuntime_container.go` v1.37.0 L1206-1208 and the CronJob controller v1.37.0 L595, source reading, not run).
- **UID 0 with `runAsNonRoot: true`.** The kubelet refuses to start such a container (`security_context_others.go`
  v1.33.12 L38-41 and v1.37.0 L41-44, source reading, not run): an entry is an init container, so the pod never
  initializes.
- **Helm and `null`.** Helm deletes a key on `null` only when the chart's own `values.yaml` defines it, so a `null`
  below `initContainers.<name>` reaches the chart from `-f`/`--set` and from Helm 3.22's umbrella values, while Helm 4.3
  drops a `null` of the umbrella's own values while nothing is passed for that alias (measured on Helm 4.3.0 and
  3.22.0; the same facts as [ADR-0049](0049-volumes-are-a-map-of-typed-entries-mounted-in-the-main-container.md)). Helm 3.22 hands the chart a nil map for a deleted
  default. A `--set` below an entry that an override file sets to `null` fails in Helm itself (`failed parsing --set
  data: unable to parse key: interface conversion: interface {} is nil, not map[string]interface {}`, measured on Helm
  4.3.0 and 3.22.0).
- **Keys that YAML 1.1 reads as booleans**: two sidecars `on` and `yes`, unquoted, render ONE container named
  `"true"` (measured on Helm 4.3.0 and 3.22.0), and a single key such as `off` or `n` is renamed to `"false"`. The same
  holds for an `env` or `config` name such as `OFF`: unquoted it is renamed to `false` with no error (measured on both).
  Quote such a key.

## Decision

**Two maps, `initContainers` and `sidecars`**, keyed by the container name, default `{}`, not required keys. Both are
rendered into the pod's one `initContainers` list; the chart writes `restartPolicy: Always` on every sidecar and nothing
on an init container (`restartPolicy` in an entry fails, and the message says where such a container goes).

- **One start order.** Every entry has an integer `order` from -1000 to 1000; an init container's default is 0, a
  sidecar's 1000. Containers start in ascending `order`, then the init containers before the sidecars, then by name:
  the sort key is the text `<order + 1000, four digits>|<0 or 1>|<name>`, and the offset 1000 is minus the schema's
  minimum, so the number is never negative (two negative numbers sort backwards as text). So every init container
  runs before every sidecar whose `order` is not set: to start a sidecar before an init container, lower the
  sidecar's `order` (a database proxy that a migration needs); raising an init container's `order` never moves it
  behind such a sidecar.
- **The entry.** A closed object: `image` (`repository`; `tag` or `digest`, the digest wins; `pullPolicy`, default
  `IfNotPresent`), `resources` (`requests.cpu` and `requests.memory` required, the main container's definition),
  `command`, `args`, `securityContext`, `order`, `env`, `inheritEnv` and `volumeMounts`; a sidecar also `ports` and
  `probes`. No `lifecycle`, no literal `env` value, no `envFrom` of its own, and no raw Kubernetes container (the
  strictness of [ADR-0011](0011-strict-draft-07-schema.md)).
- **`null`.** In `initContainers` and `sidecars` a `null` entry or optional field is absent at any depth (in maps; a list is kept as written, and a required field
   such as a mount's `mountPath` or a probe's `port` stays a schema error), from every values
  layer and on Helm 3.22 and 4.3 alike, except inside the definitions the main container shares: one variable's
  `valueFrom` and a probe's `httpGet` or `exec`, where a `null` stays a schema error (an overlay replaces or removes
  such an object whole). This is the rule of these maps, not of every map: the main container's `env.<NAME>: null` is
  still a schema error. Every template and guard reads the two maps through one accessor, `chart-base.containers`
  (`chart-base.pruneNulls` on a deep copy; a value that is not a map is empty, so the list form gets its own message).
  A `null` entry is skipped before every check, the name checks included.
- **Names.** A DNS-1123 label of at most 63 characters, checked by a guard (not by `propertyNames`, whose error
  Helm's library reports at another path), unique across both maps and the main container, which is named after the
  component (the alias, or `chart-base` without one).
- **The security context.** Every entry starts from the chart's hardened default (`allowPrivilegeEscalation: false`,
  `readOnlyRootFilesystem: true`, `runAsNonRoot: true`, `capabilities.drop: [ALL]`; a template literal next to the copy
  in `values.yaml`, kept equal by a test), never from the component's `securityContext`, and its own
  `securityContext` is merged over it with `mergeOverwrite` after its `null` fields are removed: a `null` restores the
  default of that field, a list replaces the default's. A relaxation of the main container does not reach another
  container; the pod-level `podSecurityContext` reaches every container (its `runAsUser` and `runAsGroup` unless an entry sets its own,
   and one `fsGroup` for every volume), and the container default
  does not follow it. An entry that would run as UID 0 (its merged `runAsUser`, else `podSecurityContext.runAsUser`)
  with `runAsNonRoot: true` fails.
- **Nothing is inherited from the main CONTAINER; what the POD grants is shared.** An entry declares its own `env`,
  references only, with the main container's one definition of a variable (`definitions.envVar`) and one renderer
  (`chart-base.env`). `inheritEnv: true` gives it exactly the main container's `envFrom` and `env`, and then an
  `env` name of the entry that the main container already receives (from its `env`, `config` or
  `externalSecret.data`, the list `chart-base.chartEnvNames` that the main container's own duplicate guard reads)
  fails: the result is one map, never two variables of one name. A `null` in an entry's `env` removes the entry's own
  variable, never an inherited one. Mounts are explicit (`volumeMounts`). Every container of the pod, whatever its
  entry declares, shares the ServiceAccount token (with `serviceAccount.automountToken`) and with it the `rbac`
  grants and the cloud identity, the NetworkPolicy allowances, `podSecurityContext`, `imagePullSecrets` and the
  network namespace.
- **Mounts.** `volumeMounts` is a map keyed by the volume name (`mountPath` required, `subPath`, `readOnly`): the
  chart's `tmp`, `config-files` while a file is rendered, or a non-null entry of `volumes`; each container's mounts
  render in key order. A mount of `config-files`, of a `configMap` or `secret` volume, or of a claim declared
  `ReadOnlyMany` is rendered read-only and `readOnly: false` on it fails. The rules of the main container's mounts
  hold per container: normalized paths unique among its own mounts, not `/`, not the token directory, no ConfigMap
  or Secret file beneath a ConfigMap or Secret mount, a relative `subPath`; and with `items` set, a `subPath` must name
  one of the item paths, a directory that holds one or `.` (the whole volume; the kubelet would mount an empty directory
   otherwise); and a `subPath` of `config-files` is one of the files rendered or `.`.
- **This amends [ADR-0049](0049-volumes-are-a-map-of-typed-entries-mounted-in-the-main-container.md)**: `volumes.<name>.mountPath` is optional and nullable for a volume that an init
  container or a sidecar mounts (the main container then does not mount it; `subPath` and `readOnly`, which describe
  the main container's mount, then fail, and so does a volume that no container mounts), and `readOnly: true` on an
  `emptyDir` or `ephemeral` volume is accepted when another container mounts it writable (it fails only when every
  container mounts it read-only).
- **Ports are pod-internal.** A sidecar's `ports` (`{name, containerPort}`, TCP; a definition of its own) are the
  targets of its own probes, not Service ports, metrics ports or NetworkPolicy targets; a port that must be reached
  from outside the pod is declared in the component's `ports` (the fronting-proxy recipe of the README). A port name
  and a port number are declared once in the pod: a sidecar's port that repeats the main container's or another
  sidecar's fails (two ports of the main container are not compared: the API checks one container's names).
- **Probes.** A sidecar's probes are a closed definition: exactly one of `exec`, `httpGet`, `tcpSocket` or `grpc`, no
  `host`, no `httpGet.protocol` or `grpc.mode` (alpha in Kubernetes 1.37), and the timing fields. A port name must be
  one of the sidecar's own `ports` (`chart-base.validateProbePorts`, called per sidecar). The main container's probes
  stay an open object, and its rule of [ADR-0047](0047-when-enabled-keys-required-externalsecret-source-probe-port-names.md)
  is unchanged; when an unresolved name is declared on another container, both messages say where.
- **Batch components.** A `job` or `cronjob` with a non-null sidecar requires `job.activeDeadlineSeconds`.
- **Restarts.** The Secrets and ConfigMaps of the entries' own `env` references join the Reloader annotations, on
  Deployments only, under `reloadOnChange`; `inheritEnv` adds nothing new.

## Consequences

- A proxy, a shipper, a migration or a check is one entry, checked at `helm template`, install and upgrade. The
  guards do not fail `helm lint` ([ADR-0044](0044-guards-fail-the-render-helm-lint-reports-them.md)).
- A volume without `mountPath` that no container mounts fails through a guard, no longer the schema: `helm template`,
  install and upgrade still fail on it, and `helm lint` of chart-base itself no longer does (exit 1 in 0.7.0, 0 now:
  measured with Helm 4.3.0 and 3.22.0).
- A consumer who relaxes the security context of every container on purpose repeats it per entry.
- A component relaxed for a root image (`podSecurityContext.runAsUser: 0`) that adds a sidecar without an override
  fails the render: the sidecar needs `runAsUser` or `runAsNonRoot: false`.
- The schema is looser by `null` and by the list form and `restartPolicy`, which only guards reject; schema-only
  tooling (an IDE) does not flag a bad container name.
- Until the 1.0 contract freeze the chart has two probe contracts: a probe moved from the main container to a sidecar
  can start failing the schema, and the main container keeps accepting `host` and misspelt fields.
- For five releases a sidecar's `env.<NAME>: null` is absent while the main container's is a schema error.
- With `inheritEnv`, an init container that needs the application's environment with one variable changed cannot use
  it: it lists its references, or the work moves to a `job` component.
- An inherited `resourceFieldRef` without `containerName` reads the entry's own resources (source reading).
- The fronting recipe declares on the main container a port that another container serves, and it is fail-open
  without `networkPolicy.enabled: true`: any pod can reach the application's port on the pod IP (a `containerPort` is
  informational).
- Not checked (documented): a sidecar whose `startupProbe` depends on the main container (the pod never starts), probe
  thresholds the API rejects, an image that does not exist, a `lifecycle` hook's `httpGet.port` given by a name (a
  `preStop` hook on an undeclared name fails with only a `FailedPreStopHook` event, kubelet source reading), a
  `subPath` FILE of an `emptyDir`, claim or ephemeral volume beneath a ConfigMap or Secret mount (it fails at
  container start; the chart cannot tell a file from a directory there), and, for the MAIN container, a `subPath` that
  names no item of a volume with `items` (checking it would reject values that render today).
- Additive later: a per-entry `automountToken: false`, an entry-level `config` for literal variables, `lifecycle` on
  an entry, a sidecar port exposed in the Service.

## Alternatives considered

### One list in the Kubernetes shape

An overlay replaces a list whole, so an environment could not change one container; it is also the shape the guards
reject with a remedy, because every upstream example uses it.

### One default order of 0 for both maps

Sequenced init containers (`order: 1`, `2`) would land behind every default sidecar, each reserving the sidecars'
requests on top of its own, and a sidecar whose `startupProbe` needs what they prepare would never start.

### Starting from the component's `securityContext`

A relaxation made for the main container (`readOnlyRootFilesystem: false` for a legacy image) would travel silently to
every sidecar ([ADR-0013](0013-secure-by-default.md): lowering the posture is explicit, per field).

### The main container's environment by default, or the entry's `env` winning over an inherited name

A log shipper would receive every application secret; a duplicate name is refused by Helm 4's server-side apply, and
relaxing the strict rule later is additive while tightening it would not be.

### An open probe object for sidecars

A misspelt field, a probe without a handler or with two, and `host` would reach the cluster: Helm 3.22 creates objects
without field validation and the API server drops an unknown field with a warning.

## References

- `templates/_containers.tpl` (`chart-base.containers`, `chart-base.hardenedSecurityContext`,
  `chart-base.entryContainer`, `chart-base.hasSidecars`), `templates/_pod.tpl` (`chart-base.env`,
  `chart-base.envFrom`), `templates/_values.tpl` (`chart-base.chartEnvNames`, `chart-base.validateProbePorts`),
  `templates/_volumes.tpl` (`chart-base.readOnlyMount`), `templates/validate.yaml`, `templates/_reloader.tpl`;
  `values.schema.json` (`definitions.initContainer`, `sidecar`, `probe`, `envVar`, `volumeMount`, `sidecarPort`).
- `tests/containers_test.yaml`, `tests/containers_guards_test.yaml`; `.github/scripts/alias-contract.sh`;
  `.github/scripts/e2e.sh` (the `deployment`, `job` and `full` scenarios and the `front` component of the
  NetworkPolicy umbrella).
- Kubernetes v1.33.12 and v1.37.0: `pkg/probe/util.go`, `pkg/kubelet/kuberuntime/kuberuntime_container.go`,
  `pkg/kubelet/kuberuntime/security_context_others.go`, `pkg/kubelet/lifecycle/handlers.go`,
  `pkg/kubelet/kubelet_pods.go`.
