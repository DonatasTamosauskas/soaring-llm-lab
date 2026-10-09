#!/bin/bash
# Valley evidence batches for the game loop's pacing (fix round 5), from a
# FROZEN copy of the tree: other areas edit their code while a batch runs,
# and every run copies the tree it is started from, so all runs of a batch
# start from one snapshot (.sandboxes/gl_frozen_src; its artifacts and addons
# are links to the real ones). Every part file records the fingerprint of
# this area's code and the hashes of the AI, valley and core code it ran.
#
#   tests/shots/gameloop_batch.sh freeze               # snapshot the tree now
#   tests/shots/gameloop_batch.sh run <jobs> [workers]  # run a job file
#
# A job file has one run per line: <part name> <gameloop_pacing args...>, e.g.
#   com_100 --skills=competent --seed0=100
#   qcom_100 --skills=competent --seed0=100 --quest_npcs=28 --quest_lod_near=60 --quest_lod_far=140
# Every run gets --live_ai --integrated=1 --minutes=50 (or $MINUTES). A part
# already complete (artifacts/gameloop/integrated_live_part_<name>.json
# without "partial") is skipped, so a stopped batch resumes. Logs:
# artifacts/gameloop/batch_logs/<name>.log. Workers use sandboxes gl_p<k>
# inside the frozen copy (default 3 workers: the machine is shared).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FZ="$ROOT/.sandboxes/gl_frozen_src"
ART="$ROOT/artifacts/gameloop"
CMD="${1:?usage: gameloop_batch.sh freeze | run <jobs> [workers]}"

if [ "$CMD" = "freeze" ]; then
	mkdir -p "$FZ" "$ART/batch_logs"
	rsync -a --delete --exclude '/.godot/' --exclude '/.sandboxes/' --exclude '/artifacts' --exclude '/.git/' \
		--exclude '/build/' --exclude '/addons' --exclude '/android/' "$ROOT/" "$FZ/"
	# The copy's artifacts: a real directory (gd.sh leaves a directory named
	# artifacts out of every worker sandbox; a LINK to the real artifacts was
	# copied into them, Godot imported all of it, and a stray copy of this
	# area's threat_watch.gd another area had left there with its class_name
	# shadowed the real ThreatWatch - fix round 5), holding .gdignore and a
	# link to the real artifacts/gameloop, where the runs write.
	[ -L "$FZ/artifacts" ] && rm "$FZ/artifacts"
	mkdir -p "$FZ/artifacts"
	touch "$FZ/artifacts/.gdignore"
	ln -sfn "$ROOT/artifacts/gameloop" "$FZ/artifacts/gameloop"
	ln -sfn "$ROOT/addons" "$FZ/addons"
	echo "$(date +%H:%M:%S) frozen $ROOT -> $FZ" | tee -a "$ART/batch_logs/freeze.log"
	exit 0
fi

JOBS="${2:?run <jobs> [workers]}"
WORKERS="${3:-3}"
MINUTES="${MINUTES:-50}"
# Worker sandboxes are <WPREFIX><k> (a second batch at the same time needs
# another prefix, e.g. WPREFIX=gl_d).
WPREFIX="${WPREFIX:-gl_p}"
mkdir -p "$ART/batch_logs"
[ -d "$FZ" ] || { echo "no frozen copy: run '$0 freeze' first" >&2; exit 2; }

# Workers take the next unclaimed job (a claim is an atomic mkdir), so a
# slow run never holds the others' queue.
CLAIMS="$ART/batch_logs/claims_$(basename "$JOBS")_$$"
mkdir -p "$CLAIMS"
worker() {
	local w=$1
	while read -r name args; do
		[ -z "$name" ] && continue
		case "$name" in \#*) continue ;; esac
		mkdir "$CLAIMS/$name" 2>/dev/null || continue
		local part="$ART/integrated_live_part_$name.json"
		if [ -f "$part" ] && ! grep -q '"partial": true' "$part"; then
			continue
		fi
		local t0
		t0=$(date +%s)
		echo "$(date +%H:%M:%S) w$w start $name $args" >> "$ART/batch_logs/batch.log"
		# shellcheck disable=SC2086
		(cd "$FZ" && GD_TIMEOUT=2700 tools/gd.sh "$WPREFIX$w" --headless res://tests/shots/gameloop_pacing.tscn -- \
			--integrated=1 --minutes="$MINUTES" --live_ai $args --part="$name" < /dev/null \
			> "$ART/batch_logs/$name.log" 2>&1)
		echo "$(date +%H:%M:%S) w$w done $name rc=$? $(( $(date +%s) - t0 ))s" >> "$ART/batch_logs/batch.log"
	done < "$JOBS"
}

# First imports one at a time (parallel first imports of a fresh copy on a
# loaded machine can run past gd.sh's import limit), then a check that every
# worker resolves this area's classes to the frozen copy's own scripts.
for w in $(seq 0 $((WORKERS - 1))); do
	if [ ! -f "$FZ/.sandboxes/$WPREFIX$w/.godot/global_script_class_cache.cfg" ]; then
		(cd "$FZ" && GD_TIMEOUT=900 tools/gd.sh "$WPREFIX$w" --headless --quit < /dev/null > "$ART/batch_logs/import_$WPREFIX$w.log" 2>&1)
	fi
	if [ -e "$FZ/.sandboxes/$WPREFIX$w/artifacts" ] || grep -q 'res://artifacts/' "$FZ/.sandboxes/$WPREFIX$w/.godot/global_script_class_cache.cfg"; then
		echo "worker sandbox $WPREFIX$w sees artifacts (stray classes could shadow the project's): delete it and re-run" >&2
		exit 3
	fi
done
for w in $(seq 0 $((WORKERS - 1))); do
	worker "$w" &
done
wait
rm -rf "$CLAIMS"
echo "$(date +%H:%M:%S) ALL DONE $JOBS" >> "$ART/batch_logs/batch.log"
