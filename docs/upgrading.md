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

## 0.2.x → 0.3.0

### `enableServiceLinks` defaults to `false`

Kubernetes injects `<SERVICE>_SERVICE_HOST`, `<SERVICE>_SERVICE_PORT` and Docker-links variables such as
`<SERVICE>_PORT=tcp://...` into every container, for every Service of the namespace. From 0.3.0 chart-base
turns that off on every Deployment, CronJob and Job
([ADR-0035](adr/0035-service-links-off-by-default.md)).

- **What changes.** The pod template gains `enableServiceLinks: false`, so the upgrade restarts every
  Deployment's pods once, through a normal rolling update; CronJob runs and Job hooks get the field at
  their next run. `KUBERNETES_SERVICE_HOST` and `KUBERNETES_SERVICE_PORT` are still injected, so in-cluster
  Kubernetes clients keep working.
- **Who is affected.** A component that reads the service-link variables of another Service, for example
  `VENDING_SALES_SERVICE_HOST`, or of its own Service. Use the Service's DNS name instead (`vending-sales`),
  or restore Kubernetes' behavior for that component:

| 0.2.x | 0.3.0 |
|---|---|
| nothing (Kubernetes' default, `true`) | `<alias>.enableServiceLinks: true` |

### `cronjob.suspend` is always rendered: set it before upgrading a CronJob suspended by hand

In 0.2.x the chart did not render `spec.suspend`, so a CronJob could only be suspended by hand
(`kubectl patch`). 0.3.0 renders `suspend: false` on every CronJob, and the upgrade can resume a CronJob
suspended that way: a client-side upgrade (Helm 3, or Helm 4 on a release installed client-side) computes
a three-way merge that writes the `false` over the live `true`; with Helm 4's server-side apply (its
default for the releases it installs) the same change can instead fail the upgrade with a field-manager
conflict. A resumed CronJob without `startingDeadlineSeconds` may start its missed run immediately.

**To keep a CronJob suspended, set `<alias>.cronjob.suspend: true` before upgrading.** Nothing changes for
a CronJob that was never suspended (`false` is Kubernetes' default), and from 0.3.0 on a suspension
belongs in the values, not only in the cluster.

### New and optional: rollout and pod runtime knobs, `lifecycle`

Nothing to change. `strategy`, `minReadySeconds` and `revisionHistoryLimit` (Deployments),
`cronjob.startingDeadlineSeconds`, `priorityClassName`, `runtimeClassName`, `dnsConfig` and `hostAliases`
render nothing until you set them, so Kubernetes' defaults apply
([ADR-0036](adr/0036-rollout-and-runtime-knobs-are-validated-pass-throughs.md)). `lifecycle` adds
`postStart` and `preStop` hooks; on a Deployment, `lifecycle.preStop` needs `preStopSleepSeconds: 0`
([ADR-0037](adr/0037-one-prestop-hook.md)), or validation fails with an error that contains:

```text
lifecycle.preStop replaces the built-in preStop sleep: set preStopSleepSeconds: 0
```
