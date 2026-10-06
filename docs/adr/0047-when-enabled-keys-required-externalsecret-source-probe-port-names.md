# ADR-0047: When-enabled keys are required, an ExternalSecret needs a source, and a probe port name must be declared

- **Status:** Accepted
- **Date:** 2026-10-06
- **Since:** 0.7.0
- **Related:** [ADR-0027](0027-required-keys-in-the-schema.md) (amended), [ADR-0044](0044-guards-fail-the-render-helm-lint-reports-them.md), [ADR-0045](0045-null-in-configfiles-and-resources-is-absent.md)

## Context

[ADR-0027](0027-required-keys-in-the-schema.md) makes the keys the templates rely on `required`, because Helm deletes
a chart default on `null` before the schema validates. The rules that check a key while its block is enabled
(`minLength`, `minItems` in the schema's `allOf`) never saw such a key: with `--set <key>=null` and the block enabled,
0.6.0 rendered `schedule: null` (CronJob), `parentRefs: null` (HTTPRoute), `rules: null` (Ingress) and
`secretStoreRef: {"kind":null,...}` or `{...,"name":null}` (measured on Helm 4.3.0 and 3.22.0). An enabled
`externalSecret` with `data: null` rendered `spec.data: null`: Helm 4.3 then fails at the API server and Helm 3.22
stores an ExternalSecret without a source (measured); what ESO does with it was read in its source, not run. And
`data: {}` in an override file removes nothing: maps are merged.

The main container's probes are open objects. A probe `httpGet.port` or `tcpSocket.port` given by a name that no
`ports` entry declares is accepted by the API server, and the kubelet never runs the probe: it cannot resolve the
name, records a Warning event and keeps the probe's initial result, `Failure` for readiness, `Unknown` for startup and
`Success` for liveness, so nothing is restarted (kubelet `pkg/kubelet/prober` at v1.33.12 and v1.37.0, source reading;
not verified at runtime).

## Decision

- Every when-enabled rule of the schema's `allOf` except `ingress.className` (below) also requires
  its key: `cronjob.schedule` on a cronjob,
  `externalSecret.secretStoreRef.kind` and `.name`, `httpRoute.parentRefs`, `ingress.hosts`, next to `ports` and
  `prometheusRule.groups`, which were already required. A unit test nulls the key of every rule and expects a failure.
  `ingress.className` is not required: `null` keeps rendering an Ingress without a class, an open decision.
- A guard in `templates/validate.yaml`: `externalSecret.enabled` with `externalSecret.data` null, empty or absent
  fails, with one message from every values layer and its remedies. The schema's `minProperties` on `data` is
  removed.
- A guard, `chart-base.validateProbePorts` (`templates/_values.tpl`): in the startup, liveness and readiness probes of
  the main container, on every workload type, an `httpGet.port` or `tcpSocket.port` that is a string must be the name
  of an entry of `ports`; a handler that is neither a map nor `null` fails. A number, an absent `port`, `exec` and
  `grpc` are not checked. The probes stay open objects otherwise.

## Consequences

- Values that rendered a broken object fail at `helm template`, install and upgrade: the `required` keys as schema
  errors, which also fail `helm lint` of the chart itself (through an umbrella, a `null` from `-f` or `--set` passes
  lint, and Helm 4.3 lints no subchart schema when the umbrella has no `templates/`:
  [ADR-0044](0044-guards-fail-the-render-helm-lint-reports-them.md)), and the two guards with their remedies, which do
  not fail `helm lint`. The gate is `helm template` with the deploy's real values.
- `externalSecret.secretStoreRef.kind: null` may have fallen back to ESO's own default `SecretStore` on Helm 3.22
  (unverified); it now fails, because it silently flips the chart's default `ClusterSecretStore`.
- Schema-only tooling (an IDE, `helm lint`) no longer flags an enabled ExternalSecret without `data`.
- The probe guard can make `helm upgrade` fail for a release that runs today: a Deployment whose only wrong name is in
  the liveness probe, or a `job`/`cronjob` with any such probe. After the fix the liveness probe runs for the first
  time. In an umbrella, one such component blocks the whole release.

## Alternatives considered

### `required: [data]` or `minProperties` in the schema

Rejected: the schema message names no remedy, the obvious reaction (`data: {}`) keeps every inherited key, the message
differs per layer on Helm 4.3, and a later release widens the rule to "at least one source".

### Closing the main container's probe objects

Not done here: it rejects values that render today; a question for the 1.0 contract freeze.

## References

- `values.schema.json` (`allOf`), `templates/validate.yaml`, `templates/_values.tpl` (`chart-base.validateProbePorts`)
- `tests/schema_test.yaml`, `tests/validate_test.yaml`, `tests/exposure_test.yaml`, `.github/scripts/alias-contract.sh`
- Kubernetes `pkg/kubelet/prober/prober.go` and `worker.go`, v1.33.12 and v1.37.0
