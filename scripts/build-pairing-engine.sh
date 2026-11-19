#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
PACKAGE_DIR="${PROJECT_ROOT}/Native/RoamPairingFFI"
BUILD_DIR="${ROAM_PAIRING_BUILD_DIR:-${PROJECT_ROOT}/work/pairing-engine}"
OUTPUT_DIR="${ROAM_PAIRING_OUTPUT_DIR:-${PROJECT_ROOT}/Frameworks/RoamPairingFFI.xcframework}"
LOCAL_TOOLCHAIN_ROOT="${PROJECT_ROOT:h:h}/.toolchains"

if [[ -e "${OUTPUT_DIR}" ]]; then
    print -u2 "${OUTPUT_DIR} already exists. Set ROAM_PAIRING_OUTPUT_DIR to build a separate copy."
    exit 1
fi

if [[ -x "${LOCAL_TOOLCHAIN_ROOT}/cargo/bin/cargo" ]]; then
    CARGO_BIN="${LOCAL_TOOLCHAIN_ROOT}/cargo/bin/cargo"
    export CARGO_HOME="${LOCAL_TOOLCHAIN_ROOT}/cargo"
    export RUSTUP_HOME="${LOCAL_TOOLCHAIN_ROOT}/rustup"
elif command -v cargo >/dev/null 2>&1; then
    CARGO_BIN="$(command -v cargo)"
else
    print -u2 "Rust is required. Install Rust with rustup, then run this script again."
    exit 1
fi

export DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
export CARGO_TARGET_DIR="${BUILD_DIR}/target"
export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-26.0}"
mkdir -p "${BUILD_DIR}" "${OUTPUT_DIR:h}"

for rust_target in aarch64-apple-ios aarch64-apple-ios-sim; do
    "${CARGO_BIN}" build \
        --locked \
        --manifest-path "${PACKAGE_DIR}/Cargo.toml" \
        --release \
        --target "${rust_target}"
done

xcrun xcodebuild -create-xcframework \
    -library "${CARGO_TARGET_DIR}/aarch64-apple-ios/release/libroam_pairing_ffi.a" \
    -headers "${PACKAGE_DIR}/include" \
    -library "${CARGO_TARGET_DIR}/aarch64-apple-ios-sim/release/libroam_pairing_ffi.a" \
    -headers "${PACKAGE_DIR}/include" \
    -output "${OUTPUT_DIR}"

print "Built ${OUTPUT_DIR}"
