#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
OUT="${ROOT}/work/localization-tests/LocalizationTests.app/Contents"
mkdir -p "${OUT}/MacOS" "${OUT}/Resources"
for folder in "${ROOT}"/RoamControl/Resources/*.lproj; do cp -R "${folder}" "${OUT}/Resources/"; done
python3 - "${OUT}/Info.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'wb') as stream:
    plistlib.dump({'CFBundleIdentifier': 'com.ppanphper.roamcontrol.localization-tests',
                  'CFBundleExecutable': 'LocalizationTests', 'CFBundleDevelopmentRegion': 'en'}, stream)
PY
xcrun swiftc -parse-as-library -o "${OUT}/MacOS/LocalizationTests" \
  "${ROOT}/RoamControl/Services/Localization/AppLanguage.swift" \
  "${ROOT}/Tests/LocalizationMessageTests.swift"
"${OUT}/MacOS/LocalizationTests"
