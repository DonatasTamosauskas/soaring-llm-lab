#!/usr/bin/env bash
set -euo pipefail
PORT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$PORT_ROOT/Soaring"
EDITOR="${UNITY_EDITOR:-/Applications/Unity/Hub/Editor/6000.6.4f1/Unity.app/Contents/MacOS/Unity}"
mkdir -p "$PORT_ROOT/Logs" "$PORT_ROOT/Builds"
ACTION="${1:-open}"
TARGET_ARGS=(-buildTarget OSXUniversal)
[[ "$ACTION" == build-android ]] && TARGET_ARGS=(-buildTarget Android)
case "$ACTION" in
 setup) METHOD=Soaring.Editor.ProjectSetup.Setup;;
 scene) METHOD=Soaring.Editor.ProjectSetup.RefreshScene;;
 validate) METHOD=Soaring.Editor.ProjectSetup.Validate;;
 build-mac) METHOD=Soaring.Editor.ProjectSetup.BuildMac;;
 build-android) METHOD=Soaring.Editor.ProjectSetup.BuildAndroid;;
 test) exec "$EDITOR" "${TARGET_ARGS[@]}" -batchmode -nographics -projectPath "$PROJECT" -runTests -testPlatform EditMode -testResults "$PORT_ROOT/Logs/editmode-results.xml" -logFile "$PORT_ROOT/Logs/test.log";;
 open) exec "$EDITOR" "${TARGET_ARGS[@]}" -projectPath "$PROJECT" -logFile "$PORT_ROOT/Logs/editor.log";;
 *) echo "Usage: $0 {setup|scene|validate|test|build-mac|build-android|open}" >&2;exit 2;;
esac
exec "$EDITOR" "${TARGET_ARGS[@]}" -batchmode -quit -projectPath "$PROJECT" -executeMethod "$METHOD" -logFile "$PORT_ROOT/Logs/$ACTION.log"
