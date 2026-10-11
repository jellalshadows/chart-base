# ADR-0053: The ExternalSecret takes `dataFrom`, a curated template and a file mount, and its injection is a switch

- **Status:** Accepted
- **Date:** 2026-10-09
- **Since:** 0.9.0
- **Related:** [ADR-0004](0004-env-in-configmap-secrets-through-externalsecret.md) (amended), [ADR-0027](0027-required-keys-in-the-schema.md),
  [ADR-0032](0032-external-envfrom-first-env-wins.md) (amended), [ADR-0033](0033-component-level-reload-on-change.md), [ADR-0044](0044-guards-fail-the-render-helm-lint-reports-them.md),
  [ADR-0047](0047-when-enabled-keys-required-externalsecret-source-probe-port-names.md) (amended), [ADR-0049](0049-volumes-are-a-map-of-typed-entries-mounted-in-the-main-container.md),
  [ADR-0051](0051-init-containers-and-sidecars-are-two-maps-in-one-start-order.md) (amended), [ADR-0054](0054-env-externalsecretkeyref-references-the-components-own-secret.md)

## Context

Up to 0.8.0 a component has one ExternalSecret (`external-secrets.io/v1`) whose `data` maps a variable name to one
remote value, and its Secret `<fullname>-secrets` reaches the main container whole through `envFrom` (ADR-0004). Three
common needs had no expression: a JSON secret whose members should all become keys (one `data` entry per member), a
value built from several secrets (a connection string, a configuration file that holds a password), and a certificate
or a key as a FILE (0.7.0 rejects a `volumes` entry that mounts the component's own Secret).

The facts this record relies on, with what backs them:

- **How External Secrets builds the Secret** (External Secrets Operator v2.11.0, source reading, and its own code run
  in a harness): the `dataFrom` entries are merged in list order, a later entry winning on a key, then every `data`
  entry, which wins over every `dataFrom` key (`externalsecret_controller_secret.go` L79-120). A `rewrite` runs on an
  extract's keys; once a rewrite is present the `conversionStrategy` is skipped (L233-242). With a template,
  `mergePolicy: Replace`, External Secrets' default, writes the templated keys only, `Merge` adds them to the provider
  keys and the templated key wins on a name both have, and a template without data keeps the provider keys
  (`externalsecret_controller_template.go` L60-75). Once a template exists, the Secret no longer gets a copy of the
  ExternalSecret's labels and annotations, and the values of `template.metadata` are executed as templates (source
  reading). The template engine's delimiters are a controller flag, `{{` and `}}` by default
  (`runtime/template/v2/template.go` L88-96).
- **The API**: `external-secrets.io/v1` exists since External Secrets 0.16.0 and is the only served version from 0.17.0
  (source reading). On kube-apiserver 1.33.0 and 1.37.0 with the External Secrets 2.11.0 CRDs, every ExternalSecret
  the chart renders (`data`, `dataFrom` with a decoding strategy, a template) is stored as rendered, with the CRD's
  defaults `target.deletionPolicy: Retain` and `target.template.engineVersion: v2` added, with Helm 3.22.0
  (client-side) and Helm 4.3.0 (server-side apply) (measured).
- **The kubelet** turns every key of an `envFrom` Secret into a variable, whatever its name: v1.33.12 and v1.37.0 check
  no name, while v1.29.0 skipped a key outside `[-._a-zA-Z][-._a-zA-Z0-9]*`, one that starts with a digit for example
  (kubelet source reading only). The e2e checks that a key that is no shell identifier (`api-key`) reaches the
  container's environment; v1.29.0 let that key through too, so the e2e does not show the change. Binary content in
  such a variable keeps the container from starting on kubelets 1.34.0-1.34.8, 1.35.0-1.35.5 and 1.36.0-1.36.1
  (kubernetes#139132) and beyond 128 KiB; the container runtime needs its own fix (containerd 2.2.7 and 2.3.4, CRI-O
  1.34.11, 1.35.6 and 1.36.3: affected are containerd 2.2.0-2.2.6 and 2.3.0-2.3.3 and CRI-O 1.34.0-1.34.10,
  1.35.0-1.35.5 and 1.36.0-1.36.2, earlier runtimes were not) (source reading, not run).
