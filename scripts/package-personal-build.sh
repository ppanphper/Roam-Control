#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
BUILD_DIR="${ROOT}/work/personal-release"
OUTPUT_DIR="${ROOT}/outputs"
STAMP="$(python3 -c 'from datetime import datetime; from zoneinfo import ZoneInfo; print(datetime.now(ZoneInfo("America/Los_Angeles")).strftime("%Y-%m-%d_%H-%M-%S"))')"
BUILD_TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
ARCHIVE="${BUILD_DIR}/Roam-Control-${STAMP}.xcarchive"
mkdir -p "${BUILD_DIR}" "${OUTPUT_DIR}"

xcodebuild -project "${ROOT}/RoamControl.xcodeproj" -scheme RoamControl \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath "${BUILD_DIR}/DerivedData" -archivePath "${ARCHIVE}" \
  CODE_SIGNING_ALLOWED=NO ROAMCONTROL_BUILD_TIMESTAMP="${BUILD_TIMESTAMP}" \
  archive > "${BUILD_DIR}/archive-${STAMP}.log" 2>&1

python3 "${ROOT}/scripts/validate-and-package.py" \
  --app "${ARCHIVE}/Products/Applications/RoamControl.app" \
  --output-dir "${OUTPUT_DIR}" --stamp "${STAMP}" --source-root "${ROOT}"
