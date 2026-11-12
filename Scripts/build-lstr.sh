#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
source_dir="$repo_root/.deps/lstr"
binary_dir="$repo_root/.build/bin"
lstr_commit="dcd72f5a653d042249eecb94aaa6406382ca8a1d"
sdk_path=""

if command -v xcrun >/dev/null 2>&1; then
  sdk_path="$(xcrun --show-sdk-path)"
fi

if command -v rustup >/dev/null 2>&1; then
  cargo_command=(rustup run stable cargo)
  rustc_path="$(rustup which --toolchain stable rustc)"
elif command -v cargo >/dev/null 2>&1; then
  cargo_command=(cargo)
  rustc_path=""
else
  echo "Rust and Cargo are required to build the bundled lstr executable." >&2
  echo "Install Rust from https://rustup.rs, then run this script again." >&2
  exit 1
fi

if [[ ! -d "$source_dir/.git" ]]; then
  mkdir -p "$repo_root/.deps"
  git clone --filter=blob:none https://github.com/bgreenwell/lstr.git "$source_dir"
fi

git -C "$source_dir" fetch --depth 1 origin "$lstr_commit"
git -C "$source_dir" checkout --detach "$lstr_commit"
(
  cd "$source_dir"
  unset CFLAGS CPPFLAGS LDFLAGS
  if [[ -n "$sdk_path" ]]; then
    export SDKROOT="$sdk_path"
  fi
  if [[ -n "$rustc_path" ]]; then
    RUSTC="$rustc_path" "${cargo_command[@]}" build --release --locked
  else
    "${cargo_command[@]}" build --release --locked
  fi
)

mkdir -p "$binary_dir"
cp "$source_dir/target/release/lstr" "$binary_dir/lstr"
cp "$source_dir/LICENSE" "$binary_dir/lstr-LICENSE.txt"
echo "$binary_dir/lstr"
