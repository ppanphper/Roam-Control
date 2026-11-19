#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
OUT="${ROOT}/work/movement-tests"
mkdir -p "${OUT}"
TEST_MAIN="${1:-Tests/MovementTests.swift}"
SOURCES=(
  "${ROOT}/RoamControl/Models/LocationTarget.swift"
  "${ROOT}/RoamControl/Models/RouteCoordinate.swift"
  "${ROOT}/RoamControl/Models/CoordinateCompatibility.swift"
  "${ROOT}/RoamControl/Models/Movement"*.swift
  "${ROOT}/RoamControl/Services/Movement/"*.swift
  "${ROOT}/RoamControl/Services/Routes/"*.swift
  "${ROOT}/RoamControl/Features/Map/RoutePlanner.swift"
  "${ROOT}/RoamControl/Features/Map/MovementController.swift"
  "${ROOT}/Tests/MovementSessionDouble.swift"
  "${ROOT}/${TEST_MAIN}"
)
xcrun swiftc -swift-version 5 -parse-as-library -o "${OUT}/movement-tests" "${SOURCES[@]}"
"${OUT}/movement-tests"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
xcrun --sdk iphonesimulator swiftc -swift-version 5 -target arm64-apple-ios26.0-simulator -sdk "${SDK}" \
  -typecheck -parse-as-library "${SOURCES[@]}"
print 'PASS iOS simulator SDK typecheck (isolated movement sources)'
