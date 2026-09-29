# Re-publishing a tag

**When to use:** the tag `vX.Y.Z` and its GitHub release exist, but the `publish to ghcr.io` job failed, so the version is not on GHCR.

## Prerequisites

- Permission to run workflows on `jellalshadows/chart-base` (write access) and `gh` authenticated.
- The tag must already exist and its `Chart.yaml` version must equal the tag without the `v`.
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
3. **Check that the version is really not published** (optional, the guard also checks it):
   ```bash
   mkdir -p /tmp/empty-docker-config
   DOCKER_CONFIG=/tmp/empty-docker-config helm pull oci://ghcr.io/jellalshadows/charts/chart-base --version X.Y.Z
   ```
   Expected: an error saying the version was not found. If the pull works, the version is already published:
   stop and go to "Verification".
4. **Run the workflow manually with the tag.**
   ```bash
   gh workflow run release.yaml --repo jellalshadows/chart-base --ref main -f tag=vX.Y.Z
   sleep 10   # give GitHub a moment to register the new run
   gh run list --repo jellalshadows/chart-base --workflow release.yaml --event workflow_dispatch --limit 1
   gh run watch <run-id> --repo jellalshadows/chart-base
   ```
   Expected: a `workflow_dispatch` run that finishes `completed  success`.

## What the run does

- The `release-please` job also runs first, as on every run. For a tag that was already released it has nothing to release, and the `publish` job's `!cancelled()` condition means the re-publish does not depend on its output. (As on any run, it may update an open Release PR if releasable commits are pending.)
- The `publish to ghcr.io` job runs because `inputs.tag != ''`. It checks out `refs/tags/vX.Y.Z`, so it
  publishes exactly the tagged content, but with the workflow file of the ref you selected (`main`).
- The provenance attestation of a re-published version records the dispatched ref and commit (for
  example `main`), not the tag's commit, because the workflow run belongs to the selected ref.
- The overwrite guard runs on this attempt too. If the version was published after all (a previous attempt
  got further than it looked), the guard fails the job and nothing is overwritten.
- A manual `workflow_dispatch` runs the workflow file of the ref you select: always pass `--ref main`.

## Verification

Same as [Cutting a release](release.md#verification): an anonymous `helm pull` of `X.Y.Z`,
`gh attestation verify` (the command in the [README](../../README.md#versioning-and-releases)), and the
package page.

## If something goes wrong

- **The run fails at "Resolve the version from the tag":** the value is not `vX.Y.Z` (for example a missing `v`). Run again with a well-formed tag.
- **The run fails at the checkout of `refs/tags/<tag>`:** the tag is well-formed but does not exist.
  Check `git ls-remote --tags https://github.com/jellalshadows/chart-base` for the exact name.
- **The run fails at "Chart.yaml version must match the release":** the tag exists but its `Chart.yaml`
  has a different version. The tagged content is inconsistent: do not move the tag; fix forward with a new release.
- **The guard fails with `already exists in ghcr.io`:** the version is published. Verify it as above; do not overwrite.
- **The push succeeded but the attestation step failed:** the version is on GHCR without provenance, and
  this runbook cannot fix it: a re-run stops at the overwrite guard (`200`, "refusing to overwrite").
  Do not overwrite; ship a new patch release through [Cutting a release](release.md).
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
- [ADR-0022: provenance with actions/attest](../adr/0022-provenance-with-actions-attest.md)
- [Cutting a release](release.md)
