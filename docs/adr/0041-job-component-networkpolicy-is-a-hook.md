# ADR-0041: A job component's NetworkPolicy is a hook of its phase

- **Status:** Accepted
- **Date:** 2026-10-02
- **Since:** 0.5.0
- **Related:** [ADR-0007](0007-jobs-as-helm-hooks.md) (amended), [ADR-0039](0039-prometheus-rules-travel-with-the-component.md), [ADR-0040](0040-networkpolicy-per-component-with-sibling-references.md)

## Context

A `job` component is a Helm hook Job, and its ServiceAccount, ConfigMaps and ExternalSecret are hooks of the same
phase with weight `-10`, so that they exist before the Job's pod starts ([ADR-0007](0007-jobs-as-helm-hooks.md)).
Its NetworkPolicy ([ADR-0040](0040-networkpolicy-per-component-with-sibling-references.md)) has the same problem:

- **A regular object does not exist during the first pre-deploy run.** Helm 4.3 and 3.22 run the `pre-install`
  hooks before they create the release's regular objects (`performInstall`, `pkg/action/install.go`), and the
  `pre-upgrade` hooks before they update them. Under a namespace default-deny, a migration Job whose allows are a
  regular object has no DNS and no database on the first install, and runs with the previous revision's rules on
  every upgrade.
- **Hooks run in order.** Helm sorts a phase's hooks by weight, then name, and creates them one at a time; it waits
  for a Job, while any other kind is ready as soon as it exists (Helm 3 `watchUntilReady` watches only Jobs and
  Pods; Helm 4 reads other kinds with an always-ready status reader). "Ready" says nothing about enforcement: the
  CNI programs a policy some time after it is created, and in the meantime a pod "may be started unprotected" or,
  if isolation is already applied, with "no network connectivity at all" (Kubernetes documentation, *Pod
  lifecycle*). On EKS, the VPC CNI's default "standard mode" starts new pods with a default allow until their
  policies are configured.
- **When Helm deletes a `hook-succeeded` hook** (`pkg/action/hooks.go`, Helm 4.3 and 3.22): once every hook of the
  phase has succeeded, and also when a later hook of the phase fails: then the hooks that already succeeded are
  deleted. A Job fails when it exhausts `backoffLimit` or `activeDeadlineSeconds` (no pod of it runs any more), or when
  Helm's `--timeout` expires while it still runs: then the Job's pod keeps running after its support resources,
  this policy included, were deleted. `job.activeDeadlineSeconds` defaults to `null`.
- Hook resources are not part of the release: `helm uninstall` does not delete them (Helm documentation, *Chart
  Hooks*).

## Decision

- On a `job` component, the NetworkPolicy carries the support resources' hook annotations
  (`chart-base.supportHookAnnotations`, `templates/_hooks.tpl`): `helm.sh/hook` of `job.phase`,
  `helm.sh/hook-weight: "-10"` and `helm.sh/hook-delete-policy: before-hook-creation,hook-succeeded`. It is created,
  with the new rules, before the Job, and deleted with the other support resources.
- On `deployment` and `cronjob` components it is a regular release object.
- The documentation advises `job.activeDeadlineSeconds` below Helm's `--timeout`, and a Job that retries its first
  connections for a few seconds (the CNI's programming delay), as the e2e's Job does.

## Consequences

- The policy exists before the first pre-deploy run, so a migration works under a namespace default-deny with the
  chart's own allows. The e2e proves it: under a default-deny, a pre-deploy Job resolves and reaches the cluster DNS
  only through its own policy, and the policy is gone once the phase succeeded.
- Nothing is left behind after a successful deploy. After a failed one, the Job is left for its logs, while its
  support resources, this policy included, are deleted; the next deploy replaces the Job (`before-hook-creation`)
  and creates them again.
- Trade-off: when Helm's `--timeout` expires while the Job still runs, Helm deletes the policy and the Job's pod goes
  on without it: under a namespace default-deny it loses its allows, without one it is no longer restricted. An
  `activeDeadlineSeconds` below `--timeout` makes the Job fail first.
- Trade-off: neither Helm nor the chart can wait for the CNI to enforce the policy; the Job must tolerate a short
  delay before its first connection succeeds.
- Trade-off: on an upgrade, a pre-upgrade Job reaches a sibling only through the sibling's policy of the previous
  revision (a regular object, updated after the pre-upgrade phase): a `fromComponents` entry newly added for the Job
  takes effect only after that phase, so the first deploy with it runs the Job before the sibling allows it.
- Unlike the support resources, a component's PrometheusRule stays a regular object
  ([ADR-0039](0039-prometheus-rules-travel-with-the-component.md)): it must outlive the deploy, the policy must not.

## Alternatives considered

### A regular object

Simple, and it outlives the deploy, but it does not exist when a pre-install Job runs and has the old rules during a
pre-upgrade Job. Under a default-deny the first migration has no allows at all.

### A hook without `hook-succeeded`

No deletion window, but a permanent object outside the release that `helm uninstall` never deletes, selecting pods
that exist only while the Job runs.

### No NetworkPolicy for job components

The schema could reject `networkPolicy.enabled` on a Job, but then a Job could not run under a namespace
default-deny with chart-managed allows.

## References

- Helm v4.3.0 and v3.22.0, `pkg/action/install.go` (`performInstall`), `pkg/action/upgrade.go`,
  `pkg/action/hooks.go` (`execHook`, `deleteHooksByPolicy`), Helm v3.22.0 `pkg/kube/client.go`
  (`watchUntilReady`), Helm v4.3.0 `pkg/kube/statuswait.go` (https://github.com/helm/helm/tree/v4.3.0/pkg,
  https://github.com/helm/helm/tree/v3.22.0/pkg)
- [Helm: Chart Hooks](https://helm.sh/docs/topics/charts_hooks/)
- [Kubernetes: Network Policies, Pod lifecycle](https://kubernetes.io/docs/concepts/services-networking/network-policies/#pod-lifecycle)
- [Amazon EKS: Restrict Pod network traffic with Kubernetes network policies](https://docs.aws.amazon.com/eks/latest/userguide/cni-network-policy-configure.html) (step 1)
- `templates/networkpolicy.yaml`, `templates/_hooks.tpl`, `tests/networkpolicy_test.yaml`, `.github/scripts/e2e.sh`
