#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
OUT="${ROOT}/work/update-tests"
mkdir -p "${OUT}"
xcrun swiftc -parse-as-library -o "${OUT}/update-tests" \
  "${ROOT}/RoamControl/Services/Updates/ReleaseUpdateService.swift" \
  "${ROOT}/Tests/ReleaseUpdateNoticeTests.swift"
"${OUT}/update-tests"
