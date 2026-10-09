#!/bin/bash
# Round-2 engineering verifier: each mutation in its own copy, one at a time, against the tests
# that should pin it. Summary: artifacts/integration/verify/r2eng/mutants.txt
ROOT=/Users/don/Projects/Soaring/soaring-godot-claude-opus-5.5
HERE="$ROOT/tests/probes/integration/r2eng"
OUT="$ROOT/artifacts/integration/verify/r2eng/mut"
mkdir -p "$OUT"
run() { # name mut.py godot-args...
	local name=$1 mut=$2; shift 2
	echo "$(date +%H:%M:%S) start $name" >> "$OUT/../mutants.txt"
	GD_TIMEOUT=1200 bash "$HERE/mutrun.sh" "$name" "$mut" --headless "$@" > "$OUT/$name.log" 2>&1
	local res=$(grep -E "^\[test\] =====" "$OUT/$name.log" | tail -1)
	local fails=$(grep -E "^\[test\]   FAIL" "$OUT/$name.log" | sed 's/\[test\]   FAIL //' | tr '\n' ' ')
	echo "$(date +%H:%M:%S) $name: $res FAILED: [$fails]" >> "$OUT/../mutants.txt"
}
INTEG=(--fixed-fps 72 res://tests/runner.tscn -- --fresh-settings)
for spec in "$@"; do
	case "$spec" in
		base_reach) run base_reach mut_base_reach_quarter.py "${INTEG[@]}" --suite=unit/integration/game_catch;;
		no_npc_catches) run no_npc_catches mut_no_npc_catches.py "${INTEG[@]}" --suite=unit/integration/;;
		growth_no_flight) run growth_no_flight mut_growth_no_flight.py "${INTEG[@]}" --suite=unit/integration/game_flow;;
		npcs_ignore_player) run npcs_ignore_player mut_npcs_ignore_player.py "${INTEG[@]}" --suite=unit/integration/;;
		no_tier_celebration) run no_tier_celebration mut_no_tier_celebration.py "${INTEG[@]}" --suite=unit/integration/game_flow;;
		leak_small) run leak_small mut_leak_small.py "${INTEG[@]}" --suite=unit/integration/game_flow;;
		leak_small_soak) GDT=1; run leak_small_soak mut_leak_small.py --fixed-fps 72 res://tests/runner.tscn -- --dir=res://tests/soak --suite=integration_soak --fresh-settings;;
		exact_assist) run exact_assist mut_exact_assist.py "${INTEG[@]}" --suite=unit/integration/game_catch;;
		exact_assist_base_reach) run exact_assist_base_reach mut_exact_assist_base_reach.py "${INTEG[@]}" --suite=unit/integration/game_catch;;
		pristine_flow) run pristine_flow none "${INTEG[@]}" --suite=unit/integration/game_flow;;
		*) echo "unknown $spec" >> "$OUT/../mutants.txt";;
	esac
done
echo "$(date +%H:%M:%S) batch done: $*" >> "$OUT/../mutants.txt"
