# Ten decisions that shape chart-base

chart-base is one Helm application chart that deploys any workload of a business domain: a domain umbrella chart
declares it once per component, each under its own alias, and no service writes a template. This page curates its
[architecture decision records](adr/README.md): the ten decisions with the most consequence, each with the problem, the
decision, the main alternative, the cost and the evidence. The records hold the full reasoning and every alternative
considered, and the README's [design decisions](../README.md#design-decisions) summarize each one in a paragraph.

| # | Decision | In one line |
|---|---|---|
| 1 | [One chart, consumed through aliases](#1-one-chart-consumed-through-aliases) | Every component is schema-validated, and no service writes templates. |
| 2 | [The alias is the identity](#2-the-alias-is-the-identity) | Names are `<release>-<alias>`, never truncated, never overridden. |
| 3 | [A strict schema, then render-time guards](#3-a-strict-schema-then-render-time-guards) | A typo or an impossible combination fails before anything reaches the cluster. |
| 4 | [A null means absent](#4-a-null-means-absent) | One rule lets an environment overlay remove what a lower layer set. |
| 5 | [Posture on, integrations off](#5-posture-on-integrations-off) | Production defaults with no configuration; no operator required until asked. |
| 6 | [A chart upgrade never restarts pods](#6-a-chart-upgrade-never-restarts-pods) | Only a change to a component's own values rolls its pods. |
| 7 | [A Job is a hook, and so is everything it needs](#7-a-job-is-a-hook-and-so-is-everything-it-needs) | A migration runs before every deploy, with the new config. |
| 8 | [The 1.0 contract is frozen by CI](#8-the-10-contract-is-frozen-by-ci) | A removed key or a broken upgrade fails the pull request, not a consumer. |
| 9 | [Releases are signed and never overwritten](#9-releases-are-signed-and-never-overwritten) | A version is one digest, with provenance and a signature. |
| 10 | [Tested in a cluster, not only rendered](#10-tested-in-a-cluster-not-only-rendered) | Every pull request installs the chart where Pod Security `restricted` is enforced. |

## 1. One chart, consumed through aliases

- **Problem:** a chart per service is N copies to patch and keep in sync by hand. A library chart shares templates, but
  each consumer still writes its own templates and its own schema, so every umbrella re-implements the same checks,
  or skips them.
- **Decision:** chart-base is an application chart. A domain umbrella declares it once per component, each with its own
  `alias` and `condition: <alias>.enabled`, and configures every component under its alias. Under an alias Helm sets
  `.Chart.Name` to the alias, so every name and selector derives from it, and Helm validates `values.schema.json`
  against each alias's values before it renders anything.
- **Rejected:** a library chart, whose schema never validates the consumer's values; a copy per service, where a fix
  ships N times.
- **Cost:** one umbrella is one Helm release. A domain's components deploy and roll back together, and a bad value in
  one alias blocks the release of the whole domain. chart-base answers by failing at render time, before anything
  reaches the cluster (decision 3).
- **Evidence:** [ADR-0001](adr/0001-application-chart-consumed-through-aliases.md);
  [`templates/_names.tpl`](../templates/_names.tpl) (`chart-base.component` is `.Chart.Name`);
  [`alias-contract.sh`](../.github/scripts/alias-contract.sh) builds a throwaway umbrella with several aliases, one of
  them hyphenated; the first real umbrella, `jellalshadows/domain-boutique`, validated the model before 1.0
  ([1.0.0 criteria](roadmap.md#100-criteria)).

## 2. The alias is the identity

- **Problem:** the name helper of `helm create` truncates to 63 characters and uses the release name alone when it
  already contains the chart name, so two components can collide on one name with no warning. With `nameOverride`,
  two aliases that set the same value render duplicate names that neither `helm lint` nor `helm template` detects. In
  the [comparison](../README.md#how-it-compares), each of the three other generic charts gives two aliases the same
  object names by default, and its Service selects the pods of both.
- **Decision:** every object is named `<release>-<alias>`, with no shortcut and no truncation. A name over 63
  characters (52 for a CronJob or a StatefulSet, whose controllers append a suffix to it) fails the render. There is no
  `nameOverride` or `fullnameOverride`. The selector labels are exactly `app.kubernetes.io/name: <alias>` and
  `app.kubernetes.io/instance: <release>`, and `podLabels` cannot override them.
- **Rejected:** the `helm create` helper; keeping the overrides behind a duplicate check, which a subchart cannot
  implement: it never sees its siblings' values.
- **Cost:** the umbrella author picks a shorter alias or release name; the chart offers no automatic fix. Renaming an
  alias deletes and recreates every one of its objects.
- **Evidence:** [ADR-0008](adr/0008-names-are-release-alias-and-never-truncated.md),
  [ADR-0009](adr/0009-no-name-overrides.md), [ADR-0028](adr/0028-podlabels-cannot-override-selector-labels.md);
  [`templates/validate.yaml`](../templates/validate.yaml); [`tests/validate_test.yaml`](../tests/validate_test.yaml)
  tests the boundaries (63 passes and 64 fails, 52 and 53 for a CronJob); the alias contract checks that no two
  aliases render the same kind and name.

## 3. A strict schema, then render-time guards

- **Problem:** a permissive schema accepts a typo (`replicaz: 3`) and the chart renders its default; nobody finds out
  until the component misbehaves. Some rules no schema can express: a name built from the release and the alias, a
  comparison of two keys, the Kubernetes version floor.
- **Decision:** a hand-written draft-07 `values.schema.json`, with `additionalProperties: false` on every fixed-shape
  object. The rules a schema cannot express are `fail` guards in `templates/validate.yaml`, each message prefixed
  `chart-base[<alias>]:`. Guards fail `helm template`, `helm install` and `helm upgrade` before anything is applied.
  `helm lint` only logs them, because Helm's `fail` does not fail in lint mode (measured on Helm 4.3.0 and 3.22.0), so
  the gate for a deploy's values is `helm template` with the real values, release name and namespace.
- **Rejected:** draft 2020-12, which Helm up to 3.18.4 cannot validate. Guards made fatal under lint: lint renders every
  chart under the release name `test-release`, so a 51-character alias that deploys fine would fail lint with no way
  out.
- **Cost:** the schema is one more file to keep in step with `values.yaml` and the templates. A pipeline that only
  lints misses every guard; the deploy then fails at install, still before anything is applied.
- **Evidence:** [ADR-0011](adr/0011-strict-draft-07-schema.md),
  [ADR-0044](adr/0044-guards-fail-the-render-helm-lint-reports-them.md); [`values.schema.json`](../values.schema.json);
  the unit tests assert that every schema rule and every guard fails with its message
  ([testing guide](guides/testing.md#unit-tests)); [`validate-manifests.sh`](../.github/scripts/validate-manifests.sh)
  renders every `ci/` scenario with `helm template`; the [comparison](../README.md#how-it-compares) shows which charts
  reject an unknown key.

## 4. A null means absent

- **Problem:** environments are values layers: the umbrella's values, then an override file per environment. Helm
  deletes a key set to `null` only when the chart's own `values.yaml` defines it. Elsewhere the `null` reaches the
  schema and fails, so an overlay could not remove what a lower layer set, such as an inherited environment variable.
  Where Helm does delete it, a `null` silently drops a safe default (`serviceAccount.automountToken: null` would mount
  the token).
- **Decision:** one rule, chart-wide since 1.5.0: a `null` on a map entry or on an optional member of a closed object is
  absent. The templates and every guard read a copy pruned by `chart-base.pruneNulls`, so a guard never counts a `null`
  as set. A key whose default protects something is `required`, so its `null` fails instead of flipping the default;
  a key added after 1.0.0 reads its absence as its default instead.
- **Rejected:** adding `null` to each member's type: shorter, but every wrong non-null value would then print
  `want null or string`. Each nullable member is an `if`/`then` pair over the previous schema, which keeps every earlier
  message byte for byte. Pruning the whole values tree once would also reach pass-through objects, whose `null` keys
  render today: a breaking change.
- **Cost:** the schema reads less directly. Three cases keep their earlier rule until a major: a `null` inside a list
  and a `null` on a required key stay errors, and a `null` key inside a pass-through object such as `securityContext`
  still renders as written. Helm 4.3 drops a `null` written in an umbrella's own values, while nothing else is passed
  for the alias, before the schema runs, so the consuming guide documents what a `null` does in each layer.
- **Evidence:** [ADR-0027](adr/0027-required-keys-in-the-schema.md),
  [ADR-0045](adr/0045-null-in-configfiles-and-resources-is-absent.md),
  [ADR-0070](adr/0070-a-null-means-absent-chart-wide.md); [`templates/_values.tpl`](../templates/_values.tpl); the
  alias contract checks each `null` rule in every values layer (the umbrella's own values, an override file, `--set`);
  [what a null does in each values layer](guides/consuming.md#what-a-null-does-in-each-values-layer).

## 5. Posture on, integrations off

- **Problem:** a shared chart's defaults are what most components run. Permissive defaults raise the floor for nobody:
  hardening, a disruption budget and resource requests get skipped under a deadline. Integrations on by default make
  every cluster run every operator, and a chart that gates them on `.Capabilities` hides a missing CRD: the component
  deploys without its route, and no error says so.
- **Decision:** posture is on. Pods meet Pod Security `restricted` and add a read-only root filesystem (with `/tmp` as
  an `emptyDir`), UID 65532 and no ServiceAccount token; `resources.requests` are required; every Deployment and
  StatefulSet gets a PodDisruptionBudget (`maxUnavailable: 1`, `unhealthyPodEvictionPolicy: AlwaysAllow`) and topology
  spread, and a guard rejects a budget that allows no eviction at the replica floor. Each default is lowered key by
  key. Integrations are off: the ExternalSecret, the routes, the Ingress, the Prometheus monitors and rules, KEDA and
  the NetworkPolicy render only with `enabled: true`, and then with no `.Capabilities` gate, so a missing CRD fails the
  install of the whole release before anything is applied.
- **Rejected:** opt-in hardening and budgets; resource presets, which hide the numbers behind a size that is wrong for
  some components; a `.Capabilities` gate with an escape flag.
- **Cost:** an image built to run as root or to write its own filesystem fails until the conflicting field is
  overridden. A new component must guess its requests. A single-replica component loses its pod on every drain.
  NetworkPolicy stays off even where the CNI enforces it, because its rules depend on facts of each cluster.
- **Evidence:** [ADR-0013](adr/0013-secure-by-default.md), [ADR-0014](adr/0014-resource-requests-required.md),
  [ADR-0015](adr/0015-pdb-and-topology-spread-by-default.md),
  [ADR-0062](adr/0062-a-pdb-never-blocks-a-drain-at-the-replica-floor.md),
  [ADR-0012](adr/0012-no-capabilities-gating.md),
  [ADR-0040](adr/0040-networkpolicy-per-component-with-sibling-references.md); the roadmap's
  [principles](roadmap.md#principles); [`e2e.sh`](../.github/scripts/e2e.sh) installs every `ci/` scenario in a
  namespace that enforces `restricted`; in the [comparison](../README.md#how-it-compares), none of the other three
  charts requires requests or renders a budget by default.

## 6. A chart upgrade never restarts pods

- **Problem:** `helm create` puts `helm.sh/chart: <chart>-<version>` on the pod template, so every chart release, even
  a comment fix, rolls every pod of every umbrella that takes it. A config checksum over the whole ConfigMap leaks the
  version the same way, through the ConfigMap's metadata; chart-base had that defect and fixed it in the final review
  before 0.1.0.
- **Decision:** `helm.sh/chart` is on object metadata only, never on a pod template, and the config checksums hash only
  the ConfigMaps' `.data`. A config change rolls the pods through those checksums, inside the deploy, so Helm reports
  a broken config as a failed release. A Secret rotated by External Secrets Operator, and any Secret or ConfigMap the
  component references, changes outside the deploy, so Reloader annotations roll the pods instead.
- **Rejected:** the `helm create` labels; Reloader for everything, because Helm would report success before the
  restart, and the next deploy of the domain would fail on someone else's broken config.
- **Cost:** a running pod does not say which chart version rendered it; that lives on the objects one level up. Before
  1.0, two breaking releases (0.3.0 and 0.12.0) rolled every Deployment once on purpose, and the upgrade guide said
  so; from 1.0, a default that changes the manifest of unchanged values is a major.
- **Evidence:** [ADR-0010](adr/0010-chart-version-never-restarts-pods.md),
  [ADR-0006](adr/0006-checksum-for-config-reloader-for-secrets.md); [`templates/_labels.tpl`](../templates/_labels.tpl),
  [`templates/_reloader.tpl`](../templates/_reloader.tpl); [upgrade guide](upgrading.md); in the
  [comparison](../README.md#how-it-compares), one of the other three charts restarts pods on a chart upgrade alone.

## 7. A Job is a hook, and so is everything it needs

- **Problem:** a Job's pod template is immutable. A plain Job installs once, then the next upgrade with a new image
  fails with `field is immutable` and takes the deploy of the whole release with it. A hook Job alone is not enough:
  if its ConfigMaps and ExternalSecret are ordinary objects, the first install waits on objects that do not exist yet,
  and an upgrade runs the migration with the old config.
- **Decision:** `workload.type: job` renders a Helm hook, before the deploy (`job.phase: pre-deploy`, the default) or
  after it, recreated on every deploy (`before-hook-creation`). Its ServiceAccount, ConfigMaps, ExternalSecret,
  NetworkPolicy, Role, RoleBindings and extra objects are hooks of the same phase at weight `-10`, so they exist, with
  the new content, before the Job's pod starts. A failing pre-deploy Job stops the release before anything else
  changes.
- **Rejected:** a plain Job; a Job named after the release revision, which avoids the immutability error but gives up
  ordering and blocking, the reason to run a migration before the deploy.
- **Cost:** hooks are outside the release's bookkeeping: `helm uninstall` does not remove them, and cleanup relies on
  `job.ttlSecondsAfterFinished`. A broken migration blocks the domain's release, even when the cause is a flaky
  dependency.
- **Evidence:** [ADR-0007](adr/0007-jobs-as-helm-hooks.md),
  [ADR-0041](adr/0041-job-component-networkpolicy-is-a-hook.md), [ADR-0043](adr/0043-job-component-rbac-is-a-hook.md);
  [`templates/_hooks.tpl`](../templates/_hooks.tpl), [`templates/job.yaml`](../templates/job.yaml); the e2e's Job
  reads its ConfigMap, its Secret and a file, then a second deploy must not hit `field is immutable`;
  [`umbrella-lifecycle.sh`](../.github/scripts/umbrella-lifecycle.sh) takes an umbrella with a Job alias through an
  install, a values change, a rollback and an uninstall.

## 8. The 1.0 contract is frozen by CI

- **Problem:** up to 0.11.0 the contract was a set of habits spread over the ADRs. Nothing listed what was frozen, and
  nothing failed when a key disappeared. A new `required` key breaks `helm upgrade --reuse-values`, which renders with
  the previous release's values; five releases before 1.0 did that, each documented as breaking.
- **Decision:** [ADR-0058](adr/0058-the-1-0-contract-and-how-it-stays-frozen.md) lists what is frozen: the two selector
  labels, the object names, the main container's and the chart's volume names, the label and annotation keys the chart
  writes, and every values key. After 1.0 a key is never removed or renamed, a new key is optional, and a changed
  default or a new rejection of values that render is a major. The last breaking changes went into 0.12.0 first,
  among them dropping `app.kubernetes.io/component`, which said `deployment` where Kubernetes means an architectural
  component ([ADR-0063](adr/0063-the-chart-does-not-write-app-kubernetes-io-component.md)). CI enforces the contract
  in three places: unit tests pin the names, the selectors and the label and annotation keys; `contract-keys.sh` fails
  a pull request that removes or renames a values key unless its title marks it breaking; the alias contract renders
  every `ci/` scenario with the `values.yaml` of v1.0.0 and of the previous release as defaults, the shape of a
  `--reuse-values` upgrade.
- **Rejected:** listing the schema's own paths without following `$ref`: renaming an internal definition would fail as
  a removal, and pointing a map at a definition that lacks a key would pass. A snapshot of `values.yaml`: most keys
  have no default, so a removal would pass. Freezing error messages: every clarification would become a major.
- **Cost:** the key list is long and grows with every key, on purpose: its diff shows a reviewer the contract change.
  It cannot see a type change or a narrower rule; the schema tests and the rule above cover those. Odd names stay
  (`externalSecret.envFrom` is a switch, a homonym of the main container's `envFrom`), because a rename breaks every
  values file.
- **Evidence:** [ADR-0058](adr/0058-the-1-0-contract-and-how-it-stays-frozen.md),
  [ADR-0064](adr/0064-from-1-0-0-a-new-key-is-optional.md); [`tests/contract_test.yaml`](../tests/contract_test.yaml),
  [`contract-keys.sh`](../.github/scripts/contract-keys.sh), [`tests/contract/keys.txt`](../tests/contract/keys.txt),
  [`alias-contract.sh`](../.github/scripts/alias-contract.sh); [testing guide](guides/testing.md#the-10-contract). From
  1.0.0 to 1.6.1, no release is a major ([CHANGELOG](../CHANGELOG.md)).

## 9. Releases are signed and never overwritten

- **Problem:** GHCR tags are mutable and `Chart.lock` stores no digest, so a re-pushed version silently changes what
  every umbrella pinned to it deploys. A publisher triggered by tags, or one that guesses the latest tag, can publish
  twice or publish the wrong commit.
- **Decision:** release-please keeps a Release PR open; merging it tags `vX.Y.Z` and publishes in the same run, from
  `refs/tags/<tag>`, in the one job that publishes. That job checks that `Chart.yaml` carries the tag's version,
  refuses a version whose manifest GHCR already serves, packages reproducibly from the tagged commit, attaches SLSA
  provenance (`actions/attest`) and a cosign keyless signature to the digest, and verifies both before it ends. A
  manual run re-publishes a failed tag with the fixed workflow, or only signs a digest that already carries this
  workflow's provenance.
- **Rejected:** a personal access token and a `workflow_run` publisher with a "latest tag" heuristic; a signing key
  pair, which is a secret to store and rotate, and binds the signature to a key instead of the workflow's identity.
- **Cost:** a failure after the push cannot be repaired in place: a version whose attestation failed stays without
  provenance, and the fix is a new patch release. The overwrite check puts GHCR's API on the critical path of every
  release. The signature proves which workflow signed the digest, not that the content is safe.
- **Evidence:** [ADR-0020](adr/0020-release-please-and-publish-in-one-workflow.md),
  [ADR-0022](adr/0022-provenance-with-actions-attest.md), [ADR-0029](adr/0029-publishing-built-for-recovery.md),
  [ADR-0034](adr/0034-keyless-cosign-signatures.md); [`release.yaml`](../.github/workflows/release.yaml);
  [`release-signing.sh`](../.github/scripts/release-signing.sh) verifies a real signed release in CI and refuses a wrong
  identity, a missing bundle type and a bad digest; the [verify commands](../README.md#versioning-and-releases); the
  [re-publish runbook](runbooks/republish-a-tag.md).

## 10. Tested in a cluster, not only rendered

- **Problem:** a green unit suite proves what the templates render, not what a cluster accepts. helm-unittest embeds
  its own Helm engine, so it says nothing about Helm 4, and no render shows Pod Security admission, NetworkPolicy
  enforcement, RBAC or an operator's webhook.
- **Decision:** layers, each proving what the others cannot: 1,700+ helm-unittest cases, including a negative case for
  every schema rule and guard and a snapshot per `ci/` scenario; `helm lint --strict` on Helm 3.22 and 4.3;
  kubeconform for Kubernetes 1.33 and 1.37; the alias and 1.0 contracts; every README recipe rendered and validated.
  Then, on kind with Kubernetes 1.33 and 1.37, every scenario is installed in a namespace that enforces `restricted`,
  next to the Gateway API CRDs, External Secrets Operator, the Prometheus Operator CRDs and KEDA; kindnet enforces the
  NetworkPolicies, `kubectl auth can-i` checks the RBAC, and an umbrella is installed, changed, rolled back and
  uninstalled. One required check, `ci-ok`, depends on every job.
- **Rejected:** chart-testing (`ct`): its last release predates Helm 4, and its version-bump check fights
  release-please, the tool that bumps the version.
- **Cost:** what `ct` gives by configuration is hand-written shell here, maintained by hand; the kind versions and node
  image digests are bumped by hand, outside Renovate. The e2e needs kind and a container runtime; the unit tests and
  lint run without one.
- **Evidence:** [ADR-0019](adr/0019-helm-4-first-helm-3-tested.md), [ADR-0023](adr/0023-no-chart-testing.md);
  [testing guide](guides/testing.md#overview); [`ci.yaml`](../.github/workflows/ci.yaml),
  [`e2e.sh`](../.github/scripts/e2e.sh), [`readme-recipes.sh`](../.github/scripts/readme-recipes.sh); before 1.0.0, a
  validation campaign against the published 0.12.0, on Kubernetes 1.33.12 and 1.37.0 with Helm 3.22.0 and 4.3.0, found
  no defect of the chart ([1.0.0 record](releases/1.0.0.md)).

## What chart-base leaves out

Each of these is left out on purpose; the [roadmap](roadmap.md#out-of-scope) gives every reason, and
[Waits for a major](roadmap.md#waits-for-a-major) lists the changes held for the next major.

- **Workload kinds beyond Deployment, StatefulSet, CronJob and Job.** A DaemonSet conflicts with Pod Security
  `restricted`.
- **Several workloads or several Services per alias.** They break the one-workload-per-alias model that decision 2
  rests on.
- **A second path for secrets.** No SealedSecrets, plain Secrets or SecretProviderClass: the chart creates Secrets
  through External Secrets Operator only, and references existing ones by name
  ([ADR-0004](adr/0004-env-in-configmap-secrets-through-externalsecret.md)).
- **Cluster-scoped RBAC.** No ClusterRole or ClusterRoleBinding: a component binds existing ClusterRoles in its own
  namespace, never `cluster-admin` ([ADR-0042](adr/0042-existing-serviceaccount-and-namespaced-rbac.md)).
- **The platform around the workload.** No cert-manager Certificate (TLS terminates at the Gateway), no chart-created
  PersistentVolumeClaim for a Deployment (a StatefulSet gets a claim per pod,
  [ADR-0071](adr/0071-a-statefulset-workload-type-with-a-claim-per-pod.md)), no Helm tests (the e2e already validates
  the chart, and Argo CD does not run them).
- **Escape hatches that would undo a decision above.** No `nameOverride` or `fullnameOverride`, no `.Capabilities`
  gating, no resource presets, no `diagnosticMode` (`kubectl debug` covers it). For an object the chart does not
  render, `extraObjects` renders it as written, named `<release>-<alias>.<key>`
  ([ADR-0057](adr/0057-common-labels-and-annotations-service-annotations-and-extraobjects.md)).
