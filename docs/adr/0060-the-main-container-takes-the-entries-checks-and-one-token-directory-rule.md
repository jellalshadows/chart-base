# ADR-0060: The main container takes the entries' checks, and one token-directory rule for every mount

- **Status:** Accepted
- **Date:** 2026-11-17
- **Since:** 0.12.0
- **Related:** [ADR-0044](0044-guards-fail-the-render-helm-lint-reports-them.md), [ADR-0046](0046-configfiles-mountpath-compared-normalized-rendered-as-written.md) (amended), [ADR-0047](0047-when-enabled-keys-required-externalsecret-source-probe-port-names.md), [ADR-0049](0049-volumes-are-a-map-of-typed-entries-mounted-in-the-main-container.md) (amended), [ADR-0051](0051-init-containers-and-sidecars-are-two-maps-in-one-start-order.md) (amended), [ADR-0058](0058-the-1-0-contract-and-how-it-stays-frozen.md), [ADR-0059](0059-one-probe-contract-for-every-container.md)

## Context

0.8.0 gave init containers and sidecars checks that the main container did not get, because checking the main
container would have rejected values that rendered before (ADR-0051, "Not checked"). After 1.0 a new check on a value
that renders is a major forever, so the 1.0 contract either takes them now or freezes the gap. Measured with the 0.11.0
chart on Helm 4.3.0 and 3.22.0 (`helm template`, exit 0 each), all values that fail later or silently:

- `lifecycle.preStop.httpGet.port: admin` with no `ports` entry `admin`: the kubelet resolves a hook's port name among
  the container's own ports only; a `preStop` hook on an unknown name fails with nothing but a `FailedPreStopHook` event
  while termination goes on, and a `postStart` hook kills the container (kubelet source reading,
  `pkg/kubelet/lifecycle/handlers.go` and `kuberuntime_container.go` at v1.33.12 and v1.37.0). The drain hook silently
  does not run.
- `volumes.rules: {type: configMap, items: [{key: a, path: a.yaml}], subPath: b.yaml}`: with `items` the volume holds
  only those paths, and the kubelet mounts an empty directory at `b.yaml`.
- `securityContext.runAsUser: 0` with the default `runAsNonRoot: true`: the kubelet refuses to start the container, a
  Deployment shows `FailedCreate` and `helm --wait` times out.
- `configFiles.mountPath: /var/run/secrets/kubernetes.io/serviceaccount` with `serviceAccount.automountToken: false`
  (the default): every other mount rejects the token directory whether or not the token is mounted; `configFiles`
  rejected it only while the token was on (ADR-0046). Turning the token on later (for `rbac`, a cloud identity) turned
  a working values file into a failure about an unrelated key.

## Decision

Each rule is the entries' rule, through one helper shared by the main container and the entries, with the entries'
message:

- **A hook's port name is declared.** A `lifecycle.postStart` or `preStop` `httpGet.port` given by name must be the
  name of an entry in `ports`, on every workload type, with the probe check's message (`lifecycle.preStop.httpGet.port
  "admin" is not the name of an entry in ports: the kubelet cannot resolve it and never runs the hook. ...`) and its
  note when a sidecar declares the name. `chart-base.validateProbePorts` takes the hooks through two optional inputs,
  `kinds` (postStart, preStop) and `subject` (hook); `definitions.lifecycleHandler` admits no `tcpSocket`, so only
  `httpGet` is read. A port by number is not checked.
- **A main-container `subPath` names an item.** For a `configMap` or `secret` entry of `volumes` with `items`, the
  `subPath` must be one of their paths, a directory that holds one, or `.`, compared normalized:
  `chart-base.validateSubPathItems`, the helper the entries' mounts now call too. Without `items` the keys of the
  object are unknown and nothing is checked.
- **UID 0 with `runAsNonRoot`.** The main container fails when its effective `runAsUser` (`securityContext`, else
  `podSecurityContext`) is 0 and its effective `runAsNonRoot` (the same fallback) is true:
  `chart-base.validateRunAsRoot`, the helper the entries now call too. Each field is tested for `nil`, never for
  truth, so `0` and `false` are values; an entry's merged security context always carries `runAsNonRoot` (the hardened
  default, which a `null` does not override), so the pod fallback changes nothing for the entries. `runAsNonRoot: false`
  with UID 0 renders: Pod Security is the cluster's business.
- **One token-directory rule.** `configFiles.mountPath` calls `chart-base.validateMountPath`, as every other mount
  does: the token directory fails whether or not `serviceAccount.automountToken` is true, with that helper's message.
  The `/tmp` and `/` guards of `configFiles` and their messages stay, and run first. Ancestors (`/var/run/secrets`)
  stay allowed on every mount: a mount beneath a ConfigMap mount works (the e2e mounts a Secret beneath `/config`),
  and whether the token mount starts inside a read-only ancestor is ADR-0046's known gap. The 1.0 Docker campaign
  measures it with the outcome decided in advance: if the pod does not start, a `fix:` in 0.12.x rejects ancestors on
  every mount before 1.0.0; if it starts, the gap note goes.

This amends ADR-0046 (the token directory unconditionally), ADR-0049 (the `subPath` of a volume with `items`) and
ADR-0051 (its "Not checked" list loses the hook port name and the main container's `subPath`; the UID rule is the
main container's too).

## Consequences

- Values that render and then fail at start, or never run a hook, fail at render with the key's path and the remedy.
- The main container and the entries cannot drift apart on these rules: one helper each.
- The upgrade from 0.11.0 can fail for values that rendered: a hook on an undeclared port name, a `subPath` that names
  no item, a main container that runs as UID 0 with `runAsNonRoot: true`, `configFiles` at the token directory with the
  token off. The upgrade guide lists each shape and its fix; each one did not work before.
- A component relaxed for a root image through `podSecurityContext.runAsUser: 0` now fails unless the main container
  sets `securityContext.runAsUser` or `runAsNonRoot: false`, as its sidecars already had to.

## Alternatives considered

### Keep the main container unchecked

Freezes at 1.0 a difference that has no reason left: 0.8.0 skipped the main container to keep values that rendered;
1.0 is the last release where a check on them is not a major.

### Reject ancestors of the token directory now

Would reject a shape that may work (a mount beneath a ConfigMap mount does); the campaign measures it first.

### A sibling helper for the hooks

The rule and its message are the probe check's; two copies drift.

## References

- `templates/validate.yaml` (the main container's guards, the entries' guards), `templates/_values.tpl`
  (`chart-base.validateProbePorts`, `chart-base.validateRunAsRoot`), `templates/_volumes.tpl`
  (`chart-base.validateSubPathItems`, `chart-base.validateMountPath`).
- `tests/validate_test.yaml`, `tests/volumes_guards_test.yaml`, `tests/containers_guards_test.yaml`.
