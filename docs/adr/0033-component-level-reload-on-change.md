# ADR-0033: Component-level `reloadOnChange`

- **Status:** Accepted
- **Date:** 2026-09-28
- **Since:** 0.2.0
- **Related:** [ADR-0006](0006-checksum-for-config-reloader-for-secrets.md) (amended),
  [ADR-0030](0030-env-takes-references-only.md), [ADR-0031](0031-existing-secrets-referenced-by-name.md)

## Context

ADR-0006 gives config changes a checksum (they happen inside the deploy) and Secret rotation a Stakater
Reloader annotation (it happens outside the deploy). In 0.1.0 the switch for the annotation was
`externalSecret.reloadOnChange`, and the annotation listed only the ExternalSecret's Secret.

With `env` and `envFrom` (ADR-0030, ADR-0031) a component also reads Secrets and ConfigMaps it does not
own, and they change outside the deploy too: an operator rotates a password, someone edits a shared
ConfigMap. The switch no longer belongs to the ExternalSecret.

Facts about Reloader (Stakater Reloader v1.4.22, `pkg/common/common.go:285`, verified): the value of
`secret.reloader.stakater.com/reload` and `configmap.reloader.stakater.com/reload` is split on commas
and every entry is matched as an anchored regular expression (`^entry$`). A name with a `.` in it
(`vending.db-app`) would therefore also match other names unless the dot is escaped.

## Decision

- `reloadOnChange` (`values.yaml`, default `true`) is a component-level key that replaces
  `externalSecret.reloadOnChange`. It is `required` in `values.schema.json`, so `reloadOnChange: null`
  cannot silently switch restarts off.
- The Deployment (only the Deployment) carries `secret.reloader.stakater.com/reload`, listing the
  ExternalSecret's Secret (`<fullname>-secrets`, when `externalSecret.enabled`) and every Secret
  referenced by `env` (`secretKeyRef`) or `envFrom` (`secretRef`); and
  `configmap.reloader.stakater.com/reload`, listing every ConfigMap referenced by `env`
  (`configMapKeyRef`) or `envFrom` (`configMapRef`) (`templates/_reloader.tpl`). A list with no entries
  renders no annotation.
- Each list is deduplicated, sorted and regex-quoted, then joined with commas: `vending.db-app` becomes
  `vending\.db-app` (`tests/env_test.yaml`).
- The chart's own ConfigMaps are never listed: they roll pods through checksums inside the deploy
  (ADR-0006).
- CronJob runs and Job hooks get no annotation: each run reads the current objects when it starts.
- Breaking change in 0.2.0: `externalSecret.reloadOnChange` now fails validation (`additional properties
  'reloadOnChange' not allowed`). See the [upgrade guide](../upgrading.md).

As in ADR-0006, the annotations only have an effect if Reloader is installed. `reloadStrategy:
annotations` is the recommended setting for GitOps-managed clusters; Reloader's default `env-vars`
strategy also works with these annotations but changes the workload behind the GitOps tool's back.

## Consequences

- One switch covers everything that changes outside the deploy; rotating an operator-created Secret
  restarts the pods, with no Helm operation involved.
- A Secret shared by several components restarts all of them when it changes. That is intended: they all
  read it.
- Cost: referencing the chart's own `<fullname>-env` ConfigMap through `configMapKeyRef` would list it
  and restart the pods twice, once through the checksum and once through Reloader. Use `config` for the
  chart's own values.
- Since 0.2.0, ADR-0006's "Reloader is deliberately not used for ConfigMaps" applies to the chart's own
  ConfigMaps only (`<fullname>-env`, `<fullname>-files`, rolled by checksums). ConfigMaps referenced by
  name are listed in the Reloader annotation, because nothing in the deploy changes when they do.
- Follow-up: any future feature that mounts a ConfigMap or Secret as a volume (roadmap 0.7.0 volumes,
  0.9.0 ESO file mounts) must feed `templates/_reloader.tpl`, or the mounted object will not be watched.
- Cost: an upgrade from 0.1.x that set `externalSecret.reloadOnChange` must rename the key. The old
  key fails validation before anything reaches the cluster.

## Alternatives considered

### One flag per source

`externalSecret.reloadOnChange`, plus one for `env` and one for `envFrom`: several switches for one
behavior, with no case where a caller wants some sources watched and others not. Rejected.

### Reloader's `reloader.stakater.com/auto` mode

Reloader watches everything a workload references, without a list. Rejected, because chart-base wants
an explicit, rendered and testable list of exactly what is watched: the annotation is visible in
`helm template` and pinned by `tests/env_test.yaml`. There is also a side effect: `auto` also watches the
chart's own ConfigMaps, so a config change would restart the pods a second time after the checksum
rollout, unless the chart's ConfigMaps are excluded with Reloader's exclude annotations
(`configmaps.exclude.reloader.stakater.com/reload`, present in Reloader v1.4.22,
`internal/pkg/options/flags.go`). That double restart alone would not have ruled `auto` out; the
explicit list does.

## References

- `templates/_reloader.tpl`, `templates/deployment.yaml`
- `values.yaml` (`reloadOnChange`), `values.schema.json` (`reloadOnChange`)
- `tests/env_test.yaml`, `tests/schema_test.yaml`
- [Upgrade guide](../upgrading.md)
- [Stakater Reloader](https://github.com/stakater/Reloader)
- [Reloader v1.4.22, `pkg/common/common.go` (comma split and anchored regular expression)](https://github.com/stakater/Reloader/blob/v1.4.22/pkg/common/common.go#L284-L300)
