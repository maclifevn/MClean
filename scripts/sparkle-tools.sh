#!/usr/bin/env bash
# Fetch the same pinned Sparkle distribution used by project.yml.
set -euo pipefail
SPARKLE_VERSION=2.10.0
SPARKLE_SHA256=c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c
DESTINATION="${1:?Usage: $0 <tools-directory>}"
mkdir -p "${DESTINATION}"
DESTINATION=$(cd "${DESTINATION}" && pwd)
ARCHIVE="${DESTINATION}/Sparkle-${SPARKLE_VERSION}.tar.xz"
curl --fail --location --silent --show-error --retry 3 \
  "https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz" \
  --output "${ARCHIVE}"
printf '%s  %s\n' "${SPARKLE_SHA256}" "${ARCHIVE}" | shasum -a 256 --check
mkdir -p "${DESTINATION}/Sparkle"
tar -xJf "${ARCHIVE}" -C "${DESTINATION}/Sparkle"
