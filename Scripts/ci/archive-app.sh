#!/bin/zsh
set -euo pipefail

if (( $# != 2 )); then
  echo "Usage: $0 /path/to/MacScope.app /path/to/MacScope.zip" >&2
  exit 64
fi

app_path="$1"
archive_path="$2"

if [[ ! -d "$app_path" || "$app_path" != *.app ]]; then
  echo "Application bundle not found: $app_path" >&2
  exit 66
fi

if [[ "$archive_path" != *.zip ]]; then
  echo "Archive path must end in .zip: $archive_path" >&2
  exit 64
fi

mkdir -p "${archive_path:h}"
rm -f "$archive_path" "$archive_path.sha256"

ditto -c -k --sequesterRsrc --keepParent "$app_path" "$archive_path"
shasum -a 256 "$archive_path" > "$archive_path.sha256"

echo "$archive_path"
