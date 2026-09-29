# ADR-0006: Checksums for config, Reloader for Secrets

- **Status:** Accepted — amended by [ADR-0033](0033-component-level-reload-on-change.md) (0.2.0)
- **Date:** 2026-09-27
- **Since:** 0.1.0

## Context

A Kubernetes Deployment does not restart its pods just because a ConfigMap or Secret it references
changed: `envFrom` reads the referenced object's content only when a pod is (re)created. chart-base
needs two different answers because config and secrets change through two different paths.

`config` and `configFiles` are values the umbrella declares in the same `values.yaml` that drives the
rest of the release, so a config change is applied in the very same `helm upgrade`/`helm template`
invocation that changes anything else about the component. chart-base forces that change to reach
the pods immediately by hashing the rendered ConfigMaps into pod template annotations: if the caller
waits for the rollout (`helm upgrade --wait`, `--rollback-on-failure` on Helm 4 or `--atomic` on
Helm 3, or a tool like helmfile configured with `wait: true`), a config value that breaks the app surfaces as that same invocation failing, with the
release's own logs to point at, rather than as a mysterious failure days later.

A Secret backed by `externalSecret` is different: its content is written by the External Secrets
Operator (ESO) polling the remote store on `externalSecret.refreshInterval` (default `1h`), which
happens **outside** any Helm operation — the Secret can change while nothing is being deployed at
all. Hashing the Secret into a pod annotation would not help, because chart-base never sees ESO's
write; only a controller that watches the Secret directly, in the cluster, can react to it. Stakater
Reloader is that controller: it watches for annotated workloads and restarts them when the Secret (or
ConfigMap) they reference changes, and its documentation recommends `reloadStrategy: annotations` for
GitOps-style clusters, where the alternative default strategy (rolling the Deployment through an
environment variable Reloader injects itself) creates a diff the GitOps tool did not make.

## Decision

- The Deployment's pod template carries `checksum/config-env` and `checksum/config-files`
  annotations (`templates/deployment.yaml`), each `sha256sum` of the corresponding rendered
  ConfigMap's `data`, present only when `config` (respectively `configFiles.files`) is non-empty.
  Changing either value changes its checksum, which changes the pod template, which rolls the pods
  in the same `helm upgrade`.
- When `externalSecret.enabled` and `externalSecret.reloadOnChange` (default `true`) are both set,
  the **Deployment** — not the Job or CronJob — carries the annotation
  `secret.reloader.stakater.com/reload: <fullname>-secrets` (`templates/deployment.yaml`). The
  cluster must run Stakater Reloader for this annotation to have any effect; without Reloader
  installed, it is inert. Reloader's `reloadStrategy: annotations` is the recommended setting for
  GitOps-managed clusters, because its default `env-vars` strategy also works with this annotation
  but changes the workload behind the GitOps tool's back.
- Reloader is deliberately **not** used for ConfigMaps. Doing so would mean a broken config no
  longer causes the same `helm upgrade` invocation to fail: the Deployment object itself would not
  have changed (its config is read from the ConfigMap by the pod, not baked into the template), so
  the release would look successful, and the actual restart — and any resulting crash loop — would
  land on whichever unrelated deploy of the domain happens to run next, or never, if nothing else
  changes for a while.

## Consequences

- A config change and its consequences (a broken pod, a bad rollout) are visible in the same
  operation that made the change, for anyone who deploys with `--wait` (or `--rollback-on-failure` on Helm 4,
  `--atomic` on Helm 3) or an equivalent tool.
- Secret rotation reaches running pods without a Helm operation at all, which is the point of using
  ESO, but it depends entirely on Reloader being installed (ideally with the `annotations`
  strategy) — a platform-level requirement outside this chart's control (README "Rules for
  consumers").
- Trade-off / cost: two different reload mechanisms exist side by side for what looks, from the
  umbrella author's point of view, like "my env vars changed." Anyone debugging a stuck rollout has
  to know which mechanism applies to which kind of change.

## Alternatives considered

### Reloader for everything, including ConfigMaps

Rejected because it breaks the fail-fast property described above: Helm would report the deploy
successful before Reloader's restart happens, so a broken config would not fail the deploy that
introduced it — it would surface later, on someone else's unrelated change to the same domain.
Running checksum and Reloader together for the same object would also restart the pods twice for one
change.

### No reload mechanism for the Secret

Without Reloader (or an equivalent), a Secret rotated by ESO never reaches already-running pods; they
would only pick it up at their next restart for an unrelated reason (a node drain, a new image), which
can be an arbitrarily long time for a rotated credential to still be in use.

## References

- `templates/deployment.yaml`
- `values.yaml` (`externalSecret.reloadOnChange`)
- [Kubernetes: ConfigMaps](https://kubernetes.io/docs/concepts/configuration/configmap/)
- [Stakater Reloader](https://github.com/stakater/Reloader)
