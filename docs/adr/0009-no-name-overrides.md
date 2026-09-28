# ADR-0009: No `nameOverride`/`fullnameOverride`

- **Status:** Accepted
- **Date:** 2026-09-27
- **Since:** 0.1.0

## Context

`helm create`'s scaffolded chart exposes two values, `nameOverride` and `fullnameOverride`, that let
a consumer replace the computed chart name or full resource name outright. chart-base has neither:
`values.yaml` defines no such keys, and `values.schema.json` sets `"additionalProperties": false` at
the top level, so a consumer who tried to set one anyway would fail schema validation immediately
(an unknown key under an alias) rather than have it silently accepted.

The reason is specific to how chart-base is consumed (ADR-0001): each component is a subchart
rendered under its own alias, and a subchart's template context only has access to its own values —
it cannot see the values of any sibling alias in the same umbrella. If two aliases in the same
umbrella both set the same `fullnameOverride`, each subchart would render its resources with that
same literal name, independently, with no way for either one to know the other did the same thing.
Neither `helm lint` nor `helm template` can catch this: both render each subchart's templates
correctly in isolation, and the collision only becomes visible as duplicate resource names in the
combined output — or, worse, at `kubectl apply` time, as one component's objects silently overwrite
another's.

The alias is chart-base's only source of identity (`chart-base.component` is `.Chart.Name`, replaced
by the alias for an aliased dependency, ADR-0001; `chart-base.fullname` is
`<release>-<component>`, ADR-0008). Two different aliases can never produce the same name by
construction, because Helm itself requires aliases to be unique within one `dependencies` list. An
override value could reintroduce exactly the collision the alias mechanism is designed to prevent.

## Decision

- chart-base's values contract has no `nameOverride` and no `fullnameOverride` key. `templates/_names.tpl`
  has no override lookup of any kind: `chart-base.component` is always `.Chart.Name`, and
  `chart-base.fullname` is always `<.Release.Name>-<component>` (ADR-0008).
- `values.schema.json`'s top-level `"additionalProperties": false` rejects any attempt to set one of
  these keys under an alias as an unknown property, at the same validation layer as any other typo.
- The alias remains the only identity a component has; renaming an alias is the only supported way to
  change a component's resource names (ADR-0008).

## Consequences

- Two components can never collide on a shared, consumer-chosen name: identity is derived, not
  declared, and Helm already enforces alias uniqueness within one `dependencies` list.
- Trade-off: an umbrella author who wants a resource name that does not match `<release>-<alias>`
  (for a migration from an existing, differently-named deployment, for instance) has no supported way
  to get one from chart-base — the alias itself is the only lever, and renaming it deletes and
  recreates every one of the component's objects (ADR-0008).

## Alternatives considered

### Keeping `nameOverride`/`fullnameOverride` (the `helm create` default)

Reintroduces exactly the collision this decision avoids: two aliases setting the same override value
render duplicate names, undetectable by `helm lint` or `helm template` because each subchart only
sees its own values.

### Keeping them with a guard against duplicates

Not implementable from inside a single alias's template render: a subchart has no visibility into
its sibling aliases' values, so nothing inside chart-base could ever detect that two aliases chose
the same override.

## References

- `templates/_names.tpl`
- `values.yaml`
- `values.schema.json`
- [ADR-0001](0001-application-chart-consumed-through-aliases.md)
- [ADR-0008](0008-names-are-release-alias-and-never-truncated.md)
