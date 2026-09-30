# ADR-0037: One preStop hook: `lifecycle.preStop` requires `preStopSleepSeconds: 0`

- **Status:** Accepted
- **Date:** 2026-09-29
- **Since:** 0.3.0
- **Related:** [ADR-0036](0036-rollout-and-runtime-knobs-are-validated-pass-throughs.md)

## Context

Since 0.1.0 every Deployment's container gets a native `preStop` sleep of `preStopSleepSeconds` (default
5), so that endpoints stop sending traffic to a terminating pod before it receives SIGTERM; a guard keeps
`preStopSleepSeconds` lower than `terminationGracePeriodSeconds`. It is part of the posture that is on by
default ([roadmap principles](../roadmap.md#principles)).

Some components need their own hooks: a `preStop` that tells the application to drain, a `postStart`
that warms a cache. Kubernetes facts (API reference v1.33 and "Container Lifecycle Hooks"):

- A container has one `lifecycle.preStop` and one `lifecycle.postStart` handler, and a handler has
  exactly one action: "One and only one of the fields, except TCPSocket must be specified" (`exec`,
  `httpGet`, `sleep`).
- `tcpSocket` is "Deprecated. TCPSocket is NOT supported as a LifecycleHandler and kept for backward
  compatibility. There is no validation of this field and lifecycle hooks will fail at runtime when it
  is specified."
- The termination grace period starts before the `preStop` hook runs, and the hook and the container's
  own shutdown share it. `postStart` runs concurrently with the container's entrypoint; if either hook
  fails, the container is killed.
- The API server rejects a `sleep` action longer than the pod's `terminationGracePeriodSeconds`, in
  `postStart` or `preStop` (`validateSleepAction`, `pkg/apis/core/validation/validation.go`, Kubernetes
  v1.33.0: `sleep.Seconds > *gracePeriod` is invalid, so a sleep equal to the grace period is accepted).
- `httpGet.host` defaults to the pod IP, and the API reference suggests setting the `Host` header in
  `httpHeaders` instead. The Pod Security Standards baseline, and so restricted, only allow `host` empty in
  lifecycle hooks from policy version v1.34; enforcement applies to the pods, not to the workload
  resources that create them.

A custom `preStop` and the built-in sleep cannot both be the container's `preStop`. Letting one silently
win would either drop the drain the consumer asked for or drop the sleep without the consumer noticing.

## Decision

- `lifecycle` (`values.yaml`, default `{}`) takes `postStart` and/or `preStop`, on every workload type.
  The schema (`definitions.lifecycleHandler`) accepts exactly one of `exec` (`command`, at least one
  element), `httpGet` (`port` required, an integer or a port name; `path`, `scheme` `HTTP` or `HTTPS`,
  `httpHeaders` with `name` and `value`) or `sleep` (`seconds`, at least 1) per hook, and rejects
  `tcpSocket` and `httpGet.host` like any unknown key: a different host name goes in the `Host` header.
- Rendering (`templates/_pod.tpl`): `postStart` whenever it is set; `preStop` is `lifecycle.preStop`
  when it is set, otherwise the built-in sleep on Deployments with `preStopSleepSeconds` greater than 0.
- Guard (`templates/validate.yaml`, Deployments): `lifecycle.preStop` with `preStopSleepSeconds` greater
  than 0 fails with `lifecycle.preStop replaces the built-in preStop sleep: set preStopSleepSeconds: 0`.
  The guard `preStopSleepSeconds < terminationGracePeriodSeconds` stays.
- Guard (`templates/validate.yaml`, every workload type, because the API server validates every pod): a
  `sleep` in `postStart` or `preStop` longer than `terminationGracePeriodSeconds` fails with
  `lifecycle.<hook>.sleep.seconds (N) must not be greater than terminationGracePeriodSeconds (M)`, the API
  server's own bound (equal passes). The built-in sleep keeps its stricter guard (strictly lower).
- CronJobs and Jobs have no built-in sleep (`preStopSleepSeconds` is ignored there), so their
  `lifecycle.preStop` needs nothing else.

## Consequences

- Nothing is replaced silently: whoever adds a custom `preStop` to a Deployment also writes
  `preStopSleepSeconds: 0`, and so decides how the endpoints drain. Everybody else keeps the 5-second
  sleep.
- `postStart` works next to the built-in sleep.
- Every `sleep` is checked against `terminationGracePeriodSeconds` at render time: the built-in one strictly,
  a custom one with the API server's bound. A `preStop` command or request is not checked by anyone
  before it runs: if it outlasts the grace period, the container is killed when the period ends.
- Hooks call the pod's own IP; a hook that needs another virtual host sets the `Host` header in
  `httpHeaders`.

## Alternatives considered

### The custom hook silently wins over the sleep

The simplest rendering, but a consumer who adds a drain command would lose the endpoint-draining sleep
without being told, and nothing in the rendered manifest would say that it used to be there. Rejected.

### Chaining the sleep and the custom hook in one command

Wrapping the consumer's `preStop` in `sh -c "sleep N; <command>"` needs a shell in the image (distroless
images have none), only works for `exec`, and changes the command the consumer wrote. Rejected.

### Keep `httpGet.host`

It is dead under the chart's own posture: chart-base's pods target Pod Security restricted, which rejects a
non-empty `host` from policy version v1.34. And it would fail late: the Deployment is accepted and the pods
are rejected at admission, so the rollout stalls until `progressDeadlineSeconds`. Adding the key later is
additive; removing it later would be a breaking change. Rejected.

### Keeping the built-in sleep and ignoring `lifecycle.preStop` on Deployments

It would make the key useless where it is most needed. Rejected.

## References

- `values.yaml` (`lifecycle`, `preStopSleepSeconds`), `values.schema.json` (`definitions.lifecycleHandler`),
  `templates/_pod.tpl`, `templates/validate.yaml`
- `tests/lifecycle_test.yaml`, `tests/schema_test.yaml`, `tests/validate_test.yaml`
- [Kubernetes: Container Lifecycle Hooks](https://kubernetes.io/docs/concepts/containers/container-lifecycle-hooks/)
- [Kubernetes v1.33.0, `staging/src/k8s.io/api/core/v1/types.go` (`LifecycleHandler`)](https://github.com/kubernetes/kubernetes/blob/v1.33.0/staging/src/k8s.io/api/core/v1/types.go#L2963-L2981)
- [Kubernetes: Pod Security Standards, baseline (host probes and lifecycle hooks)](https://kubernetes.io/docs/concepts/security/pod-security-standards/#baseline)
- [Kubernetes: Pod Security Admission, workload resources and Pod templates](https://kubernetes.io/docs/concepts/security/pod-security-admission/#workload-resources-and-pod-templates)
- [Kubernetes v1.33.0, `pkg/apis/core/validation/validation.go` (`validateSleepAction`)](https://github.com/kubernetes/kubernetes/blob/v1.33.0/pkg/apis/core/validation/validation.go#L3170-L3187)
