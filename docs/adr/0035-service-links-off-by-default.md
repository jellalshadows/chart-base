# ADR-0035: Service links are off by default

- **Status:** Accepted
- **Date:** 2026-09-29
- **Since:** 0.3.0
- **Related:** [ADR-0010](0010-chart-version-never-restarts-pods.md) (amended),
  [ADR-0001](0001-application-chart-consumed-through-aliases.md)

## Context

When a container starts, the kubelet adds a set of environment variables for every active Service of
the pod's namespace: `{SVCNAME}_SERVICE_HOST` and `{SVCNAME}_SERVICE_PORT`, with the Service name
upper-cased and dashes turned into underscores, plus variables compatible with Docker's legacy
container links. For a Service `redis-primary` on port 6379 that is `REDIS_PRIMARY_SERVICE_HOST`,
`REDIS_PRIMARY_SERVICE_PORT`, `REDIS_PRIMARY_PORT=tcp://10.0.0.11:6379` and four
`REDIS_PRIMARY_PORT_6379_TCP*` variables (Kubernetes documentation, "Service", section "Environment
variables"). The pod field that controls it, `enableServiceLinks`, defaults to `true` (API reference,
PodSpec).

chart-base is consumed as one umbrella per business domain, installed in one namespace
([ADR-0001](0001-application-chart-consumed-through-aliases.md)), so every pod receives these variables
for every Service of every sibling component, and the list grows with the domain. The variables are also
a snapshot: a Service created after the pod started is not in them (the documentation says the Service
must exist before the client pods for the variables to be populated).

The variables collide with application settings. A Service named `redis` injects
`REDIS_PORT=tcp://<cluster IP>:6379`; an application that reads `REDIS_PORT` as a port number, and whose
component does not set that variable itself, receives a URL instead. Variables the container defines win:
the kubelet builds the environment from `envFrom` and `env` first and appends a service variable only
when no variable of that name exists (kubelet v1.33.0, `pkg/kubelet/kubelet_pods.go`,
`makeEnvironmentVariables`). The collision therefore hits the settings an application reads without the
component setting them, which is exactly where nobody looks.

`KUBERNETES_SERVICE_HOST` and `KUBERNETES_SERVICE_PORT`, which in-cluster Kubernetes clients use, come
from the `kubernetes` Service of the `default` namespace. The kubelet always adds the variables of that
Service, even when `enableServiceLinks` is `false` (kubelet v1.33.0, `pkg/kubelet/kubelet_pods.go`,
`getServiceEnvVarMap`, lines 686-696: "We always want to add environment variabled for master services
from the default namespace, even if enableServiceLinks is false").

## Decision

- `enableServiceLinks: false` is the default (`values.yaml`), rendered on the pod spec of every workload
  type, Deployment, CronJob and Job (`templates/_pod.tpl`).
- The key is a `required` boolean in `values.schema.json`: `enableServiceLinks: null` would otherwise
  delete it and silently bring back Kubernetes' `true`
  ([ADR-0027](0027-required-keys-in-the-schema.md)).
- `enableServiceLinks: true` restores Kubernetes' behavior for one component.
- Breaking change in 0.3.0 (`feat!`): the rendered pod template changes, so upgrading restarts every
  Deployment's pods once ([upgrade guide](../upgrading.md)).

## Consequences

- No variable of a sibling Service reaches a component's environment, however many components the
  domain has. Components find each other through DNS (`<release>-<alias>`, for example `vending-sales`,
  or its fully qualified `<name>.<namespace>.svc` form), which also sees Services created after the pod
  started.
- In-cluster Kubernetes clients keep working: `KUBERNETES_SERVICE_HOST`/`_PORT` are still injected. The
  e2e proves both halves: the `cronjob` scenario's run checks that `KUBERNETES_SERVICE_HOST` is set and
  that `DEPLOYMENT_CHART_BASE_SERVICE_HOST`, of the `deployment` scenario's Service installed before it,
  is not.
- Cost: a component that reads another Service's address from the service-link variables must switch
  to DNS or set `enableServiceLinks: true`.
- Cost: upgrading to 0.3.0 restarts every Deployment's pods once, through a normal rolling update
  (CronJob runs and Job hooks pick the field up at their next run). This amends
  [ADR-0010](0010-chart-version-never-restarts-pods.md): bumping chart-base still never restarts pods
  through labels or checksums, but a breaking release that changes the rendered pod template on purpose
  does, once, and the upgrade guide says so.

## Alternatives considered

### Keep Kubernetes' default and only expose the key

No restart on upgrade, but every domain namespace keeps the collision by default, and every consumer
would have to know about it and opt out component by component. Turning it off later would be the same
breaking change, with more consumers. Rejected.

### Render the field only when it is `false`

Leaving Kubernetes' default out of the manifest when `true` saves one line, but the pod spec would then
depend on a default the chart does not show. Rendering the value always keeps the manifest explicit and
the snapshots honest. Rejected.

## References

- `values.yaml` (`enableServiceLinks`), `values.schema.json`, `templates/_pod.tpl`
- `tests/pod_test.yaml`, `tests/schema_test.yaml`, `ci/cronjob-values.yaml`, `.github/scripts/e2e.sh`
- [Upgrade guide](../upgrading.md)
- [Kubernetes: Service, environment variables](https://kubernetes.io/docs/concepts/services-networking/service/#environment-variables)
- [Kubernetes v1.33.0, `pkg/kubelet/kubelet_pods.go` (master services always added)](https://github.com/kubernetes/kubernetes/blob/v1.33.0/pkg/kubelet/kubelet_pods.go#L686-L696)
