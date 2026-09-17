#!/usr/bin/env bash
# Screenshot tour of DBS Limited's engineers, service managers and service desk against the local
# OPSAPI (WSLCRM-Local scheme). Opens the Simulator on screen, runs DBSLimitedTourUITests and
# exports every screenshot as a named PNG to build/dbs-screenshots/.
#
#   scripts/seed-dbs-limited.py --reset     # refresh the day around now first (optional)
#   scripts/seed-dbs-portfolio.py           # the Simpro portfolio, for the simpro-* screens
#   scripts/run-dbs-screenshots.sh
#   scripts/run-dbs-screenshots.sh -only-testing:WSLCRMUITests/DBSLimitedTourUITests/test4ManagerSimproReportsAndAssets
#
# Credentials come from build/dbs-limited.env (scripts/seed-dbs-limited.py) and are passed to the
# test runner as TEST_RUNNER_* variables — never printed.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="$ROOT/build/dbs-limited.env"
DEVICE="${DEVICE:-iPhone 17}"
OUT_DIR="${OUT_DIR:-$ROOT/build/dbs-screenshots}"
RUN_DIR="$ROOT/build/dbs-run"
[ -f "$ENV_FILE" ] || { echo "Run scripts/seed-dbs-limited.py first." >&2; exit 1; }
set -a; . "$ENV_FILE"; set +a

UDID=$(xcrun simctl list devices available -j | jq -r --arg n "$DEVICE" '[.devices[][] | select(.name == $n)][0].udid')
[ -n "$UDID" ] && [ "$UDID" != "null" ] || { echo "No simulator named $DEVICE" >&2; exit 1; }
xcrun simctl boot "$UDID" 2>/dev/null || true
open -a Simulator --args -CurrentDeviceUDID "$UDID"
xcrun simctl bootstatus "$UDID" -b >/dev/null
# Clean status bar for the captures (the clock stays real: the data is relative to now).
xcrun simctl status_bar "$UDID" override --batteryState charged --batteryLevel 100 \
  --cellularMode active --cellularBars 4 --wifiBars 3 --dataNetwork 5g
trap 'xcrun simctl status_bar "$UDID" clear 2>/dev/null || true' EXIT

mkdir -p "$RUN_DIR"
RESULT="$RUN_DIR/result.xcresult"; rm -rf "$RESULT"

set +e
TEST_RUNNER_WSL_PASSWORD="$WSL_PASSWORD" TEST_RUNNER_WSL_OTP="$WSL_OTP" \
TEST_RUNNER_DBS_TOM="$DBS_TOM" TEST_RUNNER_DBS_CLAIRE="$DBS_CLAIRE" TEST_RUNNER_DBS_AISHA="$DBS_AISHA" \
xcodebuild -project "$ROOT/WSLCRM.xcodeproj" -scheme WSLCRM-Local -destination "id=$UDID" \
  -derivedDataPath "$ROOT/build/DerivedData" -resultBundlePath "$RESULT" \
  $(printf '%s\n' "$@" | grep -q -- '-only-testing' || echo -only-testing:WSLCRMUITests/DBSLimitedTourUITests) test "$@"
STATUS=$?
set -e

# Export the attachments and name each PNG after its snapshot name.
rm -rf "$OUT_DIR" "$RUN_DIR/attachments"
mkdir -p "$OUT_DIR" "$RUN_DIR/attachments"
xcrun xcresulttool export attachments --path "$RESULT" --output-path "$RUN_DIR/attachments" >/dev/null
python3 - "$RUN_DIR/attachments" "$OUT_DIR" <<'PY'
import json, pathlib, shutil, sys
source, target = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
count = 0
for test in json.loads((source / "manifest.json").read_text()):
    for attachment in test.get("attachments", []):
        name = attachment.get("suggestedHumanReadableName") or attachment["exportedFileName"]
        # Xcode appends "_<index>_<uuid>" to the name; keep the snapshot name itself, and skip its own
        # failure attachments (UI hierarchies, recordings).
        stem = name.rsplit(".", 1)[0].split("_")[0]
        if not stem.startswith(("eng-", "mgr-", "desk-", "simpro-")):
            continue
        shutil.copy(source / attachment["exportedFileName"], target / f"{stem}.png")
        count += 1
print(f"{count} screenshots in {target}")
PY
exit $STATUS
