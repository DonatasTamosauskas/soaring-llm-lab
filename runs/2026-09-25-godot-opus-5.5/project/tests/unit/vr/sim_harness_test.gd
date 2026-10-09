extends TestCase
## The simulator harness's own arithmetic (tests/sim/vr_sim.gd), pinned
## headless so a broken report cannot hide behind a simulator run.
## Fix round 6 (experience verifier): V1 reports frame pacing, not only the
## mean fps: percentiles of the frame intervals and the hitches (frames
## longer than 1.5 display intervals).

const Sim := preload("res://tests/sim/vr_sim.gd")


func test_frame_pacing_percentiles_and_hitches() -> void:
	# 1000 frames at 72 Hz: 970 on time, 20 at 20 ms (1.44 intervals: late,
	# not a visible hitch), 10 at 30 ms (2.16 intervals: dropped frames).
	var v := PackedFloat32Array()
	for i in 970:
		v.append(13.89)
	for i in 20:
		v.append(20.0)
	for i in 10:
		v.append(30.0)
	var p := Sim.frame_pacing(v, 72.0)
	eq(p["frames"], 1000, "every interval counted")
	near(float(p["budget_ms"]), 13.89, 0.01, "the budget is one 72 Hz interval")
	near(float(p["p50"]), 13.89, 0.01, "median on time")
	near(float(p["p95"]), 13.89, 0.01, "p95 on time (970 of 1000 are)")
	near(float(p["p99"]), 20.0, 0.01, "p99 falls in the late frames")
	near(float(p["max"]), 30.0, 0.01, "max is the worst frame")
	eq(p["over_1_5_intervals"], 10, "only frames over 1.5 intervals are hitches")
	near(float(p["over_pct"]), 1.0, 1e-6, "1% hitches")
	metric("pacing_example", p)


func test_frame_pacing_of_nothing_is_zero() -> void:
	var p := Sim.frame_pacing(PackedFloat32Array(), 90.0)
	eq(p["frames"], 0, "no frames")
	eq(p["over_1_5_intervals"], 0, "no hitches")
	eq(float(p["p99"]), 0.0, "no percentile")
