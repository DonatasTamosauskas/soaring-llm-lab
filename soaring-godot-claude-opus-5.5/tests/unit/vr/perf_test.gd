extends TestCase
## Per-frame CPU cost of the VR area's features on this Mac (headless,
## debug build): calibration measurement, wing layout, vignette measurement
## (its probe rays find a floor and two walls, as low flight
## along a hedge does) and update, haptics scheduling, controller polling,
## world-scale step (the bench: vr_perf_bench.gd).
##
## Fix round 3: the unit suite must be deterministic, and wall-clock time
## on this shared Mac is not (a verifier saw the 100 µs gate flake once in
## ~28 runs under load). So this test pins the WORK (the worst case really
## is measured: every feather re-laid every frame, every ray hitting) and
## records the time as metrics; the time budget itself (fastest block
## < 100 µs per frame) is gated by the on-demand suite
##   tools/gd.sh vr --headless res://tests/runner.tscn -- --dir=res://tests/sim --suite=perf
## Quest's cores are ~3-4x slower single-threaded (docs/research/QUEST.md
## §4), and GDScript shares the main thread with 60 birds.

const Bench := preload("res://tests/unit/vr/vr_perf_bench.gd")


func test_vr_frame_cost() -> void:
	var r: Dictionary = await Bench.run(self)
	check(bool(r["calibrated"]), "calibrated before measuring")
	eq(int(r["relays"]), Bench.FRAMES, "worst case measured: wings re-laid every frame")
	gt(float(r["ray_hits"]), 0.95 * Bench.FRAMES, "worst case measured: the vignette's probe rays hold a surface every frame (%d/%d)" % [r["ray_hits"], Bench.FRAMES])
	metric("best_block_us_per_frame", snappedf(float(r["best_us"]), 0.1))
	metric("mean_us_per_frame", snappedf(float(r["mean_us"]), 0.1))
	metric("block_means_us", r["blocks_us"])
	metric("parts_us", r["parts_us"])
	metric("load_avg", r["load"])
	print("[vr] VR frame cost: best block %.1f us/frame, median %.1f, mean %.1f %s (load %s; gated in tests/sim/perf)" % [r["best_us"],
		r["median_us"], r["mean_us"], str(r["parts_us"]), r["load"]])
