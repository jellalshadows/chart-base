# Architecture decision records

Each record explains one design decision of chart-base: the context and the constraints, the
decision, its consequences and every alternative that was considered. ADR *N* expands decision *N*
of the [README's design decisions](../../README.md#design-decisions). How the records are written and
maintained is itself a decision: [ADR-0000](0000-record-architecture-decisions.md).

References to "the design spec" and its addenda (A1-A15) point to the pre-0.1.0 design notes, which are
not published; each record restates every fact it uses.

| ADR | Decision | Status | Since |
|---|---|---|---|
| [0000](0000-record-architecture-decisions.md) | Record architecture decisions | Accepted | docs backfill |
| [0001](0001-application-chart-consumed-through-aliases.md) | Application chart consumed through aliases | Accepted | 0.1.0 |
| [0002](0002-repository-is-the-chart.md) | The repository is the chart | Accepted | 0.1.0 |
| [0003](0003-oci-on-ghcr.md) | OCI on GHCR, public and free | Accepted | 0.1.0 |
| [0004](0004-env-in-configmap-secrets-through-externalsecret.md) | Env vars in a ConfigMap, secrets through ExternalSecret | Amended by 0030, 0031 | 0.1.0 |
| [0005](0005-configfiles-string-or-map.md) | `configFiles` accepts a string or a map | Accepted | 0.1.0 |
| [0006](0006-checksum-for-config-reloader-for-secrets.md) | Checksums for config, Reloader for Secrets | Amended by 0033 | 0.1.0 |
| [0007](0007-jobs-as-helm-hooks.md) | `workload.type: job` is a Helm hook | Accepted | 0.1.0 |
| [0008](0008-names-are-release-alias-and-never-truncated.md) | Names are `<release>-<alias>` and never truncated | Accepted | 0.1.0 |
| [0009](0009-no-name-overrides.md) | No `nameOverride`/`fullnameOverride` | Accepted | 0.1.0 |
| [0010](0010-chart-version-never-restarts-pods.md) | Bumping chart-base never restarts pods by itself | Accepted | 0.1.0 |
| [0011](0011-strict-draft-07-schema.md) | Strict draft-07 schema with reserved `global` and `enabled` | Accepted | 0.1.0 |
| [0012](0012-no-capabilities-gating.md) | No `.Capabilities` gating for CRD kinds | Accepted | 0.1.0 |
| [0013](0013-secure-by-default.md) | Secure by default (Pod Security `restricted`) | Accepted | 0.1.0 |
| [0014](0014-resource-requests-required.md) | `resources.requests` are required | Accepted | 0.1.0 |
| [0015](0015-pdb-and-topology-spread-by-default.md) | PDB and topology spread on by default | Accepted | 0.1.0 |
| [0016](0016-httproute-first-ingress-optional.md) | HTTPRoute first, Ingress optional | Accepted | 0.1.0 |
| [0017](0017-progress-deadline-240s.md) | `progressDeadlineSeconds: 240` | Accepted | 0.1.0 |
| [0018](0018-kubernetes-version-floor.md) | Kubernetes version floor `>=1.33.0-0` | Accepted | 0.1.0 |
| [0019](0019-helm-4-first-helm-3-tested.md) | Helm 4 first, Helm 3.22 still tested | Accepted | 0.1.0 |
| [0020](0020-release-please-and-publish-in-one-workflow.md) | release-please and publishing in one workflow | Accepted | 0.1.0 |
| [0021](0021-github-app-token-for-release-please.md) | A GitHub App token for release-please | Accepted | 0.1.0 |
| [0022](0022-provenance-with-actions-attest.md) | Provenance with `actions/attest` | Accepted | 0.1.0 |
| [0023](0023-no-chart-testing.md) | No chart-testing (`ct`) | Accepted | 0.1.0 |
| [0024](0024-renovate.md) | Renovate for actions and tool versions | Accepted | 0.1.0 |
| [0025](0025-generated-english-readme.md) | Generated README, in English | Accepted | 0.1.0 |
| [0026](0026-cronjob-runs-kept-by-history-limits.md) | CronJob runs are kept by the history limits | Accepted | 0.1.0 |
| [0027](0027-required-keys-in-the-schema.md) | Keys the templates rely on are `required` | Accepted | 0.1.0 |
| [0028](0028-podlabels-cannot-override-selector-labels.md) | `podLabels` cannot override the selector labels | Accepted | 0.1.0 |
| [0029](0029-publishing-built-for-recovery.md) | Publishing is built for recovery | Accepted | 0.1.0 |
| [0030](0030-env-takes-references-only.md) | `env` takes references only | Accepted | 0.2.0 |
| [0031](0031-existing-secrets-referenced-by-name.md) | Existing Secrets are referenced by name | Accepted | 0.2.0 |
| [0032](0032-external-envfrom-first-env-wins.md) | External `envFrom` sources first, `env` wins | Accepted | 0.2.0 |
| [0033](0033-component-level-reload-on-change.md) | Component-level `reloadOnChange` | Accepted | 0.2.0 |

## Adding a record

1. Copy the template at the end of [ADR-0000](0000-record-architecture-decisions.md#template) into
   `NNNN-short-slug.md` with the next free number. Numbers are never reused.
2. Add a row to the table above and a one-paragraph summary, with the link, to the README's
   "Design decisions" list (`README.md.gotmpl`), under the same number.
3. If the decision changes an earlier one, add `Amended by` or `Superseded by` to the earlier record's
   status line; do not rewrite the earlier record.
4. Ship the record in the same pull request as the change it describes.
