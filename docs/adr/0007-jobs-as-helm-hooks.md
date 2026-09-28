# ADR-0007: `workload.type: job` is a Helm hook

- **Status:** Accepted
- **Date:** 2026-09-27
- **Since:** 0.1.0

## Context

A Kubernetes `Job`'s pod template is immutable once created (aside from a few scheduling/resource
fields on a suspended Job). A plain `Job` object rendered by a chart works on the first
`helm install`, but the second `helm upgrade` — with a new image tag, for instance — fails outright
with a "field is immutable" error from the API server, taking down the deploy of everything else in
the same release along with it. chart-base uses this workload type for run-once work that must
happen around a deploy, most commonly database migrations that must succeed *before* the rest of the
release is touched.

Helm's own hook mechanism solves the immutability problem structurally: a hook resource is deleted
and recreated according to its `helm.sh/hook-delete-policy`, so a new Job object is created on every
deploy instead of trying to update the old one in place. Helm's hooks documentation lists
`pre-install`/`pre-upgrade` as running *"before any resources are created/updated"* and
`post-install`/`post-upgrade` as running after every resource has been applied; hook resources are
outside the Helm release itself, so `helm uninstall` never removes them — deleting them is entirely
the hook's own delete policy plus a TTL.

A Job hook alone is not enough: its support resources (a `ServiceAccount`, its ConfigMaps, its
`ExternalSecret`) must already exist, with their *new* content, before the Job's pod starts, or the
Job would either deadlock on the first install (nothing exists yet) or read stale config on an
upgrade (a plain, non-hook resource is a completely separate lifecycle from the hook it is meant to
support). Making those support resources hooks of the same phase, at a lower (earlier) weight,
guarantees they are created and settled first: Helm creates and waits for hooks one at a time, in
increasing weight order. The e2e suite's "job (pre-deploy hook)" scenario
(`.github/scripts/e2e.sh`) exercises exactly this: it installs a `job` component whose container
reads `APP_MODE` from a ConfigMap, `DB_PASSWORD` from an ExternalSecret-backed Secret, and a file
from a second ConfigMap, and only passes when the Job's log shows all three were present — proving
the support resources existed, with the right content, before the Job's pod ran. The same scenario
then redeploys with a changed pod annotation to confirm the Job is recreated instead of hitting the
"field is immutable" error a plain Job would.

## Decision

- `workload.type: job` renders a Helm hook Job (`templates/job.yaml`), not a plain Job.
  `job.phase` (`pre-deploy`, the default, or `post-deploy`) selects the `helm.sh/hook` value through
  `chart-base.jobHooks` (`templates/_hooks.tpl`): `pre-deploy` → `pre-install,pre-upgrade`,
  `post-deploy` → `post-install,post-upgrade`.
- The Job itself carries `helm.sh/hook-weight: "0"` and
  `helm.sh/hook-delete-policy: before-hook-creation` (`templates/job.yaml`): the previous Job (if any)
  is deleted right before the new one is created, so every deploy gets a fresh Job object.
- The component's support resources for a `job` workload — its `ServiceAccount`, both ConfigMaps and
  its `ExternalSecret` — are hooks too, at the **same** `job.phase`, but at
  `helm.sh/hook-weight: "-10"` (lower, so earlier) with
  `helm.sh/hook-delete-policy: before-hook-creation,hook-succeeded`
  (`chart-base.supportHookAnnotations`, `templates/_hooks.tpl`, applied in
  `templates/configmap-env.yaml`, `templates/configmap-files.yaml`, `templates/externalsecret.yaml`
  and `templates/serviceaccount.yaml`). This guarantees they exist, with the new content, before the
  Job's pod starts.
- `job.backoffLimit` (default `3`), `job.activeDeadlineSeconds` (default `null`, no limit) and
  `job.ttlSecondsAfterFinished` (default `3600`) come from `values.yaml` and apply to the hook Job;
  `restartPolicy: Never` is hardcoded for it (`templates/job.yaml`).
- Because Helm waits for a Job hook and fails the release if it fails (Helm hooks documentation), a
  failing `pre-deploy` Job stops the release before anything else in it is created or updated.

## Consequences

- A `job` component behaves correctly across every deploy: no "field is immutable" error, no
  deadlock on first install, no stale config read on upgrade.
- Trade-off: hook resources are outside the Helm release's own bookkeeping — `helm uninstall` does
  not remove them, and a failed Job (plus its logs) is deliberately left behind for debugging, which
  means a `job` component's Jobs are not visible in `helm get manifest` history the way a normal
  resource would be, and rely on `ttlSecondsAfterFinished` for cleanup.
- A broken `pre-deploy` migration blocks the entire domain's release until fixed, by design
  (fail-fast), which is a real operational cost when the failure is not actually the migration's
  fault (e.g. a flaky external dependency).

## Alternatives considered

### A plain Job (no hook annotations)

Works on the first install, then fails every subsequent `helm upgrade` with a "field is immutable"
error from the API server, because a Job's pod template cannot be updated in place — exactly the
failure the e2e "job" scenario's second deploy is written to catch.

### A Job named after the release revision (e.g. suffixed with `.Release.Revision`)

Avoids the immutability error by never reusing a name, but gives up ordering entirely: nothing
guarantees the Job runs before the rest of the release is applied, and nothing blocks the rollout if
it fails — the whole reason to run a migration as a `pre-deploy` step. Old Jobs would also accumulate
with no automatic cleanup.

## References

- `templates/job.yaml`
- `templates/_hooks.tpl`
- `templates/configmap-env.yaml`, `templates/configmap-files.yaml`, `templates/externalsecret.yaml`, `templates/serviceaccount.yaml`
- `values.yaml` (`job`)
- `.github/scripts/e2e.sh`
- [Helm: Chart Hooks](https://helm.sh/docs/topics/charts_hooks/)
