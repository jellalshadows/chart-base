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

Separately, `helm upgrade`/`helm install` with `--wait` (or `--atomic`) has its own timeout, controlled
by `--timeout`, whose default is `5m0s` (300 seconds) — Helm's wait loop gives up and reports its own
generic timeout error if the release has not settled by then, regardless of what any individual
resource's own deadline says. A Kubernetes default of 600 seconds is longer than Helm's 300-second
default: a broken rollout would still be within its Kubernetes `progressDeadlineSeconds` window when
Helm's own wait already times out, so the error the operator sees is Helm's generic "timed out waiting
for the condition", not the Deployment's own `ProgressDeadlineExceeded` reason (nor the actual pod
failure behind it, e.g. `CrashLoopBackOff` or a failing probe) — Helm gives up before Kubernetes has
even decided the rollout failed.

## Decision

- `progressDeadlineSeconds: 240` is chart-base's default (`values.yaml`), rendered onto every
  Deployment's `spec.progressDeadlineSeconds` (`templates/deployment.yaml`). 240 seconds is lower than
  Helm's 300-second default `--timeout`, so the Deployment controller marks the rollout `Failed` with
  `ProgressDeadlineExceeded` (and the underlying pod's own failure reason) *before* Helm's own wait
  loop gives up on its own generic timeout.
- The result is that a stuck rollout under a plain `helm upgrade --wait` (or `--atomic`) surfaces the
  real cause — the Deployment's condition and the failing pod's reason — instead of only Helm's
  undifferentiated timeout error.
- This only matters when Helm is actually waiting on the resource: Helm only waits for ordinary
  resources like a Deployment when invoked with `--wait` or `--atomic`; Helm 4's default wait strategy
  does not wait for regular (non-hook) resources at all without one of those flags, so
  `progressDeadlineSeconds` only changes what an operator sees, not whether Helm waits in the first
  place.

## Consequences

- A consumer running `helm upgrade --wait` (or `--atomic`, or any wrapper/CI pipeline that always adds
  `--wait`) gets a real, actionable error when a rollout is stuck, instead of Helm's generic timeout.
- Trade-off: 240 seconds is shorter than what a legitimately slow-starting component might need (a
  large JVM warmup, a slow readiness probe with a long `initialDelaySeconds`) — such a component can be
  marked `Failed` even though it would have become healthy given more time, and it needs to override
  `progressDeadlineSeconds` explicitly rather than relying on the default being generous enough.
- This setting has no effect at all on a plain `helm upgrade` without `--wait`/`--atomic`: Helm returns
  as soon as the manifest is applied, and neither timeout is ever reached from Helm's side, whatever
  the Deployment controller decides afterwards.

## Alternatives considered

### The Kubernetes default (600 seconds)

Longer than Helm's own default `--timeout` of 300 seconds, so under a `--wait`/`--atomic` install Helm's
own timeout error would surface first in most stuck-rollout cases, masking the Deployment's own
`ProgressDeadlineExceeded` condition and the underlying pod failure — exactly the diagnostic loss this
decision exists to avoid.

## References

- `values.yaml` (`progressDeadlineSeconds`)
- `templates/deployment.yaml`
- [Kubernetes: Deployment — Progress Deadline Seconds](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/#progress-deadline-seconds)
- [Helm: helm upgrade](https://helm.sh/docs/helm/helm_upgrade/)
