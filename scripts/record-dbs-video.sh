#!/usr/bin/env bash
# End-to-end video tour of the app as DBS Ltd use it: records the Simulator while
# DBSLimitedTourUITests drives every feature, then cuts the recording into a captioned video with
# a chapter per persona.
#
#   scripts/record-dbs-video.sh                       # the DBS Ltd build against int (the demo)
#   SCHEME=WSLCRM-Local ENV_FILE=build/dbs-limited.env scripts/record-dbs-video.sh   # local stack
#   scripts/record-dbs-video.sh -only-testing:WSLCRMUITests/DBSLimitedTourUITests/test4ManagerSimproReportsAndAssets
#
# Credentials come from the env file written by scripts/seed-dbs-limited.py and are passed to the
# test runner as TEST_RUNNER_* variables — never printed. Output:
#
#   build/dbs-video/dbs-ltd-tour.mp4        the tour, 1920x1080
#   build/dbs-video/chapters.txt            chapter timestamps, for publishing it
#   build/dbs-video/raw.mov                 the untouched Simulator recording
#   build/dbs-video/screenshots/            the same tour as stills
#
# The app is built first and the recording starts afterwards, so no compile output is filmed.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCHEME="${SCHEME:-WSLCRM-DBS-Int}"
ENV_FILE="${ENV_FILE:-$ROOT/build/dbs-group-demo.env}"
DEVICE="${DEVICE:-iPhone 17}"
OUT_DIR="${OUT_DIR:-$ROOT/build/dbs-video}"
DERIVED="${DERIVED:-$ROOT/build/dd-dbs-video}"
TITLE="${TITLE:-WSLCRM for DBS Ltd}"
SUBTITLE="${SUBTITLE:-Field service and the Simpro CRM, on iOS}"
[ -f "$ENV_FILE" ] || { echo "No $ENV_FILE — run scripts/seed-dbs-limited.py first." >&2; exit 1; }
set -a; . "$ENV_FILE"; set +a

UDID=$(xcrun simctl list devices available -j | jq -r --arg n "$DEVICE" '[.devices[][] | select(.name == $n)][0].udid')
[ -n "$UDID" ] && [ "$UDID" != "null" ] || { echo "No simulator named $DEVICE" >&2; exit 1; }
xcrun simctl boot "$UDID" 2>/dev/null || true
open -a Simulator --args -CurrentDeviceUDID "$UDID"
xcrun simctl bootstatus "$UDID" -b >/dev/null
# A tidy status bar for the film; the clock stays real, because the data is relative to now.
xcrun simctl status_bar "$UDID" override --batteryState charged --batteryLevel 100 \
  --cellularMode active --cellularBars 4 --wifiBars 3 --dataNetwork 5g
trap 'xcrun simctl status_bar "$UDID" clear 2>/dev/null || true' EXIT

mkdir -p "$OUT_DIR"
RESULT="$OUT_DIR/result.xcresult"; rm -rf "$RESULT"
RAW="$OUT_DIR/raw.mov"; rm -f "$RAW"
LOG="$OUT_DIR/test.log"

echo "== Building $SCHEME for testing"
xcodebuild -project "$ROOT/WSLCRM.xcodeproj" -scheme "$SCHEME" -destination "id=$UDID" \
  -derivedDataPath "$DERIVED" build-for-testing >"$OUT_DIR/build.log" 2>&1 \
  || { tail -30 "$OUT_DIR/build.log"; echo "build failed — see $OUT_DIR/build.log" >&2; exit 1; }

echo "== Recording"
REC_LOG="$OUT_DIR/record.log"; : >"$REC_LOG"
xcrun simctl io "$UDID" recordVideo --codec h264 --force "$RAW" >"$REC_LOG" 2>&1 &
REC=$!
trap 'kill -INT $REC 2>/dev/null || true; xcrun simctl status_bar "$UDID" clear 2>/dev/null || true' EXIT
# The recorder takes a moment to open the file; note when it says it is running. What is left of
# the lag is measured against the tour's own screenshots when the video is cut.
for _ in $(seq 100); do grep -q "Recording started" "$REC_LOG" && break; sleep 0.1; done
RECORD_START=$(python3 -c 'import time; print(f"{time.time():.3f}")')
echo "$RECORD_START" >"$OUT_DIR/record-start.txt"   # so the video can be re-cut without refilming
sleep 1

set +e
TEST_RUNNER_WSL_PASSWORD="$WSL_PASSWORD" TEST_RUNNER_WSL_OTP="$WSL_OTP" \
TEST_RUNNER_DBS_TOM="$DBS_TOM" TEST_RUNNER_DBS_CLAIRE="$DBS_CLAIRE" TEST_RUNNER_DBS_AISHA="$DBS_AISHA" \
TEST_RUNNER_TOUR_VIDEO=1 \
xcodebuild -project "$ROOT/WSLCRM.xcodeproj" -scheme "$SCHEME" -destination "id=$UDID" \
  -derivedDataPath "$DERIVED" -resultBundlePath "$RESULT" \
  $(printf '%s\n' "$@" | grep -q -- '-only-testing' || echo -only-testing:WSLCRMUITests/DBSLimitedTourUITests) \
  test-without-building "$@" 2>&1 \
  | sed -l -E 's/Type .* into ("login\.password"|"twofactor\.code")/Type <redacted> into \1/' \
  | tee "$LOG"
# The first stage is xcodebuild's: sed and tee cannot fail the run. XCTest writes the text it types
# into its activity log, so the password and the code are taken out on the way past.
STATUS=${PIPESTATUS[0]}
set -e

# Stop the recording and let it finish writing before anything reads the file.
kill -INT $REC 2>/dev/null || true
wait $REC 2>/dev/null || true
trap 'xcrun simctl status_bar "$UDID" clear 2>/dev/null || true' EXIT

echo "== Cutting the video"
OUT_DIR="$OUT_DIR" TITLE="$TITLE" SUBTITLE="$SUBTITLE" "$ROOT/scripts/cut-dbs-video.sh" "$OUT_DIR"

[ "$STATUS" -eq 0 ] || echo "note: the tour reported failures — see $LOG" >&2
exit $STATUS
