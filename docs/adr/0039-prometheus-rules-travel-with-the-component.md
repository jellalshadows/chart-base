# ADR-0039: Prometheus rules travel with the component

- **Status:** Accepted
- **Date:** 2026-09-30
- **Since:** 0.4.0
- **Related:** [ADR-0007](0007-jobs-as-helm-hooks.md), [ADR-0012](0012-no-capabilities-gating.md), [ADR-0038](0038-one-metrics-endpoint-servicemonitor-or-podmonitor.md)

## Context

Alerting and recording rules describe one component: its error rate, its latency, whether its CronJob runs
succeed. The Prometheus Operator loads them from PrometheusRule objects (`monitoring.coreos.com/v1`). What the
CRD of prometheus-operator v0.94.1 checks, and what it leaves to the operator:

- `spec.groups[]` requires `name` (at least one character) and also has `interval`, `rules`, `limit`, `labels`,
  `query_offset` and `partial_response_strategy`. The list is a map keyed by `name`
  (`x-kubernetes-list-type: map`), so two groups with the same name are rejected by the API server.
- A rule requires only `expr` (an integer or a string). `alert` and `record` are both optional: the CRD
  documents "Only one of `record` and `alert` must be set" but does not enforce it. `for` and `keep_firing_for`
  are strings with the duration pattern of the monitors, `keep_firing_for` with at least one character;
  `labels` and `annotations` are maps of strings.
- At reconcile time the operator parses every selected PrometheusRule with Prometheus' own rule parser
  (`pkg/operator/rules.go`, `ValidateRule`, which calls `rulefmt.Parse`). A PrometheusRule that does not parse
  is skipped: the operator logs "skipping prometheusrule" and records a Warning event "PrometheusRule … was
  rejected due to invalid configuration". The parser (Prometheus v3.14.0, the version the operator builds with)
  rejects, among others, a rule with both or neither of `alert` and `record`, a rule without `expr`,
  `annotations`, `for` or `keep_firing_for` on a recording rule, an invalid recording rule name, and PromQL that
  does not parse. The operator's admission webhook, when it is deployed, runs the same checks at creation time.
  A cluster with only the CRDs accepts any string as `expr`.
- The CRD pattern matches the empty string, and the operator writes to Prometheus the spec it marshalled
  before that check: `generateRulesConfiguration` calls `yaml.Marshal` first and `ValidateRule` afterwards, and
  `ValidateRule` sets an empty `for` or group `interval` to nil before it parses. So an empty `for` or group
  `interval` is accepted by the API server, passes the operator's check and is still in the rule file as an empty
  string, which Prometheus' duration parser rejects when it loads the file (`empty duration string`,
  `model.ParseDuration` in prometheus/common v0.71.0, the version the operator builds with).
- kube-prometheus-stack (chart version 91.8.2) selects PrometheusRules like monitors:
  `prometheus.prometheusSpec.ruleSelectorNilUsesHelmValues` is `true` by default, so its Prometheus only loads
  PrometheusRules labelled `release: <its Helm release name>`.
- promtool, Prometheus' own linter, checks rule files and PromQL. It ships in the Prometheus release archive:
  `prometheus-3.15.0.linux-amd64.tar.gz` is 111,651,578 bytes, for one linter step.

chart-base does not scrape CronJob and Job components ([ADR-0038](0038-one-metrics-endpoint-servicemonitor-or-podmonitor.md)),
but their outcome is in kube-state-metrics (for example `kube_job_status_failed`), which rules can use.
A `workload.type: job` component is a Helm hook, and so are its support resources, which are deleted once the
hook succeeds (`hook-delete-policy: before-hook-creation,hook-succeeded`, [ADR-0007](0007-jobs-as-helm-hooks.md)).

## Decision

- A top-level `prometheusRule` block, off by default: `enabled`, `labels` (default `{}`) and `groups`
  (default `[]`). It renders one PrometheusRule named `<fullname>` (`templates/prometheusrule.yaml`) that
  carries the chart's labels plus `prometheusRule.labels` (no default `release` label, and none of the chart's
  own label keys, as in [ADR-0038](0038-one-metrics-endpoint-servicemonitor-or-podmonitor.md)) and whose
  `spec.groups` is `groups`, verbatim.
- **Every workload type.** The rules of a CronJob or a Job live with it, in the same alias. On a `job` component
  the PrometheusRule is a regular release object, not a hook: a hook support resource is deleted once the hook
  succeeds, and the rules must stay.
