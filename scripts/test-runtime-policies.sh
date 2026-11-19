#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
OUT="${ROOT}/work/runtime-policy-tests"
mkdir -p "${OUT}"
xcrun swiftc -parse-as-library -o "${OUT}/runtime-policy-tests" \
  "${ROOT}/RoamControl/Services/Tunnel/LocationSessionRetryPolicy.swift" \
  "${ROOT}/RoamControl/Services/Pairing/PairingExpiryStage.swift" \
  "${ROOT}/RoamControl/Services/Pairing/PairingPickerCopy.swift" \
  "${ROOT}/Tests/LocationSessionRetryPolicyTests.swift"
"${OUT}/runtime-policy-tests"
