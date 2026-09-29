# Cutting a release

**When to use:** every release, from merged pull requests to a package verified on GHCR.

## Prerequisites

- Write access to `jellalshadows/chart-base` (to review and merge the Release PR).
- [`gh`](https://github.com/cli/cli) authenticated, and `helm` to pull the package.
- Nothing is published from a laptop: the `Release` workflow does everything ([ADR-0020](../adr/0020-release-please-and-publish-in-one-workflow.md)).

## How the version is decided

Conventional commits, squash-merged with the PR title as the commit message, decide the bump. Before 1.0
(`bump-minor-pre-major: true`, `bump-patch-for-minor-pre-major: false` in `release-please-config.json`):

| Commit type | Bump |
| --- | --- |
| `fix:` | patch |
| `feat:` and `feat!:` | minor (never major before 1.0) |
| `perf:`, `revert:` | patch (release-please's default changelog sections include them) |
| `docs:`, `chore:`, `ci:`, `test:`, `refactor:` | no release |
| any commit that only touches an excluded path (`.github`, `tests`, `ci`, `docs`) | no release |

## Steps

1. **Merge normal pull requests to `main`.** Each push to `main` runs the `Release` workflow.
   Expected: the `release-please` job succeeds; the `publish to ghcr.io` job is skipped because
   `release_created` is empty (not `"false"`) when nothing was released.
2. **Find the Release PR.** release-please, acting as the GitHub App `chart-base-release`
   ([ADR-0021](../adr/0021-github-app-token-for-release-please.md)), opens or updates a pull request titled
   `chore(main): release X.Y.Z`. It contains the `CHANGELOG.md` entry, the `Chart.yaml` version
   and the quick-start version in `README.md` and `README.md.gotmpl` (the `x-release-please-version` markers).
   ```bash
   gh pr list --repo jellalshadows/chart-base --search "chore(main): release"
   ```
   Expected: one open pull request. If none exists, see "If something goes wrong".
3. **Wait for CI on the Release PR.** Because the PR is created with the App token, CI runs on it without
   a manual approval. Expected: every check green, including `ci-ok`.
   ```bash
   gh pr checks <number> --repo jellalshadows/chart-base
   ```
4. **Review the PR.** Check that the version is the bump you expect from the commits, and that the
   `CHANGELOG.md` entry reads correctly.
5. **Merge the Release PR** (squash, as for every PR). The push to `main` makes release-please tag `vX.Y.Z`
   and create the GitHub release, and the `release-please` job sets `release_created` to `true`.
6. **Watch the run.** The `publish to ghcr.io` job then runs these steps in order: *Resolve the version from
   the tag*, checkout of `refs/tags/vX.Y.Z`, setup Helm, *Chart.yaml version must match the release*,
   *Refuse to overwrite an existing version (GHCR tags are mutable)*, *Package (reproducible)*,
   login, *Push to ghcr.io*, the provenance attestation ([ADR-0022](../adr/0022-provenance-with-actions-attest.md)),
   *Digest to sign*, the cosign installation, *Sign with cosign (keyless)* and
   *The cosign signature verifies* ([ADR-0034](../adr/0034-keyless-cosign-signatures.md)).
   ```bash
   gh run list --repo jellalshadows/chart-base --workflow release.yaml --limit 3
   gh run watch <run-id> --repo jellalshadows/chart-base
   ```
   Expected: the run for the merge commit finishes `completed  success`, and the guard step prints
   `chart-base:X.Y.Z is not published yet`.

## Verification

1. **Pull the package anonymously** (no login: the package is public):
   ```bash
   helm pull oci://ghcr.io/jellalshadows/charts/chart-base --version X.Y.Z
   ```
   Expected: `chart-base-X.Y.Z.tgz` is downloaded. On a machine whose Docker config has a `credsStore`
   that cannot be used, point `DOCKER_CONFIG` at an empty directory for this command:
   ```bash
   mkdir -p /tmp/empty-docker-config
   DOCKER_CONFIG=/tmp/empty-docker-config helm pull oci://ghcr.io/jellalshadows/charts/chart-base --version X.Y.Z
   ```
2. **Verify the provenance** (the command from the
   [README](../../README.md#versioning-and-releases)):
   ```bash
   gh attestation verify oci://ghcr.io/jellalshadows/charts/chart-base:X.Y.Z --repo jellalshadows/chart-base \
     --signer-workflow jellalshadows/chart-base/.github/workflows/release.yaml
   ```
   Expected: the verification succeeds and names `release.yaml` as the signer workflow.
3. **Verify the signature** (the command from the [README](../../README.md#versioning-and-releases)):
   ```bash
   cosign verify ghcr.io/jellalshadows/charts/chart-base:X.Y.Z      --certificate-identity https://github.com/jellalshadows/chart-base/.github/workflows/release.yaml@refs/heads/main      --certificate-oidc-issuer https://token.actions.githubusercontent.com --output json      | jq -e 'any(.[]; .critical.type == "https://sigstore.dev/cosign/sign/v1")'
   ```
   Expected: `true`, and exit code 0. `cosign verify` alone also succeeds for a version that only has the
   provenance attestation (same signer, same digest), so the `jq` filter is what requires the signature itself.
4. **Check the package page** on GitHub (the repository's *Packages* section): it lists version `X.Y.Z`.

## If something goes wrong

- **The `publish to ghcr.io` job failed before the push succeeded** (the tag and the GitHub release
  already exist, the version is not on GHCR): follow [Re-publishing or signing a tag](republish-a-tag.md). Do not
  delete the tag.
- **The push succeeded but the attestation step failed:** the version is on GHCR without provenance and
  cannot be re-published (the overwrite guard refuses). Ship the fix as a new patch release.
- **The push succeeded but the job failed at `Sign with cosign (keyless)` or `The cosign signature verifies`:**
  the version is on GHCR, with provenance but without a verified signature. Do not ship a new patch: run the
  manual dispatch for the same tag, which only signs it (see [Re-publishing or signing a tag](republish-a-tag.md)).
- **The overwrite guard reported the version already exists** (`refusing to overwrite`): never overwrite
  it. GHCR tags are mutable and consumers pin only a version string. Ship the fix as a new patch release.
- **No Release PR appears:** every commit since the last release is non-releasable (`docs:`, `chore:`,
  `ci:`, `test:`, or only touching `.github`, `tests`, `ci` or `docs`). This is expected. Land a `fix:` or
  `feat:` change and the PR appears.
- **The `release-please` job itself failed:** read its log. An error creating the token points at the App
  credentials: see [Rotating the release GitHub App key](rotate-release-app-key.md).
- **The Release PR has no CI checks:** it should not happen, because the PR is created with the App token. Confirm that the `release-please` job passes `steps.app-token.outputs.token` to the release-please action, and that the Release PR's author is the App's bot account and not `github-actions[bot]`.

## Related

- [ADR-0020: release-please and publish in one workflow](../adr/0020-release-please-and-publish-in-one-workflow.md)
- [ADR-0021: a GitHub App token for release-please](../adr/0021-github-app-token-for-release-please.md)
- [ADR-0022: provenance with actions/attest](../adr/0022-provenance-with-actions-attest.md)
- [ADR-0034: keyless cosign signatures by digest](../adr/0034-keyless-cosign-signatures.md)
- [ADR-0029: publishing is built for recovery](../adr/0029-publishing-built-for-recovery.md)
- [Re-publishing or signing a tag](republish-a-tag.md), [Rotating the release GitHub App key](rotate-release-app-key.md)
