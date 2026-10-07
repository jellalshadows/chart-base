# ADR-0050: An existing claim on a Deployment declares its access mode; `strategy.rollingUpdate: null` is absent

- **Status:** Accepted
- **Date:** 2026-10-07
- **Since:** 0.7.0
- **Related:** [ADR-0017](0017-progress-deadline-240s.md), [ADR-0036](0036-rollout-and-runtime-knobs-are-validated-pass-throughs.md) (amended), [ADR-0044](0044-guards-fail-the-render-helm-lint-reports-them.md), [ADR-0047](0047-when-enabled-keys-required-externalsecret-source-probe-port-names.md) (amended), [ADR-0048](0048-httproute-parentrefs-and-matches-are-closed.md) (amended), [ADR-0049](0049-volumes-are-a-map-of-typed-entries-mounted-in-the-main-container.md)

## Context

- A Deployment's default rollout (`RollingUpdate`, `maxSurge: 25%`) starts a new pod before the old one stops. A
  `ReadWriteOnce` volume that a node attaches is attached to one node at a time: on another node the new pod waits
  (`Multi-Attach error` on 1.33, `Waiting for detach` on 1.37) until `progressDeadlineSeconds`, and the rollout fails
  (source reading, not run: kind has one node, so the e2e cannot reproduce it). Only a rule at render time catches it,
  and chart-base cannot read the claim (no `lookup`).
- An override file could not remove `strategy.rollingUpdate` that other values set, and the schema's `not` rejected
  `rollingUpdate` next to `Recreate` with `at '/strategy': 'not' failed`, which names nothing.
- Measured with Helm 4.3.0 and 3.22.0 on kube-apiserver 1.33.0 and 1.37.0 (no controllers: what is measured is
  admission and the stored object), one Deployment per transition, installed and upgraded by the same Helm; the results
  are the same on both Kubernetes versions:

| Install with, then upgrade to | Helm 4.3.0 | Helm 3.22.0 |
|---|---|---|
| no `strategy`, then `{type: Recreate}` | rejected: `spec.strategy.rollingUpdate: Forbidden: may not be specified when strategy` `type` `is 'Recreate'`; server-side apply keeps the `rollingUpdate` the API server defaulted (25%, 25%), which no field manager owns. Accepted with `--server-side=false` | accepted |
| no `strategy`, then `{type: RollingUpdate, rollingUpdate: {maxSurge: 0, maxUnavailable: 1}}` | accepted | accepted |
| no `strategy`, then `{type: RollingUpdate, rollingUpdate: {maxSurge: 0}}` | accepted; stored `maxUnavailable: 25%` (the server default) | accepted; the same |
| the previous `{maxSurge: 0, maxUnavailable: 1}`, then `{type: Recreate}` | accepted: Helm owns both keys and removes them | accepted |
| `{maxSurge: 1, maxUnavailable: 0}`, then `{type: Recreate, rollingUpdate: null}` (renders `type: Recreate` alone) | accepted | accepted |
| `{type: Recreate}`, then no `strategy`, or `{maxSurge: 0, maxUnavailable: 1}`, or `{type: RollingUpdate}` | accepted (stored: the defaults; `0` and `1`; the defaults) | accepted |

## Decision

- **`volumes.<name>.claimAccessMode` declares the access mode of an existing claim**: `ReadWriteOnce` (the default),
  `ReadWriteOncePod`, `ReadWriteMany` or `ReadOnlyMany`. It is a statement about the claim, not a request; `accessMode`
  stays the request of the claim an `ephemeral` volume creates. Two rules read it: the `ReadOnlyMany` rendering
  ([ADR-0049](0049-volumes-are-a-map-of-typed-entries-mounted-in-the-main-container.md)) and the guard below. Two keys, because one key with two meanings would be carried over
  silently when an overlay changes an `ephemeral` entry into a `persistentVolumeClaim` (the guard catches the
  carried-over `accessMode` as a field of another type: measured).
- **The guard.** On a `deployment`, a `persistentVolumeClaim` entry declared `ReadWriteOnce` or `ReadWriteOncePod`
  requires `replicas` 0 or 1, `autoscaling.enabled: false`, and a strategy that adds no pod: `strategy.type: Recreate`,
  or `RollingUpdate` with `rollingUpdate.maxSurge` 0 or `"0%"` (read as the existing `maxSurge`/`maxUnavailable` guard
  reads zero). `strategy: null` and `{type: RollingUpdate}` without `maxSurge` fail: the default surges. `readOnly`
  does not lift it; `ReadWriteMany` and `ReadOnlyMany` do; `ephemeral` entries are not read (one claim per pod). The
  message names the remedies with their literal values: `strategy: {type: Recreate}` for a new component; `strategy:
  {type: RollingUpdate, rollingUpdate: {maxSurge: 0, maxUnavailable: 1}}` for a Deployment that already exists (with
  Helm 4 the API refuses a switch to Recreate in one upgrade of a Deployment created without `strategy` or with
  `{type: RollingUpdate}` only: measured; both keys are written, so that Helm owns the block and a later switch to
  Recreate removes it); `strategy: {type: Recreate, rollingUpdate: null}` from an override file over
  values that set `rollingUpdate`; `replicas` 0 or 1 and no autoscaling; or the claim's real mode in
  `claimAccessMode`.
