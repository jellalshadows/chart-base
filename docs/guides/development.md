# Development guide

This guide is for contributors: what to install, how the repository is laid out, the test-first loop,
how to change the values contract, the pitfalls that have already cost time, and how to commit and open a
pull request. The layers of tests are described in the [testing guide](testing.md).

Contents:

- [Tools and versions](#tools-and-versions)
- [Repository layout](#repository-layout)
- [The TDD loop](#the-tdd-loop)
- [Changing the values contract](#changing-the-values-contract)
- [Pitfalls](#pitfalls)
- [Commits and pull requests](#commits-and-pull-requests)

## Tools and versions

The versions CI uses are declared as `*_VERSION` variables at the top of
[`.github/workflows/ci.yaml`](../../.github/workflows/ci.yaml), which is the source of truth (Renovate
keeps them current, see [ADR-0024](../adr/0024-renovate.md)). At the time of writing:

| Tool | Version | Used for |
|---|---|---|
| Helm | 4.3.0 (CI also runs 3.22.0 in the `lint` job) | Rendering, linting, packaging ([ADR-0019](../adr/0019-helm-4-first-helm-3-tested.md)) |
| helm-unittest plugin | 1.1.2 | Unit tests and snapshots |
| helm-docs | 1.14.2 | Generating `README.md` |
| kubeconform | 0.8.0 | Validating rendered manifests |
| lychee | 0.24.2 | Checking Markdown links |
| actionlint | 1.7.12 | Linting workflows |
| yq (mikefarah, v4) | any v4 | Required by `alias-contract.sh` and `release-signing.sh` |
| cosign | 3.1.3 (`COSIGN_VERSION` in `release.yaml`) | Required by `release-signing.sh` |
| jq | any 1.x | Required by `release-signing.sh` |

**No Docker is needed locally.** The unit tests, lint, kubeconform, the alias contract and the
documentation checks run with plain binaries. Only the end-to-end test needs Docker (it runs kind), and
it runs in CI ([testing guide](testing.md#end-to-end-on-kind)).

Tool setup, without touching your global Helm configuration:

```bash
# Put the standalone binaries (helm-docs, kubeconform, lychee, actionlint, yq, cosign, jq) in a directory on PATH.
mkdir -p "$HOME/.local/bin"
export PATH="$HOME/.local/bin:$PATH"

# Keep the Helm plugin in its own directory instead of Helm's default plugin directory.
export HELM_PLUGINS=<dir>          # any directory you own, for example one under $HOME
mkdir -p "$HELM_PLUGINS"
helm plugin install https://github.com/helm-unittest/helm-unittest.git --version v1.1.2 --verify=false
```

- `HELM_PLUGINS` makes Helm look for (and install) plugins in `<dir>`, so this project's plugin does
  not mix with the ones you already have. Export it in every shell where you run the tests.
- `--verify=false` is what CI does on Helm 4: a plugin installed from a Git source cannot be verified
  there, and the plugin's own install hook verifies the binary it downloads against the release checksum
  file. Helm 3 does not know the `--verify` flag: drop it there.
- helm-unittest ships its own Helm engine, so the unit tests do not depend on your local Helm 3 or 4;
  the `lint` job in CI is what exercises real Helm 3.22 and 4.3 binaries.
- Download the standalone tools from the releases page of each project, at the versions of the table
  above, and check their checksums like the `ci.yaml` install steps do.

## Repository layout

Everything at the top level of the repository, and why it is there:

| Path | What it is |
|---|---|
| `Chart.yaml` | The chart's metadata. The repository **is** the chart ([ADR-0002](../adr/0002-repository-is-the-chart.md)). `version` and the version in the README quick start are edited by release-please, not by hand. |
| `values.yaml` | The defaults and the public contract. Its `# --` comments become the values table of the README. |
| `values.schema.json` | The strict draft-07 schema, written by hand ([ADR-0011](../adr/0011-strict-draft-07-schema.md)). |
| `templates/` | The Kubernetes objects and helpers, described below. |
| `tests/` | The helm-unittest suites (`*_test.yaml`), the shared values files in `tests/values/`, and the snapshots in `tests/__snapshot__/`. |
| `ci/` | One values file per scenario (`deployment`, `worker`, `cronjob`, `job`, `full`, `port-names`), used by lint, kubeconform, snapshots and the e2e. |
| `README.md.gotmpl`, `README.md` | The README template (prose) and the **generated** README. Edit the template and `values.yaml`, never `README.md` ([ADR-0025](../adr/0025-generated-english-readme.md)). |
| `CHANGELOG.md` | Written by release-please. Do not edit it. |
| `LICENSE` | Apache-2.0. |
| `docs/` | This documentation: ADRs, roadmap, guides and runbooks. Not part of the package, and never triggers a release ([ADR-0000](../adr/0000-record-architecture-decisions.md)). |
| `.github/workflows/ci.yaml` | The checks that run on every pull request. |
| `.github/workflows/release.yaml` | Release and publishing ([ADR-0020](../adr/0020-release-please-and-publish-in-one-workflow.md)). |
| `.github/scripts/` | `validate-manifests.sh`, `alias-contract.sh`, `release-signing.sh` and `e2e.sh`, called by `ci.yaml`. |
| `.github/renovate.json` | Renovate configuration ([ADR-0024](../adr/0024-renovate.md)). |
| `release-please-config.json`, `.release-please-manifest.json` | release-please configuration and current version. |
| `.helmignore` | What `helm package` leaves out of the published archive: tests, CI files, `docs/`, the README template and the release tooling. |
| `.gitattributes` | `* text=auto eol=lf`: LF line endings everywhere (see [Pitfalls](#pitfalls)). |
| `.gitignore` | Ignores `helm package` output (`dist/`, `*.tgz`). |

### `templates/`

The object templates are one file per kind (`deployment.yaml`, `cronjob.yaml`, `job.yaml`,
`service.yaml`, `serviceaccount.yaml`, `configmap-env.yaml`, `configmap-files.yaml`,
`externalsecret.yaml`, `httproute.yaml`, `ingress.yaml`, `hpa.yaml`, `pdb.yaml`, `servicemonitor.yaml`,
`podmonitor.yaml`, `prometheusrule.yaml`, `networkpolicy.yaml`, `role.yaml`, `rolebinding.yaml`). The helpers are
split by
responsibility so that each one can be developed and tested on its own:

| File | Responsibility |
|---|---|
| `_names.tpl` | The component name (the alias), `<release>-<component>` and the `fail` helper that prefixes errors with the component. |
| `_labels.tpl` | Selector labels (frozen from 1.0.0), the labels shared by pods and objects, and `helm.sh/chart`. |
| `_pod.tpl` | The image reference (an image map), the pods' ServiceAccount name (the chart's, an existing one, or `default`), the renderers of every container's `env` (`chart-base.env`) and of the main container's `envFrom` (`chart-base.envFrom`), and the pod spec shared by Deployment, CronJob and Job. |
| `_containers.tpl` | Init containers and sidecars: `chart-base.containers` (the one accessor: the non-null entries without their null fields, in start order, each with its merged security context), `chart-base.hardenedSecurityContext` (the default every entry starts from), `chart-base.entryContainer` (one container) and `chart-base.hasSidecars` (the predicate of the batch guard and the HPA) ([ADR-0051](../adr/0051-init-containers-and-sidecars-are-two-maps-in-one-start-order.md)). |
| `_autoscaling.tpl` | `chart-base.utilizationMetric`: one built-in target of the HPA, `Resource` or `ContainerResource` of the main container ([ADR-0052](../adr/0052-hpa-targets-measure-the-main-container-with-sidecars.md)). |
| `_reloader.tpl` | The Reloader annotations for objects that change outside the deploy: the ExternalSecret's Secret and every Secret or ConfigMap referenced in `env` or `envFrom` (the main container's, and the `env` of init containers and sidecars) or mounted by `volumes` ([ADR-0033](../adr/0033-component-level-reload-on-change.md), [ADR-0049](../adr/0049-volumes-are-a-map-of-typed-entries-mounted-in-the-main-container.md)). |
| `_service.tpl` | The port a Service exposes for a `ports` entry. |
| `_metrics.tpl` | The single scrape endpoint of the ServiceMonitor and the PodMonitor ([ADR-0038](../adr/0038-one-metrics-endpoint-servicemonitor-or-podmonitor.md)). |
| `_hooks.tpl` | The Helm hook annotations of `workload.type: job` and of its support resources ([ADR-0007](../adr/0007-jobs-as-helm-hooks.md)). |
| `_networkpolicy.tpl` | The peers of the NetworkPolicy: a sibling component of the release by alias, and namespaces by name ([ADR-0040](../adr/0040-networkpolicy-per-component-with-sibling-references.md)). |
| `_rbac.tpl` | A RoleBinding of the component, for the pods' ServiceAccount in the release namespace ([ADR-0042](../adr/0042-existing-serviceaccount-and-namespaced-rbac.md)). |
| `_values.tpl` | Helpers that read values for templates and guards: `chart-base.pruneNulls`, `chart-base.hasConfigFiles`, `chart-base.chartEnvNames` (the variables the main container receives from the chart), `chart-base.cleanPath` and `chart-base.validateProbePorts` (per container, with where else a name is declared) ([ADR-0045](../adr/0045-null-in-configfiles-and-resources-is-absent.md), [ADR-0046](../adr/0046-configfiles-mountpath-compared-normalized-rendered-as-written.md), [ADR-0047](../adr/0047-when-enabled-keys-required-externalsecret-source-probe-port-names.md), [ADR-0051](../adr/0051-init-containers-and-sidecars-are-two-maps-in-one-start-order.md)). |
| `_volumes.tpl` | The extra volumes: `chart-base.volumes` (the one accessor: the non-null entries without their null fields), `chart-base.volumeSource` (a volume's source, field by field), `chart-base.volumeTypeFields` (the fields of each type, for the ownership guard), `chart-base.mainMounts` (every mount the main container renders, for the path guards) and `chart-base.readOnlyMount` (the volumes every mount of which is read-only: forced by the kubelet, or by the chart for a claim declared `ReadOnlyMany`) ([ADR-0049](../adr/0049-volumes-are-a-map-of-typed-entries-mounted-in-the-main-container.md)). |

`templates/validate.yaml` renders nothing. It holds the guards, `fail` calls for the rules the schema
cannot express: the alias and resource-name format and length, the Kubernetes 1.33 floor, and rules that
span several keys. It is the reason a bad name or a bad combination of values stops the release at
render time ([ADR-0008](../adr/0008-names-are-release-alias-and-never-truncated.md),
[ADR-0018](../adr/0018-kubernetes-version-floor.md)).

Named templates in Helm are global across all charts of a release. Only the values are chart-base's public
contract: do not `include` a helper of chart-base from another chart.

## The TDD loop

No template exists without a test that failed first.

1. Write or extend the suite in `tests/<name>_test.yaml`, with the assertion for the behavior you want.
2. Run it and watch it fail **for the right reason**:

   ```bash
   helm unittest --strict .
   ```

3. Write the template change until the suite passes.
4. Refactor with the suite green.
5. Run the whole set before pushing: `helm unittest --strict .`, then
   `helm lint --strict . -f ci/full-values.yaml` (CI lints every `ci/*-values.yaml`).

CI runs `helm unittest --strict .` (the plugin's help describes the flag as "strict parse the
testsuites"), so run the same command locally.

Snapshots (`tests/snapshot_test.yaml`, stored in `tests/__snapshot__/`) record the rendered manifests of
every `ci/` scenario. When you change a template on purpose:

```bash
helm unittest --strict -u .        # rewrites the snapshots
git diff tests/__snapshot__/       # read it: it must contain exactly the change you intended
```

Use `-u` only after an **intended** change, and always review the snapshot diff: it is what shows the
consumers of the chart, in the pull request, how their manifests change. Running `-u` to make a red test
green without reading the diff defeats the purpose of the snapshots.

## Changing the values contract

The contract is `values.yaml` together with `values.schema.json`, and every key is public API. To add
or change a key:

1. **Test first** (see above), including the negative cases: the values that must be rejected.
2. **`values.yaml`**: add the key with its default and a `# --` comment on the line above. helm-docs
   turns that comment into the row of the values table, so write it for a consumer. Renaming or removing a
   key, or changing a default, is a breaking change.
3. **`values.schema.json`**: describe the key, with `additionalProperties: false` on every object of a
   fixed shape, so that a typo fails instead of being ignored
   ([ADR-0011](../adr/0011-strict-draft-07-schema.md)).
4. **`required`** for any key the templates rely on whose default is not `null`. Helm deletes a key set to
   `null`, and the schema never sees the deleted key, so without `required` a `null` silently flips
   the default (for example `serviceAccount.automountToken: null` would mount the token)
   ([ADR-0027](../adr/0027-required-keys-in-the-schema.md)). Keys whose default is `null` stay optional.
5. **A guard in `templates/validate.yaml`** when the rule spans several keys or needs the release or the
   cluster version, which a schema cannot express (for example `autoscaling.minReplicas` against
   `maxReplicas`).
6. **Regenerate the README** and commit it with the change:

   ```bash
   helm-docs --chart-search-root . --template-files README.md.gotmpl
   ```

   CI runs the same command and fails on any difference in `README.md`.
7. Add the key to a `ci/` scenario when it needs an end-to-end check, and update the documentation in
   the same pull request (see [the definition of done](testing.md#definition-of-done-for-a-feature)).

## Pitfalls

Each of these has already broken something. The reason is the important part.

- **CRLF line endings change checksums and break snapshots.** On Windows, Git can convert files to CRLF
  (`core.autocrlf=true`). A CRLF template renders different text, which produces a different
  `checksum/config-*` annotation, so snapshots that pass locally fail on the Linux runners of CI.
  `.gitattributes` (`* text=auto eol=lf`) forces LF, and you should keep your editor on LF too.
- **Numbers from values files are `float64`.** Helm reads a number from a values file as a float, and
  `toString` turns `10000000` into `"1e+07"`. That is why the ConfigMap templates render non-string
  values with `toJson`, and why `ttlSecondsAfterFinished` and `activeDeadlineSeconds` go through `int64`. The
  suites therefore load `tests/values/large-numbers.yaml` as a values file, the way an umbrella feeds
  chart-base, instead of setting these numbers inline.
- **`quote` versus `toJson` for file contents.** `config` renders strings with `quote` and every other
  value with `toJson`, because a ConfigMap only holds strings. `configFiles` content is written with
  `quote` only: it keeps the file exactly as written, while `toJson` would escape `<`, `>` and `&`
  as `\u003c`, `\u003e` and `\u0026`.
- **A string from values is rendered with `quote` or `toYaml`, never as a plain scalar.** Helm's client
  converts the rendered manifests to JSON with sigs.k8s.io/yaml, which resolves plain scalars with YAML 1.1
  rules (go-yaml v2): `on`, `off`, `yes`, `no`, `y`, `n`, `true` and `false`, capitalized or in capitals too
  (`On`, `YES`, ...), become booleans, `null` becomes null, and a key such as `010` becomes `8`. The object
  is then invalid (a boolean where Kubernetes expects a string), or a map key is silently renamed: a
  plain `config` key `ON` becomes the ConfigMap key `true`. The schema cannot exclude these words without
  rejecting valid values (`on` is a valid port name), so the template quotes. Up to 0.4.0 the port names,
  the Ingress class and paths, the secret store name and the keys of `config`, `configFiles.files` and
  `externalSecret.data` were rendered plain ([upgrade guide](../upgrading.md)); the `port-names` scenario
  and the unit tests keep them fixed. Values that the schema limits to an `enum` (`service.type`,
  `image.pullPolicy`, ...) are rendered as they are, and so are `pdb.minAvailable` and `pdb.maxUnavailable`, so that
  an integer stays an integer (Kubernetes accepts a string there only as a percentage). `configFiles.mountPath` is
  quoted since 0.7.0: up to 0.6.0 a `" #"` comment or trailing whitespace in it was cut by YAML
  ([ADR-0046](../adr/0046-configfiles-mountpath-compared-normalized-rendered-as-written.md)).
- **A map that accepts `null` is read through `chart-base.pruneNulls`** (`templates/_values.tpl`), on a deep copy:
  `deepCopy (<value> | default dict)`, never `.Values` itself, and never a `deepCopy` of a nil (it aborts the
  render). The test is a nil test (`kindIs "invalid"`), never a truthiness test (`false` and `0` are values), and a
  field of a pruned map is tested with `hasKey`. Every reader and guard of that map converts with its schema:
  accepting `null` in the schema alone renders a file whose content is the text `null`
  ([ADR-0045](../adr/0045-null-in-configfiles-and-resources-is-absent.md)).
- **helm-unittest does not read YAML like Kubernetes.** It decodes the rendered manifests with go-yaml v3,
  which reads these words as YAML 1.2 does: `on`, `yes` and the other YAML 1.1 words are strings, so an
  `equal` on a plain `on` passes whether or not the template quotes it. Only `true`, `false` and `null` are
  keywords in both, so a test that a value stays a string uses one of them (the port-name tests use a port
  named `true`). kubeconform resolves these words as Helm's client does, and the `port-names` scenario
  covers `on` there ([testing guide](testing.md#manifest-validation-with-kubeconform)).
- **helm-unittest renders only the templates listed in the suite** (`templates:` at the top of the
  file). A helper or a template that is not listed is not rendered, and a test cannot assert on it. Schema
  errors and guards are reported by whichever listed template is rendered: the schema and guard suites list
  `templates/validate.yaml` for that reason.
- **helm-unittest's defaults are not the chart's defaults.** Its default Kubernetes version is older than
  the chart's 1.33 floor and its default release name is not a valid resource name. That is why every
  suite sets `capabilities` (1.33) and a real lowercase `release.name` (`vending`): the guard rejects
  anything else. Suites that snapshot also pin `chart.version`, so that `helm.sh/chart` does not change in every
  release pull request.
- **`--set` turns integer-looking strings into numbers.** `--set tag=12` is the number 12, and the schema
  then rejects it as a tag. Use `--set-string` for values that must stay text (`e2e.sh` does this for
  `podAnnotations.revision`). Decimal and zero-padded values such as `1.10` or `007` stay strings with
  `--set`, but an unquoted `1.10` inside a values **file** is a number. Quote it in files.
- **Release names in tests must be lowercase and DNS-safe.** Resource names are `<release>-<alias>` and
  the guard requires a valid DNS-1035 name. Names such as `RELEASE-NAME` or `vending.prod` are rejected
  on purpose.
- **A unit test does not prove Helm 4 behavior.** helm-unittest embeds its own Helm engine. Anything that
  depends on the real Helm version (lint behavior, dependency handling, hooks, waiting) is covered
  by the `lint`, alias-contract and e2e jobs.
- **`helm lint` does not fail on a guard.** In lint mode Helm prints a guard's message as an INFO line and exits 0,
  and it renders under the release name `test-release`. A guard is proven by its unit test and by a render
  (`helm template`, which `validate-manifests.sh` runs for every scenario), never by lint; lint fails on schema
  errors ([ADR-0044](../adr/0044-guards-fail-the-render-helm-lint-reports-them.md)).

## Commits and pull requests

- **Conventional commits.** `feat:`, `fix:`, `docs:`, `test:`, `ci:`, `chore:`, `refactor:`. release-please
  derives the next version and the changelog from them.
- **Pull requests are squash-merged and the PR title becomes the commit message on `main`.** The
  `pr-title` job fails a title that is not a conventional commit, so write the title as the commit you want
  in the history.
- **Breaking changes before 1.0 are marked `feat!:` or `fix!:`** and bump the minor version (`fix:` bumps the patch and
  `feat:` the minor). Changing a default, renaming a key or removing one is breaking
  ([ADR-0002](../adr/0002-repository-is-the-chart.md) explains which paths release the chart).
- **Only changes to the chart release it.** Commits that touch only `.github`, `tests`, `ci` or `docs` are
  excluded from releases by `exclude-paths` in `release-please-config.json`, so a documentation or CI
  change never publishes a new version.
- **Update the documentation in the same pull request:** the README template, the affected guide, a
  new ADR for a new decision, the roadmap status. `helm-docs` and the link check run in CI on every pull
  request.
- Run before you push: `helm unittest --strict .`, `helm lint --strict . -f ci/full-values.yaml`, and the
  `helm-docs` command above.
