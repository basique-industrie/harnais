# Releasing Harnais

Harnais owns its release job, signing environment and GitHub assets. GitHub's
Apple silicon `macos-26` runner runs the tagged `scripts/release.sh`, which tests,
packages, signs, notarizes and staples the shipped app. Publication uses that
job's repository-scoped `GITHUB_TOKEN`. The only interactive step is the
protected environment's approval.

## Prepare and release

1. Bump `CFBundleShortVersionString` and increment `CFBundleVersion` in
   `Sources/HarnaisCore/Info.plist`. Add the matching dated changelog section.
2. Merge the release change after CI passes.
3. Create and push the version tag, for example:

   ```sh
   git tag -a v1.2.3 -m 'Harnais 1.2.3'
   git push origin v1.2.3
   ```

4. Approve the `release` environment in the Release run. The resulting zip and
   checksum are published together. Never move an already published tag.

Versions use `X.Y.Z` or `X.Y.Z-alpha.N`, `X.Y.Z-beta.N`, `X.Y.Z-rc.N`.
Prerelease versions are marked as prereleases on GitHub.

To retry with the current workflow tooling, or validate an existing tag:

```sh
gh workflow run release.yml -R basique-industrie/harnais --ref main -f tag=v1.2.3
gh workflow run release.yml -R basique-industrie/harnais --ref main -f tag=v1.2.3 -F dry_run=true
gh run list -R basique-industrie/harnais --workflow release.yml --limit 5
```

A validation run performs the real build, signing and notarization, then saves
the artifacts without creating or editing a release. The workflow checks out
release tooling separately from the version tag, so a retry can use workflow
fixes without moving the source tag.

## Credentials and protections

Configure these six secrets in **Harnais → Settings → Environments → release**:

- `APPLE_DEVELOPER_ID_APPLICATION_P12`: base64 PKCS#12 Developer ID identity
- `APPLE_DEVELOPER_ID_PASSWORD`: its password
- `APPLE_NOTARY_KEY_ID`: App Store Connect key ID
- `APPLE_NOTARY_KEY_ISSUER`: its issuer ID
- `APPLE_NOTARY_KEY_P8`: base64 App Store Connect private key
- `HARNAIS_NATIVE_OAUTH_CATALOG`: native OAuth registration JSON

Keep required reviewers enabled and allow only the `main` branch and `v*` tags.
PR jobs receive no signing credentials. Each release uses a temporary keychain;
cleanup restores the original keychain configuration and deletes the injected
catalog and temporary key material, including after a failed build.

For an approved transfer or rotation from Iles, its **Provision Harnais release**
workflow encrypts the six values directly for Harnais's GitHub environment key.
Only the encrypted transfer is uploaded; secret plaintext is never downloaded.
After approving that Iles workflow, download its `Harnais-encrypted-release-secrets`
artifact into a temporary directory and run:

```sh
python3 scripts/import-release-secrets.py /path/to/harnais-encrypted-secrets.json
```

The importer checks the recipient, GitHub's current encryption key, the required
reviewer protection and all six secret names before sending encrypted values to
GitHub. If GitHub rotates the environment key, update the fixed public recipient
in Iles's encryption script before generating a new transfer. Do not put personal
`gh` login tokens into repository secrets.

## Failure recovery

- A missing credential fails before the build and names all missing secrets.
- Build or notarization failure leaves the GitHub release unpublished. Fix the
  source in a new version if the previous version has already been published.
- Uploads go into a draft marked with the exact source commit. A retry can repair
  that draft, verifies downloaded assets, then publishes it. Unrelated drafts
  are left alone.
- A completed release is verified and treated as a successful no-op on retry.
  Its assets are never overwritten. Signing timestamps mean rebuilding the same
  source produces different archive bytes, so completed retries verify the
  original uploaded archive rather than comparing it with a rebuild.
- API permission errors fail explicitly; they are never treated as a missing
  release. Check `gh auth status` for local commands.

`python3 scripts/test-release.py` exercises validation and failure recovery in
CI without using credentials or publishing anything.

## Why the previous automation failed

The old Harnais job dispatched Iles's signing workflow with `ILES_RELEASE_TOKEN`,
but that secret was never configured. Local `gh` authentication belongs to the
logged-in user and is not inherited by GitHub Actions. Releases 0.1.3 and 0.2.0
were signed through manually dispatched Iles runs and uploaded using local `gh`.

The old job also used `gh run watch` with a recommended fine-grained token, which
[GitHub CLI does not support](https://cli.github.com/manual/gh_run_watch), and
could select an unrelated signing run by its timestamp. The native Harnais job
removes both dependencies. GitHub documents the automatic token's repository
scope in [GITHUB_TOKEN](https://docs.github.com/en/actions/concepts/security/github_token).
