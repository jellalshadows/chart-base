# ADR-0070: A `null` means absent, chart-wide

- **Status:** Accepted
- **Date:** 2026-11-19
- **Since:** 1.5.0
- **Related:** [ADR-0045](0045-null-in-configfiles-and-resources-is-absent.md) (amended), [ADR-0049](0049-volumes-are-a-map-of-typed-entries-mounted-in-the-main-container.md) (amended), [ADR-0050](0050-existing-claim-on-a-deployment-and-strategy-rollingupdate-null.md) (amended), [ADR-0051](0051-init-containers-and-sidecars-are-two-maps-in-one-start-order.md) (amended), [ADR-0054](0054-env-externalsecretkeyref-references-the-components-own-secret.md) (amended), [ADR-0055](0055-hpa-behavior-and-metrics-are-validated-pass-throughs.md) (amended), [ADR-0058](0058-the-1-0-contract-and-how-it-stays-frozen.md), [ADR-0059](0059-one-probe-contract-for-every-container.md) (amended), [ADR-0064](0064-from-1-0-0-a-new-key-is-optional.md) (amended), [ADR-0068](0068-schema-checks-on-map-keys-report-the-right-path.md)

## Context

Helm deletes a key set to `null` only when the chart's own `values.yaml` defines it. A `null` on an entry of a map
that `values.yaml` leaves empty (`podLabels: {}`), or on a member of an object that it leaves `null`
(`strategy: null`), reaches the schema, which failed with `got null, want …`. An overlay could not remove what a lower
layer set there.

From 0.7.0 to 0.12.0 the chart made `null` mean absent map by map: `configFiles.files`, `resources`, `volumes`,
`strategy.rollingUpdate`, `initContainers`, `sidecars`, `externalSecret.data` and `template.data`, `keda.triggers`,
`extraObjects` and the main container's probes ([ADR-0045](0045-null-in-configfiles-and-resources-is-absent.md) and
the ADRs that followed it). A chart-wide rule was cut before 1.0. What stayed out:

- the main container's `env.<NAME>`, and a source inside any variable's `valueFrom`. An environment that disables the
  ExternalSecret could not drop an inherited `externalSecretKeyRef` variable, nor switch it to another source
  ([ADR-0054](0054-env-externalsecretkeyref-references-the-components-own-secret.md)): `env.<NAME>: null` and a
  `null` source both failed the schema, and a second source failed the `oneOf`;
- one entry of a typed string map: `config`, the label and annotation maps, `nodeSelector`, the DNS `podSelector`;
- an optional member of a closed object: a `lifecycle` hook, `maxSurge` and `maxUnavailable`, a `dnsConfig` field,
  `ports[].servicePort`, a direction or a field of `autoscaling.behavior` and `keda.behavior`.

1.4.0 added one more case. A `helm upgrade --reuse-values` renders the new chart with the previous release's values,
the old chart's defaults included. A key that a release added after 1.0.0 is missing from those defaults, so Helm
keeps a `null` that an override sets on it: `autoscaling.kedaHandover: null` from 1.0.x, and `grpcRoute: null`,
`grpcRoute.enabled: null` or `httpRoute.rules: null` from 1.3.x or older, failed the schema (measured on Helm 4.3.0 and
3.22.0). [ADR-0064](0064-from-1-0-0-a-new-key-is-optional.md) makes such a key optional, but did not make its `null`
valid.

## Decision

