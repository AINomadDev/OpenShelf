#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
version=1.75.2
arch="$(uname -m)"
[ "$arch" != x86_64 ] || arch=amd64
archive="rclone-v${version}-osx-${arch}.zip"
mkdir -p .build/downloads
curl -fsSL "https://downloads.rclone.org/v${version}/${archive}" -o ".build/downloads/${archive}"
curl -fsSL "https://downloads.rclone.org/v${version}/SHA256SUMS" -o .build/downloads/SHA256SUMS
python3 - "$archive" <<'PY'
import hashlib, pathlib, sys, zipfile
root = pathlib.Path('.build/downloads')
name = sys.argv[1]
expected = next(line.split()[0] for line in (root/'SHA256SUMS').read_text().splitlines() if line.split() and line.split()[-1].lstrip('*') == name)
if hashlib.sha256((root/name).read_bytes()).hexdigest() != expected:
    raise SystemExit('rclone checksum mismatch; refusing to install')
with zipfile.ZipFile(root/name) as archive:
    archive.extractall(root)
(root/name.removesuffix('.zip')/'rclone').chmod(0o755)
print('Official rclone archive checksum verified')
PY
