#!/bin/bash
# Round-2 engineering verifier: every area suite, one at a time (not all at once).
# Logs: artifacts/integration/verify/r2eng/suite_<area>.log; timeline in suites_timeline.log.
ROOT=/Users/don/Projects/Soaring/soaring-godot-claude-opus-5.5
OUT=$ROOT/artifacts/integration/verify/r2eng
cd "$ROOT"
for area in ${@:-flight vr world ai birds ui audio core game}; do
	t0=$(date +%s)
	echo "$(date +%H:%M:%S) start $area load $(sysctl -n vm.loadavg)" >> $OUT/suites_timeline.log
	GD_TIMEOUT=1500 tools/gd.sh v2e_suite_$area --headless res://tests/runner.tscn -- --suite=unit/$area/ > $OUT/suite_$area.log 2>&1
	code=$?
	res=$(grep -E '^\[test\] =====' $OUT/suite_$area.log | tail -1)
	echo "$(date +%H:%M:%S) end $area exit $code ($(( $(date +%s) - t0 )) s): $res" >> $OUT/suites_timeline.log
	cp artifacts/tests/report_unit_${area}_.json $OUT/report_unit_${area}_r2eng.json 2>/dev/null
done
echo "$(date +%H:%M:%S) ALL DONE" >> $OUT/suites_timeline.log
