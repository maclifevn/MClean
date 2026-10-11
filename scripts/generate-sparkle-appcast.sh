#!/usr/bin/env bash
# Sign the final (already notarized/stapled) ZIP and generate a signed appcast.
# No private key is accepted as a command argument or printed to the log.
set -euo pipefail
ARCHIVE="${1:?Usage: $0 <final-zip> <output-directory> [previous-appcast]}"
OUTPUT="${2:?Usage: $0 <final-zip> <output-directory> [previous-appcast]}"
PREVIOUS="${3:-}"
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
SPARKLE_TOOLS_DIR="${SPARKLE_TOOLS_DIR:-${SCRIPT_DIR}/../build/sparkle-tools/Sparkle}"
SIGN_UPDATE="${SPARKLE_TOOLS_DIR}/bin/sign_update"
GENERATE_APPCAST="${SPARKLE_TOOLS_DIR}/bin/generate_appcast"
[[ -f "${ARCHIVE}" && -x "${SIGN_UPDATE}" && -x "${GENERATE_APPCAST}" ]] || {
  echo 'Missing ZIP or Sparkle tools; run scripts/sparkle-tools.sh first.' >&2; exit 1;
}
ARCHIVE=$(cd "$(dirname "${ARCHIVE}")" && pwd)/$(basename "${ARCHIVE}")
mkdir -p "${OUTPUT}"
OUTPUT=$(cd "${OUTPUT}" && pwd)
TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/mclean-appcast.XXXXXX")
trap 'rm -rf "${TEMP_DIR}"' EXIT
# Limit extraction to our trusted, locally built archive. Sparkle independently
# verifies the downloaded archive before extraction on users' machines.
ditto -x -k "${ARCHIVE}" "${TEMP_DIR}"
PLIST="${TEMP_DIR}/MClean.app/Contents/Info.plist"
codesign --verify --deep --strict "${TEMP_DIR}/MClean.app"
EXPECTED_PLIST="${SCRIPT_DIR}/../MClean/Info.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${PLIST}")" == com.maclife.mclean ]] || {
  echo 'Refusing to publish a QA or foreign app bundle.' >&2; exit 1;
}
for key in SUFeedURL SUPublicEDKey SURequireSignedFeed SUVerifyUpdateBeforeExtraction SUSignedFeedFailureExpirationInterval; do
  [[ "$(/usr/libexec/PlistBuddy -c "Print :${key}" "${PLIST}")" == "$(/usr/libexec/PlistBuddy -c "Print :${key}" "${EXPECTED_PLIST}")" ]] || {
    echo "Archive ${key} does not match production configuration." >&2; exit 1;
  }
done
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${PLIST}")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${PLIST}")
[[ "${VERSION}" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ && "${BUILD}" =~ ^[1-9][0-9]*$ ]] || {
  echo 'Release version and build must be numeric.' >&2; exit 1;
}
KEY_ARGS=(--account com.maclife.mclean)
if [[ -n "${SPARKLE_PRIVATE_KEY_FILE:-}" ]]; then
  [[ -f "${SPARKLE_PRIVATE_KEY_FILE}" ]] || { echo 'Missing Sparkle private key file.' >&2; exit 1; }
  KEY_ARGS=(--ed-key-file "${SPARKLE_PRIVATE_KEY_FILE}")
fi
STAGING="${TEMP_DIR}/feed"
mkdir -p "${STAGING}"
if [[ -z "${PREVIOUS}" && -f "${OUTPUT}/appcast.xml" ]]; then
  PREVIOUS="${OUTPUT}/appcast.xml"
fi
if [[ -n "${PREVIOUS}" ]]; then
  [[ -f "${PREVIOUS}" ]] || { echo 'Previous appcast file not found.' >&2; exit 1; }
  # Never silently overwrite history after a network/signature problem.
  "${SIGN_UPDATE}" "${KEY_ARGS[@]}" --verify "${PREVIOUS}"
  python3 "${SCRIPT_DIR}/validate-appcast.py" "${PREVIOUS}" --next-build "${BUILD}"
  cp "${PREVIOUS}" "${STAGING}/appcast.xml"
fi
cp "${ARCHIVE}" "${STAGING}/"
"${GENERATE_APPCAST}" "${KEY_ARGS[@]}" \
  --maximum-deltas 0 --maximum-versions 5 \
  --download-url-prefix "https://github.com/maclifevn/MClean/releases/download/v${VERSION}/" \
  --link 'https://github.com/maclifevn/MClean/releases' \
  "${STAGING}"
python3 "${SCRIPT_DIR}/validate-appcast.py" "${STAGING}/appcast.xml" --archive "${ARCHIVE}" --build "${BUILD}" --version "${VERSION}"
"${SIGN_UPDATE}" "${KEY_ARGS[@]}" --verify "${STAGING}/appcast.xml"
ARCHIVE_SIGNATURE=$(python3 - "${STAGING}/appcast.xml" "${BUILD}" <<'PY'
import sys
import xml.etree.ElementTree as ET
ns = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
for item in ET.parse(sys.argv[1]).findall('./channel/item'):
    if item.findtext(ns + 'version') == sys.argv[2]:
        print(item.find('enclosure').attrib[ns + 'edSignature'])
        break
PY
)
"${SIGN_UPDATE}" "${KEY_ARGS[@]}" --verify "${ARCHIVE}" "${ARCHIVE_SIGNATURE}"
if [[ "${ARCHIVE}" != "${OUTPUT}/$(basename "${ARCHIVE}")" ]]; then
  cp "${ARCHIVE}" "${OUTPUT}/"
fi
cp "${STAGING}/appcast.xml" "${OUTPUT}/.appcast.xml.tmp"
mv "${OUTPUT}/.appcast.xml.tmp" "${OUTPUT}/appcast.xml"
echo "Signed appcast ready: ${OUTPUT}/appcast.xml (version ${VERSION}, build ${BUILD})"
