# Upgrade guide

Before 1.0, a breaking release bumps the minor version and its pull request title carries `!`
(`feat!:`). This page lists, for every breaking release, what to change in your values. Releases
that are not listed here need no change; the [changelog](../CHANGELOG.md) has every release.

## 0.1.x → 0.2.0

### `externalSecret.reloadOnChange` moved to `reloadOnChange`

The Reloader switch now covers everything that changes outside the deploy — the ExternalSecret's
Secret and every Secret or ConfigMap referenced in `env` or `envFrom` — so it moved from
`externalSecret` to the component ([ADR-0033](adr/0033-component-level-reload-on-change.md)).

| 0.1.x | 0.2.0 |
|---|---|
| `<alias>.externalSecret.reloadOnChange: false` | `<alias>.reloadOnChange: false` |

If you never set it, there is nothing to do: the default is still `true`. If you keep the old key,
validation fails before anything reaches the cluster, with an error that contains:

```text
additional properties 'reloadOnChange' not allowed
```

### New and optional: `env` and `envFrom`

Nothing to change. `env` takes references only (`valueFrom`: `fieldRef`, `resourceFieldRef`,
`secretKeyRef`, `configMapKeyRef`); literal values stay in `config`
([ADR-0030](adr/0030-env-takes-references-only.md)). `envFrom` injects existing ConfigMaps and
Secrets whole, before the component's own `config` and `externalSecret`
([ADR-0032](adr/0032-external-envfrom-first-env-wins.md)). An `env` key that also exists in `config`
or `externalSecret.data` fails validation.
