# ADR-0017: `progressDeadlineSeconds: 240`

- **Status:** Accepted
- **Date:** 2026-09-27
- **Since:** 0.1.0

## Context

A Deployment rollout that cannot make progress — a crash-looping pod, an image that never becomes
`Ready`, a probe that never passes — does not fail on its own by default: Kubernetes' Deployment
controller only marks it `Failed` (condition `ProgressDeadlineExceeded`) after
`spec.progressDeadlineSeconds` elapses with no progress; Kubernetes' own default for this field is
`600` seconds (10 minutes).

Separately, `helm upgrade`/`helm install` with `--wait` (or `--rollback-on-failure` on Helm 4,
`--atomic` on Helm 3) has its own timeout, controlled by `--timeout`, whose default is `5m0s` (300
seconds). What Helm does with a stuck Deployment depends on its waiter. Helm 3's legacy wait keeps
polling until `--timeout` and then reports only a generic "timed out waiting for the condition",
whatever the Deployment's own deadline says. Helm 4.3's status watcher stops at a Deployment that has
failed and reports `status: Failed, message: Progress deadline exceeded`, but only once the Deployment
controller has marked it failed. A Kubernetes default of 600 seconds is longer than Helm's 300-second
default: a broken rollout would still be within its `progressDeadlineSeconds` window when Helm's
own wait already times out, so on either Helm version the operator sees Helm's generic timeout,
because Helm gives up before Kubernetes has even decided the rollout failed.

## Decision

- `progressDeadlineSeconds: 240` is chart-base's default (`values.yaml`), rendered onto every
  Deployment's `spec.progressDeadlineSeconds` (`templates/deployment.yaml`). 240 seconds is lower than
  Helm's 300-second default `--timeout`, so the Deployment controller marks the rollout `Failed` with
  `ProgressDeadlineExceeded` *before* Helm's own `--timeout` expires.
- The result: under `helm upgrade --wait` on Helm 4.3, the status watcher stops at the failed
  Deployment and reports `status: Failed, message: Progress deadline exceeded` instead of an
  undifferentiated timeout. On Helm 3 the legacy wait still keeps waiting until `--timeout`, but the
  Deployment already carries the `ProgressDeadlineExceeded` condition. Neither prints the pod's own
  reason (`CrashLoopBackOff`, a failing probe): that comes from `kubectl describe` and the events.
- This only matters when Helm is actually waiting on the resource: Helm only waits for ordinary
  resources like a Deployment when invoked with `--wait`, `--rollback-on-failure` (Helm 4) or
  `--atomic` (Helm 3); Helm 4's default wait strategy does not wait for regular (non-hook)
  resources at all without one of those flags, so
  `progressDeadlineSeconds` only changes what an operator sees, not whether Helm waits in the first
  place.

## Consequences

- A consumer running `helm upgrade --wait` (or `--rollback-on-failure` on Helm 4, `--atomic` on
  Helm 3, or any wrapper/CI pipeline that always adds `--wait`) gets a more useful signal when a
  rollout is stuck: on Helm 4.3 a failed release naming the Deployment's progress deadline, instead of
  Helm's generic timeout, and on any Helm version a Deployment already marked `Failed`.
- Trade-off: 240 seconds is shorter than what a legitimately slow-starting component might need (a
  large JVM warmup, a slow readiness probe with a long `initialDelaySeconds`) — such a component can be
  marked `Failed` even though it would have become healthy given more time, and it needs to override
  `progressDeadlineSeconds` explicitly rather than relying on the default being generous enough.
- This setting has no effect on what a plain `helm upgrade` without a wait flag reports: Helm returns
  as soon as the manifest is applied, and neither timeout is ever reached from Helm's side, whatever
  the Deployment controller decides afterwards.

## Alternatives considered

### The Kubernetes default (600 seconds)

Longer than Helm's own default `--timeout` of 300 seconds, so under a `--wait` install Helm's own
timeout error would surface first in most stuck-rollout cases, before the Deployment is marked
`ProgressDeadlineExceeded` — exactly the diagnostic loss this decision exists to avoid.

## References

- `values.yaml` (`progressDeadlineSeconds`)
- `templates/deployment.yaml`
- [Kubernetes: Deployment — Progress Deadline Seconds](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/#progress-deadline-seconds)
- [Helm: helm upgrade](https://helm.sh/docs/helm/helm_upgrade/)
