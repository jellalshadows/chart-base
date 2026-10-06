# ADR-0048: The entries of `httpRoute.parentRefs` and `httpRoute.matches` are closed objects

- **Status:** Accepted
- **Date:** 2026-10-06
- **Since:** 0.7.0
- **Related:** [ADR-0011](0011-strict-draft-07-schema.md), [ADR-0016](0016-httproute-first-ingress-optional.md)

## Context

Up to 0.6.0 the schema took any object as an entry of `httpRoute.parentRefs` and `httpRoute.matches`. The API server
drops a field that the HTTPRoute CRD does not define, so a misspelt key silently widened the route: `pathh: /api`
became the default match, `PathPrefix /`, and `sectioName: https` attached the route to every listener of the Gateway.
Helm 3.22 deployed it with only a warning, and Helm 4.3 did the same for a release that Helm 3 had installed
(measured with the Gateway API v1.6.2 Standard CRDs on kube-apiserver 1.33.0 and 1.37.0). A wider exposure than
written is worse than a value that does nothing.

## Decision

The entries take exactly the fields of the Gateway API v1.6.2 Standard CRD, the version CI installs, with
`additionalProperties: false` at every level (`definitions` `httpRouteParentRef`, `httpRouteMatch` and
`httpRouteValueMatch` in `values.schema.json`):

- a parentRef: `group`, `kind`, `namespace`, `name` (required), `sectionName` and `port` (1 to 65535);
- a match: `path` (`type`: `Exact`, `PathPrefix` or `RegularExpression`; `value`), `headers` and `queryParams`
  (`name` and `value`, both required; `type`: `Exact` or `RegularExpression`) and `method` (one of the nine methods of
  the CRD).

The schema mirrors the field names, types, required fields, enums and the port range. It does not mirror the
patterns, lengths, item counts, CEL rules and defaults: the API server checks those. The rendered route is unchanged.

## Consequences

- A misspelt key fails the schema at `helm lint`, `helm template`, install and upgrade, with the path of the key.
  Values that rendered with such a key now fail (the upgrade guide lists it).
- A field that a later Gateway API release adds, or an Experimental-channel field, fails until the schema adds it.

## Alternatives considered

### Open objects

Rejected: a typo silently exposes more than the values say.

## References

- `values.schema.json` (`httpRoute`, `definitions`), `templates/httproute.yaml`, `tests/schema_test.yaml`
- Gateway API v1.6.2 `standard-install.yaml`, CRD `httproutes.gateway.networking.k8s.io`, version `v1`
