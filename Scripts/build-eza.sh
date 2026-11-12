#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
source_dir="$repo_root/.deps/eza"
binary_dir="$repo_root/.build/bin"
eza_commit="471bfbc7b03cbac8c738e8d9050edb06ee79132a"

if command -v rustup >/dev/null 2>&1; then
  cargo_command=(rustup run stable cargo)
  rustc_path="$(rustup which --toolchain stable rustc)"
elif command -v cargo >/dev/null 2>&1; then
  cargo_command=(cargo)
  rustc_path=""
else
  echo "Rust and Cargo are required to build the bundled eza executable." >&2
  echo "Install Rust from https://rustup.rs, then run this script again." >&2
  exit 1
fi

if [[ ! -d "$source_dir/.git" ]]; then
  mkdir -p "$repo_root/.deps"
  git clone --filter=blob:none https://github.com/eza-community/eza.git "$source_dir"
fi

git -C "$source_dir" fetch --depth 1 origin "$eza_commit"
git -C "$source_dir" checkout --detach "$eza_commit"
(
  cd "$source_dir"
  if [[ -n "$rustc_path" ]]; then
    RUSTC="$rustc_path" "${cargo_command[@]}" build --release --locked --no-default-features
  else
    "${cargo_command[@]}" build --release --locked --no-default-features
  fi
)

mkdir -p "$binary_dir"
cp "$source_dir/target/release/eza" "$binary_dir/eza"
cp "$source_dir/LICENSE.txt" "$binary_dir/eza-LICENSE.txt"
echo "$binary_dir/eza"