- **Helm and `null`**: Helm deletes a key on `null` only when the chart's own `values.yaml` defines it, and Helm 4.3
  drops a `null` of the umbrella's own values while nothing is passed for that alias, while Helm 3.22 keeps it
  (measured on Helm 4.3.0 and 3.22.0). The chart's own `null` defaults reach the templates as present `null` keys (Helm
  3.22 in every layer; Helm 4.3 once a values file or `--set` names the alias) or as absent keys (Helm 4.3 otherwise)
  (measured on Helm 4.3.0 and 3.22.0 by rendering through an umbrella when 0.9.0 was prototyped; the alias contract
  checks that both forms render the same). A `--set` by index on a list (`dataFrom[0].extract.key`), and a helmfile
  `set:` of the same path, depend on where the list comes from: from the chart's own values (an umbrella's
  `values.yaml`) they render a list of that one entry, without the other entries and without entry 0's `rewrite`, and
  no error, while `--set` by index `[1]` fails the schema (`at '/externalSecret/dataFrom/0': got null, want object`);
  from a values file of the same command (`-f`, or a helmfile release's `values:` file) they edit that entry in place
  and keep the rest (measured on Helm 4.3.0 and 3.22.0, and on helmfile 1.8.0).

## Decision

Still one ExternalSecret and one Secret, `<fullname>-secrets`, per component. One helper, `chart-base.externalSecret`
(`templates/_externalsecret.tpl`), computes everything the templates and the guards read of the block:

- **Templated**: `template.data` has a non-null entry; `spec.target.template` is rendered then, and only then.
- **Delivered keys**: the keys the chart can see reach the Secret: the non-null `template.data` keys, and the non-null
  `data` keys unless the block is templated with `mergePolicy: Replace`.
- **Closed key set**: the chart knows every key of the Secret: `dataFrom` is empty, or the block is templated with
  `Replace`. Otherwise the set is open and a key named elsewhere is not checked.
- **Injected**: `enabled` and `envFrom` are both true. **Mounted**: `enabled`, and a container mounts the volume
  `external-secret` (the main container through `mountPath`, or a non-null init container or sidecar through a
  non-null `volumeMounts.external-secret`).

The keys:

- **`data`** maps a Secret key to `{key, property, version, decodingStrategy}`. In `data` a `null` entry, and a `null`
  optional field of an entry (`property`, `version`, `decodingStrategy`), is absent; `key` is required (a `null` key is
  a schema error). `version` is a string (quote a numeric version); `decodingStrategy` is `None`, `Base64` or
  `Base64URL` (no `Auto`: External Secrets itself warns about it).
- **`dataFrom`** is External Secrets' own list, limited to one `extract: {key, property, version,
  conversionStrategy, decodingStrategy}` and an optional `rewrite` list (each item one of `regexp: {source, target}`
  or `transform: {template}`), closed at every level. A list: an overlay replaces it whole, a `null` item or a `null`
  field inside an item is a schema error, and `null` or `[]` is none; an empty `rewrite` is not rendered. The list
  order is the precedence. Not offered: `find`, `sourceRef`, `metadataPolicy` and the fields newer than External
  Secrets 0.16.0.
- **`template`**: `template.data` maps a Secret key to an External Secrets template string; in `template.data` a `null`
  entry is absent. `template.mergePolicy` is `Merge` by default (External Secrets' own default, `Replace`, would remove
  every `data` and `dataFrom` key the day a template key is added). `template` and `template.mergePolicy` are
  `required` (ADR-0027's rule: a `null` would hand the consumer External Secrets' `Replace`). Whenever the template is
  rendered, `mergePolicy` is rendered from the value, with the chart's labels in `template.metadata.labels`; never
  `engineVersion`, `type`, user `metadata` or `templateFrom`.
- **`envFrom`** (required, default `true`): `false` stops injecting the Secret whole; the Secret is then read as files,
  key by key through `env.<NAME>.valueFrom.externalSecretKeyRef` (ADR-0054), or both. The name is a homonym of the
  component's `envFrom` list: it names the mechanism it switches, every message qualifies it with the block, and a
  list there fails the schema (`got array, want boolean`). With an `inheritEnv: true` init container or sidecar, the
  Secret is part of the copied `envFrom` only while it is injected.
- **The file mount**: `mountPath` (absolute, default `null`: the main container does not mount it), `items` (default
  `null`: every key; `[]` fails the schema) and `defaultMode` (default `null`: Kubernetes' 0644), the names and the
  schema definitions of a `secret` entry of `volumes`. The volume `external-secret` (a name 0.7.0 reserved) is rendered
  only while the block is mounted, with `chart-base.volumeSource`; every mount of it is read-only; the main
  container's mount has no `subPath`; the volume has no `optional`. An init container or a sidecar mounts it with
  `volumeMounts.external-secret` (this amends ADR-0051's list of the volumes an entry may mount); `readOnly: false` on
  that mount fails, and its `subPath` names an item of `items`, or, without `items` and with a closed key set, one of
  the keys or `.`.

The guards, each with its remedy (a guard fails `helm template`, install and upgrade, and `helm lint` only reports it,
ADR-0044), run while `enabled` is true, so that an umbrella can keep the block's keys and switch it per environment:

- a source: a non-null `data` entry or a `dataFrom` entry (this widens ADR-0047's source guard); `conversionStrategy`
  next to a non-empty `rewrite`; `mergePolicy: Replace` without a templated key; a `template.data` value without
  `{{` (a constant written into the Secret is plaintext in the values, which ADR-0004 rules out; a heuristic for the
  accidental literal, assuming the default delimiters);
- while injected: a delivered key that is not an environment variable name (`^[A-Za-z_][A-Za-z0-9_]*$`; the schema
  takes any Secret key, `^[-._a-zA-Z0-9]+$`), and, unless the block is templated with `Replace`, `decodingStrategy:
  Base64` or `Base64URL` on a `data` entry or an extract; with `envFrom: false`, nothing that reads the Secret (a
  mount, an `externalSecretKeyRef`, or a hand-written `secretKeyRef` on `<fullname>-secrets`);
- the mount: `mountPath` unique once normalized among the main container's mounts, not `/` and not the ServiceAccount
  token directory (reserved whatever `automountToken` says), and a possible parent of the nested single-file rule;
  `items[].path` relative, without `..`, unique once normalized; with a closed key set, every `items[].key` a delivered
  key (one message, shared with ADR-0054 and with the `subPath` of an entry's mount, with two variants under a
  templated `Replace`: a `data` key, which `Replace` keeps out, and any other key, whose remedy names
  `template.data` only); `items` or `defaultMode` while nothing mounts the Secret.

Two guards look at the block from outside and run while it is disabled: a mount of `external-secret` in an init
container or a sidecar, and an `externalSecretKeyRef` (ADR-0054).

**The precedence chain is the contract.** Inside the Secret: the `dataFrom` entries in list order, then `data`, then
`template.data` (under `Merge`; under a templated `Replace` only the templated keys exist). In the container: the
imported `envFrom` sources, then `config` (`<fullname>-env`), then the Secret, then `env`; each later one wins. This
amends ADR-0032: a key that an extract brings replaces a `config` key of the same name, the chart cannot see it, and
whoever writes the remote secret can set a process-level variable (`HTTPS_PROXY`, `NODE_OPTIONS`,
`JAVA_TOOL_OPTIONS`). The `env` duplicate guard reads the delivered keys while the Secret is injected, and no Secret
key otherwise (the `config` half and its message are unchanged); the `inheritEnv` guard of ADR-0051 reads the same
list.

This amends ADR-0004: "both objects are injected the same way, through `envFrom`" and the `data` shape no longer hold
as written; "secret values never appear in the values contract" still holds, and the constant-template guard defends
it. The Reloader list does not change: `<fullname>-secrets` is listed while the block is enabled (ADR-0033), so a
mounted Secret's rotation restarts a Deployment while `reloadOnChange` is true, although the kubelet updates the files
in place (source reading).

## Consequences

- A JSON secret, a connection string, a configuration file with secrets and a certificate as a file are values, not
  templates of the umbrella; the mixed case (variables and files from one Secret) is `envFrom: false`, `mountPath` and
  one `externalSecretKeyRef` per variable.
- A values file without the new keys renders the same manifests (measured on the six `ci/` scenarios of 0.8.0, the
  shared test values and the README recipes of 0.8.0, on Helm 4.3.0 and 3.22.0; one recipe block, an overlay that
  needs the block before it, renders nothing alone and fails the same way with both charts). Every direct install upgraded with
  `--reuse-values` fails with `missing properties 'envFrom', 'template'`, whether or not it uses `externalSecret`, and
  the upgrade writes no revision (measured with a real upgrade from the published 0.8.0 on kube-apiserver 1.37.0, Helm
  4.3.0 and 3.22.0); `--reset-then-reuse-values` upgrades, and umbrellas are not affected (measured the same way).
- Relaxations: a `data` key that is not an environment variable name is accepted while the Secret is not injected,
  and the `env` duplicate guard no longer fires on the `data` keys of a disabled block or of a templated `Replace`
  block. Schema-only tooling (an IDE) no longer flags `tls.crt` under `envFrom: true`.
- Costs of the list: an overlay restates the whole `dataFrom`, and `--set` by index truncates it silently when the
  list comes from the chart's own values (an umbrella's `values.yaml`), or edits one entry in place when it comes from
  a values file of the same command (measured, see Context); vary a remote key per environment in one templated values
  file (helmfile: `key: "/{{ .Environment.Name }}/sales/db"`).
- Costs of the template: a cluster whose External Secrets runs with other delimiters cannot use `template.data`; an
  edited template changes the ExternalSecret alone (the pod template's checksums cover `config` and `configFiles`), so
  Helm returns without rolling a pod and the change reaches the pods later through Reloader, never for variables
  without Reloader; a template that calls a non-deterministic function (`bcrypt`, `htpasswd`, `randAlphaNum`,
  `randBytes`, `uuidv4`, `now`, `genPrivateKey`) changes the Secret at every `refreshInterval` (source reading). In a
  helmfile `.gotmpl` values file a template is written ``{{ `{{ .password }}` }}`` (measured on helmfile 1.4.4 and
  1.8.0). A text value stored base64-encoded is injected with `template.data.<KEY>: "{{ .<KEY> | b64dec }}"` next to
  `data.<KEY>` (under `Merge` the templated key wins: run with External Secrets' code in a harness).
- Keys that YAML 1.1 reads as a boolean (`on`, `yes`, `no`, `y`, `n`, `off`, lowercase, capitalized or uppercase) are
  renamed `"true"` or `"false"` in `data` and `template.data` when unquoted, and two of them collide silently
  (measured on Helm 4.3.0 and 3.22.0).
- **What is not validated**: the keys an extract produces and whether a remote key exists; template errors, which
  surface only as `SecretSyncedError` and a Warning event on the ExternalSecret; a source that returns nothing
  (External Secrets reports `Ready=True` and creates no Secret: source reading); binary or oversized values behind
  `envFrom`, `b64dec` in a template under an identifier key, and a store that returns binary content without any
  decoding; a key that is `.`, `..` or starts with `..` (the API rejects it when External Secrets writes the Secret:
  `IsConfigMapKey`, source reading at v1.33.12 and v1.37.0); with an open key set, an `items` key or an
  `externalSecretKeyRef` key the Secret lacks (the pod stays in `ContainerCreating`, or the container is not created:
  kubelet source reading); the timing between a sync and a rollout. A failing sync fails a release only under Helm 4
  `--wait`, after the timeout, and only once External Secrets has written `Ready=False` (measured when 0.9.0 was
  designed: Helm 3.22 never waits for an ExternalSecret).
- For 0.12.0: the common labels it adds join `template.metadata.labels`; common annotations are not rendered into the
  template, because External Secrets executes those values as templates.

## Alternatives considered

### `dataFrom` as a map with an `order` field

Precedence would depend on invented names plus a number; External Secrets' documentation would no longer apply as
written. The list's real cost (an overlay restates it) is documented next to the key.

### `find`, `sourceRef` and the whole template now

`find` can return nothing and stay green, and not every provider implements it; `sourceRef` brings a second store or a
generator; `templateFrom`, a Secret `type` (immutable, with keys the chart cannot always see) and user `metadata` widen
what the chart must validate. Each one is additive later.

### `mergePolicy` without a default, or External Secrets' `Replace`

A required key without a default would make every templated component write it; `Replace` as the default silently
removes the variables of an existing component the day a template is added. `Merge` loses nothing.

### A nested `mount` block, `items: []` as every key, and a second mount in the main container

The roadmap names `externalSecret.mountPath`, a flat key next to `configFiles.mountPath`; `[]` reads as "nothing" and
the API reads it as "every key", so only `null` means every key; a second mount waits for a later `mounts` map (today:
subdirectories through `items[].path`).

### The variable-name rule in the schema

The schema message (`invalid propertyName`) names neither `envFrom` nor a remedy, and Helm reports it at an unrelated
path (measured: `at '/prometheusRule/enabled'`).

### `externalSecret.injectEnv` instead of `envFrom`

It pairs with ADR-0051's `inheritEnv`; the name of the Kubernetes mechanism was kept. Renaming the key after 0.9.0 is a
breaking change.

### A checksum annotation for templated content

New pods could start before External Secrets has re-synced the Secret they would read.

## References

- `templates/_externalsecret.tpl` (`chart-base.externalSecret`, `chart-base.notDelivered`), `templates/externalsecret.yaml`,
  `templates/_pod.tpl` (`chart-base.envFrom`, the volume and the main container's mount), `templates/_volumes.tpl`
  (`chart-base.mainMounts`, `chart-base.readOnlyMount`, `chart-base.validateItems`, `chart-base.validateMountPath`),
  `templates/_values.tpl` (`chart-base.chartEnvNames`), `templates/validate.yaml`; `values.yaml` and
  `values.schema.json` (`externalSecret`, `definitions.externalSecretDataFrom`, `definitions.externalSecretDecoding`,
  `definitions.secretKey`).
- `tests/externalsecret_test.yaml`, `tests/externalsecret_guards_test.yaml`, `tests/externalsecret_pod_test.yaml`;
  `.github/scripts/alias-contract.sh`; `.github/scripts/e2e.sh` (the `full`, `job` and `worker` scenarios).
- External Secrets Operator v2.11.0: `pkg/controllers/externalsecret/externalsecret_controller_secret.go`,
  `externalsecret_controller_template.go`, `runtime/template/v2/template.go`, `apis/externalsecrets/v1`.
- [External Secrets: ExternalSecret](https://external-secrets.io/latest/api/externalsecret/),
  [Advanced templating](https://external-secrets.io/latest/guides/templating/), [Rewriting keys](https://external-secrets.io/latest/guides/datafrom-rewrite/).
