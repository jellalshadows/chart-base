# Rotating the release GitHub App key

**When to use:** on a schedule (the owner decides the period), or immediately if the private key of the
GitHub App `chart-base-release` may have leaked.

## Prerequisites

- Owner access to the GitHub account that owns the App `chart-base-release`, and admin access to `jellalshadows/chart-base` to set the secret.
- `gh` authenticated.

## What is being rotated

| Item | Value |
| --- | --- |
| GitHub App | `chart-base-release`, installed on this repository only |
| Repository permissions the workflow requests | contents, pull requests and issues: write (`permission-contents`, `permission-pull-requests`, `permission-issues` in the `release-please` job of `release.yaml`) |
| Secret holding the private key | `RELEASE_APP_PRIVATE_KEY` |
| Variable holding the client ID | `RELEASE_APP_CLIENT_ID` (never changes on rotation: only the key does) |

The workflow mints a short-lived installation token from these at the start of every run
([ADR-0021](../adr/0021-github-app-token-for-release-please.md)). The private key is the long-lived part.

## Suspected leak: revoke first

If the key may have leaked, a leaked key can mint tokens with the App's permissions until it is deleted, so do not wait
for the verification: generate the new key (step 2), then **delete the old key** (step 5) immediately, and only then set the
secret (step 3) and verify (step 4). Releases stop working between the deletion and step 3, which is the accepted cost.
For a routine rotation keep the order below so releases are never interrupted.

## Steps

1. **Open the App settings:** the owner account -> *Settings* -> *Developer settings* -> *GitHub Apps* ->
   `chart-base-release` -> *Edit*.
2. **Generate the new key:** under *Private keys*, click *Generate a private key*. The browser downloads the private key file.
   Expected: the key list now shows two keys.
3. **Store it as the repository secret** (the placeholder stands for the downloaded file):
   ```bash
   gh secret set RELEASE_APP_PRIVATE_KEY --repo jellalshadows/chart-base < <downloaded-key>.pem
   ```
   Expected: `Set Actions secret RELEASE_APP_PRIVATE_KEY for jellalshadows/chart-base`.
4. **Prove the new key works.** Run the workflow without the `tag` input, so `publish` is skipped:
   ```bash
   gh workflow run release.yaml --repo jellalshadows/chart-base --ref main
   sleep 10   # give GitHub a moment to register the new run
   gh run list --repo jellalshadows/chart-base --workflow release.yaml --event workflow_dispatch --limit 1
   gh run watch <run-id> --repo jellalshadows/chart-base
   ```
   Expected: the `release-please` job succeeds, its `actions/create-github-app-token` step is green, and
   `publish to ghcr.io` is skipped.
5. **Delete the old key** in the App settings (*Private keys* -> *Delete* on the old entry). Expected: one key remains.
6. **Delete the downloaded key file** from the machine. Keep a copy only in a password manager, if at all.
   Never commit it, paste it in an issue or attach it to a pull request.

## Verification

- `gh secret list --repo jellalshadows/chart-base` shows `RELEASE_APP_PRIVATE_KEY` with a new *updated* time.
- The manual run of step 4 succeeded, and the next push to `main` runs `release-please` without an authentication error.
- The App settings list exactly one private key.

## If something goes wrong

- **The `actions/create-github-app-token` step fails:** check that the file you piped in was the whole
  downloaded key file, that `RELEASE_APP_CLIENT_ID` still holds the App's client ID, and that the App is
  still installed on the repository. Set the secret again (step 3).
- **The old key was deleted before the new one worked:** releases are blocked until step 3 succeeds.
  Generate another key and repeat steps 2 to 4.
- **The key leaked:** after rotating, review the App's and the repository's recent activity (`gh run list --repo jellalshadows/chart-base`, its pull requests and branches) for changes you did not make.

## Related

- [ADR-0021: a GitHub App token for release-please](../adr/0021-github-app-token-for-release-please.md)
- [ADR-0020: release-please and publish in one workflow](../adr/0020-release-please-and-publish-in-one-workflow.md)
- [Cutting a release](release.md)
