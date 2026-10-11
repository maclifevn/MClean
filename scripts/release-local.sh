#!/usr/bin/env bash
#
# Local mirror of .github/workflows/release.yml. Use for emergency hotfixes
# when CI is unavailable. Requires:
#   - Developer ID Application identity in your login keychain
#   - notarytool keychain profile already stored, e.g.:
#       xcrun notarytool store-credentials AC_NOTARY \
#         --key ~/.appstoreconnect/private_keys/AuthKey_YOUR_KEY_ID.p8 \
#         --key-id YOUR_KEY_ID --issuer YOUR_ISSUER_ID
#   - xcodegen + create-dmg installed (brew install xcodegen create-dmg)
#
# Usage: scripts/release-local.sh <version> [notary_profile]
#        scripts/release-local.sh 2.2.0
#        scripts/release-local.sh 2.2.0 AC_NOTARY
#
set -euo pipefail

VERSION="${1:?Usage: $0 <version> [notary_profile]}"
[[ "${VERSION}" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || { echo 'Invalid version' >&2; exit 1; }
NOTARY_PROFILE="${2:-${MCLEAN_NOTARY_PROFILE:-AC_NOTARY}}"
SCHEME="MClean"
PROJECT="MClean.xcodeproj"
APP="build/export/MClean.app"
DMG="build/MClean-${VERSION}.dmg"
ZIP="build/MClean-${VERSION}.zip"

cd "$(dirname "$0")/.."

SIGN_ID="${MCLEAN_SIGN_ID:-}"
if [[ -z "${SIGN_ID}" ]]; then
  SIGN_ID=$(security find-identity -v -p codesigning | sed -nE 's/.*"(Developer ID Application:[^"]+)".*/\1/p' | head -n 1)
fi
if [[ -z "${SIGN_ID}" ]]; then
  echo "ERROR: no Developer ID Application identity found in the keychain" >&2
  exit 1
fi

TEAM_ID="${MCLEAN_TEAM_ID:-}"
if [[ -z "${TEAM_ID}" ]]; then
  TEAM_ID=$(printf '%s\n' "${SIGN_ID}" | sed -nE 's/.*\(([A-Z0-9]{10})\)$/\1/p')
fi
if [[ -z "${TEAM_ID}" ]]; then
  echo "ERROR: could not derive team ID from signing identity: ${SIGN_ID}" >&2
  exit 1
fi
PROJECT_TEAM=$(ruby -ryaml -e 'print YAML.load_file("project.yml").fetch("settings").fetch("base").fetch("DEVELOPMENT_TEAM")')
[[ "${TEAM_ID}" == "${PROJECT_TEAM}" ]] || { echo 'Signing team differs from project.yml' >&2; exit 1; }
echo "Using signing identity: ${SIGN_ID}"

PROJ_VERSION=$(grep -E '^\s*MARKETING_VERSION:' project.yml | sed -E 's/.*"([^"]+)".*/\1/')
if [[ "${PROJ_VERSION}" != "${VERSION}" ]]; then
  echo "ERROR: project.yml MARKETING_VERSION (${PROJ_VERSION}) != ${VERSION}" >&2
  exit 1
fi

echo "==> verify notarization credentials (profile: ${NOTARY_PROFILE})"
xcrun notarytool history --keychain-profile "${NOTARY_PROFILE}" --output-format json >/dev/null

rm -rf build
mkdir -p build

echo "==> xcodegen"
xcodegen generate

echo "==> Sparkle tools"
scripts/sparkle-tools.sh build/sparkle-tools

echo "==> archive"
xcodebuild \
  -project "${PROJECT}" \
  -scheme "${SCHEME}" \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath build/MClean.xcarchive \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="${SIGN_ID}" \
  DEVELOPMENT_TEAM="${TEAM_ID}" \
  OTHER_CODE_SIGN_FLAGS="--timestamp --options=runtime" \
  archive

echo "==> export"
cat > build/ExportOptions.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>${TEAM_ID}</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
</dict>
</plist>
PLIST

xcodebuild -exportArchive \
  -archivePath build/MClean.xcarchive \
  -exportPath build/export \
  -exportOptionsPlist build/ExportOptions.plist

echo "==> verify codesign"
codesign --verify --deep --strict --verbose=2 "${APP}"
codesign -dvv "${APP}" 2>&1 | grep -E "Identifier|TeamIdentifier|flags|Authority"
codesign -dvv "${APP}" 2>&1 | grep -q "flags=0x10000(runtime)" || { echo "Hardened runtime missing"; exit 1; }
lipo -archs "${APP}/Contents/MacOS/MClean"
for arch in arm64 x86_64; do
  lipo "${APP}/Contents/MacOS/MClean" -verify_arch "${arch}"
done

echo "==> notarize app zip (profile: ${NOTARY_PROFILE})"
ditto -c -k --keepParent --sequesterRsrc "${APP}" build/MClean-app.zip
xcrun notarytool submit build/MClean-app.zip \
  --keychain-profile "${NOTARY_PROFILE}" \
  --wait --timeout 30m
xcrun stapler staple "${APP}"
xcrun stapler validate "${APP}"
codesign --verify --deep --strict "${APP}"
spctl --assess --type execute --verbose=4 "${APP}"

echo "==> dmg"
create-dmg \
  --volname "MClean ${VERSION}" \
  --window-size 540 360 \
  --icon-size 100 \
  --icon "MClean.app" 140 180 \
  --hide-extension "MClean.app" \
  --app-drop-link 400 180 \
  --no-internet-enable \
  "${DMG}" \
  build/export/MClean.app
codesign --sign "${SIGN_ID}" --timestamp "${DMG}"

echo "==> notarize dmg"
xcrun notarytool submit "${DMG}" \
  --keychain-profile "${NOTARY_PROFILE}" \
  --wait --timeout 30m
xcrun stapler staple "${DMG}"
xcrun stapler validate "${DMG}"
spctl --assess --type install --verbose=4 "${DMG}"

echo "==> final zip with stapled app"
ditto -c -k --keepParent --sequesterRsrc "${APP}" "${ZIP}"

echo "==> signed Sparkle appcast"
mkdir -p build/previous-feed
HTTP_STATUS=$(curl --location --silent --show-error --retry 3 \
  --header 'Cache-Control: no-cache' --output build/previous-feed/appcast.xml --write-out '%{http_code}' \
  https://github.com/maclifevn/MClean/releases/download/appcast/appcast.xml)
if [[ "${HTTP_STATUS}" == 200 ]]; then
  scripts/generate-sparkle-appcast.sh "${ZIP}" build/appcast build/previous-feed/appcast.xml
elif [[ "${HTTP_STATUS}" == 404 ]]; then
  scripts/generate-sparkle-appcast.sh "${ZIP}" build/appcast
else
  echo "ERROR: previous appcast returned HTTP ${HTTP_STATUS}; refusing to overwrite update history" >&2
  exit 1
fi

DMG_SHA=$(shasum -a 256 "${DMG}" | awk '{print $1}')
ZIP_SHA=$(shasum -a 256 "${ZIP}" | awk '{print $1}')

echo ""
echo "===================="
echo "MClean ${VERSION} signed + notarized"
echo "===================="
echo "DMG: ${DMG}"
echo "  sha256: ${DMG_SHA}"
echo "ZIP: ${ZIP}"
echo "  sha256: ${ZIP_SHA}"
echo ""
echo "Next: gh release create v${VERSION} ${DMG} ${ZIP} --title \"MClean v${VERSION}\""
echo "Then: bump homebrew/mclean.rb sha256 to ${ZIP_SHA}"
echo "After uploading the versioned assets, upload build/appcast/appcast.xml to the appcast release."
