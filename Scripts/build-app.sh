#!/bin/zsh
set -euo pipefail

root_dir="${0:A:h:h}"
configuration="${CONFIGURATION:-release}"
architecture="${ARCHITECTURE:-arm64}"
dist_dir="$root_dir/dist"
app_dir="$dist_dir/MacScope.app"
contents_dir="$app_dir/Contents"

cd "$root_dir"
swift build -c "$configuration" --arch "$architecture" --product MacScope
swift build -c "$configuration" --arch "$architecture" --product MacScopeHelper
swift build -c "$configuration" --arch "$architecture" --product MacScopeMCPServer
bin_dir="$(swift build -c "$configuration" --arch "$architecture" --show-bin-path)"

rm -rf "$app_dir"
mkdir -p "$contents_dir/MacOS" "$contents_dir/Resources" "$contents_dir/Library/LaunchDaemons"
cp "$root_dir/Resources/Info.plist" "$contents_dir/Info.plist"
cp "$root_dir/Resources/AppIcon.icns" "$contents_dir/Resources/AppIcon.icns"
cp "$bin_dir/MacScope" "$contents_dir/MacOS/MacScope"
cp "$bin_dir/MacScopeHelper" "$contents_dir/Resources/MacScopeHelper"
cp "$bin_dir/MacScopeMCPServer" "$contents_dir/Resources/MacScopeMCPServer"
cp "$root_dir/docs/MCP_SERVER.md" "$contents_dir/Resources/MacScope-MCP-Server.md"
cp "$root_dir/Resources/local.taskmanager.MacScope.Helper.plist" "$contents_dir/Library/LaunchDaemons/local.taskmanager.MacScope.Helper.plist"

bundle_path="$bin_dir/MacScope_MacScope.bundle"
if [[ -d "$bundle_path" ]]; then
  cp -R "$bundle_path" "$contents_dir/Resources/"
fi

chmod 755 "$contents_dir/MacOS/MacScope" "$contents_dir/Resources/MacScopeHelper" "$contents_dir/Resources/MacScopeMCPServer"

if [[ -n "${DEVELOPER_ID_APPLICATION:-}" ]]; then
  keychain_arguments=()
  if [[ -n "${MACOS_CI_KEYCHAIN:-}" ]]; then
    keychain_arguments=(--keychain "$MACOS_CI_KEYCHAIN")
  fi
  codesign --force --timestamp --options runtime "${keychain_arguments[@]}" --identifier "local.taskmanager.MacScope.Helper" --sign "$DEVELOPER_ID_APPLICATION" "$contents_dir/Resources/MacScopeHelper"
  codesign --force --timestamp --options runtime "${keychain_arguments[@]}" --identifier "local.taskmanager.MacScope.MCPServer" --sign "$DEVELOPER_ID_APPLICATION" "$contents_dir/Resources/MacScopeMCPServer"
  codesign --force --timestamp --options runtime "${keychain_arguments[@]}" --entitlements "$root_dir/Resources/MacScope.entitlements" --sign "$DEVELOPER_ID_APPLICATION" "$app_dir"
else
  codesign --force --identifier "local.taskmanager.MacScope.Helper" --sign - "$contents_dir/Resources/MacScopeHelper"
  codesign --force --identifier "local.taskmanager.MacScope.MCPServer" --sign - "$contents_dir/Resources/MacScopeMCPServer"
  codesign --force --deep --sign - "$app_dir"
fi

codesign --verify --deep --strict --verbose=2 "$app_dir"
echo "$app_dir"