- **The rule.** A `null` that fails the schema on 1.4.0, set on a map entry or on an optional member of a closed
  object, is absent: the key's default, or nothing. In 1.5.0 it covers:
  - **`env`:** the main container's `env.<NAME>: null`, as an entry's already was. Inside any variable's `valueFrom`
    (the main container's and every entry's, one shared definition) a `null` source is absent, so an overlay switches
    a variable to another source by setting the inherited one to `null` next to the new one. A `null` optional field of
    a source (`secretKeyRef.optional`, `fieldRef.apiVersion`, `resourceFieldRef.containerName` and `divisor`) is absent.
  - **Typed string maps:** a `null` key of `config`, `podLabels`, `podAnnotations`, `commonLabels`,
    `commonAnnotations`, `metrics.labels`, `prometheusRule.labels`, `service.annotations`, `ingress.annotations`,
    `serviceAccount.annotations`, `nodeSelector` and `networkPolicy.egress.dns.podSelector` is absent from that map.
    A `commonLabels` or `commonAnnotations` value for the same key then applies, as it does for an extra object's
    metadata ([ADR-0057](0057-common-labels-and-annotations-service-annotations-and-extraobjects.md)).
  - **Optional members of closed objects:** `lifecycle.postStart` and `preStop`, a hook's handler next to another one,
    a hook's `httpGet.path`, `scheme` and `httpHeaders`; `strategy.rollingUpdate.maxSurge` and `maxUnavailable`;
    `dnsConfig.nameservers`, `searches` and `options`; `ports[].servicePort` (the `containerPort`); a direction of
    `autoscaling.behavior` and `keda.behavior`, and a direction's `stabilizationWindowSeconds`, `selectPolicy` and
    `policies`.
  - **Keys added after 1.0.0:** `autoscaling.kedaHandover`, `grpcRoute`, `grpcRoute.enabled`, `grpcRoute.parentRefs`,
    `grpcRoute.hostnames` and `httpRoute.rules` take `null` as their default (`false`, no GRPCRoute, none). A key a
    later minor adds takes `null` the same way.
- **Additive only.** Every value that renders on 1.4.0 renders the same manifest, and a value that 1.4.0 rejects for a
  reason other than such a `null` is still rejected, with the same message. One message changes, because its remedy
  became wrong: `externalSecretKeyRef` with the ExternalSecret disabled now ends `(an overlay removes it with
  env.<NAME>: null)` for the main container, as it already could for an entry.
- **In the schema, a nullable member keeps its message.** Each such value is
  `{"if": {"not": {"type": "null"}}, "then": <the 1.4.0 schema>}`. A non-null value is checked by the 1.4.0 schema and
  fails with the 1.4.0 message, on Helm 4.3.0 and 3.22.0 alike (measured). `"type": ["string", "null"]` would print
  `want null or string` for every wrong value. `contract-keys.sh` walks `then`, so the key list is unchanged (689 keys).
- **Exactly one non-null member where Kubernetes takes one.** Each `oneOf` branch of a `valueFrom` and of a hook
  requires its member and that it is not `null`. A `null` member next to a real one is absent; `valueFrom: null`, a
  `valueFrom` or a hook whose every member is `null`, and two real members still fail (`'oneOf' failed`).
- **The templates read a pruned copy, and so does every guard.** Each value is read through `chart-base.pruneNulls` on a
  deep copy ([ADR-0045](0045-null-in-configfiles-and-resources-is-absent.md)), at one place per value:
  - `chart-base.env` prunes the variables it renders, for the main container, each entry and `inheritEnv`;
  - `chart-base.mainEnv` gives the guards and the Reloader annotations the same pruned main `env`: the literal check,
    the duplicate names, `inheritEnv`'s checks and the detection of an `externalSecretKeyRef`;
  - `chart-base.overCommon` prunes a labels or annotations map and the common map under it;
  - `chart-base.hasConfig` and the ConfigMap read a pruned `config`; the hooks, the strategy, `dnsConfig`, the HPA's
    and the ScaledObject's `behavior`, `nodeSelector`, the ServiceAccount's annotations and the DNS `podSelector` are
    pruned where they are read.

  A guard never counts a `null` as set. A `null` `maxSurge` is "not set" in the single-pod claim rule
  ([ADR-0050](0050-existing-claim-on-a-deployment-and-strategy-rollingupdate-null.md)). `lifecycle.preStop: null` is
  no hook next to the built-in preStop sleep.
