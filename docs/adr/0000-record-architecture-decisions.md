# ADR-0000: Record architecture decisions

- **Status:** Accepted
- **Date:** 2026-09-28
- **Since:** docs backfill (after 0.1.0)

## Context

chart-base is a public chart that other teams build on, maintained by one person. Its value lies as
much in the decisions behind the values contract as in the templates: why names are never truncated,
why a Job is a Helm hook, why a `null` must not flip a default. Until now those reasons lived in a
one-paragraph summary per decision in the README and in design notes outside the repository. A
reviewer could not see the full context, and nobody but the author could reconstruct it: the bus
factor was one.

## Decision

Every design decision has an architecture decision record (ADR) in `docs/adr/`, in English.

- **Numbering.** ADR *N* expands decision *N* of the README's "Design decisions" list, and the README
  summary links to it. Numbers are never reused. ADR-0000 is this record.
- **Format.** The template below, a lightweight [MADR](https://adr.github.io/madr/): status, date, the
  release that introduced the decision, context, decision, consequences, alternatives considered and
  references.
- **Immutability.** An accepted ADR is not rewritten. When a later release changes the decision, a new
  ADR records the change and the earlier one gets `Amended by ADR-NNNN` or `Superseded by ADR-NNNN` on
  its status line. Typos and broken links are fixed in place.
- **Definition of done.** A release that makes a design decision ships its ADR, the README summary and
  every guide or runbook it affects, in the same pull request.
- **Checked by CI.** The `docs` job fails on any broken link or anchor in the repository's Markdown
  files (lychee, offline). The README links to the ADRs with absolute GitHub URLs, so the links also
  work inside the packaged chart; CI maps those URLs back to the checkout to check them.
- **Not shipped.** `docs/` is excluded from the chart package (`.helmignore`) and a commit that only
  touches `docs/` never creates a release (`exclude-paths` in `release-please-config.json`).

## Consequences

- Reviewers and future maintainers get the reasoning and the rejected options, not only the result.
- A decision is described in two places, the README summary and the ADR. The summary stays one
  paragraph and links to the ADR; when they differ, the ADR is authoritative and the summary is fixed.
- Writing the record becomes part of the cost of every change.

## Alternatives considered

### Decisions only in the README

One paragraph cannot hold the context, the consequences and every rejected option, and the README is
also shipped inside the chart package, where length matters.

### A wiki or a document outside the repository

Not versioned with the code, not reviewed in the same pull request, and invisible to anyone who
only reads the repository.

## References

- [ADR index](README.md)
- `.github/workflows/ci.yaml`, job `docs`: README drift check and link check.

## Template

````markdown
# ADR-NNNN: <the decision, as a short statement>

- **Status:** Accepted
- **Date:** YYYY-MM-DD
- **Since:** <the release that introduced it, e.g. 0.2.0>
- **Related:** [ADR-NNNN](NNNN-slug.md) (optional)

## Context

The problem, the forces and constraints, and the verified facts that matter, with their source.

## Decision

What chart-base does, in the present tense, with the exact keys, defaults and file names.

## Consequences

- What gets better.
- What gets worse or what it costs (every decision has a trade-off: name it).
- Follow-ups, if any.

## Alternatives considered

### <Alternative>

Why it was rejected.

## References

- Primary sources (official documentation, source code at a tag) and the files of this repository
  that implement the decision.
````
