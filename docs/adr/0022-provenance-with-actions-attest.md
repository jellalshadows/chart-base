# ADR-0022: Provenance with `actions/attest`

- **Status:** Accepted
- **Date:** 2026-09-27
- **Since:** 0.1.0

## Context

chart-base is a public package other teams' domain umbrellas pull straight from `ghcr.io` with a version
number and nothing else pinned (`Chart.lock` records no digest). A consumer who wants more assurance than
"the registry returned a manifest for this tag" needs some way to check *which* workflow, on *which*
commit, actually produced that artifact — otherwise trusting a public OCI package rests entirely on trusting
the registry.

GitHub's native answer to this is `actions/attest`, which creates a SLSA build-provenance attestation
scoped to a specific artifact digest and uploads it to the registry next to the package, verifiable
afterwards with the `gh` CLI. This needs no separate signing infrastructure beyond what the Actions runner
and GHCR already provide. cosign (Sigstore keyless signing) is the other common tool for the same job, but
at the time chart-base first shipped it meant one more moving part on GHCR for an equivalent guarantee
`actions/attest` already gives natively — so it was left for later rather than built in from day one.

## Decision

- The `publish` job's last step in `.github/workflows/release.yaml` runs `actions/attest@v4.2.2` with
  `subject-name: ghcr.io/${{ env.REPOSITORY }}/${{ env.CHART }}`, `subject-digest:` the digest captured from
  the preceding "Push to ghcr.io" step's output, `push-to-registry: true`, `create-storage-record: false`.
  It runs unconditionally after every successful `helm push`, for every published version.
- The job carries `id-token: write` (to obtain the short-lived Sigstore-issued signing certificate
  `actions/attest` uses) and `attestations: write` (to store the resulting attestation) — both scoped only
  to the `publish` job, not the whole workflow.
- Consumers verify a version with the command the README's "Versioning and releases" section publishes:
  `gh attestation verify oci://ghcr.io/jellalshadows/charts/chart-base:X.Y.Z --repo jellalshadows/chart-base
  --signer-workflow jellalshadows/chart-base/.github/workflows/release.yaml`.
- This was exercised for real on the very first release: 0.1.0's attestation was created during publish and
  independently verified afterwards with `gh attestation verify --signer-workflow`, confirming the whole
  chain works end to end rather than only in the workflow definition.
- cosign keyless signing is not implemented. It stays on the roadmap as a separate, later addition (its own
  `feat:` commit) rather than something bundled into this decision.

## Consequences

- Any consumer can cryptographically confirm that a given `ghcr.io` digest was produced by chart-base's own
  `release.yaml`, on `jellalshadows/chart-base`, rather than pushed from an arbitrary machine.
- Trade-off: the attestation only proves *which workflow* built and pushed the digest — it says nothing
  about the source content beyond what that workflow itself checked out at `refs/tags/<tag>`. It does not
  replace the `Chart.yaml`-version assertion or the overwrite guard (ADR-0020); it is an additional,
  independent check, and it is one more step in the `publish` job that can itself fail (an attestation
  failure after a successful `helm push` leaves that version on GHCR without provenance, and the
  re-publish path of ADR-0029 cannot fix it: a re-run stops at the overwrite guard, because the
  version's manifest now answers `200`. The recovery is a new patch release).
- Nothing produces a cosign signature, so tooling that specifically expects Sigstore/cosign verification
  (rather than GitHub's own attestations API) cannot verify chart-base's provenance today.

## Alternatives considered

### cosign from the start

At the point chart-base first shipped, using cosign meant a second signing flow (a keypair or a keyless OIDC
exchange) and a second interaction with GHCR for the same underlying guarantee `actions/attest` already
provides as a native GitHub Actions step. Kept as a roadmap item rather than added up front.

### No provenance

Leaves a consumer with nothing beyond "the registry says this manifest exists" — defeating the purpose of
publishing a versioned dependency that other teams' production umbrellas build on.

## References

- `.github/workflows/release.yaml` (`publish` job, `actions/attest` step)
- `../../README.md#versioning-and-releases` (`gh attestation verify` command)
- [actions/attest](https://github.com/actions/attest)
