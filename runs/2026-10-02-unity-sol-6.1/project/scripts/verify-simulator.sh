#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CAPTURES="${1:-$ROOT/Logs/captures}"
# Quit any earlier Soaring player normally before running this single-client check.
"$ROOT/scripts/run-simulator.sh" --smoke --verify-loop --capture "$CAPTURES" --quit-after-smoke
rg '^SOARING_(CHECK|SMOKE_DONE|ECOSYSTEM|TIMING)' "$ROOT/Logs/player.log"
rg -q '^SOARING_SMOKE_DONE passed=True$' "$ROOT/Logs/player.log"
rg -q '^QUEST_BOOTSTRAP_XR_RUNNING .*runtime=Meta XR Simulator' "$ROOT/Logs/player.log"
rg -q '^QUEST_BOOTSTRAP_DEVICE Meta Quest Pro Touch Controller OpenXR .*Left' "$ROOT/Logs/player.log"
rg -q '^QUEST_BOOTSTRAP_DEVICE Meta Quest Pro Touch Controller OpenXR .*Right' "$ROOT/Logs/player.log"
