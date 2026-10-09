#!/usr/bin/env bash
set -euo pipefail
EXAMPLE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="${QUEST_PROJECT_PATH:-$EXAMPLE_ROOT/QuestBootstrap}"
VERSION="$(sed -n 's/^m_EditorVersion: //p' "$PROJECT/ProjectSettings/ProjectVersion.txt")"
EDITOR="${UNITY_EDITOR:-/Applications/Unity/Hub/Editor/$VERSION/Unity.app/Contents/MacOS/Unity}"
RUNTIME="${META_XR_SIMULATOR_JSON:-/Applications/MetaXRSimulator.app/Contents/Resources/MetaXRSimulator/meta_openxr_simulator.json}"
[[ -x "$EDITOR" ]] || { echo "Unity editor missing: $EDITOR" >&2; exit 1; }
mkdir -p "$EXAMPLE_ROOT/Logs"
ACTION="${1:-play}"
case "$ACTION" in
  setup) METHOD=QuestProjectSetup.Setup ;;
  validate) METHOD=QuestProjectSetup.Validate ;;
  build-mac) METHOD=QuestProjectSetup.BuildMac ;;
  build-android) METHOD=QuestProjectSetup.BuildAndroid ;;
  profile) METHOD=QuestProjectSetup.CreateQuestProfile ;;
  play)
    [[ -f "$RUNTIME" ]] || { echo "Simulator manifest missing: $RUNTIME" >&2; exit 1; }
    export XR_RUNTIME_JSON="$RUNTIME" XR_SELECTED_RUNTIME_JSON="$RUNTIME"
    exec "$EDITOR" -projectPath "$PROJECT" -executeMethod QuestProjectSetup.PlaySimulator -logFile "$EXAMPLE_ROOT/Logs/play.log"
    ;;
  open) exec "$EDITOR" -projectPath "$PROJECT" -openfile "$PROJECT/Assets/QuestBootstrap/Scenes/QuestExample.unity" -logFile "$EXAMPLE_ROOT/Logs/editor.log" ;;
  *) echo "Usage: $0 {setup|validate|profile|build-mac|build-android|play|open}" >&2; exit 2 ;;
esac
exec "$EDITOR" -batchmode -quit -projectPath "$PROJECT" -executeMethod "$METHOD" -logFile "$EXAMPLE_ROOT/Logs/$ACTION.log"
