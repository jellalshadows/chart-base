# ADR-0042: An existing ServiceAccount, and namespaced RBAC whose rules are least privilege by construction

- **Status:** Accepted
- **Date:** 2026-10-03
- **Since:** 0.6.0
- **Related:** [ADR-0009](0009-no-name-overrides.md), [ADR-0013](0013-secure-by-default.md), [ADR-0027](0027-required-keys-in-the-schema.md), [ADR-0040](0040-networkpolicy-per-component-with-sibling-references.md), [ADR-0043](0043-job-component-rbac-is-a-hook.md)

## Context

Up to 0.5.0 a component runs as the ServiceAccount the chart creates (`<fullname>`) or, with
`serviceAccount.create: false`, as the namespace's `default` ServiceAccount, without a token unless
`serviceAccount.automountToken: true` ([ADR-0013](0013-secure-by-default.md)), and the chart renders no RBAC. A
component that calls the Kubernetes API (leader election with leases, its own ConfigMap, the pods of its namespace)
needed RBAC written outside the chart, and a component whose cloud identity a platform team attaches to a
ServiceAccount it owns could not run as that ServiceAccount. The facts that shape the contract (Kubernetes v1.33.12
and v1.37.0 source, the Kubernetes documentation, and measurements on kube-apiserver v1.33.0 and v1.37.0):

- **The pod's `automountServiceAccountToken` wins.** "If both the ServiceAccount and the Pod's `.spec` specify a value
  for `automountServiceAccountToken`, the Pod spec takes precedence" (*Configure Service Accounts for Pods*;
  `shouldAutomount` in the ServiceAccount admission plugin). chart-base always renders the pod's field, so an existing
  ServiceAccount's own setting never matters: measured, a pod with `true` gets the `kube-api-access` volume although
  its ServiceAccount says `false`.
- **An existing ServiceAccount still reaches into the pod.** Its `imagePullSecrets` are added to a pod that sets none,
  and its deprecated `kubernetes.io/enforce-mountable-secrets: "true"` annotation rejects a pod whose `env` or `envFrom`
  references a Secret the ServiceAccount does not list, as a component with `externalSecret.enabled` does (the
  ServiceAccount admission plugin; measured, with a deprecation warning).
- **A missing ServiceAccount is not a render error.** The admission plugin rejects the pod:
  `error looking up service account <namespace>/<name>: serviceaccount "<name>" not found`. The chart cannot check it
  beforehand: `lookup` returns nothing under `helm template` and `--dry-run`, and Argo CD renders with `helm template`.
- **Permissions of the `default` ServiceAccount reach every pod.** "Permissions given to the "default" service account
  are available to any pod in the namespace that does not specify a `serviceAccountName`" (*Using RBAC Authorization*),
  and `default` mounts a token unless told otherwise: the pods of other charts in the namespace would get the
  component's RBAC.
- **The API server validates rules shallowly.** A namespaced rule needs a verb, an API group and a resource, and cannot
  have `nonResourceURLs` (`ValidatePolicyRule`); verbs, groups and resources may be any strings (measured: `gett` and
  `podz` are accepted). kubeconform, with the schemas the `lint` job pins, does not catch a rule without `apiGroups` or
  `resources`, or `nonResourceURLs` in a Role; its 1.33.12 schema requires `roleRef.apiGroup` and its 1.37.0 schema
  does not (the field is optional in v1.37.0's types).
- **Wildcards grant the future.** "If a new resource type is added, or a new subresource is added, or a new custom verb
  is checked, the wildcard entry automatically grants access" (*Using RBAC Authorization*). `*/scale` matches the
  `scale` subresource of every resource of the rule's groups (measured).
- **Privilege-escalation prevention applies to whoever deploys.** A Role can be created or updated only by someone who
  already has "all the permissions contained in the role, at the same scope", or may `escalate`; a RoleBinding only by
  someone who has the referenced role's permissions, or may `bind` it (*Using RBAC Authorization*, privilege escalation
  prevention). A `*` is covered only by a literal `*` (`policy_comparator.go`): a deployer bound to a copy of the
  aggregated `admin` ClusterRole, which the Helm documentation recommends "if your charts create or interact with Roles
  and Rolebindings" (*Role-based Access Control*), cannot create a Role with `verbs: ["*"]`, not even on `leases`, whose
  verbs `admin` holds one by one, nor bind `cluster-admin` (measured). The error says the deployer
  `is attempting to grant RBAC permissions not currently held`. Argo CD's application controller and Flux's
  controllers are bound to cluster-admin-like roles by default, so the same values install there: the outcome depends
  on the deployer, and shows only at apply time.
