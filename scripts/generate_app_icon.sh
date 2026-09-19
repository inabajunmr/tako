#!/usr/bin/env bash
set -euo pipefail

INPUT_PNG="${1:-}"
OUTPUT_ICNS="${2:-}"

if [[ -z "$INPUT_PNG" || -z "$OUTPUT_ICNS" ]]; then
    echo "Usage: scripts/generate_app_icon.sh INPUT_PNG OUTPUT_ICNS" >&2
    exit 2
fi

if [[ ! -f "$INPUT_PNG" ]]; then
    echo "Input icon not found: $INPUT_PNG" >&2
    exit 1
fi

mkdir -p "$(dirname "$OUTPUT_ICNS")"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/tendon-app-icon.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

for size in 16 32 64 128 256 512 1024; do
    sips -z "$size" "$size" "$INPUT_PNG" --out "$WORK_DIR/$size.png" >/dev/null
done

python3 - "$WORK_DIR" "$OUTPUT_ICNS" <<'PY'
import struct
import sys
from pathlib import Path

work_dir = Path(sys.argv[1])
output_path = Path(sys.argv[2])
items = [
    ("icp4", 16),
    ("icp5", 32),
    ("icp6", 64),
    ("ic07", 128),
    ("ic08", 256),
    ("ic09", 512),
    ("ic10", 1024),
]

chunks = []
for chunk_type, size in items:
    data = (work_dir / f"{size}.png").read_bytes()
    chunks.append(
        chunk_type.encode("ascii") +
        struct.pack(">I", len(data) + 8) +
        data
    )

body = b"".join(chunks)
output_path.write_bytes(b"icns" + struct.pack(">I", len(body) + 8) + body)
PY
