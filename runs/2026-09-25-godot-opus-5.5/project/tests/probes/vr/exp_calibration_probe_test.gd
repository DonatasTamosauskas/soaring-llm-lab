extends TestCase
## Verifier probe (experience lens), V3 calibration: the area's suite uses
## synthetic players built with EXACTLY the calibrator's body model
## (shoulder width = 0.23 x span, shoulder drop = 0.15 x height, the same
## neck pivot) and a textbook capture pose, so "consistent" there is close to
## true by construction. Real people differ. This probe varies what the
## calibrator has to assume or guess:
##   - shoulder width 0.20 / 0.26 of the span (broad or narrow shoulders),
##   - ape index 0.95 / 1.05 (height != span),
##   - the capture pose: arms held 12° low, 8° high, hands 10° forward,
##     elbows soft (15°), head turned 25° towards a hand, head pitched down,
## and checks that the same gesture still reads the same after calibration.
## Thresholds are looser than the unit suite's (0.03 / 1° / 0.02) because
## the bodies really differ: extension 0.10, twist 3°, pitch 0.05.

const DT := 1.0 / 90.0

const GESTURES := {
	"spread": [0.0, 0.0, 0.0, 0.0, 0.0],
	"glide": [-45.0, 0.0, 0.0, 0.0, 40.0],
	"twist_up_20": [-5.0, 0.0, 20.0, 20.0, 10.0],
	"twist_down_20": [-5.0, 0.0, -20.0, -20.0, 10.0],
	"aileron_20": [-5.0, 0.0, 20.0, -20.0, 10.0],
	"half_fold": [-20.0, 0.0, 0.0, 0.0, 105.0],
	"arms_down": [-85.0, 0.0, 0.0, 0.0, 0.0],
}

var _rng := RandomNumberGenerator.new()


func before_each() -> void:
	_rng.seed = 4321


func feed(cal: WingCalibrator, h: VRHumanPose, seconds: float, noise_mm: float = 0.5) -> void:
	for i in int(round(seconds / DT)):
		var hd := h.head_transform()
		var l := h.hand_transform(0)
		var r := h.hand_transform(1)
		if noise_mm > 0.0:
			var k := noise_mm * 0.001
			hd.origin += Vector3(_rng.randfn(0, k), _rng.randfn(0, k), _rng.randfn(0, k))
			l.origin += Vector3(_rng.randfn(0, k), _rng.randfn(0, k), _rng.randfn(0, k))
			r.origin += Vector3(_rng.randfn(0, k), _rng.randfn(0, k), _rng.randfn(0, k))
		cal.measure(hd, l, r, 7, DT)


func pose(h: VRHumanPose, g: Array) -> void:
	h.dihedral = [deg_to_rad(g[0]), deg_to_rad(g[0])]
	h.sweep = [deg_to_rad(g[1]), deg_to_rad(g[1])]
	h.twist = [deg_to_rad(g[2]), deg_to_rad(g[3])]
	h.elbow = [deg_to_rad(g[4]), deg_to_rad(g[4])]
	h.head_yaw = 0.0
	h.head_pitch = 0.0


func readings(cal: WingCalibrator, h: VRHumanPose) -> Dictionary:
	var out := {}
	for g in GESTURES:
		pose(h, GESTURES[g])
		feed(cal, h, 0.15, 0.0)
		out[g] = [cal.extension[0], cal.extension[1], rad_to_deg(cal.twist[0]), rad_to_deg(cal.twist[1]), cal.pitch_command()]
	return out


## A real-ish body: span, shoulder ratio, ape index, wrist habit.
func body(span: float, shoulder_ratio: float, ape: float, habit_l: float, habit_r: float) -> VRHumanPose:
	var h := VRHumanPose.new()
	var height := span / ape + 0.16
	h.arm_span = span
	h.shoulder_width = shoulder_ratio * span
	h.shoulder_drop = 0.15 * height
	h.eye_height = 0.935 * height
	h.twist_offset = [deg_to_rad(habit_l), deg_to_rad(habit_r)]
	return h


## Capture styles: [dihedral°, sweep°, elbow°, head yaw°, head pitch°].
const CAPTURES := {
	"textbook": [-5.0, 0.0, 0.0, 0.0, 0.0],
	"arms_12_low": [-12.0, 0.0, 0.0, 0.0, 0.0],
	"arms_level_0": [0.0, 0.0, 0.0, 0.0, 0.0],
	"arms_5_high": [5.0, 0.0, 0.0, 0.0, 0.0],
	"arms_8_high": [8.0, 0.0, 0.0, 0.0, 0.0],
	"hands_forward_10": [-5.0, 10.0, 0.0, 0.0, 0.0],
	"soft_elbows_15": [-5.0, 0.0, 15.0, 0.0, 0.0],
	"looking_at_hand": [-5.0, 0.0, 0.0, 25.0, -15.0],
}


