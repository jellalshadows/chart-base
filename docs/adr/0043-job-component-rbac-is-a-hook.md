# ADR-0043: A job component's Role and RoleBindings are hooks of its phase

- **Status:** Accepted
- **Date:** 2026-10-03
- **Since:** 0.6.0
- **Related:** [ADR-0007](0007-jobs-as-helm-hooks.md) (amended), [ADR-0041](0041-job-component-networkpolicy-is-a-hook.md) (amended), [ADR-0042](0042-existing-serviceaccount-and-namespaced-rbac.md)

## Context

A `job` component is a Helm hook Job, and its ServiceAccount, ConfigMaps, ExternalSecret and NetworkPolicy are hooks of
the same phase with weight `-10` ([ADR-0007](0007-jobs-as-helm-hooks.md),
[ADR-0041](0041-job-component-networkpolicy-is-a-hook.md)). Its Role and RoleBindings
([ADR-0042](0042-existing-serviceaccount-and-namespaced-rbac.md)) have the same problem, with facts of their own
(Helm v4.3.0 and v3.22.0 source, and measurements with both Helm versions on kube-apiserver v1.33.0 and v1.37.0):

- **A regular object does not exist during the first pre-deploy run.** Helm runs the `pre-install` hooks before it
  creates the release's regular objects (ADR-0041): with regular RBAC objects, a migration that calls the API gets 403
  on the first install, and works with the previous revision's rules on every upgrade.
- **The hooks of a phase come out in order.** Helm sorts hooks by kind (its install order: ServiceAccount, Role,
  RoleBinding, ..., Job), then, stably, by weight and name (`pkg/action/hooks.go`, `kind_sorter.go`). The
  ServiceAccount, Role and RoleBinding named `<fullname>` with weight `-10` therefore come in that order, and the
  RoleBindings `<fullname>.<ClusterRole>` after them, all before the Job (weight `0`). Measured on both Helm versions:
  created ServiceAccount, Role, RoleBinding, then the weight-0 hook, and deleted in reverse. A deployer without `bind`
  needs the Role to exist when its RoleBinding is created.
- **They are ready as soon as they exist**, for Helm 4's status reader and Helm 3's ready checker (measured: `--wait`
  with a ServiceAccount, a Role and a RoleBinding ends in about 0.3 s). On a local API server, `kubectl auth can-i` right
  after the RoleBinding was created already answered `yes`; how long another cluster's authorizer takes is not known.
- **When Helm deletes them** (`hook-succeeded`, as in ADR-0041): once the phase has succeeded, and, when a later hook of
  the phase fails, the hooks that already succeeded. If Helm's `--timeout` expires while the Job still runs, its Role and
  RoleBindings are deleted under the running pod. Measured on a local API server: the permission is gone within about
  150 ms, and once the ServiceAccount is deleted too, its token is rejected (`Unauthorized`) after the API server's
  10-second token cache; a ServiceAccount recreated with the same name does not revive it.
- **A hook whose creation fails leaves the earlier ones behind.** When Helm cannot create a hook (for example a Role the
  deployer does not hold: `attempting to grant RBAC permissions not currently held`), it returns at once: the hooks it
  created before (the ServiceAccount) stay until the next deploy's `before-hook-creation`, and the Job is never created
  (measured on both Helm versions). After a failing Job, by contrast, the earlier hooks are deleted (ADR-0041).
- **A changed `roleRef` is harmless for a hook**: `before-hook-creation` deletes the binding and creates it again
  (measured on both Helm versions), where a regular binding fails the upgrade
  ([ADR-0042](0042-existing-serviceaccount-and-namespaced-rbac.md)).
- **An existing ServiceAccount must exist before the phase.** The pre-deploy Job's pods are created before any regular
  object of the release, so its `serviceAccount.name` cannot point to a ServiceAccount that a sibling component of the
  same umbrella creates: on the first install it does not exist yet, and the API server rejects the pods.

## Decision

- On a `job` component, the Role and every RoleBinding carry the support resources' hook annotations
  (`chart-base.supportHookAnnotations`, `templates/_hooks.tpl`): `helm.sh/hook` of `job.phase`,
  `helm.sh/hook-weight: "-10"` and `helm.sh/hook-delete-policy: before-hook-creation,hook-succeeded`.
- On `deployment` and `cronjob` components they are regular release objects.
- The documentation repeats ADR-0041's advice to keep `job.activeDeadlineSeconds` below Helm's `--timeout`, says that a
  pre-deploy Job's `serviceAccount.name` must not point to a sibling's chart-created ServiceAccount, and that the Job
  should retry its first API calls for a few seconds, as the e2e's Job does.
- This amends [ADR-0007](0007-jobs-as-helm-hooks.md) (the Role and RoleBindings join the support resources) and
  [ADR-0041](0041-job-component-networkpolicy-is-a-hook.md) (when a hook's creation fails, the hooks created before it
  are not deleted).

## Consequences

- A migration can call the API on the first install, with the new rules on every upgrade. The e2e proves it: a
  pre-deploy Job lists ConfigMaps with its own token, which only its hook Role and RoleBinding allow, and they are gone
  once the phase has succeeded.
- Nothing is left behind after a successful deploy; after a failed Job, only the Job, for its logs.
- Trade-off: when `--timeout` expires while the Job still runs, its API calls are denied (403), and once its
  ServiceAccount is deleted, rejected (401). An `activeDeadlineSeconds` below `--timeout` makes the Job fail first.
- Trade-off: a hook that cannot be created, typically a Role the deployer does not hold, stops the deploy and leaves the
  Job's ServiceAccount behind until the next deploy.
- Trade-off: hooks are not part of the release (`helm uninstall` does not delete them), like the other support
  resources.
- How Argo CD's own sync semantics treat these deletions is not verified.

## Alternatives considered

### Regular objects

They outlive the deploy, but they do not exist when a pre-install Job runs, and hold the previous revision's rules
while a pre-upgrade Job runs: the first migration that calls the API would get 403.

### A hook without `hook-succeeded`

No deletion window, but permanent permissions outside the release, which `helm uninstall` never deletes, for a
ServiceAccount whose Job has finished.

### No RBAC for job components

The schema could reject `rbac` on a Job, but a migration that needs the API could not use the chart.

## References

- Helm v4.3.0 and v3.22.0, `pkg/action/hooks.go` (`execHook`, `deleteHooksByPolicy`), `pkg/action/install.go`
  (`performInstall`), `pkg/release/v1/util/kind_sorter.go` and `pkg/releaseutil/kind_sorter.go` (the install order)
  (https://github.com/helm/helm/tree/v4.3.0/pkg, https://github.com/helm/helm/tree/v3.22.0/pkg)
- [Helm: Chart Hooks](https://helm.sh/docs/topics/charts_hooks/)
- Kubernetes v1.37.0, `pkg/kubeapiserver/options/authentication.go` (the token cache)
- `templates/role.yaml`, `templates/_rbac.tpl`, `templates/_hooks.tpl`, `tests/rbac_test.yaml`, `.github/scripts/e2e.sh`
