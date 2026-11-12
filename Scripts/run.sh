#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
library_path="$repo_root/.build/lib/libghostty-vt.dylib"
eza_path="$repo_root/.build/bin/eza"

if [[ ! -f "$library_path" ]]; then
  "$repo_root/Scripts/build-libghostty.sh"
fi

if [[ ! -x "$eza_path" ]]; then
  "$repo_root/Scripts/build-eza.sh"
fi

export LIBGHOSTTY_VT_PATH="$library_path"
export TERMINAL_TABS_EZA_PATH="$eza_path"
cd "$repo_root"
swift run TerminalTabs
