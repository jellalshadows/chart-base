# ADR-0027: Keys the templates rely on are `required`

- **Status:** Accepted — amended by [ADR-0044](0044-guards-fail-the-render-helm-lint-reports-them.md) (0.6.0) and [ADR-0047](0047-when-enabled-keys-required-externalsecret-source-probe-port-names.md) (0.7.0)
- **Date:** 2026-09-28
- **Since:** 0.1.0

## Context

Helm's values merging has a sharp edge that is easy to miss: setting a key to `null` in an override does not
"keep the default" — it deletes the key from the merged map entirely, before `values.schema.json` ever
validates anything (Helm: [Deleting a default key](https://helm.sh/docs/chart_template_guide/values_files/);
the schema validates whatever values survive the merge, not the consumer's intent). For most keys a missing entry is
harmless, because the template still falls back to a Sprig default. For a handful of keys, though, the
*absence* produces a different and worse outcome than "use the default": a ServiceAccount token that gets
auto-mounted because `automountToken` disappeared, a hook Job that is deleted the moment it finishes, together with its logs, because
`ttlSecondsAfterFinished` disappeared (`templates/job.yaml` pipes the value through `int64`, and a missing
value becomes `0`), or a security-hardening block that vanishes entirely.

This was found twice, independently, before 0.1.0. First while prototyping: `ports: null`
on a `deployment` with a Service made the property disappear before the schema saw it, and the rendered
Service ended up with no ports at all. Then again during the final review before 0.1.0
shipped, which generalized the fix: any key whose silent disappearance would flip a security- or
correctness-relevant default needs to be `required` in `values.schema.json`, so `helm lint`/`helm template`
fails loudly with the schema's own error instead of rendering a manifest with the wrong default already
baked in.

## Decision

- `values.schema.json`'s top-level `required` array includes `serviceAccount`, `job`, `podSecurityContext`
  and `securityContext`, among others — none of these four objects can be deleted wholesale via `null`
  without failing validation.
- Within `serviceAccount`, `required: ["create", "automountToken"]` — `automountToken: null` (which would
  otherwise silently mount the ServiceAccount token) fails validation instead of rendering.
- Within `job`, `required: ["phase", "backoffLimit", "ttlSecondsAfterFinished"]` — a `job.ttlSecondsAfterFinished:
  null` (which would render `ttlSecondsAfterFinished: 0` and delete the hook Job, with its logs, the
  moment it finishes, ADR-0007) is rejected the same way.
- `ports` is required conditionally, through the schema's `allOf`: when `workload.type` is `deployment` and
  `service.enabled` is `true`, `ports` becomes `required` with `minItems: 1` — this is the exact case
  the prototype found broken, now closed structurally rather than by convention.
- Keys whose own legitimate default *is* `null` — `job.activeDeadlineSeconds`, `topologySpreadConstraints` —
  stay optional: writing `null` for them reproduces the existing default instead of changing it, so there is
  nothing for `required` to protect against.

## Consequences

- `serviceAccount.automountToken: null`, `job.ttlSecondsAfterFinished: null`, or an omitted
  `podSecurityContext`/`securityContext` now fail `helm lint --strict`/`helm template` immediately, with the
  schema's own error naming the missing key, instead of silently changing what gets deployed.
- Trade-off: `required` only enforces presence, not a particular value — a consumer can still deliberately
  write `automountToken: true` and pass validation. This guards against *accidental* deletion via `null`,
  not against a value that is present but wrong.
- A second cost: nothing in JSON Schema itself flags "this key needs `required` treatment" — every future
  key with a non-null, security- or correctness-relevant default has to be remembered and added by hand. This
  is an ongoing discipline the maintainer has to keep applying, not a mechanism that enforces itself as the
  chart grows.

## Alternatives considered

### Trusting consumers not to write `null`

Already failed once during prototyping: `ports: null` silently rendered a Service with no ports at all
— precisely the class of bug `required` exists to catch at `helm lint` time, before it ever
reaches a real cluster.

## References

- `values.schema.json` (top-level `required`; `serviceAccount.required`; `job.required`; the `allOf` clause
  conditionally requiring `ports`)
- [Helm: Schema files](https://helm.sh/docs/topics/charts/#schema-files)
