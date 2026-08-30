#!/bin/zsh
set -euo pipefail

if (( $# != 2 )); then
  echo "Usage: $0 /path/to/MacScope.app /path/to/MacScope.dmg" >&2
  exit 64
fi

app_path="${1:A}"
dmg_path="${2:A}"

if [[ ! -d "$app_path" || "$app_path" != *.app ]]; then
  echo "Application bundle not found: $app_path" >&2
  exit 66
fi

if [[ ! -f "$dmg_path" || "$dmg_path" != *.dmg ]]; then
  echo "Disk image not found: $dmg_path" >&2
  exit 66
fi

fail() {
  echo "Distribution verification failed: $1" >&2
  exit 65
}

signature_details() {
  codesign --display --verbose=4 "$1" 2>&1
}

team_identifier() {
  signature_details "$1" | sed -n 's/^TeamIdentifier=//p'
}

cdhash() {
  signature_details "$1" | sed -n 's/^CDHash=//p'
}

require_developer_id_signature() {
  local artifact_path="$1"
  local details
  details="$(signature_details "$artifact_path")"

  [[ "$details" == *"Authority=Developer ID Application:"* ]] || \
    fail "$artifact_path is not signed with a Developer ID Application certificate."

  local team
  team="$(printf '%s\n' "$details" | sed -n 's/^TeamIdentifier=//p')"
  [[ -n "$team" && "$team" != "not set" ]] || \
    fail "$artifact_path has no signing TeamIdentifier."
}

codesign --verify --deep --strict --verbose=2 "$app_path"
require_developer_id_signature "$app_path"
app_signature_details="$(signature_details "$app_path")"
[[ "$app_signature_details" == *"(runtime)"* ]] || \
  fail "$app_path does not enable the hardened runtime."

xcrun stapler validate "$app_path"
app_assessment="$(spctl --assess --type execute --verbose=4 "$app_path" 2>&1)" || \
  fail "Gatekeeper rejected $app_path: $app_assessment"
[[ "$app_assessment" == *"source=Notarized Developer ID"* ]] || \
  fail "Gatekeeper did not identify $app_path as a notarized Developer ID build."

codesign --verify --verbose=2 "$dmg_path"
require_developer_id_signature "$dmg_path"

app_team="$(team_identifier "$app_path")"
dmg_team="$(team_identifier "$dmg_path")"
[[ "$dmg_team" == "$app_team" ]] || \
  fail "The app TeamIdentifier ($app_team) does not match the DMG TeamIdentifier ($dmg_team)."

xcrun stapler validate "$dmg_path"
dmg_assessment="$(spctl --assess --type open --context context:primary-signature --verbose=4 "$dmg_path" 2>&1)" || \
  fail "Gatekeeper rejected $dmg_path: $dmg_assessment"
[[ "$dmg_assessment" == *"source=Notarized Developer ID"* ]] || \
  fail "Gatekeeper did not identify $dmg_path as a notarized Developer ID build."

mount_point=""
detach_disk_image() {
  if [[ -n "$mount_point" ]]; then
    hdiutil detach "$mount_point" >/dev/null 2>&1 || true
  fi
}
trap detach_disk_image EXIT

mount_output="$(hdiutil attach -nobrowse -readonly "$dmg_path")"
mount_point="$(printf '%s\n' "$mount_output" | sed -n 's#^.*\(/Volumes/.*\)$#\1#p' | tail -1)"
[[ -n "$mount_point" ]] || fail "Could not determine the mounted DMG path."

embedded_app="$mount_point/${app_path:t}"
[[ -d "$embedded_app" ]] || fail "The DMG does not contain ${app_path:t}."
codesign --verify --deep --strict --verbose=2 "$embedded_app"

embedded_team="$(team_identifier "$embedded_app")"
[[ "$embedded_team" == "$app_team" ]] || \
  fail "The app inside the DMG has a different TeamIdentifier."

embedded_cdhash="$(cdhash "$embedded_app")"
app_cdhash="$(cdhash "$app_path")"
[[ "$embedded_cdhash" == "$app_cdhash" ]] || \
  fail "The app inside the DMG does not match the verified app bundle."

embedded_assessment="$(spctl --assess --type execute --verbose=4 "$embedded_app" 2>&1)" || \
  fail "Gatekeeper rejected the app inside the DMG: $embedded_assessment"

echo "Verified Developer ID signatures, notarization tickets, Gatekeeper acceptance, and DMG contents."
