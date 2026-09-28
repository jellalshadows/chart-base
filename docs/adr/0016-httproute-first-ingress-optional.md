# ADR-0016: HTTPRoute first, Ingress optional

- **Status:** Accepted
- **Date:** 2026-09-27
- **Since:** 0.1.0

## Context

A generic chart that wants to expose HTTP components needs to pick a primary exposure API, because the
two Kubernetes networking APIs for HTTP ingress differ in what they can express and in where the
ecosystem is heading. The Ingress API (`networking.k8s.io/v1`) has been stable since it graduated to
GA and has not gained new capabilities since; it also ties routing behavior to
controller-specific annotations (there is no portable way to express a path rewrite, for instance,
without picking a controller and its annotation vocabulary). ingress-nginx, the controller most charts
default to, was retired in March 2026 — a chart that keeps defaulting to nginx-flavored Ingress
annotations is defaulting to a controller that is no longer maintained. The Gateway API
(`gateway.networking.k8s.io`) was designed to replace Ingress with a portable, controller-neutral model
and continues to receive new features; `HTTPRoute` is its equivalent of an HTTP-routing Ingress.

Consumers on a cluster that already runs a Gateway API implementation get a fully portable route with
no controller-specific configuration in chart-base at all. Consumers on a cluster without one still need
a way in — dropping Ingress entirely would leave them with no supported exposure path — so Ingress stays
available, but as a plain, controller-neutral fallback: a `className` and free-form `annotations`, with
no controller's annotation vocabulary baked into the chart's defaults.

## Decision

- `httpRoute.enabled: false` by default; when set, `templates/httproute.yaml` renders an `HTTPRoute`
  (`gateway.networking.k8s.io/v1`), gated to Deployments and to `service.enabled: true` (the schema
  requires `httpRoute.parentRefs` to have at least one entry and `service.enabled: true` when
  `httpRoute.enabled`). The e2e suite installs the Gateway API CRDs at the **standard** release channel,
  version `v1.6.2` (`GATEWAY_API_VERSION` in `.github/workflows/ci.yaml`, applied from
  `standard-install.yaml` in `.github/scripts/e2e.sh`).
- `ingress.enabled: false` by default; when set, `templates/ingress.yaml` renders a plain
  `networking.k8s.io/v1` Ingress, gated the same way (Deployments, `service.enabled: true`). It is
  controller-neutral: the schema requires `ingress.className` (no default, a consumer must name their
  cluster's IngressClass) and `ingress.annotations` is a free-form map the consumer fills in — the chart
  adds no controller-specific annotation of its own (no nginx `rewrite-target`, no default
  `ingressClassName`).
- Both resources back onto this component's own Service: `HTTPRoute`'s `backendRefs` and Ingress's
  backend both target the first entry of `.Values.ports` (by port number for `HTTPRoute`, by port name
  for Ingress).
- A `Gateway` (the resource an `HTTPRoute` attaches to via `parentRefs`) is provisioned by the platform,
  not by chart-base — the chart only renders the route. The Gateway's listener must itself allow routes
  from the application's namespace (`allowedRoutes`); a `Gateway`'s default only allows routes from its
  own namespace, so a route from another namespace is silently not attached unless the platform
  configures `allowedRoutes` to permit it (documented for consumers in the README's
  [Rules for consumers](../../README.md#rules-for-consumers)).

## Consequences

- Every HTTP-exposed component gets a portable route with zero controller-specific configuration when
  the cluster has a Gateway API implementation, and still has a working fallback when it does not.
- Trade-off: a consumer on a cluster with only an Ingress controller gets none of chart-base's opinion
  on how to configure it — no default annotations, no default `className` — which means every
  Ingress-only consumer has to know their controller's own annotation vocabulary and set it themselves;
  the chart trades convenience for staying controller-neutral.
- A route or Ingress that a consumer enabled but that never gets traffic because the Gateway's
  `allowedRoutes` does not permit the application's namespace fails silently from chart-base's point of
  view — the `HTTPRoute` object is created and reports as accepted-by-the-controller, but nothing
  guarantees the platform side actually attached it; this is a cross-team coordination point the chart
  cannot detect on its own.

## Alternatives considered

### Ingress with nginx-flavored annotations by default

Would give consumers a working default out of the box on the (previously common) clusters running
ingress-nginx, but bakes in a dependency on a specific controller's annotation vocabulary into a chart
that is meant to be controller-neutral, and defaults to a controller that was retired in March 2026 —
new consumers would be defaulting into a project with no further maintenance.

## References

- `templates/httproute.yaml`
- `templates/ingress.yaml`
- `values.yaml` (`httpRoute`, `ingress`)
- `values.schema.json` (`httpRoute`, `ingress`)
- `.github/workflows/ci.yaml` (`GATEWAY_API_VERSION`), `.github/scripts/e2e.sh`
- [README: Rules for consumers](../../README.md#rules-for-consumers)
- [Gateway API: HTTPRoute](https://gateway-api.sigs.k8s.io/api-types/httproute/)
- [Gateway API: Gateway](https://gateway-api.sigs.k8s.io/api-types/gateway/)
- [Kubernetes: Ingress](https://kubernetes.io/docs/concepts/services-networking/ingress/)
- [github.com/kubernetes/ingress-nginx](https://github.com/kubernetes/ingress-nginx)
