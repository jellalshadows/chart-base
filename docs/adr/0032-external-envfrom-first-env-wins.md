# ADR-0032: External `envFrom` sources first, `env` wins

- **Status:** Accepted
- **Date:** 2026-09-28
- **Since:** 0.2.0
- **Related:** [ADR-0004](0004-env-in-configmap-secrets-through-externalsecret.md),
  [ADR-0030](0030-env-takes-references-only.md), [ADR-0031](0031-existing-secrets-referenced-by-name.md)

## Context

With `envFrom` (ADR-0031) a container can import whole ConfigMaps and Secrets next to the chart's own
`<fullname>-env` (from `config`) and `<fullname>-secrets` (from `externalSecret`). Two objects can define
the same key, so an order has to be chosen. Kubernetes fixes two rules: when a key exists in several
`envFrom` sources the last source wins, and the container's `env` wins over every `envFrom` source.

The component's own explicit values (`config`, `externalSecret`) are the ones the umbrella author wrote
for this component. A bulk import of an object someone else maintains must not silently replace them.

## Decision

- The container's `envFrom` is, in order: the `envFrom` entries as listed in values, then
  `<fullname>-env` when `config` is set, then `<fullname>-secrets` when `externalSecret.enabled`
  (`templates/_pod.tpl`). `env` is rendered on top of all of them.
- Therefore `config` and `externalSecret` are never overridden by an imported source, and `env` wins over
  everything.
- An `env` key that also exists in `config` or in `externalSecret.data` fails validation (`env.<NAME>
  duplicates a key of config or externalSecret.data: literal values belong in config, secrets in
  externalSecret, references in env`, `templates/validate.yaml`). Two explicit definitions of one
  variable in one component are a mistake, not a precedence question.
- Duplicates between `env` and the imported sources, or among the imported sources, cannot be checked:
  the chart cannot see the keys of objects it does not own. `prefix` (pattern
  `^[A-Za-z_][A-Za-z0-9_]*$`) keeps an imported source from colliding.
- The order is pinned by a test in `tests/env_test.yaml` ("injects external envFrom sources BEFORE the
  chart's own config and secrets"), which fails if the external sources move after the chart's own.

## Consequences

- The rule to remember is short: what the component says itself wins over what it imports.
- A shared ConfigMap can be imported without the risk of it overriding a local setting.
- Cost: an imported source cannot override the component's `config`; to change a value, change the
  component's own `config`, or use `env`, which wins.
- Cost: collisions among imported sources are decided by list order, and the chart cannot warn about
  them. Use `prefix` to keep them apart.

## Alternatives considered

### External sources last

An imported ConfigMap could silently override the component's `config`, and the umbrella author would
see the wrong value in the pod with nothing in the chart's values to explain it. Rejected.

### Failing on every duplicate key

Impossible for keys the chart cannot see (the contents of an imported object). The chart only checks
what it can see: the duplicates between `env`, `config` and `externalSecret.data`.

## References

- `templates/_pod.tpl`, `templates/validate.yaml`
- `values.yaml` (`env`, `envFrom`), `values.schema.json` (`envFrom`)
- `tests/env_test.yaml`, `tests/validate_test.yaml`
- [Kubernetes API: Pod, Container `envFrom` (last source wins, `env` takes precedence)](https://kubernetes.io/docs/reference/kubernetes-api/core/pod-v1/)
