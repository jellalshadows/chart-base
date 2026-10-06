# ADR-0044: Guards fail the render; `helm lint` reports them without failing

- **Status:** Accepted
- **Date:** 2026-10-06
- **Since:** 0.6.0 (recorded with 0.6.0; Helm has behaved this way for every release since 0.1.0)
- **Related:** [ADR-0001](0001-application-chart-consumed-through-aliases.md) (amended), [ADR-0008](0008-names-are-release-alias-and-never-truncated.md), [ADR-0011](0011-strict-draft-07-schema.md) (amended), [ADR-0018](0018-kubernetes-version-floor.md) (amended), [ADR-0027](0027-required-keys-in-the-schema.md) (amended), [ADR-0036](0036-rollout-and-runtime-knobs-are-validated-pass-throughs.md) (amended), [ADR-0042](0042-existing-serviceaccount-and-namespaced-rbac.md)

## Context

chart-base checks the values in two layers ([ADR-0011](0011-strict-draft-07-schema.md)): `values.schema.json`, and
the `fail` guards of `templates/validate.yaml` for the rules a schema cannot express (names and their length, the
Kubernetes floor, combinations of keys). Several records and guides said that both layers fail `helm lint`. Measured
with Helm 4.3.0 and 3.22.0, the guards do not:

- **In lint mode a guard is a log line.** With `autoscaling: {enabled: true, minReplicas: 5, maxReplicas: 2}`, a guard
  of 0.1.0 that does not depend on the release name, `helm lint --strict` prints the guard's message and exits 0. The
  first and the last line of its output, on Helm 4.3.0 and then on Helm 3.22.0:

  ```text
  level=INFO msg="funcMap fail" message="chart-base[chart-base]: autoscaling.minReplicas must be <= autoscaling.maxReplicas"
  1 chart(s) linted, 0 chart(s) failed
  engine.go:227: [INFO] Fail: chart-base[chart-base]: autoscaling.minReplicas must be <= autoscaling.maxReplicas
  1 chart(s) linted, 0 chart(s) failed
  ```

  Through an umbrella alias `api` the lines name `chart-base[api]` and lint still exits 0. A guard of 0.6.0
  (`serviceAccount.name` with `create: true`) and every other guard tried (`configFiles.mountPath: /tmp`, `maxSurge`
  and `maxUnavailable` both 0, `cluster-admin`, a ClusterRole without a token, a name-restricted `create`) behave the
  same, single chart and through the alias. `helm template` with the same values fails on both versions, for example
  `Error: execution error at (vending/charts/api/templates/validate.yaml:22:4): chart-base[api]:
  autoscaling.minReplicas must be <= autoscaling.maxReplicas`. The lines come from Helm's template engine: its `fail`
  checks lint mode first ("Don't fail when linting"), logs the message and returns no error, so the render goes on
  (`pkg/engine/engine.go` at v4.3.0 and v3.22.0).
