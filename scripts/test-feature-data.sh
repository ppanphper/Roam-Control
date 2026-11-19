#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
OUT="${ROOT}/work/feature-data-tests"
mkdir -p "${OUT}"
xcrun swiftc -parse-as-library -o "${OUT}/feature-data-tests" \
  "${ROOT}/RoamControl/Models/LocationTarget.swift" \
  "${ROOT}/RoamControl/Models/AppPreferences.swift" \
  "${ROOT}/RoamControl/Models/RouteCoordinate.swift" \
  "${ROOT}/RoamControl/Models/MovementMode.swift" \
  "${ROOT}/RoamControl/Models/MovementRoute.swift" \
  "${ROOT}/RoamControl/Models/MovementSnapshot.swift" \
  "${ROOT}/RoamControl/Models/CoordinateCompatibility.swift" \
  "${ROOT}/RoamControl/Models/FeaturePreferences.swift" \
  "${ROOT}/RoamControl/Models/SessionRecoveryRecord.swift" \
  "${ROOT}/RoamControl/Services/Backup/BackupService.swift" \
  "${ROOT}/RoamControl/Services/Updates/ReleaseUpdateService.swift" \
  "${ROOT}/RoamControl/Services/Localization/AppLanguage.swift" \
  "${ROOT}/Tests/FeatureDataTests.swift"
"${OUT}/feature-data-tests"
