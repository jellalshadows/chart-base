# ADR-0005: `configFiles` accepts a string or a map

- **Status:** Accepted
- **Date:** 2026-09-27
- **Since:** 0.1.0

## Context

Some workloads need a whole configuration file mounted into the container, not just environment
variables — the most common case in this chart's target stack is a Spring Boot application's
`application.yaml`. Spring Boot's own documentation describes
`spring.config.additional-location` (settable as the environment variable
`SPRING_CONFIG_ADDITIONAL_LOCATION`) as a location that is added on top of, and **overrides**, the
`application.yaml` packaged inside the jar; it must be supplied as an environment variable (not a
JVM property alone) and directory locations must end with `/`. The README's HTTP API recipe sets
`SPRING_CONFIG_ADDITIONAL_LOCATION: "optional:file:/config/"` under `config` together with a
`configFiles.files` entry for `application.yaml`.

A file's content can be handed to chart-base two ways: as a plain string, or as a YAML/JSON-shaped
map that Helm can merge. A string has to be written back out byte for byte — no re-encoding step may
change even a single character, because the file is meant to be exactly what the author wrote. Helm's
`toJson` escapes characters like `<` as `<` for safe embedding in JSON contexts, which would
corrupt a file such as an XML config or anything containing HTML-sensitive characters; `quote` does
not have this problem, so string values are rendered with `quote`.

A map value, on the other hand, is rendered with `toYaml`: this lets an umbrella override a nested
key by re-declaring only that key in its own `values.yaml` — Helm's values merge is a deep merge of
maps, and setting a key to `null` deletes it from the merged result. The cost is that `toYaml` goes
through Go's YAML encoder, which follows YAML 1.1 scalar resolution rules: unquoted `on`/`yes`
resolve to the boolean `true`, `1.10` resolves to the float `1.1` (a trailing zero is not
significant), and `0755` resolves to the decimal integer `493` (a leading zero is octal in YAML
1.1). A value meant to stay a string must be quoted in the umbrella's `values.yaml` to survive the
round trip.

## Decision

- `configFiles.files` is a map of file name to content, rendered into ConfigMap `<fullname>-files`
  only when non-empty (`templates/configmap-files.yaml`).
- A **string** value is rendered verbatim with `{{ $content | quote }}`, preserving the file exactly
  (no `toJson`-style character escaping).
- A **map** value is rendered with `{{ toYaml $content | quote }}`, so an umbrella can override a
  single nested key per environment by re-declaring it, and delete a key by setting it to `null`.
  Ambiguous scalars inside such a map (`"on"`, `"1.10"`, `"0755"`) must be quoted by whoever writes
  them, or YAML 1.1 resolves them to a boolean, a float or a different integer.
- `configFiles.mountPath` (default `/config`) is the read-only mount point for the rendered
  ConfigMap (`templates/_pod.tpl`: `volumeMounts` entry `config-files`, `readOnly: true`); it must
  not be `/tmp`, which is already mounted as the chart's own `emptyDir`
  (`templates/validate.yaml` guard).
- Secret values must never be written into `configFiles`: the recipe pattern is a `${VAR}`
  placeholder in the file, resolved from an environment variable that itself comes from `config` or
  `externalSecret`.

## Consequences

- One key (`configFiles.files`) covers both "ship this file exactly" and "let environments override
  pieces of this file", instead of two separate value shapes.
- Trade-off: mixing content types under the same key means a consumer must know which representation
  they need up front — switching a file from a map to a string (or back) changes the merge behavior
  for every umbrella that overrides it, and is a behavior change even though the schema still
  accepts both.
- The YAML 1.1 ambiguous-scalar trap is real and silent: a value like `0755` written unquoted in a
  map does not fail validation, it just becomes a different, valid integer.

## Alternatives considered

### Strings only

Simpler to reason about (no YAML ambiguous-scalar trap), but an umbrella could never override a
single nested key per environment — the whole file would have to be redeclared to change one value.

### Maps only

Cannot represent a file's exact bytes: a map necessarily goes through YAML re-encoding, which cannot
hold arbitrary text (a properties file, a script, an XML file) byte for byte.

## References

- `templates/configmap-files.yaml`
- `templates/_pod.tpl`
- `templates/validate.yaml`
- `values.yaml` (`configFiles`)
- [Spring Boot: Externalized Configuration](https://docs.spring.io/spring-boot/reference/features/external-config.html)