- **The structure is validated by the schema**, with the CRD's field names and `additionalProperties: false` at
  every level: `enabled: true` needs at least one group; a group has a `name` (at least one character), an
  optional non-empty `interval` and at least one rule; a rule has exactly one of `alert` and `record` (a `oneOf`,
  which the CRD documents but does not enforce), a non-empty string `expr`, optional `for` and `keep_firing_for`,
  and `labels` and `annotations` (maps of strings). Every duration is non-empty and has the CRDs' pattern
  (`definitions.nonEmptyDuration`, like the CRD's own type for `keep_firing_for`): an empty one would break the
  rule file in Prometheus. The rule fields are the CRD's, so `keep_firing_for` is snake_case.
- **PromQL is not validated.** There is no promtool step in CI. The operator skips a PrometheusRule that does not
  parse, and its admission webhook, where it runs, rejects it.
- **Not validated either:** two groups with the same name (the API server rejects them), and what the parser
  checks beyond the structure (for example `annotations` or `for` on a recording rule).
- The CRD's group fields `limit`, `labels`, `query_offset` and `partial_response_strategy` are not accepted.
- **No `.Capabilities` gating** ([ADR-0012](0012-no-capabilities-gating.md)): without the CRD, a release that
  enables `prometheusRule` fails.

## Consequences

- A component ships its alerts in the same pull request and the same release as the code they watch, and they
  are removed with it.
- Mistakes in the structure (a missing `expr`, `alert` and `record` together, `keepFiringFor`, a duration such as
  `5 minutes` or an empty `for`) fail at render time, with the path of the offending rule.
- Trade-off: a PromQL error is not caught before the cluster. The objects are created, and the only signals are
  the operator's Warning event and log, or the webhook's rejection where it is deployed. Teams that want the
  check before merging can run promtool on the rendered `spec` in their own CI.
- Trade-off: the four group fields that are not accepted, and any rule field a future CRD adds, need a chart
  change; adding them is additive.
- Like monitors, a PrometheusRule without the label its Prometheus selects on is created and silently ignored.
- On the first install of a `workload.type: job` component with `job.phase: pre-deploy`, a failing hook stops the
  release before any regular object is created ([ADR-0007](0007-jobs-as-helm-hooks.md)), so its PrometheusRule
  does not exist yet: rules on the hook's outcome cover the later deploys, when the rule from the previous release
  is in place.
- The e2e installs the CRD and no operator: it proves that the API server accepts the object with its label, not
  that Prometheus evaluates the rules.

## Alternatives considered

### promtool in CI

`promtool check rules` on the rendered `spec.groups` would catch PromQL errors in the chart's own CI scenarios.
But the chart ships no rules of its own: the rules that matter are the consumers', which chart-base's CI never
sees. It would cost a download of about 112 MB (the Prometheus release archive) to lint one example rule.
To revisit if the chart ever ships default rules.

### A flat `rules` list with one implicit group

bitnami's `metrics.prometheusRule.rules`. Simpler for one group, but group names and intervals are part of how
Prometheus evaluates rules, and `groups` is the CRD's own shape.

### A free-form pass-through without a schema

stakater application passes `groups` through, and its schema only checks that it is a list. Every structural
mistake would then surface only as the operator's Warning event and log line.

### Rules only in a central monitoring repository

Keeps all alerts in one place, but separates them from the component they describe: they are not reviewed with
its changes, and they outlive it when it is removed.

## References

- prometheus-operator v0.94.1: `example/prometheus-operator-crd/monitoring.coreos.com_prometheusrules.yaml`,
  `pkg/operator/rules.go`, `pkg/admission/admission.go`, `pkg/apis/monitoring/v1/types.go` (`Duration`,
  `NonEmptyDuration`), `go.mod` (https://github.com/prometheus-operator/prometheus-operator/tree/v0.94.1)
- prometheus/common v0.71.0: `model/time.go` (`ParseDuration`, `Duration.UnmarshalYAML`)
- Prometheus v3.14.0: `model/rulefmt/rulefmt.go` (https://github.com/prometheus/prometheus/blob/v3.14.0/model/rulefmt/rulefmt.go)
- Prometheus v3.15.0 release assets (https://github.com/prometheus/prometheus/releases/tag/v3.15.0)
- kube-prometheus-stack 91.8.2: `values.yaml` (`ruleSelectorNilUsesHelmValues`)
  (https://github.com/prometheus-community/helm-charts/tree/kube-prometheus-stack-91.8.2/charts/kube-prometheus-stack)
- kube-state-metrics v2.20.0: `docs/metrics/workload/job-metrics.md`
- `values.yaml` (`prometheusRule`), `values.schema.json` (`prometheusRule`, `definitions.duration`, the `allOf`
  rule that requires a group), `templates/prometheusrule.yaml`, `.github/scripts/e2e.sh`
