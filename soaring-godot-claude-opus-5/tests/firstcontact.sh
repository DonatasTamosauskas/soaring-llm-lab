#!/usr/bin/env bash
# Somebody's first session, flown headlessly: they hold the controllers still,
# read what the game tells them, and try each gesture the way a person who has
# never done it tries it. Fails if the tutorial does not finish, if any of its
# promises turn out to be untrue, or if following them leaves the bird on the
# ground. See scripts/game/FirstContact.gd.
set -uo pipefail
cd "$(dirname "$0")/.."

output=$(godot --headless --xr-mode off --fixed-fps 90 -- --firstcontact=1 2>&1)
echo "$output" | sed -n '/=== First contact/,/^FIRST CONTACT/p'

if grep -q "FIRST CONTACT PASS" <<<"$output"; then
  exit 0
fi
grep -E "^  - " <<<"$output"
exit 1
