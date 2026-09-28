# ADR-0026: CronJob runs are kept by the history limits

- **Status:** Accepted
- **Date:** 2026-09-28
- **Since:** 0.1.0

## Context

A CronJob run's only record of what happened — its logs, its exit status, its Pod — lives in the Job object
Kubernetes creates for that run. If that Job is garbage-collected too soon after a scheduled failure (a
3 a.m. run, say), nobody looking at the cluster hours later will find anything left to inspect. Kubernetes
already ships a mechanism built for exactly this: a CronJob's own `successfulJobsHistoryLimit` and
`failedJobsHistoryLimit` keep the last N runs of each kind around specifically so they can still be
inspected later ("Jobs history limits", `kubernetes.io`).

chart-base's `workload.type: job` hook Job (ADR-0007) already has its own retention idea:
`job.ttlSecondsAfterFinished` (default `3600`) deletes a finished hook Job an hour after it completes, purely
as a bounded log-inspection window before cleanup, since a hook Job sits outside Helm's own release
bookkeeping entirely. The chart's original design carried that same TTL over onto CronJob runs as well —
but a CronJob's `jobTemplate` is a different mechanism from a hook: setting a TTL there races against, and
effectively defeats, the history limits that are supposed to keep failed runs around. A 1-hour TTL deletes a
3 a.m. failure long before anyone at 9 a.m. would look for it — at which point `failedJobsHistoryLimit`
never gets the chance to do its job, because there is nothing left for it to keep. The branch's final review
before 0.1.0 shipped caught this and corrected the plan's original wording (Spec §14.1, A12).

## Decision

- `templates/cronjob.yaml`'s `jobTemplate.spec` sets no `ttlSecondsAfterFinished` field.
- Retention of every CronJob run is governed solely by `cronjob.successfulJobsHistoryLimit` (default `3`)
  and `cronjob.failedJobsHistoryLimit` (default `1`), both read from `values.yaml` and mapped directly onto
  the CronJob object's own `spec.successfulJobsHistoryLimit`/`spec.failedJobsHistoryLimit`.
- `job.backoffLimit` (default `3`) and `job.activeDeadlineSeconds` (default `null`, no limit) still apply to
  a CronJob run's `jobTemplate.spec`, shared with `workload.type: job` — only `ttlSecondsAfterFinished` is
  excluded from the CronJob path, since it is the only one of the three that competes with the history
  limits.

## Consequences

- A failed 3 a.m. run is still there to inspect at 9 a.m. — the entire reason CronJob history limits exist
  in the first place.
- `job.ttlSecondsAfterFinished` keeps one unambiguous meaning across the chart: it only ever applies to a
  `workload.type: job` hook Job, never to a scheduled CronJob run.
- Trade-off: with no TTL at all on the CronJob path, `successfulJobsHistoryLimit`/`failedJobsHistoryLimit`
  are the *only* cleanup mechanism left for its runs. A consumer who sets both limits high, or schedules a
  CronJob very frequently, accumulates Job and Pod objects for as long as those limits allow, with no
  separate time-based backstop to bound that.

## Alternatives considered

### A TTL on CronJob runs (e.g. one hour)

With a 1-hour TTL, a failed 3 a.m. run is deleted before anyone looks at it that morning, and
`failedJobsHistoryLimit` — whose entire purpose is to keep the last failures around for inspection — never
gets a chance to apply, since the run it would have kept is already gone.

## References

- `templates/cronjob.yaml`
- `values.yaml` (`cronjob.successfulJobsHistoryLimit`, `cronjob.failedJobsHistoryLimit`, `job.backoffLimit`,
  `job.activeDeadlineSeconds`)
- Design spec §14.1 (A12)
- [Kubernetes: CronJob — Jobs history limits](https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/#jobs-history-limits)
