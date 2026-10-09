#!/usr/bin/env bash
set -euo pipefail
PORT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$PORT_ROOT/tools/unity.sh" test
"$PORT_ROOT/tools/unity.sh" build-mac
"$PORT_ROOT/tools/unity.sh" build-android
"$PORT_ROOT/tools/verify-apk.sh"