- **Rulings for the edge cases:**
  - A reserved key of a label or annotation map set to `null` still fails (`false schema`, at the key's own path,
    [ADR-0068](0068-schema-checks-on-map-keys-report-the-right-path.md)). A false schema rejects every value, and an
    extra object's metadata already rejects it the same way.
  - A `config` whose every key is `null` renders no ConfigMap, no `envFrom` entry and no checksum, as `config: {}`.
  - A DNS `podSelector` whose every key is `null` selects the default `{k8s-app: kube-dns}`, as `podSelector: null`.
  - A `dnsConfig` whose every field is `null` is not rendered.
  - A `behavior` whose every direction is `null` is not rendered. A direction whose every field is `null` renders
    `{}`, which the API server fills with its defaults, the same as a direction left out. The schema's
    `minProperties` still rejects a `behavior` or a direction written as `{}`.
  - A `rollingUpdate` left empty by its `null`s next to `Recreate` still fails the guard: Kubernetes rejects an empty
    one.
  - A required field stays required: `valueFrom`, a `secretKeyRef` or `configMapKeyRef` `key`, a hook's `httpGet.port`,
    `exec.command` and `sleep.seconds`, a `dnsConfig` option's `name`, `resources.requests.cpu` and `.memory`.
  - A key this decision does not list keeps its 1.4.0 rule, for example `strategy.type: null` (a schema error).

## Consequences

- One rule to remember: an overlay removes an entry, or an optional member, by setting it to `null`. What stays an
  error is named: a required field, a `null` inside a list, and the pass-through objects below.
- The gap of [ADR-0054](0054-env-externalsecretkeyref-references-the-components-own-secret.md) closes. An environment
  that disables the ExternalSecret removes an inherited `externalSecretKeyRef` variable with `env.<NAME>: null`, or
  switches it with `externalSecretKeyRef: null` next to another source.
- A `--reuse-values` upgrade from 1.0.x to 1.3.x renders with a `null` on a key added after 1.0.0. helm-unittest cannot
  build that shape: the chart's own `values.yaml` defines every key, and Helm deletes a `null` on it. The release
  measures it by rendering the new chart with an old release's `values.yaml` as its defaults, on both Helm versions,
  as [ADR-0064](0064-from-1-0-0-a-new-key-is-optional.md) asks.
- Helm 4.3 keeps one exception, its own. It drops a `null` written in an umbrella's own values while nothing is passed
  for the alias, before the schema runs
  ([consuming guide](../guides/consuming.md#what-a-null-does-in-each-values-layer)). The key is then missing. For an
  entry or an optional member the result is the same. A `behavior` left empty fails `minProperties`, a required field
  fails `missing property`, and a reserved key is simply absent (measured in an umbrella on Helm 4.3.0 and 3.22.0).
- The schema reads less directly: a nullable member is an `if`/`then` pair. Its description says what `null` means.
- Out, because each would be breaking:
  - **Pruning a pass-through object** (`securityContext`, `podSecurityContext`, `affinity`): a `null` key there renders
    as `null` today, so pruning it changes the manifest of a value that renders.
  - **A `null` inside a list** (`tolerations: [null]`, an `options` item's `value`, a behavior policy's field): an
    overlay replaces a list whole, so a `null` there removes nothing, and it stays a schema error.
  - **A `null` on a required key** (`resources.requests.cpu`): it stays an error, so a value cannot silently lose a
    request.

## Alternatives considered

### `null` added to each member's `type`

Shorter, but it changes the message of every wrong non-null value (`got integer, want null or string`), on values that
have nothing to do with `null`. The `if`/`then` pair keeps those messages byte for byte.

### Pruning the whole values tree once

One prune at the root would also reach the pass-through objects, whose `null` keys render today, and every guard reads
`.Values` directly. It is breaking, and it moves the pruning point away from each reader.

### Keeping the per-map rules

Each map would keep its own answer, and the main container's `env` would stay the one map an overlay cannot reduce.
