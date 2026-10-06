# ADR-0046: `configFiles.mountPath` is compared normalized and rendered as written

- **Status:** Accepted
- **Date:** 2026-10-06
- **Since:** 0.7.0
- **Related:** [ADR-0005](0005-configfiles-string-or-map.md) (amended), [ADR-0044](0044-guards-fail-the-render-helm-lint-reports-them.md)

## Context

Up to 0.6.0 the guard on `configFiles.mountPath` compared `trimSuffix "/"` of the path with `/tmp`, where the chart
mounts its own emptyDir. Other spellings of the same directory passed: `//tmp`, `/tmp/.` and `/./tmp` rendered a
second mount that normalizes to `/tmp`, which the API server accepts (it compares mount paths as plain strings;
which of the two mounts the container gets was not measured), and `/` rendered the ConfigMap mounted at the
container's root (accepted by the API server; what the container does then was not measured). The path was also the
last string from values rendered as a plain YAML scalar: `"/tmp #x"` was cut by YAML to `/tmp` (a second `/tmp` mount
that the guard never saw), `"/ "` to `/`. The ServiceAccount token is mounted at
`/var/run/secrets/kubernetes.io/serviceaccount`: for that exact string the admission plugin adds no token mount, and
for another spelling it adds its own next to the ConfigMap's (source reading, Kubernetes 1.37.0).

## Decision

- `chart-base.cleanPath` (`templates/_values.tpl`) returns `clean (print "/" <path>)`, the kubelet's own rule
  (`filepath.Clean("/" + path)`; Sprig's `clean` is Go's `path.Clean`): `/tmp/`, `//tmp`, `/tmp/.`, `/./tmp` and
  `/a/../tmp` are `/tmp`, `/..` is `/`. It is used only to compare, never rendered. Whitespace and `#` are kept.
- Three guards in `templates/validate.yaml`, whether or not a file is rendered (a path that would break the day a file
  is added fails now), each with its message and remedy: the path must not be `/tmp` once normalized, nor `/`, nor
  the token directory while `serviceAccount.automountToken` is true.
- The path is rendered with `quote`, as written: `/config/` stays `/config/`, and trailing whitespace or a ` #`
  comment is part of another directory.
- The token directory is rejected only while `serviceAccount.automountToken` is true: with the token off, the path
  collides with nothing, and turning the token on later fails at render. The mounts that later releases add reserve
  the directory always; one rule for every mount is an open decision for the 1.0 contract freeze
  ([roadmap](../roadmap.md#open-decisions)).

## Consequences

- A `configFiles.mountPath` that normalizes to `/tmp` or `/`, or to the token directory with the token on, fails at
  `helm template`, install and upgrade ([ADR-0044](0044-guards-fail-the-render-helm-lint-reports-them.md)). None of
  these is known to produce a working pod; the runtime was not measured.
- A path that 0.6.0 silently trimmed is sent as written and moves the mount once (upgrade guide).
- A parent of the token directory (`/var/run/secrets`) is not checked: the token mount would land inside a read-only
  ConfigMap mount, and whether such a pod starts is not measured (a known gap, pinned by a unit test).

## Alternatives considered

### Reserving the token directory unconditionally

Rejected for this existing key: it would reject a value that renders and works while the token is off.

### Rejecting whitespace and `#` in the path

Rejected: once quoted they are part of another directory, which collides with nothing.

## References

- `templates/_values.tpl` (`chart-base.cleanPath`), `templates/validate.yaml`, `templates/_pod.tpl`
- `tests/validate_test.yaml`, `tests/deployment_test.yaml`
- Kubernetes `pkg/kubelet/kubelet_pods.go` (the mount path joined and cleaned) and the ServiceAccount admission
  plugin (`MountPath == DefaultAPITokenMountPath`), v1.37.0
