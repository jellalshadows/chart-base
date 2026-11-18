# ADR-0066: An entry-level `config` for literal variables

- **Status:** Accepted
- **Date:** 2026-11-18
- **Since:** 1.2.0
- **Related:** [ADR-0051](0051-init-containers-and-sidecars-are-two-maps-in-one-start-order.md) (amended), [ADR-0058](0058-the-1-0-contract-and-how-it-stays-frozen.md), [ADR-0064](0064-from-1-0-0-a-new-key-is-optional.md)

## Context

An init container or a sidecar takes `env` as references only (`NAME: {valueFrom: ...}`), and a literal fails
([ADR-0051](0051-init-containers-and-sidecars-are-two-maps-in-one-start-order.md)). A literal could reach it in two
ways only. It could go in `args`, which works only for a program that reads flags. Or it could go in the component's
`config` with `inheritEnv: true`, which brings the main container's whole environment, the Secret's keys included.

The first real umbrella hit this (finding G4 of `domain-boutique`, deferred by 0.12.0): an init container that reads
its settings from variables. cloud-sql-proxy's `CSQL_PROXY_*` settings are the same shape for a sidecar.

## Decision

- **`config` on an entry** (`initContainers.<name>.config`, `sidecars.<name>.config`): a map of `NAME: value`, a string,
  a number or a boolean. The name follows the main container's variable names (`envName`). Optional
  ([ADR-0064](0064-from-1-0-0-a-new-key-is-optional.md)). As every field of an entry, `config: null` is none and
  `NAME: null` is absent.
- **Rendered in the entry's `env`, after the references, by name,** each as `{name, value}`, with the value as a string,
  converted as the component's `config` is (`chart-base.configValue`: a number through `toJson`, so `10000000` is not
  `1e+07`). The kubelet expands `$(NAME)` of a variable defined before it, so a literal can be built from a reference
  (`"pod-$(POD_NAME)"`) or from an earlier literal.
- **No ConfigMap.** The values are in the pod template, so a change rolls the pod as any change of the entry does.
- **Two guards:** a name in both the entry's `env` and its `config` fails (one variable, one source). With
  `inheritEnv: true`, a `config` name that the main container already receives fails, as an `env` name already does. An
  explicit variable would otherwise hide the inherited one without a word.
- **The remedy of a literal in an entry's `env`** now names the entry's `config`. It used to name `args`, or the
  component's `config` with `inheritEnv`. A message is not part of the contract.

## Consequences

- It amends ADR-0051: an entry takes literals of its own, and still inherits nothing unless `inheritEnv` is set.
- The full scenario's sidecar `shipper` takes a reference and two literals, one of them built with `$(POD_NAME)`. The
  kind e2e reads its environment as the kubelet set it (`/proc/1/environ`).
- A `Secret` value never goes in `config`: it is rendered in the pod template, readable by anyone who can read the
  Deployment. `env` with `secretKeyRef` or `externalSecretKeyRef` stays the way.

## Alternatives considered

### A literal in `env` (`NAME: value`)

It mixes two shapes in one map, and an overlay that changes a variable from a literal to a reference changes its type.
The main container already separates them (`config` and `env`). The entries follow it.

### A ConfigMap per entry, injected with `envFrom`

It adds an object per entry and a checksum to roll the pod. `envFrom` values are not expanded, so `$(NAME)` would not
work. Inline values roll the pod by themselves.

## References

- `templates/_containers.tpl` (`chart-base.configValue`, `chart-base.entryContainer`), `templates/configmap-env.yaml`,
  `templates/validate.yaml`, `values.schema.json` (`definitions.initContainer`, `definitions.sidecar`),
  `tests/containers_test.yaml`, `tests/containers_guards_test.yaml`, `ci/full-values.yaml`, `.github/scripts/e2e.sh`.
- Kubernetes: dependent environment variables (`$(VAR_NAME)` in `env[].value`), `pkg/kubelet/kubelet_pods.go`
  (`makeEnvironmentVariables`).
