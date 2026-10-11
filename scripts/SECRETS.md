# Release pipeline secrets

`.github/workflows/release.yml` requires the following GitHub Actions secrets
on `maclifevn/MClean`. Configure them before running the manual Release workflow.
Missing signing/notarization/Sparkle credentials stop the workflow before publication.

The CI pipeline uses an **Apple ID and app-specific password** for notarization,
as selected during production preparation. It validates and stores them in the
runner's temporary signing keychain for Team **CF5PGH3KGK**. Local releases can
reuse an existing `notarytool` Keychain profile.

## Required secrets (6)

| Secret | Source | Notes |
|--------|--------|-------|
| `BUILD_CERTIFICATE_BASE64` | Filtered Developer ID Application `.p12` (cert + matching private key only), base64 | `base64 -i cert.p12 \| pbcopy` |
| `P12_PASSWORD` | Password set when exporting the `.p12` | Random — only you and CI need it |
| `KEYCHAIN_PASSWORD` | Random string | Used to lock the runner's temporary signing keychain |
| `NOTARIZATION_APPLE_ID` | Apple ID with access to the signing team's notarization service | Enter at the interactive Terminal prompt below |
| `NOTARIZATION_APP_PASSWORD` | Apple app-specific password | Use an app-specific password, never the account's primary password |
| `SPARKLE_PRIVATE_KEY` | Exported Ed25519 seed from Sparkle `generate_keys -x` | Keep the matching public key in `MClean/Info.plist`; never regenerate for each release |

For the Sparkle key and signed appcast workflow, see [SPARKLE-UPDATES.md](../docs/SPARKLE-UPDATES.md). The key created for this integration uses the Keychain account `com.maclife.mclean`. Its public key is `uG9oyQv95UqnmgJdLQsaHjHwphJ65HvcbGbAhIluoy0=`. The private key stays outside the repository.

Production preparation on **11 October 2026** configured all six required names
on `maclifevn/MClean`, including both `NOTARIZATION_*` secrets after the owner
ran the interactive setup. The workflow checks
all required names before installing tools or building; it never prints values.
Local **1.0.5 / build 6** has already been notarized with the existing profile
`mdrivehealth`. See [PRODUCTION-RELEASE.md](../docs/PRODUCTION-RELEASE.md) for artifacts
and CI verification status.

## Optional secret (1)

| Secret | Source | Notes |
|--------|--------|-------|
| `HOMEBREW_TAP_TOKEN` | Fine-grained PAT with `Contents: read+write` on `maclifevn/homebrew-tap` | Without this the tap formula bump step is skipped (in-repo `homebrew/mclean.rb` still bumps via the default `GITHUB_TOKEN`) |

## Exporting the Developer ID identity

In Keychain Access → My Certificates, select only **Developer ID Application**
for Team **CF5PGH3KGK** (the team in `project.yml`), including its matching
private key. Export that identity as `MClean-DeveloperID.p12` with a strong
password. The pipeline rejects certificates from a different team so subsequent
Developer ID releases keep a stable signing identity. The published 1.0.4 used
Apple Development instead, so its existing Full Disk Access grant may need to
be renewed when upgrading to the Developer ID release.

Prepare a private directory outside the repository and keep the export password
in `P12_PASSWORD.txt` there:

```bash
mkdir -p ~/Desktop/MClean-secrets
chmod 700 ~/Desktop/MClean-secrets
umask 077
base64 -i ~/Desktop/MClean-secrets/MClean-DeveloperID.p12 \
  -o ~/Desktop/MClean-secrets/MClean-DeveloperID.p12.b64
openssl rand -base64 32 > ~/Desktop/MClean-secrets/KEYCHAIN_PASSWORD.txt
```

Exporting the entire login keychain is unnecessary. Back up the single identity
in your secret manager; do not commit `.p12`, password files or Apple API keys.

## Local notarization profile

`AC_NOTARY` was absent during the audit. The production preparation then found
the working profile **`mdrivehealth`**, which accepted both the 1.0.5 app and DMG.
No replacement credentials were created. Reuse it explicitly:

```bash
xcrun notarytool history --keychain-profile mdrivehealth
scripts/release-local.sh 1.0.5 mdrivehealth
# Or set MCLEAN_NOTARY_PROFILE=mdrivehealth for local runs.
```

On a new machine, create a profile interactively for the signing team:

```bash
xcrun notarytool store-credentials AC_NOTARY \
  --apple-id YOUR_DEVELOPER_APPLE_ID \
  --team-id CF5PGH3KGK
xcrun notarytool history --keychain-profile AC_NOTARY
```

