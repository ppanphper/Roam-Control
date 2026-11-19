#!/bin/zsh
set -euo pipefail
if [[ $# -lt 1 || "$1" == "--help" ]]; then
  print 'Usage: zsh scripts/test-ui-simulator.sh <existing-simulator-UDID> [--release] [xcodebuild test selectors]'
  exit 0
fi
ROOT="${0:A:h:h}"
SIMULATOR_ID="$1"
shift
CONFIGURATION=Debug
if [[ "${1:-}" == "--release" ]]; then
  CONFIGURATION=Release
  shift
fi
APP_BUILD="${ROOT}/work/ui-app-${CONFIGURATION}"
STAMP="$(date +%Y-%m-%d_%H-%M-%S)"
OUT="${ROOT}/work/ui-validation-${STAMP}"
mkdir -p "${OUT}"
xcrun simctl list devices available -j > "${OUT}/simulators.json"
python3 - "${OUT}/simulators.json" "${SIMULATOR_ID}" <<'PY'
import json, sys
devices = json.load(open(sys.argv[1]))['devices']
assert any(d['udid'] == sys.argv[2] for group in devices.values() for d in group), 'Expected an available simulator UDID'
PY
cp -R "${ROOT}/Tests/UI/" "${OUT}/project"
xcodegen generate --spec "${OUT}/project/project.yml" --project "${OUT}/project" > "${OUT}/generate.log"
xcodebuild -project "${ROOT}/RoamControl.xcodeproj" -scheme RoamControl \
  -configuration "${CONFIGURATION}" -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "${APP_BUILD}" CODE_SIGNING_ALLOWED=NO build > "${OUT}/build.log" 2>&1
xcrun simctl bootstatus "${SIMULATOR_ID}" -b
xcrun simctl install "${SIMULATOR_ID}" "${APP_BUILD}/Build/Products/${CONFIGURATION}-iphonesimulator/RoamControl.app"
xcodebuild -project "${OUT}/project/RoamAlignmentUI.xcodeproj" -scheme RoamAlignmentUI \
  -destination "platform=iOS Simulator,id=${SIMULATOR_ID}" \
  -derivedDataPath "${ROOT}/work/ui-tests/DerivedData" \
  -resultBundlePath "${OUT}/results.xcresult" CODE_SIGNING_ALLOWED=NO "$@" test > "${OUT}/test.log" 2>&1
xcrun xcresulttool export attachments --path "${OUT}/results.xcresult" --output-path "${OUT}/attachments"
print "PASS: UI test evidence ${OUT}"