- **`resourceNames` cannot restrict every request.** "You cannot restrict **deletecollection** or top-level **create**
  requests by resource name. ... the **create** limitation applies only to top-level resources, not subresources. For
  example, you can use the `resourceNames` field with `pods/exec`." (*Using RBAC Authorization*, current text; the 1.33
  text has no subresource sentence). Measured: `create` with `resourceNames` is denied for a ConfigMap, and allowed, by
  name, for `pods/exec` and `serviceaccounts/token`.
- **A binding's `roleRef` cannot change.** "If you do want to change the `roleRef` for a binding, you need to remove the
  binding object and create a replacement" (*Using RBAC Authorization*). No Helm 4.3 or 3.22 flag gets around it
  (measured: server-side apply, a three-way merge patch, `--force` and `--force-replace` all fail with `field is
  immutable` or `cannot change roleRef`).
- **A RoleBinding to an existing ClusterRole grants it in one namespace.** `view` "allows read-only access to see most
  objects in a namespace", but not Secrets, roles or rolebindings; `edit` "can be used to gain the API access levels of
  any ServiceAccount in the namespace"; `admin` adds roles and rolebindings; `cluster-admin` in a RoleBinding "gives full
  control over every resource in the role binding's namespace, including the namespace itself" (*Using RBAC
  Authorization*, user-facing roles). Role and ClusterRole names are path segment names (`ValidateRBACName`: not `.` or
  `..`, no `/` or `%`), without a length limit (measured: a 312-character RoleBinding name is created).
- **Verbs.** `kubectl auth can-i` knows `get`, `list`, `watch`, `create`, `update`, `patch`, `delete`,
  `deletecollection`, `use`, `bind`, `impersonate`, `escalate`, `approve`, `sign`, `attest` and `*` (`cani.go`). The
  *Authorization* page also names `unsafe-delete-ignore-read-errors` and Dynamic Resource Allocation's node-aware
  verbs. `approve`, `sign` and `attest` apply to certificate signers, a cluster-scoped resource that a namespaced Role
  cannot grant.
- **Some rules grant more than they name.** Kubernetes' *RBAC Good Practices* lists, among the escalation paths that a
  namespaced Role can carry: `list` and `watch` on Secrets ("effectively allow for users to reveal the Secret
  contents"), workload creation ("since Pods can run as any ServiceAccount, granting permission to create workloads
  also implicitly grants the API access levels of any service account in that namespace", and they mount its Secrets
  and ConfigMaps), the `escalate`, `bind` and `impersonate` verbs, `create` on `serviceaccounts/token`, and `patch` on
  the namespace (its Pod Security and NetworkPolicy labels). Kubernetes' own `edit` role lists `pods/attach`,
  `pods/exec`, `pods/portforward`, `pods/proxy`, `secrets` and `services/proxy` as "escalating resources"
  (bootstrap `policy.go`), and an ephemeral container, added through `pods/ephemeralcontainers`, lets its author "run
  arbitrary commands" in an existing pod (*Ephemeral Containers*).
- **ClusterRoles hold wildcard rules too.** A RoleBinding grants a ClusterRole as it is, and Kubernetes' own roles
  include wildcards: `system:controller:generic-garbage-collector` holds `get`, `list`, `watch`, `patch`, `update` and
  `delete` on every resource of every group (`controller_policy.go`), `system:kube-controller-manager` `list` and
  `watch` on all of them, Secrets included (`policy.go`). The chart cannot read a ClusterRole (no `lookup`); it sees
  only its name.