- **`strategy.rollingUpdate: null` means absent**: the schema accepts it, and it is never rendered.
  `strategy.rollingUpdate.maxSurge: null` and `.maxUnavailable: null` stay schema errors.
- **The Recreate rule is a guard**, no longer the schema's `not`: a `rollingUpdate` next to `Recreate`, `{}` included,
  fails with its remedy. This amends [ADR-0036](0036-rollout-and-runtime-knobs-are-validated-pass-throughs.md).
- **The routes for a Deployment that already exists, on Helm 4** (each measured): stay on `{type: RollingUpdate,
  rollingUpdate: {maxSurge: 0, maxUnavailable: 1}}`; switch to Recreate in a later upgrade, once Helm owns both
  `rollingUpdate` keys; or run that one upgrade with `--server-side=false`. Going back to rolling updates needs no
  `strategy` written out.
- **CronJob and Job components get no guard.** An RWO or RWOP claim belongs to ONE component (source reading,
  unverified): a cronjob or a job that shares the claim of a running Deployment waits on another node for the
  attachment; with `job.activeDeadlineSeconds: null` and `concurrencyPolicy: Forbid` every later run is skipped without
  an error, and a hook fails the release at `--timeout`. `job.activeDeadlineSeconds` turns the wait into a failed Job,
  and `concurrencyPolicy: Allow` with such a claim waits the same way.
- **What `helm lint` checks of a schema rule, stated precisely** (this amends
  [ADR-0047](0047-when-enabled-keys-required-externalsecret-source-probe-port-names.md) and
  [ADR-0048](0048-httproute-parentrefs-and-matches-are-closed.md), whose sentences on lint are incomplete): a schema
  error, such as a misspelt key of a route entry or a missing when-enabled key, fails `helm lint` of chart-base itself
  and of an umbrella, with two limits: through an umbrella, a `null` from `-f` or `--set` that deletes a required key
  passes lint ([ADR-0044](0044-guards-fail-the-render-helm-lint-reports-them.md), measured), and Helm 4.3 lints no
  subchart schema when the umbrella has no `templates/` (measured; documented in the
  [consuming guide](../guides/consuming.md#recommendations-for-umbrella-authors), not in ADR-0044, which ADR-0047 cited
  for it). The gate stays `helm template` with the deploy's real values.

## Consequences

- The dangerous case fails at `helm template`, install and upgrade, with a remedy that can be applied to a new and to an
  existing Deployment. The guard does not fail `helm lint`
  ([ADR-0044](0044-guards-fail-the-render-helm-lint-reports-them.md)).
- A node-pinned `ReadWriteOnce` Deployment with two replicas on one node must declare `ReadWriteMany` or run one
  replica, and a false declaration goes unnoticed.
- `helm lint` and schema-only tooling no longer flag `rollingUpdate` next to `Recreate` (measured on chart-base itself:
  `helm lint --strict` exited 1 before, 0 now); `helm template` and install do.
- **Not reversible without `feat!`:** after this release, restricting claims to CronJobs and Jobs would be breaking. The
  key name `claimAccessMode` freezes at 1.0.
- The two forms differ (source reading, not run): with `maxSurge: 0` the new pod is created while the old one
  terminates (with an attachable volume on another node it waits for the detach; on the same node two pods briefly
  share the volume); `Recreate` waits until the old pods are gone. Neither protects against an eviction or a deleted
  pod. With one replica, `maxSurge: 0` alone keeps the server's `maxUnavailable: 25%`, which the deployment controller
  turns into one unavailable pod (source reading, not run).
- KEDA (0.10.0) must add `keda.enabled` to the guard.

## Alternatives considered

### Existing claims on CronJobs and Jobs only

Reversible (widening later is additive), but it leaves out real uses: a Deployment of one replica with its data, and a
`ReadWriteMany` claim shared by several replicas.

### One `accessMode` key for the request and the declaration

An `ephemeral` entry's requested `ReadWriteMany`, carried over by an overlay that changes the entry into a
`persistentVolumeClaim`, would silence the guard.

### `Recreate` as the only remedy

With Helm 4 it cannot be reached in one upgrade from a Deployment created without `strategy` (measured), so the
guard would have no remedy for an existing component.

## References

- `templates/validate.yaml` (the claim guard and the Recreate guard), `templates/deployment.yaml` (`strategy`),
  `values.schema.json` (`strategy`, `definitions.volume`), `tests/volumes_guards_test.yaml`,
  `.github/scripts/e2e.sh` (the `deployment` scenario's in-place strategy changes on Helm 4.3).
- Helm v4.3.0: `pkg/action/install.go` (`ServerSideApply: true`), `pkg/cmd/upgrade.go` (`--server-side` defaults to
  `auto`). Kubernetes v1.33.12 and v1.37.0: `pkg/apis/apps/validation/validation.go` (`rollingUpdate` "may not be
  specified when strategy `type` is 'Recreate'").
