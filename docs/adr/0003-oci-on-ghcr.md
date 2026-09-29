# ADR-0003: OCI on GHCR, public and free

- **Status:** Accepted
- **Date:** 2026-09-27
- **Since:** 0.1.0

## Context

Helm has supported OCI registries as a first-class storage backend since 3.8.0 (GA), alongside the
older classic Helm repository format (an `index.yaml` served over HTTP). An OCI registry needs no
`helm repo add`/`helm repo update` step: `helm dependency update` and `helm install`/`helm template`
resolve an `oci://` reference directly. GitHub ships GHCR (`ghcr.io`) as an OCI registry bundled with
every GitHub account and repository, at no extra cost for public packages, and `Chart.yaml`'s
`sources` field is exactly what Helm needs to link a pushed chart back to its repository.

Helm's OCI push path (`pkg/registry/chart.go`, function `generateChartOCIAnnotations`) builds the
image manifest's annotations from the chart's `Metadata`: `Description` becomes
`org.opencontainers.image.description`, `Name` becomes `.title`, `Version` becomes `.version`,
`Home` becomes `.url`, and — when `meta.Sources` is non-empty — `meta.Sources[0]` becomes
`org.opencontainers.image.source`. chart-base's `Chart.yaml` sets `sources[0]` to
`https://github.com/jellalshadows/chart-base`, so every pushed version carries an
`org.opencontainers.image.source` annotation pointing at this repository with no manual annotation
to maintain (`Chart.yaml`'s `annotations` map only adds `org.opencontainers.image.licenses`, which
`generateOCIAnnotations` copies verbatim since it is not one of the fields Helm derives itself).

Publishing worked with no manual step: the chart came out public on the first release. The
`release.yaml` workflow pushes with the repository's own `GITHUB_TOKEN` from a public repository,
and GHCR linked and published the `chart-base` package automatically — `helm pull` and an anonymous
`docker manifest inspect`-equivalent both succeeded with no login, and the package page shows the
repository link derived from the annotation above. `0.1.0` was published at
`ghcr.io/jellalshadows/charts/chart-base:0.1.0` with an `actions/attest` SLSA provenance attestation,
verified with `gh attestation verify --signer-workflow`.

## Decision

- chart-base is published as an OCI artifact to `oci://ghcr.io/jellalshadows/charts/chart-base`.
  Consumers add it as a dependency with `repository: oci://ghcr.io/jellalshadows/charts` and no
  `helm repo add` step (see the README quick start).
- `Chart.yaml`'s `sources[0]` (`https://github.com/jellalshadows/chart-base`) is the only thing that
  links the OCI package to this repository: Helm copies it into the `org.opencontainers.image.source`
  manifest annotation on every push.
- Public GHCR packages are free; no registry credentials or paid plan are required to consume
  chart-base.
- Anonymous pull with no login was verified on the `0.1.0` release: `helm pull` and package discovery
  worked without authentication.

## Consequences

- Consumers add one `repository: oci://...` line and never manage a Helm repo index.
- The published package's provenance is directly traceable to the source repository through a
  standard annotation, with no extra step in `release.yaml`.
- The trade-off: GHCR's automatic linking and public visibility on first publish is an *observed*
  behavior of this specific setup (a public repository publishing with its own `GITHUB_TOKEN`), not
  a documented guarantee from GitHub; a repository configuration change could alter it, and it should
  be re-verified after any change to how `release.yaml` authenticates to GHCR.

## Alternatives considered

### An HTTP Helm repository on GitHub Pages

The classic Helm repository format needs an `index.yaml` regenerated and committed on every release,
served from a separate branch or Pages deployment — a second publishing path and a second artifact
to keep in sync with the OCI push, for no benefit over `oci://` support that every target Helm
version (3.8+) already has.

## References

- `Chart.yaml`
- `.github/workflows/release.yaml`
- [Helm: Use OCI-based registries](https://helm.sh/docs/topics/registries/)
- [helm/helm `pkg/registry/chart.go`, `generateChartOCIAnnotations`](https://github.com/helm/helm/blob/v4.3.0/pkg/registry/chart.go)
