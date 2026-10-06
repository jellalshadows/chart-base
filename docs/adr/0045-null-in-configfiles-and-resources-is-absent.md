# ADR-0045: A `null` in `configFiles` removes the file or the key; a `null` resource quantity is absent

- **Status:** Accepted
- **Date:** 2026-10-06
- **Since:** 0.7.0
- **Related:** [ADR-0005](0005-configfiles-string-or-map.md) (amended), [ADR-0014](0014-resource-requests-required.md) (amended), [ADR-0027](0027-required-keys-in-the-schema.md)

## Context

[ADR-0005](0005-configfiles-string-or-map.md) says that an umbrella deletes a key of a map-form file by setting it to
`null`. That held only by accident. Helm deletes a key on `null` only when the chart's own `values.yaml` defines it
([Helm: Deleting a default key](https://helm.sh/docs/chart_template_guide/values_files/)), and the keys inside
`configFiles.files` never are. Measured on Helm 4.3.0 and 3.22.0, with chart-base under an alias:

- a `null` for a key of a map-form file in an override file (`-f`) or in `--set` was rendered into the file as
  `key: null`;
- a `null`, or a key written with an empty value (`key:`), in the umbrella's own `values.yaml` was rendered as
  `key: null` by Helm 3.22 always, and by Helm 4.3 as soon as any `-f`/`--set` value named that alias; Helm 4.3 drops
  it only while nothing is passed for the alias;
- a `null` for a whole file failed the schema (`got null, want string or object`), except on Helm 4.3 with nothing
  passed for the alias, where Helm dropped it.

A real deploy passes `-f` per environment, so a bare key (`grpc:` in an OpenTelemetry Collector file is a YAML null)
was rendered `grpc: null` in practically every deploy. A resource quantity had the same hole:
`resources.limits.cpu: null` was rendered `cpu: null`, and the API server stores a `null` quantity as `"0"`: an install
with a request for the same resource is rejected (`must be less than or equal to cpu limit of 0`), and a limit
without a request becomes a zero limit, silently (measured on kube-apiserver 1.33.0 and 1.37.0 with both Helm
versions).

## Decision

- chart-base reads `configFiles.files` and `resources` through `chart-base.pruneNulls` (`templates/_values.tpl`), on
  a deep copy (`deepCopy (<value> | default dict)`; never `.Values`, never a `deepCopy` of a nil). It removes every
  key whose value is `null`, with a nil test (`kindIs "invalid"`), in maps reached through maps, at any depth. It does
  not enter lists: a list, and everything inside it (a `null` item, a map with a null key), is rendered as written. A
  map left empty stays `{}`. `false`, `0`, `""`, `[]` and `{}` are kept, and numbers keep their type and precision.
- In `configFiles.files`, a file set to `null` (also a bare `name:`) is no file, `files: null` removes every file,
  and an empty file is `""`. The schema accepts `null` for a file (`["string", "object", "null"]`). One predicate,
  `chart-base.hasConfigFiles` (at least one file that is not `null`), decides the `<fullname>-files` ConfigMap, the
  `config-files` volume and mount, `checksum/config-files` and the pod template's `annotations` key. The checksum
  hashes the rendered ConfigMap, so a removed key changes no checksum.
- In `resources`, a `null` entry of `limits` or `requests`, and `limits: null`, are absent; the schema accepts
  `limits: null`. `resources`, `requests.cpu` and `requests.memory` stay required
  ([ADR-0014](0014-resource-requests-required.md)).
- chart-base so applies, in every values layer and on both Helm versions, what Helm 4.3 does to the umbrella's own
  values while nothing is passed for the alias: in that layer a map-form file renders the same bytes as before this
  decision (measured). The rule belongs to these maps; in the other maps a `null` behaves as the
  [consuming guide](../guides/consuming.md#what-a-null-does-in-each-values-layer) lists per layer.

## Consequences

- An override file can unset a key of a map-form file, and drop a file, the same way on Helm 3.22 and 4.3 and from
  every values layer. A `null` resource quantity means "no such limit or request", not a zero limit.
- A map-form file cannot carry a `null` or an empty value outside a list. Where an empty value carries meaning, the
  file changes once, with no render error: an OpenTelemetry Collector receiver enabled by a bare `grpc:` fails the
  Collector's configuration validation (`must specify at least one protocol`, measured with `otelcol validate` of
  0.162.0; write `grpc: {}`), and a Spring Boot property blanked by a bare key falls back to the jar's packaged
  value (write `key: ""`). The string form of a file keeps a literal `null`. Whether `{}` or `""` is equivalent depends
  on the application (checked for OpenTelemetry Collector 0.162.0 and Spring Boot 3.5.6 only). The upgrade guide
  gives the check.
- Every reader of a map that accepts `null` reads the pruned copy: accepting `null` in the schema alone renders a
  file whose content is the text `null` (measured). Maintainers follow the
  [development guide](../guides/development.md).
- A chart-wide "a `null` entry means absent" rule is an open decision ([roadmap](../roadmap.md#open-decisions)).

## Alternatives considered

### Documenting Helm's behaviour instead

Rejected: the documented contract is the useful one (an environment must be able to unset a key), and Helm 4.3
already strips these nulls from the umbrella's own values, so a chart that kept them could never render the same on
Helm 3.22 and 4.3.

### Failing on a `null` in a map-form file

Rejected: it could not be uniform either, since Helm 4.3 drops the `null` before the chart sees it in one layer.

### Copying the map with a `toJson` and `fromJson` round trip

Rejected: JSON decoding turns every integer into a float, and an integer above 2^53 from `--set` loses precision.
`deepCopy` keeps the types.

## References

- `templates/_values.tpl` (`chart-base.pruneNulls`, `chart-base.hasConfigFiles`), `templates/configmap-files.yaml`,
  `templates/_pod.tpl`, `templates/deployment.yaml`, `values.schema.json` (`configFiles.files`, `resources.limits`)
- `tests/configmap_test.yaml`, `tests/deployment_test.yaml`, `tests/pod_test.yaml`, `.github/scripts/alias-contract.sh`
- [Helm: Values Files](https://helm.sh/docs/chart_template_guide/values_files/)
