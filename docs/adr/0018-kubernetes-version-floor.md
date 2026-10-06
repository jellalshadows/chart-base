# ADR-0018: Kubernetes version floor `>=1.33.0-0`

- **Status:** Accepted — amended by [ADR-0044](0044-guards-fail-the-render-helm-lint-reports-them.md) (0.6.0)
- **Date:** 2026-09-27
- **Since:** 0.1.0
- **Related:** [ADR-0011](0011-strict-draft-07-schema.md)

## Context

chart-base's schema validation relies on `if`/`then` conditionals (ADR-0011), and its guard for a
missing CRD relies on Helm's own build-before-apply behavior (ADR-0012); neither of those is a
Kubernetes API-server feature, but the chart still needs a floor for the Kubernetes version it targets,
because `values.schema.json` and the templates assume API shapes (e.g. `autoscaling/v2`'s stable field
set, `policy/v1`'s `unhealthyPodEvictionPolicy`) that only exist from a given Kubernetes release
onward. 1.33 is the floor chart-base declares, and it is a version still supported by every major
managed Kubernetes offering (EKS, GKE, AKS) into 2027 — not a version about to fall out of support the
moment a consumer adopts the chart.

A version floor in `Chart.yaml`'s `kubeVersion` needs the `-0` pre-release suffix to actually work
against real clusters: managed Kubernetes offerings report a version string with a provider suffix,
e.g. `v1.33.5-eks-x`, and in semantic versioning a pre-release suffix (anything after a `-`) sorts
*before* the release it qualifies — so `v1.33.5-eks-x` does not, by plain semver rules, satisfy
`>=1.33.0` (a range with no pre-release component only matches other versions with no pre-release
component). Appending `-0` to the floor (`>=1.33.0-0`) fixes this: `-0` is the lowest possible
pre-release identifier, so the range now matches any pre-release of `1.33.0` and everything above it,
including provider suffixes like `-eks-x`. This is not a hypothetical edge case CI would catch either
way: `helm template --kube-version` strips the provider suffix before comparing, so a `kubeVersion`
floor missing `-0` looks correct in CI and only breaks on the real cluster whose version string carries
the suffix.

Helm does not enforce a subchart's own `kubeVersion` constraint when that subchart is installed as a
dependency of an umbrella — only the top-level chart's `kubeVersion` is checked against the cluster.
Since chart-base is always consumed as a dependency (ADR-0001), never installed directly, its own
`kubeVersion` floor in `Chart.yaml` is never actually enforced by Helm for a real consumer; it is
documentation and a CI-time hint at best. `templates/validate.yaml` is the guard that actually runs,
because a `fail` template guard executes for every alias of every umbrella release regardless of
whether Helm itself checked the dependency's `kubeVersion`.

## Decision

- `Chart.yaml` declares `kubeVersion: ">=1.33.0-0"`.
- `templates/validate.yaml` additionally guards the floor directly against the render-time capability
  Helm does check regardless of dependency status:
  `{{- if not (semverCompare ">=1.33.0-0" .Capabilities.KubeVersion.Version) -}}`, failing with
  `chart-base[<component>]: Kubernetes >= 1.33 is required, got <version>` when it does not hold. This
  guard runs on every `helm template`/`helm lint`/`helm install`/`helm upgrade`, whether or not Helm
  itself enforced the `Chart.yaml` constraint for this particular install.
- 1.33 is supported (receives patches) by EKS, GKE and AKS into 2027, so the floor does not force
  consumers off a version their managed control plane is about to drop support for.
- The e2e suite runs on Kubernetes 1.33 and 1.37 (`.github/workflows/ci.yaml` matrix, kind node images
  `v1.33.12` and `v1.37.0`); the `lint` job's kubeconform step validates every `ci/` scenario's rendered
  manifests against both the 1.33 and the 1.37 Kubernetes schemas.

## Consequences

- A consumer on a real managed-Kubernetes cluster whose version string carries a provider suffix is
  correctly accepted by the floor, on both the `Chart.yaml` declaration (when Helm does check it) and
  the template guard (which always runs).
- Trade-off: because Helm does not check a subchart's own `kubeVersion`, the `Chart.yaml` declaration by
  itself gives a consumer of the umbrella no protection at all — the template guard is doing the actual
  work, and a maintainer who edits one without the other (e.g. bumping the floor in `Chart.yaml` but
  forgetting `templates/validate.yaml`, or vice versa) leaves the two out of sync with no automated
  check tying them together.
- A cluster on a Kubernetes version below 1.33 fails every render with the same guard error regardless
  of which feature in a given component actually needs 1.33 — the message names the required floor, not
  the specific field or resource that would have broken.

## Alternatives considered

### No floor

Would let the chart render successfully against a Kubernetes version whose API shapes it was never
tested against, with the actual failure surfacing later and less clearly — as an API-server rejection
of a field the chart assumed exists, rather than a chart-base error naming the real requirement.

### A floor without `-0` (`>=1.33.0`)

Passes on `helm template --kube-version`, which strips provider suffixes before comparing, so CI would
never catch the mistake — but fails on real managed-Kubernetes clusters whose reported version carries
a provider suffix, since a pre-release suffix does not satisfy a semver range with no pre-release
component of its own.

## References

- `Chart.yaml` (`kubeVersion`)
- `templates/validate.yaml`
- `.github/workflows/ci.yaml` (`lint`, `e2e` matrices)
- [Helm: Chart.yaml Files](https://helm.sh/docs/topics/charts/#the-chartyaml-file)
