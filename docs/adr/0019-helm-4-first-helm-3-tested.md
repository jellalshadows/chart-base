# ADR-0019: Helm 4 first, Helm 3.22 still tested

- **Status:** Accepted
- **Date:** 2026-09-27
- **Since:** 0.1.0

## Context

chart-base has to pick a primary Helm version to develop and release against, while still being usable
by consumers who have not yet moved off Helm 3. Helm 3 continues to receive security fixes only until
2027-02-10; after that date a consumer still on Helm 3 gets no further patches at all, which makes Helm
3 a version chart-base can still support for now but should not treat as its primary target going
forward. Helm 4 is where new capabilities land, so it is the version everything is authored and released
against (nothing in the chart requires it: the draft-07 schema of ADR-0011 works on every Helm 3 and
Helm 4 release); Helm 3.22.0 stays in CI specifically
to catch a regression that would otherwise only surface for a consumer still on it.

`azure/setup-helm`, the action CI uses to install Helm, resolves an unpinned `latest` version to
whatever the latest Helm release is, and when it cannot fetch that answer it falls back to a
version built into the action (`v3.18.4` in `v5.0.1`) with only a warning in the log. A workflow that relies on `latest` for "the
current Helm" can end up testing a materially older Helm than intended, with no visible change to the
workflow file itself.

## Decision

- Helm **4.3.0** is chart-base's primary version (`HELM_VERSION: v4.3.0`, `.github/workflows/ci.yaml`):
  the `unittest` job (`helm unittest --strict`) and the `e2e` job (real installs on kind, both
  Kubernetes 1.33 and 1.37) both run on it, and it is the version releases are cut and published with.
- The `lint` job additionally runs its entire matrix — `helm lint --strict` of every `ci/` scenario,
  the kubeconform validation on Kubernetes 1.33/1.37, and the alias contract
  (`.github/scripts/alias-contract.sh`) — twice, once on Helm **3.22.0** and once on Helm **4.3.0**
  (`matrix.helm: [v3.22.0, v4.3.0]`, `.github/workflows/ci.yaml`), so every one of those checks is
  proved on both major versions on every PR, not only on the primary one.
- Helm 3 only receives security fixes until **2027-02-10**; chart-base keeps testing against 3.22.0
  while that support window is still open, rather than dropping Helm 3 the moment Helm 4 becomes
  primary.
- Every `azure/setup-helm` step in the workflow pins an explicit version (`v5.0.1` for the action
  itself, `env.HELM_VERSION` or `matrix.helm` for the Helm version it installs) — never `latest` — so
  CI always installs the exact Helm version the job intends, regardless of what the action's own
  default currently resolves to.

## Consequences

- Every release is built, unit-tested and end-to-end tested on the primary version chart-base actually
  targets going forward (Helm 4.3.0), while the `lint` job still proves compatibility with the Helm 3
  release consumers who have not upgraded yet are most likely to run.
- Trade-off: the `lint` job's Helm 3.22.0 run is `helm lint`/`helm template` + kubeconform + the alias
  contract only — it does not repeat the `unittest` suite or the real kind installs of `e2e` on Helm 3.
  A behavioral difference between Helm 3 and Helm 4 that only shows up in `helm unittest`'s rendering or
  in a real cluster install (rather than in linting, static validation, or the alias contract) would not
  be caught for Helm 3 specifically.
- Maintaining a two-version matrix in the `lint` job is recurring cost: every change to that job's steps
  has to keep working on both Helm versions, and Renovate does not track the matrix
  (`matrix.helm: [v3.22.0, v4.3.0]`) at all: both entries are pinned by hand, and the 4.x entry must
  be kept equal to `HELM_VERSION`, which Renovate does bump.

## Alternatives considered

### Helm 3 only

Would keep developing and releasing against a major version that stops receiving even security
fixes on 2027-02-10 with no plan to move off it, and would leave chart-base's primary target one
major version behind the Helm that consumers are moving to.

### Helm 4 only (drop Helm 3 entirely)

Would cut off every consumer still on Helm 3 immediately, rather than for the remainder of its security
support window — a real cost for anyone who has not yet had the chance to upgrade their own tooling and
CI, for no correctness benefit to chart-base itself (nothing in the chart requires Helm 4 to render or
install correctly; Helm 4 is a target, not a hard dependency, in this decision).

## References

- `.github/workflows/ci.yaml` (`HELM_VERSION`, `lint` job's `matrix.helm`, `azure/setup-helm` steps)
- `.github/workflows/release.yaml` (publishes with `HELM_VERSION: v4.3.0`)
