# Upgrade guide

Before 1.0, a breaking release bumps the minor version and its pull request title carries `!`
(`feat!:` or `fix!:`). This page lists, for every breaking release, what to change in your values, and for a fix
release that changes rendered objects (0.4.1), which objects change. Releases that are not listed here need
no change to your values; the [changelog](../CHANGELOG.md) has every release.

## Every upgrade: a direct install must not use `--reuse-values`

A release that installs chart-base directly (not through an umbrella) and is upgraded with
`helm upgrade --reuse-values` fails validation when the new version adds required keys, as 0.3.0, 0.4.0, 0.5.0
and 0.6.0 do: Helm renders the new chart with the previous release's values, the old chart's defaults included,
instead of the new chart's defaults, so the new keys are missing. An upgrade to 0.3.0 fails with
`missing property 'enableServiceLinks'` and `'/cronjob': missing property 'suspend'`; an upgrade to 0.4.0
with an error that contains:

```text
missing properties 'metrics', 'prometheusRule'
```

an upgrade from 0.4.x to 0.5.0 with an error that contains:

```text
missing property 'networkPolicy'
```

and an upgrade from 0.5.x to 0.6.0 with an error that contains:

```text
missing property 'rbac'
```

The errors add up when versions are skipped: from 0.3.x straight to 0.5.0,
`missing properties 'metrics', 'prometheusRule', 'networkPolicy'`; from 0.2.x,
`missing properties 'enableServiceLinks', 'metrics', 'prometheusRule', 'networkPolicy'` and
`'/cronjob': missing property 'suspend'`. Straight to 0.6.0, `'rbac'` comes first: from 0.4.x,
`missing properties 'rbac', 'networkPolicy'`; from 0.3.x,
`missing properties 'rbac', 'metrics', 'prometheusRule', 'networkPolicy'`; from 0.2.x,
`missing properties 'rbac', 'enableServiceLinks', 'metrics', 'prometheusRule', 'networkPolicy'` and
`'/cronjob': missing property 'suspend'`.
Use `--reset-then-reuse-values` (available in Helm 3.22 and 4.3), which starts from the new chart's
defaults and applies your previous values on top, or pass your values files again. Umbrellas are not
affected.

## 0.1.x → 0.2.0

### `externalSecret.reloadOnChange` moved to `reloadOnChange`

The Reloader switch now covers everything that changes outside the deploy — the ExternalSecret's
Secret and every Secret or ConfigMap referenced in `env` or `envFrom` — so it moved from
`externalSecret` to the component ([ADR-0033](adr/0033-component-level-reload-on-change.md)).

| 0.1.x | 0.2.0 |
|---|---|
| `<alias>.externalSecret.reloadOnChange: false` | `<alias>.reloadOnChange: false` |

If you never set it, there is nothing to do: the default is still `true`. If you keep the old key,
validation fails before anything reaches the cluster, with an error that contains:

```text
additional properties 'reloadOnChange' not allowed
```

### New and optional: `env` and `envFrom`

Nothing to change. `env` takes references only (`valueFrom`: `fieldRef`, `resourceFieldRef`,
`secretKeyRef`, `configMapKeyRef`); literal values stay in `config`
([ADR-0030](adr/0030-env-takes-references-only.md)). `envFrom` injects existing ConfigMaps and
Secrets whole, before the component's own `config` and `externalSecret`
([ADR-0032](adr/0032-external-envfrom-first-env-wins.md)). An `env` key that also exists in `config`
or `externalSecret.data` fails validation.

## 0.2.x → 0.3.0

### `enableServiceLinks` defaults to `false`

Kubernetes injects `<SERVICE>_SERVICE_HOST`, `<SERVICE>_SERVICE_PORT` and Docker-links variables such as
`<SERVICE>_PORT=tcp://...` into every container, for every Service of the namespace. From 0.3.0 chart-base
turns that off on every Deployment, CronJob and Job
([ADR-0035](adr/0035-service-links-off-by-default.md)).

