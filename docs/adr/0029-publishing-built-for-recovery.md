# ADR-0029: Publishing is built for recovery

- **Status:** Accepted
- **Date:** 2026-09-28
- **Since:** 0.1.0

## Context

Even with the overwrite guard (ADR-0020) and a short-lived App token (ADR-0021), the `publish` job can still
fail for reasons that have nothing to do with the release decision itself: a transient GHCR outage during
`helm push`, a `docker/login-action` hiccup, an unexpected HTTP status from the guard's own manifest check.
When that happens, the tag and the GitHub Release already exist — release-please's own job succeeded — but
nothing has actually reached `ghcr.io` yet.

release-please will not help recover from this: its entire model is "propose the next version from commits
that have not been released yet", and a tag that already exists means, from its perspective, that version
*was* released — it will never propose or re-tag it again (Spec §14, A6). GitHub's generic "Re-run failed
jobs" does not help either: it re-executes the same job with the workflow file exactly as it was *at the
time that run started*. If the failure came from a bug in the publish steps themselves — the very thing a
fix would target — re-running reproduces the identical failure, not a corrected one. Deleting and recreating
the tag by hand fights release-please directly, and mutates a reference other tooling (and any consumer who
already pinned that release) may already depend on. And publishing from a laptop skips every guarantee the
workflow itself provides: no overwrite guard, no reproducible packaging, no provenance attestation
(ADR-0022), no audit trail of who ran it or from where.

## Decision

- `.github/workflows/release.yaml`'s `workflow_dispatch` trigger takes an input `tag` (e.g. `v0.1.0`):
  a manual run with `tag` set re-publishes that exact tag using whatever `release.yaml` is current on
  `main` at the time of the manual run — not whatever version of the workflow ran (and failed) originally.
- The `publish` job's condition is `${{ !cancelled() && (needs.release-please.outputs.release_created ==
  'true' || inputs.tag != '') }}`. The `release-please` job still runs first, unconditionally, in the same
  workflow, but `!cancelled()` means a manual re-publish's success does not depend on that job succeeding or
  producing anything meaningful — only on not having been cancelled.
- `env.TAG` is `${{ inputs.tag || needs.release-please.outputs.tag_name }}`, and the job checks out
  `ref: refs/tags/${{ env.TAG }}`: it always publishes exactly what was tagged, whether `TAG` came from this
  run's own `release-please` job or from a manual `tag` input pointing at an older, already-tagged release.
- The "Push to ghcr.io" step captures `helm push`'s combined output and prints it on failure:
  `out="$(helm push ... 2>&1)" || { echo "$out"; echo "::error::helm push failed"; exit 1; }` — a failed
  push leaves the actual registry error visible in the run log instead of a bare non-zero exit code.
- The overwrite guard (ADR-0020) runs on every publish attempt, manual or automatic alike, so a manual
  re-publish still refuses to overwrite a version GHCR already reports as `200`.
- Procedure: [runbook](../runbooks/republish-a-tag.md).

## Consequences

- A publish failure that happens after the tag already exists has a real recovery path: fix whatever broke,
  merge the fix to `main`, then trigger `workflow_dispatch` with the failed `tag` — running the *fixed*
  workflow against the *original* tagged commit, not the broken one that failed the first time.
- The overwrite guard still applies during a manual re-publish, so recovery can never silently push over a
  version that a previous, partially-successful attempt already got onto GHCR.
- Trade-off: a free-text `workflow_dispatch` `tag` input has to trust the operator to type a real, existing
  tag. The "Resolve the version from the tag" step's regex (`^v[0-9]+\.[0-9]+\.[0-9]+$`) only checks the
  *shape* of the input, not that the tag exists or ever had a real release behind it — a mistyped tag simply
  fails later, at the `Chart.yaml`-version-match step, rather than being rejected up front.

## Alternatives considered

### "Re-run failed jobs"

Re-executes the workflow exactly as it existed when the failed run started; if the bug was in the publish
steps themselves, the re-run reproduces the same failure verbatim, since it is not running the fixed
version on `main`.

### Deleting and recreating the tag and the GitHub release

Fights release-please directly — its model treats a tag's existence as proof that version was already
released, and it will not propose that version again once the tag is gone and recreated by hand. It also
mutates a reference other tooling, and any consumer who already resolved that release, may depend on.

### `helm push` from a laptop

Skips the overwrite guard, the reproducible packaging step, and the provenance attestation entirely (ADR-0022),
leaving the republished version with no way for a consumer to verify it came from `release.yaml` at all.

## References

- `.github/workflows/release.yaml` (`workflow_dispatch.inputs.tag`, `publish.if`, `env.TAG`, the "Push to
  ghcr.io" step)
- Design spec §9.1, §14 (A6), §14.1 (A15)
- `../../README.md#versioning-and-releases`
- [Re-publishing a tag runbook](../runbooks/republish-a-tag.md)