- **Schema errors fail lint, with one gap through an umbrella.** Linting the chart directly, an unknown key, a reserved
  `podLabels` key and `serviceAccount.automountToken: null` fail `helm lint --strict` on both versions
  (`Error: 1 chart(s) linted, 1 chart(s) failed`). Through an umbrella, an unknown key, a wrong type and a missing key
  under an alias fail it too, but a `null` that deletes a required key (`api.serviceAccount.automountToken: null`,
  `api.rbac: null`) passed lint on both versions when it came from a `-f` file, where `helm template` rejects it
  (`missing property 'automountToken'`, `missing property 'rbac'`). From the umbrella's own `values.yaml`, Helm 3.22.0
  rejects it in lint and template alike, and Helm 4.3.0 ignores the `null` (the chart's default stays), so neither
  fails.
- **Lint renders under a placeholder release name.** Lint always uses the release name `test-release`
  ([ADR-0008](0008-names-are-release-alias-and-never-truncated.md); `helm lint --help` offers no flag to change it, on
  either version), so the messages read `... always named test-release-api ...`, and the name guards judge a name the
  deploy never uses. Measured on both versions: an umbrella `shop` whose alias has 51 characters renders under its
  release name (`shop-<alias>`, 56 characters), while `helm lint --strict` prints
  `resource name "test-release-<alias>" is 64 chars, max is 63` as an INFO line.
- **Install and upgrade fail like `helm template`.** Helm renders every template before it creates anything
  ([ADR-0012](0012-no-capabilities-gating.md)). Measured with Helm 4.3.0's `helm install --dry-run=client`, without a
  cluster: `Error: INSTALLATION FAILED: execution error at (chart-base/templates/validate.yaml:108:4): ...`. Helm
  3.22.0's client dry run needs a reachable cluster, so it was not run there; no cluster was used for this record.
- **This repository's CI does not rely on lint for guards.** The `lint` job's `validate-manifests.sh` renders every
  `ci/` scenario with `helm template vending ... --namespace vending` under `set -euo pipefail`, the alias contract
  renders its umbrella with `helm template`, and the unit tests (`tests/validate_test.yaml`) assert the guards'
  messages. None of the six `ci/` scenarios prints a guard's INFO line under lint (measured on both versions).

## Decision

- The guards stay `fail` calls in `templates/validate.yaml`, through `chart-base.fail`
  ([ADR-0011](0011-strict-draft-07-schema.md)). They fail `helm template`, `helm install` and `helm upgrade` before
  anything is applied; `helm lint` reports each one as an INFO line (`funcMap fail` on Helm 4, `[INFO] Fail:` on
  Helm 3) and does not fail. The chart does not work around lint mode.
- The gate for a deploy's values is `helm template` with the deploy's real values, release name and `--namespace`
  (the RoleBindings' subject carries the namespace, [ADR-0042](0042-existing-serviceaccount-and-namespaced-rbac.md)),
  with every component enabled. A `helm install` or `helm upgrade` with `--dry-run=server` against the cluster renders
  the same templates first (not measured here).
- `helm lint --strict` stays in CI and in the guides for what it does check: the schema, with the umbrella gap above,
  and the chart's own structure. An INFO line with a guard's message in a lint log is a guard that fails the render
  with those values under the release name `test-release`.

## Consequences

- A pipeline that only lints misses every guard failure. The deploy then fails at `helm install` or `helm upgrade`,
  with the guard's message and before anything is applied: nothing broken reaches the cluster, but the failure comes
  later than it could.
- Consumers are told to gate on `helm template`, which also covers the `null` that lint misses through an umbrella
  ([consuming guide](../guides/consuming.md#failure-behavior)).
- A lint log can show a guard's INFO line for a values file that deploys fine, because lint renders under
  `test-release`: a long alias, for example.
- The records that said a guard fails at `helm lint` are amended by this one:
  [ADR-0001](0001-application-chart-consumed-through-aliases.md), [ADR-0011](0011-strict-draft-07-schema.md),
  [ADR-0018](0018-kubernetes-version-floor.md) and
  [ADR-0036](0036-rollout-and-runtime-knobs-are-validated-pass-throughs.md). So is
  [ADR-0027](0027-required-keys-in-the-schema.md), which says that a `null` deleting a required key fails `helm lint`:
  true for the chart linted directly, but through an umbrella a `null` from a `-f` file passes lint, and
  `helm template` catches it (the gap above). Their statements about the schema stay true for a chart linted
  directly, and so do those of [ADR-0028](0028-podlabels-cannot-override-selector-labels.md), which is not amended.

## Alternatives considered

### Making the guards fatal under lint

`chart-base.fail` could follow the `fail` with an `include` of a template that does not exist: lint mode keeps going
after `fail`, and the missing template is an error that fails lint. Measured on both versions with that change in a
copy of the chart: lint fails on a guard, and also fails the 51-character alias above, which deploys fine under its
real release name. Lint always renders under `test-release`, and a consumer cannot give it another name, so every
umbrella with a long alias would fail lint with no way out. The trick also depends on how Helm's lint mode treats
`fail`, an internal detail.

### Checking guards in the schema instead

The guards exist because a draft-07 schema cannot express them: a name built from the release name and the alias, a
comparison of two keys, the Kubernetes version ([ADR-0011](0011-strict-draft-07-schema.md)).

## References

- Helm v4.3.0 and v3.22.0 `pkg/engine/engine.go` (lint mode's `fail`); v4.3.0 `pkg/chart/v2/lint/rules/template.go`
  and v3.22.0 `pkg/lint/rules/template.go` (`Name: "test-release"`)
  (https://github.com/helm/helm/tree/v4.3.0/pkg, https://github.com/helm/helm/tree/v3.22.0/pkg)
- `templates/validate.yaml`, `templates/_names.tpl` (`chart-base.fail`), `.github/scripts/validate-manifests.sh`,
  `.github/scripts/alias-contract.sh`, `tests/validate_test.yaml`, `.github/workflows/ci.yaml` (job `lint`)
