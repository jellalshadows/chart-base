# ADR-0023: No chart-testing (`ct`)

- **Status:** Accepted
- **Date:** 2026-09-27
- **Since:** 0.1.0

## Context

`chart-testing` (`ct`) is the community-standard tool for CI on a Helm chart: `ct lint` and `ct install`
auto-discover changed charts in a repository and run `helm lint`/a real install against them, and
`ct lint`'s version-increment check (`check-version-increment`) is a "did you bump the version" gate
before merge.

That last part actively conflicts with how chart-base is versioned: `Chart.yaml`'s version is bumped
exclusively by release-please, from conventional commits, *after* a PR merges — never by the PR author
before merge (ADR-0020, ADR-0021). A version-bump gate at PR time would either be redundant with
release-please or, worse, fail every correctly-written PR for not bumping a version nothing but
release-please is supposed to touch.

`ct`'s own release cadence adds a second, independent reason: its most recent release, `v3.14.0`, was
published 2025-10-08 (per `github.com/helm/chart-testing`'s own release history), which predates Helm
`v4.0.0`'s general availability on 2025-11-12 (`github.com/helm/helm`) — `ct` therefore ships with no
explicit stance on Helm 4 at all, a real risk to depend on for a chart that targets Helm 4 first
(ADR-0019) and validates on both major versions in the same CI matrix.

## Decision

- `.github/workflows/ci.yaml`'s `lint` job runs `helm lint --strict . -f "$values"` for every
  `ci/*-values.yaml` scenario, across a matrix of `helm: [v3.22.0, v4.3.0]` (the `v4.3.0` entry is kept
  equal to `HELM_VERSION` by hand; the matrix comment says so explicitly).
- The same job runs `.github/scripts/validate-manifests.sh . 1.33.12` and `... 1.37.0` — kubeconform against
  pinned Kubernetes 1.33/1.37 schemas — and `.github/scripts/alias-contract.sh .`, which builds a throwaway
  umbrella and checks the guarantees `ct install` would otherwise stand in for indirectly: no duplicate
  `(kind, name)`, names are `<release>-<alias>`, each alias's own `values.schema.json` is applied (with a
  negative case that must fail), `global`/`enabled` are tolerated, and `enabled: false` disables a
  component.
- A real cluster install happens too, in the separate `e2e` job, via `.github/scripts/e2e.sh` against kind
  (Kubernetes 1.33 and 1.37), not through `ct install`.
- No `chart-testing` dependency exists anywhere in the workflows or scripts.

## Consequences

- CI is never blocked by a version-bump check that would fight the one tool actually responsible for
  bumping the version.
- CI exercises the exact Helm versions chart-base targets (3.22.0 and 4.3.0) instead of whatever `ct` bundles
  or supports internally.
- Trade-off: chart-base gives up `ct`'s ready-made, zero-configuration "discover every changed chart and lint
  and install it" convenience and the shared familiarity that comes with a widely-used community tool; the
  equivalent coverage (per-scenario lint matrix, the alias contract script, kind-based e2e) has to be
  hand-written and hand-maintained instead of configured.

## Alternatives considered

### `ct lint` / `ct install`

Its last release predates Helm 4's GA by about a month and takes no explicit position on Helm 4 support, a
poor fit for a Helm-4-first chart; its version-bump check (`check-version-increment`) is designed around exactly the
workflow chart-base does not use — a version bumped by the PR author before merge — and would either be
redundant or would actively fail correct PRs.

## References

- `.github/workflows/ci.yaml` (`lint`, `e2e` jobs)
- `.github/scripts/alias-contract.sh`, `.github/scripts/validate-manifests.sh`, `.github/scripts/e2e.sh`
- [chart-testing releases](https://github.com/helm/chart-testing/releases)
- [Helm v4.0.0](https://github.com/helm/helm/releases/tag/v4.0.0)
