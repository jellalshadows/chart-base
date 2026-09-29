# ADR-0031: Existing Secrets are referenced by name

- **Status:** Accepted
- **Date:** 2026-09-28
- **Since:** 0.2.0
- **Related:** [ADR-0004](0004-env-in-configmap-secrets-through-externalsecret.md) (amended),
  [ADR-0030](0030-env-takes-references-only.md), [ADR-0032](0032-external-envfrom-first-env-wins.md),
  [ADR-0033](0033-component-level-reload-on-change.md)

## Context

ADR-0004 routes every secret through ExternalSecret: the value lives in a secret manager and the External
Secrets Operator (ESO) writes the Kubernetes Secret. That covers credentials someone chose and stored.
It does not cover Secrets that operators create inside the cluster, where no secret manager is
involved:

- CloudNativePG creates a `<cluster>-app` Secret with the application's database credentials.
- Strimzi's User Operator creates one Secret per `KafkaUser`.

The owner decided on 2026-09-28 that chart-base consumes such Secrets where they live, instead of
copying them anywhere. The values contract must still never carry a secret value (ADR-0004), and the
umbrella author must be able to say "this component reads the Secret `orders-db-app`".

## Decision

Existing Secrets and ConfigMaps may be referenced by name, in two ways:

- `env`: `valueFrom.secretKeyRef` or `valueFrom.configMapKeyRef` (`name`, `key`, optional `optional`),
  for single keys (ADR-0030).
- `envFrom`: `secretRef` or `configMapRef` (`name`, optional `optional`), for a whole object, with an
  optional `prefix` (ADR-0032).

Values never appear in chart values, only names and keys. Secrets that live in a secret manager still go
through `externalSecret` (ADR-0004). The chart does not create, copy or own the referenced objects.

The chart cannot check at render time that a referenced object exists. A missing reference that is not
`optional` keeps the pod in `CreateContainerConfigError`; for a Deployment the rollout then fails within
`progressDeadlineSeconds` (240 s by default, `values.yaml`), so a caller that waits for the rollout
(`helm upgrade --wait`, `--rollback-on-failure` on Helm 4 or `--atomic` on Helm 3) sees the failure. A
tool that does not wait does not.

Other workloads behave differently:

- **CronJob:** `helm --wait` does not wait for runs, so the release succeeds. The run's pod stays in
  `CreateContainerConfigError` and its Job stays active, because `job.activeDeadlineSeconds` defaults to
  `null` (`values.yaml`). With the default `concurrencyPolicy: Forbid`, later runs are skipped while that
  Job is still active, and the only trace is a Kubernetes event on the CronJob. For a CronJob that
  references external objects, set `job.activeDeadlineSeconds` so a stuck run is ended and reported as
  failed.
- **Job hook:** Helm waits for the hook Job until `--timeout` and then fails the operation.

Referenced objects are watched by Reloader as well, so a rotation performed by the operator restarts the
Deployment's pods (ADR-0033). CronJob runs and Job hooks read the current objects each time they start.

## Consequences

- Operator-created Secrets are consumed in place: no copy, no second sync loop, no extra RBAC.
- The chart's values only ever contain names and keys; ADR-0004's rule that secret values stay out of the
  values contract still holds.
- Cost: correctness depends on the operator creating the object before the pod starts. Ordering is the
  umbrella's business (for example, the database domain deployed before the application), not the
  chart's.
- Cost: a typo in a name is found at deploy time in the cluster, not at render time. Mark a reference
  `optional: true` only when the application really tolerates its absence.

## Alternatives considered

### Copying in-cluster Secrets through ESO's Kubernetes provider

Reads the Secret out of the cluster and writes it back into it: extra RBAC for ESO, a second sync loop and
a second copy of the credential to keep in step, for no gain over referencing the original. Rejected.

### Checking existence with `lookup` at render time

`lookup` returns nothing under `helm template` and client-side dry runs, so a missing-object error could
not be relied on: the same values would render in CI and fail in the cluster, or the reverse. Rejected.

## References

- `values.yaml` (`env`, `envFrom`, `progressDeadlineSeconds`),
  `values.schema.json` (`definitions.keyRef`, `definitions.objectRef`)
- `templates/_pod.tpl`, `templates/_reloader.tpl`
- README recipe "Operator-created Secrets and pod metadata"
- [Kubernetes: Secrets](https://kubernetes.io/docs/concepts/configuration/secret/)
