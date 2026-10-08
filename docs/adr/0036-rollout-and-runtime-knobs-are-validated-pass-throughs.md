# ADR-0036: Rollout and pod runtime knobs are validated pass-throughs

- **Status:** Accepted — amended by [ADR-0044](0044-guards-fail-the-render-helm-lint-reports-them.md) (0.6.0) and [ADR-0050](0050-existing-claim-on-a-deployment-and-strategy-rollingupdate-null.md) (0.7.0)
- **Date:** 2026-09-29
- **Since:** 0.3.0
- **Related:** [ADR-0011](0011-strict-draft-07-schema.md), [ADR-0017](0017-progress-deadline-240s.md),
  [ADR-0027](0027-required-keys-in-the-schema.md)

## Context

Up to 0.2.0 chart-base rendered none of these Kubernetes fields, so a component could not set them at
all: the Deployment's `strategy`, `minReadySeconds` and `revisionHistoryLimit`; the CronJob's
`startingDeadlineSeconds` and `suspend`; the pod's `priorityClassName`, `runtimeClassName`, `dnsConfig`
and `hostAliases`. Typical needs: a rollout that never removes a pod before its replacement is available,
a CronJob paused during an incident without deleting it, a critical component scheduled ahead of others,
extra DNS search domains or `/etc/hosts` entries for a legacy host.

Kubernetes has a default for each of them (API reference v1.33): `strategy` is `RollingUpdate` with
`maxSurge` and `maxUnavailable` 25% (the absolute `maxSurge` is rounded up, `maxUnavailable` down);
`minReadySeconds` is 0; `revisionHistoryLimit` is 10; a CronJob without `startingDeadlineSeconds` has no
deadline; `suspend` is `false`; without `priorityClassName` a pod gets the default priority (the
`globalDefault` PriorityClass, or 0).

The API server rejects some combinations (`pkg/apis/apps/validation/validation.go`, Kubernetes
v1.33.0): `maxSurge` and `maxUnavailable` both 0 (`may not be 0 when maxSurge is 0`; `"0%"` counts as 0),
`rollingUpdate` with `type: Recreate` (`may not be specified when strategy type is 'Recreate'`), a
`maxUnavailable` percentage above 100% (`must not be greater than 100%`; `maxSurge` has no such cap), and a
`progressDeadlineSeconds` that is not greater than `minReadySeconds`. `dnsConfig` takes at most 3
nameservers and 32 search domains (Kubernetes documentation, "DNS for Services and Pods"). The CronJob
documentation warns that a `startingDeadlineSeconds` under 10 may prevent the CronJob from being
scheduled, because the controller checks every 10 seconds, and that unsuspending a CronJob that has no
starting deadline schedules the missed runs immediately.

An error from the API server only appears when Helm talks to the cluster, at install or upgrade time;
the chart's own checks fail at render time, in `helm template` and `helm lint` too.

## Decision

- The keys are pass-throughs with Kubernetes' defaults. `strategy`, `minReadySeconds`,
  `revisionHistoryLimit` (Deployments only), `cronjob.startingDeadlineSeconds`, `priorityClassName`,
  `runtimeClassName` and `dnsConfig` default to `null` and `hostAliases` to `[]`: nothing is rendered and
  Kubernetes' default applies. When set, the value is rendered as given (`templates/deployment.yaml`,
  `templates/cronjob.yaml`, `templates/_pod.tpl`), and an explicit `0` is rendered too
  (`revisionHistoryLimit: 0` keeps no old ReplicaSet). Integers go through `int64`, because numbers from
  values files are `float64`.
- `cronjob.suspend` defaults to `false` and is always rendered; it is `required` in the schema, so a
  `null` cannot delete it and render an empty field.
- The schema is strict (`additionalProperties: false`): `strategy.type` is `RollingUpdate` or
  `Recreate` and required, `maxSurge`/`maxUnavailable` are an integer of at least 0 or a percentage
  (`^[0-9]+%$`), a `maxUnavailable` percentage is at most 100% (`maxSurge` may exceed it, as in Kubernetes),
  `rollingUpdate` together with `Recreate` is rejected (a `not` inside `strategy`, like the
  `pdb` rule for `minAvailable` with `maxUnavailable`), the integers are at least 0, the class names are
  non-empty strings, `dnsConfig` has at most 3 `nameservers` and 32 `searches` and every option needs a
  `name` (its `value` is a string), and every `hostAliases` entry needs an `ip` and at least one hostname.
