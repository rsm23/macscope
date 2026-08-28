#!/bin/zsh
set -euo pipefail

root_dir="${0:A:h:h}"
env_path="${MACSCOPE_ENV_FILE:-$root_dir/.env}"
mode="${1:-release}"
if [[ "$mode" != "release" && "$mode" != "--preflight" ]]; then
  echo "Usage: $0 [--preflight]" >&2
  exit 64
fi

source "$root_dir/Scripts/lib/load-dotenv.zsh"
macscope_load_dotenv "$env_path" \
  NOTARY_APPLE_ID \
  NOTARY_APP_PASSWORD \
  NOTARY_TEAM_ID \
  NOTARY_KEYCHAIN_PROFILE \
  DEVELOPER_ID_APPLICATION

required_variables=(NOTARY_APPLE_ID NOTARY_APP_PASSWORD NOTARY_TEAM_ID)
for variable_name in "${required_variables[@]}"; do
  if [[ -z "${(P)variable_name:-}" ]]; then
    echo "Required variable is missing from $env_path: $variable_name" >&2
    exit 78
  fi
done

profile_name="${NOTARY_KEYCHAIN_PROFILE:-MacScopeNotary}"
echo "Validating Apple notarization credentials and saving profile '$profile_name' to Keychain…"
xcrun notarytool store-credentials "$profile_name" \
  --apple-id "$NOTARY_APPLE_ID" \
  --password "$NOTARY_APP_PASSWORD" \
  --team-id "$NOTARY_TEAM_ID" \
  --validate

if [[ -z "${DEVELOPER_ID_APPLICATION:-}" ]]; then
  identities="$(security find-identity -v -p codesigning)"
  matching_identities=("${(@f)$(printf '%s\n' "$identities" | sed -nE \
    "/Developer ID Application:.*\\(${NOTARY_TEAM_ID}\\)/s/^[[:space:]]*[0-9]+\\) [0-9A-F]+ \\\"([^\\\"]+)\\\".*$/\\1/p")}")
  matching_identities=("${matching_identities[@]:#}")
  if (( ${#matching_identities[@]} == 1 )); then
    DEVELOPER_ID_APPLICATION="${matching_identities[1]}"
    export DEVELOPER_ID_APPLICATION
  elif (( ${#matching_identities[@]} == 0 )); then
    echo "No Developer ID Application identity for team $NOTARY_TEAM_ID is installed in Keychain." >&2
    echo "Create one as the Apple Developer Account Holder, or import a .p12 containing the certificate and private key." >&2
    exit 77
  else
    echo "Multiple Developer ID Application identities match team $NOTARY_TEAM_ID." >&2
    echo "Set DEVELOPER_ID_APPLICATION in $env_path to the exact Keychain identity name." >&2
    exit 77
  fi
fi

if ! security find-identity -v -p codesigning | grep -Fq "\"$DEVELOPER_ID_APPLICATION\""; then
  echo "The configured Developer ID Application identity is not valid in the current Keychain." >&2
  exit 77
fi

echo "Developer ID signing identity is available for team $NOTARY_TEAM_ID."
if [[ "$mode" == "--preflight" ]]; then
  echo "Local signing and notarization preflight passed."
  exit 0
fi

cd "$root_dir"
./Scripts/build-app.sh

signed_team="$(codesign -dv --verbose=4 dist/MacScope.app 2>&1 | sed -n 's/^TeamIdentifier=//p')"
if [[ "$signed_team" != "$NOTARY_TEAM_ID" ]]; then
  echo "Signed app TeamIdentifier '$signed_team' does not match NOTARY_TEAM_ID." >&2
  exit 77
fi

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
archive_path="$root_dir/dist/MacScope-${version}-arm64.zip"
NOTARY_KEYCHAIN_PROFILE="$profile_name" \
  ./Scripts/ci/notarize-app.sh "$root_dir/dist/MacScope.app" "$archive_path"

echo "Release ready: $archive_path"
