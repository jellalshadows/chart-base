# chart-base documentation

The [README](../README.md) is the reference for consumers: quick start, recipes, every value and a
one-paragraph summary of each design decision. This directory is the long-form record behind it.

## Architecture decision records

[`adr/`](adr/README.md) holds one record per design decision: the context and the constraints, the
decision, its consequences and every alternative that was considered. ADR *N* expands decision *N*
of the README.

## Roadmap

[`roadmap.md`](roadmap.md): the planned releases up to 1.0, the principles every release follows, and
the features that were rejected, with the reason.

## Upgrade guide

[`upgrading.md`](upgrading.md): what to change in your values for every breaking release, and which objects
a fix release changes.

## Guides

| Guide | For |
|---|---|
| [Consuming chart-base from a domain umbrella](guides/consuming.md) | Platform teams writing a domain umbrella chart and deploying it |
| [Development](guides/development.md) | Contributors: tools, the TDD loop, the repository layout and known pitfalls |
| [Testing](guides/testing.md) | Contributors and reviewers: every test layer, what it proves and how to run it |

## Runbooks

| Runbook | When |
|---|---|
| [Cutting a release](runbooks/release.md) | Every release: from merged pull requests to a verified package on GHCR |
| [Re-publishing or signing a tag](runbooks/republish-a-tag.md) | A release was tagged but its publish job failed, or a published version has no cosign signature |
| [Rotating the release GitHub App key](runbooks/rotate-release-app-key.md) | A scheduled rotation, or a key that may have leaked |
| [Renovate](runbooks/renovate.md) | Reviewing dependency pull requests, tracking a new tool, debugging Renovate |

## Conventions

- English, Markdown, LF line endings. Links inside `docs/` are relative; CI checks every link and
  anchor (`docs` job).
- `docs/` is not part of the published chart and never triggers a release
  ([ADR-0000](adr/0000-record-architecture-decisions.md)).
- Every release updates the documentation it affects: new ADRs, the roadmap status, guides and
  runbooks.
