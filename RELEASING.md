# Releasing Maya

How to package Maya into a notarized `.dmg`, publish it, and keep the
website's download button pointing at the latest build.

There are two ways to produce a release: **locally** on your Mac, or
**automatically** through GitHub Actions. They both run the same
[`scripts/build-release.sh`](scripts/build-release.sh) and produce an
identical `build/Maya.dmg`.

---

## What "packaging" means here

Because Maya is distributed **outside the Mac App Store**, the `.app` must be:

1. **Signed** with a *Developer ID Application* certificate.
2. **Notarized** by Apple (an automated malware scan).
3. **Stapled** so the notarization ticket travels inside the app.
4. **Packaged** into a `.dmg` for download.

Skip any of these and macOS Gatekeeper blocks the app with an
"unidentified developer" / "Apple could not verify" warning. The script
does all four.

---

## One-time setup

### 1. Developer ID Application certificate

You need a *Developer ID Application* certificate (your paid Apple
Developer Program membership unlocks it):

- **Xcode** ▸ Settings ▸ Accounts ▸ select your team ▸ **Manage Certificates**
  ▸ **+** ▸ *Developer ID Application*.

Confirm it is installed:

```bash
security find-identity -v -p codesigning
# → should list:  Developer ID Application: Your Name (4W9XHUWSFR)
```

### 2. App-specific password (for notarization)

Notarization can't use your normal Apple ID password. Create an
app-specific password at <https://appleid.apple.com> ▸ Sign-In & Security
▸ App-Specific Passwords.

### 3. `create-dmg` (local builds only)

The packaging step uses [`create-dmg`](https://github.com/create-dmg/create-dmg)
to lay out the styled disk-image window:

```bash
brew install create-dmg
```

GitHub Actions installs it automatically, so this is only needed for
local releases.

---

## Option A — Release locally

Store your notarization credentials once in the keychain:

```bash
xcrun notarytool store-credentials maya-notary \
  --apple-id "you@example.com" \
  --team-id 4W9XHUWSFR \
  --password "abcd-efgh-ijkl-mnop"   # the app-specific password
```

Then build:

```bash
NOTARY_PROFILE=maya-notary ./scripts/build-release.sh
```

The result is `build/Maya.dmg`. Create the GitHub release with the
[`gh`](https://cli.github.com) CLI:

```bash
gh release create v1.0.0 build/Maya.dmg --title "Maya v1.0.0" --generate-notes
```

> The DMG asset **must stay named `Maya.dmg`** — the website's download
> button relies on that exact name (see *Download URL* below).

---

## Option B — Release automatically (GitHub Actions)

[`.github/workflows/release.yml`](.github/workflows/release.yml) builds,
signs, notarizes and publishes a release every time you push a version
tag.

### Add these repository secrets

*GitHub repo ▸ Settings ▸ Secrets and variables ▸ Actions ▸ New secret*

| Secret | Value |
|---|---|
| `DEVELOPER_ID_P12` | Your *Developer ID Application* cert + private key, exported as `.p12`, then base64-encoded (see below). |
| `DEVELOPER_ID_P12_PASSWORD` | The password you set when exporting the `.p12`. |
| `KEYCHAIN_PASSWORD` | Any random string — used for the temporary CI keychain. |
| `NOTARY_APPLE_ID` | Your Apple ID email. |
| `NOTARY_PASSWORD` | The app-specific password from setup step 2. |
| `NOTARY_TEAM_ID` | `4W9XHUWSFR` |

**Exporting the `.p12`:** open **Keychain Access**, find *Developer ID
Application: …*, expand it, select **both** the certificate **and** its
private key, right-click ▸ *Export 2 items* ▸ save as `.p12` with a
password. Then base64-encode it:

```bash
base64 -i Certificates.p12 | pbcopy   # paste into the DEVELOPER_ID_P12 secret
```

### Cut a release

```bash
git tag v1.0.0
git push origin v1.0.0
```

The workflow runs, and a new release with `Maya.dmg` attached appears
under **Releases**. You can also trigger it manually from the **Actions**
tab (*Run workflow*) to test — that build uploads the DMG as an artifact
but does not publish a release.

> **Runner note:** the workflow targets `runs-on: macos-26` with
> Xcode 26.5, because Maya needs the macOS 26.3 SDK. If that runner image
> isn't available on your account, switch to the newest macOS runner you
> have and adjust the *Select Xcode* step.

---

## The website download button

The landing page in [`docs/`](docs/) (served at
<https://ronaldo-avalos.github.io/Maya/>) links to:

```
https://github.com/ronaldo-avalos/Maya/releases/latest/download/Maya.dmg
```

GitHub resolves `releases/latest/download/<asset>` to the asset of that
name in the **most recent release**. So every new release with a
`Maya.dmg` attached updates the download automatically — no edits to the
website needed.

### Enabling GitHub Pages (one-time)

GitHub repo ▸ **Settings** ▸ **Pages** ▸ Source: **Deploy from a branch**
▸ Branch: **main**, folder: **/docs** ▸ Save. The site goes live at
`https://ronaldo-avalos.github.io/Maya/` within a minute.

---

## Versioning

Bump `MARKETING_VERSION` (and optionally `CURRENT_PROJECT_VERSION`) in the
Xcode project before tagging, and keep the git tag in sync — e.g. tag
`v1.1.0` ⇄ `MARKETING_VERSION = 1.1.0`.

## Troubleshooting

- **`No 'Developer ID Application' certificate found`** — the cert isn't
  in the keychain. Re-do setup step 1, or import the `.p12`.
- **Notarization `Invalid` status** — run
  `xcrun notarytool log <submission-id> --keychain-profile maya-notary`
  to see exactly which file failed (usually an unsigned binary or a
  missing hardened-runtime flag).
- **`xcodebuild: requires Xcode`** — you have only the Command Line
  Tools. Install full Xcode and run
  `sudo xcode-select -s /Applications/Xcode.app`.
