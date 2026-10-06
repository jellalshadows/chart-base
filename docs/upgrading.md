# Upgrade guide

Before 1.0, a breaking release bumps the minor version and its pull request title carries `!`
(`feat!:`). This page lists, for every breaking release, what to change in your values, and for a fix
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
    Ingress now names a class `null`, which no controller serves unless such a class exists. For all of
    them, remove the key if you want no class.
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