- Guards in `templates/validate.yaml`, for Deployments, cover what the schema cannot compare: `maxSurge`
  and `maxUnavailable` both 0 (parsed like the API server does, so `0%` is 0), and `minReadySeconds` not
  lower than `progressDeadlineSeconds`.
- Keys that apply to one workload type say so in their comment and are ignored by the other types, as
  `preStopSleepSeconds` already is; there is no guard for a key set on the wrong workload type.

## Consequences

- The combinations above fail at render time, with the component's name, before anything reaches the
  cluster. Other API rules on these fields are still checked only by the API server, at install or upgrade
  time: for example a `hostAliases` entry whose `ip` is not an IP address or whose hostname is not a DNS
  subdomain (`ValidateHostAliases`, `pkg/apis/core/validation/validation.go`, Kubernetes v1.33.0).
- The chart does not choose rollout values: Kubernetes' defaults stay the defaults, and a consumer who sets
  nothing gets the same rollout as in 0.2.0. The posture keys that the chart does choose
  (`progressDeadlineSeconds: 240`, the preStop sleep, the PodDisruptionBudget) are unchanged.
- A PriorityClass or RuntimeClass must exist, and the chart cannot check it at render time: the priority
  admission controller rejects a pod whose PriorityClass is not found, and the RuntimeClass admission
  plugin, also on by default, rejects a pod whose RuntimeClass does not exist (`pod rejected: RuntimeClass
  "<name>" not found`). For a Deployment the rollout then fails after `progressDeadlineSeconds`. The e2e
  creates the PriorityClass `e2e-high` and checks that the `full` scenario's pod gets priority 1000.
- `minReadySeconds` must stay below `progressDeadlineSeconds` (240 s by default,
  [ADR-0017](0017-progress-deadline-240s.md)): a larger `minReadySeconds` needs a larger deadline, and the
  guard says so at render time instead of the API server at install time.
- `cronjob.suspend` is rendered on every CronJob, so the chart owns the field: a suspension belongs in the
  values (`cronjob.suspend: true`), not only in the cluster (`kubectl patch`). A CronJob suspended by hand
  under 0.2.x must get `cronjob.suspend: true` before the upgrade to 0.3.0
  ([upgrade guide](../upgrading.md)).

## Alternatives considered

### Chart-chosen rollout defaults

For example `maxUnavailable: 0` for every Deployment. It would change the behavior of every existing
component, with a restart and a breaking release, and a large Deployment with little spare capacity may
prefer Kubernetes' 25%. Consumers who want it set it; the README has the recipe. Rejected.

### A free-form pod spec pass-through

One key merged into the pod spec as given would cover these fields and every future one, without a
schema: typos would be ignored and the chart's own fields (security context, volumes) could be
overridden without anyone noticing ([ADR-0011](0011-strict-draft-07-schema.md)). Rejected.

### Guards for keys set on the wrong workload type

An ignored key does nothing, so failing on it prevents no broken manifest. The chart already ignores
`preStopSleepSeconds` outside Deployments; the comment of each key names its workload type instead.
Rejected.

## References

- `values.yaml`, `values.schema.json`, `templates/deployment.yaml`, `templates/cronjob.yaml`,
  `templates/_pod.tpl`, `templates/validate.yaml`
- `tests/deployment_test.yaml`, `tests/cronjob_test.yaml`, `tests/pod_test.yaml`,
  `tests/schema_test.yaml`, `tests/validate_test.yaml`, `ci/full-values.yaml`, `.github/scripts/e2e.sh`
- [Kubernetes: Deployments, strategy](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/#strategy)
- [Kubernetes: CronJob, deadline for delayed Job start](https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/#starting-deadline)
- [Kubernetes: DNS for Services and Pods, Pod's DNS config](https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/#pod-dns-config)
- [Kubernetes: Pod priority and preemption](https://kubernetes.io/docs/concepts/scheduling-eviction/pod-priority-preemption/)
- [Kubernetes v1.33.0, `pkg/apis/apps/validation/validation.go` (rolling update rules)](https://github.com/kubernetes/kubernetes/blob/v1.33.0/pkg/apis/apps/validation/validation.go#L533-L544)
- [Kubernetes v1.33.0, RuntimeClass admission plugin](https://github.com/kubernetes/kubernetes/blob/v1.33.0/plugin/pkg/admission/runtimeclass/admission.go#L158)
