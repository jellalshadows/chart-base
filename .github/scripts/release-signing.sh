#!/usr/bin/env bash
# Exercises the signing logic of .github/workflows/release.yaml against a real, already-signed
# release, without signing anything: the actual `run:` blocks are extracted with yq and run
# here, so a change to them (or a cosign bump that breaks verification) fails in the PR.
# Usage: release-signing.sh <repository root>     Requires: cosign, jq, yq (mikefarah v4), curl
# Needs network access (ghcr.io, Sigstore). Registry access is anonymous.
set -euo pipefail

root="${1:?usage: release-signing.sh <repository root>}"
workflow="${root}/.github/workflows/release.yaml"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Anonymous registry access, also on machines whose Docker config has a credential store.
mkdir -p "$work/docker"
export DOCKER_CONFIG="$work/docker"

# Fixture: chart-base 0.2.0, signed and attested. Published versions are immutable, so the
# digest never changes.
digest=sha256:8f91568b2371fef9cca7ade9a26aa1c0e994b8fec8804cfdd7574f06d7bacf07
REF="ghcr.io/jellalshadows/charts/chart-base@${digest}"
SIGNER_IDENTITY=https://github.com/jellalshadows/chart-base/.github/workflows/release.yaml@refs/heads/main
SIGNER_ISSUER=https://token.actions.githubusercontent.com
PROVENANCE=https://slsa.dev/provenance/v1
SIGNATURE=https://sigstore.dev/cosign/sign/v1
export SIGNER_IDENTITY SIGNER_ISSUER

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok - $*"; }

# The run block of a release.yaml step, by name; fails if the step is missing or has no run.
step_run() {
  local block
  block="$(yq ".jobs.publish.steps[] | select(.name == \"$1\") | .run" "$workflow")"
  if [ -z "$block" ] || [ "$block" = null ]; then
    fail "step '$1' not found in ${workflow} (renamed or removed?)"
  fi
  printf '%s\n' "$block"
}
# Runs a block the way the GitHub runner runs `run:` (bash -e -o pipefail).
run_block() { bash -e -o pipefail -c "$1"; }

# 1. The helper is created by the real "Prepare" step.
export RUNNER_TEMP="$work/runner"
mkdir -p "$RUNNER_TEMP"
run_block "$(step_run 'Prepare the Sigstore bundle check')" > /dev/null
helper="${RUNNER_TEMP}/require-bundles.sh"
[ -x "$helper" ] || fail "${helper} was not created as an executable"
pass "prepare step creates an executable require-bundles.sh"

# 2. The signature and the provenance verify for the release workflow identity.
out="$work/out.txt"
"$helper" "$REF" "$PROVENANCE" "$SIGNATURE" > "$out" 2>&1 || { cat "$out" >&2; fail "0.2.0 does not verify with both bundle types"; }
pass "signed release verifies: provenance and signature bundles"

# 3. A missing bundle type is reported (the type filter is not vacuous).
missing=https://example.invalid/none
if "$helper" "$REF" "$PROVENANCE" "$missing" > "$out" 2>&1; then
  fail "a non-existent bundle type was accepted"
fi
grep -q "has no ${missing} bundle" "$out" || { cat "$out" >&2; fail "missing type not reported as such"; }
pass "a missing bundle type is rejected"

# 4. The identity is enforced.
if SIGNER_IDENTITY=https://github.com/jellalshadows/chart-base/.github/workflows/ci.yaml@refs/heads/main \
  "$helper" "$REF" "$PROVENANCE" "$SIGNATURE" > "$out" 2>&1; then
  fail "a different signer identity was accepted"
fi
pass "a different signer identity is rejected"

# 5. The guard's digest extraction, on real HEAD headers of the published tag.
token="$(curl -fsS "https://ghcr.io/token?scope=repository:jellalshadows/charts/chart-base:pull" | jq -r .token)"
headers="$work/manifest-headers.txt"
curl -fsS -o /dev/null -D "$headers" -I \
  -H "Authorization: Bearer ${token}" \
  -H 'Accept: application/vnd.oci.image.manifest.v1+json' \
  https://ghcr.io/v2/jellalshadows/charts/chart-base/manifests/0.2.0
awk_line="$(step_run 'Refuse to overwrite an existing version (GHCR tags are mutable)' | { grep 'docker-content-digest' || true; })"
[ -n "$awk_line" ] || fail "no docker-content-digest extraction found in the guard step"
extracted="$(headers="$headers" bash -e -o pipefail -c "${awk_line}"$'\n''printf %s "$digest"')"
[ "$extracted" = "$digest" ] || fail "guard extracted '${extracted}', expected ${digest}"
pass "guard extracts the digest from the manifest headers"

# 6. "Digest to sign".
target="$(step_run 'Digest to sign')"
run_target() { # <pushed> <existing>; output file in $work/github-output
  : > "$work/github-output"
  GITHUB_OUTPUT="$work/github-output" PUSHED="$1" EXISTING="$2" REPOSITORY=jellalshadows/charts CHART=chart-base \
    run_block "$target" > "$out" 2>&1
}
run_target "" "$digest" || { cat "$out" >&2; fail "existing digest was not accepted"; }
[ "$(cat "$work/github-output")" = "ref=${REF}" ] || fail "existing digest gave: $(cat "$work/github-output")"
pass "sign-only: the existing digest is the target"

pushed="sha256:$(printf 'a%.0s' {1..64})"
run_target "$pushed" "$digest" || { cat "$out" >&2; fail "pushed digest was not accepted"; }
[ "$(cat "$work/github-output")" = "ref=ghcr.io/jellalshadows/charts/chart-base@${pushed}" ] || fail "pushed digest did not win"
pass "publish: the pushed digest wins over the existing one"

if run_target "" ""; then fail "an empty digest was accepted"; fi
grep -q 'no digest to sign' "$out" || { cat "$out" >&2; fail "empty digest not reported"; }
pass "no digest: refuses to sign"

if run_target "" "sha256:nothex"; then fail "a malformed digest was accepted"; fi
grep -q 'no digest to sign' "$out" || { cat "$out" >&2; fail "malformed digest not reported"; }
pass "malformed digest: refuses to sign"
