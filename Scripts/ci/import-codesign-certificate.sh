#!/bin/zsh
set -euo pipefail

required_variables=(
  MACOS_CERTIFICATE_P12
  MACOS_CERTIFICATE_PASSWORD
  DEVELOPER_ID_APPLICATION
)

for variable_name in "${required_variables[@]}"; do
  if [[ -z "${(P)variable_name:-}" ]]; then
    echo "Required environment variable is missing: $variable_name" >&2
    exit 78
  fi
done

runner_temp="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
keychain_path="$runner_temp/macscope-signing.keychain-db"
certificate_path="$runner_temp/macscope-developer-id.p12"
keychain_password="$(openssl rand -hex 24)"

cleanup_certificate() {
  rm -f "$certificate_path"
}
trap cleanup_certificate EXIT

rm -f "$keychain_path"
printf '%s' "$MACOS_CERTIFICATE_P12" | base64 --decode > "$certificate_path"
chmod 600 "$certificate_path"

security create-keychain -p "$keychain_password" "$keychain_path"
security set-keychain-settings -lut 21600 "$keychain_path"
security unlock-keychain -p "$keychain_password" "$keychain_path"
security import "$certificate_path" \
  -k "$keychain_path" \
  -P "$MACOS_CERTIFICATE_PASSWORD" \
  -A \
  -t cert \
  -f pkcs12
security set-key-partition-list \
  -S apple-tool:,apple: \
  -s \
  -k "$keychain_password" \
  "$keychain_path"
security list-keychains -d user -s "$keychain_path"
security default-keychain -d user -s "$keychain_path"

identities="$(security find-identity -v -p codesigning "$keychain_path")"
if [[ "$identities" != *"$DEVELOPER_ID_APPLICATION"* ]]; then
  echo "The imported keychain does not contain the requested Developer ID identity." >&2
  echo "$identities" >&2
  exit 77
fi

if [[ -n "${GITHUB_ENV:-}" ]]; then
  echo "MACOS_CI_KEYCHAIN=$keychain_path" >> "$GITHUB_ENV"
else
  echo "MACOS_CI_KEYCHAIN=$keychain_path"
fi

echo "Imported Developer ID identity into an ephemeral keychain."
