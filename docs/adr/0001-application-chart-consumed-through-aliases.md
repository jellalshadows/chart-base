# ADR-0001: Application chart consumed through aliases

- **Status:** Accepted
- **Date:** 2026-09-27
- **Since:** 0.1.0

## Context

chart-base targets a specific consumption model: one umbrella chart per business domain (for
example `vending`), where every component of the domain (`sales`, `machines`, `front-web`) is a
Helm dependency on chart-base, each with a different `alias`. The model is one workload per alias:
the umbrella never renders a workload itself, it only wires aliases. Domain umbrellas are deployed
per environment with helmfile, and inside an umbrella `global` only toggles components on or off;
every other setting for a component lives nested under its alias in one `values.yaml`, including
its `ExternalSecret`.

Helm's alias mechanism replaces `.Chart.Name` with the alias for the whole subchart render
(`getAliasDependency`). chart-base's own name helper reads exactly that value:
`chart-base.component` is `.Chart.Name` (`templates/_names.tpl`), so every resource name, label and
hook derives from the alias, not from a hardcoded string. Because Helm validates a dependency's
`values.schema.json` against the values nested under its alias before rendering anything, every
component gets full schema validation — required keys, enums, `additionalProperties: false` — with
no template code written by the consuming team. A typo under an alias (an unknown key, a bad enum
value) fails the same way regardless of which component wrote it.

The model has a real cost: one umbrella chart is one Helm release, so the components of a domain
deploy and roll back together. A broken value for one component can block the release of every
other component in the same domain. This trade-off is accepted, not avoided, and chart-base's
answer is to fail as early as possible — at `helm template`/`helm lint` validation time, before
anything reaches the cluster — rather than at apply time, so a broken component never gets a chance
to affect the others' rollout (Spec §1.1, §5).

The alias behavior is not exercised by a committed example: `.github/scripts/alias-contract.sh`
builds a throwaway umbrella chart in CI with three aliases, one of them hyphenated
(`nightly-cleanup`), verifies unique `<release>-<alias>` resource names, that `helm.sh/chart` still
names the real chart under the alias, and that a schema violation under one alias fails with that
alias's name in the error.

## Decision

chart-base is consumed exclusively as an aliased Helm dependency of a domain umbrella chart, never
standalone and never through a hand-written template in the consuming chart:

- One umbrella chart per business domain. Each component of the domain declares chart-base as a
  dependency with a distinct, lowercase kebab-case `alias` and `condition: <alias>.enabled`.
- Inside the rendered subchart, `.Chart.Name` equals the alias; `chart-base.component` (defined in
  `templates/_names.tpl`) reads that value, and every other name, label and hook annotation is built
  from it.
- Helm validates `values.schema.json` against the values nested under each alias, so every
  component — regardless of which team owns it — is schema-validated with no template written by
  the consumer.
- The alias contract (unique names, per-alias schema errors, a hyphenated alias) is verified by
  `.github/scripts/alias-contract.sh` against a throwaway umbrella built in CI, not by a committed
  example chart.
- Trade-off accepted: one umbrella equals one Helm release, so deploys and rollbacks of its
  components are coupled. chart-base mitigates this by failing validation (schema and
  `templates/validate.yaml` guards) before any resource reaches the cluster.

## Consequences

- Every component gets the same schema validation and the same identity rules for free; the
  umbrella never contains a hand-written Deployment, Job or CronJob template.
- A single, versioned chart is the one place that fixes a bug or adds a feature for every consumer.
- Deploys and rollbacks are coupled per domain: a bad value in one component's alias blocks the
  whole umbrella's release until fixed, which is the cost of the one-release-per-domain model.

## Alternatives considered

### A library chart

A library chart contributes only named templates for a consumer to `include`; it has no values of
its own to validate independently, so the consumer would still have to write its own templates and
its own `values.schema.json` (or none at all). Typos and missing required keys under a component
would not be caught the same way for every consumer — each umbrella would need to reimplement the
same guards.

### A copy of the chart per service

Duplicating chart-base per service means N charts to version, patch and keep in sync by hand. A fix
or a new feature has to be ported to every copy instead of a single dependency bump.

## References

- `templates/_names.tpl`
- `values.schema.json`
- `.github/scripts/alias-contract.sh`
- `Chart.yaml`
- [README quick start](../../README.md#quick-start)
- [Helm: Subcharts and Global Values](https://helm.sh/docs/chart_template_guide/subcharts_and_globals/)
