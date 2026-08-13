#!/usr/bin/env bash
# Every gate, in one command, failing if any of them fails.
#   tests/all.sh          all five gates (about three minutes)
#   tests/all.sh --quick  the four fast ones, skipping the hunting gate (~1 min)
#
# This exists because each gate is blind to what the others see, and a green
# run.sh reads like a green game. It is not: with the menu's pause broken
# outright, run.sh, probe.sh and firstcontact.sh all stayed green and only
# ui.sh noticed; with the hunting rules reverted to a state that caught nothing
# in ten minutes, all four of the others stayed green and only hunt.sh noticed.
#
#   run.sh          the headless suites — physics, world, art, birds, AI,
#                   progression, UI models, comfort, audio
#   probe.sh        flies the real game through the real world
#   ui.sh           opens the real menu in the real game and presses it
#   firstcontact.sh somebody's first session, gesture by gesture
#   hunt.sh         ten minutes of real hunting; the only gate that can see
#                   whether the chase converts
set -uo pipefail
cd "$(dirname "$0")/.."

quick=0
[[ "${1:-}" == "--quick" ]] && quick=1

gates=(run probe ui firstcontact)
[[ $quick -eq 0 ]] && gates+=(hunt)

failed=()
for gate in "${gates[@]}"; do
  printf '=== tests/%s.sh ===\n' "$gate"
  started=$SECONDS
  if "tests/$gate.sh" > "/tmp/soaring-gate-$gate.log" 2>&1; then
    summary=$(grep -E "assertions|PASS" "/tmp/soaring-gate-$gate.log" \
      | grep -v "ERROR" | tail -n 2 | tr '\n' ' ')
    printf '    PASS  (%ss)  %s\n' "$((SECONDS - started))" "$summary"
  else
    failed+=("$gate")
    printf '    FAIL  (%ss)\n' "$((SECONDS - started))"
    tail -n 25 "/tmp/soaring-gate-$gate.log"
  fi
done

echo
if [[ ${#failed[@]} -eq 0 ]]; then
  [[ $quick -eq 1 ]] && echo "ALL GATES PASS (quick: hunt.sh not run)" || echo "ALL GATES PASS"
  exit 0
fi
echo "FAILED: ${failed[*]}  (full output in /tmp/soaring-gate-*.log)"
exit 1
