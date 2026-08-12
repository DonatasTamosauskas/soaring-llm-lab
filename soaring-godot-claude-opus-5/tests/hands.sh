#!/usr/bin/env bash
# Flies the real game through the real wing sensor with the controllers held
# still at a range of separations, and fails if any of them ends with the bird
# on the ground.
#
# This is the test that was missing. WingInput was covered in isolation and the
# flight model was covered in isolation, but nothing drove the two together the
# way a headset does — so a player holding the controllers naturally flew into
# the terrain in eight seconds and every suite stayed green.
set -uo pipefail
cd "$(dirname "$0")/.."

status=0
for separation in 0.10 0.25 0.40 0.60 0.90 1.30; do
  output=$(godot --headless --xr-mode off --fixed-fps 90 -- --hands="$separation" 2>&1)
  summary=$(grep -E "span ranged" <<<"$output")
  if grep -q "HANDS REPRO PASS" <<<"$output"; then
    printf "  ok    %.2f m apart   %s\n" "$separation" "$summary"
  else
    printf "  FAIL  %.2f m apart   %s\n" "$separation" "$summary"
    grep -E "^  - " <<<"$output"
    status=1
  fi
done

[ $status -eq 0 ] && echo "HANDS ALL PASS"
exit $status
