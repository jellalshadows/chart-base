# ADR-0013: Secure by default (Pod Security `restricted`)

- **Status:** Accepted
- **Date:** 2026-09-27
- **Since:** 0.1.0

## Context

chart-base's pod and container security settings are values with defaults, not hardcoded — every field
under `podSecurityContext` and `securityContext` can be overridden. What matters is what the *default*
is, because most consumers never touch it: whatever ships as the default is what most components in
every umbrella actually run with. A chart whose secure posture requires every consumer to opt in,
key by key, only ever protects the consumers who already knew to ask — which defeats the point of a
shared base chart in the first place.

Kubernetes' Pod Security Standards define three profiles; `restricted` is the most hardened one, and it
is what platform teams enforce with a namespace label
(`pod-security.kubernetes.io/enforce=restricted`). Meeting `restricted` is not automatic just because a
chart sets *some* security context — it requires a specific combination of fields to be at specific
values, and defaulting only some of them (e.g. `runAsNonRoot` without `allowPrivilegeEscalation: false`
and a dropped `ALL` capability set) still gets a pod rejected by a namespace enforcing it. `restricted`
also does not by itself require a read-only root filesystem or a fixed non-root UID/GID — those are
additional hardening chart-base applies on top, not something the profile mandates.

The chart proves the claim rather than just asserting it: the e2e suite installs every `ci/` scenario
into a namespace labelled `pod-security.kubernetes.io/enforce=restricted` (`.github/scripts/e2e.sh`),
so a pod that does not satisfy `restricted` fails to admit, and the e2e job fails.

## Decision

- **`podSecurityContext`** (pod-level, `values.yaml`): `runAsNonRoot: true`, `runAsUser: 65532`,
  `runAsGroup: 65532`, `fsGroup: 65532`, `fsGroupChangePolicy: OnRootMismatch`,
  `seccompProfile.type: RuntimeDefault`.
- **`securityContext`** (container-level, `values.yaml`): `allowPrivilegeEscalation: false`,
  `readOnlyRootFilesystem: true`, `runAsNonRoot: true`, `capabilities.drop: [ALL]` (no capabilities are
  added back).
- Of these, `restricted` requires exactly: `runAsNonRoot`, a `RuntimeDefault` (or `Localhost`) seccomp
  profile, `allowPrivilegeEscalation: false`, and dropping all Linux capabilities — the profile's own
  Capabilities control still permits one capability to be added back,
  `securityContext.capabilities.add: [NET_BIND_SERVICE]`, and no other. chart-base's default adds
  nothing back at all (`capabilities.drop: [ALL]`, no `add` key in `values.yaml`): that is the chart's
  own choice on top of the profile's minimum, not something `restricted` itself requires — the same
  way `readOnlyRootFilesystem`, the fixed UID/GID `65532`, `fsGroup` and `fsGroupChangePolicy` are
  **not** part of the `restricted` profile either; all of these are extra hardening the chart chooses
  as its default on top of the profile's minimum.
- `65532` is a fixed, non-root, non-root-group UID/GID (the conventional "nonroot" distroless user) so
  the pod runs with a known, predictable identity regardless of what the image's own `USER` declares.
- Because the container filesystem is read-only by default, an `emptyDir` volume is always mounted at
  `/tmp` (`templates/_pod.tpl`) — writable scratch space that many runtimes (temp files, JVM, etc.)
  need even when the rest of the filesystem cannot be written to. `configFiles.mountPath` is guarded
  against being `/tmp` itself (`templates/validate.yaml`), so a component cannot accidentally shadow
  this volume with its own read-only config mount.
- The ServiceAccount token is not mounted into the pod by default: `serviceAccount.automountToken:
  false` (`values.yaml`) sets `automountServiceAccountToken: false` on both the rendered
  `ServiceAccount` object (`templates/serviceaccount.yaml`) and the pod spec itself
  (`templates/_pod.tpl`), so neither object can re-enable it behind the other's back — a component that
  needs the Kubernetes API sets `automountToken: true` explicitly.
- Every one of these is an independent key under `podSecurityContext`/`securityContext`/
  `serviceAccount`; there is no single "secure" toggle. Lowering the posture (e.g. a legacy image that
  needs to write to its own filesystem) means overriding the one field that needs it —
  `securityContext.readOnlyRootFilesystem: false` — while every other default stays in place.
- The e2e suite (`.github/scripts/e2e.sh`) installs every `ci/` scenario into a namespace labelled
  `pod-security.kubernetes.io/enforce=restricted`, so these defaults are proved to satisfy `restricted`
  on every PR, not just asserted.

## Consequences

- Every component gets the hardened posture without its author having to know Pod Security Standards
  exist; a namespace that enforces `restricted` never rejects a chart-base pod running with defaults.
- Trade-off: an image that was never built to run as a fixed non-root UID with a read-only filesystem
  (writes to its own install directory, expects to run as root, needs an added capability) fails to
  start until a consumer overrides the specific field that conflicts — a real, occasionally surprising
  cost the first time someone onboards such an image, though it is the exact class of image
  `restricted` is meant to push out.
- `fsGroupChangePolicy: OnRootMismatch` avoids recursively `chown`-ing every file on every pod start for
  volumes that already have the right ownership, but a volume whose ownership drifts for another reason
  still only gets fixed up when its GID doesn't match — an edge case, not the common path.

## Alternatives considered

### Permissive defaults (nothing set, or root-friendly defaults)

Every consumer would have to harden every component by hand to satisfy a `restricted` namespace, and in
practice most would not — either because they do not know the profile exists, or because it is easy to
skip under a deadline. A shared base chart that does not default to the safe behavior is not actually
raising the floor for anyone who does not already ask for it.

## References

- `values.yaml` (`podSecurityContext`, `securityContext`, `serviceAccount.automountToken`)
- `templates/_pod.tpl`
- `templates/serviceaccount.yaml`
- `templates/validate.yaml` (`configFiles.mountPath` must not be `/tmp`)
- `.github/scripts/e2e.sh`
- [Kubernetes: Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/)
- [Kubernetes: Configure a Security Context for a Pod or Container](https://kubernetes.io/docs/tasks/configure-pod-container/security-context/)
