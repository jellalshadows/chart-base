# ADR-0011: Strict draft-07 schema with reserved `global` and `enabled`

- **Status:** Accepted
- **Date:** 2026-09-27
- **Since:** 0.1.0

## Context

chart-base is consumed only as an aliased dependency of a domain umbrella (ADR-0001): nothing else
validates a component's values before Helm builds Kubernetes objects out of them. `values.schema.json`
is the only layer that can catch a mistake at render time, before `helm template`/`helm lint`/
`helm install` ever reaches the cluster (the guards that the schema itself cannot express are a second
layer, the `fail` guards in `templates/validate.yaml`, described below). A schema is only as useful as what it rejects: JSON Schema's
`additionalProperties: false` on an object is what makes an unknown key fail instead of being ignored.
Without it, a typo like `service.typ` or a misremembered `imagePulSecrets` never reaches a template —
the value is simply dropped, the chart renders its default, and the consumer gets no error at all.

Helm's built-in schema validation is bounded by the JSON Schema draft its bundled library understands.
Helm releases up to 3.18.4 validate with a library that stops at draft-07 (it knows drafts
04/06/07); newer releases also accept newer drafts. Draft-07 already includes `if`/`then`, so it
works on every Helm 3 and Helm 4 release — the conditionals in the schema (cronjob's schedule,
externalSecret's data, httpRoute's parentRefs, and so on) all depend on it, and no consumer is cut
off. The `lint` matrix tests Helm 3.22.0 and Helm 4.3.0.

Two keys need special-casing rather than rejection. Helm always injects a `global` object into every
subchart's values, whether or not the umbrella sets one. And an umbrella that wants to switch a
component off conditionally uses `condition: <alias>.enabled` on the dependency in its own
`Chart.yaml`, which reads a per-alias `enabled` boolean directly off the values — placed under the
alias, i.e. inside chart-base's own values map. Both keys land in front of `additionalProperties: false`
whether chart-base wants them or not, but no template in this chart reads either of them.

## Decision

- `values.schema.json` declares `"$schema": "http://json-schema.org/draft-07/schema#"` and is
  hand-written, not generated from `values.yaml`.
- `additionalProperties: false` is set on the top-level object and on every nested object that has a
  fixed set of keys — 21 objects in the current schema, including `workload`, `image`, `resources`,
  `configFiles`, `externalSecret`, `service`, `probes`, `autoscaling`, `pdb`, `httpRoute`, `ingress`,
  `cronjob`, `job` and `serviceAccount`. An unknown key under any of these fails validation instead of
  being dropped.
- The genuinely open maps do **not** get `additionalProperties: false`, because their keys are
  consumer-defined data, not a fixed schema: `config`, `configFiles.files`, `externalSecret.data`,
  `podAnnotations`, `podLabels`, `nodeSelector` and `ingress.annotations`. Each still constrains its
  keys with `propertyNames` (e.g. `config`'s keys must match `^[A-Za-z_][A-Za-z0-9_]*$`, a valid
  environment variable name) or types its values (e.g. `config`'s values must be
  `string`/`number`/`boolean`).
- `global` (`"type": "object"`) and `enabled` (`"type": "boolean"`) are declared at the top level,
  outside `required`: the schema accepts them so validation never fails merely because Helm injected
  `global` or an umbrella's `condition` set `enabled`. No template in `templates/` reads
  `.Values.global` or `.Values.enabled` — chart-base itself never sees them as behavior, only as
  tolerated input.
- Rules the schema cannot express — a name that must be lowercase kebab-case, a resource name that
  must fit under a length limit, a Kubernetes-version floor, a cross-field ordering — are `fail`
  guards in `templates/validate.yaml`, evaluated at render time by every one of `helm
  template`/`helm lint`/`helm install`/`helm upgrade`. Every guard's message is prefixed
  `chart-base[<component>]:` by the `chart-base.fail` helper (`templates/_names.tpl`), so a multi-alias
  umbrella's error output names the failing component, not just the failing key.

## Consequences

- A typo under any fixed-shape object fails fast, with the error naming the component, instead of
  silently rendering a default nobody asked for.
- draft-07 keeps the schema working on every Helm 3 and Helm 4 release, including consumers still on
  Helm 3.18.4 or older, with no loss of conditional validation.
- Trade-off: a hand-written schema is one more file to keep in sync. Adding a key to a fixed-shape
  object means editing `values.yaml`, `values.schema.json` and usually a template; forgetting the
  schema edit means the key is either rejected outright (if its parent object has
  `additionalProperties: false`) or silently accepted untyped (if it lands under an open map).
- The reserved-keys convention is invisible to a consumer who reads only `values.yaml` (which never
  mentions `global` or `enabled`, by design — they are not part of the public contract a consumer
  writes).

## Alternatives considered

### JSON Schema draft 2020-12

Gives access to newer keywords, but Helm releases up to 3.18.4 cannot validate it (their bundled
library stops at draft-07), which would break the chart for any consumer still on one of those
releases. Newer Helm releases would accept it, so the cost is the older consumers, not the primary
Helm version.

### A permissive schema (no `additionalProperties: false`)

The default JSON Schema behavior when the keyword is omitted. A typo is accepted, silently produces
the chart's default, and the consumer never finds out until the running component behaves
unexpectedly — the exact failure mode `additionalProperties: false` exists to prevent.

## References

- `values.schema.json`
- `templates/validate.yaml`, `templates/_names.tpl` (`chart-base.fail`)
- [ADR-0001](0001-application-chart-consumed-through-aliases.md)
- [ADR-0012](0012-no-capabilities-gating.md)
- [Helm: Subcharts and Global Values](https://helm.sh/docs/chart_template_guide/subcharts_and_globals/)
- [Helm: Schema files](https://helm.sh/docs/topics/charts/#schema-files)
