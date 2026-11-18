# ADR-0067: A per-volume Reloader opt-out

- **Status:** Accepted
- **Date:** 2026-11-18
- **Since:** 1.3.0
- **Related:** [ADR-0033](0033-component-level-reload-on-change.md) (amended), [ADR-0049](0049-volumes-are-a-map-of-typed-entries-mounted-in-the-main-container.md) (amended), [ADR-0058](0058-the-1-0-contract-and-how-it-stays-frozen.md), [ADR-0064](0064-from-1-0-0-a-new-key-is-optional.md)

## Context

With `reloadOnChange: true` (the default), the Deployment carries Stakater Reloader annotations that list every Secret
and ConfigMap the pod reads from outside the deploy, the `configMap` and `secret` entries of `volumes` included. So
Reloader restarts the Deployment when one of them changes ([ADR-0033](0033-component-level-reload-on-change.md)).

A mounted file does not need a restart when the application re-reads it. The kubelet updates the files of a
ConfigMap or Secret volume in place, except a `subPath` mount, which it never updates. A certificate or a trust bundle
that rotates restarts every component that mounts it, on every rotation. ADR-0033 rejected per-source flags.
[ADR-0049](0049-volumes-are-a-map-of-typed-entries-mounted-in-the-main-container.md) named mounted certificates as the
first case for one, and left it to a real umbrella. The owner ruled on 2026-11-18 that every post-1.0 improvement is
built, this one included.

## Decision

- **`volumes.<name>.reloadOnChange`**, a boolean, optional ([ADR-0064](0064-from-1-0-0-a-new-key-is-optional.md)), a
  field of `configMap` and `secret` entries only (another type fails with the message of a field of another type).
  `false` keeps the volume's ConfigMap or Secret out of the Reloader annotations. `true`, `null` and absent list it, as
  in 1.2.0.
- **It removes this volume's contribution only.** An `env` reference, an `envFrom` source or another volume that names
  the same ConfigMap or Secret still lists it, because a variable never changes without a restart.
- **The top-level `reloadOnChange` still wins:** with `false` nothing is listed, whatever a volume says.
- **A guard:** `reloadOnChange: false` on a volume that the main container or a sidecar mounts with `subPath` fails.
  The kubelet never updates that mount, so a change would reach the container only when the pod restarts. An init
  container's `subPath` mount is allowed: it has exited before a change.
- **Nothing is rendered in the pod:** the field is read by the Reloader helper only.

## Consequences

- It amends ADR-0033 (one per-source flag, on volumes only) and ADR-0049 (the alternative it left open is taken).
- The Deployment's annotations change only for a volume that sets `false`. Removing a name from
  `secret.reloader.stakater.com/reload` changes no pod template, so no pod rolls.
- Unit tests cover the annotation, the dedup with `env` and the guard. The e2e reads the annotations of the full
  scenario, which does not set the field.

## Alternatives considered

### A flag on every source (`env`, `envFrom`)

A variable is read once, at start, so an opted-out variable would stay stale until an unrelated restart. ADR-0033's
reason still holds for those.

### Reloader's own `reloader.stakater.com/auto` with a `match` annotation on the Secret

It moves the decision to the Secret, which the component usually does not own (a cert-manager Secret), and it changes
the chart's explicit list for a discovery mode.

## References

- `templates/_reloader.tpl`, `templates/_volumes.tpl` (`chart-base.volumeTypeFields`), `templates/validate.yaml`,
  `values.schema.json` (`definitions.volume`), `tests/volumes_test.yaml`, `tests/volumes_guards_test.yaml`.
- Kubernetes: ConfigMap and Secret volumes are updated in place, a `subPath` mount never is (the documentation of
  ConfigMaps, "Mounted ConfigMaps are updated automatically").
