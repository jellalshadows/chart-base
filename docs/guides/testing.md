# Testing guide

chart-base is tested in layers. Each layer is cheap where it can be and realistic where it has to be,
and each one proves something the others cannot. This guide is for contributors and reviewers: for every
layer it says what it proves, where it lives, how to run it locally and where CI runs it. Tool
installation is in the [development guide](development.md#tools-and-versions). All commands run from
the repository root.

Contents:

- [Overview](#overview)
- [Unit tests](#unit-tests)
- [Lint on Helm 3 and 4](#lint-on-helm-3-and-4)
- [Manifest validation with kubeconform](#manifest-validation-with-kubeconform)
- [The alias contract](#the-alias-contract)
- [End-to-end on kind](#end-to-end-on-kind)
- [Documentation checks](#documentation-checks)
- [Workflow checks](#workflow-checks)
- [Release signing checks](#release-signing-checks)
- [Mutation testing as a review practice](#mutation-testing-as-a-review-practice)
- [Definition of done for a feature](#definition-of-done-for-a-feature)

## Overview

| Layer | Proves | Runs locally without Docker | CI job |
|---|---|---|---|
| Unit tests | What the templates render, and what the schema and guards reject | Yes | `unit tests` |
| `helm lint --strict` | The chart lints on every scenario, on real Helm 3.22 and 4.3 | Yes | `lint` |
| kubeconform | The rendered manifests are valid for Kubernetes 1.33 and 1.37 | Yes (needs network) | `lint` |
| Alias contract | Several aliases in one umbrella work and stay independent | Yes | `lint` |
| End-to-end | The manifests really install and run in a cluster, and kindnet enforces the NetworkPolicies as rendered | No (needs kind) | `e2e` |
| Documentation | The README is not stale; every link and anchor resolves | Yes | `docs` |
| Workflows | The workflow files are sound; the PR title is a conventional commit | Yes (actionlint) | `workflows`, `pr-title` |
| Release signing | The signing steps of `release.yaml` verify a real signed release, and refuse a wrong identity, a missing bundle type and a bad digest | Yes (needs network; cosign, jq, yq, curl) | `release signing checks (cosign)` |

A single required check, `ci-ok`, depends on all the jobs. chart-testing (`ct`) is deliberately not used
([ADR-0023](../adr/0023-no-chart-testing.md)).

## Unit tests

**What it proves.** The rendered manifests for each workload type and flag combination, the contract
(names, labels, `envFrom`, mounts, hook annotations, checksums), and the negative cases: every rule of
`values.schema.json` and every guard of `templates/validate.yaml` fails with the expected message.

**Where it lives.**

- Suites in `tests/*_test.yaml`, roughly one per area (`deployment`, `cronjob`, `job`, `configmap`,
  `env` (references, `envFrom`, Reloader annotations), `pod` (runtime knobs and service links, on every
  workload type), `lifecycle` (container hooks), `monitoring` (the ServiceMonitor or the PodMonitor),
  `prometheusrule` (on every workload type), `networkpolicy` (every workload type, a hook on a job component),
  `externalsecret`, `exposure`, `scaling`, `service`, `serviceaccount`, `hooks`, `validate`, `schema`,
  `snapshot`). Each suite names the templates it renders.
- Shared values in `tests/values/`: `base.yaml` (the minimum valid values every suite starts from),
  `env-refs.yaml` (one reference of every kind plus `envFrom` sources, for the `env` suite),
  `pod-runtime.yaml` (every pod runtime knob, for the `pod` suite), `prometheus-rules.yaml` (a recording
  and an alerting rule, for the `prometheusrule` suite) and
  `large-numbers.yaml` (numbers, loaded as a values file on purpose, see the
  [pitfalls](development.md#pitfalls)).
- Snapshots in `tests/__snapshot__/`, from `tests/snapshot_test.yaml`: one per `ci/` scenario. A
  pull request that changes rendered manifests shows the change as a snapshot diff, which is what
  reviewers read.
- **Schema tests** use `failedTemplate` with an `errorPattern` that matches the schema error path, for
  example `"/image/repository': minLength"`. They go through `templates/validate.yaml`, because rendering
  any template makes Helm validate the values against the schema first.
- **Guard tests** (`tests/validate_test.yaml`) assert the `chart-base[<alias>]: ...` messages of the
  guards, including the boundaries: a 63-character name passes and a 64-character one fails, and the same
  for 52 and 53 with a CronJob.
- Every suite sets `capabilities` (Kubernetes 1.33) and a real `release.name`, because the defaults of
  helm-unittest are not valid for this chart.

**Run locally.**

```bash
helm unittest --strict .
```

Add `-u` to update snapshots after an intended change, and review the diff of `tests/__snapshot__/`
([TDD loop](development.md#the-tdd-loop)).

**In CI.** The `unit tests` job runs `helm unittest --strict .` with Helm 4.3.0 and helm-unittest 1.1.2.

**Limit.** helm-unittest embeds its own Helm engine, so it does not prove behavior on Helm 4. The
next layers do. helm-unittest also decodes the rendered manifests with go-yaml v3 (YAML 1.2 booleans),
while Helm's client uses YAML 1.1 rules: a plain `on` is a string for helm-unittest and a boolean for Kubernetes. A
test that a value stays a string therefore uses `true`, `false` or `null`, which are keywords in both
(the port-name tests use a port named `true`), and the `port-names` scenario covers `on` with kubeconform
([pitfalls](development.md#pitfalls)).

## Lint on Helm 3 and 4

**What it proves.** `helm lint --strict` passes, with the real Helm binaries, for every scenario in `ci/`
(`deployment`, `worker`, `cronjob`, `job`, `full`, `port-names`). The `full` scenario turns every feature on
at once; `port-names` names its only port `on` (see [kubeconform](#manifest-validation-with-kubeconform)).
CI runs the layer on Helm 3.22.0 and 4.3.0, because Helm 3 still receives security fixes and consumers still
use it ([ADR-0019](../adr/0019-helm-4-first-helm-3-tested.md)).

**Where it lives.** `ci/*-values.yaml` and the `lint` job of `.github/workflows/ci.yaml`. The matrix
(`helm: [v3.22.0, v4.3.0]`) is bumped by hand: keep its `4.x` entry equal to `HELM_VERSION`.

**Run locally**, with whichever Helm you have installed:

```bash
for values in ci/*-values.yaml; do
  helm lint --strict . -f "$values"
done
```

## Manifest validation with kubeconform

**What it proves.** Each `ci/` scenario, rendered with `helm template --kube-version`, is valid against
the strict Kubernetes JSON schemas for Kubernetes 1.33 and 1.37, and against the CRD schemas for the
Gateway API, External Secrets and Prometheus Operator kinds. Both schema sources are pinned to a commit in the script, so
a run does not change when an upstream catalog changes.

**Where it lives.** `.github/scripts/validate-manifests.sh <chart-dir> <kubernetes-version>`. The
chart's floor is 1.33, so the tests run on the oldest and the newest supported versions
([ADR-0018](../adr/0018-kubernetes-version-floor.md)).

**Run locally.** Needs `helm` and `kubeconform` on `PATH` and network access to fetch the schemas:

```bash
.github/scripts/validate-manifests.sh . 1.33.12
.github/scripts/validate-manifests.sh . 1.37.0
```

Each scenario ends with a `Summary:` line that must report `Invalid: 0, Errors: 0`.

kubeconform parses the manifests with the same YAML library as Helm's client (sigs.k8s.io/yaml, with
YAML 1.1 rules), so it is the layer that sees a value that YAML 1.1 reads as a boolean. The `port-names`
scenario names its only port `on`, and the Service, the Ingress backend and the ServiceMonitor endpoint
refer to it: a port name rendered without `quote` fails here with a `got boolean` error
([pitfalls](development.md#pitfalls)).

**In CI.** The `lint` job, on both Helm versions, with kubeconform 0.8.0 verified against the published
checksums.

## The alias contract

**What it proves.** That chart-base works the way it is consumed: as several aliased dependencies of an
umbrella. The script builds a **throwaway umbrella** in a temporary directory (nothing is committed) with three
aliases: `api`, `worker` and a hyphenated `nightly-cleanup` (CronJob), so that the case of `front-web` is
covered: a hyphen in the values key, the `condition` path and the resource names. It checks that:

- the umbrella renders with `global` and `<alias>.enabled` keys present;
- there are no duplicated `kind/name` pairs across aliases;
- objects are named `<release>-<alias>`, and a worker renders no Service;
- with `metrics` on, `api` gets a ServiceMonitor and `worker` a PodMonitor (never the other kind), each
  selecting only its own component (`app.kubernetes.io/name` is the alias);
- with `networkPolicy` on, `api` and `worker` each get a NetworkPolicy that selects only their own pods,
  `api`'s `fromComponents: [worker]` selects the worker's pods of the release and `worker`'s
  `toComponents: [api]` selects api's, and `nightly-cleanup` (policy off) gets none; `worker` sets
  `egress.dns.podSelector` in the umbrella's values, and its DNS rule selects exactly that map (it replaces the
  default selector), on both Helm versions;
- `helm.sh/chart` keeps the real chart name (`chart-base-<version>`) under an alias;
- `<alias>.enabled=false` removes the component;
- the schema is enforced per alias and names the alias in the error, and a typo under an alias fails;
- an uppercase alias is rejected by the guard.

**Where it lives.** `.github/scripts/alias-contract.sh <chart-dir>`. The script copies the chart next to
the umbrella and uses a relative `file://` repository, because Helm treats only `file://` paths that start
with `/` as absolute, which breaks with Windows drive letters. It also adds a `NOTES.txt` to the umbrella
because Helm 4 skips subchart schema validation in `helm lint` when the umbrella has no `templates/`.

**Run locally.** Needs `helm` and `yq` (mikefarah, v4) on `PATH`:

```bash
.github/scripts/alias-contract.sh .
```

It ends with `alias contract: all checks passed`.

**In CI.** The `lint` job, on Helm 3.22.0 and 4.3.0.

## End-to-end on kind

**What it proves.** That the manifests are accepted and work in a real cluster, under the same
restrictions consumers have. The other layers never start a pod.

**Where it lives.** `.github/scripts/e2e.sh <chart-dir>` and the `e2e` job of the workflow. It needs
Docker and kind, so it is **not** run locally as part of the usual loop. It is described here from the
script and the workflow.

The cluster:

- Two legs: Kubernetes 1.33 with kind v0.32.0 and node image `kindest/node:v1.33.12`, and Kubernetes 1.37
  with kind v0.33.0 and `kindest/node:v1.37.0`. Each node image is pinned by digest and must match its kind
  release (kind v0.33.0 does not publish a 1.33 image, hence the two kind versions). The kind versions
  and digests are bumped by hand, not by Renovate.
- Helm 4.3.0.
- kind's default CNI, kindnet, which enforces NetworkPolicy since kind v0.24.0 through kube-network-policies
  (both kind versions embed it at commit `f67f0fb35e2b`).

The prerequisites the script installs:

1. The **Gateway API** standard CRDs (`GATEWAY_API_VERSION`, v1.6.2 in CI), so that an HTTPRoute can be
   created.
2. The **Prometheus Operator** CRDs of ServiceMonitor, PodMonitor and PrometheusRule
   (`PROMETHEUS_OPERATOR_VERSION`, v0.94.1), from the `example/prometheus-operator-crd` directory of that
   tag, and nothing else: no operator runs, so the e2e proves that the API server accepts the objects, not
   that anything scrapes them. The script waits until the three CRDs are `Established`.
3. The **External Secrets Operator** chart (`ESO_CHART_VERSION`, 2.11.0), with a `ClusterSecretStore`
   named `fake` that uses ESO's `fake` provider and one key, `/sales/db-password`. The script waits until
   the store is `Ready`.
4. A namespace `vending` labelled `pod-security.kubernetes.io/enforce=restricted`. Every pod of every
   scenario must therefore satisfy Pod Security `restricted`, which validates the secure defaults
   ([ADR-0013](../adr/0013-secure-by-default.md)).
5. A Secret `e2e-shared` (key `TOKEN`) in that namespace, created by hand like the ones an operator
   would create. The `cronjob` and `full` scenarios reference it by name.
6. A PriorityClass `e2e-high` (value 1000, not the global default, `preemptionPolicy: Never` so it never
   evicts anything), which the `full` scenario's `priorityClassName` points to.

The image is the Kubernetes end-to-end test image `registry.k8s.io/e2e-test-images/agnhost:2.66.1`
(see `ci/*-values.yaml`). It runs as a non-root arbitrary UID with a read-only filesystem, serves HTTP on
8080 with `netexec`, and has a shell, so the Job and CronJob scenarios can check environment variables,
the Secret and the config file.

Each scenario is installed with `helm upgrade --install ... --wait --timeout 5m` from its
`ci/<name>-values.yaml`. What each one asserts:

| Scenario | Assertions |
|---|---|
| `deployment` | The Deployment becomes Ready in the restricted namespace. A second upgrade with `--set config.APP_MODE=api-v2` creates a new ReplicaSet: a config change rolls the pods (the checksum annotation). |
| `worker` | The worker becomes Ready and there is no Service named for it. It has a PodMonitor labelled `release: e2e` whose endpoint port is the container port `metrics`, and no ServiceMonitor. |
| `cronjob` | A Job created manually from the CronJob (`kubectl create job --from=cronjob/...`) completes within 180 seconds: a restricted pod that reads its config from the ConfigMap, its `env` references (`fieldRef`, `resourceFieldRef`) and the `e2e-shared` Secret injected with `envFrom` and a prefix. Service links are off: `KUBERNETES_SERVICE_HOST` is set, `DEPLOYMENT_CHART_BASE_SERVICE_HOST` (the `deployment` scenario's Service, installed before; the script first checks that it has a ClusterIP) is not. |
| `job` | The `pre-deploy` hook Job succeeds and its log contains `migrations-ok`: it saw `APP_MODE`, `DB_PASSWORD` (from the ExternalSecret) and `/config/migrations.yaml`, all created as hooks before it ran. A second deploy with `--set-string podAnnotations.revision=2` succeeds, so the Job hook is recreated instead of hitting `field is immutable` ([ADR-0007](../adr/0007-jobs-as-helm-hooks.md)). |
| `full` | The ExternalSecret becomes Ready, the Secret it creates holds the value `s3cr3t` from the fake provider, the API server accepts the HTTPRoute, the Deployment's `secret.reloader.stakater.com/reload` annotation is exactly `e2e-shared,full-chart-base-secrets`, and the HPA, PDB and Ingress are created. The Deployment carries `strategy` (`maxSurge: 1`, `maxUnavailable: 0`), `minReadySeconds` and `revisionHistoryLimit`; a pod carries `priorityClassName: e2e-high` resolved to priority 1000 by the API server, `enableServiceLinks: false`, the `dnsConfig` option and the `hostAliases` entry. The ServiceMonitor is labelled `release: e2e` and its endpoint targets the Service port `http` with a `30s` interval, there is no PodMonitor, and the PrometheusRule is labelled `release: e2e` and holds the alert `FullChartBaseDown`. The NetworkPolicy is accepted with both policy types, the `except` of its `ipBlock` and its `endPort`. |
| `port-names` | The API server accepts the component whose only port is named `on`, and stores `on` as a string in the Service port name and `targetPort`, the container port name, the Ingress backend port name and the ServiceMonitor endpoint port. |

After the scenarios, the **NetworkPolicy checks**. The script creates a namespace `netpol` (Pod Security
`restricted`) with a default-deny NetworkPolicy (`podSelector: {}`, `policyTypes: [Ingress, Egress]`, no rule), and
a namespace `monitoring` without policies, with an agnhost pod `probe` that serves HTTP on 8080. It builds a throwaway
umbrella `shop` like the alias contract does, with three aliases, and installs it in `netpol`:

- `api` (a Deployment serving HTTP on `http`, 8080, with a `metrics` port, 9090, where nothing listens) allows
  `fromComponents: [web]` and `metricsFromNamespaces: [monitoring]`;
- `web` (the same image) allows no ingress source and isolates its egress: the cluster DNS (the default) and
  `toComponents: [api]`;
- `migrate`, a `pre-deploy` Job with egress isolated (DNS only), resolves and connects over TCP to
  `kube-dns.kube-system.svc.cluster.local:53`, with up to 20 attempts one second apart.

Each probe is `kubectl exec ... /agnhost connect <host>:<port> --timeout=3s`, repeated every second for up to
10 seconds until the result is the expected one, as Kubernetes' own NetworkPolicy e2e does: an allowed connection
connects or is `REFUSED` (nothing listens), a denied one is a `TIMEOUT` (kindnet drops it), and a DNS error counts as
neither. kindnet fails open, and when its policy controller cannot start it only logs `skipping network policies`:
allow checks alone would pass without enforcement, so the **first** check is a deny.

With the default-deny in place, a denial may come from it as well as from the chart, so these checks prove that
NetworkPolicy is enforced, that the chart's rules allow what they should, and that they open nothing more:

| Check | Expected |
|---|---|
| `monitoring/probe` → `shop-web.netpol.svc.cluster.local:8080` | Denied: neither `web`'s policy nor the default-deny allows a source. Fails as "NetworkPolicy is not enforced". |
| The install itself, and the `migrate` Job's log | The Job logged `dns-ok`: under the default-deny it reached the cluster DNS only through its own policy, a hook created before it ([ADR-0041](../adr/0041-job-component-networkpolicy-is-a-hook.md)). The policy is gone after the install (`hook-succeeded`). |
| `web` → `shop-api:8080` | Allowed: DNS by Service name, `web`'s `toComponents: [api]` and `api`'s `fromComponents: [web]`. |
| `web` → the `probe` pod's IP, port 8080 | Denied: `web`'s rules allow only the cluster DNS and `api`, and the default-deny allows nothing (the destination has no policy). |
| `monitoring/probe` → `shop-api.netpol.svc.cluster.local:9090` | Allowed (`REFUSED`): `metricsFromNamespaces` opens the `metrics` port. |
| `monitoring/probe` → `shop-api.netpol.svc.cluster.local:8080` | Denied: the monitoring namespace reaches only the metrics port. |

Then the script deletes the default-deny, so that only the chart's policies remain, and checks the chart's own
isolation:

| Check | Expected |
|---|---|
| `api` → the `probe` pod's IP, port 8080 | Allowed: `api`'s policy isolates ingress only (`egress.enabled: false`), so its egress is open. The probe also waits until the deletion is enforced. |
| `monitoring/probe` → `shop-web.netpol.svc.cluster.local:8080` | Denied by `web`'s own policy: it isolates `web`'s ingress and allows no source. |
| `web` → the `probe` pod's IP, port 8080 | Denied by `web`'s own policy: it isolates `web`'s egress and allows only the cluster DNS and `api`. |

No check depends on an `ipBlock` matching a pod IP, which kindnet does and some CNIs never do.

On failure the script prints
`kubectl get all,externalsecrets,servicemonitors,podmonitors,prometheusrules,networkpolicies` for the namespace
of the failing check (`vending` for the scenarios, `netpol` for the NetworkPolicy checks, which also list the pods and
policies of `monitoring`).

**In CI.** The `e2e` job, one leg per Kubernetes version. To debug a failure locally, read the failing
step in the job log first: the `FAIL:` message names what the script expected. Reproducing it needs a
local kind cluster on the same Kubernetes version and the three environment variables above.

## Documentation checks

**What it proves.** The README is not stale, and every link and anchor in the Markdown files resolves.

**README drift.** `README.md` is generated from `README.md.gotmpl` and the comments of `values.yaml`.

```bash
helm-docs --chart-search-root . --template-files README.md.gotmpl
git diff --exit-code README.md
```

The second command must print nothing and exit 0. CI runs the same pair and fails when the committed README
differs ([ADR-0025](../adr/0025-generated-english-readme.md)).

**Link check.** lychee runs offline: it checks that files and anchors exist, without network access.
Links to this repository's GitHub URLs (used by the README so that they also work inside the packaged
chart) are remapped to the checkout:

```bash
lychee --offline --include-fragments --no-progress \
  --remap "https://github.com/jellalshadows/chart-base/(blob|tree)/main/ file://$PWD/" \
  './**/*.md'
```

On Windows with Git Bash, use `file:///$(cygpath -m "$PWD")/` as the replacement. External URLs are not
checked by this command. Both checks run in the `docs` job.

## Workflow checks

- **actionlint** lints the workflow files (`actionlint` from the repository root, no arguments).
- **zizmor** audits the workflows for security problems. It runs in CI through its action, with
  `advanced-security: false` so that findings fail the job.
- **PR title** (`pr-title` job): the title must be a conventional commit, because the squash-merge uses it
  as the commit message that release-please reads.

Workflow hygiene follows one rule set: `permissions: {}` at workflow level and only what a job needs,
actions pinned by commit SHA with a version comment, `persist-credentials: false`, and tool versions in
`*_VERSION` variables with a `# renovate:` comment ([ADR-0024](../adr/0024-renovate.md)).

## Release signing checks

**What it proves.** That the signing logic of `.github/workflows/release.yaml` works, before a release
depends on it. A signing failure after the push cannot be undone, because published versions are never
overwritten, so the steps are exercised in every pull request instead. The script extracts the real `run:`
blocks of these steps with yq (by step name) and runs them, so it tests the workflow as written and not a
copy:

- `Prepare the Sigstore bundle check` creates the `require-bundles.sh` helper. Against a real signed
  release it must accept the provenance and signature bundles, reject a bundle type that does not exist
  (so the type filter is not vacuous) and reject a different signer identity.
- The digest extraction of the overwrite guard (`Refuse to overwrite an existing version`) returns the
  right digest from the real manifest headers of the published tag.
- `Digest to sign` picks the existing digest, prefers the pushed one, and refuses to continue with no
  digest or a malformed one.

A missing or renamed step fails the script with a message that names it.

**Where it lives.** `.github/scripts/release-signing.sh <repository root>`. The fixture is chart-base
0.2.0, pinned by digest: it is already signed and attested, and a published version never changes. The
script uses anonymous registry access (it sets an empty `DOCKER_CONFIG`), so a local Docker credential
store does not interfere.

**Run locally.** Needs network access and `cosign`, `jq`, `yq` (mikefarah, v4) and `curl` on `PATH`:

```bash
export PATH=/path/to/tools:$PATH
.github/scripts/release-signing.sh .
```

Every case prints `ok - ...`; the first failure prints `FAIL: ...` and stops.

**In CI.** The `release signing checks (cosign)` job (`release-signing`). It installs the cosign version
that `release.yaml` declares in `COSIGN_VERSION`, read from that file, so there is one place to bump and a
cosign update from Renovate is exercised in its own pull request. The job **signs nothing** and needs
only `contents: read`. What it cannot prove is the signing itself, which needs the release workflow's
OIDC identity and runs only in a real release.

## Mutation testing as a review practice

A passing test proves nothing until you have seen it fail. When you write or review a test, **break the
template on purpose** and check that the right test goes red:

1. Change one thing the test claims to protect: remove a `required` from the schema, flip a default,
   drop a label, change `toJson` to `toString`, delete the guard's `fail`.
2. Run `helm unittest --strict .`.
3. The test that is meant to guard that behavior must fail, with a message that points to the cause. If
   nothing fails, the behavior is untested. If a test unrelated to the change fails and the intended one
   does not, the intended test asserts the wrong thing.
4. Restore the template.

This is the second half of the TDD loop: the test failed once before the template existed, and it still
fails when the template is broken. Reviewers can ask for the mutation they tried, or run one themselves
on the pull request.

## Definition of done for a feature

From [the principles of the roadmap](../roadmap.md#principles) ("Every feature ships complete"), a feature is
done when the pull request contains:

- helm-unittest tests written test-first, negative cases included;
- a scenario in `ci/`, or an extension of an existing one;
- a check in `e2e.sh` against the real system in kind, whenever an operator or CRD is installed in the
  e2e;
- updated snapshots, with the diff reviewed;
- the rows in the values table (a `# --` comment in `values.yaml`, README regenerated);
- its documentation: new ADRs in `docs/adr/` (context, decision, consequences, rejected alternatives),
  and updates to the roadmap, the affected guides and runbooks, and the summarized decision in the
  README.
