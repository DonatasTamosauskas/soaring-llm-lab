#!/usr/bin/env bash
# Renders the world through the Forward Mobile renderer — the one a Quest
# actually uses — and fails if the frame contains Godot's "invalid material"
# magenta or if the scene is suspiciously empty.
#
# This exists because a shader variant that is fine on Forward+ can fail on
# Forward Mobile, and the failure is silent: no error, healthy draw calls,
# geometry still submitted. It shipped a build to a headset where every tree,
# building and pole was invisible. Run this before any Quest deploy.
set -uo pipefail
cd "$(dirname "$0")/.."

shot="${TMPDIR:-/tmp}/soaring_mobile_check.png"
output=$(godot --rendering-method mobile --xr-mode off \
  -- --capture="$shot" --capture_delay=8 --diag=1 2>&1 \
  | grep -E "\[Soaring\]|\[diag\]")

echo "$output"

broken=$(grep -oE "broken-shader pixels: [0-9.]+" <<<"$output" | grep -oE "[0-9.]+$")
draws=$(grep -oE "draws=[0-9]+" <<<"$output" | tail -1 | grep -oE "[0-9]+$")

status=0
if [ -z "${broken:-}" ]; then
  echo "FAIL: no frame was captured"
  status=1
elif awk "BEGIN{exit !($broken > 0.5)}"; then
  echo "FAIL: ${broken}% of the frame is broken-shader magenta (see $shot)"
  status=1
fi

if [ -z "${draws:-}" ] || [ "${draws:-0}" -lt 40 ]; then
  echo "FAIL: only ${draws:-0} draw calls — the world is not rendering"
  status=1
fi

[ $status -eq 0 ] && echo "MOBILE RENDER OK (${broken}% magenta, ${draws} draws)"
exit $status
