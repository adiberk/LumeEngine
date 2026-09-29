#!/bin/bash
# Download every source tarball pinned in build/versions.json into build/ and
# verify it against its SHA-256. Entries without a checksum (planned libraries)
# are skipped. Idempotent: a tarball already present with the right checksum is
# not downloaded again.
#
# Usage: fetch-sources.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$(dirname "$SCRIPT_DIR")"

python3 - "$BUILD_DIR/versions.json" <<'PYEOF' | while read -r name url sha; do
import json, sys
for name, entry in json.load(open(sys.argv[1])).items():
    if "sha256" in entry:
        print(name, entry["url"], entry["sha256"])
PYEOF
    file="$BUILD_DIR/$(basename "$url")"
    if [ -f "$file" ] && echo "$sha  $file" | shasum -a 256 -c - >/dev/null 2>&1; then
        echo "==> $name: $(basename "$file") present"
        continue
    fi
    echo "==> $name: downloading $url"
    curl -sfL --retry 3 -o "$file" "$url"
    echo "$sha  $file" | shasum -a 256 -c - >/dev/null || {
        echo "$name: checksum mismatch for $file" >&2; rm -f "$file"; exit 1; }
    echo "==> $name: verified"
done
