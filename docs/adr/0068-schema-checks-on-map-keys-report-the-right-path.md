# ADR-0068: Schema checks on map keys report the right path

- **Status:** Accepted
- **Date:** 2026-11-18
- **Since:** 1.3.1
- **Related:** [ADR-0011](0011-strict-draft-07-schema.md) (amended), [ADR-0028](0028-podlabels-cannot-override-selector-labels.md) (amended), [ADR-0038](0038-one-metrics-endpoint-servicemonitor-or-podmonitor.md) (amended), [ADR-0057](0057-common-labels-and-annotations-service-annotations-and-extraobjects.md) (amended), [ADR-0058](0058-the-1-0-contract-and-how-it-stays-frozen.md), [ADR-0061](0061-reserved-metadata-keys-and-a-required-ingress-class.md) (amended)

## Context

Up to 1.3.0 the schema checked the keys of a map with `propertyNames`:

- the reserved keys, through `definitions.extraLabels` and `definitions.extraAnnotations`;
- an environment variable name, through `definitions.envName`, in `env`, `config` and an entry's `env` and `config`;
- a ConfigMap key in `configFiles.files`;
- a Secret key, through `definitions.secretKey`, in `externalSecret.data` and `externalSecret.template.data`.

The schema library that Helm 4.3.0 and 3.22.0 use (`santhosh-tekuri/jsonschema` v6) reports a `propertyNames` failure
at another key's path. In v6.0.3 `validator.go` stores the failure with the validator's live location slice
(`verr.InstanceLocation = vd.vloc`) instead of a copy. A sibling validated later writes its own key into the same
array. So a reserved `podLabels` key failed with `at '/prometheusRule': invalid propertyName 'app.kubernetes.io/name'`,
and so did a `config` name. Every other kind of failure takes a copy (`vd.instanceLocation()`) and is reported at the
right path. 0.6.0 recorded this, 0.12.0 documented it in the upgrade guide, and ADR-0049 and ADR-0051 chose guards
over `propertyNames` because of it.

## Decision

- **No `propertyNames` in `values.schema.json`.** The accepted set of every map stays the same. Only the messages
  change.
- **A reserved key is a false schema:**
  - under `properties` for an exact key, under `patternProperties` for a prefix (`^helm\.sh/hook`, `^meta\.helm\.sh/`);
  - the error is at the key's own path: `at '/podLabels/app.kubernetes.io~1name': false schema`, where JSON Pointer
    writes a `/` in a key as `~1`.
- **A name with a pattern is a `patternProperties` entry next to `additionalProperties: false`:**
  - the error is at the map's path and names the key: `at '/config': additional properties '1BAD' not allowed`;
  - a Secret key's 253-character limit joins its pattern (`^[-._a-zA-Z0-9]{1,253}$`);
  - `definitions.envName` and `definitions.secretKey` are removed, because only `propertyNames` referenced them.
- **The reserved keys repeat where they are needed,** in `extraObjects.<key>.metadata` and `commonAnnotations`. An
  `allOf` over one shared definition would add an `'allOf' failed` line to each of their errors. A unit test pins
  every key in each copy.

## Consequences

- A reserved key or a bad name is found where the error says. The 0.12.0 note in the upgrade guide, "nothing is wrong
  with your `prometheusRule`", no longer applies.
- The name messages no longer quote the pattern, nor a Secret key's 253-character limit. The descriptions in the
  schema state them.
- A pattern is written once per map, because a `patternProperties` key cannot be a reference. The unit tests reject a
  bad name in each map.
- Error messages are not frozen ([ADR-0058](0058-the-1-0-contract-and-how-it-stays-frozen.md)), so the change is a
  patch.
- `.github/scripts/contract-keys.sh` reads a `patternProperties` entry as a map entry (`<name>`), as it reads
  `additionalProperties`, and skips a false schema under `properties` (a rejected key, not a key of the contract). It
  lists the same 653 keys from the schemas before and after this change.

## Alternatives considered

### Template guards in place of the schema checks

0.6.0 proposed this for `podLabels`. A guard writes any message. But the schema would accept the keys, so an editor
that validates values against it would stop flagging them, and a guard runs only after the schema has passed.

### Keep `propertyNames` and wait for a fixed library

The wrong path is reported today on both supported Helm versions, and a fix reaches consumers only when they upgrade
Helm.

### One shared definition, referenced through `allOf`

It avoids the repeated lists but adds an `'allOf' failed` line to every error, which `definitions.secretKey` already
avoided for the same reason.

## References

- `santhosh-tekuri/jsonschema` v6.0.3, `validator.go`: the `propertyNames` block and `func (vd *validator) error`.
- `values.schema.json`, `tests/schema_test.yaml`, `tests/common_labels_test.yaml`,
  `tests/common_annotations_test.yaml`, `tests/extraobjects_test.yaml`, `tests/externalsecret_guards_test.yaml`.
