#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EDITOR="${UNITY_EDITOR:-/Applications/Unity/Hub/Editor/6000.6.4f1/Unity.app/Contents/MacOS/Unity}"
mkdir -p "$ROOT/Logs" "$ROOT/Builds"
ACTION="${1:-setup}"
case "$ACTION" in
 setup) METHOD=Soaring.Editor.SoaringBuild.Setup;;
 full-world) METHOD=Soaring.Editor.SoaringBuild.FullWorld;;
 validate) METHOD=Soaring.Editor.SoaringBuild.Validate;;
 build-mac) METHOD=Soaring.Editor.SoaringBuild.BuildMac;;
 build-android) METHOD=Soaring.Editor.SoaringBuild.BuildAndroid;;
 play) export XR_RUNTIME_JSON="${META_XR_SIMULATOR_JSON:-/Applications/MetaXRSimulator.app/Contents/Resources/MetaXRSimulator/meta_openxr_simulator.json}" XR_SELECTED_RUNTIME_JSON="${META_XR_SIMULATOR_JSON:-/Applications/MetaXRSimulator.app/Contents/Resources/MetaXRSimulator/meta_openxr_simulator.json}"; exec "$EDITOR" -projectPath "$ROOT/Soaring" -executeMethod Soaring.Editor.SoaringBuild.Play -logFile "$ROOT/Logs/play.log";;
 test) exec "$EDITOR" -batchmode -projectPath "$ROOT/Soaring" -runTests -testPlatform EditMode -testResults "$ROOT/Logs/tests.xml" -logFile "$ROOT/Logs/test.log";;
 *) echo "Usage: $0 {setup|full-world|validate|test|build-mac|build-android|play}"; exit 2;;
esac
exec "$EDITOR" -batchmode -quit -projectPath "$ROOT/Soaring" -executeMethod "$METHOD" -logFile "$ROOT/Logs/$ACTION.log"
