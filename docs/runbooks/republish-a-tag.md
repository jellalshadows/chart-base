# Re-publishing or signing a tag

**When to use:** the tag `vX.Y.Z` and its GitHub release exist and one of these is true:

- The `publish to ghcr.io` job failed before the push, so the version is not on GHCR (**publish** mode).
- The version is on GHCR but has no verified cosign signature: the job failed at the signing steps, or the
  version was published before signing existed (0.1.0 and 0.2.0) (**sign-only** mode).

The mode is not an input: the overwrite guard decides it from what GHCR answers for the version
(see "What the run does").

## Prerequisites

- Permission to run workflows on `jellalshadows/chart-base` (write access) and `gh` authenticated.
- The tag must already exist and its `Chart.yaml` version must equal the tag without the `v`.
- **A sign-only run checks the provenance itself.** Before signing, the run requires a provenance attestation
  from this workflow on the digest the version tag points to, and refuses to sign otherwise (step
  *Only sign what this workflow built*). Running `gh attestation verify` first (the command in the
  [README](../../README.md#versioning-and-releases)) is optional belt-and-braces; if it fails, do not
  dispatch: the tag may have been overwritten.
- Why this runbook exists: release-please treats an existing tag as "released" and will never re-tag it, and
  "Re-run failed jobs" re-executes the workflow file as it was when the run started
  ([ADR-0029](../adr/0029-publishing-built-for-recovery.md)).

## Steps

1. **Find the failed run and read the error.**
   ```bash
   gh run list --repo jellalshadows/chart-base --workflow release.yaml --limit 5
   gh run view <run-id> --repo jellalshadows/chart-base --log-failed
   ```
   Expected: the `publish to ghcr.io` job is the failed one, and the log names the failing step (for
   example *Push to ghcr.io*, where the registry error is printed before `helm push failed`).
2. **Decide whether the cause is in the workflow.** A transient GHCR or login failure needs no code change:
   go to step 4. If the failing step is broken (a bug in `release.yaml`), fix it on `main` through a
   normal pull request first (`fix:` or `ci:` as appropriate) and merge it. The re-publish uses the
   `release.yaml` current on the ref you select, so the fix must be on `main` before step 4.
3. **Check whether the version is published** (optional, the guard also checks it):
   ```bash
   mkdir -p /tmp/empty-docker-config
   DOCKER_CONFIG=/tmp/empty-docker-config helm pull oci://ghcr.io/jellalshadows/charts/chart-base --version X.Y.Z
   ```
   An error saying the version was not found means publish mode: go to step 4. If the pull works, the version
   is published: to sign it, go to step 4 (sign-only mode; the run checks the provenance itself); if it is
   already signed (see "Verification"), stop.
4. **Run the workflow manually with the tag.**
   ```bash
   gh workflow run release.yaml --repo jellalshadows/chart-base --ref main -f tag=vX.Y.Z
   sleep 10   # give GitHub a moment to register the new run
   gh run list --repo jellalshadows/chart-base --workflow release.yaml --event workflow_dispatch --limit 1
   gh run watch <run-id> --repo jellalshadows/chart-base
   ```
   Expected: a `workflow_dispatch` run that finishes `completed  success`. In sign-only mode the guard step
   prints `nothing is pushed, it is only signed`.
   When signing several versions, **wait for each run to finish before dispatching the next**: a new pending
   run in the `release` concurrency group cancels an older pending one.

## What the run does

- The `release-please` job also runs first, as on every run. For a tag that was already released it has nothing to release, and the `publish` job's `!cancelled()` condition means the re-publish does not depend on its output. (As on any run, it may update an open Release PR if releasable commits are pending.)
- The `publish to ghcr.io` job runs because `inputs.tag != ''`. It checks out `refs/tags/vX.Y.Z`, so it
  publishes exactly the tagged content, but with the workflow file of the ref you selected (`main`).
- The provenance attestation of a re-published version records the dispatched ref and commit (for
  example `main`), not the tag's commit, because the workflow run belongs to the selected ref.
- The overwrite guard runs on this attempt too and sets the mode by what GHCR answers for the version:
  - `404` (not published): **publish** mode. Package, push, provenance attestation, signature and its
    verification, as on a normal release.
  - `200` on a manual run: **sign-only** mode. Nothing is packaged, pushed or attested. The digest from the
    guard's `Docker-Content-Digest` header is signed with cosign keyless only if it has a provenance
    attestation from this workflow (otherwise the run fails at *Only sign what this workflow built*); the
    signature and the provenance are then verified. This is the recovery for a failure at the signing steps, and the backfill of versions published before
    signing existed.
  - `200` on an automatic (push) run still fails with `refusing to overwrite`. Nothing ever overwrites.
- Signing a version twice only adds another signature to the digest; verification accepts either.
- A manual `workflow_dispatch` runs the workflow file of the ref you select: always pass `--ref main`.

## Verification

Same as [Cutting a release](release.md#verification): an anonymous `helm pull` of `X.Y.Z`,
`gh attestation verify` and `cosign verify | jq -e` (the commands in the
[README](../../README.md#versioning-and-releases)), and the package page.

## If something goes wrong

- **The run fails at "Resolve the version from the tag":** the value is not `vX.Y.Z` (for example a missing `v`). Run again with a well-formed tag.
- **The run fails at the checkout of `refs/tags/<tag>`:** the tag is well-formed but does not exist.
  Check `git ls-remote --tags https://github.com/jellalshadows/chart-base` for the exact name.
- **The run fails at "Chart.yaml version must match the release":** the tag exists but its `Chart.yaml`
  has a different version. The tagged content is inconsistent: do not move the tag; fix forward with a new release.
- **The guard fails with `already exists in ghcr.io`:** this was an automatic run (the automatic path never
  overwrites). The version is published: verify it as above, and
  to sign it dispatch the workflow manually with the tag.
- **A sign-only run fails at `Only sign what this workflow built`:** the digest has no provenance
  attestation from this workflow (the log names the bundle types found). Do not sign it. If the tag may
  have been overwritten, treat the version as untrusted and ship a new patch release.
- **A run fails at `Sign with cosign (keyless)` or `The signature and the provenance verify`:** read the log.
  A failure to obtain the OIDC token points at the job's `id-token: write` permission; a verification
  failure names the identity and the bundle types it found. Fix it on `main` and dispatch again.
- **The push succeeded but the attestation step failed:** the version is on GHCR without provenance, and
  this runbook cannot fix it: an automatic re-run stops at the overwrite guard (`200`, "refusing to
  overwrite"), and a manual run is refused at *Only sign what this workflow built*. Do not overwrite; ship a
  new patch release through [Cutting a release](release.md). (A failure at the signing steps is different:
  the sign-only run above recovers it.)
- **The tagged content itself is broken** (a bad chart, not a failed publish): fix forward. Merge a `fix:`
  and release a new patch version through [Cutting a release](release.md).

## Never

- Delete and recreate a tag or its GitHub release: it fights release-please and mutates a reference consumers may already use.
- Overwrite a published version: GHCR tags are mutable and `Chart.lock` in a consumer records only a version string.
- Run `helm push` from a laptop: it skips the guard, the reproducible packaging and the provenance attestation.
- Add a workflow triggered by a tag that publishes: tags created by the App do trigger workflows, and there must be a single publisher ([ADR-0020](../adr/0020-release-please-and-publish-in-one-workflow.md)).

## Related

- [ADR-0029: publishing is built for recovery](../adr/0029-publishing-built-for-recovery.md)
- [ADR-0020: release-please and publish in one workflow](../adr/0020-release-please-and-publish-in-one-workflow.md)
- [ADR-0034: keyless cosign signatures by digest](../adr/0034-keyless-cosign-signatures.md)
- [ADR-0022: provenance with actions/attest](../adr/0022-provenance-with-actions-attest.md)
- [Cutting a release](release.md)
