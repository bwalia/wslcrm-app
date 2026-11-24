#!/usr/bin/env bash
# Builds the desktop app's icons from the iOS app icon (the single source of the artwork):
#   wslcrm.png (512), wslcrm.icns (macOS), wslcrm.ico (Windows; PNG-compressed entries).
# Run from anywhere after the iOS AppIcon changes; the outputs are committed.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
src="$here/../../../WSLCRM/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

sips -z 512 512 "$src" --out "$here/wslcrm.png" >/dev/null

set_dir="$tmp/wslcrm.iconset"; mkdir "$set_dir"
for s in 16 32 128 256 512; do
  sips -z $s $s "$src" --out "$set_dir/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$src" --out "$set_dir/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$set_dir" -o "$here/wslcrm.icns"

sizes=(16 24 32 48 64 128 256)
for s in "${sizes[@]}"; do sips -z $s $s "$src" --out "$tmp/ico_$s.png" >/dev/null; done
python3 - "$here/wslcrm.ico" "$tmp" "${sizes[@]}" <<'PY'
import struct, sys, os
out, tmp, sizes = sys.argv[1], sys.argv[2], [int(s) for s in sys.argv[3:]]
blobs = [open(os.path.join(tmp, f"ico_{s}.png"), "rb").read() for s in sizes]
header = struct.pack("<HHH", 0, 1, len(sizes))
offset = 6 + 16 * len(sizes)
entries = b""
for s, b in zip(sizes, blobs):
    entries += struct.pack("<BBBBHHII", s % 256, s % 256, 0, 0, 1, 32, len(b), offset)
    offset += len(b)
open(out, "wb").write(header + entries + b"".join(blobs))
PY
echo "icons written to $here"
