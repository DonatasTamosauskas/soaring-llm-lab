#!/bin/bash
# Round-3 engineering verifier: every area suite, one at a time, in one
# sandbox (one import). WAIT_PID: a run to wait for first.
ROOT=/Users/don/Projects/Soaring/soaring-godot-claude-opus-5.5
OUT=$ROOT/artifacts/integration/verify/r3eng
cd "$ROOT"
if [ -n "${WAIT_PID:-}" ]; then
	for i in $(seq 400); do kill -0 "$WAIT_PID" 2>/dev/null || break; sleep 5; done
	echo "$(date +%H:%M:%S) flight done (pid $WAIT_PID): $(grep -E '^\[test\] =====' "$OUT/suite_flight.log" | tail -1)" >> "$OUT/suites.txt"
fi
for s in ${SUITES:-vr world birds ui audio core ai game}; do
	echo "$(date +%H:%M:%S) start $s load $(sysctl -n vm.loadavg)" >> "$OUT/suites.txt"
	GD_TIMEOUT=1800 tools/gd.sh r3e_flight --headless res://tests/runner.tscn -- --suite=unit/$s/ > "$OUT/suite_$s.log" 2>&1
	echo "$(date +%H:%M:%S) $s exit $? load $(sysctl -n vm.loadavg): $(grep -E '^\[test\] =====' "$OUT/suite_$s.log" | tail -1)" >> "$OUT/suites.txt"
done
echo "$(date +%H:%M:%S) ALL DONE" >> "$OUT/suites.txt"
