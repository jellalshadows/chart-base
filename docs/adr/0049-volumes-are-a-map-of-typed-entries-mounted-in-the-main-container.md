# ADR-0049: Extra volumes are a map of typed entries, each mounted in the main container

- **Status:** Accepted
- **Date:** 2026-10-07
- **Since:** 0.7.0
- **Related:** [ADR-0005](0005-configfiles-string-or-map.md), [ADR-0011](0011-strict-draft-07-schema.md), [ADR-0033](0033-component-level-reload-on-change.md), [ADR-0044](0044-guards-fail-the-render-helm-lint-reports-them.md), [ADR-0045](0045-null-in-configfiles-and-resources-is-absent.md), [ADR-0046](0046-configfiles-mountpath-compared-normalized-rendered-as-written.md), [ADR-0050](0050-existing-claim-on-a-deployment-and-strategy-rollingupdate-null.md)

## Context

Until 0.6.0 a component had two volumes, both the chart's own: an `emptyDir` at `/tmp` and the `configFiles` ConfigMap.
A cache in memory, a certificate from a Secret, a shared ConfigMap, a scratch disk or an existing claim could not be
mounted. The facts that shape the contract:

- **Helm and `null`.** Helm deletes a key on `null` only when the chart's own `values.yaml` defines it, and Helm 4.3
  drops a `null` of the umbrella's own values while nothing is passed for that component (measured on Helm 3.22.0 and
  4.3.0; [consuming guide](../guides/consuming.md#what-a-null-does-in-each-values-layer)). A volume entry is never a key
  of the chart's defaults, so Helm cannot delete an entry or one of its fields for an overlay.
- **A strict union of per-type schemas blocks a type change.** A schema `oneOf`, or a `then` that closes each type,
  rejects an entry whose previous type's field is set to `null` (measured on Helm 4.3.0 and 3.22.0: `additional
  properties 'sizeLimit' not allowed`, `'oneOf' failed, none matched`).
- **Helm's schema library reports a `propertyNames` failure at an unrelated path** (measured on both Helm versions:
  `--set config.bad-key=x` gives `at '/prometheusRule': invalid propertyName 'bad-key'`).
- **The API server compares mount paths as written, the kubelet normalizes them**: `//tmp` next to `/tmp` is accepted
  and gives two mounts on one directory (measured on kube-apiserver 1.33.0 and 1.37.0 when 0.7.0 was designed). A
  volume whose name starts with `kube-api-access-` is taken for the ServiceAccount token volume, and a mount at the token
  directory hides the token (measured then too).
- **A file (`subPath`) beneath a ConfigMap or Secret mount fails**: the kubelet creates every mount point nested beneath
  such a volume as a directory, and a file cannot be mounted on a directory (`pkg/volume/util/nested_volumes.go` at
  v1.33.12 and v1.37.0, source reading; kubernetes#61545; not run). A directory beneath it works on kind's containerd:
  the e2e's `full` scenario checks both shapes (`/config/secrets` beneath `/config`, and `/tmp/cache` beneath `/tmp`),
  and this release merges only with that check green.
- **The claim template of an ephemeral volume is part of the pod template**: a label added to it later changes the pod
  template and rolls every such pod (inferred from its place in `spec.template`, not run).
- **The kubelet uses a volume's size limit only when it is greater than zero** (`empty_dir.go` and the eviction manager
  at v1.33.12 and v1.37.0, source reading), and an `emptyDir` with `medium: Memory` is a tmpfs whose files count against
  the container's memory limit.

## Decision

`volumes` is a map keyed by the volume name, default `{}`, not a required key. Each entry is one pod volume and its
mount in the MAIN container:

| Type | Its fields | Required |
|---|---|---|
| every type | `type`, `mountPath`, `subPath`, `readOnly` | `type`, `mountPath` |
| `emptyDir` | `medium` (`Memory`), `sizeLimit` | none |
| `configMap` | `name`, `items`, `defaultMode`, `optional` | `name` |
| `secret` | `secretName`, `items`, `defaultMode`, `optional` | `secretName` |
| `persistentVolumeClaim` (an EXISTING claim) | `claimName`, `claimAccessMode` ([ADR-0050](0050-existing-claim-on-a-deployment-and-strategy-rollingupdate-null.md)) | `claimName` |
| `ephemeral` (a claim created and deleted with each pod) | `size`, `accessMode` (default `ReadWriteOnce`; not `ReadOnlyMany`), `storageClassName` | `size` |

- **In `volumes`, a `null` entry or field is absent**, and `volumes: null` is no volume (the umbrella's included). This
  is the rule of this map, not of every map: `config.<KEY>: null` is still a schema error. Every template and guard
  reads the volumes through one accessor, `chart-base.volumes`: `chart-base.pruneNulls` on a deep copy
  ([ADR-0045](0045-null-in-configfiles-and-resources-is-absent.md)). A list (`items`) is taken as written, and a `null`
  item or `mode` in it is a schema error. A `null` entry is skipped before every check, the name checks included. An
  overlay changes a volume's type by setting the previous type's fields to `null`, or removes the entry with `null`
  and adds one under another name.
- **Two layers of strictness.** The schema holds one closed list of every type's fields, each optional field also
  accepting `null`, so a misspelt field fails there; one `if`/`then` per type adds only that type's required field. A
  guard, driven by one type-to-fields table (`chart-base.volumeTypeFields`), fails a non-null field of another type
  (`volumes.cache.medium is a field of type emptyDir and the entry is ephemeral: remove it (from an overlay, set it to
  null)`) and a `null` in the type's required field.
- **Names.** A DNS-1123 label of at most 63 characters, checked by a guard; `tmp`, `config-files`, `external-secret`
  (for 0.9.0) and the prefixes `kube-api-access-` and `chart-base-` are reserved.
- **Rendering.** The volumes and mounts follow the chart's own `tmp` and `config-files`, in key order. Each field is
  rendered by name and every string from values is quoted; a field that is not set is not rendered, and `false`, `0`
  and `""` are values. The chart never renders an empty list.
- **`readOnly`.** A `configMap` or `secret` mount is always rendered read-only, and `readOnly: false` fails. A claim
  declared `ReadOnlyMany` is rendered read-only on the volume source and on the mount: the storage driver reads only the
  source's flag (source reading, v1.33.12 and v1.37.0). `readOnly: true` on an `emptyDir` or `ephemeral` volume fails:
  nothing could write it.
- **Sizes** (`sizeLimit`, `size`) are strings with the API's quantity pattern without a sign, and a size of zero fails.
  `medium: Memory` requires `sizeLimit`.
- **The ephemeral claim template carries exactly the selector labels** (`app.kubernetes.io/name`,
  `app.kubernetes.io/instance`): no `helm.sh/chart`, no version, no user label or annotation. This set is a contract.
- **Paths.** Every mount path of the main container is compared normalized (`chart-base.cleanPath`,
  [ADR-0046](0046-configfiles-mountpath-compared-normalized-rendered-as-written.md)) with every mount the container
  renders, one list (`chart-base.mainMounts`): the chart's `/tmp`, `configFiles.mountPath` while a file is rendered, and
  the other entries. A duplicate fails, and so does a mount at `/` or at the ServiceAccount token directory, whether or
  not `automountToken` is true now. A directory may lie beneath another mount; a `configMap` or `secret` file
  (`subPath`) must not lie beneath a ConfigMap or Secret mount. `subPath` and `items[].path` are relative, without a
  `..` element, and the `items[].path` of one entry are unique once normalized.
- **References.** A `configMap` entry must not name the component's `<fullname>-env` or `<fullname>-files`, and a
  `secret` entry its `<fullname>-secrets`, whether or not the component renders them (they roll the pods by checksum,
  or are hooks of a `job` component). Two `persistentVolumeClaim` entries must not name one claim: before Kubernetes
  1.35 such a pod stays in `ContainerCreating` (the text of kubernetes PR #122140; not reproduced).
- **Restarts.** The names of the `configMap` and `secret` entries join the Reloader annotations, on Deployments only,
  under `reloadOnChange`: this is the follow-up that
  [ADR-0033](0033-component-level-reload-on-change.md) announced, and ADR-0033 is not amended.
- **`fsGroup` stays pod-level** (`fsGroup: 65532`, `fsGroupChangePolicy: OnRootMismatch`): it is applied to an
  `emptyDir`, to a CSI volume as its driver's `fsGroupPolicy` says, and not to hostPath-backed volumes such as kind's
  local-path, whose directories are world-writable (source reading).
- **Every workload type.** The volumes are part of the pod spec that Deployments, CronJobs and Jobs share; on a `job`
  component nothing new is a hook: the volumes reference existing objects, and an ephemeral claim lives as long as its
  pod.

**What cannot be expressed in 0.7.0**, with the additive exit of each: one volume at two paths of the main container
(a per-entry `mounts` list); a `sizeLimit` or `medium` for the chart's own `/tmp` (accept `volumes.tmp` as an
`emptyDir` at `/tmp` in place of the default); one claim in two entries (once the chart's floor reaches Kubernetes
1.35); user labels or annotations on an ephemeral claim; mounts in other containers (0.8.0); the types `projected` and
`downwardAPI`; `subPathExpr`, `mountPropagation` and `recursiveReadOnly`. The types `csi`, `image`, `hostPath` and
`nfs` are not offered: Pod Security `restricted` rejects the last two, `image` is dropped silently on Kubernetes 1.33,
and `csi` is the SecretProviderClass path that the roadmap rejects.

**A constraint for 0.13.0:** the claim templates of a future StatefulSet workload share the `volumes` name space (the
StatefulSet controller silently replaces a pod volume that has the name of a claim template: source reading); their
shape belongs to the 0.13.0 design.

## Consequences

- A cache, a certificate, a shared ConfigMap, a scratch disk or an existing claim is one entry, checked at
  `helm template`, install and upgrade. The guards do not fail `helm lint`
  ([ADR-0044](0044-guards-fail-the-render-helm-lint-reports-them.md)).
- The schema is looser by `null` on every entry and every optional field, and schema-only tooling (an IDE) does not flag
  a field of another type or a bad volume name; `helm template` does.
- A mounted certificate or trust bundle that the application reloads in place still restarts the Deployment on every
  rotation, and every component that mounts it; `reloadOnChange: false` is the only switch, and it also stops the
  restarts for `env`/`envFrom` Secrets. Mounted files are updated in place, except a `subPath` file, which never is
  (Kubernetes documentation).
- A read-only `emptyDir` that masks a path of the image cannot be written in 0.7.0.
- An ephemeral claim, and its storage, lives as long as its pod (the claim is owned by the pod; source reading): a
  CronJob keeps the claims of the finished runs its history limits keep (`cronjob.successfulJobsHistoryLimit`, default 3,
  and `failedJobsHistoryLimit`, default 1), a `job` component keeps its claim for `job.ttlSecondsAfterFinished`
  (default 3600), and every retry (`job.backoffLimit`) gets a claim of its own.
- `storageClassName: ""` fails, because it turns off dynamic provisioning: an ephemeral claim cannot bind a class-less
  PersistentVolume. A size is a string: `size: 10` would mean 10 bytes.
- Only the API server or the kubelet catches: a missing ConfigMap, Secret or claim (the pod stays in
  `ContainerCreating` or `Pending`); a file from a claim mounted beneath a ConfigMap mount (the chart cannot tell a file
  from a directory there; it fails in the kubelet: source reading, `nested_volumes.go`); a mount beneath a claim
  mounted read-only, which works only if the directory exists in the claim (kubernetes#121294).
- An unquoted key `on`, `yes`, `no` or `y` is read as a boolean: a volume named `y` renders as `"true"` (measured on
  Helm 4.3.0 and 3.22.0), and two such keys collide silently. No guard can see the original key: quote such keys.

## Alternatives considered

### A list of volumes

An overlay replaces a list whole, so an environment could not change one volume.

### A schema `oneOf` per type, or a `then` that closes each type

Both reject the type change an overlay writes (measured; see Context).

### The volume name in the schema's `propertyNames`

The error would name an unrelated path on both Helm versions, and camelCase, the chart's own key style, is a likely
first try (`appData`).

### `chart-base.labels` on the ephemeral claim template

`helm.sh/chart` would enter the pod template, and every chart bump would roll those pods. Without labels, the claims
could not be selected by release or component.

### A per-volume Reloader opt-out

ADR-0033 rejected per-source flags. Mounted certificates are the first case for one; the first real umbrella decides
([roadmap](../roadmap.md#open-decisions)).

## References

- `templates/_volumes.tpl` (`chart-base.volumes`, `chart-base.volumeSource`, `chart-base.volumeTypeFields`,
  `chart-base.mainMounts`), `templates/_pod.tpl`, `templates/validate.yaml`, `templates/_reloader.tpl`;
  `values.schema.json` (`definitions.volume`, `volumeItems`, `fileMode`, `positiveQuantity`).
- `tests/volumes_test.yaml`, `tests/volumes_guards_test.yaml`; `.github/scripts/alias-contract.sh` (the layers U0, U1,
  F and S); `.github/scripts/e2e.sh` (the `cronjob` and `full` scenarios).
- Kubernetes v1.33.12 and v1.37.0: `pkg/volume/util/nested_volumes.go`, `pkg/volume/emptydir/empty_dir.go`,
  `pkg/kubelet/volumemanager/populator/desired_state_of_world_populator.go`.
