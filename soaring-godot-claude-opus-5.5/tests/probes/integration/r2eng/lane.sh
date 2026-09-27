#!/bin/bash
# Round-2 engineering verifier: run named probe jobs one after another (a lane).
# Timeline: artifacts/integration/verify/r2eng/lanes.txt
ROOT=/Users/don/Projects/Soaring/soaring-godot-claude-opus-5.5
HERE="$ROOT/tests/probes/integration/r2eng"
OUT="$ROOT/artifacts/integration/verify/r2eng"
cd "$ROOT"
PR=(res://tests/runner.tscn -- --dir=res://tests/probes/integration/r2eng --fresh-settings)
job() { # name cmd...
	local name=$1; shift
	echo "$(date +%H:%M:%S) start $name load $(sysctl -n vm.loadavg)" >> "$OUT/lanes.txt"
	"$@" > "$OUT/job_$name.log" 2>&1
	local code=$?
	local res=$(grep -E "^\[test\] =====" "$OUT/job_$name.log" | tail -1)
	echo "$(date +%H:%M:%S) end $name exit $code: $res" >> "$OUT/lanes.txt"
}
for j in "$@"; do
	case "$j" in
		exact_assist|exact_assist_base_reach) job $j bash "$HERE/mutbatch2.sh" $j;;
		tail_quest) job $j env GD_TIMEOUT=1200 tools/gd.sh v2e_tail --headless --fixed-fps 72 "${PR[@]}" --suite=frame_tail --quality=quest --tail_s=180;;
		tail_full) job $j env GD_TIMEOUT=1200 tools/gd.sh v2e_tail --headless --fixed-fps 72 "${PR[@]}" --suite=frame_tail --quality=full --tail_s=180;;
		desk) job $j env GD_TIMEOUT=600 tools/gd.sh v2e_desk --rendering-method forward_plus --resolution 1280x720 "${PR[@]}" --suite=desktop_shots;;
		leak_*) job $j env GD_TIMEOUT=1500 tools/gd.sh v2e_leak --headless --fixed-fps 72 "${PR[@]}" --suite=run_cycle_leak --variant=${j#leak_} --cycles=10;;
		prog_quest) job $j env GD_TIMEOUT=2400 tools/gd.sh v2e_prog --headless --fixed-fps 72 "${PR[@]}" --suite=progress_real --quality=quest --prog_s=1500 --prog_seed=5;;
		prog_full) job $j env GD_TIMEOUT=2400 tools/gd.sh v2e_prog --headless --fixed-fps 72 "${PR[@]}" --suite=progress_real --quality=full --prog_s=1500 --prog_seed=5;;
		soak) job $j env GD_TIMEOUT=2600 tools/gd.sh v2e_soak --headless --fixed-fps 72 res://tests/runner.tscn -- --dir=res://tests/soak --suite=integration_soak --fresh-settings;;
		ai_perf) job $j env GD_TIMEOUT=600 tools/gd.sh v2e_suite_ai --headless res://tests/runner.tscn -- --suite=unit/ai/perf;;
		pacing_strict) job $j env GD_TIMEOUT=1200 tools/gd.sh v2e_suite_game --headless res://tests/runner.tscn -- --suite=unit/game/pacing --strict_evidence;;
		*) echo "$(date +%H:%M:%S) unknown job $j" >> "$OUT/lanes.txt";;
	esac
done
echo "$(date +%H:%M:%S) lane done: $*" >> "$OUT/lanes.txt"
