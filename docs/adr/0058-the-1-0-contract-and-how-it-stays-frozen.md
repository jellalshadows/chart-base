# ADR-0058: The 1.0 contract, and how it stays frozen

- **Status:** Accepted
- **Date:** 2026-11-17
- **Since:** 0.12.0
- **Related:** [ADR-0008](0008-names-are-release-alias-and-never-truncated.md), [ADR-0009](0009-no-name-overrides.md), [ADR-0010](0010-chart-version-never-restarts-pods.md), [ADR-0011](0011-strict-draft-07-schema.md), [ADR-0027](0027-required-keys-in-the-schema.md), [ADR-0028](0028-podlabels-cannot-override-selector-labels.md), [ADR-0057](0057-common-labels-and-annotations-service-annotations-and-extraobjects.md)

## Context

Criterion 3 of 1.0.0 is "the contract is frozen: selector labels and key names. From 1.0 on, only additive changes
(`feat:`) or explicit majors" ([roadmap](../roadmap.md#100-criteria)). Up to 0.11.0 the contract was a set of habits
spread over the ADRs: the selector labels never change (ADR-0010, ADR-0028), names are `<release>-<alias>` (ADR-0008),
every key is public API (the [development guide](../guides/development.md#changing-the-values-contract)). Nothing listed
what exactly is frozen, and nothing failed when a key disappeared: the unit tests reject a removed key only when one of
them happens to set it, and a renamed key in a definition shared by several maps (`definitions.probe`, for example)
changes the contract of every map at once.

What a consumer depends on, read from the renders of every `ci/` scenario at 0.11.0 and from the umbrella that
validated criterion 2 (`jellalshadows/domain-boutique`): the names of the objects (a sibling calls `<release>-<alias>`, a
NetworkPolicy and a dashboard select by name or label), the selector labels (a Deployment's `.spec.selector` is
immutable), the label and annotation keys the chart writes (dashboards, policies and the consumer's own selectors read
them), the main container's name (`kubectl logs -c`, a `ContainerResource` metric), the names of the chart's volumes (an
init container or a sidecar mounts them by name) and every values key name (each values file of each environment).

## Decision

**Frozen from 1.0:**

- the selector labels `app.kubernetes.io/name: <alias>` and `app.kubernetes.io/instance: <release>`, exactly these two,
  in every selector the chart renders;
- the object names: `<release>-<alias>` for every object of the component, `<release>-<alias>-env` and
  `<release>-<alias>-files` for its ConfigMaps, `<release>-<alias>-secrets` for the ExternalSecret and its Secret,
  `<release>-<alias>.<key>` for an extra object and `<release>-<alias>.<clusterRole>` for a RoleBinding to a ClusterRole;
- the main container's name (the alias) and the names of the chart's volumes: `tmp`, `config-files`, `external-secret`;
- the label keys the chart writes: `app.kubernetes.io/name`, `instance`, `part-of` (the release) and `version` (from
  the image tag, absent without one) on every object and pod template, `app.kubernetes.io/managed-by` and
  `helm.sh/chart` on every object's metadata and never on a pod template (ADR-0010); `app.kubernetes.io/component` is
  not in this list, and 0.12.0 decides it on its own;
- the annotation keys the chart writes: `checksum/config-env` and `checksum/config-files` on a pod template,
  `secret.reloader.stakater.com/reload` and `configmap.reloader.stakater.com/reload`, and the hook keys of a `job`
  component (`helm.sh/hook`, `helm.sh/hook-weight`, `helm.sh/hook-delete-policy`, weight `0` on the Job and `-10` on
  its support objects);
- every values key name, as listed in `tests/contract/keys.txt`.

**Not frozen:** error messages, the order of keys in a manifest, comments and documentation. A message can be reworded
in any release; the tests pin its meaning, not its wording.

**After 1.0:** a key is never removed or renamed; a new key is optional (never a new root `required`, the lesson of
0.11.0's design review: `--reuse-values` keeps the old values, which lack the key); a default that changes the manifest
of an unchanged values file, and a check that rejects values that render, are majors.

**No renames.** The oddities considered stay as they are: `externalSecret.envFrom` (a switch, a homonym of the main
container's `envFrom`), `autoscaling.targetCPUUtilizationPercentage` (kept next to `autoscaling.metrics`), the `job.*`
keys a CronJob's runs read, and `serviceAccount.automountToken`. Renaming any of them breaks every values file for no
change in behavior.

**Decided not to add before 1.0** (each one is additive later, so leaving it out freezes nothing):

- a per-volume Reloader opt-out: the first real umbrella mounts no ConfigMap or Secret volume and did not ask;
- a key that overrides the version label: the label follows the tag, and next to a digest a version-shaped tag
  (`7.2.4-alpine`) keeps it meaningful;
- an OpenTelemetry service-name annotation by default: integrations are opt-in, and the annotation would reserve a key
  in `podAnnotations`; the README's recipe sets `OTEL_SERVICE_NAME`;
- a placeholder for a sibling's address: a `{{release}}` token in `config` would stop rendering values as written,
  which is itself a break; the address is written with the release name, kept in one place with a YAML anchor;
- reading `global`: it stays accepted and unread, because reading it would change what values that do nothing today do;
- literal variables for an init container (an entry-level `config`): the 0.8.0 follow-up, additive;
- nothing changes because the first umbrella exercises only the Deployment path: the e2e's umbrellas cover the CronJob
  and Job aliases.

**The mechanism.**

- `tests/contract_test.yaml` pins the names, the selectors, the main container's and the volumes' names and the label
  and annotation keys, on the three workload types, through helm-unittest like every other suite.
- `.github/scripts/contract-keys.sh` lists every key a values file can set, as a path read from `values.schema.json`
  (properties, list items `[]` and map entries `<name>`, through every `$ref`, `allOf`, `anyOf`, `oneOf`, `then` and
  `else`), and compares the list with the committed `tests/contract/keys.txt`. A key that is gone fails ("a removed or
  renamed key is a major change"); a key that is not listed fails until the list that holds it is committed with the
  change that adds it (`contract-keys.sh --list . > tests/contract/keys.txt`). It runs in the CI `lint` job. A
  packaged chart carries no `tests/`, so the list can be given as a second argument, to check a published chart
  against the repository's list.

## Consequences

- A rename, a removed key or a changed name fails in the pull request that makes it, with a message that says why, not
  in a consumer's upgrade.
- The list is long (every key under every map entry is spelled out: a sidecar's probe keys appear once per probe kind)
  and every new key adds lines to it. That is the point: the diff of `keys.txt` shows a reviewer the contract change.
- Renaming an internal definition of the schema changes nothing in the list, and so does moving a key into a shared
  definition: the paths are a consumer's paths.
- The list cannot tell a type change or a narrower rule from no change: those are caught by the schema tests and by the
  rule above (a check that rejects values that render is a major), not by this script.
- What a consumer reads outside these items (the order of keys, a message's wording) can change in a minor release.

## Alternatives considered

### The schema's own paths (`jq paths`) without following `$ref`

Simpler, but a key of a definition appears once under `definitions.<name>`, so renaming a definition fails as a removal
although no consumer sees it, and pointing a map at another definition that lacks a key passes. The consumer's paths are
the contract.

### A snapshot of `values.yaml`

It shows the defaults, not the keys: most keys have no default (`volumes.<name>.subPath`, every probe field), so a
removal would pass.

### Freezing error messages

Messages explain and get better; consumers do not parse them, and pinning their wording would turn every clarification
into a major.

## References

- [docs/roadmap.md, 1.0.0 criteria](../roadmap.md#100-criteria).
- `tests/contract_test.yaml`, `.github/scripts/contract-keys.sh`, `tests/contract/keys.txt`, the `lint` job of
  `.github/workflows/ci.yaml`.
- [Testing guide: the 1.0 contract](../guides/testing.md#the-10-contract).
