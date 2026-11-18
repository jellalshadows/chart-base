# ADR-0064: From 1.0.0, a new values key is optional

- **Status:** Accepted — amended by [ADR-0069](0069-grpcroute-httproute-rules-and-appprotocol.md) (1.4.0)
- **Date:** 2026-11-18
- **Since:** 1.1.0
- **Related:** [ADR-0027](0027-required-keys-in-the-schema.md) (amended), [ADR-0058](0058-the-1-0-contract-and-how-it-stays-frozen.md), [ADR-0065](0065-an-opt-in-handover-from-the-chart-s-hpa-to-keda.md)

## Context

[ADR-0027](0027-required-keys-in-the-schema.md) puts in the schema's `required` every key that the templates rely on
and whose default is not `null`: Helm deletes a key set to `null`, the schema never sees it, and without `required` a
`null` would silently flip the default.

A required key that a release adds breaks one kind of upgrade. A release installed directly and upgraded with
`helm upgrade --reuse-values` is rendered with the previous release's values, the old chart's defaults included,
instead of the new chart's defaults. The new key is missing, and the schema fails with `missing property '<key>'`.
0.3.0, 0.4.0, 0.5.0, 0.6.0 and 0.9.0 did this, as the [upgrade guide](../upgrading.md) records. Before 1.0 each of
those was a breaking change, documented. From 1.0.0 the contract of
[ADR-0058](0058-the-1-0-contract-and-how-it-stays-frozen.md) changes only in a major, and a minor that fails an upgrade
that worked is not additive.

## Decision

- **A key added after 1.0.0 is never in `required`,** at any level, in a minor or a patch.
- **The templates read the key absent as its default.** For a boolean that defaults to `false`, `eq <key> true`, so a
  missing key or a `null` behaves as `false`. A `null` then means the default, so ADR-0027's silent flip cannot happen.
- **The test of every new key** includes the key set to `null` (Helm deletes it), with the default's render.
- **Before the release, measure it:** render the new chart with the previous release's `values.yaml` as its defaults (the
  shape of a `--reuse-values` upgrade) over every `ci/` scenario, on Helm 4.3 and 3.22.

## Consequences

- A `--reuse-values` upgrade from 1.0.x renders with every 1.x minor, unless the consumer's own values fail a check.
- It amends ADR-0027 for keys added from 1.1.0 on. The keys required up to 1.0.0 stay required: removing them from
  `required` is allowed, but not needed.
- A major may add a required key, and its upgrade notes name it.

## Alternatives considered

### Keep ADR-0027 and document each new required key

Each minor would then break `--reuse-values` for direct installs, which the 1.0 contract rules out for a minor.

### A default filled in by a helper in place of the template's own reading

It moves the default out of `values.yaml`, which helm-docs and the consumer read. The template's reading is one
expression and keeps `values.yaml` the single place for the default.

## References

- `values.schema.json`, `docs/upgrading.md` ("Every upgrade: a direct install must not use `--reuse-values`").
- Helm v3.22.0 and v4.3.0: `pkg/action/upgrade.go` (`reuseValues`).
