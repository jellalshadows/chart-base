# ADR-0052: With a sidecar, the HPA's built-in targets measure the main container

- **Status:** Accepted
- **Date:** 2026-10-08
- **Since:** 0.8.0
- **Related:** [ADR-0014](0014-resource-requests-required.md), [ADR-0051](0051-init-containers-and-sidecars-are-two-maps-in-one-start-order.md)

## Context

`autoscaling.targetCPUUtilizationPercentage` and `targetMemoryUtilizationPercentage` rendered pod-wide `Resource`
metrics. Pod-wide utilization sums the usage of every container that the metrics API reports against the requests of
the regular containers and the sidecars (`calculatePodRequests` in `replica_calculator.go` v1.33.12 and
`calculatePodRequestsFromContainers` v1.37.0, `getPodMetrics` in `metrics/client.go` v1.37.0; source reading). A
sidecar therefore moves the threshold: a main container with a 500m request at 80% scales at 400m; with a proxy that
requests 1 CPU it scales at 1200m of pod usage, more than a 1000m limit lets the main container use (arithmetic from
that reading, not run). A plain init container has exited before the main container starts and its requests never
count. The `ContainerResource` source names one container; it is GA since Kubernetes 1.30 (the feature gate
`HPAContainerMetrics` is gone from `kube_features.go` at v1.33.12 and v1.37.0, and `horizontal.go` handles the source
without a gate check; source reading). kube-apiserver 1.33.0 and 1.37.0 accept an HPA with `ContainerResource`
metrics, created and changed in place from `Resource` and back, with Helm 4.3.0 (server-side apply) and Helm 3.22.0
(client-side), and store exactly the rendered metrics (measured).

## Decision

When `autoscaling.enabled` and the component has at least one non-null sidecar (`chart-base.hasSidecars`, the pruned
map of `chart-base.containers`), the two built-in targets render as `ContainerResource` metrics of the main container
(`container`: the component's name, quoted): `chart-base.utilizationMetric` writes the block per target, and the
`Resource` block when there is no sidecar. A component without a non-null sidecar renders byte-identical to 0.7.0, and
init containers alone change nothing.

## Consequences

- The percentage keeps its meaning, percent of the main container's requests, whatever sidecars the pod has.
- The upgrade that adds the first sidecar changes the HPA's metric kind in the same upgrade, and removing the last
  sidecar changes it back. During the rollout the old pods have the main container too (a pod without the named
  container is ignored, the Kubernetes documentation says; not run).
- A component with sidecars cannot scale on pod-wide utilization with the built-in targets; 0.10.0's
  `autoscaling.metrics` will be the way (a `Resource` entry there is pod-wide on purpose).
- Neither the old nor the new form is proven at runtime: the e2e has no metrics-server; it checks that the API server
  stores `ContainerResource` for the main container.
- For 0.10.0, which owns `autoscaling.metrics`: its empty list must keep this path unchanged, a non-empty list is
  rendered as written, and its sentence about switching an existing HPA's metric kind must say that the built-in
  targets switch with the first sidecar.

## Alternatives considered

### Pod-wide `Resource` with sidecars too

The sidecar's requests and usage enter the sums, and the same application load gives another percentage.

### A key to choose

It would make every component with a sidecar choose a meaning that the chart can fix; changing the default later
would be breaking.

## References

- `templates/hpa.yaml`, `templates/_autoscaling.tpl` (`chart-base.utilizationMetric`), `templates/_containers.tpl`
  (`chart-base.hasSidecars`); `tests/scaling_test.yaml`; `.github/scripts/e2e.sh` (the `full` scenario's HPA).
- Kubernetes v1.33.12 and v1.37.0: `pkg/controller/podautoscaler/replica_calculator.go`, `horizontal.go`,
  `metrics/client.go`, `pkg/features/kube_features.go`.
