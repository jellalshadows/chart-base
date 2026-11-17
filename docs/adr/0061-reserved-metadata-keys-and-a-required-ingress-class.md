# ADR-0061: Reserved metadata keys in every map, and a required Ingress class

- **Status:** Accepted
- **Date:** 2026-11-17
- **Since:** 0.12.0
- **Related:** [ADR-0016](0016-httproute-first-ingress-optional.md) (amended), [ADR-0028](0028-podlabels-cannot-override-selector-labels.md) (amended), [ADR-0044](0044-guards-fail-the-render-helm-lint-reports-them.md), [ADR-0047](0047-when-enabled-keys-required-externalsecret-source-probe-port-names.md) (amended), [ADR-0057](0057-common-labels-and-annotations-service-annotations-and-extraobjects.md) (amended), [ADR-0058](0058-the-1-0-contract-and-how-it-stays-frozen.md), [ADR-0063](0063-the-chart-does-not-write-app-kubernetes-io-component.md)

## Context

After 1.0 a check that rejects values that render is a major (ADR-0058), so two open shapes are closed now or frozen.

**Reserved keys.** 0.11.0 gave its new maps (`commonLabels`, `commonAnnotations`, `service.annotations`,
`metrics.labels`, `prometheusRule.labels`, an extra object's metadata) the keys the chart and Helm write as schema
rules, `definitions.extraLabels` and `definitions.extraAnnotations` (ADR-0057). The four older maps did not get them:
`podLabels` rejected only the two selector labels (ADR-0028), and `podAnnotations`, `ingress.annotations` and
`serviceAccount.annotations` were open string maps. Measured with the 0.11.0 chart on Helm 4.3.0 and 3.22.0 (`helm
template`, exit 0 each): `podLabels: {app.kubernetes.io/part-of: other}` renders a pod template with the key twice,
which kubeconform `-strict` rejects (`key already set in map`); `podAnnotations: {checksum/config-env: pinned}` the
same; an Ingress annotation `helm.sh/hook` renders, and a hook key turns the Ingress into a Helm hook, which Helm
manages as a hook, not as one of the release's objects; `meta.helm.sh/release-name` on the ServiceAccount renders,
although Helm writes the `meta.helm.sh/*` keys itself to record which release owns an object.

**The Ingress class.** The ingress when-enabled branch set `minLength: 1` on `className` but did not require it, so
`ingress.className: null` from an override file, `--set`, or the umbrella's own values on Helm 3.22 deleted the chart's
default `""` before the schema ran, and the Ingress rendered with no `ingressClassName`: the cluster's default
IngressClass, if one exists, then serves it. ADR-0016 says a class is required with no default; ADR-0047 left the
`null` an open decision, pinned by a test that was to flip when it was taken.

## Decision

1. **`podLabels` is `definitions.extraLabels`**: the six label keys the chart writes (`app.kubernetes.io/name`,
   `instance`, `part-of`, `version`, `managed-by`, `helm.sh/chart`) fail the schema, as in `commonLabels`.
   `app.kubernetes.io/component` is the consumer's (ADR-0063).
2. **`podAnnotations`, `ingress.annotations` and `serviceAccount.annotations` are `definitions.extraAnnotations`**:
   `helm.sh/hook*`, `meta.helm.sh/*`, `checksum/config-env` and `checksum/config-files` fail the schema. The checksum
   keys collide with nothing on an Ingress or a ServiceAccount; one definition is kept anyway, as `service.annotations`
   already does, so every annotations map of an object's or a pod template's metadata rejects the same set (and
   `commonAnnotations` the two Reloader keys besides). `helm.sh/resource-policy` stays allowed: the hand-over of the
   chart's ServiceAccount uses it. The rule `labels` and `annotations` of a PrometheusRule are alert fields, not
   metadata, and stay open.
3. **Schema rules, not guards**, as ADR-0057 decided for 0.11.0: a guard only prints an INFO line under `helm lint`
   (ADR-0044), the schema fails `helm lint` directly and through an umbrella. The message names the key at an
   unrelated path, measured on Helm 4.3.0 and 3.22.0 alike: `at '/prometheusRule': invalid propertyName
   'app.kubernetes.io/part-of'`, `at '/prometheusRule/enabled': invalid propertyName 'helm.sh/hook'` (Helm's schema
   library; the consuming guide lists which maps reject which keys).
4. **`ingress.className` joins `required` in the when-enabled branch.** A `null` fails in every values layer: `at
   '/ingress': missing property 'className'` from `-f`, `--set`, and the umbrella's own values (Helm 3.22, or Helm 4.3
   when a `-f` or `--set` value names the component); on Helm 4.3 a `null` in the umbrella's own values is ignored
   while nothing is passed for the component, so the default `""` stays and `minLength` fails (measured with a
   throwaway umbrella on both versions). With the Ingress off a `null` class still renders nothing and fails nothing.
   `className` is in the defaults of every published release with an Ingress, so the `--reuse-values` lesson of a new
   root `required` does not apply.

This amends ADR-0016 (the class is required, `null` included), ADR-0028 (six keys, not two), ADR-0047 (its
`ingress.className` exception is gone) and ADR-0057 (point 4: on a `job`'s ServiceAccount the hook annotations can no
longer meet a `serviceAccount.annotations` key, which rejects them; point 6: the reserved keys cover the four maps).

## Consequences

- Values that render a key twice, a hook out of an Ingress or a ServiceAccount, or an Ingress the cluster's default
  class picks fail at render, before the API server sees them.
- The upgrade from 0.11.0 can fail for values that rendered: one of the reserved keys in the four maps, or
  `ingress.className: null` with the Ingress on. The upgrade guide lists the shapes and their fix.
- A key a consumer legitimately sets is rejected if it is one of the reserved keys; each is a key the chart writes or
  Helm owns. Relaxing a key later is additive; accepting `""` as "no class" later is additive too.

## Alternatives considered

### The reserved keys as guards

A guard names the map in its message, but only prints an INFO line under `helm lint` (ADR-0044), and the 0.11.0 maps
already use the schema rule: two mechanisms for one rule.

### An Ingress without a class on purpose

It hands the choice to a cluster fact the values do not show (whether a default IngressClass exists, and which), and
ADR-0016 already rejects a default class.

### A reserved set per map (no checksum keys on an Ingress or a ServiceAccount)

One definition is one rule to state and test; nobody needs a `checksum/config-*` annotation there.

## References

- `values.schema.json` (`definitions.extraLabels`, `definitions.extraAnnotations`, `podLabels`, `podAnnotations`,
  `ingress.annotations`, `serviceAccount.annotations`, the ingress when-enabled branch).
- `tests/schema_test.yaml`, `tests/exposure_test.yaml`, `tests/common_annotations_test.yaml`.
- [Consuming guide, item 8 of "Common labels and annotations, and extra objects"](../guides/consuming.md#common-labels-and-annotations-and-extra-objects).
