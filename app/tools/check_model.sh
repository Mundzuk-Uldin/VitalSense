#!/bin/bash
# Verify that the Swift scorer and the exported Core ML model agree with the
# PyTorch model they came from.
#
# Compiles the shared Swift sources for macOS and replays the frozen
# reference predictions from model/artifacts/reference.json.
set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_DIR="$(cd "$APP_DIR/.." && pwd)"
BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

xcrun coremlcompiler compile "$APP_DIR/Shared/VitalRisk.mlmodel" "$BUILD_DIR" >/dev/null

xcrun swiftc -O -o "$BUILD_DIR/modelcheck" \
  "$APP_DIR/Shared/VitalsReading.swift" \
  "$APP_DIR/Shared/RiskPrediction.swift" \
  "$APP_DIR/Shared/NEWS2.swift" \
  "$APP_DIR/Shared/RiskScorer.swift" \
  "$APP_DIR/tools/ModelCheck/main.swift"

if [[ "${1:-}" == "--seed-simulator" ]]; then
  HISTORY="$BUILD_DIR/history.json"
  "$BUILD_DIR/modelcheck" "$BUILD_DIR/VitalRisk.mlmodelc" \
    "$REPO_DIR/model/artifacts/reference.json" --emit-history "$HISTORY"
  xcrun simctl spawn booted defaults write com.bayhacks.VitalSense \
    scoredReadingHistory -data "$(xxd -p "$HISTORY" | tr -d '\n')"
  echo "Seeded history into the booted Simulator. Relaunch VitalSense to see it."
else
  "$BUILD_DIR/modelcheck" "$BUILD_DIR/VitalRisk.mlmodelc" "$REPO_DIR/model/artifacts/reference.json"
fi