- **What changes.** The pod template gains `enableServiceLinks: false`, so the upgrade restarts every
  Deployment's pods once, through a normal rolling update; CronJob runs and Job hooks get the field at
  their next run. `KUBERNETES_SERVICE_HOST` and `KUBERNETES_SERVICE_PORT` are still injected, so in-cluster
  Kubernetes clients keep working.
- **Who is affected.** A component that reads the service-link variables of another Service, for example
  `VENDING_SALES_SERVICE_HOST`, or of its own Service. Use the Service's DNS name instead (`vending-sales`),
  or restore Kubernetes' behavior for that component:

| 0.2.x | 0.3.0 |
|---|---|
| nothing (Kubernetes' default, `true`) | `<alias>.enableServiceLinks: true` |

### `cronjob.suspend` is always rendered: set it before upgrading a CronJob suspended by hand

In 0.2.x the chart did not render `spec.suspend`, so a CronJob could only be suspended by hand
(`kubectl patch`). 0.3.0 renders `suspend: false` on every CronJob, and the upgrade can resume a CronJob
suspended that way: a client-side upgrade (Helm 3, or Helm 4 on a release installed client-side) computes
a three-way merge that writes the `false` over the live `true`; with Helm 4's server-side apply (its
default for the releases it installs) the same change can instead fail the upgrade with a field-manager
conflict. A resumed CronJob without `startingDeadlineSeconds` has its missed runs scheduled immediately.

If you do want the CronJob resumed, pass `--force-conflicts` to `helm upgrade` on Helm 4 (a server-side
apply flag: it forces the change through conflicts with other field managers).

