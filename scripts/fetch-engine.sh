#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
version=1.75.2
arch="$(uname -m)"
[ "$arch" != x86_64 ] || arch=amd64
archive="rclone-v${version}-osx-${arch}.zip"
# Pinned so a compromised download server cannot supply a matching checksum file. Update with the version.
case "$archive" in
  rclone-v1.75.2-osx-amd64.zip) pinned=574e1f31cf1c464e5fb0325cb66fcbdeaf1efa1802bd9b17f13c256fd74b6561 ;;
  rclone-v1.75.2-osx-arm64.zip) pinned=610ab7d48615135dfc60b763858b11a426a0d3d1160c1bb76fb0ae6011b02edd ;;
  *) echo "No pinned checksum for $archive; add one before changing the version." >&2; exit 1 ;;
esac
mkdir -p .build/downloads
curl -fsSL "https://downloads.rclone.org/v${version}/${archive}" -o ".build/downloads/${archive}"
curl -fsSL "https://downloads.rclone.org/v${version}/SHA256SUMS" -o .build/downloads/SHA256SUMS
python3 - "$archive" "$pinned" <<'PY'
import hashlib, pathlib, sys, zipfile
root = pathlib.Path('.build/downloads')
name, pinned = sys.argv[1], sys.argv[2]
expected = next(line.split()[0] for line in (root/'SHA256SUMS').read_text().splitlines() if line.split() and line.split()[-1].lstrip('*') == name)
if expected != pinned or hashlib.sha256((root/name).read_bytes()).hexdigest() != pinned:
    raise SystemExit('rclone checksum mismatch; refusing to install')
with zipfile.ZipFile(root/name) as archive:
    archive.extractall(root)
(root/name.removesuffix('.zip')/'rclone').chmod(0o755)
print('Official rclone archive matches the pinned checksum')
PY
