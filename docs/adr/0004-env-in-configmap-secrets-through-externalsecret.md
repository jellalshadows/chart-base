# ADR-0004: Env vars in a ConfigMap, secrets through ExternalSecret

- **Status:** Accepted
- **Date:** 2026-09-27
- **Since:** 0.1.0

## Context

Every workload needs plain configuration (feature flags, profiles, URLs) and, often, secret material
(database passwords, API keys) as environment variables. Kubernetes offers two native objects for
this, ConfigMap and Secret, and the Kubernetes documentation is explicit about the difference:
*"ConfigMap does not provide secrecy or encryption"* — a Secret gets a separate, stricter RBAC
surface (`secrets` is a distinct API resource that can be granted independently of `configmaps`,
and kubelet/etcd handle it differently). Putting a password in a ConfigMap, or in `values.yaml`
committed to a Git repository, defeats that boundary regardless of which object holds it at
runtime.

chart-base does not accept secret *values* in its own values contract at all: `externalSecret.data`
only holds references to secret material that already lives in an external store (a `key`, an
optional `property`), rendered into an `external-secrets.io/v1` `ExternalSecret` that the External
Secrets Operator (ESO) resolves into a real Kubernetes `Secret`. The chart itself, and the umbrella's
`values.yaml`, never see the secret's plaintext.

Plain configuration goes through `config`, rendered into a ConfigMap. Values coming from a
`values.yaml` file are parsed by Helm as YAML, and YAML has no distinct integer type wide enough to
avoid float64 for large numbers: a key like `10000000` is read as a float64 and `toString` renders it
as `1e+07`, corrupting the value. `templates/configmap-env.yaml` avoids this by rendering string
values with `quote` and every other type with `toJson | quote` instead of `toString`.

## Decision

- `config` (a flat map of string/number/boolean) renders into ConfigMap `<fullname>-env`
  (`templates/configmap-env.yaml`), only when `config` is non-empty. Each entry is rendered as
  `{{ $value | quote }}` when the value is already a string, and as `{{ $value | toJson | quote }}`
  otherwise, to avoid Helm's float64 parsing turning a large integer into `1e+07`.
- `externalSecret.enabled: true` (default `false`) renders an `ExternalSecret`
  (`external-secrets.io/v1`, `templates/externalsecret.yaml`) named `<fullname>-secrets`, with
  `spec.target.name: <fullname>-secrets` and `creationPolicy: Owner`: ESO creates and owns a Secret
  of that name. `externalSecret.data` maps an environment variable name to
  `{key: <remote key>, property: <optional field>}` — a reference to the external store, never a
  literal value.
- Both objects are injected the same way, through `envFrom` on the container
  (`templates/_pod.tpl`): `envFrom[].configMapRef.name: <fullname>-env` when `config` is set,
  `envFrom[].secretRef.name: <fullname>-secrets` when `externalSecret.enabled`.
- Secret values never appear anywhere in chart-base's values contract: only remote references do.

## Consequences

- Config and secrets share one injection mechanism (`envFrom`), so a container sees both sets of
  variables the same way, with no per-variable wiring in the umbrella.
- Secret rotation happens outside a Helm deploy (ESO re-syncing on `refreshInterval`), which is why
  it needs its own reload mechanism (ADR-0006) instead of the checksum annotations used for config.
- Trade-off: `config` accepts any scalar type but is still rendered as a string in the ConfigMap (a
  Kubernetes ConfigMap's `data` only holds strings) — a consumer that needs a genuinely typed value
  inside the application must parse it back, same as with any environment variable.

## Alternatives considered

### Secret values in a ConfigMap

Kubernetes documents ConfigMaps as not providing secrecy or encryption; External Secrets Operator
only allows targeting a plain ConfigMap with `--unsafe-allow-generic-targets`, an explicitly
unsafe escape hatch, not the supported path.

### Plain Secret values written directly in `values.yaml`

Puts secret plaintext in the umbrella's Git history and in Helm's release storage (Secrets/ConfigMaps
holding release manifests), with no external rotation and no audit trail beyond Git.

### Literal values in the container's `env` list

chart-base has no `env` list in its values contract; adding one would create a second place to set
the same variable a `config` or `externalSecret` entry already covers, with no clear rule for which
one wins.

## References

- `templates/configmap-env.yaml`
- `templates/externalsecret.yaml`
- `templates/_pod.tpl`
- `values.yaml` (`config`, `externalSecret`)
- `values.schema.json` (`externalSecret.data` properties)
- [Kubernetes: Secrets](https://kubernetes.io/docs/concepts/configuration/secret/)
- [External Secrets Operator: ExternalSecret](https://external-secrets.io/latest/api/externalsecret/)
