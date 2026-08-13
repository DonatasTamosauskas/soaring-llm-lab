#!/usr/bin/env bash
# Somebody's first session, flown headlessly: they hold the controllers still,
# read what the game tells them, and try each gesture the way a person who has
# never done it tries it. Fails if the tutorial does not finish, if any of its
# promises turn out to be untrue, or if following them leaves the bird on the
# ground. See scripts/game/FirstContact.gd.
set -uo pipefail
cd "$(dirname "$0")/.."

# Hard deadline, because this gate can hang rather than fail. FirstContact waits
# on the tutorial completing, and if the player is killed on the way through it
# waits forever — observed looping "perched, caught, perched, caught" for
# minutes. A hung gate is worse than a failing one: it tells you nothing and it
# blocks everything behind it.
#
# Output goes via a file rather than a pipeline, so the watchdog cannot cost us
# the log we are about to read. Doing this with command substitution around a
# backgrounded job silently swallowed all output and reported a false failure.
DEADLINE=${FIRSTCONTACT_TIMEOUT:-90}
log=$(mktemp)
godot --headless --xr-mode off --fixed-fps 90 -- --firstcontact=1 > "$log" 2>&1 &
runner=$!
( sleep "$DEADLINE"; kill -9 "$runner" 2>/dev/null ) >/dev/null 2>&1 &
watchdog=$!
wait "$runner" 2>/dev/null
kill "$watchdog" 2>/dev/null
output=$(cat "$log"); rm -f "$log"
if ! grep -q "FIRST CONTACT" <<<"$output"; then
  echo "FIRST CONTACT TIMEOUT — no verdict within ${DEADLINE}s (the gate hung)"
  exit 1
fi
echo "$output" | sed -n '/=== First contact/,/^FIRST CONTACT/p'

if grep -q "FIRST CONTACT PASS" <<<"$output"; then
  exit 0
fi
grep -E "^  - " <<<"$output"
exit 1
