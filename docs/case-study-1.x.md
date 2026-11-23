# From 1.0 to 1.6.1 without breaking the contract

chart-base 1.0.0 froze a contract: the object names, the selector labels, the label and annotation keys the chart
writes, and every values key. Eight releases followed, six minors and two patches. The [upgrade guide](upgrading.md)
lists no values change for any of them, no 1.x pull request carries a breaking title, and the frozen key list grew from
649 to 698 keys without losing one. CI enforces the rule on every pull request, and the first real consumer moved to
1.6.1 with no change that a 1.x release asked for.

## The promise

[ADR-0058](adr/0058-the-1-0-contract-and-how-it-stays-frozen.md) lists what 1.0 freezes:

- the selector labels `app.kubernetes.io/name: <alias>` and `app.kubernetes.io/instance: <release>`, exactly these two;
- the object names (`<release>-<alias>` and its suffixes), the main container's name and the chart's volume names;
- the label and annotation keys the chart writes;
- every values key name, as listed in [`tests/contract/keys.txt`](../tests/contract/keys.txt).

Error messages, the order of keys in a manifest, comments and documentation are not frozen.

The rule for 1.x follows from that list. A key is never removed or renamed. A new key is optional, never `required`
([ADR-0064](adr/0064-from-1-0-0-a-new-key-is-optional.md)). A default that changes the manifest of an unchanged values
file is a major, and so is a check that rejects values that render. In the 1.x line, every value that renders on the
previous release renders the same manifest, but for the version in the `helm.sh/chart` label: a release may accept
more, never less.

