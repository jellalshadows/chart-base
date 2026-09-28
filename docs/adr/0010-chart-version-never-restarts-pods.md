# ADR-0010: Bumping chart-base never restarts pods by itself

- **Status:** Accepted
- **Date:** 2026-09-27
- **Since:** 0.1.0

## Context

chart-base's own version has nothing to do with whether a workload's actual configuration changed:
a chart release can fix a typo in a comment, add a new optional value, or patch a template with no
observable effect on any already-running component. If bumping the chart version rolled every pod of
every umbrella that depends on it, upgrading chart-base would restart an entire domain's workloads on
every patch release, with no real change behind any of those restarts — a maintenance cost with no
corresponding benefit, and a blast radius entirely disproportionate to, say, a one-line documentation
fix.

Two places in the templates could leak the chart version into a pod restart if left unguarded.
First, object labels: `chart-base.labels` (`templates/_labels.tpl`) includes
`helm.sh/chart: chart-base-<.Chart.Version>` (with `+` replaced by `_` for label-value validity, a
metadata-only label hardcoding the real chart name so it is not lost under an alias). If that label
were also applied to the pod template, any pod template label diff would trigger a rolling update —
which is exactly what happens with `helm create`'s scaffolded labels, where the same label set is
used for both object metadata and the pod template. chart-base avoids this by having a **separate**
helper, `chart-base.podLabels`, that composes only `chart-base.baseLabels` (selector labels plus
`part-of`, `component`, `version`) and `.Values.podLabels` — `helm.sh/chart` is deliberately absent
from it.

Second, the config-change checksum annotations (ADR-0006) could leak it a different way: an earlier
version of the checksum expression hashed the *entire* rendered ConfigMap object, not just its
`data`. But the ConfigMap's own object metadata also carries `helm.sh/chart` (`chart-base.labels` is
applied to every object, ConfigMaps included, in `templates/configmap-env.yaml` and
`templates/configmap-files.yaml`) — so hashing the whole object meant that bumping the chart version
changed the ConfigMap's `helm.sh/chart` label, which changed the checksum, which changed the pod
template, which rolled every pod with a `config` or `configFiles` entry across the whole domain, with
no real configuration change behind it. This was found during the final review of the first release
and fixed by narrowing the hash to only the ConfigMap's `data` field.

## Decision

- `helm.sh/chart` is rendered only by `chart-base.labels` (object metadata:
  `templates/_labels.tpl`), never by `chart-base.podLabels` (pod template labels, same file). The
  pod template's label set is `chart-base.baseLabels` (selector labels + `part-of` + `component` +
  `version`) plus `.Values.podLabels`, nothing else.
- `checksum/config-env` and `checksum/config-files` (`templates/deployment.yaml`) hash only the
  rendered ConfigMap's `.data` field, extracted with
  `(include (print $.Template.BasePath "/configmap-env.yaml") . | fromYaml).data | toJson | sha256sum`
  (respectively `configmap-files.yaml`) — never the whole rendered object, whose metadata carries
  `helm.sh/chart`.
- The selector labels (`app.kubernetes.io/name`, `app.kubernetes.io/instance`,
  `chart-base.selectorLabels`) are immutable once a Deployment exists (Kubernetes rejects a change to
  `spec.selector`) and are frozen for good from chart-base `1.0.0` on (README "Versioning and
  releases").

## Consequences

- Publishing a new `chart-base` patch or minor version never, by itself, restarts a single pod
  anywhere it is already deployed; only an actual change to a component's own values (image, config,
  resources, and so on) does.
- Trade-off: because `helm.sh/chart` is absent from the pod template, nothing in the running pod's
  own metadata records which chart version rendered it — that information only lives on the
  Deployment/ConfigMap/Secret objects' metadata, one level up, and must be read from there instead.
- The checksum's narrower scope means it only reacts to changes in the ConfigMap's `data`; a future
  template change that adds meaningful pod-affecting metadata to the ConfigMap without touching
  `data` would not roll the pods, and would need its own checksum coverage if that ever happens.

## Alternatives considered

### The labels `helm create` puts on the pod template

Copies every object label (including `helm.sh/chart`) onto the pod template too, which is exactly
the leak this decision avoids: any chart version bump becomes a pod template diff and rolls every
pod, everywhere, for no functional reason.

### Hashing the whole rendered ConfigMap object

What this repository's first release actually shipped and then fixed: hashing the entire object
(including its `helm.sh/chart`-bearing metadata) meant a chart-base version bump changed the
checksum on every component with `config` or `configFiles` set, rolling their pods with no real
configuration change.

## References

- `templates/_labels.tpl`
- `templates/deployment.yaml`
- `templates/configmap-env.yaml`, `templates/configmap-files.yaml`
- [README: Versioning and releases](https://github.com/jellalshadows/chart-base/blob/main/README.md.gotmpl)
- [ADR-0006](0006-checksum-for-config-reloader-for-secrets.md)
