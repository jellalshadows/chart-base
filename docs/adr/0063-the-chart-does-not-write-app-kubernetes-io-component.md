# ADR-0063: The chart does not write `app.kubernetes.io/component`

- **Status:** Accepted
- **Date:** 2026-11-17
- **Since:** 0.12.0
- **Related:** [ADR-0010](0010-chart-version-never-restarts-pods.md) (amended), [ADR-0028](0028-podlabels-cannot-override-selector-labels.md), [ADR-0035](0035-service-links-off-by-default.md), [ADR-0057](0057-common-labels-and-annotations-service-annotations-and-extraobjects.md), [ADR-0058](0058-the-1-0-contract-and-how-it-stays-frozen.md)

## Context

Up to 0.11.0, `chart-base.baseLabels` (`templates/_labels.tpl`) wrote `app.kubernetes.io/component: <workload.type>` on
every object and pod template, so every object said `deployment`, `cronjob` or `job`, which its `kind` already says.
Kubernetes' recommended labels define the key as "the component within the architecture", with the example `database`
([common labels](https://kubernetes.io/docs/concepts/overview/working-with-objects/common-labels/)): something only
the consumer knows (a frontend, a cache, a worker of the billing domain).

Since 0.11.0 a consumer could not set it: `commonLabels` rejects the chart's label keys (ADR-0057), and `podLabels`,
which rejects only the two selector labels (ADR-0028), rendered the key twice on the pod template, a manifest that
kubeconform `-strict` rejects (`key already set in map`). The first real umbrella (`jellalshadows/domain-boutique`,
finding G6) met it. 1.0 freezes the label keys the chart writes (ADR-0058), so this was the last release in which the
key could change without a major.

## Decision

- The chart writes no `app.kubernetes.io/component`, on any object, pod template, job template, claim template or
  ExternalSecret template. The key is the consumer's: `commonLabels` sets it on every labels map the chart writes,
  `podLabels` on the pod templates.
- `definitions.extraLabels` drops the key: the maps that reject the chart's label keys (`commonLabels`,
  `metrics.labels`, `prometheusRule.labels`, an extra object's labels) reject six keys, `app.kubernetes.io/name`,
  `instance`, `part-of`, `version`, `managed-by` and `helm.sh/chart`.
- It is not a selector label (ADR-0010), so no object is recreated. The pod template changes once: every Deployment
  rolls once at the upgrade to 0.12.0, and the next CronJob run and the next Job hook carry the new label set. This is
  an exception to ADR-0010 ("bumping chart-base never restarts pods by itself"), made in a breaking release, as
  ADR-0035 was for `enableServiceLinks`.

Measured: the snapshots of the seven `ci/` scenarios lose 56 lines with this change, all of them this label, and change
nothing else; on the 0.12.0 design's prototype, the Online Boutique umbrella (76 objects) differed in 90 lines, all of
them this label, on Helm 4.3 and 3.22.

## Consequences

- The label carries the meaning Kubernetes gives it, when the consumer sets it; tools that group by it (dashboards that
  follow the recommended labels) see the architecture instead of the kind.
- Every Deployment rolls once at the upgrade, with no change of its own.
- Anything that selects on `app.kubernetes.io/component=deployment` (a dashboard, an alert, a policy of the consumer's)
  stops matching. The upgrade guide says so; the consumer sets the key with `commonLabels` to keep such a selector.
- After 1.0, writing the key again is a major (ADR-0058).

## Alternatives considered

### Keep writing the workload type, frozen

A label with the wrong meaning, owned by the chart forever: the consumer could never use the key for what Kubernetes
defines it for, and it repeats the `kind`.

### Write the alias (a copy of `app.kubernetes.io/name`)

The alias names the chart's dependency, which is often, not always, the architectural component. It would still be the
chart's choice in the consumer's key, and it duplicates a label every object already has.

### Let a consumer's value win over the chart's

The chart's value would stay on every object where the consumer sets nothing, with the wrong meaning, and a per-key
precedence between the chart and the consumer is a rule the other chart keys do not have.

## References

- [Kubernetes recommended labels](https://kubernetes.io/docs/concepts/overview/working-with-objects/common-labels/).
- `templates/_labels.tpl` (`chart-base.baseLabels`), `values.schema.json` (`definitions.extraLabels`).
- `tests/contract_test.yaml` (the label is absent from every object and template), `tests/common_labels_test.yaml`
  (`commonLabels` and `podLabels` set it).