- **Cloud identities do not use the chart's token.** EKS IRSA and EKS Pod Identity (one webhook) and Azure Workload
  Identity inject a projected token of their own and never read `automountServiceAccountToken` (their webhooks' source);
  GKE Workload Identity's metadata server requests a token for the pod's ServiceAccount itself (the documented flow; no
  GKE page says so about automount in words). Azure mutates "only pods with this label",
  `azure.workload.identity/use: "true"`. The providers attach the identity per ServiceAccount name and namespace, when
  a pod is created: "All new pods launched using this Service Account will be modified" (amazon-eks-pod-identity-webhook
  README).
- Sibling charts: none validates rule content or rejects wildcards; stakater application binds its Roles to `default`
  with its default values, and bitnami silently ignores ServiceAccount annotations with `create: false`.

## Decision

- **`serviceAccount.name`** (default `null`): the name of an existing ServiceAccount of the release namespace, only with
  `serviceAccount.create: false` (with `create: true` the schema requires `null`), a DNS-1123 subdomain of at most 253
  characters, never `default` (a guard: that is `create: false` without a name). The pods run as it, and the
  RoleBindings bind it. The name is quoted where it is rendered.
- **`serviceAccount.annotations` with `create: false` fail the render**: they belong on the existing ServiceAccount, and
  its owner sets them. With `create: true` they are rendered as before.
- **`rbac.rules`**: namespaced PolicyRules, rendered in a Role `<fullname>` and bound by a RoleBinding `<fullname>`.
  **`rbac.clusterRoles`**: existing ClusterRoles, one RoleBinding `<fullname>.<ClusterRole>` each, so that a binding's
  `roleRef` never changes and removing an entry deletes its binding. A `<fullname>` is a DNS-1035 label (the chart's
  name guard), without a `.`, so the first `.` splits every binding name: two components' bindings never share a
  name, in one release or across releases (measured: `vending-chart-base.view` and
  `vending-chart-base.system:aggregate-to-view` are created and take effect on kube-apiserver v1.33.0 and v1.37.0). Every RoleBinding has one subject, the pods'
  ServiceAccount (`<fullname>` or `serviceAccount.name`) in the release namespace, and always renders
  `roleRef.apiGroup: rbac.authorization.k8s.io`. Both lists are empty by default. On a `job` component the Role and
  RoleBindings are hooks ([ADR-0043](0043-job-component-rbac-is-a-hook.md)). The chart creates no ClusterRole and no
  ClusterRoleBinding (the roadmap's out-of-scope list).
- **A strict schema for rules** (`policyRule`): `apiGroups` (the core group is `""`), `resources` and `verbs` required and
  not empty, `resourceNames` optional and not empty, nothing else (no `nonResourceURLs`); no `*` in `apiGroups`,
  `resources` (`*/scale` included) or `verbs`, nor in `resourceNames`, where it is no wildcard (`ResourceNameMatches`
  compares names literally) and would match no object; `verbs` among `get`, `list`, `watch`, `create`, `update`, `patch`,
  `delete`, `deletecollection`, `use`, `bind`, `escalate`, `impersonate`. ClusterRole names are RBAC names without a
  `*` (a `roleRef` reads it as a name, not as a wildcard), each listed once. `rbac` is `required` ([ADR-0027](0027-required-keys-in-the-schema.md)).
- **Guards** in `templates/validate.yaml`, each naming its remedies:
  - RBAC with `create: false` and no `name` fails: it would be the namespace's `default` ServiceAccount's;
  - RBAC without `serviceAccount.automountToken: true` fails: the pods would have no token (cloud identity
    annotations, which need no token, are not tied to it);
  - a rule with `resourceNames` and `deletecollection`, or `create` on a top-level resource, fails: it would never allow
    them;
  - the ClusterRole named `cluster-admin` in `rbac.clusterRoles` fails: in a namespace it is the `*` that the schema
    rejects in rules. Only that name is checked: any other ClusterRole is granted as it is, wildcard rules included;
    a deployer with only the namespace's `admin` rights cannot bind those either (a `*` is covered only by a literal
    `*`), and a cluster-admin-like GitOps controller can.
- **Documented, not validated**: whoever deploys must hold every permission it grants (or `escalate` and `bind`); that
  the ServiceAccount or the ClusterRole exists; resource names (custom resources cannot be enumerated); the rules of a
  ClusterRole other than `cluster-admin`; the main escalation paths listed above, and the ClusterRoles `edit` and
  `admin`; that handing the chart's ServiceAccount over under its own name takes two deploys, with
  `helm.sh/resource-policy: keep` first (Consequences);
  an existing ServiceAccount's `imagePullSecrets` and `enforce-mountable-secrets`; what a cloud identity needs on the pod
  (`podLabels`, `podAnnotations`, `nodeSelector`) and in a NetworkPolicy.

## Consequences

- A component that calls the API gets exactly the namespaced permissions its values list, bound only to its own
  ServiceAccount. Rules the API server would reject, a rule that would never allow what it names, a wildcard and RBAC for
  `default` fail at render time, with the component's name.
- A component can run as a ServiceAccount that a platform team owns (a cloud identity), without the chart touching it.
- Trade-off: a deployer with only the namespace's `admin` rights can install only what `admin` holds, where GitOps
  controllers bound to cluster-admin install more. A rule the deployer does not hold fails at apply time, and an upgrade
  that changes the Role needs every rule of it held again.
- Trade-off: a custom verb (a CRD's own) and the verbs the list leaves out (`approve`, `sign`, `attest`,
  `unsafe-delete-ignore-read-errors`, Dynamic Resource Allocation's node-aware verbs) cannot be granted through the
  chart.
- Trade-off: a typo in a resource name grants nothing, silently; a ClusterRole that does not exist is bound and grants
  nothing (`kubectl auth can-i` answers `no`, with a reason that names the missing role); a missing ServiceAccount shows
  only when the API server rejects the pods.
- Trade-off: only the name `cluster-admin` is rejected. Any other ClusterRole is granted as it is, wildcard rules
  included; the values reviewer must read the ClusterRole before binding it.
- Trade-off: a component that moves to an existing ServiceAccount of the same name, the chart's own `<fullname>` (to
  keep a cloud identity's trust policy, which names the namespace and the ServiceAccount), loses it in one deploy.
  Measured with Helm 4.3.0 and 3.22.0 on kube-apiserver v1.33.0 and v1.37.0: the upgrade reports `deployed`, Helm
  deletes the ServiceAccount, the Deployment does not roll (its pod template is unchanged), and a new pod is rejected
  because the ServiceAccount no longer exists. Deployed first with the annotation `helm.sh/resource-policy: keep`, the
  ServiceAccount survives the switch with the same UID, and new pods are admitted; the upgrade guide gives the two
  steps.
- Breaking: values that set `serviceAccount.annotations` with `create: false`, which 0.5.0 ignored, fail the render; the
  release is a `feat!`, and the upgrade guide names the remedy (an override file clears the annotations with `null`,
  not with `{}`, because Helm merges maps).
- The e2e proves the contract on kind: `kubectl auth can-i` as each ServiceAccount, a "yes" and a "no" per rule; a pod
  of an existing ServiceAccount that says no token gets one and calls the API (200 for what is allowed, 403 for what is
  not); the `view` binding grants nothing outside its namespace
  ([testing guide](../guides/testing.md#end-to-end-on-kind)).

## Alternatives considered

### Wildcards allowed, with the deployer requirement documented

Flexible, but a `*` grants resources and verbs that do not exist yet, and a namespace-admin deployer cannot even
install it: the same values would install under a cluster-admin GitOps controller and fail in CI. Rejecting it at
render time is the only check that does not depend on the deployer.

### Rejecting the escalation verbs too

`escalate`, `bind`, `impersonate` and `create` on `serviceaccounts/token` are rarely what an application component
needs, but some operator-like components do; they are documented as escalation paths instead.

### Naming the ServiceAccount the chart creates

Helm's best practice and what bitnami and stakater offer, but two aliases that set the same name would share one
object, the collision that [ADR-0009](0009-no-name-overrides.md) removed. `serviceAccount.name` names only a
ServiceAccount the chart does not create.

### A `roleRef` set from values

One RoleBinding whose role comes from a value is simpler, but changing that value would fail every later upgrade:
a `roleRef` cannot change, and no Helm flag gets around it. A binding per ClusterRole, named after it, never changes
its `roleRef`.

### Binding names `<fullname>-<ClusterRole>` or `<fullname>:<ClusterRole>`

A `-` reads like the chart's other suffixes, but an alias may contain `-`, so one alias's `<fullname>-<ClusterRole>`
can be another alias's `<fullname>` or binding. Measured with Helm 4.3.0 and 3.22.0: an alias `api` with
`clusterRoles: [view]` next to an alias `api-view` with `rules` renders two RoleBindings `vending-api-view`, to
different roles. A `:` cannot collide either, but it trips tools: `argocd app sync --resource` splits
`GROUP:KIND:NAME` on every `:` and needs exactly three parts (Argo CD v3.5.3, `cmd/argocd/commands/app.go`); Argo CD
v2.7.0 and v2.8.0 split their tracking annotation on every `:` too (`util/argo/resource_tracking.go`; v3.5.3 splits it
into three parts at most); and `:` is a reserved character in Windows file names (Microsoft, *Naming Files, Paths, and
Namespaces*). A `.` is valid in an RBAC name and appears in neither problem.

### Rejecting ClusterRoles with wildcard rules, or a `system:` prefix

The chart cannot read a ClusterRole's rules (no `lookup`), only its name. A list of names to reject is never complete,
and a prefix rule would also reject roles such as `system:aggregate-to-view` that grant little. `cluster-admin`, the
name that means every verb on every resource, is the one name rejected; the rest is documented.

### RBAC for the default ServiceAccount behind an opt-in key

A key whose only purpose is to accept a posture that grants the component's permissions to every other pod of the
namespace that runs as `default`.

### Checking that the ServiceAccount and the ClusterRole exist

`lookup` returns nothing under `helm template`, `--dry-run` and Argo CD: the check would fail or pass depending on how
the chart is rendered.

### ClusterRoles and ClusterRoleBindings

Cluster-scoped RBAC breaks multi-tenancy (the roadmap's out-of-scope list); a RoleBinding to an existing ClusterRole
stays in the namespace.

## References

- [Kubernetes: Using RBAC Authorization](https://kubernetes.io/docs/reference/access-authn-authz/rbac/) (referring to
  resources, user-facing roles, privilege escalation prevention, service account permissions)
- [Kubernetes: Role Based Access Control Good Practices](https://kubernetes.io/docs/concepts/security/rbac-good-practices/)
  (privilege escalation risks)
- [Kubernetes: Ephemeral Containers](https://kubernetes.io/docs/concepts/workloads/pods/ephemeral-containers/)
- [Kubernetes: Authorization, request verbs](https://kubernetes.io/docs/reference/access-authn-authz/authorization/#determine-the-request-verb)
- [Kubernetes: Configure Service Accounts for Pods](https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/)
- Kubernetes v1.37.0 and v1.33.12: `plugin/pkg/admission/serviceaccount/admission.go`,
  `pkg/apis/rbac/validation/validation.go` (`ValidatePolicyRule`, `ValidateRBACName`),
  `pkg/registry/rbac/escalation_check.go`,
  `staging/src/k8s.io/component-helpers/auth/rbac/validation/policy_comparator.go`,
  `staging/src/k8s.io/kubectl/pkg/cmd/auth/cani.go`, `plugin/pkg/auth/authorizer/rbac/bootstrappolicy/policy.go` and
  `controller_policy.go` (https://github.com/kubernetes/kubernetes/tree/v1.37.0)
- argoproj/argo-cd v3.5.3 `cmd/argocd/commands/app.go` (`parseSelectedResources`) and v2.7.0, v2.8.0 and v3.5.3
  `util/argo/resource_tracking.go` (`ParseAppInstanceValue`);
  [Microsoft: Naming Files, Paths, and Namespaces](https://learn.microsoft.com/en-us/windows/win32/fileio/naming-a-file)
- [Helm: Role-based Access Control](https://helm.sh/docs/topics/rbac/);
  [Helm: Chart Development Tips and Tricks](https://helm.sh/docs/howto/charts_tips_and_tricks/) (`helm.sh/resource-policy: keep`)
- aws/amazon-eks-pod-identity-webhook v0.6.17, `README.md` and `pkg/handler/handler.go`;
  [Amazon EKS: EKS Pod Identity](https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html); Azure
  Workload Identity v1.6.3, `docs/book/src/topics/service-account-labels-and-annotations.md` and `pkg/webhook/webhook.go`;
  [GKE: Workload Identity Federation for GKE](https://docs.cloud.google.com/kubernetes-engine/docs/concepts/workload-identity)
- `values.yaml` (`serviceAccount`, `rbac`), `values.schema.json` (`serviceAccount`, `rbac`, `policyRule`, `rbacName`),
  `templates/role.yaml`, `templates/rolebinding.yaml`, `templates/_rbac.tpl`, `templates/_pod.tpl`,
  `templates/validate.yaml`, `tests/rbac_test.yaml`, `ci/full-values.yaml`, `.github/scripts/e2e.sh`,
  `.github/scripts/alias-contract.sh`
