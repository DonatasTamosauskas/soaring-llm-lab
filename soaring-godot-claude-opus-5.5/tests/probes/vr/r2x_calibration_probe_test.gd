extends TestCase
## VERIFIER PROBE (vr, round 2, experience lens), V3 calibration.
##   tools/gd.sh vr_verify --headless res://tests/runner.tscn -- --dir=res://tests/probes/vr --suite=r2x_cal
## The area's real-body test draws 120 players from ONE seed (2026) and
## asserts bounds (0.13 / 4° / 0.08 / 3 cm) that sit just above that seed's
## worst case (0.125 / 3.27° / 0.073 / 2.3 cm). Were the bounds fitted to the
## seed? Here: 5 other seeds x 120 players, the same factor ranges, the same
## 8 capture styles, the builder's own bounds; plus the corners of the
## factor box (every factor at an extreme at once), plus the brief's own
## 16-player grid with noisier trackers (1.5 mm) and a 72 Hz tick.
## Gate opened explicitly (as VRCalibration does while perched).

const DT := 1.0 / 90.0
const SPREAD_GESTURES := ["spread", "glide", "twist_up_20", "twist_down_20", "aileron_20", "arm_raise_40"]
const GESTURES := {
	"spread": [0.0, 0.0, 0.0, 0.0, 0.0],
	"glide": [-45.0, 0.0, 0.0, 0.0, 40.0],
	"twist_up_20": [-5.0, 0.0, 20.0, 20.0, 10.0],
	"twist_down_20": [-5.0, 0.0, -20.0, -20.0, 10.0],
	"aileron_20": [-5.0, 0.0, 20.0, -20.0, 10.0],
	"arm_raise_40": [40.0, 0.0, 0.0, 0.0, 0.0],
	"half_fold": [-20.0, 0.0, 0.0, 0.0, 105.0],
	"hands_together": [-30.0, 20.0, 0.0, 0.0, 165.0],
	"arms_down": [-85.0, 0.0, 0.0, 0.0, 0.0],
}
const STYLES := {
	"textbook": [-5.0, 0.0, 0.0, 0.0, 0.0],
	"arms_12_low": [-12.0, 0.0, 0.0, 0.0, 0.0],
	"arms_level": [0.0, 0.0, 0.0, 0.0, 0.0],
	"arms_5_high": [5.0, 0.0, 0.0, 0.0, 0.0],
	"arms_8_high": [8.0, 0.0, 0.0, 0.0, 0.0],
	"hands_forward_10": [-5.0, 10.0, 0.0, 0.0, 0.0],
	"soft_elbows_15": [-5.0, 0.0, 15.0, 0.0, 0.0],
	"looking_at_hand": [-5.0, 0.0, 0.0, 25.0, -15.0],
}

var _rng := RandomNumberGenerator.new()


func feed(cal: WingCalibrator, h: VRHumanPose, seconds: float, noise_mm: float = 0.5, dt: float = DT) -> void:
	for i in int(round(seconds / dt)):
		var hd := h.head_transform()
		var l := h.hand_transform(0)
		var r := h.hand_transform(1)
		if noise_mm > 0.0:
			var k := noise_mm * 0.001
			hd.origin += Vector3(_rng.randfn(0, k), _rng.randfn(0, k), _rng.randfn(0, k))
			l.origin += Vector3(_rng.randfn(0, k), _rng.randfn(0, k), _rng.randfn(0, k))
			r.origin += Vector3(_rng.randfn(0, k), _rng.randfn(0, k), _rng.randfn(0, k))
		cal.measure(hd, l, r, 7, dt)


func pose(h: VRHumanPose, g: Array) -> void:
	h.dihedral = [deg_to_rad(g[0]), deg_to_rad(g[0])]
	h.sweep = [deg_to_rad(g[1]), deg_to_rad(g[1])]
	h.twist = [deg_to_rad(g[2]), deg_to_rad(g[3])]
	h.elbow = [deg_to_rad(g[4]), deg_to_rad(g[4])]


func readings(cal: WingCalibrator, h: VRHumanPose) -> Dictionary:
	var out := {}
	for g in GESTURES:
		pose(h, GESTURES[g])
		feed(cal, h, 0.1, 0.0)
		out[g] = [cal.extension[0], cal.extension[1], rad_to_deg(cal.twist[0]), rad_to_deg(cal.twist[1]), cal.pitch_command(),
			minf(cal.twist_conf[0], cal.twist_conf[1])]
	return out


func perched() -> WingCalibrator:
	var cal := WingCalibrator.new()
	cal.auto_capture_allowed = true
	return cal


func reference() -> Dictionary:
	var h := VRHumanPose.for_span(1.6)
	h.spread_pose()
	var cal := perched()
	feed(cal, h, 2.0)
	return readings(cal, h)


