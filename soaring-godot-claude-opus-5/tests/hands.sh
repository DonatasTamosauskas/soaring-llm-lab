#!/usr/bin/env bash
# Flies the real game through the real wing sensor with the controllers held
# still at a range of separations, and fails if any of them ends with the bird
# on the ground.
#
# Currently a diagnostic, not a gate: with the speculative onboarding fixes
# reverted, a bird given no input glides down and eventually leaves the world.
# Whether that should be prevented — and how — is a design question for the
# world-building and game-loop work, not something to paper over here. See
# docs/PARKED-quest-visibility.md.
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

echo "(diagnostic only — see docs/PARKED-quest-visibility.md)"
exit 0
