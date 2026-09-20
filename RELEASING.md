# Releasing HerdX

A release is a notarized, stapled, universal `HerdX.dmg` attached to a GitHub
release. Pushing a `v*` tag is the whole ceremony; everything below is setup you
do once, plus the local equivalent for when you want to see it work before
trusting CI with it.

## What the pipeline does

`scripts/package.sh` builds a release bundle for arm64 and x86_64, signs it with
a Developer ID certificate under the hardened runtime, sends it to Apple for
notarization, staples the ticket to the app, wraps the stapled app in a disk
image, and then notarizes and staples the disk image too.

The app is stapled separately from the image on purpose. Stapling only the
`.dmg` leaves the copy the user drags into `/Applications` depending on an
online Gatekeeper check — which is exactly the offline first launch where an
app looks broken for reasons nobody can diagnose from the outside.

The script verifies the result with `stapler validate` on both, and with
`spctl --assess`, which answers the question that actually matters: not "is it
signed" but "will Gatekeeper run it".

## One-time setup

### 1. The signing certificate

You need a **Developer ID Application** certificate — not "Apple Development",
not "Apple Distribution". Those cannot notarize.

Export it from Keychain Access (My Certificates → right-click → Export), giving
it a password, then:

```sh
base64 -i DeveloperID.p12 | pbcopy
```

### 2. The notarization credentials

Use an App Store Connect API key rather than an Apple ID and app-specific
password: it carries no 2FA, it is scoped, and it can be revoked on its own
without touching your Apple ID.

App Store Connect → Users and Access → Integrations → Keys. Create a team key
with **Developer** access or higher. You get:

- the **Key ID**, next to the key
- the **Issuer ID**, above the key table
- `AuthKey_<KeyID>.p8`, downloadable exactly once

```sh
base64 -i AuthKey_XXXXXXXXXX.p8 | pbcopy
```

### 3. The GitHub secrets

Settings → Secrets and variables → Actions:

| Secret | Value |
| --- | --- |
| `MACOS_CERTIFICATE_P12` | base64 of the `.p12` |
| `MACOS_CERTIFICATE_PASSWORD` | the password you gave the `.p12` on export |
| `APPLE_API_KEY_P8` | base64 of the `.p8` |
| `APPLE_API_KEY_ID` | the Key ID |
| `APPLE_API_ISSUER` | the Issuer ID |
| `MACOS_SIGN_IDENTITY` | optional; only needed if the keychain ends up holding more than one Developer ID Application identity |

## Cutting a release

```sh
git tag v0.2.0
git push origin main
git push origin v0.2.0
```

`origin` is git.home, which mirrors to GitHub — pushing the tag to `github`
directly leaves the two out of step, and the mirror is what the release runs
from.

The workflow stamps `0.2.0` into `CFBundleShortVersionString`, builds, notarizes,
and publishes a GitHub release with the `.dmg` attached.

Notes come from `release-notes/v0.2.0.md` when that file exists, and from
`--generate-notes` when it does not. Write the file: a list of commit subjects
says what was touched rather than what changed for the person reading it.

To exercise the pipeline without spending a version number, run the workflow
manually from the Actions tab: it builds and notarizes exactly the same way but
uploads the `.dmg` as a workflow artifact instead of publishing a release.

## Releasing from your own machine

Worth doing once, so that the first time you see a notarization error it is not
also the first time you are reading CI logs.

```sh
xcrun notarytool store-credentials herdx \
  --key ~/path/AuthKey_XXXXXXXXXX.p8 \
  --key-id XXXXXXXXXX \
  --issuer xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx

HERDX_VERSION=0.2.0 HERDX_NOTARY_PROFILE=herdx ./scripts/package.sh
```

This needs both Rust targets:

```sh
rustup target add aarch64-apple-darwin x86_64-apple-darwin
```

## When notarization fails

`package.sh` prints Apple's log for the rejected submission rather than the
bare `Invalid`, because `Invalid` on its own tells you nothing. The two that
come up:

- **"The signature does not include a secure timestamp"** — signing happened
  without `--timestamp`, or the machine could not reach Apple's timestamp
  server while signing.
- **"The executable does not have the hardened runtime enabled"** — signing
  happened without `--options runtime`.

Both are set in `package.sh`; seeing either usually means something re-signed
the bundle afterwards.
