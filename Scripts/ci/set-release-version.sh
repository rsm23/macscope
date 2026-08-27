#!/bin/zsh
set -euo pipefail

if (( $# != 2 )); then
  echo "Usage: $0 VERSION BUILD_NUMBER" >&2
  exit 64
fi

raw_version="$1"
build_number="$2"
version="${raw_version#v}"
version="${version%%-*}"

if [[ ! "$version" =~ '^[0-9]+([.][0-9]+){0,2}$' ]]; then
  echo "Release version must look like v1.2.3 or 1.2.3: $raw_version" >&2
  exit 64
fi

if [[ ! "$build_number" =~ '^[0-9]+$' ]]; then
  echo "Build number must contain only digits: $build_number" >&2
  exit 64
fi

root_dir="${0:A:h:h:h}"
info_plist="$root_dir/Resources/Info.plist"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$info_plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$info_plist"
plutil -lint "$info_plist"

if [[ -n "${GITHUB_ENV:-}" ]]; then
  echo "MACSCOPE_RELEASE_VERSION=$version" >> "$GITHUB_ENV"
fi
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "version=$version" >> "$GITHUB_OUTPUT"
fi

echo "Prepared MacScope $version ($build_number)."
