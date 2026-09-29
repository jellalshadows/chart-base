# ADR-0025: Generated README, in English

- **Status:** Accepted
- **Date:** 2026-09-27
- **Since:** 0.1.0

## Context

The README is the first thing a consumer reads before writing a domain umbrella against chart-base, and its
"Values" table is a direct restatement of `values.yaml`'s 31 top-level keys and their defaults. A
hand-maintained copy of that table drifts the moment a key is added, renamed or given a new default without
someone remembering to also edit the README — a gap that is invisible until a consumer trusts a stale
default. helm-docs solves this structurally: it builds the values table straight from the `# --` comments
already sitting above each key in `values.yaml`, and takes the rest of the page's prose from a separate
template, `README.md.gotmpl`, so the generated document is always a projection of the source of truth.

Because `docs/` itself is excluded from the packaged chart (`.helmignore`) but `README.md` is not, the
README is read in at least three different places with three different filesystem layouts: on GitHub (where
relative links to `docs/adr/...` work fine), inside the unpacked `.tgz` a consumer's tooling might inspect
(where `docs/` simply is not there), and in anything that renders the packaged README (`helm show readme`, chart registries such as
Artifact Hub). A relative link into `docs/` would 404 in the second and third cases; only an absolute
GitHub URL resolves identically everywhere the README travels.

A version badge was considered and rejected for a related reason: `Chart.yaml`'s version only reflects what
was last *tagged*, while a Release PR sits open, unmerged, with a newer version proposed — a badge would
either show a stale number until the PR merges or need its own separate update mechanism, either of which
fights the drift check this ADR is about, for a detail the "Versioning and releases" section already covers
in prose.

## Decision

- `README.md` is generated: `helm-docs --chart-search-root . --template-files README.md.gotmpl`, driven from
  `README.md.gotmpl` (prose, recipes, design decisions, versioning rules) and the `# --` comments above each
  key in `values.yaml` (the "Values" table). Editing `README.md` directly is undone the next time this
  command runs.
- `.github/workflows/ci.yaml`'s `docs` job regenerates the README on every PR and fails the build on any
  diff: `git diff --exit-code README.md || { echo "::error::README.md is stale: run helm-docs and commit
  it"; exit 1; }` — the values table can never silently drift from `values.yaml`.
- All prose is in English.
- Every entry in the "Design decisions" section links to its ADR with an absolute GitHub URL, e.g.
  `https://github.com/jellalshadows/chart-base/blob/main/docs/adr/0007-jobs-as-helm-hooks.md`, so the link
  resolves the same way whether the README is read on GitHub, inside the packaged `.tgz`, or through `helm show readme`.
- The `chart-base` version quoted in the quick start's `Chart.yaml` snippet (`version: 0.1.0 #
  x-release-please-version`) carries the `# x-release-please-version` marker. `release-please-config.json`'s
  `extra-files: ["README.md", "README.md.gotmpl"]` makes release-please bump that line in both files on
  every release, alongside `Chart.yaml` itself.
- No version badge appears anywhere in `README.md.gotmpl`.

## Consequences

- The values table, and the version quoted in the README quick start, cannot drift from what
  `values.yaml`/`Chart.yaml` actually declare — CI fails the PR the moment they disagree.
- Trade-off: nobody can fix a typo directly in `README.md`, even a trivial one — every change to its prose
  goes through `README.md.gotmpl` plus a `helm-docs` run, adding one extra step to what would otherwise be a
  one-line edit.
- A second cost: because `extra-files` also touches `README.md.gotmpl`, every Release PR carries a
  version-bump diff in a file most maintainers would not expect an automated release bot to touch at all —
  this has to be understood by anyone who later edits `extra-files` for a different reason.

## Alternatives considered

### A hand-written README and values table

A hand-maintained values table for a chart with this many top-level keys is a drift risk with no mechanism
to catch it — nothing short of generation-plus-CI-check keeps prose and `values.yaml` in agreement.

### Spanish

English reaches a wider, international audience of Helm chart consumers and matches every other document in
this repository; the pre-0.1.0 design notes, which are not published, are the sole exception.

## References

- `README.md.gotmpl`
- `values.yaml` (`# --` comments)
- `.github/workflows/ci.yaml` (`docs` job)
- `release-please-config.json` (`extra-files`)
- [helm-docs](https://github.com/norwoodj/helm-docs)
