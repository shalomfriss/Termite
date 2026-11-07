#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
source_dir="$repo_root/.deps/ghostty"
library_dir="$repo_root/.build/lib"
ghostty_commit="5acdbf154369928eb228d2263cbe612d165f7569"

if ! command -v zig >/dev/null 2>&1; then
  echo "Zig is required to build libghostty-vt." >&2
  echo "Install the version listed at https://ghostty.org/docs/install/build, then run this script again." >&2
  exit 1
fi

if [[ ! -d "$source_dir/.git" ]]; then
  mkdir -p "$repo_root/.deps"
  git clone --filter=blob:none https://github.com/ghostty-org/ghostty.git "$source_dir"
fi

git -C "$source_dir" fetch --depth 1 origin "$ghostty_commit"
git -C "$source_dir" checkout --detach "$ghostty_commit"
(
  cd "$source_dir"
  zig build -Demit-lib-vt -Demit-macos-app=false -Demit-xcframework=false -Doptimize=ReleaseFast
)

mkdir -p "$library_dir"
library_path="$(find "$source_dir/zig-out/lib" -maxdepth 1 -name 'libghostty-vt*.dylib' -type f | head -1)"
if [[ -z "$library_path" ]]; then
  echo "The libghostty-vt build completed without producing a dylib." >&2
  exit 1
fi
cp "$library_path" "$library_dir/libghostty-vt.dylib"
echo "$library_dir/libghostty-vt.dylib"