The local script accepts a profile argument or `MCLEAN_NOTARY_PROFILE`, with
`AC_NOTARY` as its fallback, and validates credentials before starting a build.
CI runners cannot access a profile stored on this Mac. CI still needs the two
notarization secrets. Replace the Apple ID placeholder with your account.
Omitting `--password` lets Apple's tool ask for it securely in Terminal.

## Interactive notarization setup

Run this yourself in Terminal from the repository:

```bash
python3 scripts/setup-notarization.py
```

The script prompts for your Apple ID and app-specific password with hidden
password input. It checks notarization access for Team **CF5PGH3KGK** with Apple
before changing any secrets, then sends both `NOTARIZATION_*` values to
`maclifevn/MClean` through `gh secret set` stdin. It does not write a credentials
file or put the entered password in shell history. It redacts credential values
from command error messages. A failed Apple validation changes no secrets.

The Apple tool receives the password as a process argument during validation;
the script does not print the command or enable shell tracing. Run it on your
trusted Mac. The script does not publish a release or replace existing local
notarization profiles. CI creates its own `MCLEAN_NOTARY` profile in a temporary
keychain and deletes that keychain on completion.

If you need a new app-specific password, sign in yourself at
[Apple Account](https://account.apple.com/) → Sign-In and Security →
App-Specific Passwords. [Apple's instructions](https://support.apple.com/en-us/102654)
describe creation and revocation; two-factor authentication is required.

## Setting secrets via gh CLI

```bash
gh secret set BUILD_CERTIFICATE_BASE64 --repo maclifevn/MClean < ~/Desktop/MClean-secrets/MClean-DeveloperID.p12.b64
gh secret set P12_PASSWORD --repo maclifevn/MClean < ~/Desktop/MClean-secrets/P12_PASSWORD.txt
gh secret set KEYCHAIN_PASSWORD --repo maclifevn/MClean < ~/Desktop/MClean-secrets/KEYCHAIN_PASSWORD.txt
# Configure NOTARIZATION_APPLE_ID and NOTARIZATION_APP_PASSWORD interactively:
python3 scripts/setup-notarization.py
gh secret set SPARKLE_PRIVATE_KEY --repo maclifevn/MClean \
  < /Users/maclife/.codex/backups/MClean-sparkle-20261011-103249/sparkle-private-key.txt

# Optional: gh prompts for the token without displaying it.
gh secret set HOMEBREW_TAP_TOKEN --repo maclifevn/MClean
gh secret list --repo maclifevn/MClean
```

Before overwriting a secret, check `gh secret list` and keep its matching key and
password together in your secret manager. The production preparation already
configured four names; the commands for those names are examples for a new setup.

## Triggering a release

Dry run first (build + sign + notarize, no upload, no homebrew bump):

```bash
gh workflow run release.yml --repo maclifevn/MClean -f version=1.0.5 -f dry_run=true
gh run watch --repo maclifevn/MClean
```

Real release (after dry run is green):

```bash
gh workflow run release.yml --repo maclifevn/MClean -f version=1.0.5 -f dry_run=false
```

Publication requires `main`; preparation branches can run with `dry_run=true`.
Merge reviewed source first so the release and Homebrew bump use the intended revision.

## What ships

| Artifact | Purpose |
|----------|---------|
| `MClean-X.Y.Z.dmg` | Direct download link in release notes (signed + notarized + stapled) |
| `MClean-X.Y.Z.zip` | Homebrew and Sparkle archive (notarized + stapled `.app` inside, Ed25519 signature in appcast) |
| `appcast.xml` | Signed Sparkle feed; published at the stable `appcast` release after the versioned assets |

Both checksums land in `build/CHECKSUMS.md` and the GH release body.

## Troubleshooting #86 (`code or signature have been modified`)

Root causes that the pipeline guards against, that the previous manual
release path did not:

- Files modified after `codesign` (e.g. running `xcodegen` post-sign breaks the
  signature). The pipeline runs `xcodegen` before `archive` and never edits the
  bundle after the export step.
- Notarizing the `.app` but shipping a `.zip` made before the staple. The
  pipeline staples the `.app` first, then re-zips it. Order matters — Gatekeeper
  on first launch checks the stapled ticket on the `.app`, not the zip.
- Using `Apple Development` cert (default in `project.yml`) for distribution —
  the pipeline overrides with `Developer ID Application` at archive time.
- Skipping `--options=runtime` (no hardened runtime → notary rejects). Pipeline
  passes it via `OTHER_CODE_SIGN_FLAGS`.
- Universal-binary signing race where `lipo` is run after sign. The archive
  step builds universal in one pass via `ARCHS="arm64 x86_64"` so the codesign
  covers both slices atomically.
