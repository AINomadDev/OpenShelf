#!/usr/bin/env bash
# Starts the right OpenShelf for this operating system.
set -euo pipefail
cd "$(dirname "$0")"
case "$(uname -s)" in
  Darwin)
    [ -d dist/OpenShelf.app ] || ./scripts/build-app.sh
    open dist/OpenShelf.app ;;
  Linux)
    command -v cargo >/dev/null || { echo "Install Rust (https://rustup.rs), rclone and fuse3 first."; exit 1; }
    cd desktop/src-tauri && cargo run --release ;;
  MINGW*|MSYS*|CYGWIN*)
    cd desktop/src-tauri && cargo run --release ;;
  *) echo "Unsupported OS: $(uname -s)"; exit 1 ;;
esac
