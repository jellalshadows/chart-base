# ADR-0020: release-please and publishing in one workflow

- **Status:** Accepted
- **Date:** 2026-09-27
- **Since:** 0.1.0

## Context

chart-base is a single-maintainer public chart consumed as an OCI dependency by domain umbrellas: cutting
a release has to turn a set of merged conventional commits into a version bump, a tag, a GitHub Release
and a package on GHCR, without a person doing any of those steps by hand. release-please already solves
the "what's the next version" problem from commit history; the remaining question is how to actually build
and push the package once a release is decided.

The obvious design is a second workflow triggered `on: push: tags`. With the default `GITHUB_TOKEN` that
cannot work: GitHub does not run new workflows for events produced by a workflow's own `GITHUB_TOKEN`
(with the exceptions of `workflow_dispatch` and `repository_dispatch`, and of `pull_request` events, whose runs need approval), so a tag created that way would
never fire a tag-triggered publisher. chart-base does not use the default token for release-please but a
GitHub App token (ADR-0021), and tags created with an App token *do* trigger workflows. That would make a
tag-triggered publisher possible, but also dangerous: a second workflow that publishes on tags would run in
addition to any other publisher and could publish the same version twice. The rule the repository
enforces instead is that there is exactly one publisher, the `publish` job of the release workflow itself,
and no workflow triggered by a tag may ever publish (the comment in `release.yaml` says so).

GHCR OCI tags are also mutable: `helm push`-ing the same version a second time silently replaces what is
there, and `Chart.lock` in a consumer umbrella records only a version string, never a digest. If a version
that is already in use got overwritten, every umbrella pinning it would start receiving different bits on
its next `helm dependency update` with no diff to review — the exact opposite of what a versioned, public
dependency is supposed to guarantee. And because the package should be reproducible from its source commit,
the build step needs a deterministic timestamp rather than "whenever CI happened to run".

## Decision

- `.github/workflows/release.yaml` runs on `push: branches: [main]` (plus a `workflow_dispatch` covered by
  ADR-0029) and has exactly two jobs: `release-please`, then `publish` (`needs: release-please`). No other
  workflow publishes; the comment in the file states this explicitly: "The ONLY job that publishes."
- `release-please` uses `googleapis/release-please-action@v5.0.0`, manifest mode: `config-file:
  release-please-config.json`, `manifest-file: .release-please-manifest.json`.
  `release-please-config.json` sets `release-type: helm`, `initial-version: "0.1.0"`,
  `bump-minor-pre-major: true`, `bump-patch-for-minor-pre-major: false`, `include-component-in-tag: false`,
  `include-v-in-tag: true` — before 1.0, `fix:` bumps patch, `feat:` and `feat!:` both bump minor (never
  major), and tags are plain `vX.Y.Z`.
- Merging the Release PR release-please keeps open pushes to `main`, which makes it tag `vX.Y.Z`, cut a
  GitHub Release, and set `steps.release.outputs.release_created` to `'true'`. On every other push to
  `main`, that output is **empty**, not the string `"false"` (the workflow's own comment: "release_created is
  EMPTY (not "false") when nothing was released: compare with == 'true'"), so the `publish` job's
  condition explicitly compares `needs.release-please.outputs.release_created == 'true'` (or
  `inputs.tag != ''` for a manual re-publish).
- `publish`'s steps, in order: resolve `VERSION` from a `TAG` that must match `^v[0-9]+\.[0-9]+\.[0-9]+$`;
  `actions/checkout` at `ref: refs/tags/${{ env.TAG }}`; `azure/setup-helm` at `HELM_VERSION`; assert
  `Chart.yaml`'s `.version` (via `yq`) equals `VERSION`, failing otherwise; the overwrite guard (below);
  `helm package . --destination dist` with `SOURCE_DATE_EPOCH="$(git log -1 --format=%ct)"` exported, then
  `touch -d "@${SOURCE_DATE_EPOCH}"` on the resulting `.tgz` so the package is reproducible from the tagged
  commit; `docker/login-action` to `ghcr.io`; `helm push`; `actions/attest` (ADR-0022).
- The overwrite guard requests a registry token from `ghcr.io/token` authenticated with
  `-u "${ACTOR}:${GITHUB_TOKEN}"` and scope `repository:<owner>/charts/chart-base:pull,push`, then does a
  `HEAD` on the version's OCI manifest with that token: `404` means "not published yet, continue"; `200` fails the job ("already exists in
  ghcr.io; refusing to overwrite"); any other code also fails. On chart-base's very first publish (0.1.0),
  this guard observed `404` and let the release through, confirming the 404/200 logic against the real
  registry.

## Consequences

- Tagging and publishing happen in one workflow run, so there is nothing to keep in sync between "what got
  tagged" and "what gets published" — the same run does both.
- No `workflow_run`-triggered publisher and no heuristic for "the latest tag" to guess wrong; exactly one
  publisher exists, and a tag-triggered workflow must never publish (App-created tags would fire it and
  double-publish).
- Trade-off: because `publish` is coupled to the same run as `release-please`, a publish failure after the
  tag already exists cannot be fixed by re-running release-please, which never releases an existing tag
  again; recovering from that specific failure mode needed its own mechanism, covered in
  ADR-0029.
- The overwrite guard is one more outbound network dependency (a GHCR token request plus a manifest `HEAD`)
  on the critical path of every release; if GHCR's API is unreachable, the whole release stalls rather than
  degrading gracefully — an accepted cost, since publishing over an existing version silently is worse.

## Alternatives considered

### A personal access token plus a `workflow_run`-triggered publisher

A `workflow_run` workflow triggered after `release-please` finishes would need its own way to figure out
*what* to publish, since it does not share the same run's context. The natural shortcut — "publish whatever
the latest tag is" — is a heuristic: if any other push landed on `main` between the tag being created and
the publisher's run starting, it can resolve to the wrong tag and re-publish the current state of `main`
under an old version number (the republishing bug of an earlier design of this pipeline). The PAT half of the
option adds a long-lived credential tied to a person (ADR-0021). A single `publish` job that receives
`tag_name` from the `release-please` job through `needs` has no such guess to make.

## References

- `.github/workflows/release.yaml`
- `release-please-config.json`, `.release-please-manifest.json`
- [GitHub: Events that trigger workflows — `GITHUB_TOKEN`](https://docs.github.com/en/actions/reference/events-that-trigger-workflows)
- [release-please](https://github.com/googleapis/release-please)
