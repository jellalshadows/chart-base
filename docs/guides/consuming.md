# Consuming chart-base from a domain umbrella

This guide is for platform teams that write an umbrella chart for a business domain and deploy it.
The [README](../../README.md) has the quick start, the recipes and the values table; this guide
explains the model behind them, the reason for each rule, and what to expect when something is wrong.

Contents:

- [The model](#the-model)
- [The umbrella `Chart.yaml`](#the-umbrella-chartyaml)
- [Values: nested under the alias](#values-nested-under-the-alias)
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
- **Setting a key to `null` deletes it** (this is Helm's behavior). chart-base's schema marks as
  `required` the keys whose deletion would silently change a default, so such a `null` fails instead of
  flipping the default ([ADR-0027](../adr/0027-required-keys-in-the-schema.md)).

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

**Job components: expect them to run as Helm hooks.**
A component with `workload.type: job` is rendered as a Helm hook (`job.phase: pre-deploy` by default,
or `post-deploy`), and its ServiceAccount, ConfigMaps and ExternalSecret are hooks of the same phase.
Hook resources are not part of the release, so `helm uninstall` does not delete them
([ADR-0007](../adr/0007-jobs-as-helm-hooks.md)).

## Failure behavior

What fails **before the cluster is touched**, at `helm template`, `helm lint` and `helm install` /
`helm upgrade` alike (rendering and schema validation are local):

- A value that breaks the schema: an unknown key, a wrong type, a missing required key, a feature
  that does not apply to the workload type. The error names the alias.
- A guard that spans several keys or names, for example a name that is not a DNS-1035 label, a name longer than 63
  characters (52 for a CronJob), a Kubernetes version below 1.33, `autoscaling.minReplicas` greater
  than `maxReplicas`.

What fails **at install or upgrade**, when Helm talks to the cluster (rendering does not need the CRD,
so `helm template` and `helm lint` do not catch it):

- A kind whose CRD is not installed (HTTPRoute, ExternalSecret): Helm cannot build the object, so the
  release fails cleanly. chart-base does not skip such objects
  ([ADR-0012](../adr/0012-no-capabilities-gating.md)).

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
3. **Lint once with every component enabled.** A disabled component is removed before its values are
   validated: `helm template` accepts an invalid key under an alias whose `enabled` is `false` (checked
   with Helm 3.19). Keep a values file (or a CI job) that turns every component on, and run
   `helm lint --strict` and `helm template` with it, so a problem in a component that is off in some
   environments is still found.

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
for what to change in your values after each breaking release.

- Before 1.0, a breaking change is marked `feat!:` and bumps the **minor** version, and a `feat:`
  also bumps the minor. So a `0.x` minor bump can break your values: read it before you bump.
  A `fix:` bumps the patch.
- Bump the `version:` in **every** dependency entry of the umbrella at the same time (one version per
  umbrella), then run `helm dependency update` and commit the updated `Chart.lock`.
- Bumping chart-base never restarts pods by itself: `helm.sh/chart` is not a pod label and the config
  checksums hash only the ConfigMaps' data
  ([ADR-0010](../adr/0010-chart-version-never-restarts-pods.md)). Pods restart only when their own
  content changes.
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
