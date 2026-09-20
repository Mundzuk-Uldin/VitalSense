#!/bin/bash
# Compile the shared Swift networking layer for macOS and run it against a
# live risk server. Pass --seed-simulator to also push a sample history into
# a booted iOS Simulator so the results screens have something to show.
set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

xcrun swiftc -O -o "$BUILD_DIR/clientcheck" \
  "$APP_DIR/Shared/VitalsReading.swift" \
  "$APP_DIR/Shared/RiskPrediction.swift" \
  "$APP_DIR/Shared/RiskAPIClient.swift" \
  "$APP_DIR/tools/ClientCheck/main.swift"

if [[ "${1:-}" == "--seed-simulator" ]]; then
  HISTORY="$BUILD_DIR/history.json"
  "$BUILD_DIR/clientcheck" --emit-history "$HISTORY"
  HEX=$(xxd -p "$HISTORY" | tr -d '\n')
  xcrun simctl spawn booted defaults write com.bayhacks.VitalSense \
    scoredReadingHistory -data "$HEX"
  echo "Seeded history into the booted Simulator. Relaunch VitalSense to see it."
else
  "$BUILD_DIR/clientcheck"
fi
