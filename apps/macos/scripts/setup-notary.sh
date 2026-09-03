#!/usr/bin/env bash
# One-time: store App Store Connect credentials for notarytool in the keychain.
#
# Create an app-specific password at https://appleid.apple.com (name it "Oat notary"),
# then run this and enter your Apple ID email when prompted.
set -euo pipefail

PROFILE="${NOTARY_PROFILE:-oat-notary}"
TEAM_ID="${NOTARY_TEAM_ID:-UBWBPNVBAN}"

echo "Storing notary credentials as keychain profile '${PROFILE}' (team ${TEAM_ID})."
echo "You will be prompted for your Apple ID and an app-specific password."
echo

xcrun notarytool store-credentials "$PROFILE" \
  --team-id "$TEAM_ID"

echo
echo "Done. Release with: ./apps/macos/scripts/release.sh"