The `required` rule comes from the 0.x line. 0.3.0, 0.4.0, 0.5.0, 0.6.0 and 0.9.0 each added a required key, and each
broke a direct install upgraded with `helm upgrade --reuse-values`: Helm renders the new chart with the previous
release's defaults, which lack the key
([upgrade guide](upgrading.md#every-upgrade-a-direct-install-must-not-use---reuse-values)). Before 1.0 that was a
documented breaking change. From 1.0 it would break the promise.

## How CI enforces it

| Layer | Where | What it compares | Runs in |
|---|---|---|---|
| Contract suite | [`tests/contract_test.yaml`](../tests/contract_test.yaml) | The object names, the selectors, the main container's and the volumes' names, and the label and annotation keys, on the four workload types | `unit tests` job |
| Key list | [`contract-keys.sh`](../.github/scripts/contract-keys.sh) | Every key path a values file can set, read from `values.schema.json` through every `$ref`, `allOf`, `anyOf`, `oneOf`, `then` and `else`, against the committed `keys.txt`. A key that is gone fails; a key that is not listed fails until the list is committed with it | `lint` job, Helm 3.22.0 and 4.3.0 |
| Base check | `contract-keys.sh --base` | `keys.txt` against the same file at the pull request's base commit. A lost line fails unless the title is breaking (`type!:`), so a pull request cannot pass by rewriting the list it is compared with | `lint` job, every pull request |
| Alias contract | [`alias-contract.sh`](../.github/scripts/alias-contract.sh) | Throwaway umbrellas with several aliases: names, selectors, the schema per alias, and what a `null` does in each of four values layers | `lint` job, Helm 3.22.0 and 4.3.0 |
| R layer (`--reuse-values`, from 1.6.1) | `alias-contract.sh` | Every `ci/` scenario rendered with the `values.yaml` of v1.0.0 and of the previous release as defaults (the `--reuse-values` shape), against the render with the chart's own defaults; and each key added since 1.0.0 that has a default, set to `null`, against the key absent. Output, sorted errors and exit code must match | `lint` job, Helm 3.22.0 and 4.3.0 |
| Lifecycle on kind | [`umbrella-lifecycle.sh`](../.github/scripts/umbrella-lifecycle.sh) | Install, values change, rollback and uninstall of an umbrella; every object of the first revision keeps its uid and its selector | `e2e` job, Kubernetes 1.33 and 1.37 |

The R layer reads its keys from the files: the lines of `keys.txt` gained since v1.0.0 that are paths of `values.yaml`.
No list is kept in the script, so a key added in a later minor is checked without an edit. The
[testing guide](guides/testing.md#the-alias-contract) describes every check.

The key list cannot see a type change or a narrower rule. Those fall to the schema tests and to the evidence of each
pull request. From 1.3.1 on, each change records a differential render against the previous release: in
[#42](https://github.com/jellalshadows/chart-base/pull/42), the seven `ci/` scenarios on Helm 4.3.0 and 3.22.0, 14
renders and 0 differences.

## Six minor releases and two patches

| Release | Change | How it stayed compatible |
|---|---|---|
| [1.1.0](https://github.com/jellalshadows/chart-base/pull/34) | `autoscaling.kedaHandover`, an opt-in handover from the chart's HPA to KEDA ([ADR-0065](adr/0065-an-opt-in-handover-from-the-chart-s-hpa-to-keda.md)) | One optional key, `false` by default; no manifest changes unless it is `true`. This release wrote the rule of ADR-0064 |
| [1.2.0](https://github.com/jellalshadows/chart-base/pull/36) | `config` on an init container or a sidecar, for literal variables ([ADR-0066](adr/0066-an-entry-level-config-for-literal-variables.md)) | An optional key; no manifest changes unless an entry sets it |
| [1.3.0](https://github.com/jellalshadows/chart-base/pull/38) | `volumes.<name>.reloadOnChange`, a per-volume Reloader opt-out ([ADR-0067](adr/0067-a-per-volume-reloader-opt-out.md)) | An optional key; no manifest changes unless it is `false` |
| [1.3.1](https://github.com/jellalshadows/chart-base/pull/40) | Schema errors on map keys at the right path, and one message for a sidecar's metrics port ([ADR-0068](adr/0068-schema-checks-on-map-keys-report-the-right-path.md)) | Only messages change, and messages are not frozen. The accepted set of every changed map matched 1.3.0's: 1,693 probes, 6,772 renders, no difference |
| [1.4.0](https://github.com/jellalshadows/chart-base/pull/42) | A GRPCRoute, extra HTTPRoute rules and `ports[].appProtocol` ([ADR-0069](adr/0069-grpcroute-httproute-rules-and-appprotocol.md)) | Three optional keys. The plan cut before 1.0 replaced `httpRoute.matches`; a frozen key cannot be replaced, so the new rules come after the existing one |
| [1.5.0](https://github.com/jellalshadows/chart-base/pull/44) | A `null` means absent, chart-wide ([ADR-0070](adr/0070-a-null-means-absent-chart-wide.md)) | No key added. It accepts `null`s that 1.4.0 rejected; a non-null value is checked by the 1.4.0 schema, and an invalid one fails with the 1.4.0 message |
| [1.6.0](https://github.com/jellalshadows/chart-base/pull/46) | `workload.type: statefulset`, with a claim per pod ([ADR-0071](adr/0071-a-statefulset-workload-type-with-a-claim-per-pod.md)) | A new enum value and an optional block. The Deployment, CronJob and Job output is identical to 1.5.0's; two schema messages list the new values |
| [1.6.1](https://github.com/jellalshadows/chart-base/pull/48) | Two guards accept values that their workload type ignores; the R layer joins CI | It accepts more and rejects nothing new. Rejecting `strategy` on a type that ignores it waits for a major |

## What the checks caught

### 1.3.1: the key list reported 58 removals that were not removals

**Problem.** 1.3.1 replaced `propertyNames` in the schema with false schemas and `patternProperties`, so that Helm's
schema library reports an error on a map key at the right path. The accepted values did not change. The 1.3.0
`contract-keys.sh` read a false schema as a key and skipped `patternProperties`.

**How it was found.** By the key compare itself. Run on the 1.3.1 schema, the 1.3.0 script fails with 58 keys gone,
every `env.<name>.valueFrom` path among them, and 44 new ones, such as `prometheusRule.labels.helm.sh/chart`: reserved
keys that the schema forbids, listed as if a values file could set them.

**Fix.** The walker reads a `patternProperties` entry as a map entry (`<name>`) and skips a false schema. It lists the
same 653 keys from the 1.3.0 and the 1.3.1 schema
([#40](https://github.com/jellalshadows/chart-base/pull/40)). The list was not regenerated to make the check pass.

### 1.4.0: a `null` on a new key failed a `--reuse-values` upgrade

**Problem.** Helm deletes a key set to `null` only when the chart's own `values.yaml` defines it. A `--reuse-values`
upgrade renders the new chart with the previous release's defaults, which lack a key added since. A `null` that an
override sets on that key reaches the schema: `autoscaling.kedaHandover: null` over the 1.0.x defaults, and
`grpcRoute: null` over the 1.3.x defaults, failed with `got null, want …`. ADR-0064 had made new keys optional, but not
their `null`.

**How it was found.** The pre-merge verification of 1.4.0 rendered the `--reuse-values` shape and recorded it
([#42](https://github.com/jellalshadows/chart-base/pull/42)), with `kedaHandover` showing the same gap since 1.1.0.

**Fix.** 1.5.0 makes every key added after 1.0.0 take `null` as its default
([#44](https://github.com/jellalshadows/chart-base/pull/44), ADR-0070). That shape was still checked by hand, so 1.6.1
put it in CI as the R layer ([#48](https://github.com/jellalshadows/chart-base/pull/48)). Run against the 1.4.0 chart,
the layer fails on 42 combinations; over the v1.0.0 defaults the schema answers
`at '/autoscaling/kedaHandover': got null, want boolean`.

### 1.6.0: a label on a claim template would have failed later upgrades

**Problem.** The first version of the `volumeClaimTemplate` volume type gave the StatefulSet's claim template the
chart's labels, `commonLabels` included, as an `ephemeral` claim has, with a caveat in the upgrade guide. The API
server refuses any change to a StatefulSet's claim templates, labels included. A routine `commonLabels` change would
have failed every upgrade that made it.

**How it was found.** In review, before the pull request was merged.

**Fix.** A claim template carries the two frozen selector labels only, which never change
([commit `f493653`](https://github.com/jellalshadows/chart-base/commit/f49365376a949704671e25ffd9e551649e4405ec) in
[#46](https://github.com/jellalshadows/chart-base/pull/46); ADR-0071). It is the one labels map that `commonLabels`
does not reach. The verification of #46 rendered 20 routine changes, the chart version and the namespace among them,
and the claim templates stayed byte-identical.

### 1.6.1: the R layer compared a release with itself

**Problem.** The R layer finds the previous release with `git describe`. On the tagged release commit, that returned
the release itself, so the previous-release pass compared the chart with its own `values.yaml`: it passed without
checking the upgrade from the release before. Second, Helm lists several schema errors in no fixed order, so two
renders of the same failing value could compare unequal: 12 renders gave 8 distinct outputs.

**How it was found.** In the review of [#48](https://github.com/jellalshadows/chart-base/pull/48).

**Fix.** On a release commit the layer describes from the tag's parent, and it sorts the errors before it compares them
([#50](https://github.com/jellalshadows/chart-base/pull/50)). On the v1.6.1 commit the pass line went from
`v1.0.0 and v1.6.1` to `v1.0.0 and v1.6.0`, and the 12 renders gave one output.

## A real consumer upgrades

[domain-boutique](https://github.com/jellalshadows/domain-boutique) deploys Online Boutique as one umbrella of 13
chart-base aliases, 12 Deployments and a smoke Job, with helmfile. It validated criterion 2 of chart-base's 1.0
roadmap on 0.11.0 and recorded eight gaps in its
[findings](https://github.com/jellalshadows/domain-boutique/blob/main/docs/findings.md#status-at-chart-base-161).
[Pull request #2](https://github.com/jellalshadows/domain-boutique/pull/2) moved it from 0.11.0 to 1.6.1:

- **One upgrade-guide item applied, from 0.12.0**, the breaking release before 1.0: the chart no longer writes
  `app.kubernetes.io/component` ([ADR-0063](adr/0063-the-chart-does-not-write-app-kubernetes-io-component.md)), a
  label on every pod template, so the 12 Deployments rolled once. Nothing selected on it. No item of a 1.x release
  applied.
- **It adopted the fix of its own gap G4.** 1.2.0's entry-level `config` gives the init container `frontend-check` its
  literal `FRONTEND_ADDR`, in place of `inheritEnv: true`
  ([ADR-0004](https://github.com/jellalshadows/domain-boutique/blob/main/docs/adr/0004-twelve-hardened-deployments.md)).
- **Besides those two, the render changed only in the `helm.sh/chart` label.** CI passed: `helm lint --strict` on
  Helm 3.22.0 and 4.3.0, kubeconform with 76 of 76 objects valid on Kubernetes 1.33.12 and 1.37.0, and
  `helmfile -e ci sync` on kind with Kubernetes 1.33 and 1.37, where the e2e places an order through the frontend
  ([run 45082515539](https://github.com/jellalshadows/domain-boutique/actions/runs/45082515539)).

One consumer is a small sample, and it went from 0.11.0 straight to 1.6.1. It shows that the 1.x line asked nothing of
a 13-alias umbrella. It does not prove the same for every values file; the CI layers above are there for that.

## Lessons

1. **Write the contract as data a script can diff.** Up to 0.11.0, "every key is public API" was a habit. `keys.txt`
   turns a removed key into a failing line in the pull request that removes it, not in a consumer's upgrade.
2. **Make the list append-only by construction.** `--add` writes a union, and the base check fails a lost line unless
   the title is breaking. A pull request cannot pass by editing the list it is checked against.
3. **Test the upgrade your users run, not only the install.** `--reuse-values` renders with the old defaults, and that
   is where a new required key or a `null` on a new key breaks. A shape measured by hand in each release belongs in CI.
4. **Check the checker.** Two of the four cases above were defects in the checks. Each fix came with a proof: the same
   653 keys from both schemas, and the compared releases printed on the pass line. A new check gets a negative control
   that must fail: the R layer fails against the 1.4.0 chart.
5. **Let the contract shape the design.** 1.4.0 added rules after a frozen key instead of replacing it, and 1.6.1
   listed a stricter guard under [Waits for a major](roadmap.md#waits-for-a-major) instead of shipping it in a patch.
