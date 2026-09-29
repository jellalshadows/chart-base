# ADR-0024: Renovate for actions and tool versions

- **Status:** Accepted
- **Date:** 2026-09-27
- **Since:** 0.1.0

## Context

Workflow hygiene pins every `uses:` action reference to a commit SHA rather than a floating tag, which is the safe default against a tag being moved after the fact — but it also means nothing
updates those pins unless something watches upstream releases and rewrites them; hand-maintaining SHA pins
across two workflow files rots quickly.

A second, entirely separate set of versions lives inside those same workflows as plain `*_VERSION`
environment variables (`HELM_VERSION`, `HELM_UNITTEST_VERSION`, `KUBECONFORM_VERSION`, `HELM_DOCS_VERSION`,
`ACTIONLINT_VERSION`, `LYCHEE_VERSION`, `GATEWAY_API_VERSION`, `ESO_CHART_VERSION`): binaries the workflow
downloads and checksum-verifies by hand, or a Gateway API/ESO CRD version applied for e2e. Dependabot's
GitHub Actions ecosystem only understands `uses:` references — it has no mechanism at all for a version
baked into an env var, no matter how it is commented.

The project has one maintainer, so a single, predictable, low-noise cadence matters more than speed:
picking up a same-day release before problems have had a chance to surface upstream is a worse trade than
waiting a few days and reviewing everything at once.

## Decision

- `.github/renovate.json` extends `config:best-practices` ("best practices from the Renovate maintainers"),
  which pins every GitHub Action to a commit SHA and keeps the version as a trailing comment
  (`uses: owner/action@<sha> # vX.Y.Z`, the form used in both workflows), and `customManagers:githubActionsVersions`, whose own description is "Update `_VERSION` environment
  variables in GitHub Action files" — the exact mechanism the `*_VERSION` vars above rely on.
- A single `packageRules` entry applies to `matchManagers: ["github-actions", "custom.regex"]`:
  `groupName: "ci tooling"`, `minimumReleaseAge: "7 days"`, `schedule: ["before 6am on monday"]` — every
  update this configuration produces, whether an action's pinned SHA or a custom-managed tool version, lands
  in one weekly, grouped pull request, and only once the target release is at least a week old.
- The custom manager reads the `# renovate: datasource=... depName=...` comment placed directly above each
  tracked variable and updates the value it comments on: `HELM_VERSION` (declared identically in both
  `release.yaml` and `ci.yaml`) and, in `ci.yaml` only, `HELM_UNITTEST_VERSION`, `KUBECONFORM_VERSION`,
  `HELM_DOCS_VERSION`, `ACTIONLINT_VERSION`, `LYCHEE_VERSION`, `GATEWAY_API_VERSION`, `ESO_CHART_VERSION`.
- Deliberately **not** tracked by Renovate, bumped by hand instead — the code comments in `ci.yaml` say so
  explicitly: the Helm 3.22.0 entry of the `lint` job's matrix (`helm: [v3.22.0, v4.3.0]`, whose 4.x entry
  must also be kept equal to `HELM_VERSION` by hand), and the `e2e` job's `kind` versions together with
  their digest-pinned `node_image` values.

## Consequences

- SHA-pinned actions and the tool versions declared next to them stay current without anyone editing two
  workflow files by hand every time an upstream tool ships a release.
- One grouped weekly PR, instead of a stream of individual bump PRs, keeps the review burden manageable for
  a single maintainer.
- Trade-off: the four values explicitly excluded from Renovate's coverage (the Helm 3 matrix entry, its
  paired 4.x value, the `kind` versions, the node image digests) are exactly the ones nothing pings the
  maintainer about — Renovate's weekly PR can create a false sense that "dependencies are handled" while
  these keep drifting silently until someone remembers to check them by hand.

## Alternatives considered

### Dependabot

Its `github-actions` ecosystem updates only the `uses:` reference itself; it has no equivalent to a custom
regex manager, so every `*_VERSION` env var here would still need a human to notice and bump it by hand —
solving only half the problem this decision addresses.

### Updating everything by hand

The exact rot this decision exists to prevent: a SHA pin or a tool version that nobody remembers to revisit
until something breaks because of it.

## References

- `.github/renovate.json`
- `.github/workflows/ci.yaml`, `.github/workflows/release.yaml` (`# renovate:` comments; the "Not tracked by
  Renovate" comments in the `lint` and `e2e` jobs)
- [Renovate: `config:best-practices`](https://docs.renovatebot.com/presets-config/)
- [Renovate: `customManagers:githubActionsVersions`](https://docs.renovatebot.com/presets-customManagers/)
