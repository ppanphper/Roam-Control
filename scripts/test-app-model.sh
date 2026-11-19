#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
OUT="${ROOT}/work/app-model-tests"
mkdir -p "${OUT}"
TEST_MAIN="${1:-Tests/AppModelIntegrationTests.swift}"
xcrun swiftc -parse-as-library -o "${OUT}/app-model-tests" \
  "${ROOT}/RoamControl/Models/LocationTarget.swift" \
  "${ROOT}/RoamControl/Models/AppPreferences.swift" \
  "${ROOT}/RoamControl/Models/RouteCoordinate.swift" \
  "${ROOT}/RoamControl/Models/MovementMode.swift" \
  "${ROOT}/RoamControl/Models/MovementRoute.swift" \
  "${ROOT}/RoamControl/Models/MovementSnapshot.swift" \
  "${ROOT}/RoamControl/Models/CoordinateCompatibility.swift" \
  "${ROOT}/RoamControl/Models/FeaturePreferences.swift" \
  "${ROOT}/RoamControl/Models/SessionRecoveryRecord.swift" \
  "${ROOT}/RoamControl/Services/Routes/CoordinateTransform.swift" \
  "${ROOT}/RoamControl/Services/Routes/MainlandCoordinateRegion.swift" \
  "${ROOT}/RoamControl/Services/Backup/BackupService.swift" \
  "${ROOT}/RoamControl/Services/Updates/ReleaseUpdateService.swift" \
  "${ROOT}/RoamControl/Services/UsageAnalyticsService.swift" \
  "${ROOT}/RoamControl/Services/Pairing/PairingService.swift" \
  "${ROOT}/RoamControl/App/AppModel.swift" \
  "${ROOT}/Tests/AppModelTestRuntime.swift" \
  "${ROOT}/${TEST_MAIN}"
"${OUT}/app-model-tests"
