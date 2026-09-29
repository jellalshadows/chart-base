# Renovate

**When to use:** reviewing a Renovate pull request, bumping something Renovate does not track, tracking a new tool, or finding out why Renovate opens nothing.

## Prerequisites

- Write access to `jellalshadows/chart-base` and `gh` authenticated.
- The Renovate GitHub app installed on the repository, configured by `.github/renovate.json` ([ADR-0024](../adr/0024-renovate.md)).

## What Renovate manages here

`.github/renovate.json` extends `config:best-practices` and `customManagers:githubActionsVersions`, with semantic commits enabled.

- **Actions:** `config:best-practices` pins every `uses:` reference to a commit SHA with the version as a trailing comment (`# vX.Y.Z`), in `ci.yaml` and `release.yaml`.
- **Tool versions:** the `*_VERSION` environment variables that have a `# renovate:` comment directly above them.
  In `ci.yaml`: `HELM_VERSION`, `HELM_UNITTEST_VERSION`, `KUBECONFORM_VERSION`, `HELM_DOCS_VERSION`,
  `ACTIONLINT_VERSION`, `LYCHEE_VERSION`, `GATEWAY_API_VERSION` and `ESO_CHART_VERSION`
  (the External Secrets Operator chart and the Gateway API CRDs used by the e2e). `release.yaml` tracks `HELM_VERSION` too.
- **Cadence:** one `ci tooling` group (`packageRules`, for the `github-actions` and `custom.regex` managers): one pull request, only for releases older than 7 days (`minimumReleaseAge`), scheduled `before 6am on monday`.

## What Renovate does not manage

Nothing pings you about these; check them by hand from time to time.

- The Helm 3 entry of the `lint` job matrix in `ci.yaml` (`helm: [v3.22.0, v4.3.0]`). Its **4.x entry must equal `HELM_VERSION`**: when a Renovate PR bumps `HELM_VERSION`, edit the matrix entry in that same PR.
- The `kind` versions and the digest-pinned `node_image` values of the `e2e` matrix in `ci.yaml`.
- The commit SHAs of the schema sources in `.github/scripts/validate-manifests.sh` (`k8s_schemas` and `crd_schemas`): they are raw URLs, which Renovate does not track.

## Reviewing a Renovate pull request

1. Read the PR body: which tools and actions change, and the release notes linked from it.
2. Wait for CI. **Every check must be green, including the `e2e` jobs on kind**; a green `lint` alone is not enough for a Helm or Gateway API bump.
   ```bash
   gh pr checks <number> --repo jellalshadows/chart-base
   ```
3. A Helm bump touches both `ci.yaml` and `release.yaml` (both declare `HELM_VERSION` with a `# renovate:` comment). Confirm both changed to the same version, and that the `lint` matrix 4.x entry matches it (see above).
4. Read the release notes of anything that runs in the release path (Helm, `actions/attest`, `actions/create-github-app-token`, `release-please-action`): a broken release is harder to recover than a broken CI ([re-publish runbook](republish-a-tag.md)).
5. Squash-merge it. The title is already a conventional commit (semantic commits), typically `chore(deps): ...`, so it does not cause a release.

## Bumping kind by hand

1. Open the release notes of the new kind version. They list the node images built for it with their digests.
2. For each Kubernetes version of the `e2e` matrix (`kubernetes: "1.33"` and `"1.37"` at the time of writing), set `kind:` to the kind release that supports it and `node_image:` to `kindest/node:vX.Y.Z@sha256:<digest>`, taking the digest from the release notes of that kind release.
3. Open a pull request (`ci:` type) and require the `e2e` jobs to pass.

The Kubernetes patch versions in `validate-manifests.sh` calls in the `lint` job (for example `1.33.12`) should follow the node images.

## Tracking a new tool

1. Declare the version as an environment variable named `*_VERSION` in the workflow, with a comment on the line directly above it:
   ```yaml
   # renovate: datasource=github-releases depName=<owner>/<repo>
   TOOL_VERSION: v1.2.3
   ```
2. If the upstream tags are not plain versions, add `extractVersion` with a named group `version`. The existing example is `LYCHEE_VERSION` in `ci.yaml`:
   ```yaml
   # renovate: datasource=github-releases depName=lycheeverse/lychee extractVersion=^lychee-(?<version>.+)$
   LYCHEE_VERSION: v0.24.2
   ```
3. Use the variable in the download URL, and keep verifying the checksum as the other tools do.
4. Update [ADR-0024](../adr/0024-renovate.md) if the list of tracked variables changes. See the [Renovate documentation](https://docs.renovatebot.com/) for the `datasource` values.

## Verification

- The next Monday run opens (or updates) the `ci tooling` pull request, and its diff only changes SHAs, comments and `*_VERSION` values.
- `gh pr list --repo jellalshadows/chart-base --search "in:title deps"` shows Renovate pull requests (or none, when everything is current).

## If something goes wrong

- **No Renovate pull requests at all:** check that the Renovate app is installed on the repository (repository *Settings* -> *GitHub Apps*), then read the job logs of the repository in the Mend developer portal (developer.mend.io). Also confirm that `.github/renovate.json` is valid JSON.
- **An update you expected does not appear:** the Dependency Dashboard issue (part of `config:best-practices`) lists pending, rate-limited and awaiting-schedule updates (and `minimumReleaseAge` holds back releases younger than 7 days).
- **A tool is not updated:** its `# renovate:` comment must be on the line directly above the `*_VERSION` variable, with a valid `datasource` and `depName`.
- **A Renovate bump breaks CI:** do not merge; close it or fix the cause in the PR.

## Related

- [ADR-0024: Renovate for actions and tool versions](../adr/0024-renovate.md)
- [ADR-0019: Helm 4 first, Helm 3 tested](../adr/0019-helm-4-first-helm-3-tested.md)
- [Cutting a release](release.md)
