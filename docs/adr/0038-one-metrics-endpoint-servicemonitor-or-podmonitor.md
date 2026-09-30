# ADR-0038: One metrics endpoint, scraped through a ServiceMonitor or a PodMonitor

- **Status:** Accepted
- **Date:** 2026-09-30
- **Since:** 0.4.0
- **Related:** [ADR-0012](0012-no-capabilities-gating.md), [ADR-0027](0027-required-keys-in-the-schema.md), [ADR-0039](0039-prometheus-rules-travel-with-the-component.md)

## Context

Components expose Prometheus metrics, and the clusters chart-base targets discover scrape targets through
the Prometheus Operator, often installed by kube-prometheus-stack. The operator reads two custom resources
of `monitoring.coreos.com/v1` (facts from the CRDs of prometheus-operator v0.94.1):

- A **ServiceMonitor** selects Services by label. The `port` of each of its `endpoints` is "the name of the
  Service port which this endpoint refers to (e.g. `.spec.ports[].name`)".
- A **PodMonitor** selects Pods by label. The `port` of each of its `podMetricsEndpoints` is "the `Pod` port
  name which exposes the endpoint. If the pod doesn't expose a port with the same name, it will result in no
  targets being discovered."
- Without a `namespaceSelector`, both discover their targets "in the same namespace as" the monitor.
- Both endpoint types have `interval` and `scrapeTimeout`, strings with the same duration pattern. For
  `scrapeTimeout` the CRD says: "The value cannot be greater than the scrape interval otherwise the operator
  will reject the resource." The CRD schema itself does not check it, so the API server accepts such a
  monitor.
- The `job` label of the scraped series defaults to the name of the Service for a ServiceMonitor, and to
  `<namespace>/<name>` of the PodMonitor for a PodMonitor.

Prometheus selects monitors with label selectors: "An empty label selector matches all objects. A null label
selector matches no objects." kube-prometheus-stack (checked on chart version 91.8.2) sets
`prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues` and `podMonitorSelectorNilUsesHelmValues`
to `true` by default; with the default empty selectors, its Prometheus is then created with
`matchLabels: {release: <its Helm release name>}`. A monitor without that label is created and silently
ignored. Its namespace selectors default to `{}`, every namespace.

A chart-base component is one workload ([ADR-0001](0001-application-chart-consumed-through-aliases.md)): an
API Deployment with a Service, a worker Deployment without one, a CronJob or a Job. Every entry of `ports` is a
named container port and, when there is a Service, a Service port of the same name. CronJob and Job pods run
for seconds or minutes and every run is a new pod, so a scrape every interval may never catch one. The
Prometheus documentation recommends the Pushgateway only "in certain limited cases" and adds: "Usually, the
only valid use case for the Pushgateway is for capturing the outcome of a service-level batch job."

## Decision

