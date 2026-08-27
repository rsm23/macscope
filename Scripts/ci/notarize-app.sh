#!/bin/zsh
set -euo pipefail

if (( $# != 2 )); then
  echo "Usage: $0 /path/to/MacScope.app /path/to/final.zip" >&2
  exit 64
fi

app_path="$1"
archive_path="$2"

required_variables=(ASC_PRIVATE_KEY_BASE64 ASC_KEY_ID ASC_ISSUER_ID)
for variable_name in "${required_variables[@]}"; do
  if [[ -z "${(P)variable_name:-}" ]]; then
    echo "Required environment variable is missing: $variable_name" >&2
    exit 78
  fi
done

if [[ ! -d "$app_path" || "$app_path" != *.app ]]; then
  echo "Application bundle not found: $app_path" >&2
  exit 66
fi

runner_temp="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
api_key_path="$runner_temp/AuthKey_${ASC_KEY_ID}.p8"
submission_archive="$runner_temp/MacScope-notarization.zip"
result_path="${archive_path:h}/notarization-result.json"
log_path="${archive_path:h}/notarization-log.json"

cleanup() {
  rm -f "$api_key_path" "$submission_archive"
}
trap cleanup EXIT

mkdir -p "${archive_path:h}"
rm -f "$api_key_path" "$submission_archive" "$result_path" "$log_path"
printf '%s' "$ASC_PRIVATE_KEY_BASE64" | base64 --decode > "$api_key_path"
chmod 600 "$api_key_path"

codesign --verify --deep --strict --verbose=2 "$app_path"
ditto -c -k --sequesterRsrc --keepParent "$app_path" "$submission_archive"

set +e
xcrun notarytool submit "$submission_archive" \
  --key "$api_key_path" \
  --key-id "$ASC_KEY_ID" \
  --issuer "$ASC_ISSUER_ID" \
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
    --key "$api_key_path" \
    --key-id "$ASC_KEY_ID" \
    --issuer "$ASC_ISSUER_ID" \
    "$log_path" || true
fi

if (( submit_status != 0 )) || [[ "$notarization_status" != "Accepted" ]]; then
  echo "Notarization was not accepted. See $result_path and $log_path." >&2
  exit 65
fi

xcrun stapler staple "$app_path"
xcrun stapler validate "$app_path"
spctl --assess --type execute --verbose=4 "$app_path"

"${0:A:h}/archive-app.sh" "$app_path" "$archive_path"
echo "Notarized and packaged $archive_path"