func make_body(span: float, sr: float, ape: float, dr: float, er: float, floor_err: float, habit_l: float, habit_r: float) -> VRHumanPose:
	var h := VRHumanPose.new()
	var stature := span / ape + 0.16
	h.arm_span = span
	h.shoulder_width = sr * span
	h.shoulder_drop = dr * stature
	h.eye_height = er * stature
	h.room_offset = Vector3(0.0, floor_err, 0.0)
	h.twist_offset = [deg_to_rad(habit_l), deg_to_rad(habit_r)]
	return h


## Captures h in style st and compares its readings with ref. Returns
## {captured, ext, twist, pitch, pitch_folded, drop}.
func compare(h: VRHumanPose, st: Array, ref: Dictionary) -> Dictionary:
	h.set_arms(deg_to_rad(st[0]), deg_to_rad(st[1]), 0.0, deg_to_rad(st[2]))
	h.head_yaw = deg_to_rad(st[3])
	h.head_pitch = deg_to_rad(st[4])
	var cal := perched()
	feed(cal, h, 2.2)
	h.head_yaw = 0.0
	h.head_pitch = 0.0
	var res := {"captured": cal.calibrated, "ext": 0.0, "twist": 0.0, "pitch": 0.0, "pitch_folded": 0.0, "drop": 0.0}
	if not cal.calibrated:
		return res
	res["drop"] = absf(cal.shoulder_drop - h.shoulder_drop)
	var r := readings(cal, h)
	for g in GESTURES:
		var a: Array = r[g]
		var b: Array = ref[g]
		var comparable := float(a[5]) >= 0.5 and float(b[5]) >= 0.5
		res["ext"] = maxf(res["ext"], maxf(absf(a[0] - b[0]), absf(a[1] - b[1])))
		if comparable:
			var dt := maxf(absf(a[2] - b[2]), absf(a[3] - b[3]))
			var dp := absf(a[4] - b[4])
			if g in SPREAD_GESTURES:
				res["twist"] = maxf(res["twist"], dt)
				res["pitch"] = maxf(res["pitch"], dp)
			else:
				res["pitch_folded"] = maxf(res["pitch_folded"], dp)
	return res


func test_builders_bounds_hold_on_other_seeds() -> void:
	_rng.seed = 1234
	var ref := reference()
	var style_names := STYLES.keys()
	var per_seed := {}
	var worst := {"ext": 0.0, "twist": 0.0, "pitch": 0.0, "pitch_folded": 0.0, "drop": 0.0}
	var missed := 0
	for seed_value in [7, 99, 31337, 424242, 1]:
		var rng := RandomNumberGenerator.new()
		rng.seed = seed_value
		var ws := {"ext": 0.0, "twist": 0.0, "pitch": 0.0, "pitch_folded": 0.0, "drop": 0.0}
		for n in 120:
			var h := make_body(rng.randf_range(1.4, 2.0), rng.randf_range(0.20, 0.26), rng.randf_range(0.95, 1.05),
				rng.randf_range(0.14, 0.16), rng.randf_range(0.925, 0.945), rng.randf_range(-0.03, 0.03),
				rng.randf_range(-25.0, 25.0), rng.randf_range(-25.0, 25.0))
			var r := compare(h, STYLES[style_names[n % style_names.size()]], ref)
			if not r["captured"]:
				missed += 1
				continue
			for k in ws:
				ws[k] = maxf(ws[k], r[k])
		for k in ws:
			worst[k] = maxf(worst[k], ws[k])
			ws[k] = snappedf(ws[k], 0.001)
		per_seed[seed_value] = ws
		print("[vr-verify] seed %d worst %s" % [seed_value, str(ws)])
	metric("r2x_cal_worst_per_seed", per_seed)
	eq(missed, 0, "every natural capture is accepted on every seed")
	lt(worst["ext"], 0.13, "extension within the builder's 0.13 on 600 unseen players")
	lt(worst["twist"], 4.0, "spread-wing twist within the builder's 4° on 600 unseen players")
	lt(worst["pitch"], 0.08, "spread-wing pitch within the builder's 0.08 on 600 unseen players")
	lt(worst["pitch_folded"], 0.15, "folded pitch within the builder's 0.15 on 600 unseen players")
	lt(worst["drop"], 0.03, "shoulder height within the builder's 3 cm on 600 unseen players")


