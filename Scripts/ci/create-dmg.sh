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

if [[ "$dmg_path" != *.dmg ]]; then
  echo "Disk image path must end in .dmg: $dmg_path" >&2
  exit 64
fi

staging_dir="$(mktemp -d "${TMPDIR:-/tmp}/macscope-dmg.XXXXXX")"
cleanup() {
  rm -rf "$staging_dir"
}
trap cleanup EXIT

mkdir -p "${dmg_path:h}"
rm -f "$dmg_path" "$dmg_path.sha256"

ditto "$app_path" "$staging_dir/${app_path:t}"
ln -s /Applications "$staging_dir/Applications"

hdiutil create \
  -volname "MacScope" \
  -srcfolder "$staging_dir" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -ov \
  "$dmg_path"

(cd "${dmg_path:h}" && shasum -a 256 "${dmg_path:t}") > "$dmg_path.sha256"
echo "$dmg_path"
