# ADR-0034: Keyless cosign signatures by digest

- **Status:** Accepted
- **Date:** 2026-09-29
- **Since:** after 0.2.0 (ci)
- **Related:** [ADR-0022](0022-provenance-with-actions-attest.md), [ADR-0029](0029-publishing-built-for-recovery.md)

## Context

[ADR-0022](0022-provenance-with-actions-attest.md) gave every version a SLSA provenance attestation,
verifiable with `gh`. Other verifiers look for a signature instead: Flux can verify a `HelmChart` with
cosign, and supply-chain tooling in general speaks Sigstore. (Kyverno and Sigstore's policy-controller verify
the images of Pods, not Helm charts, so they are not consumers of this signature.)

- GHCR has no OCI referrers API. cosign v3 and `actions/attest` both store their Sigstore bundle in the
  referrers tag-schema fallback: an index tagged `sha256-<hex>` of the subject digest. Each of them fetches
  that index and appends its own entry, so two writers running at the same time could lose one entry.
- `cosign verify` accepts any bundle of the digest that verifies for the given identity, including the
  provenance attestation. Version 0.2.0 verified with plain `cosign verify` before it had any signature, only
  because of its attestation. That command alone therefore does not prove that a signature exists.
- The versions published before this change (0.1.0 and 0.2.0) have no signature.

## Decision

- The `publish` job of `.github/workflows/release.yaml` signs the chart's digest with cosign keyless (the
  GitHub OIDC token, a Fulcio certificate and a Rekor entry), using cosign v3's default bundle format.
  The steps run after `actions/attest`, in the same job:
  - `Digest to sign` takes the digest printed by `helm push` (or, in sign-only mode, the one the guard read)
    and requires the form `sha256:<64 hex>`.
  - `sigstore/cosign-installer` v4.1.2 installs cosign. `COSIGN_VERSION` (`v3.1.3`) is an environment
    variable with a `# renovate:` comment, so Renovate tracks it. The installer verifies the signature of the
    cosign binary it downloads.
  - `Sign with cosign (keyless)` runs `cosign sign --yes` on `ghcr.io/<owner>/charts/chart-base@<digest>`.
  - `The cosign signature verifies` runs `cosign verify … --output json` with the exact identity
    `https://github.com/jellalshadows/chart-base/.github/workflows/release.yaml@refs/heads/main` and issuer
    `https://token.actions.githubusercontent.com`, and fails unless an entry of type
    `https://sigstore.dev/cosign/sign/v1` is present. The type filter is what keeps the attestation from
    satisfying the check.
- `attest` and `sign` append to the same referrers index, so they are sequential steps of one job, and the
  workflow's `concurrency: release` group (`cancel-in-progress: false`) serializes whole runs.
- **Sign-only mode.** The overwrite guard reports its result as `mode`. `404` is `publish`, as before. `200`
  on the automatic path still fails with `refusing to overwrite`. `200` on a manual `workflow_dispatch` run
  switches to `sign-only`: nothing is packaged, pushed or attested, and the digest from the response header
  `Docker-Content-Digest` is signed and verified. This is the recovery when signing fails after the
  irreversible push, and the way to backfill 0.1.0 and 0.2.0
  ([runbook](../runbooks/republish-a-tag.md)).
- All the logic is inline in the workflow file, because a sign-only run checks out the old tag: a script
  added to the repository would not exist there.
- Consumers verify with the `cosign verify … | jq -e …` command of the
  [README](../../README.md#versioning-and-releases).

## Consequences

- A consumer can verify both who built a version (`gh attestation verify`) and who signed it (`cosign
  verify`), with the identity of the workflow and no key to manage.
- Flux 2.8 and later can verify these bundles: `HelmChart` `spec.verify.provider: cosign` with keyless
  `matchOIDCIdentity` (see [Consuming](../guides/consuming.md#verifying-what-you-deploy)). Older Flux
  reads only the legacy `.sig` tag and would not find them.
- Each signature is a public Rekor entry that names the repository and the workflow.
- Signing the same digest twice adds a second signature. It is harmless: verification accepts either.
- The publish path gains a third-party action and a downloaded binary, both pinned and tracked by Renovate.
- A sign-only run signs whatever digest the version tag currently points to. Nothing compares it with the
  provenance attestation, so before dispatching one, check the version with `gh attestation verify` to
  confirm that digest was built by this workflow.
- The signature proves that `release.yaml` on `main` signed the digest, not that the chart content is safe.

## Alternatives considered

### A signing key pair

A secret to guard, store in Actions and rotate, and a signature that binds to a key and not to a workflow
identity.

### Legacy `.sig` signatures

cosign v3.1.3 writes them only with `--new-bundle-format=false --use-signing-config=false`. They are
deprecated and cosign has announced their removal for v4. Flux ignores them when a bundle exists.

### Relying on `cosign verify` accepting the attestation

That behavior is an implementation detail, not a contract, and it would leave versions without a signature
looking verified.

### Signing only from the next release on, with no sign-only mode

The first real test would be a real release, and a signing failure after the push would need a new patch
release, because the overwrite guard refuses to touch a published version.

## References

- `.github/workflows/release.yaml` (`publish` job: guard, `Digest to sign`, `Sign with cosign (keyless)`,
  `The cosign signature verifies`)
- [Signing overview](https://docs.sigstore.dev/cosign/signing/overview/) and
  [Verifying signatures](https://docs.sigstore.dev/cosign/verifying/verify/) (Sigstore documentation)
- [HelmChart verification](https://fluxcd.io/flux/components/source/helmcharts/#verification) (Flux
  documentation) and [the Flux 2.8 announcement](https://fluxcd.io/blog/2026/02/flux-v2.8.0/), which lists
  support for Cosign v3
