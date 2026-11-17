#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
dist_dir="$repo_root/dist"
app_path="$dist_dir/Air.app"
archive_path="$dist_dir/Air-macOS-arm64.zip"
contents_path="$app_path/Contents"
macos_path="$contents_path/MacOS"
resources_path="$contents_path/Resources"
frameworks_path="$contents_path/Frameworks"
library_path="$repo_root/.build/lib/libghostty-vt.dylib"
eza_path="$repo_root/.build/bin/eza"
lstr_path="$repo_root/.build/bin/lstr"

if [[ "$(uname -m)" != "arm64" ]]; then
  echo "This packaging script currently expects Apple Silicon build dependencies." >&2
  exit 1
fi

if [[ ! -f "$library_path" ]]; then
  "$repo_root/Scripts/build-libghostty.sh"
fi
if [[ ! -x "$eza_path" ]]; then
  "$repo_root/Scripts/build-eza.sh"
fi
if [[ ! -x "$lstr_path" ]] || otool -L "$lstr_path" | rg -q '/opt/homebrew|/usr/local'; then
  "$repo_root/Scripts/build-lstr.sh"
fi

swift build --package-path "$repo_root" --configuration release --product Air
binary_dir="$(swift build --package-path "$repo_root" --configuration release --show-bin-path)"

if [[ ! -x "$binary_dir/Air" || ! -d "$binary_dir/Air_Air.bundle" ]]; then
  echo "The release build did not produce Air and its resource bundle." >&2
  exit 1
fi

mkdir -p "$dist_dir"
rm -rf "$app_path"
rm -f "$archive_path"
mkdir -p "$macos_path" "$resources_path/bin" "$resources_path/licenses" "$frameworks_path"

cp "$binary_dir/Air" "$macos_path/Air"
cp "$repo_root/Packaging/Air-Info.plist" "$contents_path/Info.plist"
ditto "$binary_dir/Air_Air.bundle" "$resources_path/Air_Air.bundle"
cp "$library_path" "$frameworks_path/libghostty-vt.dylib"
cp "$eza_path" "$resources_path/bin/eza"
cp "$lstr_path" "$resources_path/bin/lstr"
cp "$repo_root/.build/bin/eza-LICENSE.txt" "$resources_path/licenses/eza-LICENSE.txt"
cp "$repo_root/.build/bin/lstr-LICENSE.txt" "$resources_path/licenses/lstr-LICENSE.txt"
cp "$repo_root/.deps/ghostty/LICENSE" "$resources_path/licenses/ghostty-LICENSE.txt"

chmod 755 "$macos_path/Air" "$resources_path/bin/eza" "$resources_path/bin/lstr"
codesign --force --sign - --timestamp=none "$frameworks_path/libghostty-vt.dylib"
codesign --force --sign - --timestamp=none "$resources_path/bin/eza"
codesign --force --sign - --timestamp=none "$resources_path/bin/lstr"
codesign --force --deep --sign - --timestamp=none "$app_path"

codesign --verify --deep --strict --verbose=2 "$app_path"
ditto -c -k --sequesterRsrc --keepParent "$app_path" "$archive_path"

echo "$archive_path"
