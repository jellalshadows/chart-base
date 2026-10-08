# Consuming chart-base from a domain umbrella

This guide is for platform teams that write an umbrella chart for a business domain and deploy it.
The [README](../../README.md) has the quick start, the recipes and the values table; this guide
explains the model behind them, the reason for each rule, and what to expect when something is wrong.

Contents:

- [The model](#the-model)
- [The umbrella `Chart.yaml`](#the-umbrella-chartyaml)
- [Values: nested under the alias](#values-nested-under-the-alias)
- [What a null does in each values layer](#what-a-null-does-in-each-values-layer)
- [Rules](#rules)
- [Failure behavior](#failure-behavior)
- [Recommendations for umbrella authors](#recommendations-for-umbrella-authors)
- [Upgrading chart-base](#upgrading-chart-base)
- [Verifying what you deploy](#verifying-what-you-deploy)

## The model

- **One umbrella chart per business domain** (for example `vending`).
- **One `chart-base` dependency per component**, each with a different `alias` (`sales`, `machines`,
  `front-web`). One alias renders **one workload**: a Deployment, a CronJob or a Job, plus the
  objects that belong to it (Service, ConfigMaps, ExternalSecret, and so on). A worker is a
  Deployment with `service.enabled: false`.
- **One Helm release per domain.** The umbrella is installed once, so every component of the domain
  is upgraded and rolled back together. This is the accepted trade-off of the model: a broken
  component can fail the deploy of the whole domain. chart-base reduces the risk by failing at
  render time on invalid values, before anything reaches the cluster (see
  [Failure behavior](#failure-behavior)).
- chart-base is an **application chart**, not a library chart, so that Helm validates every alias's
  values against chart-base's `values.schema.json`
  ([ADR-0001](../adr/0001-application-chart-consumed-through-aliases.md)).

Every object is named `<release>-<alias>` (`vending-sales`); the ConfigMaps and the Secret add a
suffix (`-env`, `-files`, `-secrets`)
([ADR-0008](../adr/0008-names-are-release-alias-and-never-truncated.md)). There are no
`nameOverride` or `fullnameOverride` keys: the alias is the identity
([ADR-0009](../adr/0009-no-name-overrides.md)).

## The umbrella `Chart.yaml`

This is the quick start's file, one dependency per component. `<chart-base version>` is a placeholder:
the current version is in the [README quick start](../../README.md#quick-start) and in the
[CHANGELOG](../../CHANGELOG.md).

```yaml
# vending/Chart.yaml
apiVersion: v2
name: vending
version: 0.1.0
dependencies:
  - name: chart-base
    version: <chart-base version>
    repository: oci://ghcr.io/jellalshadows/charts
    alias: sales
    condition: sales.enabled
  - name: chart-base
    version: <chart-base version>
    repository: oci://ghcr.io/jellalshadows/charts
    alias: machines
    condition: machines.enabled
```

| Line | Meaning |
|---|---|
| `apiVersion: v2`, `name`, `version` | An ordinary Helm 3/4 chart. The umbrella has its own version, independent of chart-base's. |
| `name: chart-base` | The chart to pull. The same name is repeated once per component. |
| `version: <chart-base version>` | An exact chart-base version. It must be **identical in every entry** (see [Rules](#rules)). |
| `repository: oci://ghcr.io/jellalshadows/charts` | The OCI registry that holds the chart, public on GHCR ([ADR-0003](../adr/0003-oci-on-ghcr.md)). It must be the same URL in every entry. With OCI there is no `helm repo add`. |
| `alias: sales` | The name of the component. Helm renames the subchart to the alias, so the alias becomes the key for the component's values and the `<alias>` part of every object name. |
| `condition: sales.enabled` | Helm reads this path in the umbrella's values and drops the whole component when it is `false`. |

```bash
helm dependency update vending/     # downloads chart-base into vending/charts/ and writes Chart.lock
helm template vending vending/      # renders vending-sales, vending-machines, ...
```

chart-base requires Kubernetes 1.33 or later. Its `kubeVersion` is `>=1.33.0-0`, and a guard in the
templates repeats the check because Helm does not check a subchart's `kubeVersion`
([ADR-0018](../adr/0018-kubernetes-version-floor.md)).

## Values: nested under the alias

All configuration of a component lives under its alias, in one values file for the whole umbrella
(the recipes in the [README](../../README.md#recipes) show complete examples):

```yaml
# vending/values.yaml
sales:
  enabled: true
  image: {repository: ghcr.io/acme/sales, tag: "1.4.2"}
  resources:
    requests: {cpu: 250m, memory: 512Mi}
machines:
  enabled: false
```

- **`global` is reserved for toggling.** Helm injects `global` into every alias. chart-base accepts
  the key and never reads it, so nothing in a component's behavior may depend on it. Use `global`
  in the umbrella only to switch components on and off.
- **`enabled` is reserved for `condition: <alias>.enabled`.** chart-base accepts it and ignores it.
- **Every other key is checked.** The schema is strict: an unknown key under an alias is an error, not
  an ignored value ([ADR-0011](../adr/0011-strict-draft-07-schema.md)). Required keys such as
  `image.repository`, an image tag or digest, and `resources.requests` must be present
  ([ADR-0014](../adr/0014-resource-requests-required.md)).
- **A `null` does not always delete a key**: what it does depends on the values layer and on the map
  ([next section](#what-a-null-does-in-each-values-layer)). chart-base's schema marks as `required` the keys whose
  deletion would silently change a default, so such a `null` fails instead of flipping the default
  ([ADR-0027](../adr/0027-required-keys-in-the-schema.md)).

## What a null does in each values layer

Helm deletes a key on `null` only when the chart's own `values.yaml` defines it, and Helm 4.3 drops a `null` written in
the umbrella's own values while nothing is passed for that component. Measured on Helm 3.22.0 and 4.3.0; each row is
pinned by one check of the alias contract, on both Helm versions
([testing guide](testing.md#the-alias-contract)):

| The `null` is written on | From `-f`/`--set`; from the umbrella's own values on Helm 3.22; from the umbrella's own values on Helm 4.3 when a `-f`/`--set` value names that alias | From the umbrella's own values on Helm 4.3 when nothing is passed for that alias |
|---|---|---|
| a chart default the schema requires ([ADR-0027](../adr/0027-required-keys-in-the-schema.md): `serviceAccount.automountToken`, `job.ttlSecondsAfterFinished`, `podSecurityContext`) | Helm removes it; the render fails (`missing property`) | ignored: the default stays (nothing fails when the default is valid; `resources` and `image.repository` then fail the schema like the next row) |
| a key that an enabled block needs ([ADR-0047](../adr/0047-when-enabled-keys-required-externalsecret-source-probe-port-names.md): `cronjob.schedule`, `externalSecret.secretStoreRef.kind` and `.name`, `httpRoute.parentRefs`, `ingress.hosts`) | Helm removes it; the render fails (`missing property`) | ignored: the default (`""`, `[]`) stays and fails the schema (`minLength: got 0, want 1`, `minItems`); for `secretStoreRef.kind` the default `ClusterSecretStore` stays and renders |
| any other chart default (`podSecurityContext.runAsUser`, `securityContext.readOnlyRootFilesystem`, `ingress.className`) | the default is gone | ignored: the default stays |
| a whole map that the chart's `values.yaml` defines (`config`, `env`, `podLabels`, `podAnnotations`, `nodeSelector`, `configFiles.files`, `volumes`) | cleared | same result |
| a whole map that the chart's `values.yaml` does not define (`resources.requests`) | schema error `got null, want object` | Helm drops it, and the required `requests` is then missing (`missing property 'requests'`) |
| one entry of a typed map (`config.<KEY>`, `env.<NAME>`, `externalSecret.data.<KEY>`, labels, annotations, `nodeSelector.<key>`), or an optional member of a closed object (`lifecycle.postStart`, `strategy.rollingUpdate.maxSurge`, `dnsConfig.options`) | schema error `got null, want …` | Helm drops the entry (an ExternalSecret left without a `data` entry then fails the source guard) |
| a key inside a pass-through object (`affinity.<key>`, a key of a probe) | rendered as `null` in the manifest | dropped |
| a file of `configFiles.files` or a key of a map-form file (maps reached through maps); an entry of `resources.limits`, an entry of `resources.requests` other than `cpu` and `memory`, or `resources.limits` itself; an entry of `volumes` or a field of an entry; `strategy.rollingUpdate` | removed by chart-base ([ADR-0045](../adr/0045-null-in-configfiles-and-resources-is-absent.md), [ADR-0049](../adr/0049-volumes-are-a-map-of-typed-entries-mounted-in-the-main-container.md), [ADR-0050](../adr/0050-existing-claim-on-a-deployment-and-strategy-rollingupdate-null.md)) | removed |

`externalSecret.data: null` with `externalSecret.enabled: true` is cleared and then fails the source guard
([ADR-0047](../adr/0047-when-enabled-keys-required-externalsecret-source-probe-port-names.md)). In `configFiles.files`, a `null` file is no file, and in a map-form
file a key whose value is `null` or empty (`key:`) is removed; a list inside it is rendered as written. In `volumes`, a
`null` entry or field is absent: an entry can also be removed with `null` and re-added under another name, and an
overlay changes a volume's type by setting the previous type's fields to `null`
([ADR-0049](../adr/0049-volumes-are-a-map-of-typed-entries-mounted-in-the-main-container.md)). These are rules of these maps, not of every map.

An overlay can add entries to a map, and can clear with `null` a whole map that the chart's `values.yaml` defines; it
cannot remove one entry, except where this guide says so per map (in 0.7.0: a file of `configFiles.files`, a key of a
map-form file, an entry of `resources.limits` or `resources.requests`, other than `requests.cpu` and `requests.memory`, which stay required, and an entry of `volumes` or one of its fields): keep the entries that differ per
environment in the overlays. On Helm 4, lint and template an umbrella with the same `-f`/`--set` values the deploy
uses: a `null` in the umbrella's own values is ignored until a value is passed for that component.

## Rules

The same list appears in the README under
[Rules for consumers](../../README.md#rules-for-consumers). Here each one has its reason.

**One `chart-base` version and one repository URL for every alias of an umbrella.**
Helm's named templates (`define`) are global across an umbrella's subcharts. With two versions of
the same chart in one umbrella, their template definitions collide and one version ends up rendering
every alias; and `helm package` drops one of the versions. Pin the same `version:` and the same
`repository:` in every entry
([ADR-0001](../adr/0001-application-chart-consumed-through-aliases.md)).

**Aliases are lowercase kebab-case, and `<release>-<alias>` must fit in 63 characters (52 for
CronJobs).**
Object names must be valid DNS-1035 labels, which forbids uppercase. A CronJob's controller appends an
11-character timestamp to its name for every Job it creates, which is why the CronJob limit is lower. chart-base fails the render for a
name that is invalid or too long and never truncates it, because two truncated names can collide.
Renaming an alias renames every object of the component, so Helm deletes the old objects and creates
new ones ([ADR-0008](../adr/0008-names-are-release-alias-and-never-truncated.md)).

**Toggle components with a real boolean: `sales.enabled: false`.**
Helm only honors a boolean at the `condition` path. With a string such as `"false"`, Helm prints a
warning ("returned non-bool value") and does not apply the condition, so the component stays in the
release; chart-base's schema, which declares `enabled` as a boolean, then rejects the value at
render time (checked with Helm 3.19). Write `false`, not `"false"`, and be careful with tooling that
turns every value into a string
([ADR-0011](../adr/0011-strict-draft-07-schema.md)).

**Quote image tags: `tag: "1.10"`.**
YAML reads an unquoted `1.10` as the number 1.1. The schema only accepts a string for `image.tag`, so an
unquoted tag fails at render time ("got number, want string") instead of deploying `1.1`.

**Turning on autoscaling for a running component scales it to 1 once.**
With `autoscaling.enabled: true` the Deployment no longer sets `spec.replicas`, so that the HPA and
Helm do not fight over it. On an existing release, Kubernetes treats the removed field as the default
of 1 replica, and then the HPA scales the Deployment back up. Expect a single dip when you enable it on a
component that is already serving traffic.

**Install [Stakater Reloader](https://github.com/stakater/Reloader) with
`reloadStrategy: annotations`.**
Config changes roll the pods through a checksum annotation, inside the deploy. Secret rotation cannot
work that way: the chart never sees the content of the Secret that External Secrets Operator syncs, nor
of a Secret or ConfigMap that an operator or another team maintains. With `reloadOnChange: true` (the
default) chart-base adds Reloader annotations to the Deployment that list the ExternalSecret's Secret
(when `externalSecret.enabled`) and every Secret and ConfigMap referenced in `env` or `envFrom`, so
Secret rotation **and** changes to referenced Secrets and ConfigMaps reach the pods. Without Reloader
running in the cluster the annotations do nothing. Reloader's `annotations` strategy is the one that
avoids drift between the cluster and what GitOps tools render
([ADR-0006](../adr/0006-checksum-for-config-reloader-for-secrets.md),
[ADR-0033](../adr/0033-component-level-reload-on-change.md)). The setting belongs to Reloader's own
installation, not to chart-base.

**A Gateway whose listener allows routes from the application namespace.**
An HTTPRoute is accepted only if the listener it attaches to allows it. By default a Gateway
listener only accepts routes from the Gateway's own namespace, so configure `allowedRoutes` on the
listener that the route's `parentRefs` point to
([ADR-0016](../adr/0016-httproute-first-ingress-optional.md)).

**Label the monitors and rules for your Prometheus.**
`metrics` and `prometheusRule` render Prometheus Operator objects, and Prometheus selects them by label.
With its default values, kube-prometheus-stack (checked on chart version 91.8.2) selects only the
ServiceMonitors, PodMonitors and PrometheusRules labelled `release: <its release name>`: an object without
the label is created and silently ignored, and nothing fails. Set `metrics.labels.release` and
`prometheusRule.labels.release` to that name, or configure kube-prometheus-stack to select every object (the
[README recipe](../../README.md#prometheus-monitoring-kube-prometheus-stack) names the keys;
[ADR-0038](../adr/0038-one-metrics-endpoint-servicemonitor-or-podmonitor.md),
[ADR-0039](../adr/0039-prometheus-rules-travel-with-the-component.md)).

**NetworkPolicy: a CNI that enforces it, and the namespaces of your Gateway's proxies and of Prometheus.**
`networkPolicy` renders a standard NetworkPolicy, and only the CNI enforces it: on one that does not, the object is
created and nothing is restricted (on EKS, network policy must be enabled in the VPC CNI). The policy allows sources
by namespace name, so list in `fromNamespaces` the namespace of the Gateway's proxy pods (with Envoy Gateway's default
mode, the namespace Envoy Gateway runs in, not the Gateway's) or of the ingress controller's pods, and Prometheus' in
`metricsFromNamespaces`. The traffic of Cilium's Ingress or Gateway matches no namespace and `extra` cannot allow it (a
standard NetworkPolicy cannot select its `reserved:ingress` identity; a Cilium maintainer said so on 2024-12-11, for
Cilium 1.16, current releases unverified): allow it with a CiliumNetworkPolicy and set
`networkPolicy.ingress.routeTrafficAllowedElsewhere: true`, which opens nothing and only tells the route guard that
the traffic is allowed elsewhere (it fails without a route). A controller on the host network (usually treated as node
traffic) is the same case; an `ipBlock` of the node CIDRs in `extra` may allow it. The metrics guard needs
a namespace even for a scraper that is not a pod in one (an agent on the host network, a Prometheus outside the
cluster): list the namespace it is deployed in, or one you control, and allow its addresses on `metrics.port` with an
`ipBlock` in `extra`. With `egress.enabled`, the defaults allow DNS to `kube-system` pods labelled `k8s-app: kube-dns`
on port 53: OpenShift and NodeLocal DNSCache need an override. OpenShift: `dns.namespace: openshift-dns`,
`dns.podSelector: {dns.operator.openshift.io/daemonset-dns: default}` and
`dns.ports: [{port: 5353, protocol: UDP}, {port: 5353, protocol: TCP}]` (every entry needs its protocol: one without
would be TCP only and block UDP DNS). NodeLocal DNSCache: list in `dns.cidrs` the address the pods actually query,
`169.254.20.10/32` when the kubelet's `clusterDNS` points at the NodeLocal address (kube-proxy IPVS mode), the kube-dns
Service ClusterIP `/32` in kube-proxy iptables mode (NodeLocal DNSCache also listens on that IP and the traffic is not
DNAT-ed); on GKE with Dataplane V2 nothing is needed. A `dns.podSelector` you set replaces the default selector, it is
not merged with it, and a resolver that cannot be selected takes `dns.enabled: false` and an `egress.extra` rule. A
component that calls the Kubernetes API needs the API server's endpoint IPs and port in `toCIDRs` (ports are matched
after DNAT: kubeadm listens on 6443, not 443; `kubectl get endpointslices -n default -l
kubernetes.io/service-name=kubernetes`). While `egress.enabled` is `false`, the egress destination lists must stay empty
(an overlay that turns egress off clears them with `[]`). As a general rule, do not use `ipBlock` for pods or Services:
some CNIs never match pod traffic with a CIDR; the NodeLocal DNSCache address above is the one documented exception,
because it is a host-network address that pod selectors do not match
([ADR-0040](../adr/0040-networkpolicy-per-component-with-sibling-references.md)).

**RBAC: a ServiceAccount of the component, a token for what the pods use, and a deployer that holds what it grants.**
`rbac.rules` renders a Role `<fullname>` and a RoleBinding for the pods' ServiceAccount, and `rbac.clusterRoles` a
RoleBinding `<fullname>.<ClusterRole>` per existing ClusterRole, in the release namespace only. The subject carries the
release namespace, so render with the real `--namespace`: without it Helm takes `HELM_NAMESPACE`, then the kubeconfig
context's namespace, and `default` when neither is set (measured on Helm 4.3.0 and 3.22.0; inside a pod, the pod's own
namespace: client-go's in-cluster fallback, a source reading), and piping that render
into `kubectl apply -n <namespace>` can grant the roles to a ServiceAccount of another namespace. The render fails for
the namespace's `default` ServiceAccount (`create: false` without a `name`), whose permissions every pod of the
namespace without a ServiceAccount of its own gets, and without `serviceAccount.automountToken: true` (the pods would
have no token), unless no ClusterRole is bound and `use` is the only verb of every rule. A `use` grant is checked by
admission on the ServiceAccount itself, without a token (OpenShift's SCC admission, read in its source, not run;
ADR-0042): on OpenShift, a SecurityContextConstraints the pods may run under, granted by a rule with
`apiGroups: [security.openshift.io]`, `resources: [securitycontextconstraints]`, `resourceNames: [nonroot-v2]` and
`verbs: [use]` (binding one of OpenShift's `system:openshift:scc:*` ClusterRoles instead needs the token, because the
chart cannot see a ClusterRole's rules). Kubernetes lets a deployer create a Role only if it holds every permission in
it, and a RoleBinding only if it holds the referenced role's permissions, unless it may `escalate` or `bind`: for the
`use` rule above the deployer must hold `use` on that SCC (`bind` on the SCC's ClusterRole lets it create a RoleBinding,
not the Role: 403, measured on kube-apiserver v1.33.0 and v1.37.0), and a CI deployer with
the namespace's `admin` ClusterRole (the Helm documentation's advice for charts that create Roles) can grant only what
`admin` holds, never `cluster-admin` or a `*`; Argo CD's and Flux's controllers, bound to cluster-admin-like roles by
default, can grant more. A ClusterRole is bound by name and its rules are not checked: one that does not exist grants
nothing, and only `cluster-admin` is rejected for what it grants (and `*`, which a `roleRef` reads as a name), so any
other ClusterRole is granted as it is, wildcard rules included (Kubernetes' own controller roles, such as
`system:controller:generic-garbage-collector`, hold rules on every resource of every group). `edit` and `admin` let
the pods act as any ServiceAccount of the namespace. The main ways a rule grants more than it names, from Kubernetes'
*RBAC Good Practices*: reading Secrets (`list` and `watch` reveal them like `get`), creating or changing workloads (a
pod may run as any ServiceAccount of the namespace and mount its Secrets), `create` on `serviceaccounts/token`,
`escalate`, `bind`, `impersonate`, and `patch` on the namespace itself (its Pod Security labels); and running commands
in other pods, through `pods/exec` and `pods/attach` (escalating resources for Kubernetes' own `edit` role) or an
ephemeral container (`pods/ephemeralcontainers`)
([ADR-0042](../adr/0042-existing-serviceaccount-and-namespaced-rbac.md)).

**An existing ServiceAccount: it must exist first, and it brings its own settings.**
With `serviceAccount.create: false` and `serviceAccount.name`, the pods run as a ServiceAccount the chart does not
create, for example one that a platform team annotated with a cloud identity. It must exist before the pods: the API
server rejects them otherwise. Its `imagePullSecrets` are added to pods that set none, and its deprecated
`kubernetes.io/enforce-mountable-secrets` annotation rejects pods that reference a Secret it does not list, the
component's `externalSecret` Secret included. Its annotations are its owner's: `serviceAccount.annotations` fails the
render with `create: false` (an override file clears inherited annotations with `serviceAccount.annotations: null`;
`{}` is merged and clears nothing), and an annotation change reaches only pods created afterwards (restart the
Deployment). Keeping the chart's own ServiceAccount under its name, for a cloud identity's trust policy, takes two
deploys on a `deployment` or `cronjob` component, with `helm.sh/resource-policy: keep` first
([upgrade guide](../upgrading.md#keeping-the-charts-serviceaccount-under-its-name)): in one step Helm deletes the
ServiceAccount, and the pods, which do not roll, lose it. On a `job` component the ServiceAccount is a hook, which Helm
deletes once the phase succeeds whatever `resource-policy` says (measured on Helm 4.3.0 and 3.22.0): after a
successful deploy, once it is gone, its owner creates `<fullname>`, and the next deploy sets `create: false` and
`name: <fullname>`.
A cloud identity needs no `automountToken`; Azure Workload Identity needs the pod label
`azure.workload.identity/use: "true"` (in `podLabels`). With `networkPolicy.egress.enabled`, allow what the identity
calls in `toCIDRs`: EKS Pod Identity's agent at `169.254.170.23` (IPv6 `fd00:ec2::23`) on port 80; on GKE, as its
documentation says for a strict network policy, `169.254.169.252/32` on port 988, and `169.254.169.254/32` on port 80
with Dataplane V2. IRSA's AWS STS and Azure's Microsoft Entra ID endpoints are outside the cluster; this guide does not
cover them.

**Job components: expect them to run as Helm hooks.**
A component with `workload.type: job` is rendered as a Helm hook (`job.phase: pre-deploy` by default,
or `post-deploy`), and its ServiceAccount, ConfigMaps, ExternalSecret, NetworkPolicy, Role and RoleBindings are hooks
of the same phase. Hook resources are not part of the release, so `helm uninstall` does not delete them
([ADR-0007](../adr/0007-jobs-as-helm-hooks.md)). If Helm's `--timeout` expires while the Job still runs, Helm deletes
those support resources under the running pod, its NetworkPolicy included: keep `job.activeDeadlineSeconds` below
`--timeout`. With `networkPolicy` on, let the Job retry its first connections for a few seconds: the CNI applies a
new policy some time after it is created, and a pod may start before that
([ADR-0041](../adr/0041-job-component-networkpolicy-is-a-hook.md)). With `rbac`, let the Job retry its first API
calls for a few seconds too, since how soon another cluster's authorizer sees a new binding is not known (the e2e's
Job makes up to 20 attempts, one second apart); the same deletion denies the running Job's API calls; a hook that
cannot be created (a deployer that does not hold its rules) stops the deploy and leaves
the hooks created before it, such as the Job's ServiceAccount, until the next deploy; and a pre-deploy Job's
`serviceAccount.name` must not name a ServiceAccount that a sibling component creates, which does not exist yet when
the Job runs on the first install ([ADR-0043](../adr/0043-job-component-rbac-is-a-hook.md)).
The exception is the component's PrometheusRule: it is not a hook but a regular release object, deleted by
`helm uninstall`, and on the first install it is created only if the pre-deploy hook succeeds
([ADR-0039](../adr/0039-prometheus-rules-travel-with-the-component.md)).

## Failure behavior

What fails **before the cluster is touched**, at `helm template` and at `helm install` / `helm upgrade` alike
(rendering and schema validation are local). Gate the pipeline on `helm template` with the deploy's real values,
release name and `--namespace`, not on `helm lint`
([ADR-0044](../adr/0044-guards-fail-the-render-helm-lint-reports-them.md)):

- A value that breaks the schema: an unknown key, a wrong type, a missing required key, a
  `maxUnavailable` given as a percentage above 100% (an integer above 100 is valid). The error names the
  alias. Keys that apply to one workload type only (`strategy`, `minReadySeconds`, ...) are ignored on the
  others, not rejected; the exceptions are the Deployment-only integrations (`httpRoute`, `ingress`,
  `autoscaling`, `metrics`), which fail when they are enabled on a CronJob or a Job. `helm lint` fails on these
  too when it lints the chart itself; through an umbrella it passed a `null` that deletes a required key
  (`api.rbac: null`, measured on Helm 4.3.0 and 3.22.0 with a `-f` file), which `helm template` rejects.
- A guard that spans several keys or names. `helm lint` does not fail on a guard: it prints the message as an INFO
  line (`funcMap fail` on Helm 4, `[INFO] Fail:` on Helm 3), exits 0, and renders under the placeholder release name
  `test-release`, so the name guards judge a name the deploy never uses. The guards are, for example, a name that is
  not a DNS-1035 label, a name longer than 63 characters (52 for a CronJob), a Kubernetes version below 1.33,
  `autoscaling.minReplicas` greater than `maxReplicas`, a rollout that Kubernetes would reject (`maxSurge` and
  `maxUnavailable` both 0, `minReadySeconds` not lower than `progressDeadlineSeconds`, a `strategy.rollingUpdate` next
  to `Recreate`), a custom
  `lifecycle.preStop` next to the built-in preStop sleep, a lifecycle `sleep` longer than
  `terminationGracePeriodSeconds`, a `metrics.port` that is not the name of an entry in `ports`, a probe
  `httpGet.port` or `tcpSocket.port` given by a name that no `ports` entry declares (or a probe handler that is not a
  map), a `configFiles.mountPath` that is `/tmp` or `/` once normalized (or the ServiceAccount token directory while
  `serviceAccount.automountToken` is true), `externalSecret.enabled` with no entry in `externalSecret.data`, and with
  `networkPolicy` on: `metrics` or a route (`httpRoute`, `ingress`) without a source in the policy (or without
  `routeTrafficAllowedElsewhere: true`), `routeTrafficAllowedElsewhere` without a route,
  `metricsFromNamespaces` without `metrics`, `fromComponents` or `fromNamespaces` with no `ports`, an `endPort`
  lower than its port, egress destinations (`toComponents`, `toCIDRs`, `extra`, `dns.cidrs`) listed while
  `egress.enabled` is `false`; `serviceAccount.annotations` with `create: false`, `serviceAccount.name: default`,
  `serviceAccount.name` with `create: true`, `rbac` for the namespace's `default` ServiceAccount, `rbac` without
  `automountToken: true` (unless no ClusterRole is bound and `use` is the only verb of every rule), `cluster-admin` in
  `rbac.clusterRoles`, and, in a rule with `resourceNames`, a `deletecollection`, or a `create` on a resource when that
  rule grants neither `patch` nor `update`.
- The guards of `volumes` ([ADR-0049](../adr/0049-volumes-are-a-map-of-typed-entries-mounted-in-the-main-container.md), [ADR-0050](../adr/0050-existing-claim-on-a-deployment-and-strategy-rollingupdate-null.md)): a volume
  name that is not a DNS-1123 label or that chart-base reserves; a field of another type, or a `null` in a type's
  required field; a mount path that is another mount's once normalized, `/`, or the token directory; a `subPath` or
  `items[].path` that is absolute or has a `..` element, and two items with one path; a `configMap` or `secret` file
  (`subPath`) beneath a ConfigMap or Secret mount; a `readOnly` that the type contradicts; a size of zero;
  `medium: Memory` without `sizeLimit`; a reference to the component's own ConfigMaps or Secret; two entries of one
  claim; an existing claim declared `ReadWriteOnce` or `ReadWriteOncePod` on a Deployment that can run two pods.

What fails **at install or upgrade**, when Helm talks to the cluster (rendering does not need the CRD,
so `helm template` and `helm lint` do not catch it):

- A kind whose CRD is not installed (HTTPRoute, ExternalSecret, ServiceMonitor, PodMonitor,
  PrometheusRule): Helm cannot build the object, so the release fails cleanly. chart-base does not skip
  such objects ([ADR-0012](../adr/0012-no-capabilities-gating.md)).
- A Role or a RoleBinding that grants a permission the deployer does not hold (unless it may `escalate` or `bind`):
  the API server rejects it with `is attempting to grant RBAC permissions not currently held`, a RoleBinding whose
  Role was rejected fails too (`not found`), and the release fails; the objects already created stay. An upgrade that
  changes a Role needs every rule of it held again
  ([ADR-0042](../adr/0042-existing-serviceaccount-and-namespaced-rbac.md)).
- On Helm 4, for a release that Helm 4 installed, a switch to `strategy: {type: Recreate}` of a Deployment created
  without `strategy`: Helm 4 applies server-side, the `rollingUpdate` that the API server defaulted stays, and the API
  rejects it next to Recreate (`spec.strategy.rollingUpdate: Forbidden`; measured on kube-apiserver 1.33.0 and 1.37.0;
  Helm 3.22.0 switches in place). A Deployment created with `{type: RollingUpdate}` only is the same mechanism (Helm
  then owns only `type`; not run), and `--server-side auto` keeps a release that Helm 3 installed on client-side apply,
  which switches in place (source reading). Stay on `{type: RollingUpdate, rollingUpdate: {maxSurge: 0,
  maxUnavailable: 1}}`, switch to Recreate in a later upgrade, or run that one upgrade with `--server-side=false` (each
  measured; [ADR-0050](../adr/0050-existing-claim-on-a-deployment-and-strategy-rollingupdate-null.md)).

What fails **at rollout**, in the cluster:

- A Deployment that cannot become healthy (crash loop, an image that never pulls, a probe that never
  passes). chart-base sets `progressDeadlineSeconds: 240`, so after 240 seconds the Deployment
  controller marks the rollout failed with `ProgressDeadlineExceeded`. That is shorter than Helm's
  default `--timeout` of 5 minutes. Helm 4.3's status watcher then stops at the failed Deployment and
  reports `status: Failed, message: Progress deadline exceeded`; Helm 3's legacy wait keeps waiting
  until `--timeout`. Neither shows the pod's own reason: find it with `kubectl describe` and the
  events ([ADR-0017](../adr/0017-progress-deadline-240s.md)).
- Helm only waits for ordinary resources like a Deployment when you pass `--wait`,
  `--rollback-on-failure` (Helm 4) or `--atomic` (Helm 3). Without one of them, `helm upgrade` returns
  once the manifests are applied and nothing turns a stuck rollout into a failed release. Use `--wait`
  (or `--rollback-on-failure` / `--atomic`, which also roll back on failure) in the pipeline that
  deploys the umbrella.
- A `pre-deploy` Job that fails: Helm waits for hooks of kind Job and fails the release, so a broken
  migration stops the deploy before the other resources of the release are updated
  ([ADR-0007](../adr/0007-jobs-as-helm-hooks.md)).
- A slow component that legitimately needs more than 240 seconds must raise
  `progressDeadlineSeconds` under its alias.
- A volume whose ConfigMap, Secret or claim does not exist: the pod stays in `ContainerCreating` (a ConfigMap or a
  Secret that is not `optional`) or `Pending` (a claim), and the rollout fails after `progressDeadlineSeconds` (not
  verified for each case). Also caught only there: a file from a claim mounted beneath a ConfigMap mount (the kubelet
  creates that mount point as a directory: source reading, `pkg/volume/util/nested_volumes.go`), and a mount beneath a
  claim mounted read-only, which works only if that directory exists in the claim (kubernetes#121294).
- A `ReadWriteOnce` or `ReadWriteOncePod` claim belongs to ONE component (source reading, unverified): a cronjob or a
  job that shares the claim of a running Deployment waits on another node for the attachment; with
  `job.activeDeadlineSeconds: null` and `concurrencyPolicy: Forbid` every later run is skipped without an error, and
  a hook fails the release at `--timeout`. Set `job.activeDeadlineSeconds` to turn the wait into a failed Job;
  `concurrencyPolicy: Allow` with such a claim waits the same way.
- An existing ServiceAccount (`serviceAccount.name`) that does not exist: the API server rejects every pod
  (`error looking up service account <namespace>/<name>: serviceaccount "<name>" not found`), so none is created. A
  Deployment's rollout is then expected to fail after `progressDeadlineSeconds`, and a Job hook to make Helm wait until
  `--timeout`, as with a PriorityClass that does not exist (not verified for this case: the measurement ran without the
  controllers).
- A `priorityClassName` or `runtimeClassName` that names no existing class: the Priority or the
  RuntimeClass admission plugin (both on by default) rejects the pods. A Deployment's rollout fails
  after `progressDeadlineSeconds`; for a `pre-deploy` or `post-deploy` Job hook no pod is ever created, so
  the release waits until Helm's `--timeout` (or `job.activeDeadlineSeconds`); for a CronJob the runs
  silently never start ([ADR-0036](../adr/0036-rollout-and-runtime-knobs-are-validated-pass-throughs.md)).

What **Helm never reports**, because only the Prometheus Operator reads it (the objects are created and the
release succeeds):

- A monitor or a PrometheusRule that Prometheus does not select, for example without the `release` label that
  kube-prometheus-stack selects on (see [Rules](#rules)).
- A `scrapeTimeout` greater than `interval`: the operator rejects the monitor
  ([ADR-0038](../adr/0038-one-metrics-endpoint-servicemonitor-or-podmonitor.md)).

What **Helm never reports** about a NetworkPolicy, because only the CNI reads it (the object is created, it is ready
for Helm as soon as it exists, and the release succeeds):

- A CNI that does not enforce NetworkPolicy: nothing is restricted.
- An alias in `fromComponents` or `toComponents`, or a namespace, that matches nothing: the peer selects no pod.
- DNS settings that do not match the cluster, with `egress.enabled`: the pods cannot resolve names.
- The time the CNI takes to program a new policy: a pod may start before it is enforced.

What **Helm never reports** about RBAC (the objects are created and the release succeeds):

- A resource name or an API group with a typo, or a ClusterRole that does not exist: the rule or the binding grants
  nothing. `kubectl auth can-i --list --as=system:serviceaccount:<namespace>:<name> -n <namespace>` shows what a
  ServiceAccount may do.
- Another workload that runs as the same existing ServiceAccount: it gets the same permissions.

A **rule whose PromQL does not parse** (or a broken annotation template) depends on the operator's admission
webhook. Where it is deployed (kube-prometheus-stack deploys it by default, checked on chart version 91.8.2), the
PrometheusRule is rejected when Helm applies it and is not created, and the install or upgrade of the whole
release (the whole umbrella) fails. Without the webhook the object is created and the operator skips the whole
PrometheusRule with a Warning event
([ADR-0039](../adr/0039-prometheus-rules-travel-with-the-component.md)). The schema already rejects the structural
mistakes, including a `for`, `keep_firing_for` or `annotations` on a recording rule.

## Recommendations for umbrella authors

These are practices for the umbrella, not features of chart-base.

1. **Ship at least one real template in the umbrella**, for example `templates/NOTES.txt`. The
   repository's [`alias-contract.sh`](../../.github/scripts/alias-contract.sh) notes that Helm 4
   skips subchart schema validation in `helm lint` when `templates/` is missing, so its throwaway umbrella
   adds a `NOTES.txt`. A template-less umbrella can therefore pass `helm lint` with invalid values.
2. **Give the umbrella its own root `values.schema.json`.** chart-base validates the keys under each
   alias, but an umbrella's own top-level keys are not its business: a mistyped alias key (`apii:` for
   `api:`) is just another unknown key at the root and is silently ignored, and the values under it are never
   applied. A root schema with
   `additionalProperties: false` and the list of aliases catches the typo.
3. **Render once with every component enabled.** A disabled component is removed before its values are
   validated: `helm template` accepts an invalid key under an alias whose `enabled` is `false` (checked
   with Helm 3.19). Keep a values file (or a CI job) that turns every component on, and run
   `helm template` (with the release name and `--namespace` of a real deploy) and `helm lint --strict` with it,
   so a problem in a component that is off in some environments is still found. Only `helm template` fails on
   a guard ([ADR-0044](../adr/0044-guards-fail-the-render-helm-lint-reports-them.md)).

## Secrets created by operators

Some Secrets are created inside the cluster by an operator, not synced from a secret manager: the
`<cluster>-app` Secret of a CloudNativePG cluster, the Secret of a Strimzi `KafkaUser`. Reference them by
name, in `env` (one key) or `envFrom` (the whole Secret), instead of copying them through
`externalSecret`. The values never appear in your values file, and rotating the Secret restarts a
Deployment's pods through Reloader (a CronJob run or a Job hook reads the current Secret when it starts).
See the
[README recipe](https://github.com/jellalshadows/chart-base/blob/main/README.md#operator-created-secrets-and-pod-metadata-cloudnativepg-strimzi-opentelemetry)
and [ADR-0031](../adr/0031-existing-secrets-referenced-by-name.md). A reference to an object that does
not exist is not caught at render time: the pod stays in `CreateContainerConfigError`. A Deployment
rollout then fails within `progressDeadlineSeconds`. A CronJob is different: `helm --wait` does not wait
for its runs, the stuck run's Job stays active (`job.activeDeadlineSeconds` defaults to `null`) and, with
the default `concurrencyPolicy: Forbid`, later runs are skipped. Set `job.activeDeadlineSeconds` on
CronJobs that reference external objects. A Job hook makes Helm wait until `--timeout`.

## Upgrading chart-base

Read [`CHANGELOG.md`](../../CHANGELOG.md) for every version between the current one and the target,
which release-please writes from the conventional commits, and the [upgrade guide](../upgrading.md)
for what to change in your values after each breaking release and after a fix release that changes
rendered objects (0.4.1).

- Before 1.0, a breaking change is marked `feat!:` or `fix!:` and bumps the **minor** version, and a `feat:`
  also bumps the minor. So a `0.x` minor bump can break your values: read it before you bump.
  A `fix:` bumps the patch.
- Bump the `version:` in **every** dependency entry of the umbrella at the same time (one version per
  umbrella), then run `helm dependency update` and commit the updated `Chart.lock`.
- Bumping chart-base never restarts pods by itself: `helm.sh/chart` is not a pod label and the config
  checksums hash only the ConfigMaps' data
  ([ADR-0010](../adr/0010-chart-version-never-restarts-pods.md)). Pods restart only when their own
  content changes. A breaking release that changes the rendered pod template on purpose restarts them once
  and says so in the upgrade guide: upgrading to 0.3.0 does, because it turns service links off
  ([ADR-0035](../adr/0035-service-links-off-by-default.md)).
- The pod selector labels are frozen from 1.0.0 on.

## Verifying what you deploy

Every published version has a provenance attestation and, from the signing step on, a cosign signature
([ADR-0022](../adr/0022-provenance-with-actions-attest.md),
[ADR-0034](../adr/0034-keyless-cosign-signatures.md)). Versions published before signing existed are signed by a manual
sign-only run (see the [re-publish runbook](../runbooks/republish-a-tag.md)), so check that a version is signed
before you rely on it.
The commands, with the exact identity and issuer, are in the
[README](../../README.md#versioning-and-releases):

- `gh attestation verify` proves which workflow built the digest.
- `cosign verify ... | jq -e ...` proves that the `release.yaml` workflow on `main` signed it. Plain
  `cosign verify` also accepts the attestation, which is why the README pipes the result through a `jq`
  filter that requires the signature type.

Flux can verify the signature when it fetches the chart (like plain `cosign verify`, it accepts either bundle: it
proves that `release.yaml@main` vouched for the digest, not that the cosign signature in particular exists; to
require the signature, use the README's `cosign verify ... | jq` command). Flux documents cosign
verification of OCI Helm charts through a `spec.verify` block on the `HelmChart`
([Flux documentation](https://fluxcd.io/flux/components/source/helmcharts/#verification)). Support for the
cosign v3 bundle format arrived in Flux 2.8 (source-controller 1.8,
[PR #1961](https://github.com/fluxcd/source-controller/pull/1961)); Flux 2.7 and older cannot verify cosign v3 signatures
([issue #1923](https://github.com/fluxcd/source-controller/issues/1923)). The example below uses the field names of the Flux documentation and was not tested on a
cluster here:

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmChart
metadata:
  name: chart-base
spec:
  interval: 5m0s
  chart: chart-base
  version: <chart-base version>
  sourceRef:
    kind: HelmRepository   # a HelmRepository with type: oci and url: oci://ghcr.io/jellalshadows/charts
    name: chart-base
  verify:
    provider: cosign
    matchOIDCIdentity:
      - issuer: ^https://token\.actions\.githubusercontent\.com$
        subject: ^https://github\.com/jellalshadows/chart-base/\.github/workflows/release\.yaml@refs/heads/main$
```

Older Flux reads only legacy `.sig` signatures, which chart-base does not publish
([ADR-0034](../adr/0034-keyless-cosign-signatures.md)). A `HelmRelease` that uses a `chartRef` to this
`HelmChart`, or a chart spec of its own, needs the same verification; this guide does not cover those
variants.
