# ADR-0021: A GitHub App token for release-please

- **Status:** Accepted
- **Date:** 2026-09-27
- **Since:** 0.1.0

## Context

release-please needs write access to open and keep updating the Release PR (its branch, its title, the
`CHANGELOG.md` and `Chart.yaml` commits) and, later, to create the tag and the GitHub Release. That access
has to come from some token, and the choice of token has a real, day-to-day consequence: GitHub's own
documentation on workflow triggers states that a `pull_request` created or updated by a workflow using
`GITHUB_TOKEN` creates workflow runs that "require approval" (a user with write access can approve them
from the pull request page), and that, "with the exception of `workflow_dispatch` and
`repository_dispatch`, other `GITHUB_TOKEN`-triggered events do not create workflow runs at all".

For chart-base that would mean every update release-please makes to the Release PR — which happens
repeatedly as more commits land on `main` — needs a human to click "approve workflow run" before `ci-ok`
(the single required check) can pass, even though the maintainer is the only person who could ever approve
it. A GitHub App's installation token is a different actor as far as GitHub is concerned: pull requests and
pushes it makes trigger the repository's normal workflows immediately, with no approval gate, giving the
Release PR the exact same CI treatment as any other PR before it can be merged.

A classic personal access token would sidestep the same approval gate, but it is tied to a person: it
outlives whatever scope was intended, has to be rotated by hand, and stops working the moment that person's
account changes or is removed from the repository — an availability risk for a chart other teams depend on.

## Decision

- release-please authenticates through a GitHub App named `chart-base-release`, installed only on this
  repository, using `actions/create-github-app-token@v3.2.0` (`release-please` job of
  `.github/workflows/release.yaml`) to mint a fresh installation token at the start of every run.
- The action reads `client-id: ${{ vars.RELEASE_APP_CLIENT_ID }}` (a repository variable) and
  `private-key: ${{ secrets.RELEASE_APP_PRIVATE_KEY }}` (a repository secret); neither the client ID nor the
  key is stored anywhere else in the repository.
- The token is requested with `permission-contents: write`, `permission-pull-requests: write` and
  `permission-issues: write` — the minimum release-please itself asks for, nothing broader.
- Installation tokens generated this way expire after 1 hour (`actions/create-github-app-token`'s own
  documentation: "An installation access token expires after 1 hour"), so nothing long-lived is ever held by
  the workflow beyond the App's private key itself.
- Because the App's token is not `GITHUB_TOKEN`, pull requests and pushes it makes are treated as coming
  from a distinct actor: their `pull_request`/`push` events trigger CI normally, without the manual-approval
  gate `GITHUB_TOKEN`-authored `pull_request` runs are subject to. The `release-please` job itself runs with
  `permissions: {}` — every write the job performs goes through the minted App token, not the workflow's own
  default permissions.
- Rotating the private key (a scheduled rotation, or a suspected leak): [runbook](../runbooks/rotate-release-app-key.md).

## Consequences

- The Release PR gets the repository's full required checks automatically, every time release-please
  updates it, with nobody clicking "approve" in between.
- Tokens are short-lived (1 hour) and scoped to exactly three permissions, reducing what a compromised CI
  run could do with them compared with a broadly-scoped, long-lived credential.
- Trade-off: this trades a token-management problem for an App-management one — the App has to be created
  once, installed on exactly this repository, and its private key rotated on a schedule or on
  suspicion of a leak; a plain `GITHUB_TOKEN` would never need any of that upkeep, and it now falls entirely
  on a single maintainer to keep current.
- A compromised App private key is more damaging than a compromised ephemeral `GITHUB_TOKEN`: the private
  key itself is long-lived (it is what mints the 1-hour tokens), so its exposure is a standing risk until
  rotated, not something that naturally expires with the workflow run.

## Alternatives considered

### `GITHUB_TOKEN` plus a manual CI trigger on every Release PR

Every update to the Release PR would produce a `pull_request` run requiring manual approval from someone
with write access, per GitHub's own documented behavior for `GITHUB_TOKEN`-authored pull requests — turning
every commit that lands on `main` into a "go click approve" chore, indefinitely.

### A personal access token (long-lived, tied to a person)

Solves the approval-gate problem the same way an App token does, but the credential belongs to an
individual: it must be manually rotated, typically carries broader scopes than release-please actually
needs, and stops working if that person's account is disabled or removed — a single point of failure a
chart meant to outlive any one maintainer's tenure should not depend on.

## References

- `.github/workflows/release.yaml` (`release-please` job)
- [actions/create-github-app-token](https://github.com/actions/create-github-app-token)
- [GitHub: Events that trigger workflows](https://docs.github.com/en/actions/reference/events-that-trigger-workflows)
- [Key rotation runbook](../runbooks/rotate-release-app-key.md)
