#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
library_path="$repo_root/.build/lib/libghostty-vt.dylib"

if [[ ! -f "$library_path" ]]; then
  "$repo_root/Scripts/build-libghostty.sh"
fi

export LIBGHOSTTY_VT_PATH="$library_path"
cd "$repo_root"
swift run TerminalTabs
