#!/bin/zsh
set -euo pipefail

if (( $# != 1 )); then
  echo "Usage: $0 /path/to/MacScope.dmg" >&2
  exit 64
fi

dmg_path="${1:A}"
if [[ ! -f "$dmg_path" || "$dmg_path" != *.dmg ]]; then
  echo "Disk image not found: $dmg_path" >&2
  exit 66
fi

runner_temp="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
api_key_path=""
result_path="${dmg_path:h}/dmg-notarization-result.json"
log_path="${dmg_path:h}/dmg-notarization-log.json"
credential_arguments=()

if [[ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
  credential_arguments=(--keychain-profile "$NOTARY_KEYCHAIN_PROFILE")
elif [[ -n "${ASC_PRIVATE_KEY_BASE64:-}" && -n "${ASC_KEY_ID:-}" && -n "${ASC_ISSUER_ID:-}" ]]; then
  api_key_path="$runner_temp/AuthKey_${ASC_KEY_ID}.p8"
  printf '%s' "$ASC_PRIVATE_KEY_BASE64" | base64 --decode > "$api_key_path"
  chmod 600 "$api_key_path"
  credential_arguments=(--key "$api_key_path" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID")
elif [[ -n "${NOTARY_APPLE_ID:-}" && -n "${NOTARY_APP_PASSWORD:-}" && -n "${NOTARY_TEAM_ID:-}" ]]; then
  credential_arguments=(
    --apple-id "$NOTARY_APPLE_ID"
    --password "$NOTARY_APP_PASSWORD"
    --team-id "$NOTARY_TEAM_ID"
  )
else
  echo "Notarization credentials are missing." >&2
  echo "Set NOTARY_KEYCHAIN_PROFILE, Apple ID notarization variables, or App Store Connect API key variables." >&2
  exit 78
fi

cleanup() {
  [[ -z "$api_key_path" ]] || rm -f "$api_key_path"
}
trap cleanup EXIT

mkdir -p "${dmg_path:h}"
[[ -z "$api_key_path" ]] || rm -f "$api_key_path"
rm -f "$result_path" "$log_path"

codesign --verify --verbose=2 "$dmg_path"

set +e
xcrun notarytool submit "$dmg_path" \
  "${credential_arguments[@]}" \
  --wait \
  --timeout 30m \
  --output-format json > "$result_path"
submit_status=$?
set -e

cat "$result_path"
submission_id="$(plutil -extract id raw -o - "$result_path" 2>/dev/null || true)"
notarization_status="$(plutil -extract status raw -o - "$result_path" 2>/dev/null || true)"

if [[ -n "$submission_id" ]]; then
  xcrun notarytool log "$submission_id" \
    "${credential_arguments[@]}" \
    "$log_path" || true
fi

if (( submit_status != 0 )) || [[ "$notarization_status" != "Accepted" ]]; then
  echo "DMG notarization was not accepted. See $result_path and $log_path." >&2
  exit 65
fi

xcrun stapler staple "$dmg_path"
xcrun stapler validate "$dmg_path"
spctl --assess --type open --context context:primary-signature --verbose=4 "$dmg_path"

(cd "${dmg_path:h}" && shasum -a 256 "${dmg_path:t}") > "$dmg_path.sha256"
echo "Notarized and stapled $dmg_path"
