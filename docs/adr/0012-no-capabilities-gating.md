# ADR-0012: No `.Capabilities` gating for CRD kinds

- **Status:** Accepted
- **Date:** 2026-09-27
- **Since:** 0.1.0
- **Related:** [ADR-0011](0011-strict-draft-07-schema.md)

## Context

Two of chart-base's templates render kinds that only exist if a CRD is installed:
`templates/httproute.yaml` renders a Gateway API `HTTPRoute` (`gateway.networking.k8s.io/v1`), and
`templates/externalsecret.yaml` renders an External Secrets Operator `ExternalSecret`
(`external-secrets.io/v1`). A chart that renders a kind the cluster does not know about can fail in one
of two ways: check first with `.Capabilities.APIVersions.Has` and skip the resource if the CRD is
missing, or render it unconditionally and let the API server reject it.

Neither template in chart-base checks `.Capabilities.APIVersions` for either kind. This is a direct
consequence of how Helm applies a release: it builds every Kubernetes object for every resource in the
rendered manifest *before* creating or updating any of them, and before it even persists the release
record. If any object cannot be resolved to a known kind — no CRD, a typo in `apiVersion`, anything —
the whole build fails and nothing in the release is touched. A gate on `.Capabilities.APIVersions`
would not make the release safer; it would make the missing CRD invisible. Instead of a release that
fails cleanly and immediately, `httpRoute.enabled: true` on a cluster without the Gateway API CRDs
would silently render every other resource in the component while skipping the route entirely — a
component with no way to reach it, deployed successfully, with no error surfaced to the operator doing
the install.

`.Capabilities.APIVersions` also cannot be exercised the same way in every context that matters for
this chart: `helm template` without `--api-versions` or a real cluster connection reports a much
smaller, static built-in set, so a gate written and tested against a real cluster's capabilities would
behave differently — and likely wrongly — the moment someone runs a plain `helm template` for a
preview, exactly the workflow the `lint`/`alias-contract` CI jobs and any consumer's local dry run rely
on.

## Decision

- `templates/httproute.yaml` and `templates/externalsecret.yaml` render their object unconditionally
  once their own feature flag is on (`httpRoute.enabled` / `externalSecret.enabled`); neither checks
  `.Capabilities.APIVersions.Has` for its kind.
- Helm builds every object in the rendered manifest before creating or updating anything (this is a
  property of `helm install`/`helm upgrade` itself, not something chart-base configures). If the
  cluster does not have the Gateway API CRDs or the External Secrets Operator CRDs installed, that
  build step fails with `unable to build kubernetes objects from release manifest`, wrapping a
  `no matches for kind "HTTPRoute" in version "gateway.networking.k8s.io/v1"` (or the equivalent for
  `ExternalSecret`) resource-mapping error — before any object in the release, including the ones that
  would have succeeded, is applied.
- This makes a missing CRD a release-blocking, immediately visible failure instead of a partially
  applied component silently missing its route or its secrets.

## Consequences

- A component that turns on `httpRoute` or `externalSecret` on a cluster missing the corresponding CRD
  fails its entire release with a clear, standard Helm error, rather than deploying successfully minus
  the one resource that needed the CRD.
- Trade-off: there is no way to install chart-base's other resources on a cluster that intentionally
  does not have the Gateway API or ESO CRDs while leaving `httpRoute`/`externalSecret` off in a values
  file meant for that cluster — but that is exactly what turning the flag `false` already does; the
  trade-off is that chart-base offers no escape hatch to render the manifest as if the CRD existed when
  it does not (e.g. for a `helm template` dry run against a cluster that will get the CRD later).
- The `e2e` CI job installs the Gateway API CRDs (`kubectl apply` of `standard-install.yaml`) and the
  External Secrets Operator (whose Helm chart carries its own CRDs) as platform prerequisites before
  installing any `ci/` scenario (`.github/scripts/e2e.sh`), so CI never actually exercises the
  missing-CRD failure path itself — it relies on Helm's own build-before-apply behavior, which is
  covered by Helm's own test suite, not this chart's.

## Alternatives considered

### A `.Capabilities.APIVersions` gate plus an escape flag for `helm template` without a cluster

Would let a component render (skipping the CRD-dependent resource) both against a real cluster missing
the CRD and against a bare `helm template`, using the flag to force the same behavior in both cases.
Rejected because the result is strictly worse for the common case: a real install where the CRD really
is missing would succeed with the resource silently absent instead of failing, and the escape flag
would need to be remembered and passed consistently by every consumer's tooling to keep local previews
and CI in sync with cluster reality — one more values-adjacent flag to get wrong, in exchange for
turning a fail-fast error into a silent gap.

## References

- `templates/httproute.yaml`
- `templates/externalsecret.yaml`
- [Helm: Charts](https://helm.sh/docs/topics/charts/)
- [Gateway API: HTTPRoute](https://gateway-api.sigs.k8s.io/reference/api-types/httproute/)
- [External Secrets Operator: ExternalSecret](https://external-secrets.io/latest/api/externalsecret/)
