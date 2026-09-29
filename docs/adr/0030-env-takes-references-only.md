# ADR-0030: `env` takes references only

- **Status:** Accepted
- **Date:** 2026-09-28
- **Since:** 0.2.0
- **Related:** [ADR-0004](0004-env-in-configmap-secrets-through-externalsecret.md) (amended),
  [ADR-0032](0032-external-envfrom-first-env-wins.md), [ADR-0033](0033-component-level-reload-on-change.md)

## Context

In 0.1.0 every environment variable is a literal in `config`, rendered into the ConfigMap
`<fullname>-env` and injected with `envFrom` (ADR-0004). Some values, however, exist only at runtime
or in objects the chart does not own:

- The downward API: the pod's name, namespace or labels, for example to fill `OTEL_SERVICE_NAME`
  from a pod label.
- The container's own resource limits, for example to size a runtime's heap from `limits.memory`.
- Keys of Secrets and ConfigMaps created elsewhere, for example by an operator (ADR-0031).

None of these can be written as a literal in `config`: the value is not known when the chart renders.
Kubernetes covers them with `valueFrom` on a container `env` entry, which the values contract did not
expose.

Two more forces shaped the decision. First, a literal must keep one home: if `env` also accepted
literals, the same variable could be set in `config` and in `env` with no obvious rule for which one
applies. Second, the chart must see every object a container reads by reference, because the Reloader
annotations (ADR-0033) are computed from them; an `env` list passed through untouched would hide them.

## Decision

- `env` is a map `NAME -> {valueFrom: ...}` (`values.yaml`, default `{}`). `valueFrom` holds exactly one
  of `fieldRef`, `resourceFieldRef`, `secretKeyRef` or `configMapKeyRef` (`values.schema.json`: a
  `oneOf` with one `required` per source, `additionalProperties: false`).
  - `fieldRef` requires `fieldPath` (optional `apiVersion`); `resourceFieldRef` requires `resource`
    (optional `containerName`, `divisor`).
  - `secretKeyRef` and `configMapKeyRef` require `name` and `key` and accept `optional` (boolean).
  - The variable name must match `^[A-Za-z_][A-Za-z0-9_]*$`.
- `templates/_pod.tpl` renders the entries as the container's `env`, sorted by name (Go templates
  iterate a map in key order), with `valueFrom` copied verbatim. With no `env`, no `env` key is
  rendered. The same pod spec serves the Deployment, the CronJob and the Job hook.
- Each wrong shape fails with a message that says what to do (`templates/validate.yaml`, prefixed with
  `chart-base[<component>]:`, and the JSON schema):
  - `env.FOO: bar` (a scalar) fails with `env.FOO is a literal value: literal values belong in config; env
    only takes valueFrom references`. The schema deliberately lets a scalar through to that guard, so the
    message points to `config` instead of being a JSON-schema type error.
  - A Kubernetes-style list (`- name: FOO` / `value: bar`) fails with `env is a map of NAME: {valueFrom:
    ...}, not a Kubernetes env list: literal values belong in config, references in env as a map`. The
    schema accepts an array for `env` only so that this guard, and not a type error, is what the user sees.
  - `FOO: {value: bar}` (a map without `valueFrom`) is a schema error: `missing property 'valueFrom'` and
    `additional properties 'value' not allowed`.
- `env` wins over every `envFrom` source: that is Kubernetes semantics, and ADR-0032 builds on it.

The name pattern is the classic C identifier rule. It is deliberately stricter than recent Kubernetes
versions, whose relaxed environment-variable validation also allows other characters. The strict rule
keeps a chart-base release portable across clusters and usable from shells, where a name such as `A.B`
cannot be used as a variable.

## Consequences

- One home for literals (`config`), one for references (`env`), one for secret-manager values
  (`externalSecret`). Each variable has a single obvious place.
- Every reference is visible to chart-base, so the Reloader annotations list the referenced Secrets and
  ConfigMaps (ADR-0033).
- The downward API and `resourceFieldRef` work without wrapper scripts in the image.
- Cost: a Kubernetes user who pastes `- name: FOO` / `value: bar` finds that literals are refused. The
  error message names `config` and says `env` is a map, which is the fix.
- Cost: `resourceFieldRef.resource` and `fieldRef.fieldPath` are only checked for being non-empty; the
  API server validates the actual path when the pod is created.
- Cost: the strict name pattern rejects names that some clusters would accept.

## Alternatives considered

### Literals in `env` as well

Two places for the same setting (`config` and `env`), with a precedence rule to remember and a
ConfigMap checksum that would no longer cover every literal. Rejected; ADR-0004 had already reached the
same conclusion for a literal `env` list.

### Passing the container `env` list through verbatim

No validation, no way to reject a literal, and the chart could not tell which Secrets and ConfigMaps a
container references, so it could not build the Reloader annotations. Rejected.

## References

- `values.yaml` (`env`), `values.schema.json` (`env`, `definitions.keyRef`)
- `templates/_pod.tpl`, `templates/validate.yaml`
- `tests/env_test.yaml`, `tests/validate_test.yaml`
- [Kubernetes: ConfigMaps](https://kubernetes.io/docs/concepts/configuration/configmap/)
- [Kubernetes: Secrets](https://kubernetes.io/docs/concepts/configuration/secret/)
