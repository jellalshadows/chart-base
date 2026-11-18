# ADR-0065: An opt-in handover from the chart's HPA to KEDA

- **Status:** Accepted
- **Date:** 2026-11-18
- **Since:** 1.1.0
- **Related:** [ADR-0056](0056-keda-scaledobject-a-curated-block-with-a-triggers-map.md) (amended), [ADR-0057](0057-common-labels-and-annotations-service-annotations-and-extraobjects.md), [ADR-0064](0064-from-1-0-0-a-new-key-is-optional.md)

## Context

A Deployment has one autoscaler: the chart's HPA (`autoscaling`) or a KEDA ScaledObject (`keda`). Where KEDA's
admission webhook runs, the switch from the HPA to KEDA cannot be one upgrade. Helm creates the ScaledObject before it
deletes the HPA, and the webhook denies a ScaledObject whose workload an HPA already scales (measured with KEDA
2.21.0, [upgrade guide](../upgrading.md#switching-to-keda)). 0.10.0 left two paths: `kubectl delete hpa` before the
upgrade, or two upgrades that render `replicas` in between, which on the second one sets the count to 1.

KEDA's webhook skips an HPA annotated `validations.keda.sh/hpa-ownership: "false"` (KEDA v2.21.0,
`apis/keda/v1alpha1/scaledobject_webhook.go`, `verifyHpas`). [ADR-0056](0056-keda-scaledobject-a-curated-block-with-a-triggers-map.md)
rejected that annotation on every chart HPA, because it puts a KEDA setting on the HPA of consumers who never use KEDA
and turns KEDA's check off for it, and it left an opt-in key as additive later (O1 of the 0.10.0 design).

## Decision

- **`autoscaling.kedaHandover`**, a boolean, `false` by default and optional ([ADR-0064](0064-from-1-0-0-a-new-key-is-optional.md)).
  `true` puts `validations.keda.sh/hpa-ownership: "false"` on the chart's HPA, and nothing else changes.
- **The annotation is the HPA's per-object map** (`chart-base.annotations`' `object`), so it wins over the same key in
  `commonAnnotations` and renders once ([ADR-0057](0057-common-labels-and-annotations-service-annotations-and-extraobjects.md)).
  `commonAnnotations` keeps accepting the key, as in 1.0.0.
- **No guard.** The key is read only while `autoscaling.enabled` is `true`. After the switch, the values that turn KEDA
  on may keep it, so the switch is one change of `enabled` and `keda.enabled`.
- **The switch** is two upgrades: the first sets the key, and the second turns the HPA off and KEDA on. Neither renders
  `replicas`, so the count stays with the autoscalers, and an HPA scales the workload throughout.

## Consequences

- It amends ADR-0056: HPA to KEDA takes one upgrade once the HPA carries the mark. `kubectl delete hpa` and the two
  upgrades through `replicas` remain for a chart before 1.1.0.
- The kind e2e asserts it in the keda scenario: after the switch back to the chart's HPA, an upgrade sets the key and the
  live HPA carries the annotation. The next upgrade switches to KEDA, the ScaledObject becomes Ready, KEDA's HPA
  targets the Deployment, and the chart's HPA is gone.
- While the key is `true`, KEDA's webhook does not protect that Deployment from a second autoscaler: a ScaledObject
  created by hand next to the chart's HPA is admitted (source reading). The key is for the switch, and the values
  comment says so.

## Alternatives considered

### The annotation on every chart HPA

Rejected by ADR-0056 for the reasons above. It is still rejected.

### `transfer-hpa-ownership` on the ScaledObject

KEDA's `scaledobject.keda.sh/transfer-hpa-ownership` makes KEDA adopt an existing HPA under its own name. Helm would
then delete the HPA KEDA adopted, because the chart's HPA leaves the manifest in the same upgrade (a reading of
Helm's upgrade, not measured). ADR-0056 says never.

### A guard that fails the key without the HPA

It would make the consumer remove the key in the same upgrade that switches, and a forgotten key does nothing.

## References

- `templates/hpa.yaml`, `values.yaml` and `values.schema.json` (`autoscaling.kedaHandover`), `tests/scaling_test.yaml`,
  `tests/autoscaling_guards_test.yaml`, `.github/scripts/e2e.sh` (the keda scenario).
- KEDA v2.21.0: `apis/keda/v1alpha1/scaledobject_webhook.go`.