- A top-level `metrics` block, off by default: `enabled`, `port` (default `http`), `path` (default
  `/metrics`), `interval` and `scrapeTimeout` (default `null`: Prometheus' own defaults) and `labels`
  (default `{}`).
- **One endpoint.** The monitor has exactly one endpoint, built from these keys (`templates/_metrics.tpl`).
  Nothing else of the CRDs' endpoint fields is exposed.
- **The Service decides the kind.** With a Service (`service.enabled: true`) the chart renders a
  ServiceMonitor named `<fullname>` (`templates/servicemonitor.yaml`) whose `endpoints[0].port` is
  `metrics.port`, the name of the Service port rendered from the `ports` entry of that name. Without a Service
  (a worker) it renders a PodMonitor (`templates/podmonitor.yaml`) whose `podMetricsEndpoints[0].port` is the
  container port of that name. Never both.
- **The port name is checked.** A guard in `templates/validate.yaml` fails when `metrics.enabled` is `true`
  and `metrics.port` is not the name of an entry in `ports`; the message says to declare it, for a worker too.
- `spec.selector.matchLabels` is the chart's selector labels. There is no `namespaceSelector`: each monitor
  only looks in its own namespace, where its component runs.
- **Labels pass through, with no default `release`, and never over the chart's own.** The monitor carries the
  chart's labels plus `metrics.labels`. The value that kube-prometheus-stack selects on is the release name of
  the user's kube-prometheus-stack, which the chart cannot know. The keys the chart sets itself
  (`app.kubernetes.io/name`, `instance`, `part-of`, `component`, `version`, `managed-by` and `helm.sh/chart`)
  are rejected by the schema (`definitions.extraLabels`, an error that contains `invalid propertyName '<key>'`):
  the template would render them twice, a duplicate key that `helm template` does not report. `podLabels` keeps
  its narrower rule, the two selector labels only ([ADR-0028](0028-podlabels-cannot-override-selector-labels.md)).
- **Deployments only.** The schema rejects `metrics.enabled: true` on `cronjob` and `job`, with the same
  `allOf` rule as `httpRoute`, `ingress` and `autoscaling`.
- **No `.Capabilities` gating** ([ADR-0012](0012-no-capabilities-gating.md)): without the CRDs, a release that
  enables `metrics` fails.
- **Schema.** `interval` and `scrapeTimeout` are `null` or a string with the CRDs' duration pattern
  (`definitions.duration`); `path` starts with `/`; `labels` is a map of strings without the chart's own keys;
  `enabled`, `port` and `path`
  are `required` ([ADR-0027](0027-required-keys-in-the-schema.md)), and so is `metrics` itself.
- **Not validated:** a `scrapeTimeout` greater than `interval` (templates cannot compare durations; the
  operator rejects the monitor), and whether the port really serves metrics at `path`.

## Consequences

- An API turns on scraping with `metrics.enabled` (plus `metrics.port` when its metrics are not on `http`), and a
  worker with the same keys plus a named entry in `ports`: the kind is always the right one.
- A port name that matches nothing fails at render time instead of producing a monitor with no targets.
- kube-prometheus-stack users must set `metrics.labels.release`; without it nothing fails, the monitor is simply
  never selected. The README recipe and the consuming guide say so.
- Trade-off: several endpoints, TLS, authentication, relabelings, `honorLabels` or a `jobLabel` cannot be
  expressed. Adding them later (for example a list of extra endpoints next to `metrics.port`) is additive.
- Trade-off: the chart does not scrape CronJobs and Jobs. Their outcome is visible through kube-state-metrics
  (for example `kube_job_status_failed`), which a `prometheusRule` can alert on
  ([ADR-0039](0039-prometheus-rules-travel-with-the-component.md)), or through a Pushgateway push from the
  application.
- The e2e installs the three CRDs and no operator: it proves that the API server accepts the objects with their
  labels and endpoint port, not that Prometheus scrapes anything.

## Alternatives considered

### A list of endpoints passed through verbatim

What bjw-s app-template and stakater application do. Every CRD field becomes available, but the schema can no
longer check the port name, the durations or the path, and the common case needs a list for one endpoint.

### Separate `serviceMonitor` and `podMonitor` switches

bitnami gates its ServiceMonitor behind `metrics.serviceMonitor.enabled`. A switch per kind lets a user pick the
wrong one (a ServiceMonitor for a worker selects no Service) or both. The component's Service already says which
kind works.

### A PodMonitor for every component

It would also work for an API, whose pods have the named container port. But a component with a Service is
normally scraped through it, and a ServiceMonitor gives the series the Service name as their `job` label, where a
PodMonitor gives `<namespace>/<podmonitor name>`.

### Letting `metrics.labels` override the chart's labels

A merge would let a user overwrite the labels that describe the component (`app.kubernetes.io/name`, `instance`,
...), and appending the map as it is renders a duplicate key. Rejecting those keys fails loudly and leaves every
label a Prometheus selects on (`release`, `team`, ...) available.

### A default `release` label

Its value is the release name of kube-prometheus-stack in each cluster. A wrong default is silently ignored just
like a missing label, and it would suggest that nothing needs to be set.

### Scraping CronJobs and Jobs with a PodMonitor

A pod that lives shorter than the scrape interval may never be scraped, and every run creates new series. The
outcome of a run is better observed through kube-state-metrics or a push.

### `.Capabilities` gating

stakater application renders its ServiceMonitor only when `monitoring.coreos.com/v1` is available, so a cluster
without the CRDs silently gets no monitor. Rejected for every CRD kind by
[ADR-0012](0012-no-capabilities-gating.md).

## References

- prometheus-operator v0.94.1 CRDs: `example/prometheus-operator-crd/monitoring.coreos.com_servicemonitors.yaml`,
  `monitoring.coreos.com_podmonitors.yaml` and `monitoring.coreos.com_prometheuses.yaml`
  (https://github.com/prometheus-operator/prometheus-operator/tree/v0.94.1/example/prometheus-operator-crd)
- kube-prometheus-stack 91.8.2: `charts/kube-prometheus-stack/values.yaml` (`*SelectorNilUsesHelmValues`) and
  `templates/prometheus/prometheus.yaml` (the `release` selectors)
  (https://github.com/prometheus-community/helm-charts/tree/kube-prometheus-stack-91.8.2/charts/kube-prometheus-stack)
- Prometheus: [When to use the Pushgateway](https://prometheus.io/docs/practices/pushing/)
- kube-state-metrics v2.20.0: `docs/metrics/workload/job-metrics.md`
- `values.yaml` (`metrics`), `values.schema.json` (`metrics`, `definitions.duration`, the `allOf` rule for
  `cronjob` and `job`), `templates/servicemonitor.yaml`, `templates/podmonitor.yaml`, `templates/_metrics.tpl`,
  `templates/validate.yaml`, `.github/scripts/e2e.sh`
