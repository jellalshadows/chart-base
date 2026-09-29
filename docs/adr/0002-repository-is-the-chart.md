# ADR-0002: The repository is the chart

- **Status:** Accepted
- **Date:** 2026-09-27
- **Since:** 0.1.0

## Context

chart-base is a single-chart repository: there is exactly one chart, versioned once, published
once. Nothing else in the repository is a second artifact competing for a version number or a
release. The repository root holds `Chart.yaml`, `values.yaml`, `values.schema.json` and
`templates/` directly, with no `charts/` directory and no committed `examples/` umbrella to
exercise the alias consumption model.

Packaging a Helm chart always includes every file under the chart directory except what
`.helmignore` excludes. For a repository whose root *is* the chart, that means CI configuration,
test fixtures and long-form documentation sources have to be excluded explicitly, or they end up
inside the `.tgz` that consumers pull from GHCR. `.helmignore` in this repository excludes VCS and
CI files (`.git/`, `.gitignore`, `.gitattributes`, `.github/`, `.superpowers/`), test and CI
scenario directories (`tests/`, `ci/`), the documentation sources and release tooling
(`docs/`, `README.md.gotmpl`, `release-please-config.json`, `.release-please-manifest.json`),
editor files (`*.swp`, `*.bak`, `*.tmp`, `.idea/`, `.vscode/`) and `dist/`. The package keeps
`README.md`, `CHANGELOG.md`, `LICENSE` and `.helmignore` itself; a consumer can read the README with
`helm show readme` and `Chart.yaml` with `helm show chart` without cloning the repository.

release-please tracks exactly one package, `.` (the repository root), in
`release-please-config.json`. Its `exclude-paths` — `.github`, `tests`, `ci`, `docs` — keeps commits
that only touch CI configuration, test fixtures or documentation from ever opening or updating a
Release PR, so a docs-only or CI-only commit never triggers a release. The alias consumption model
(ADR-0001) is still verified in CI, but through a throwaway umbrella chart built on the fly by
`.github/scripts/alias-contract.sh`, not through a committed example that would live under
`charts/` or `examples/` and have to be kept in sync with every schema change by hand.

## Decision

- The chart lives at the repository root: `Chart.yaml`, `values.yaml`, `values.schema.json` and
  `templates/` are top-level, with no `charts/` subdirectory and no committed example umbrella.
- `.helmignore` excludes from the packaged `.tgz`: `.git/`, `.gitignore`, `.gitattributes`,
  `.github/`, `.superpowers/`, `tests/`, `ci/`, `docs/`, `README.md.gotmpl`,
  `release-please-config.json`, `.release-please-manifest.json`, editor files (`*.swp`, `*.bak`,
  `*.tmp`, `.idea/`, `.vscode/`) and `dist/`. The package keeps `README.md`, `CHANGELOG.md`,
  `LICENSE` and `.helmignore` itself.
- `release-please-config.json` tracks a single package (`"."`) with
  `"exclude-paths": [".github", "tests", "ci", "docs"]`, so commits touching only those paths never
  produce a Release PR or a release.
- The alias contract is exercised against a throwaway umbrella built by
  `.github/scripts/alias-contract.sh` in CI, not against a chart committed to the repository.

## Consequences

- One artifact, one version, one place to look: there is never a question of which chart in the
  repository a change affects.
- The trade-off: without a committed example umbrella, a consumer has to read the README's quick
  start and recipes (or the alias contract script) to see the consumption model in practice; there
  is no runnable example chart in the repository to `helm template` directly.
- Docs and CI changes are release-neutral: a maintainer can improve documentation or CI without
  cutting a chart version, but must also remember that `docs/` and CI changes never bump the
  version even when they are user-facing (e.g. a correction to a guide under `docs/`).

## Alternatives considered

### `charts/chart-base/`

The multi-chart repository convention, where `charts/` holds one or more chart directories. It adds
a directory level with no benefit for a repository that will only ever contain one chart, and it
would require `.helmignore` and `release-please-config.json` paths to account for the extra nesting
for no gain.

### A committed `examples/` umbrella

An example umbrella chart in the repository drifts from the real schema the moment a key is added,
renamed or made required, unless someone remembers to update it in the same PR — and CI already
builds an equivalent throwaway umbrella on the fly (`.github/scripts/alias-contract.sh`) from the
current chart files. Its values are hard-coded in the script, so when a schema change makes them
stale the script fails CI instead of the drift going unnoticed.

## References

- `.helmignore`
- `release-please-config.json`
- `.github/scripts/alias-contract.sh`
- [ADR-0003](0003-oci-on-ghcr.md)
