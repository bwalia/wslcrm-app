#!/usr/bin/env bash
# Runs the end-to-end Field Service UI test against the local OPSAPI (WSLCRM-Local scheme).
# Credentials come from build/local-fs-test.env (scripts/local-opsapi-fs-seed.sh) and are passed
# to the test runner as TEST_RUNNER_* variables — never printed. Records a screen video.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="$ROOT/build/local-fs-test.env"
DEVICE="${DEVICE:-iPhone 17}"
[ -f "$ENV_FILE" ] || { echo "Run scripts/local-opsapi-fs-seed.sh first." >&2; exit 1; }
set -a; . "$ENV_FILE"; set +a

# Start from a clean engineer schedule: cancel open visits/jobs left by earlier (interrupted) runs.
# Only ever touches the isolated test database's "fs-test" namespace.
DB="${DB:-opsapi-wslcrm-pr610}"
case "$DB" in opsapi-diytaxreturn|*prod*) echo "Refusing to reset $DB" >&2; exit 1 ;; esac
docker exec -i "${PG_CONTAINER:-opsapi-postgres-dev-db}" sh -c "psql -U \"\$POSTGRES_USER\" -d '$DB' -Atq" <<'SQL'
UPDATE fs_visits v SET status = 'cancelled', cancelled_reason = 'UI test reset', updated_at = NOW()
  FROM fs_jobs j JOIN namespaces n ON n.id = j.namespace_id
  WHERE v.job_id = j.id AND n.slug = 'fs-test' AND v.status IN ('scheduled', 'en_route', 'on_site');
UPDATE fs_jobs j SET status = 'cancelled', cancelled_reason = 'UI test reset', updated_at = NOW()
  FROM namespaces n WHERE n.id = j.namespace_id AND n.slug = 'fs-test' AND j.status IN ('draft', 'scheduled', 'in_progress', 'on_hold');
SQL

UDID=$(xcrun simctl list devices available -j | jq -r --arg n "$DEVICE" '[.devices[][] | select(.name == $n)][0].udid')
xcrun simctl boot "$UDID" 2>/dev/null || true

# A photo for the engineer to attach (the picker needs something in the library).
PHOTO="$ROOT/build/local-fs-run/fault-photo.jpg"
mkdir -p "$(dirname "$PHOTO")"
if [ ! -f "$PHOTO" ]; then
  swift - "$PHOTO" <<'SWIFT'
import AppKit
let path = CommandLine.arguments[1]
let size = NSSize(width: 1200, height: 900)
let image = NSImage(size: size)
image.lockFocus()
NSColor(calibratedRed: 0.16, green: 0.20, blue: 0.28, alpha: 1).setFill()
NSRect(origin: .zero, size: size).fill()
let text = "WSLCRM test fault photo" as NSString
text.draw(at: NSPoint(x: 80, y: 420), withAttributes: [
    .font: NSFont.boldSystemFont(ofSize: 64), .foregroundColor: NSColor.white,
])
image.unlockFocus()
let tiff = image.tiffRepresentation!
let jpeg = NSBitmapImageRep(data: tiff)!.representation(using: .jpeg, properties: [.compressionFactor: 0.8])!
try! jpeg.write(to: URL(fileURLWithPath: path))
SWIFT
fi
xcrun simctl addmedia "$UDID" "$PHOTO" 2>/dev/null || true
xcrun simctl location "$UDID" set 51.5171,-0.1749          # St Mary's, Paddington
xcrun simctl privacy "$UDID" grant location uk.co.workstation.wslcrm 2>/dev/null || true

mkdir -p "$ROOT/build/local-fs-run"
RESULT="$ROOT/build/local-fs-run/result.xcresult"; rm -rf "$RESULT"
VIDEO="$ROOT/build/local-fs-run/happy-path.mp4"; rm -f "$VIDEO"
xcrun simctl io "$UDID" recordVideo --codec h264 --force "$VIDEO" & REC=$!
trap 'kill -INT $REC 2>/dev/null || true' EXIT

TEST_RUNNER_WSL_PASSWORD="$WSL_PASSWORD" TEST_RUNNER_WSL_OTP="$WSL_OTP" \
TEST_RUNNER_WSL_TELECALLER="$WSL_TELECALLER" TEST_RUNNER_WSL_MANAGER="$WSL_MANAGER" TEST_RUNNER_WSL_ENGINEER="$WSL_ENGINEER" \
xcodebuild -project "$ROOT/WSLCRM.xcodeproj" -scheme WSLCRM-Local -destination "id=$UDID" \
  -derivedDataPath "$ROOT/build/DerivedData" -resultBundlePath "$RESULT" \
  -only-testing:WSLCRMUITests/FieldServiceLocalFlowUITests -only-testing:WSLCRMUITests/LocalPhotoUploadTests test "$@"