**To keep a CronJob suspended, set `<alias>.cronjob.suspend: true` before upgrading.** Nothing changes for
a CronJob that was never suspended (`false` is Kubernetes' default), and from 0.3.0 on a suspension
belongs in the values, not only in the cluster.

### New and optional: rollout and pod runtime knobs, `lifecycle`

Nothing to change. `strategy`, `minReadySeconds` and `revisionHistoryLimit` (Deployments),
`cronjob.startingDeadlineSeconds`, `priorityClassName`, `runtimeClassName`, `dnsConfig` and `hostAliases`
render nothing until you set them, so Kubernetes' defaults apply
([ADR-0036](adr/0036-rollout-and-runtime-knobs-are-validated-pass-throughs.md)). `lifecycle` adds
`postStart` and `preStop` hooks; on a Deployment, `lifecycle.preStop` needs `preStopSleepSeconds: 0`
([ADR-0037](adr/0037-one-prestop-hook.md)), or validation fails with an error that contains:

```text
lifecycle.preStop replaces the built-in preStop sleep: set preStopSleepSeconds: 0
```

## 0.4.x → 0.4.1

No value needs to change, unless one of the cases in the second bullet below applies to you (check them
first: they make `helm upgrade` fail). 0.4.1 quotes every string it renders from values: the port names,
`ingress.className`, the Ingress paths, `externalSecret.secretStoreRef.name` and the keys of
`externalSecret.data`, `config` and `configFiles.files`, so that Kubernetes receives them as written. An
object changes only where 0.4.0 rendered such a value wrongly:

- A port name, an Ingress class, a secret store name or an `externalSecret.data` key that YAML 1.1 reads
  as a boolean (`on`, `off`, `yes`, `no`, `y`, `n`, `true`, `false`, also capitalized or in capitals) made
  the object invalid, so the release could not be installed; 0.4.1 installs it. A store name or an
  `externalSecret.data` key that YAML reads as null (`null`, `Null`, `NULL`) was rendered as a null, not as
  a name or a key; 0.4.1 sends the string.
- **Values 0.4.0 trimmed or dropped now fail `helm upgrade`.** 0.4.0 rendered them as another value, which
  Kubernetes accepted; 0.4.1 sends them as written, which Kubernetes rejects. Fix the values before you
  upgrade:
  - An Ingress path `null`, `~`, `Null` or `NULL` (with `pathType: ImplementationSpecific`) was dropped,
    which Kubernetes accepts as no path; 0.4.1 sends the string, and a non-empty path must start with `/`.
    Set the path to `""` or remove it.
  - An Ingress path with a leading space (`" /api"`) was sent as `/api`; 0.4.1 sends `" /api"`, which is
    not an absolute path. Remove the space.
  - `ingress.className` with leading or trailing whitespace or a ` #` comment (`" nginx"`, `"nginx "`,
    `"nginx #x"`) was sent as `nginx`; 0.4.1 sends it as written, which is not a DNS-1123 subdomain.
    Remove the whitespace or the comment.
  - `ingress.className` `NULL`, `Null` or `~` was dropped, so the Ingress had no class; 0.4.1 sends it as
    written, which is not a DNS-1123 subdomain. `null` is a valid name, so the upgrade succeeds, but the
    Ingress now names a class `null`, which no controller serves unless such a class exists. Measured on Helm
    3.22.0 and 4.3.0 (corrected in 0.7.0): `ingress.className: null` renders an Ingress whose `ingressClassName` is
    empty (null) when the `null` comes from an override file, from `--set`, or from the umbrella's own values on
    Helm 3.22; on Helm 4.3 a `null` in the umbrella's own values is ignored while nothing is passed for the
    component, and the chart's default `""` then fails the schema (`minLength: got 0, want 1`). Removing the key does
    not give an Ingress without a class: the chart's default `""` applies and an enabled Ingress fails the schema the
    same way. Whether an Ingress without a class is supported is an open decision ([roadmap](roadmap.md#open-decisions)).
  - `externalSecret.secretStoreRef.name` with surrounding whitespace or a ` #` comment (`"vault "`) was sent
    as `vault`; 0.4.1 sends it as written, which ESO rejects or cannot find as a store, and the Secret
    stops syncing. Remove the whitespace or the comment.
- A `config` or `configFiles.files` key that YAML 1.1 reads as a boolean or a number was renamed in the
  ConfigMap: `ON` became `true` (and `ON` with `Y` became a single key `true` that kept one of the
  values), and a file key `010`, `007`, `1.0`, `1e3`, `0x10`, `.5` or `1_000` became `8`, `7`, `1`,
  `1000`, `16`, `0.5` or `1000`. 0.4.1 keeps the key as written, so that ConfigMap changes once: a
  Deployment rolls (its `checksum/config-*` annotation changes), and CronJob and Job pods get the new keys
  at their next run. A key that YAML reads as null (`null`, `NULL`) failed the render and now renders.
- An Ingress path that contains ` #` or ends with a space was cut there (`/a #b` and `/a ` were sent as
  `/a`). 0.4.1 sends the path the values say, **which can change the routing of an existing Ingress on
  upgrade**: check such paths before you upgrade. A path that contains `: ` failed the render and now
  renders. An empty path is sent as `""` instead of null, and Kubernetes stores both as no path.

## 0.4.x → 0.5.0

Nothing to change, and the same values render the same objects: 0.5.0 adds `networkPolicy`, off by default
([ADR-0040](adr/0040-networkpolicy-per-component-with-sibling-references.md)). A direct install upgraded with
`--reuse-values` fails (see above). Before you turn it on for a component:

- The cluster's CNI must enforce NetworkPolicy (on EKS, network policy must be enabled in the VPC CNI): otherwise the
  object is created and changes nothing.
- Ingress becomes isolated: list every source. A component with `httpRoute` or `ingress` needs, in
  `networkPolicy.ingress.fromNamespaces`, the namespace of the Gateway's proxy pods (with Envoy Gateway's default
  mode, the namespace Envoy Gateway runs in, not the Gateway's) or of the ingress controller's pods, and one with
  `metrics` needs Prometheus' namespace in `networkPolicy.ingress.metricsFromNamespaces`; the render fails without
  them. A route that a policy the chart cannot express allows (Cilium's Ingress or Gateway) takes
  `networkPolicy.ingress.routeTrafficAllowedElsewhere: true` instead. Traffic from the pod's own node, such as the
  kubelet's probes, stays allowed.
- `networkPolicy.egress.enabled` isolates egress too: list the cluster DNS (the default fits kubeadm (kind), EKS, GKE
  with kube-dns, AKS and k3s; OpenShift and NodeLocal DNSCache need an override, every `dns.ports` entry needs its
  protocol, and a `dns.podSelector` you set replaces the default selector), the siblings, and every destination
  outside the cluster, including the API server (its endpoint IPs and port) for a component with
  `serviceAccount.automountToken: true`. Destinations listed while `egress.enabled` is `false` fail the render.
- On a `job` component the policy is a hook of the Job's phase: keep `job.activeDeadlineSeconds` below Helm's
  `--timeout` ([ADR-0041](adr/0041-job-component-networkpolicy-is-a-hook.md)).

## 0.5.x → 0.6.0

0.6.0 adds `serviceAccount.name` and `rbac` ([ADR-0042](adr/0042-existing-serviceaccount-and-namespaced-rbac.md)),
unused by default, and is a breaking release for one combination of values: otherwise the same values render the
same objects. A direct install upgraded with `--reuse-values` fails (see above).

### `serviceAccount.annotations` with `serviceAccount.create: false` fail the render

0.5.0 ignored those annotations: with `create: false` the chart creates no ServiceAccount to put them on. 0.6.0 fails
with an error that contains:

```text
serviceAccount.annotations apply only to the ServiceAccount the chart creates
```

Remove them from the values of that component. An override file that turns `create` off clears inherited annotations
with `serviceAccount.annotations: null`; `{}` does not and the render still fails, because Helm merges maps.

- **Without `serviceAccount.name`** (the 0.5.x case): the pods run as the namespace's `default` ServiceAccount, which
  never carried the annotations. With them removed, 0.6.0 renders the same objects as 0.5.0 did with them. If the
  pods need the annotations (a cloud identity), set `create: true` instead, so that the chart creates `<fullname>`
  with them; the pods then run as that ServiceAccount and roll once.
- **With `serviceAccount.name`** (new in 0.6.0): the pods run as that existing ServiceAccount; its owner sets the
  annotations on it, not the chart. Or remove `name` and set `create: true`, as the error says: the chart then
  creates `<fullname>` with the annotations, and the pods move to it (`create: true` with `name` still set fails).

### Keeping the chart's ServiceAccount under its name

Moving a component to an existing ServiceAccount with another name rolls its pods (the pod template changes), and Helm
deletes the chart's ServiceAccount once the new objects are applied: with `automountToken: true`, pods of the old
revision that still run lose API access about 10 seconds later (their token belongs to the deleted ServiceAccount).

To keep the chart's own ServiceAccount, `<fullname>`, and hand it over to its owner (for example because a cloud
identity's trust policy names the namespace and the ServiceAccount), deploy a `deployment` or `cronjob` component
twice:

1. With `create: true`, add `helm.sh/resource-policy: keep` to `serviceAccount.annotations`, and deploy.
2. Set `create: false` and `name: <fullname>`, remove the annotations from the values (`null` in an override file),
   and deploy. Helm keeps the ServiceAccount, and the annotation stays on it: from now on its owner manages it.

In one step instead, the upgrade succeeds and Helm deletes the ServiceAccount, while the pods do not roll (their
template names the same ServiceAccount): the running pods keep a token of the deleted ServiceAccount, which the API
server rejects after its token cache, and every new pod is rejected because the ServiceAccount does not exist.

A `job` component's ServiceAccount is a hook of the Job's phase (`before-hook-creation,hook-succeeded`), and Helm
deletes a hook whatever `helm.sh/resource-policy` says: measured with Helm 4.3.0 and 3.22.0 on kube-apiserver v1.33.0
and v1.37.0, a hook ServiceAccount annotated `keep` is gone once the phase has succeeded. The two steps above keep
nothing, and the second deploy's Job pods would name a ServiceAccount that no longer exists, which the API server
rejects (this follows from the deletion; not run). There is nothing to hand over, so it is one step: after a
successful deploy, check that the hook ServiceAccount is gone
(`kubectl get serviceaccount <fullname> -n <namespace> --ignore-not-found` prints nothing), have its owner create
`<fullname>`, then deploy with `create: false` and `name: <fullname>` (the annotations removed, as above). Do not
create it while the chart still renders the hook ServiceAccount (`create: true`): the next deploy's
`before-hook-creation` deletes it by name (Helm's `pkg/action/hooks.go`, a source reading, not run).

### New and optional: an existing ServiceAccount and RBAC

- `serviceAccount.name` runs the pods as an existing ServiceAccount (with `create: false`). It must exist before the
  pods, and its `imagePullSecrets` and its deprecated `kubernetes.io/enforce-mountable-secrets` annotation apply to
  them.
- `serviceAccount.name` with `create: true` fails the render (the chart's own ServiceAccount is always `<fullname>`);
  `helm lint` reports it without failing.
- `rbac` needs a ServiceAccount of the component (the render fails for the namespace's `default` one) and
  `serviceAccount.automountToken: true`, unless no ClusterRole is bound and `use` is the only verb of every rule (a
  grant that admission checks on the ServiceAccount, such as an OpenShift SecurityContextConstraints). Render with
  the release's real `--namespace`: the RoleBindings' subject is in it. **Whoever runs `helm upgrade` must hold every
  permission it grants**: check the deployer's own permissions first (`kubectl auth can-i --list`). With
  `networkPolicy.egress.enabled`, a component that calls the API also needs the API server's endpoint IPs and port in
  `networkPolicy.egress.toCIDRs`.
- On a `job` component the Role and RoleBindings are hooks of the Job's phase: keep `job.activeDeadlineSeconds` below
  Helm's `--timeout` ([ADR-0043](adr/0043-job-component-rbac-is-a-hook.md)).

## 0.6.x → 0.7.0

0.7.0 is a breaking release. Its first pull request fixes values that Helm let through where chart-base assumed a
value, and values that rendered objects that do not work; it changes the content of a working ConfigMap without a
render error in one case, listed first. Render every environment with 0.7.0 and exactly the `-f`/`--set` values its
deploy uses before you upgrade.

**What changes for values that rendered a working object** (no render error):

- **A map-form config file loses every key whose value is null or empty (`key:`), in maps reached without crossing a
  list, from ANY values layer** (the umbrella's own values, `-f`, `--set`, a direct install's values file;
  [ADR-0045](adr/0045-null-in-configfiles-and-resources-is-absent.md)). 0.6.0 rendered `key: null`. The ConfigMap changes once: a Deployment rolls
  through its checksum annotation; CronJob and Job pods read the new file at their next run. **Who is affected:** a
  format where an empty value carries meaning. An OpenTelemetry Collector section enabled by a bare key (`grpc:`)
  fails its configuration validation (`must specify at least one protocol`, measured with `otelcol validate` of
  OpenTelemetry Collector 0.162.0; the crash-loop that would follow was not run); a Spring property blanked with a
  bare key falls back to the jar's packaged value, silently. **The check:** render every environment with 0.6.0 and
  exactly the `-f`/`--set`
  values its deploy uses, and search the `<fullname>-files` ConfigMaps for `null`, or diff them against 0.7.0; a bare
  `helm template <umbrella>` on Helm 4.3 shows no difference, because Helm already dropped the key there. **The
  remedies:** `key: {}` for a section with its defaults; `key: ""` (for Spring, the same meaning as the `null`); the
  string form of the file for a literal `null`; a `null` inside a list stays as written. Whether `{}` or `""` is
  equivalent to the `null` depends on the application (checked for OpenTelemetry Collector 0.162.0 and Spring Boot
  3.5.6 only). A `null` file (also a bare `name:`) is now no file instead of a schema error.
- **A `null` resource quantity is absent.** A `null` entry of `resources.limits`, or of `resources.requests`
  other than the required `cpu` and `memory`, and `resources.limits: null` (a schema error in 0.6.0), render no such
  limit or request (ADR-0045; a `null` `requests.cpu` or `requests.memory` stays a schema error). 0.6.0 rendered `<k>: null`, which the API
  server stores as `"0"`: an install with a request for the same resource was rejected (`limit of 0`), and a limit
  without a request became a zero limit (measured on kube-apiserver 1.33.0 and 1.37.0). A `null` limit stored as a zero
  limit (on install with either Helm version, on upgrade with Helm 4.3) is no longer rendered (what the upgrade then
  stores was not measured); Helm 3.22 already removed it on upgrade.
- **`configFiles.mountPath` is sent as written** ([ADR-0046](adr/0046-configfiles-mountpath-compared-normalized-rendered-as-written.md)): a path with trailing whitespace
  or a ` #` comment was cut there by 0.6.0 and is now another directory (the mount moves; remove them); a path that
  contains `: ` failed the render and now renders. `mountPath: /config` is now rendered `"/config"`, the same object.

**What now fails at render** (`helm template`, install and upgrade. `helm lint` of chart-base itself also fails on the
schema rules among them, the `required` keys and the closed route entries; through an umbrella, a `null` from `-f` or
`--set` that deletes a required key passes lint ([ADR-0044](adr/0044-guards-fail-the-render-helm-lint-reports-them.md)),
Helm 4.3 lints no subchart schema when the umbrella has no `templates/`, and no guard fails lint: gate on `helm template`
with the deploy's real values): fix the values before you upgrade.

- A `configFiles.mountPath` that is `/tmp` or `/` once normalized (`//tmp`, `/tmp/.`, `/./tmp`, `/a/../tmp`, `/..`),
  or the ServiceAccount token directory `/var/run/secrets/kubernetes.io/serviceaccount` (also `//var/...` or with a
  trailing `/`) while `serviceAccount.automountToken` is true: `configFiles.mountPath must not be /tmp (an emptyDir is
  mounted there): "//tmp" is /tmp once normalized; choose another directory, such as the default /config`, and the
  same for `/` and the token directory. Choose another directory (for the token directory, or set
  `serviceAccount.automountToken: false`). A parent of the token directory (`/var/run/secrets`) is not checked;
  whether such a pod starts is not measured.
- `externalSecret.enabled: true` with `externalSecret.data` null, empty or absent, including a Helm 3.22 release with
  `data: null` that deployed: `externalSecret.enabled is true and externalSecret.data has no entry: list at least one
  key in externalSecret.data, or set externalSecret.enabled: false (an override file cannot remove single keys that
  another values file defines, and data: {} removes nothing: maps are merged)`
  ([ADR-0047](adr/0047-when-enabled-keys-required-externalsecret-source-probe-port-names.md)). The schema no longer checks this, so schema-only tools (an IDE, `helm lint`)
  do not flag it.
- A `null` for `cronjob.schedule` (on a cronjob), for `externalSecret.secretStoreRef.kind` or `.name`, for
  `httpRoute.parentRefs` or for `ingress.hosts` while their block is enabled: `missing property '<key>'`. 0.6.0
  rendered `null` (what the API server then did was not measured). Write the value. **`secretStoreRef.kind: null`**
  in particular may have fallen back to ESO's default `SecretStore` on Helm 3.22 (unverified) and now fails: write
  the kind, `ClusterSecretStore` or `SecretStore`.
- **A main-container probe whose `httpGet.port` or `tcpSocket.port` is a name that no `ports` entry declares, or
  whose `httpGet` or `tcpSocket` is not a map. This one can make `helm upgrade` fail for a release that runs
  today**: a Deployment whose only wrong name is in the liveness probe, and a `job` or `cronjob` with any such probe.
  The kubelet cannot resolve such a name and never runs the probe (kubelet source at v1.33.12 and v1.37.0; not
  verified at runtime). `probes.liveness.httpGet.port "htpp" is not the name of an entry in ports: the kubelet cannot
  resolve it and never runs the probe. Use the port number, or declare the name in ports (a ports entry also becomes a
  Service port when a Service is rendered, and is opened by networkPolicy.ingress.fromComponents/fromNamespaces), or
  remove the probe`. After the fix a liveness probe runs for the first time: check its path and thresholds before you
  roll out. In an umbrella, one such component blocks the render of the whole release.
- **An unknown or misspelt key, or a `null` value, in an entry of `httpRoute.parentRefs` or `httpRoute.matches`**, at any level
  ([ADR-0048](adr/0048-httproute-parentrefs-and-matches-are-closed.md)): `additional properties 'sectioName' not allowed`, with the path of the key.
  0.6.0 rendered it; on Helm 3.22, and on Helm 4.3 for a release first installed by Helm 3, the API server dropped
  the field, which widened the route (`pathh: /api` matched every request; `sectioName: https` attached the route to
  every listener). Fix the key's spelling; the entries take exactly the fields of the Gateway API v1.6.2 Standard CRD.
  A `null` field in such an entry (`sectionName: null`) now fails the schema too: on 0.6.0 it rendered, and on Helm 3.22
  the API server dropped the `null` (the route was the same without it), while Helm 4.3's server-side apply rejected it
  (measured on kube-apiserver 1.33.0 and 1.37.0). Remove the key.

### Extra volumes and `strategy.rollingUpdate: null` (the second pull request of 0.7.0)

The second pull request of 0.7.0 adds `volumes` and adds no required key: a values file without `volumes` renders
the same manifests as with its first pull request (measured on the six `ci/` scenarios, on Helm 4.3.0 and 3.22.0).

- **`volumes` is new and optional** ([ADR-0049](adr/0049-volumes-are-a-map-of-typed-entries-mounted-in-the-main-container.md)). In `volumes`, a `null`
  entry or field is absent. A volume added to the rendered Deployment some other way (a post-renderer, a patch) can
  move to `volumes`, whose guards then check it at `helm template`.
- **`strategy.rollingUpdate: null` is accepted and never rendered** ([ADR-0050](adr/0050-existing-claim-on-a-deployment-and-strategy-rollingupdate-null.md)):
  an override file over values that set `rollingUpdate` switches to Recreate with `strategy: {type: Recreate,
  rollingUpdate: null}`. 0.6.0 rejected that `null` (`got null, want object`).
- **`helm lint` no longer fails on `rollingUpdate` next to `Recreate`**: the rule moved from the schema to a guard,
  which fails `helm template`, install and upgrade with a remedy (measured on chart-base itself: `helm lint --strict`
  exited 1 before, 0 now). Gate on `helm template` with the deploy's real values.
- **On Helm 4, for a release that Helm 4 installed, a Deployment that exists without `strategy` cannot switch to
  `{type: Recreate}` in one upgrade.** Helm 4 applies server-side, the `rollingUpdate` that the API server defaulted
  stays, and the API rejects it: `` spec.strategy.rollingUpdate: Forbidden: may not be specified when strategy `type`
  is 'Recreate' `` (measured on kube-apiserver 1.33.0 and 1.37.0; Helm 3.22.0 switches in place). The same holds for a
  Deployment created with `{type: RollingUpdate}` only, by the same mechanism (Helm then owns only `type`; measured on
  kube-apiserver 1.33.0 and 1.37.0: Helm 4.3.0 is refused, Helm 3.22.0 switches in place).
  `--server-side auto` keeps a release that Helm 3 installed on client-side apply, which switches in place (source
  reading). The routes, each measured there: stay on `{type: RollingUpdate, rollingUpdate: {maxSurge: 0, maxUnavailable: 1}}`; switch to
  Recreate in a later upgrade, once Helm owns both `rollingUpdate` keys; or run that one upgrade with
  `--server-side=false`. It matters first for a Deployment that gains an existing claim declared `ReadWriteOnce`,
  which needs a strategy that adds no pod.
