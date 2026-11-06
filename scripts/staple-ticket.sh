#!/usr/bin/env bash
set -euo pipefail

artifact="${1:?Usage: staple-ticket.sh <notarized-app-or-dmg>}"

# CloudKit can temporarily fail to deliver a ticket after notarytool accepts it.
for delay in 0 5 10 20 40; do
  if [[ "${delay}" != 0 ]]; then
    sleep "${delay}"
  fi
  if xcrun stapler staple "${artifact}" && xcrun stapler validate "${artifact}"; then
    exit 0
  fi
done

printf 'Could not staple and validate a notarization ticket for %s\n' "${artifact}" >&2
exit 1