func capture(h: VRHumanPose, style: Array) -> WingCalibrator:
	var cal := WingCalibrator.new()
	h.set_arms(deg_to_rad(style[0]), deg_to_rad(style[1]), 0.0, deg_to_rad(style[2]))
	h.head_yaw = deg_to_rad(style[3])
	h.head_pitch = deg_to_rad(style[4])
	feed(cal, h, 2.2)
	return cal


func test_real_bodies_and_capture_styles_read_consistently() -> void:
	var ref_h := body(1.6, 0.23, 1.0, 0.0, 0.0)
	var ref := readings(capture(ref_h, CAPTURES["textbook"]), ref_h)
	var worst := {"ext": 0.0, "twist": 0.0, "pitch": 0.0}
	var worst_case := {"ext": "", "twist": "", "pitch": ""}
	var not_captured: Array[String] = []
	var n := 0
	for span in [1.45, 1.75, 1.95]:
		for sr in [0.20, 0.26]:
			for ape in [0.95, 1.05]:
				for habit in [[20.0, 20.0], [-20.0, 15.0]]:
					for cs in CAPTURES:
						var h := body(span, sr, ape, habit[0], habit[1])
						var cal := capture(h, CAPTURES[cs])
						var tag := "span %.2f sh %.2f ape %.2f habit %s capture %s" % [span, sr, ape, str(habit), cs]
						if not cal.calibrated:
							not_captured.append(tag)
							continue
						n += 1
						var r := readings(cal, h)
						for g in GESTURES:
							var a: Array = r[g]
							var b: Array = ref[g]
							var de := maxf(absf(a[0] - b[0]), absf(a[1] - b[1]))
							var dt := maxf(absf(a[2] - b[2]), absf(a[3] - b[3]))
							var dp := absf(a[4] - b[4])
							if de > worst["ext"]:
								worst["ext"] = de
								worst_case["ext"] = "%s / %s" % [tag, g]
							if dt > worst["twist"]:
								worst["twist"] = dt
								worst_case["twist"] = "%s / %s" % [tag, g]
							if dp > worst["pitch"]:
								worst["pitch"] = dp
								worst_case["pitch"] = "%s / %s" % [tag, g]
	metric("players_calibrated", n)
	metric("not_captured", not_captured.size())
	metric("worst_ext_diff", worst["ext"])
	metric("worst_twist_diff_deg", worst["twist"])
	metric("worst_pitch_diff", worst["pitch"])
	metric("worst_ext_case", worst_case["ext"])
	metric("worst_twist_case", worst_case["twist"])
	metric("worst_pitch_case", worst_case["pitch"])
	print("[vr-verify] calibration probe: %d players, not captured %d, worst ext %.3f (%s), twist %.2f° (%s), pitch %.3f (%s)" % [
		n, not_captured.size(), worst["ext"], worst_case["ext"], worst["twist"], worst_case["twist"], worst["pitch"], worst_case["pitch"]])
	if not not_captured.is_empty():
		print("[vr-verify] not captured: ", not_captured.slice(0, 6))
	eq(not_captured.size(), 0, "every natural capture style is accepted")
	lt(worst["ext"], 0.10, "extension consistent within 0.10 across real bodies/capture styles")
	lt(worst["twist"], 3.0, "wrist twist consistent within 3°")
	lt(worst["pitch"], 0.05, "pitch command consistent within 0.05")


## Persist -> reload through a JSON round trip (flight's WingCalibration
## writes flat arrays; a JSON-backed store would too) keeps the readings.
func test_json_round_trip_keeps_readings() -> void:
	var h := body(1.8, 0.24, 1.0, 22.0, -18.0)
	var cal := capture(h, CAPTURES["textbook"])
	var before := readings(cal, h)
	var d := cal.to_dict()
	var flat := {}
	for k in d:
		var v: Variant = d[k]
		if v is Basis:
			flat[k] = VRMath.basis_to_array(v)
		elif v is Vector3:
			flat[k] = VRMath.vec_to_array(v)
		else:
			flat[k] = v
	var parsed: Variant = JSON.parse_string(JSON.stringify(flat))
	var cal2 := WingCalibrator.new()
	check(cal2.from_dict(parsed as Dictionary), "loaded from JSON")
	check(not cal2.auto_capture, "a loaded calibration does not re-capture automatically")
	var after := readings(cal2, h)
	var worst := 0.0
	for g in GESTURES:
		for k in 5:
			worst = maxf(worst, absf(float(before[g][k]) - float(after[g][k])) / (1.0 if k != 2 and k != 3 else 20.0))
	lt(worst, 0.01, "JSON round trip reads the same (worst %.4f)" % worst)
	# Flight's own WingCalibration reads VR's native dict (the Settings form).
	var wc := WingCalibration.new()
	wc.from_dict(d)
	near(wc.arm_span, cal.arm_span, 1e-4, "flight's WingCalibration reads VR's arm span")
	check(wc.neutral_left.is_equal_approx(cal.neutral[0]), "flight's WingCalibration reads VR's neutral basis")
	check(wc.forearm_axis_right.is_equal_approx(cal.forearm_axis[1]), "flight's WingCalibration reads VR's forearm axis")


