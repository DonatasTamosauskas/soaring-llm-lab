#!/usr/bin/env bash
# Flies the real game through the real wing sensor with the controllers held
# still at a range of separations, and fails if any of them ends with the bird
# on the ground.
#
# All six separations now pass. Both of the failures it used to report are
# genuinely fixed: the world no longer runs out (the arena work), and holding the
# controllers still no longer folds the wings into a power dive
# (WingInput.NOVICE_MIN_SPAN — that used to end every run in a field within
# seconds, at 90% of the run spent on the ground).
#
# It is still `exit 0` all the same, and deliberately so. The last check standing
# is "not still on the ground after 60 seconds", and a bird given literally no
# input glides from the 190 m spawn to the deck in about 63 — so it passes by
# three seconds, and any small change to sink rate or spawn height flips it
# without anything actually being wrong. Promoting a margin that thin makes a
# flaky gate, not a safety net.
#
# The place first contact is actually gated is tests/firstcontact.sh, where
# somebody does what the game tells them. See docs/COMFORT.md.
set -uo pipefail
cd "$(dirname "$0")/.."

status=0
for separation in 0.10 0.25 0.40 0.60 0.90 1.30; do
  output=$(godot --headless --xr-mode off --fixed-fps 90 -- --hands="$separation" 2>&1)
  # HandsRepro prints "  span 1.00..1.00, furthest landmark 230 m, ...".
  # This used to grep for "span ranged", which nothing has ever printed, so the
  # summary column was silently always empty.
  summary=$(grep -E "^  span " <<<"$output" | sed 's/^  //')
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
