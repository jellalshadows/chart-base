# ADR-0059: One probe contract for every container

- **Status:** Accepted
- **Date:** 2026-11-17
- **Since:** 0.12.0
- **Related:** [ADR-0011](0011-strict-draft-07-schema.md), [ADR-0045](0045-null-in-configfiles-and-resources-is-absent.md), [ADR-0047](0047-when-enabled-keys-required-externalsecret-source-probe-port-names.md) (amended), [ADR-0051](0051-init-containers-and-sidecars-are-two-maps-in-one-start-order.md) (amended), [ADR-0058](0058-the-1-0-contract-and-how-it-stays-frozen.md)

## Context

Up to 0.11.0 the chart had two probe contracts. A sidecar's probes were the closed `definitions.probe` since 0.8.0:
exactly one of `exec`, `httpGet`, `tcpSocket` or `grpc`, no `host`, the five int32 timing fields `minimum: 0`,
`terminationGracePeriodSeconds` `minimum: 1`, `grpc.port` an integer, rendered without their `null` fields
(ADR-0051). The main container's `probes.startup`, `liveness` and `readiness` were open objects (`{"type": "object"}`)
rendered as written. ADR-0051 recorded the two contracts as temporary, until the 1.0 freeze: after 1.0, closing an
open object is a major forever, and two contracts would be frozen.

Measured with the 0.11.0 chart on Helm 4.3.0 and 3.22.0 (`helm template`, exit 0 each), all values that fail later:

- a gRPC port given by name: the first real umbrella (`jellalshadows/domain-boutique`, finding G2) had 18 such probes
  on nine services, which `helm template` and `helm lint --strict` accept and kubeconform and the API server reject
  (`expected numeric ... got string`);
- `httpGet.host`, which Pod Security baseline rejects from policy v1.34;
- a misspelt field (`initialDelaySecond`), which the API server drops without a word: the probe silently loses its
  delay;
- `successThreshold: 2` on a liveness probe and `terminationGracePeriodSeconds` on a readiness probe, which the API
  server rejects, on the main container and on a sidecar alike (the closed definition admitted both);
- `periodSeconds: null`, rendered as `periodSeconds: null`.

Kubernetes v1.37.0 `pkg/apis/core/validation/validation.go` (source reading): `validateProbe` requires non-negative
timing fields and a grace period above 0; `validateLivenessProbe` and `validateStartupProbe` require a success
threshold of 1 (the API server defaults 0 to 1 before validating); `validateReadinessProbe` rejects a grace period.

## Decision

- `probes.<kind>` is an object or `null`. `{}` (the default) and `null` are no probe. Any other object is the closed
  `definitions.probe` plus the rule of its kind: `definitions.livenessProbe` for `startup` and `liveness`
  (`successThreshold` at most 1; 0 is accepted, the API server makes it 1), `definitions.readinessProbe` for
  `readiness` (no `terminationGracePeriodSeconds`; `null` is absent). A sidecar's probes use the same two definitions:
  one contract for every container that takes probes (an init container takes none: the API forbids it, ADR-0051).
- The main container's probes render from a deep copy pruned with `chart-base.pruneNulls`, as a sidecar's are: a
  `null` field or handler is left out. This is the only part of the chart-wide "a `null` means absent" rule that 0.12.0
  takes, and the closed definition forces it: one definition that admits `null` in every field must mean the same in
  both places. The API server decodes `periodSeconds: null` and no key alike, so no pod rolls for it.
- Inside a probe's handler the optional fields take `null` too: a probe's `httpGet` is
  `definitions.probeHttpGetHandler`, whose `path`, `scheme` and `httpHeaders` admit `null`, as `grpc.service` already
  did; the render prunes them, and the API server defaults a missing `path` to `/` and `scheme` to `HTTP`. 0.11.0
  rendered such a `null` on the main container, and the chart documents `null` as the way to drop a lower values
  layer's key, so rejecting it would break values that work. A `lifecycle` hook keeps `definitions.httpGetHandler`,
  where a `null` stays an error, as in 0.11.0 (its hooks are not pruned). Both share `definitions.httpHeader`. An
  `exec` handler has one field, the required `command`.
- `chart-base.validateProbePorts` stays: a named `httpGet` or `tcpSocket` port must be an entry of the container's own
  ports. Its branch that failed on a handler that is not a map is gone: the schema now types every container's handlers
  as a map or `null`, so the branch could not be reached.
- `host` stays out, and so do the alpha fields `httpGet.protocol` and `grpc.mode` (ADR-0051): the e2e enforces
  `restricted` with `enforce-version=latest`, and Pod Security baseline rejects a probe's `host` from policy v1.34.
- No int32 upper bound: a value above 2^31 is out of domain and the API server rejects it when it decodes it.

A consequence on the messages: a handler that is a string, a list, a number or a boolean, and an `httpGet` without a
`port`, fail in the schema (`at '/probes/readiness/httpGet': got string, want ...`) instead of a guard.

## Consequences

- Values that lint clean and fail at install, or never fail and silently lose a field, now fail at render with the
  key's path: G2's gRPC names, `host`, a misspelt field, the two kind rules.
- A probe moves between the main container and a sidecar unchanged, except `{}`, which is no probe on the main
  container and fails on a sidecar (below).
- A probe field that Kubernetes accepts and the definition lacks fails at render. The definition has every `Probe`
  field of Kubernetes 1.37 except the alpha ones; adding one later is additive.
- The upgrade from 0.11.0 can fail for values that rendered: the upgrade guide lists each shape and its fix.
- A sidecar's `probes.<kind>: {}` still fails (no handler), while the main container's is no probe: the main
  container's defaults are `{}`, a sidecar has no defaults. Accepting `{}` on a sidecar later is additive.

## Alternatives considered

### Keep the main container's probes open

Two contracts frozen at 1.0, and the first real umbrella's top finding (values that fail only at install) left in
place. The owner's cut of the stricter `httpRoute` checks rested on "the API server already rejects those values at
install"; a misspelt probe field is not rejected at all.

### Kind rules for the sidecars only, or the main container only

One definition per kind for every container is the point: the same probe must pass or fail the same way wherever it
is written.

### Render the main container's probes as written

A `null` would render in one place and be absent in the other, under one definition.

## References

- Kubernetes v1.37.0 `pkg/apis/core/validation/validation.go` (`validateProbe`, `validateLivenessProbe`,
  `validateStartupProbe`, `validateReadinessProbe`).
- `values.schema.json` (`definitions.probe`, `probeHttpGetHandler`, `livenessProbe`, `readinessProbe`, `sidecarProbes`,
  `probes`),
  `templates/_pod.tpl` (the main container's probes), `templates/_values.tpl` (`chart-base.validateProbePorts`).
- `tests/schema_test.yaml`, `tests/containers_guards_test.yaml`, `tests/pod_test.yaml`, `tests/validate_test.yaml`.
