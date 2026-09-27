extends TestCase
## VERIFIER PROBE (vr, round 3). Not part of the area suite:
##   tools/gd.sh vr_verify --headless res://tests/runner.tscn -- --dir=res://tests/probes/vr --suite=r3x_calibration
## The builder bounds calibration error at the corners of a body box, with
## each capture style applied ALONE (arms 12° low .. 8° high, hands 10°
## forward, elbows 15° soft, looking at a hand), and argues every factor is
## monotonic so the corners are the worst case. Real players combine them.
## Probe: (a) the body corners x COMBINED styles; (b) 5 fresh seeds x 120
## players with continuously random, combined capture styles. Bars: the
## builder's own REAL_BOUNDS (calibration_test.gd) and the brief's grid
## tolerance is not re-used here.

const CalT := preload("res://tests/unit/vr/calibration_test.gd")
const DEG := PI / 180.0

var T: Node


func before_all() -> void:
	T = CalT.new()
	add_child(T)


func after_all() -> void:
	T.queue_free()


func body(f: Array, habit: Array, st: Array) -> VRHumanPose:
	var h := VRHumanPose.new()
	var stature: float = f[0] / f[2] + 0.16
	h.arm_span = f[0]
	h.shoulder_width = f[1] * f[0]
	h.shoulder_drop = f[3] * stature
	h.eye_height = f[4] * stature
	h.room_offset = Vector3(0.0, f[5], 0.0)
	h.twist_offset = [habit[0] * DEG, habit[1] * DEG]
	h.set_arms(st[0] * DEG, st[1] * DEG, 0.0, st[2] * DEG)
	h.head_yaw = st[3] * DEG
	h.head_pitch = st[4] * DEG
	return h


func test_combined_capture_styles() -> void:
	var ref_h: VRHumanPose = T.player(1.6, [0.0, 0.0])
	var ref: Dictionary = T.readings(T.calibrated_for(ref_h), ref_h)
	var bounds: Dictionary = CalT.REAL_BOUNDS
	var combos := {
		"high+forward+soft+look": [8.0, 10.0, 15.0, 25.0, -15.0],
		"low+forward+soft+look": [-12.0, 10.0, 15.0, 25.0, -15.0],
		"high+soft": [8.0, 0.0, 15.0, 0.0, 0.0],
		"low+soft+look": [-12.0, 0.0, 15.0, -25.0, -15.0],
	}
	var corners: Dictionary = T.new_worst()
	for cname in combos:
		for mask in 64:
			var f := [2.0 if mask & 1 else 1.4, 0.26 if mask & 2 else 0.20, 1.05 if mask & 4 else 0.95,
				0.16 if mask & 8 else 0.14, 0.945 if mask & 16 else 0.925, 0.03 if mask & 32 else -0.03]
			for habit in [[25.0, 25.0], [-25.0, -25.0], [25.0, -25.0]]:
				T.score_player(body(f, habit, combos[cname]), ref, corners, "%s %s habit %s" % [cname, str(f), str(habit)])
	var rnd: Dictionary = T.new_worst()
	for s in [11, 99, 31337, 5, 2027]:
		var rng := RandomNumberGenerator.new()
		rng.seed = s
		for n in 120:
			var f := [rng.randf_range(1.4, 2.0), rng.randf_range(0.20, 0.26), rng.randf_range(0.95, 1.05),
				rng.randf_range(0.14, 0.16), rng.randf_range(0.925, 0.945), rng.randf_range(-0.03, 0.03)]
			var habit := [rng.randf_range(-25.0, 25.0), rng.randf_range(-25.0, 25.0)]
			var st := [rng.randf_range(-12.0, 8.0), rng.randf_range(0.0, 10.0), rng.randf_range(0.0, 15.0),
				rng.randf_range(-25.0, 25.0), rng.randf_range(-15.0, 0.0)]
			T.score_player(body(f, habit, st), ref, rnd, "seed %d #%d %s %s" % [s, n, str(f), str(st)])
	var rc: Dictionary = T.worst_row(corners)
	var rr: Dictionary = T.worst_row(rnd)
	print("[vr-verify] combined-style corners: ", rc, " missed ", corners["missed"])
	print("[vr-verify] 5 fresh seeds x 120, combined random styles: ", rr, " missed ", rnd["missed"])
	for k in bounds:
		print("[vr-verify]   worst %s: corners %s | random %s" % [k, corners.get(k + "_case", ""), rnd.get(k + "_case", "")])
	metric("combined_style_corners", rc)
	metric("fresh_seeds_combined_styles", rr)
	eq(corners["missed"], 0, "every combined-style corner player is captured")
	eq(rnd["missed"], 0, "every random player is captured")
	for k in bounds:
		lt(float(corners[k]), float(bounds[k]), "combined-style corners: %s %.4f within the builder's bound %.3f" % [k, corners[k], bounds[k]])
		lt(float(rnd[k]), float(bounds[k]), "fresh seeds, combined styles: %s %.4f within the builder's bound %.3f" % [k, rnd[k], bounds[k]])


## Seated players over the brief's grid (spans 1.4..2.0, wrist habits
## +-25°), captured the moment they spread (before the 5 s seated
## detection, as a player who sits down and spreads at once), and after it.
## Compared to a seated reference (1.6 m) with the grid's own tolerances.
func test_seated_grid_reads_consistently() -> void:
	var rows := {}
	for when in ["spread at once", "after 6 s seated"]:
		var ref_h := VRHumanPose.for_span(1.6, true)
		var ref_cal: WingCalibrator = T.perched()
		if when != "spread at once":
			ref_h.set_arms(deg_to_rad(-40.0))
			T.feed(ref_cal, ref_h, 6.0)
		ref_h.spread_pose()
		T.feed(ref_cal, ref_h, 2.0)
		var ref: Dictionary = T.readings(ref_cal, ref_h)
		var w := {"ext": 0.0, "twist": 0.0, "pitch": 0.0, "missed": 0}
		for span in [1.4, 1.6, 1.8, 2.0]:
			for off in [[0.0, 0.0], [25.0, 25.0], [-25.0, -25.0], [25.0, -25.0]]:
				var h := VRHumanPose.for_span(span, true)
				h.twist_offset = [off[0] * DEG, off[1] * DEG]
				var cal: WingCalibrator = T.perched()
				if when != "spread at once":
					h.set_arms(deg_to_rad(-40.0))
					T.feed(cal, h, 6.0)
				h.spread_pose()
				T.feed(cal, h, 2.0)
				if not cal.calibrated:
					w["missed"] += 1
					continue
				var r: Dictionary = T.readings(cal, h)
				for g in r:
					var a: Array = r[g]
					var b: Array = ref[g]
					w["ext"] = maxf(w["ext"], maxf(absf(a[0] - b[0]), absf(a[1] - b[1])))
					if T.twist_comparable(a, b):
						w["twist"] = maxf(w["twist"], maxf(absf(a[2] - b[2]), absf(a[3] - b[3])))
						w["pitch"] = maxf(w["pitch"], absf(a[4] - b[4]))
		rows[when] = w
		print("[vr-verify] seated grid (%s): %s" % [when, str(w)])
		eq(w["missed"], 0, "seated (%s): every player captured" % when)
		lt(w["ext"], 0.03, "seated (%s): extension agrees within 0.03 (%.4f)" % [when, w["ext"]])
		lt(w["twist"], 1.0, "seated (%s): twist agrees within 1° (%.3f)" % [when, w["twist"]])
		lt(w["pitch"], 0.02, "seated (%s): pitch agrees within 0.02 (%.4f)" % [when, w["pitch"]])
	metric("seated_grid", rows)
