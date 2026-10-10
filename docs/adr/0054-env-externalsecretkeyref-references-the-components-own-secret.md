# ADR-0054: `env` can reference the component's own ExternalSecret Secret (`externalSecretKeyRef`)

- **Status:** Accepted
- **Date:** 2026-10-09
- **Since:** 0.9.0
- **Related:** amends [ADR-0030](0030-env-takes-references-only.md); [ADR-0053](0053-externalsecret-datafrom-template-files-and-an-envfrom-switch.md), [ADR-0031](0031-existing-secrets-referenced-by-name.md),
  [ADR-0033](0033-component-level-reload-on-change.md)

## Context

With `externalSecret.envFrom: false` (ADR-0053) the Secret `<fullname>-secrets` is no longer injected whole, and a
variable that should come from it needs an `env` reference. A hand-written `secretKeyRef.name:
<release>-<alias>-secrets` follows the release name and the alias: the same values under another release name render
without error and the reference dangles (measured on the 0.6.0 chart under the alias `api`: the release
`vending-staging` renders the target `vending-staging-api-secrets` while the reference stays `vending-api-secrets`,
and the dangling name joins the Reloader list). chart-base's differentiator is alias-safety, and 0.7.0 already rejects
a `volumes` entry that names `<fullname>-secrets` by hand. ADR-0030 fixes `valueFrom` to exactly one of four
Kubernetes sources, copied verbatim.

## Decision

- `env.<NAME>.valueFrom.externalSecretKeyRef: {key}` is a fifth source of the one `env` definition shared by the main
  container, the init containers and the sidecars (`definitions.envVar`): a closed object with one required field,
  `key`, a Secret key (`^[-._a-zA-Z0-9]+$`, 1 to 253 characters). No `name`: the chart resolves it. No `optional`: the
  chart's own `envFrom` entry and the mount of this Secret are not optional either, and `optional: true` would turn a
  missing key into a variable that is silently unset (a consumer who needs it keeps a hand-written `secretKeyRef`).
  The schema messages are the ones of the other sources (`additional properties 'optional' not allowed`, `missing
  property 'key'`, `'oneOf' failed, subschemas 2, 4 matched` next to a second source), measured on Helm 4.3.0 and
  3.22.0.
- `chart-base.env`, the one renderer of every container's `env`, copies the Kubernetes sources as before and renders
  this one as `secretKeyRef: {name: <fullname>-secrets, key: "<key>"}`; no manifest carries `externalSecretKeyRef`. An
  init container or a sidecar with `inheritEnv: true` gets the main container's references already resolved. Under
  the alias `api`, the releases `vending` and `vending-staging` render `vending-api-secrets` and
  `vending-staging-api-secrets`, the ExternalSecret's `spec.target.name` in both (the alias contract checks it on Helm
  4.3.0 and 3.22.0).
- Guards, for the main container's `env` and for the own `env` of every non-null init container and sidecar:
  `externalSecret.enabled` must be true (this one runs while the block is disabled: the Secret is not rendered
  otherwise); and with a closed key set (ADR-0053) the key must be a delivered key, with the message ADR-0053's `items`
  guard uses. With an open key set the key is not checked (a missing key keeps the container from being created,
  `couldn't find key`: kubelet source reading at v1.33.12 and v1.37.0). The reference counts as a reader for ADR-0053's
  "`envFrom: false` requires a reader".
- Allowed while `envFrom` is true: the same key then reaches the container twice, under its own name and as `<NAME>`;
  what fails is one variable name twice (`env.FOO` while `FOO` is a delivered key of an injected Secret: the duplicate
  guard). It names a non-identifier key that an extract brings (`env.API_KEY` on key `api-key`), and gives one key to
  an init container or a sidecar whatever the main container's switch says.
- The Reloader list does not change: `<fullname>-secrets` is listed whenever the block is enabled, and the first guard
  makes that true for every reference.

This amends ADR-0030: `valueFrom` holds exactly one of `fieldRef`, `resourceFieldRef`, `secretKeyRef`,
`configMapKeyRef` or `externalSecretKeyRef`, and the last one is translated, not copied verbatim.

## Consequences

- The mixed case (a certificate as a file, a password as a variable) needs no release name or alias in the values.
- One chart-specific key sits in a Kubernetes-shaped block; removing it before 1.0 is a breaking change, and adding
  `optional` later is additive.
- An environment that disables the ExternalSecret cannot drop a main-container reference with an overlay: the main
  container's `env.<NAME>: null` is a schema error and a second source fails the `oneOf` (measured on the 0.6.0
  chart); keep such an entry in the values of the environments that enable the block. An init container's or a
  sidecar's entry is removed with `env.<NAME>: null` (ADR-0051).
- With `envFrom` on, a secret value can sit in the environment under two names.
- For 0.10.0: with `externalSecret.envFrom: false`, a KEDA `...FromEnv` parameter names the `env` NAME of an
  `externalSecretKeyRef` entry, rendered as a plain `secretKeyRef`, one of the forms KEDA resolves (the 0.10.0
  research's source reading, not checked for this case).

## Alternatives considered

### A hand-written `secretKeyRef` only

It dangles under another release name or alias, silently.

### A generated key list (`externalSecret.envKeys`)

A list cannot rename a variable nor give one key to a sidecar.

### Guards on a hand-written `secretKeyRef` named `<fullname>-secrets`

They would reject values that work today; the chart-resolved source carries the checks instead.

### Only while `envFrom` is false

The rule would differ per container (an init container without `inheritEnv` needs one key whatever the main
container's switch) without catching a failure.

## References

- `templates/_pod.tpl` (`chart-base.env`), `templates/_containers.tpl` (`chart-base.entryContainer`),
  `templates/validate.yaml`, `templates/_externalsecret.tpl` (`chart-base.notDelivered`); `values.schema.json`
  (`definitions.envVar`); `values.yaml` (`env`).
- `tests/externalsecret_pod_test.yaml`, `tests/externalsecret_guards_test.yaml`; `.github/scripts/alias-contract.sh`;
  `.github/scripts/e2e.sh` (the `worker` scenario).
- [Kubernetes: Secrets as environment variables](https://kubernetes.io/docs/concepts/configuration/secret/#using-secrets-as-environment-variables)