## Every factor at an extreme at once (2^6 bodies x 8 styles, wrist habits
## at ±25°): the adult box's corners, which random draws rarely reach.
func test_corners_of_the_body_box() -> void:
	_rng.seed = 1234
	var ref := reference()
	var worst := {"ext": 0.0, "twist": 0.0, "pitch": 0.0, "pitch_folded": 0.0, "drop": 0.0}
	var worst_tag := {}
	var missed: Array = []
	for span in [1.4, 2.0]:
		for sr in [0.20, 0.26]:
			for ape in [0.95, 1.05]:
				for dr in [0.14, 0.16]:
					for er in [0.925, 0.945]:
						for fl in [-0.03, 0.03]:
							for style in STYLES:
								var h := make_body(span, sr, ape, dr, er, fl, 25.0, -25.0)
								var r := compare(h, STYLES[style], ref)
								var tag := "span %.1f sh %.2f ape %.2f drop %.2f eye %.3f floor %+.2f %s" % [span, sr, ape, dr, er, fl, style]
								if not r["captured"]:
									missed.append(tag)
									continue
								for k in worst:
									if r[k] > worst[k]:
										worst[k] = r[k]
										worst_tag[k] = tag
	print("[vr-verify] corners worst ", worst, " ", worst_tag)
	metric("r2x_cal_corners_worst", worst)
	metric("r2x_cal_corners_worst_case", worst_tag)
	eq(missed.size(), 0, "every corner body is captured (missed: %s)" % str(missed.slice(0, 4)))
	lt(worst["ext"], 0.13, "corners: extension within 0.13")
	lt(worst["twist"], 4.0, "corners: spread-wing twist within 4°")
	lt(worst["pitch"], 0.08, "corners: spread-wing pitch within 0.08")
	lt(worst["drop"], 0.03, "corners: shoulder height within 3 cm")


## The brief's own grid (spans 1.4-2.0 m, wrist habits ±25°) with noisier
## tracking (1.5 mm, a worn controller in daylight) at 72 Hz: still the
## unit suite's 0.03 / 1° / 0.02?
func test_brief_grid_with_noisy_tracking_at_72hz() -> void:
	_rng.seed = 99
	var ref := reference()
	var worst := {"ext": 0.0, "twist": 0.0, "pitch": 0.0}
	var missed := 0
	for span in [1.4, 1.6, 1.8, 2.0]:
		for off in [[-25.0, -25.0], [0.0, 0.0], [25.0, 25.0], [25.0, -25.0]]:
			var h := VRHumanPose.for_span(span)
			h.twist_offset = [deg_to_rad(off[0]), deg_to_rad(off[1])]
			h.spread_pose()
			var cal := perched()
			feed(cal, h, 2.5, 1.5, 1.0 / 72.0)
			if not cal.calibrated:
				missed += 1
				print("[vr-verify] not captured with 1.5 mm noise: span %.1f off %s (blocker '%s')" % [span, str(off), cal.neutral_blocker()])
				continue
			var r := readings(cal, h)
			for g in GESTURES:
				var a: Array = r[g]
				var b: Array = ref[g]
				worst["ext"] = maxf(worst["ext"], maxf(absf(a[0] - b[0]), absf(a[1] - b[1])))
				if float(a[5]) >= 0.5 and float(b[5]) >= 0.5 and g != "hands_together":
					worst["twist"] = maxf(worst["twist"], maxf(absf(a[2] - b[2]), absf(a[3] - b[3])))
					worst["pitch"] = maxf(worst["pitch"], absf(a[4] - b[4]))
	print("[vr-verify] noisy 72 Hz grid worst ", worst)
	metric("r2x_cal_noisy_grid_worst", worst)
	eq(missed, 0, "the automatic capture still fires with 1.5 mm tracker noise at 72 Hz")
	lt(worst["ext"], 0.03, "noisy grid: extension within 0.03")
	lt(worst["twist"], 1.0, "noisy grid: twist within 1°")
	lt(worst["pitch"], 0.02, "noisy grid: pitch within 0.02")


## Which gestures carry the corner case's extension error, and what
## extension the reference reads for them (is it a flight-relevant pose?).
func test_zz_worst_corner_per_gesture() -> void:
	_rng.seed = 1234
	var ref := reference()
	var cases := {
		"short_broad_arms_low": [1.4, 0.26, 0.95, 0.16, 0.925, -0.03, "arms_12_low"],
		"short_broad_textbook": [1.4, 0.26, 0.95, 0.16, 0.925, -0.03, "textbook"],
		"tall_narrow_textbook": [2.0, 0.20, 1.05, 0.14, 0.945, 0.03, "textbook"],
		"tall_narrow_arms_high": [2.0, 0.20, 1.05, 0.14, 0.945, 0.03, "arms_8_high"],
	}
	var out := {}
	for name in cases:
		var c: Array = cases[name]
		var h := make_body(c[0], c[1], c[2], c[3], c[4], c[5], 0.0, 0.0)
		var st: Array = STYLES[c[6]]
		h.set_arms(deg_to_rad(st[0]), deg_to_rad(st[1]), 0.0, deg_to_rad(st[2]))
		var cal := perched()
		feed(cal, h, 2.2)
		check(cal.calibrated, "%s captured" % name)
		var r := readings(cal, h)
		var per := {}
		for g in GESTURES:
			per[g] = "ref %.2f got %.2f (d %+.3f)" % [ref[g][0], r[g][0], float(r[g][0]) - float(ref[g][0])]
		out[name] = per
		print("[vr-verify] ", name, " ", per)
	metric("r2x_cal_corner_per_gesture", out)
