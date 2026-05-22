#!/usr/bin/env bash
#
# build-release.sh — Build, sign, notarize and package Maya into a .dmg
# ---------------------------------------------------------------------
# Produces a notarized, Gatekeeper-clean  build/Maya.dmg  that anyone can
# download and open with a normal double-click.
#
# Requirements
#   • Full Xcode 26.5+ (not just Command Line Tools)
#   • create-dmg          (brew install create-dmg)
#   • A "Developer ID Application" certificate in your login keychain
#     (Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates ▸ + )
#
# Notarization credentials — provide ONE of these sets of env vars:
#
#   A) A stored notarytool profile (recommended for local use). Create once:
#        xcrun notarytool store-credentials maya-notary \
#          --apple-id "you@example.com" --team-id 4W9XHUWSFR \
#          --password "<app-specific-password>"
#      then:  NOTARY_PROFILE=maya-notary ./scripts/build-release.sh
#
#   B) Apple ID + app-specific password (used by CI):
#        NOTARY_APPLE_ID, NOTARY_PASSWORD  [, NOTARY_TEAM_ID]
#
#   C) App Store Connect API key:
#        NOTARY_KEY_PATH, NOTARY_KEY_ID, NOTARY_ISSUER_ID
#
set -euo pipefail
cd "$(dirname "$0")/.."

# ---- Config -----------------------------------------------------------
PROJECT="Maya.xcodeproj"
SCHEME="Maya"
CONFIGURATION="Release"
APP_NAME="Maya"
TEAM_ID="${NOTARY_TEAM_ID:-4W9XHUWSFR}"
SIGN_IDENTITY="Developer ID Application"

BUILD_DIR="build"
ARCHIVE_PATH="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
APP_PATH="$EXPORT_DIR/$APP_NAME.app"
ZIP_PATH="$BUILD_DIR/$APP_NAME.zip"
DMG_STAGE="$BUILD_DIR/dmg"
DMG_PATH="$BUILD_DIR/$APP_NAME.dmg"
DMG_BG_1X="scripts/dmg-assets/background.png"
DMG_BG_2X="scripts/dmg-assets/background@2x.png"
DMG_BG_TIFF="$BUILD_DIR/dmg-background.tiff"
EXPORT_OPTIONS="scripts/ExportOptions.plist"
# -----------------------------------------------------------------------

step() { printf '\n\033[1;35m▸ %s\033[0m\n' "$1"; }
fail() { printf '\033[1;31m✗ %s\033[0m\n' "$1" >&2; exit 1; }

# ---- Pre-flight -------------------------------------------------------
xcodebuild -version >/dev/null 2>&1 || fail \
  "Full Xcode required. Run: sudo xcode-select -s /Applications/Xcode.app"
command -v create-dmg >/dev/null 2>&1 || fail \
  "create-dmg not found. Install it with:  brew install create-dmg"
security find-identity -v -p codesigning | grep -q "$SIGN_IDENTITY" || fail \
  "No '$SIGN_IDENTITY' certificate found in your keychain."

# Resolve notarization credentials once — fail fast before the long archive,
# and reuse the same flags to notarize both the app and the .dmg.
NOTARY_CRED=()
if   [[ -n "${NOTARY_PROFILE:-}"  ]]; then
  NOTARY_CRED=(--keychain-profile "$NOTARY_PROFILE")
elif [[ -n "${NOTARY_KEY_PATH:-}" ]]; then
  NOTARY_CRED=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
elif [[ -n "${NOTARY_APPLE_ID:-}" ]]; then
  NOTARY_CRED=(--apple-id "$NOTARY_APPLE_ID" --password "$NOTARY_PASSWORD" --team-id "$TEAM_ID")
else
  fail "No notarization credentials set — see the header of this script."
fi
notarize() { xcrun notarytool submit "$1" --wait "${NOTARY_CRED[@]}"; }

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# ---- 1. Archive (signed with Developer ID) ----------------------------
step "Archiving ($CONFIGURATION)…"
xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -archivePath "$ARCHIVE_PATH" \
  -destination "generic/platform=macOS" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
  DEVELOPMENT_TEAM="$TEAM_ID"

# ---- 2. Export the .app -----------------------------------------------
step "Exporting signed app…"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportOptionsPlist "$EXPORT_OPTIONS" \
  -exportPath "$EXPORT_DIR"
[[ -d "$APP_PATH" ]] || fail "Export failed: $APP_PATH not found"

# ---- 3. Notarize the app ----------------------------------------------
step "Submitting app to Apple notary service (this can take a few minutes)…"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"
notarize "$ZIP_PATH"

# ---- 4. Staple the ticket onto the app --------------------------------
step "Stapling notarization ticket…"
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"
spctl --assess --type execute --verbose=2 "$APP_PATH"

# ---- 5. Package into a styled .dmg ------------------------------------
# create-dmg lays out the classic "drag the app onto Applications" window
# with a custom background. tiffutil bundles the @1x + @2x backgrounds
# into one multi-resolution image so the window stays crisp on Retina.
step "Building $APP_NAME.dmg…"
tiffutil -cathidpicheck "$DMG_BG_1X" "$DMG_BG_2X" -out "$DMG_BG_TIFF"

rm -rf "$DMG_STAGE"
mkdir -p "$DMG_STAGE"
cp -R "$APP_PATH" "$DMG_STAGE/"
rm -f "$DMG_PATH"

create_status=0
create-dmg \
  --volname "$APP_NAME" \
  --background "$DMG_BG_TIFF" \
  --window-pos 200 120 \
  --window-size 660 400 \
  --icon-size 128 \
  --icon "$APP_NAME.app" 180 195 \
  --app-drop-link 480 195 \
  --hide-extension "$APP_NAME.app" \
  --no-internet-enable \
  "$DMG_PATH" \
  "$DMG_STAGE" || create_status=$?
[[ -f "$DMG_PATH" ]] || fail "create-dmg did not produce $DMG_PATH (exit $create_status)"
[[ $create_status -eq 0 ]] || \
  printf '\033[1;33m⚠ create-dmg exited %s but produced the .dmg — continuing.\033[0m\n' "$create_status"

# ---- 6. Sign, notarize and staple the .dmg ----------------------------
# The app inside is already notarized+stapled, but the .dmg container must
# be signed and notarized too — otherwise a freshly downloaded .dmg trips
# Gatekeeper ("Apple could not verify…") the moment the user double-clicks
# it. Signing the container (not just the app) is what lets `spctl` verify
# the result; a disk image is assessed with --type open, not install.
step "Signing the .dmg…"
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG_PATH"

step "Notarizing the .dmg…"
notarize "$DMG_PATH"
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG_PATH"

step "Done → $DMG_PATH"
ls -lh "$DMG_PATH"
