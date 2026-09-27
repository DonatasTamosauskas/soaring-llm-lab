#!/bin/bash
# The brief's pacing through the real game: a batch of whole runs of
# scenes/main.tscn played by the competent person (tests/shots/integration_pacing.gd),
# WORKERS at a time, one sandbox per worker, then the batch's summary.
#
#   tests/shots/integration_pacing.sh <batch> [--seeds="1 2 3"] [--tiers="full quest"]
#       [--minutes=40] [--workers=4] [--extra="--growth=1.3,0.03"]
#
# Part files: artifacts/integration/pacing/<batch>/part_<tier>_<seed>.json,
# logs next to them; the summary: artifacts/integration/pacing/<batch>/summary.json
# (tests/shots/integration_pacing_merge.py). Every run dies at GD_TIMEOUT
# (2700 s); the script waits for all its workers before it returns.
# Sandbox names (core loop round: several agents run batches on one
# machine): the frozen copy is .sandboxes/${IP_SRC_PREFIX}<batch> and the
# workers ${IP_WORKER_PREFIX}0.. (defaults: integration's ip_src_ / ip_w).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
IP_SRC_PREFIX="${IP_SRC_PREFIX:-ip_src_}"
IP_WORKER_PREFIX="${IP_WORKER_PREFIX:-ip_w}"
export IP_SRC_PREFIX IP_WORKER_PREFIX
BATCH="${1:?usage: integration_pacing.sh <batch> [options]}"
# Every run of a batch plays the same code: the batch runs from a frozen copy
# of the tree (.sandboxes/ip_src_<batch>; its artifacts and addons are links
# to the real ones), so edits made while it runs never mix into it (every
# part file also records the code's fingerprint).
if [ -z "${IP_FROZEN:-}" ]; then
	# (IP_SRC_DIR: one frozen copy re-used by successive batches - its
	# workers' imports are then incremental; every batch still re-syncs it.)
	FZ="$ROOT/.sandboxes/${IP_SRC_DIR:-${IP_SRC_PREFIX}$BATCH}"
	mkdir -p "$FZ"
	rsync -a --delete --exclude '/.godot/' --exclude '/.sandboxes/' --exclude '/artifacts' --exclude '/.git/' \
		--exclude '/build/' --exclude '/addons' --exclude '/android/' "$ROOT/" "$FZ/"
	# The copy's artifacts is a real directory, which gd.sh keeps out of the
	# workers' sandboxes; only its integration/ links to the real one. (A
	# link named artifacts is not a directory to gd.sh's rsync filter: every
	# worker then imported the whole shared artifacts tree - ~1900 images,
	# minutes per import, *.import files written beside other areas' shots.)
	[ -L "$FZ/artifacts" ] && rm "$FZ/artifacts"
	mkdir -p "$FZ/artifacts" "$ROOT/artifacts/integration"
	ln -sfn "$ROOT/artifacts/integration" "$FZ/artifacts/integration"
	ln -sfn "$ROOT/addons" "$FZ/addons"
	# An experiment: --patches=<dir> applies every <dir>/*.patch (paths
	# relative to the tree, `diff -u tree/file changed/file`) to the frozen
	# copy only. The part files' fingerprint then says it was not the tree.
	for a in "$@"; do
		case "$a" in
			--patches=*)
				for pf in "${a#--patches=}"/*.patch; do
					(cd "$FZ" && patch -p0 --forward --quiet < "$pf") || { echo "patch $pf failed" >&2; exit 3; }
				done ;;
		esac
	done
	IP_FROZEN=1 exec bash "$FZ/tests/shots/integration_pacing.sh" "$@"
fi
shift
SEEDS="5 11 17 23 29 31 37 41 43 47 53 59"
TIERS="full quest"
MINUTES=40
WORKERS=4
EXTRA=""
for a in "$@"; do
	case "$a" in
		--seeds=*) SEEDS="${a#--seeds=}" ;;
		--tiers=*) TIERS="${a#--tiers=}" ;;
		--minutes=*) MINUTES="${a#--minutes=}" ;;
		--workers=*) WORKERS="${a#--workers=}" ;;
		--extra=*) EXTRA="${a#--extra=}" ;;
		--patches=*) ;;
		*) echo "unknown option $a" >&2; exit 2 ;;
	esac
done
OUT="$ROOT/artifacts/integration/pacing/$BATCH"
SEED_LOG="$ROOT/artifacts/integration/pacing/seed_log.tsv"
mkdir -p "$OUT"
JOBS="$OUT/jobs.txt"
: > "$JOBS"
for s in $SEEDS; do
	for t in $TIERS; do
		echo "$t $s" >> "$JOBS"
	done
done
echo "$(date +%H:%M:%S) batch $BATCH: $(wc -l < "$JOBS" | tr -d ' ') runs, $WORKERS workers, $MINUTES min, extra '$EXTRA'" >> "$OUT/batch.log"
# Import every worker's sandbox first, one at a time: parallel first imports
# of a fresh copy on a loaded machine ran past gd.sh's import limit and left
# audio samples unimported (78 load errors in each worker's first run).
for w in $(seq 0 $((WORKERS - 1))); do
	(cd "$ROOT" && GD_TIMEOUT=600 tools/gd.sh "${IP_WORKER_PREFIX}$w" --headless --quit < /dev/null > "$OUT/import_w$w.log" 2>&1)
done
worker() {
	local w=$1
	local n=0
	while read -r tier seed; do
		[ -z "$tier" ] && continue
		if [ $((n % WORKERS)) -eq "$w" ]; then
			local q=""
			[ "$tier" = "quest" ] && q="--quality=quest"
			[ "$tier" = "full" ] && q="--quality=full"
			local t0
			t0=$(date +%s)
			echo "$(date +%H:%M:%S) w$w start $tier $seed" >> "$OUT/batch.log"
			# Every run of every batch is logged before it starts (the
			# held-out check of real_pacing_test: a held-out seed must be on
			# no other batch's line).
			printf '%s\t%s\t%s\t%s\t%s\n' "$(date +%Y-%m-%dT%H:%M:%S)" "$BATCH" "$tier" "$seed" "$EXTRA" >> "$SEED_LOG"
			# shellcheck disable=SC2086
			(cd "$ROOT" && GD_TIMEOUT=2700 tools/gd.sh "${IP_WORKER_PREFIX}$w" --headless --fixed-fps 72 res://tests/shots/integration_pacing.tscn -- \
				--fresh-settings --seed="$seed" --minutes="$MINUTES" --batch="$BATCH" $q $EXTRA < /dev/null > "$OUT/run_${tier}_${seed}.log" 2>&1)
			echo "$(date +%H:%M:%S) w$w done $tier $seed rc=$? $(( $(date +%s) - t0 ))s" >> "$OUT/batch.log"
		fi
		n=$((n + 1))
	done < "$JOBS"
}
for w in $(seq 0 $((WORKERS - 1))); do
	worker "$w" &
done
wait
echo "$(date +%H:%M:%S) ALL DONE" >> "$OUT/batch.log"
python3 "$ROOT/tests/shots/integration_pacing_merge.py" "$OUT" > "$OUT/summary.txt" 2>&1
cat "$OUT/summary.txt"