## Breakdown: which assumption breaks the readings? One factor at a time,
## everything else textbook (1.6 m, 0.23 shoulders, ape 1, no habit).
func test_breakdown_one_factor_at_a_time() -> void:
	var ref_h := body(1.6, 0.23, 1.0, 0.0, 0.0)
	var ref := readings(capture(ref_h, CAPTURES["textbook"]), ref_h)
	var rows: Array = []
	var cases := {}
	for cs in CAPTURES:
		cases["capture " + cs] = [body(1.6, 0.23, 1.0, 0.0, 0.0), CAPTURES[cs]]
	cases["shoulders 0.20"] = [body(1.6, 0.20, 1.0, 0.0, 0.0), CAPTURES["textbook"]]
	cases["shoulders 0.26"] = [body(1.6, 0.26, 1.0, 0.0, 0.0), CAPTURES["textbook"]]
	cases["ape 0.95"] = [body(1.6, 0.23, 0.95, 0.0, 0.0), CAPTURES["textbook"]]
	cases["ape 1.05"] = [body(1.6, 0.23, 1.05, 0.0, 0.0), CAPTURES["textbook"]]
	cases["habit +20/+20"] = [body(1.6, 0.23, 1.0, 20.0, 20.0), CAPTURES["textbook"]]
	for name in cases:
		var h: VRHumanPose = cases[name][0]
		var cal := capture(h, cases[name][1])
		var r := readings(cal, h)
		var line := "%-26s drop err %+.3f m |" % [name, cal.shoulder_drop - h.shoulder_drop]
		var worst_e := 0.0
		var worst_p := 0.0
		for g in GESTURES:
			var a: Array = r[g]
			var b: Array = ref[g]
			var de := maxf(absf(a[0] - b[0]), absf(a[1] - b[1]))
			var dp := absf(a[4] - b[4])
			worst_e = maxf(worst_e, de)
			worst_p = maxf(worst_p, dp)
			line += " %s e%.2f/%.2f p%+.2f/%+.2f |" % [g, a[0], b[0], a[4], b[4]]
		rows.append(line)
		metric("breakdown_" + name.replace(" ", "_"), {"ext": snappedf(worst_e, 0.001), "pitch": snappedf(worst_p, 0.001),
			"drop_err_m": snappedf(cal.shoulder_drop - h.shoulder_drop, 0.001)})
		print("[vr-verify] ", line)
	check(true, "breakdown printed")


## First launch, no calibration yet, the player skipped the lesson and is
## gliding: arms spread and still for 1.5 s with both wrists held 20°
## leading-edge-down to build speed (requirement 2). The automatic capture
## has no gate on the wrists or on the flight state (flight's own WingInput
## only auto-captures while perched/spawning/grounded), so a tilted glide
## becomes "flat" and is persisted and written into flight's calibration.
func test_auto_capture_does_not_take_a_pitched_glide_as_flat() -> void:
	var h := body(1.7, 0.23, 1.0, 0.0, 0.0)
	var cal := WingCalibrator.new()
	h.set_arms(deg_to_rad(-8.0), 0.0, deg_to_rad(-20.0), 0.0)
	feed(cal, h, 1.6)
	metric("captured_pitched_glide", cal.calibrated)
	# Now the same player holds truly flat wrists in a glide.
	h.set_arms(deg_to_rad(-8.0), 0.0, 0.0, 0.0)
	feed(cal, h, 0.2, 0.0)
	var pitch := cal.pitch_command()
	metric("flat_wrists_pitch_after_auto_capture", pitch)
	print("[vr-verify] auto capture on a 20°-LE-down glide: calibrated=%s, flat wrists then read pitch %+.2f (twist %.1f°/%.1f°)" % [
		str(cal.calibrated), pitch, rad_to_deg(cal.twist[0]), rad_to_deg(cal.twist[1])])
	lt(absf(pitch), 0.1, "flat wrists still read ~flat after the automatic capture (pitch %+.2f)" % pitch)
