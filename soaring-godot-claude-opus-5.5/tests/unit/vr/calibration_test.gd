extends TestCase
## V3: calibration. Synthetic players (VRHumanPose) with grip-to-grip arm
## spans 1.4-2.0 m and a habitual wrist roll of up to ±25° must read the same
## normalised wing extension and wrist pitch for the same gesture once
## calibrated; the capture only fires when asked, on a real "spread your
## wings" hold; results persist and reload; the calibration step works.
## (The step's own rules: calibration_flow_test.)

const MemoryStore := preload("res://tests/unit/vr/vr_memory_store.gd")
## A local WingCalibration look-alike (never flight's in-progress class).
const CalMock := preload("res://tests/unit/vr/vr_wing_calibration_mock.gd")
const StubPlayer := preload("res://scenes/dev/vr_stub_player.gd")
const DT := 1.0 / 90.0
const SPANS := [1.4, 1.6, 1.8, 2.0]
## Habitual wrist roll [left, right] in degrees (+ = leading edge up).
const OFFSETS := [[-25.0, -25.0], [0.0, 0.0], [25.0, 25.0], [25.0, -25.0]]

var _rng := RandomNumberGenerator.new()


func before_each() -> void:
	_rng.seed = 1234


## Feeds `seconds` of a held pose (with tracker noise, mm) into the calibrator.
func feed(cal: WingCalibrator, h: VRHumanPose, seconds: float, noise_mm: float = 0.5, mask: int = 7) -> void:
	for i in int(round(seconds / DT)):
		var hd := h.head_transform()
		var l := h.hand_transform(0)
		var r := h.hand_transform(1)
		if noise_mm > 0.0:
			var k := noise_mm * 0.001
			hd.origin += Vector3(_rng.randfn(0, k), _rng.randfn(0, k), _rng.randfn(0, k))
			l.origin += Vector3(_rng.randfn(0, k), _rng.randfn(0, k), _rng.randfn(0, k))
			r.origin += Vector3(_rng.randfn(0, k), _rng.randfn(0, k), _rng.randfn(0, k))
		cal.measure(hd, l, r, mask, DT)


func player(span: float, off: Array) -> VRHumanPose:
	var h := VRHumanPose.for_span(span)
	h.twist_offset = [deg_to_rad(off[0]), deg_to_rad(off[1])]
	return h


## A calibrator asked for its capture (the player was shown the card): the
## next still, plausible spread is captured, and (the game running) later
## spreads may refine the span.
func perched() -> WingCalibrator:
	var cal := WingCalibrator.new()
	cal.request_capture()
	cal.refine_allowed = true
	return cal


## `n` separate full spreads of the player's current arms (1 s each, arms
## down in between): refinement needs two (fix round 4).
func spreads(cal: WingCalibrator, h: VRHumanPose, n: int = 2, dihedral_deg: float = 0.0) -> void:
	for i in n:
		h.set_arms(deg_to_rad(dihedral_deg))
		feed(cal, h, 1.0)
		h.set_arms(deg_to_rad(-80.0))
		feed(cal, h, 0.3)


func calibrated_for(h: VRHumanPose) -> WingCalibrator:
	var cal := perched()
	h.spread_pose()
	feed(cal, h, 2.0)
	return cal


## Gestures: name -> [dihedral, sweep, twist L, twist R, elbow] (degrees).
## Gestures with the wing spread, where wrist pitch is the speed control.
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


func pose(h: VRHumanPose, g: Array) -> void:
	h.dihedral = [deg_to_rad(g[0]), deg_to_rad(g[0])]
	h.sweep = [deg_to_rad(g[1]), deg_to_rad(g[1])]
	h.twist = [deg_to_rad(g[2]), deg_to_rad(g[3])]
	h.elbow = [deg_to_rad(g[4]), deg_to_rad(g[4])]


## {gesture: [extL, extR, twistL°, twistR°, pitch_command, twist confidence]}
func readings(cal: WingCalibrator, h: VRHumanPose) -> Dictionary:
	var out := {}
	for g in GESTURES:
		pose(h, GESTURES[g])
		feed(cal, h, 0.1, 0.0)
		out[g] = [cal.extension[0], cal.extension[1], rad_to_deg(cal.twist[0]), rad_to_deg(cal.twist[1]), cal.pitch_command(),
			minf(cal.twist_conf[0], cal.twist_conf[1])]
	return out


## Swing-twist is only defined away from a half-turn swing: FLIGHT_SPEC §5.7
## holds the last twist below confidence 0.25, and near it (a forearm folded
## 165° across the chest) the angle is ill-conditioned. Twist and pitch are
## compared only where both readings are well-conditioned (>= 0.5, swing
## < 120°): every flight gesture; not "hands together", where the wing is
## tucked and pitch has no meaning.
func twist_comparable(a: Array, b: Array) -> bool:
	return float(a[5]) >= 0.5 and float(b[5]) >= 0.5


# -----------------------------------------------------------------------------

func test_synthetic_grip_matches_measured_convention() -> void:
	for side in 2:
		var b := VRHumanPose.airplane_basis(side)
		var s := -1.0 if side == 0 else 1.0
		vnear(b.transposed() * Vector3(s, 0, 0), WingCalibrator.DEFAULT_FOREARM, 1e-3, "forearm axis in the grip frame, side %d" % side)
		vnear(b.transposed() * Vector3(0, 0, -1), WingCalibrator.DEFAULT_CHORD, 1e-3, "chord axis in the grip frame, side %d" % side)
		vnear(b * Vector3(s, 0, 0), Vector3.UP, 1e-3, "wing up-normal is +X_grip right / -X_grip left, side %d" % side)


func test_capture_measures_body() -> void:
	var worst_span := 0.0
	var worst_drop := 0.0
	for span in SPANS:
		var h := player(span, [0.0, 0.0])
		var cal := calibrated_for(h)
		check(cal.calibrated, "span %.1f captured" % span)
		# The full spread (arms straight out, level): shoulders + 2 L, even
		# though the arms were held 5° low (grips 2 L (1 - cos 5°) closer).
		var want := h.shoulder_width + 2.0 * h.arm_length()
		worst_span = maxf(worst_span, absf(cal.arm_span - want) / want)
		worst_drop = maxf(worst_drop, absf(cal.shoulder_drop - h.shoulder_drop))
		near(cal.shoulder_width, 0.23 * cal.arm_span, 1e-4, "shoulder width 0.23 x span")
	lt(worst_span, 0.002, "arm span within 0.2% of the full spread for 1.4-2.0 m players")
	lt(worst_drop, 0.01, "shoulder drop within 1 cm")
	metric("worst_span_err", worst_span)
	metric("worst_drop_err_m", worst_drop)


func test_players_read_the_same_after_calibration() -> void:
	var ref := readings(calibrated_for(player(1.6, [0.0, 0.0])), player(1.6, [0.0, 0.0]))
	var worst_twist := 0.0
	var worst_ext := 0.0
	var worst_pitch := 0.0
	for span in SPANS:
		for off in OFFSETS:
			var h := player(span, off)
			var cal := calibrated_for(h)
			if not check(cal.calibrated, "span %.1f offset %s captured" % [span, str(off)]):
				continue
			var r := readings(cal, h)
			for g in GESTURES:
				var a: Array = r[g]
				var b: Array = ref[g]
				worst_ext = maxf(worst_ext, maxf(absf(a[0] - b[0]), absf(a[1] - b[1])))
				worst_twist = maxf(worst_twist, maxf(absf(a[2] - b[2]), absf(a[3] - b[3])))
				worst_pitch = maxf(worst_pitch, absf(a[4] - b[4]))
	lt(worst_ext, 0.03, "extension agrees across players within 0.03")
	lt(worst_twist, 1.0, "wrist twist agrees across players within 1 deg")
	lt(worst_pitch, 0.02, "pitch command agrees across players within 0.02")
	metric("worst_ext_diff", worst_ext)
	metric("worst_twist_diff_deg", worst_twist)
	metric("worst_pitch_diff", worst_pitch)
	# The reference itself reads what the gestures mean (FLIGHT_SPEC §5.9).
	near(ref["spread"][0], 1.0, 0.01, "spread = full extension")
	gt(ref["glide"][0], 0.95, "relaxed glide (-45°, soft elbows) still counts as spread (D10)")
	near(ref["twist_up_20"][2], 20.0, 1.0, "LE up 20° reads +20°")
	near(ref["twist_up_20"][4], 0.305, 0.02, "both wrists +20° -> pitch 0.31 (spec reference)")
	near(ref["twist_down_20"][4], -0.49, 0.02, "both wrists -20° -> pitch -0.49 (spec reference)")
	near(ref["aileron_20"][4], 0.0, 0.01, "opposite twists leak no pitch")
	near(ref["aileron_20"][2], 20.0, 1.0, "aileron left +20")
	near(ref["aileron_20"][3], -20.0, 1.0, "aileron right -20")
	near(ref["arm_raise_40"][2], 0.0, 1.0, "raising the arms 40° reads no twist")
	between(ref["half_fold"][0], 0.05, 0.95, "half fold is partial extension")
	lt(ref["hands_together"][0], 0.05, "hands together = tucked")
	lt(ref["arms_down"][0], 0.05, "arms hanging down = folded")


## Seated play (the brief's standing and seated modes) over the same grid:
## every seated player reads the gestures like the seated reference within
## the grid's tolerances, with the Settings seated preference on and by
## detection alone, whether they spread at once or after sitting for 6 s.
## (Fix round 3: a verifier's seated grid read 0.035 after 6 s because
## seated players with spans >= 1.8 m have their eyes at 1.32-1.41 m, above
## the absolute 1.30 m threshold, and were never detected; the threshold is
## now also 0.75 of the stature the span implies.)
func test_seated_grid_reads_the_same() -> void:
	var rows := {}
	for when in ["preference, spread at once", "preference, after 6 s seated", "detected, after 6 s seated"]:
		var pref: bool = when.begins_with("preference")
		var ref_h := VRHumanPose.for_span(1.6, true)
		var ref_cal := perched()
		ref_cal.seated_setting = pref
		if not when.ends_with("at once"):
			ref_h.set_arms(deg_to_rad(-40.0))
			feed(ref_cal, ref_h, 6.0)
		ref_h.spread_pose()
		feed(ref_cal, ref_h, 2.0)
		var ref := readings(ref_cal, ref_h)
		var w := {"ext": 0.0, "twist": 0.0, "pitch": 0.0, "missed": 0}
		for span in SPANS:
			for off in OFFSETS:
				var h := VRHumanPose.for_span(span, true)
				h.twist_offset = [deg_to_rad(off[0]), deg_to_rad(off[1])]
				var cal := perched()
				cal.seated_setting = pref
				if not when.ends_with("at once"):
					h.set_arms(deg_to_rad(-40.0))
					feed(cal, h, 6.0)
				h.spread_pose()
				feed(cal, h, 2.0)
				if not cal.calibrated:
					w["missed"] += 1
					continue
				if not pref:
					check(cal.is_seated(), "%s: span %.1f (eyes %.2f m) detected seated" % [when, span, h.eye_height])
				var r := readings(cal, h)
				for g in GESTURES:
					var a: Array = r[g]
					var b: Array = ref[g]
					w["ext"] = maxf(w["ext"], maxf(absf(a[0] - b[0]), absf(a[1] - b[1])))
					if twist_comparable(a, b):
						w["twist"] = maxf(w["twist"], maxf(absf(a[2] - b[2]), absf(a[3] - b[3])))
						w["pitch"] = maxf(w["pitch"], absf(a[4] - b[4]))
		rows[when] = w
		eq(w["missed"], 0, "seated (%s): every player captured" % when)
		lt(w["ext"], 0.03, "seated (%s): extension agrees within 0.03 (%.4f)" % [when, w["ext"]])
		lt(w["twist"], 1.0, "seated (%s): twist agrees within 1° (%.3f)" % [when, w["twist"]])
		lt(w["pitch"], 0.02, "seated (%s): pitch agrees within 0.02 (%.4f)" % [when, w["pitch"]])
	metric("seated_grid", rows)


func test_uncalibrated_players_disagree() -> void:
	# Without calibration a habitual 25° wrist roll reads as a 25° command:
	# this is what calibration removes.
	var h := player(1.6, [25.0, 25.0])
	var cal := WingCalibrator.new()
	pose(h, GESTURES["spread"])
	feed(cal, h, 0.2, 0.0)
	gt(absf(rad_to_deg(cal.twist[0])), 20.0, "uncalibrated: flat wrists of a 25° player read > 20°")
	gt(absf(cal.pitch_command()), 0.3, "uncalibrated: a big false pitch command")
	var cal2 := calibrated_for(h)
	pose(h, GESTURES["spread"])
	feed(cal2, h, 0.2, 0.0)
	lt(absf(rad_to_deg(cal2.twist[0])), 1.0, "calibrated: flat reads flat")


## The service reads the head and the grips relative to the XROrigin3D
## (tracking space, / world_scale) wherever they hang under it: directly
## (the usual rig; fix round 5 reads their own transform then, no global
## compositions) or nested under an offset node. Mutant F06 (every node
## read as a direct child) passed every test without the nested case.
func test_poses_are_read_relative_to_the_origin_even_nested() -> void:
	var h := player(1.6, [0.0, 0.0])
	h.spread_pose()
	for nested in [false, true]:
		var origin := XROrigin3D.new()
		origin.position = Vector3(3.0, 1.0, -2.0)
		origin.rotation.y = 0.4
		origin.world_scale = 0.5
		add_child(origin)
		var holder: Node3D = origin
		if nested:
			holder = Node3D.new()
			holder.position = Vector3(0.2, -0.1, 0.3)
			holder.rotation.y = -0.7
			origin.add_child(holder)
		var cam := XRCamera3D.new()
		var l := XRController3D.new()
		var r := XRController3D.new()
		for n in [cam, l, r]:
			holder.add_child(n)
		var node := make_node({"origin": origin, "camera": cam, "hands": [l, r]}, MemoryStore.new())
		# Place the nodes so their origin-local poses are the player's
		# tracking-space poses x world_scale.
		var inv := holder.transform.affine_inverse() if nested else Transform3D.IDENTITY
		var want: Array[Transform3D] = [h.head_transform(), h.hand_transform(0), h.hand_transform(1)]
		var nodes: Array[Node3D] = [cam, l, r]
		for i in 3:
			nodes[i].transform = inv * Transform3D(want[i].basis, want[i].origin * 0.5)
		node.tick(DT)
		var cal := node.calibrator
		var got: Array[Transform3D] = [cal.head, cal.hands[0], cal.hands[1]]
		for i in 3:
			vnear(got[i].origin, want[i].origin, 1e-4, "%s: node %d read at its tracking-space position" % ["nested" if nested else "direct", i])
			lt(rad_to_deg(VRMath.basis_angle(got[i].basis, want[i].basis)), 0.01, "%s: node %d read with its tracking-space rotation" % ["nested" if nested else "direct", i])
		node.queue_free()
		origin.queue_free()


## Hands swept back behind the shoulders fold the wing (FLIGHT_SPEC §5.5:
## extension = e_reach x e_low x e_back, e_back = 1 - smoothstep(-35°,
## -70°, sweep); fix round 5, the engineering verifier's surviving mutant
## E28 dropped e_back and no gesture noticed). Straight arms at shoulder
## height, for every player of the brief's grid (spans 1.4-2.0 m, wrist
## habits ±25°): swept 20° back they stay spread; swept 60° back they read
## e_back(-60°) = 0.20 of the same arms swept 60° FORWARD (the same reach,
## so e_reach cancels), the same for every player within 0.03; 80° back
## folds completely.
func test_hands_behind_the_back_fold_the_wing() -> void:
	var rows := {}
	var e_back_60 := 1.0 - VRMath.sstep(deg_to_rad(-35.0), deg_to_rad(-70.0), deg_to_rad(-60.0))
	var lo := INF
	var hi := -INF
	for span in SPANS:
		for off in OFFSETS:
			var h := player(span, off)
			var cal := calibrated_for(h)
			if not check(cal.calibrated, "span %.1f offset %s captured" % [span, str(off)]):
				continue
			var row := {}
			for sw in [-20.0, 60.0, -60.0, -80.0]:
				h.set_arms(deg_to_rad(-5.0), deg_to_rad(sw))
				feed(cal, h, 0.1, 0.0)
				row["%d" % int(sw)] = 0.5 * (cal.extension[0] + cal.extension[1])
			var ratio := float(row["-60"]) / maxf(float(row["60"]), 1e-6)
			row["ratio_back_forward_60"] = ratio
			rows["%.1f %s" % [span, str(off)]] = row
			gt(float(row["-20"]), 0.95, "span %.1f %s: arms 20° back stay spread (%.3f)" % [span, str(off), row["-20"]])
			gt(float(row["60"]), 0.4, "span %.1f %s: (reference) arms 60° forward, straight, still read open (%.3f)" % [span, str(off), row["60"]])
			near(ratio, e_back_60, 0.03, "span %.1f %s: 60° back reads e_back = %.2f of 60° forward (%.3f)" % [span, str(off), e_back_60, ratio])
			lt(float(row["-80"]), 0.02, "span %.1f %s: 80° back folds completely (%.3f)" % [span, str(off), row["-80"]])
			lo = minf(lo, float(row["-60"]))
			hi = maxf(hi, float(row["-60"]))
	lt(hi - lo, 0.03, "60° back reads the same for every player (%.3f .. %.3f)" % [lo, hi])
	metric("hands_behind", rows)


func test_capture_needs_a_still_level_spread() -> void:
	var h := player(1.6, [0.0, 0.0])
	# Moving (flapping): never captures.
	var cal := perched()
	for i in 360:
		h.set_arms(deg_to_rad(-5.0 + 30.0 * sin(i * DT * TAU)))
		cal.measure(h.head_transform(), h.hand_transform(0), h.hand_transform(1), 7, DT)
	check(not cal.calibrated, "no capture while flapping")
	# Arms low (-40°).
	cal = perched()
	h.set_arms(deg_to_rad(-40.0))
	feed(cal, h, 3.0)
	check(not cal.calibrated, "no capture with arms 40° low")
	# One hand 20 cm higher.
	cal = perched()
	h.set_arms(deg_to_rad(-5.0))
	h.dihedral = [deg_to_rad(-15.0), deg_to_rad(5.0)]
	feed(cal, h, 3.0)
	check(not cal.calibrated, "no capture with hands at different heights")
	# Tucked (hands close).
	cal = perched()
	pose(h, GESTURES["hands_together"])
	feed(cal, h, 3.0)
	check(not cal.calibrated, "no capture when tucked")
	# Hand lost.
	cal = perched()
	h.spread_pose()
	feed(cal, h, 3.0, 0.5, 1 | 2)
	check(not cal.calibrated, "no capture without both hands tracked")
	# A still spread captures after the 1 s hold, not before.
	cal = perched()
	h.spread_pose()
	var t := 0.0
	while not cal.calibrated and t < 5.0:
		feed(cal, h, DT, 0.5)
		t += DT
	check(cal.calibrated, "a held spread captures")
	between(t, WingCalibrator.NEUTRAL_HOLD, WingCalibrator.NEUTRAL_HOLD + 0.35, "capture after the 1 s hold (velocity filter settles first)")
	metric("capture_time_s", t)


## Swapped controllers (the left one in the right hand and vice versa: each
## on the other side, turned 180° about its handle) are never captured,
## and the card's hint says why; once the player swaps them back the same
## request completes. A controller held in a way no real grip gives (its
## forearm axis far from the grip convention: held upright like a torch)
## is never captured either: the hint asks for the usual grip, and the
## request completes once the grip is normal. The capture's own refusal
## (from the fitted shoulders) stays as a safety net: a torch grip's
## geometry is refused.
func test_swapped_controllers_and_odd_grips_are_never_captured() -> void:
	var h := player(1.6, [0.0, 0.0])
	h.spread_pose()
	var cal := perched()
	var reasons: Array[String] = []
	cal.rejected.connect(func(_k: StringName, why: String) -> void: reasons.append(why))
	var flip := Basis(Vector3.BACK, PI)
	for i in 270:
		var l := h.hand_transform(1)
		var r := h.hand_transform(0)
		cal.measure(h.head_transform(), Transform3D(l.basis * flip, l.origin), Transform3D(r.basis * flip, r.origin), 7, DT)
	check(not cal.calibrated, "swapped controllers never calibrate")
	eq(cal.neutral_blocker(), "controllers in the wrong hands?", "and the hint says why")
	check(cal.capturing, "the request keeps waiting")
	feed(cal, h, 2.0)
	check(cal.calibrated, "swapped back: the same request completes")
	# Held upright like a torch (90° about the controller's own x axis).
	var torch := Basis(Vector3.RIGHT, PI * 0.5)
	var c2 := perched()
	c2.rejected.connect(func(_k: StringName, why: String) -> void: reasons.append(why))
	var d0 := c2.to_dict()
	for i in 270:
		var l := h.hand_transform(0)
		var r := h.hand_transform(1)
		c2.measure(h.head_transform(), Transform3D(l.basis * torch, l.origin), Transform3D(r.basis * torch, r.origin), 7, DT)
	check(not c2.calibrated, "an odd grip is never taken")
	eq(c2.neutral_blocker(), "hold the controllers as usual", "the hint asks for the usual grip")
	gt(rad_to_deg(c2.grip_axis_error(0)), rad_to_deg(WingCalibrator.AXIS_LIVE), "(its forearm axis is %.0f° off)" % rad_to_deg(c2.grip_axis_error(0)))
	eq(reasons.size(), 0, "nothing refused: the step just waits")
	check(c2.to_dict() == d0, "nothing changed")
	var hd := h.head_transform()
	var pl := h.hand_transform(0).origin
	var pr := h.hand_transform(1).origin
	var fit := WingCalibrator.fit_body(pl, pr, hd.origin + hd.basis * WingCalibrator.NECK_OFFSET, Basis.IDENTITY, false)
	check(c2._capture_geometry(fit, pl, pr, h.hand_transform(0).basis * torch, h.hand_transform(1).basis * torch, Basis.IDENTITY).is_empty(),
		"the capture's own safety net refuses a torch grip's geometry")
	check(not c2._capture_geometry(fit, pl, pr, h.hand_transform(0).basis, h.hand_transform(1).basis, Basis.IDENTITY).is_empty(),
		"(and accepts the normal grip)")
	feed(c2, h, 2.0)
	check(c2.calibrated, "the usual grip: the same request completes")
	lt(rad_to_deg(c2.grip_axis_error(0)), 5.0, "(the normal grip reads within 5° of the convention after the capture: %.1f°)" % rad_to_deg(c2.grip_axis_error(0)))


func test_seated_player_is_detected() -> void:
	var h := VRHumanPose.for_span(1.6, true)
	lt(h.eye_height, WingCalibrator.SEATED_HEAD_Y, "seated eye height below 1.30 m")
	h.set_arms(deg_to_rad(-40.0))
	var cal := perched()
	feed(cal, h, 5.5)
	h.spread_pose()
	feed(cal, h, 2.0)
	check(cal.calibrated, "seated player calibrates")
	check(cal.is_seated(), "head below 1.30 m for 5 s -> seated")
	lt(cal.full_reach(), 0.585, "seated reach threshold (R_HI 0.58)")
	var standing := calibrated_for(player(1.6, [0.0, 0.0]))
	check(not standing.is_seated(), "standing player is not seated")
	standing.seated_setting = true
	check(standing.is_seated(), "Settings.seated forces seated mode")


func test_span_grows_never_shrinks() -> void:
	var h := player(1.7, [0.0, 0.0])
	# Calibrated with soft elbows: span underestimated.
	h.set_arms(deg_to_rad(-5.0), 0.0, 0.0, deg_to_rad(35.0))
	var cal := perched()
	feed(cal, h, 2.0)
	check(cal.calibrated, "cramped capture still calibrates")
	var cramped := cal.arm_span
	spreads(cal, h, 1)
	near(cal.arm_span, cramped, 1e-6, "one spread is not enough (fix round 4)")
	spreads(cal, h, 1)
	gt(cal.arm_span, cramped + 0.05, "a second, separate spread: the span grew to the real spread")
	near(cal.arm_span, h.shoulder_width + 2.0 * h.arm_length(), 0.01, "grew to the true grip span")
	var grown := cal.arm_span
	pose(h, GESTURES["hands_together"])
	feed(cal, h, 1.0)
	eq(cal.arm_span, grown, "span never shrinks")


func test_persist_reload_and_apply_to_wing_calibration() -> void:
	var h := player(1.9, [25.0, -25.0])
	var cal := calibrated_for(h)
	var store := MemoryStore.new()
	store.set_value("wing_calibration", cal.to_dict())
	var path := "user://vr_test_%d/calibration.cfg" % OS.get_process_id()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	eq(store.save_to(path), OK, "saved to a ConfigFile")
	var reloaded := MemoryStore.new()
	eq(reloaded.load_from(path), OK, "reloaded from disk")
	var cal2 := WingCalibrator.new()
	check(cal2.from_dict(reloaded.get_value("wing_calibration", {})), "calibration dict restored")
	near(cal2.arm_span, cal.arm_span, 1e-5, "arm span survives")
	near(cal2.shoulder_drop, cal.shoulder_drop, 1e-5, "shoulder drop survives")
	check(cal2.calibrated and not cal2.capturing, "restored calibration is final (nothing capturing)")
	for i in 2:
		lt(VRMath.basis_angle(cal2.neutral[i], cal.neutral[i]), 1e-4, "neutral basis %d survives" % i)
		vnear(cal2.forearm_axis[i], cal.forearm_axis[i], 1e-5, "forearm axis %d survives" % i)
	# The reloaded calibration reads the player's flat wrists as flat.
	pose(h, GESTURES["spread"])
	feed(cal2, h, 0.1, 0.0)
	lt(absf(rad_to_deg(cal2.twist[0])) + absf(rad_to_deg(cal2.twist[1])), 1.0, "reloaded: flat reads flat")
	# The JSON-safe form (flat arrays) reads back the same.
	var flat := cal.to_dict()
	var nb: Basis = cal.neutral[0]
	var fa: Vector3 = cal.forearm_axis[1]
	flat["neutral_left"] = [nb.x.x, nb.x.y, nb.x.z, nb.y.x, nb.y.y, nb.y.z, nb.z.x, nb.z.y, nb.z.z]
	flat["forearm_axis_right"] = [fa.x, fa.y, fa.z]
	var cal4 := WingCalibrator.new()
	check(cal4.from_dict(flat), "flat-array form accepted")
	lt(VRMath.basis_angle(cal4.neutral[0], cal.neutral[0]), 1e-4, "neutral from a flat array")
	vnear(cal4.forearm_axis[1], cal.forearm_axis[1], 1e-5, "axis from a flat array")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	# Written into the flight area's resource (whichever fields it has).
	var res := CalMock.new()
	cal.apply_to(res)
	near(float(res.get("arm_span")), cal.arm_span, 1e-5, "WingCalibration.arm_span written")
	near(float(res.get("shoulder_drop")), cal.shoulder_drop, 1e-5, "WingCalibration.shoulder_drop written")
	check(bool(res.get("calibrated")), "WingCalibration.calibrated written")
	for i in 2:
		lt(VRMath.basis_angle(res.get(["neutral_left", "neutral_right"][i]), cal.neutral[i]), 1e-4, "FLIGHT_SPEC §5.11 neutral %d written" % i)
		vnear(res.get(["forearm_axis_left", "forearm_axis_right"][i]), cal.forearm_axis[i], 1e-6, "forearm axis %d written" % i)
		vnear(res.get(["chord_axis_left", "chord_axis_right"][i]), cal.chord_axis[i], 1e-6, "chord axis %d written" % i)
	# And read back from it.
	var cal3 := WingCalibrator.new()
	cal3.read_from(res)
	near(cal3.arm_span, cal.arm_span, 1e-5, "read back from WingCalibration")


## A rig of plain nodes driven by a synthetic player (like flight's
## synthetic pose sources: they write the XR nodes).
func make_rig() -> Dictionary:
	var origin := XROrigin3D.new()
	var cam := XRCamera3D.new()
	var l := XRController3D.new()
	var r := XRController3D.new()
	origin.add_child(cam)
	origin.add_child(l)
	origin.add_child(r)
	add_child(origin)
	return {"origin": origin, "camera": cam, "hands": [l, r]}


func drive(rig: Dictionary, h: VRHumanPose) -> void:
	var ws := (rig["origin"] as XROrigin3D).world_scale
	var hd := h.head_transform()
	(rig["camera"] as Node3D).transform = Transform3D(hd.basis, hd.origin * ws)
	for i in 2:
		var x := h.hand_transform(i)
		(rig["hands"][i] as Node3D).transform = Transform3D(x.basis, x.origin * ws)


func run(node: VRCalibration, rig: Dictionary, h: VRHumanPose, seconds: float) -> void:
	for i in int(round(seconds / DT)):
		drive(rig, h)
		node.tick(DT)


## `n` separate full spreads through the service (1 s each, arms down in
## between).
func run_spreads(node: VRCalibration, rig: Dictionary, h: VRHumanPose, n: int) -> void:
	for i in n:
		h.set_arms(0.0)
		run(node, rig, h, 1.0)
		h.set_arms(deg_to_rad(-80.0))
		run(node, rig, h, 0.3)


func test_manual_recalibrate_flow() -> void:
	var rig := make_rig()
	var store := MemoryStore.new()
	var node := VRCalibration.new()
	node.store = store
	node.auto_tick = false
	node.show_prompt = false
	node.force_valid = true
	add_child(node)
	node.origin = rig["origin"]
	node.camera = rig["camera"]
	node.hands = [rig["hands"][0], rig["hands"][1]]
	# Player A calibrates (the step, from the menu).
	var a := player(1.5, [0.0, 0.0])
	a.spread_pose()
	run(node, rig, a, 2.0)
	check(not node.calibrator.calibrated, "nothing is captured without the step (desktop, no first launch)")
	node.start_manual()
	run(node, rig, a, 2.0)
	check(node.calibrator.calibrated, "player A calibrated by the step")
	near(float(store.get_value("wing_calibration", {}).get("arm_span", 0.0)), node.calibrator.arm_span, 1e-6, "persisted through the store")
	near(float(store.get_value("arm_span", 0.0)), node.calibrator.arm_span, 1e-6, "deprecated arm_span mirror kept in sync")
	# Player B takes the headset and recalibrates (Y-hold path).
	var results: Array = []
	node.flow_finished.connect(func(ok: bool, why: String) -> void: results.append([ok, why]))
	VR.recalibrate_requested.emit()
	eq(node.flow, VRCalibration.Flow.CAPTURE, "Y-hold / menu shows the card")
	var b := player(1.9, [20.0, 20.0])
	b.set_arms(deg_to_rad(-60.0))
	run(node, rig, b, 1.0)
	eq(node.flow, VRCalibration.Flow.CAPTURE, "waits for the spread")
	b.spread_pose()
	run(node, rig, b, 2.0)
	eq(node.flow, VRCalibration.Flow.DONE, "captured -> the confirmation (one step, no glide step)")
	eq(results.size(), 1, "one flow result")
	check(not results.is_empty() and results[0][0], "flow reported success")
	var want := b.shoulder_width + 2.0 * b.arm_length()
	near(node.calibrator.arm_span, want, 0.005, "calibration now fits player B")
	near(float(store.get_value("wing_calibration", {}).get("arm_span", 0.0)), node.calibrator.arm_span, 1e-6, "player B persisted")
	pose(b, GESTURES["spread"])
	run(node, rig, b, 0.1)
	lt(absf(rad_to_deg(node.calibrator.twist[0])), 1.0, "player B's 20° wrist habit reads flat")
	run(node, rig, b, VRCalibration.RESULT_SHOW)
	eq(node.flow, VRCalibration.Flow.IDLE, "the confirmation goes away")
	# A step that never sees the pose times out and keeps the calibration.
	var span_before := node.calibrator.arm_span
	node.start_manual()
	b.set_arms(deg_to_rad(-70.0))
	run(node, rig, b, VRCalibration.STEP_TIMEOUT + 0.5)
	eq(node.flow, VRCalibration.Flow.FAILED, "no spread within the timeout -> not changed")
	eq(results.size(), 2, "failure reported")
	check(results.size() == 2 and not results[1][0], "reported as a failure")
	near(node.calibrator.arm_span, span_before, 1e-9, "calibration unchanged on failure")
	node.queue_free()
	(rig["origin"] as Node).queue_free()


func test_calibration_survives_world_scale() -> void:
	# Node poses scale with world_scale; the calibration must not.
	var rig := make_rig()
	var node := VRCalibration.new()
	node.store = MemoryStore.new()
	node.auto_tick = false
	node.show_prompt = false
	node.force_valid = true
	add_child(node)
	node.origin = rig["origin"]
	node.camera = rig["camera"]
	node.hands = [rig["hands"][0], rig["hands"][1]]
	(rig["origin"] as XROrigin3D).world_scale = 0.15
	var h := player(1.6, [0.0, 0.0])
	h.spread_pose()
	node.start_manual()
	run(node, rig, h, 2.0)
	var want := h.shoulder_width + 2.0 * h.arm_length()
	near(node.calibrator.arm_span, want, 0.005, "span in real metres at world_scale 0.15")
	(rig["origin"] as XROrigin3D).world_scale = 1.3
	pose(h, GESTURES["half_fold"])
	run(node, rig, h, 0.1)
	var e13 := node.calibrator.extension[0]
	(rig["origin"] as XROrigin3D).world_scale = 0.15
	run(node, rig, h, 0.1)
	near(node.calibrator.extension[0], e13, 1e-4, "extension identical at world_scale 0.15 and 1.3")
	(rig["origin"] as XROrigin3D).world_scale = 1.0
	node.queue_free()
	(rig["origin"] as Node).queue_free()


func test_ui_recalibrate_button_even_if_ui_comes_later() -> void:
	var node := VRCalibration.new()
	node.store = MemoryStore.new()
	node.auto_tick = false
	node.show_prompt = false
	add_child(node)
	await wait_frames(2)
	# The UI root appears after the rig (a UIRoot look-alike: group + signal).
	var ui := Node.new()
	ui.add_user_signal("recalibrate_requested")
	add_child(ui)
	ui.add_to_group(&"ui_root")
	await wait_seconds(1.3)
	ui.emit_signal("recalibrate_requested")
	eq(node.flow, VRCalibration.Flow.CAPTURE, "Settings > Recalibrate shows the card")
	node.cancel()
	eq(node.flow, VRCalibration.Flow.FAILED, "cancel: the short 'unchanged' card")
	check(not node.calibrator.capturing, "and nothing is capturing")
	ui.queue_free()
	node.queue_free()


func make_node(rig: Dictionary, store: Object) -> VRCalibration:
	var node := VRCalibration.new()
	node.store = store
	node.auto_tick = false
	node.show_prompt = false
	node.force_valid = true
	add_child(node)
	node.origin = rig["origin"]
	node.camera = rig["camera"]
	node.hands = [rig["hands"][0], rig["hands"][1]]
	return node


## A stand-in PlayerBird (registers as Birds.player()) carrying a
## WingCalibration look-alike, in the given flight mode.
func make_player(mode: String) -> Bird:
	var p := StubPlayer.new()
	p.mode_label = mode
	p.calibration = CalMock.new()
	add_child(p)
	return p


func drop_player(p: Bird) -> void:
	remove_child(p)
	p.free()


## The calibrator never captures unless asked (redesign: the explicit step
## is the only capture). A still spread glide with both wrists 20°
## leading-edge-down, held on and on: never the neutral; flat wrists read
## flat. What asking changes: the same glide captured after
## request_capture() (the player was told "hands flat" and chose this)
## would make that tilt "flat" (the contrast).
func test_the_calibrator_captures_only_when_asked() -> void:
	var h := player(1.7, [0.0, 0.0])
	var glide := func() -> void: h.set_arms(deg_to_rad(-8.0), 0.0, deg_to_rad(-20.0), 0.0)
	var cal := WingCalibrator.new()
	cal.refine_allowed = true
	check(not cal.capturing, "a new calibrator is not capturing")
	glide.call()
	feed(cal, h, 3.0)
	h.spread_pose()
	feed(cal, h, 3.0)
	check(not cal.calibrated, "still spreads, pitched or flat, are never taken unasked")
	h.set_arms(deg_to_rad(-8.0))
	feed(cal, h, 0.2, 0.0)
	lt(absf(cal.pitch_command()), 0.02, "flat wrists read flat (pitch %+.3f)" % cal.pitch_command())
	var asked := perched()
	glide.call()
	feed(asked, h, 1.6)
	check(asked.calibrated, "(contrast) asked, the glide held is captured")
	h.set_arms(deg_to_rad(-8.0))
	feed(asked, h, 0.2, 0.0)
	gt(asked.pitch_command(), 0.25, "(contrast) and flat wrists would then read a +0.3 pitch command")
	check(not asked.capturing, "one request, one capture")


## The service never captures without its step, whatever the bird does
## (flying, perched, spawning, grounded, stunned, caught), paused or not;
## the step captures (here in the menu state: the game is not in play).
func test_the_service_captures_only_in_its_step() -> void:
	var rig := make_rig()
	var store := MemoryStore.new()
	var node := make_node(rig, store)
	var p := make_player("flying")
	check(Birds.player() == p, "the stand-in is the player")
	var h := player(1.7, [0.0, 0.0])
	for m in ["flying", "perched", "spawning", "grounded", "stunned", "caught"]:
		p.mode_label = m
		for paused in [false, true]:
			get_tree().paused = paused
			h.set_arms(deg_to_rad(-8.0), 0.0, deg_to_rad(-20.0), 0.0)
			run(node, rig, h, 2.0)
			h.spread_pose()
			run(node, rig, h, 2.0)
			get_tree().paused = false
			check(not node.calibrator.calibrated, "%s%s: no capture" % [m, ", paused" if paused else ""])
	check((store.get_value("wing_calibration", {}) as Dictionary).is_empty(), "nothing persisted")
	check(not bool(p.calibration.get("calibrated")), "flight's calibration untouched (its defaults apply)")
	eq(node.flow, VRCalibration.Flow.IDLE, "no card ever came up by itself (desktop: no first launch)")
	p.mode_label = "perched"
	node.start_manual()
	h.spread_pose()
	run(node, rig, h, 2.0)
	check(node.calibrator.calibrated, "the step captures the spread")
	near(float(p.calibration.get("arm_span")), node.calibrator.arm_span, 1e-6, "written into the player's WingCalibration")
	check(bool(p.calibration.get("calibrated")), "flight's calibration marked calibrated")
	near(float((store.get_value("wing_calibration", {}) as Dictionary).get("arm_span", 0.0)), node.calibrator.arm_span, 1e-6, "persisted")
	drop_player(p)
	node.queue_free()
	(rig["origin"] as Node).queue_free()


## WingInput look-alikes for the trim hook: one with flight's current
## private trim only, one with the requested calibration_replaced().
class _WingInputTrim:
	extends RefCounted
	var calibration: Resource
	var _trim: Array[float] = [0.1, -0.1]


class _WingInputHook:
	extends RefCounted
	var calibration: Resource
	var replaced := 0

	func calibration_replaced() -> void:
		replaced += 1


## Flight captures again after VR has calibrated (its begin_calibration),
## here with the arms held 8° high: VR adopts it, refined to its own maths,
## writes the refinement back and persists it, so flight and VR agree and
## the drop is the body's (fix round 3: it was only adopted while VR had no
## calibration; a verifier's probe found flight flying drop 0.150 for a
## true 0.286 while VR kept its own). A resource that already holds VR's
## calibration (reloaded from Settings) is not "another capture".
func test_flight_recapture_after_vr_is_adopted() -> void:
	var rig := make_rig()
	var store := MemoryStore.new()
	var p := make_player("perched")
	var node := make_node(rig, store)
	var h := player(1.75, [10.0, -5.0])
	h.spread_pose()
	node.start_manual()
	run(node, rig, h, 2.5)
	check(node.calibrator.calibrated, "(setup) VR calibrated")
	var res: Resource = p.calibration
	check(not node.foreign_capture(res), "flight holds VR's calibration: not foreign")
	var reloaded := CalMock.new()
	var wc := WingCalibrator.new()
	wc.from_dict(store.get_value("wing_calibration", {}))
	wc.apply_to(reloaded)
	check(not node.foreign_capture(reloaded), "a resource reloaded from the saved dict is VR's own")
	# Flight's own capture, arms 8° high.
	h.set_arms(deg_to_rad(8.0))
	drive(rig, h)
	flight_like_capture(h, res)
	var raw_drop := float(res.get("shoulder_drop"))
	check(node.foreign_capture(res), "flight's recapture is recognised")
	gt(absf(raw_drop - h.shoulder_drop), 0.05, "(contrast) flight's §5.10 drop for arms 8° high is off (%.3f vs %.3f)" % [raw_drop, h.shoulder_drop])
	run(node, rig, h, 0.1)
	var drop := float(res.get("shoulder_drop"))
	lt(absf(drop - h.shoulder_drop), 0.015, "adopted and refined: flight now flies the body's drop (%.3f vs %.3f)" % [drop, h.shoulder_drop])
	near(drop, node.calibrator.shoulder_drop, 1e-6, "flight and VR agree")
	near(float((store.get_value("wing_calibration", {}) as Dictionary).get("shoulder_drop", -1.0)), drop, 1e-6, "and it is persisted")
	check(not node.foreign_capture(res), "after the write-back nothing is foreign")
	# One wing's neutral changed alone is foreign too (each is checked).
	var right: Basis = res.get("neutral_right")
	res.set("neutral_right", Basis(Vector3.UP, 0.05) * right)
	check(node.foreign_capture(res), "a changed right-wing neutral alone is recognised")
	res.set("neutral_right", right)
	drop_player(p)
	node.queue_free()
	(rig["origin"] as Node).queue_free()


## Refinements reach flight the moment they happen, and are persisted (fix
## round 3: seating detected after the capture reached flight only at the
## next respawn, so a player who sat down kept standing limits; mutant E01,
## refinements never persisted, survived). Sitting down: the seated flag;
## spreading wider than the capture: the span.
func test_refinements_reach_flight_and_persist() -> void:
	var rig := make_rig()
	var store := MemoryStore.new()
	var p := make_player("perched")
	var node := make_node(rig, store)
	var h := player(1.7, [0.0, 0.0])
	h.spread_pose()
	node.start_manual()
	run(node, rig, h, 2.5)
	check(node.calibrator.calibrated and not node.calibrator.is_seated(), "(setup) captured standing")
	var saved := func() -> Dictionary: return store.get_value("wing_calibration", {})
	# The player sits down (eyes at 1.15 m) and flies seated.
	h.eye_height = 1.15
	h.set_arms(deg_to_rad(-20.0))
	run(node, rig, h, 5.5)
	check(node.calibrator.is_seated(), "seated detected after 5 s")
	check(bool(p.calibration.get("seated")), "flight's resource says seated at once (no respawn needed)")
	check(bool((saved.call() as Dictionary).get("seated", false)), "persisted as seated")
	# Standing again.
	h.eye_height = 1.59
	run(node, rig, h, 5.5)
	check(not bool(p.calibration.get("seated")), "standing again reaches flight too")
	# Spreading 8 cm wider than the capture saw, twice.
	var span0 := node.calibrator.arm_span
	h.arm_span += 0.08
	run_spreads(node, rig, h, 2)
	gt(node.calibrator.arm_span, span0 + 0.05, "(setup) the span grew")
	near(float(p.calibration.get("arm_span")), node.calibrator.arm_span, 1e-6, "flight flies the grown span at once")
	near(float((saved.call() as Dictionary).get("arm_span", 0.0)), node.calibrator.arm_span, 1e-6, "the grown span is persisted")
	drop_player(p)
	node.queue_free()
	(rig["origin"] as Node).queue_free()


## After VR's own neutral capture, flight's trim learnt against the old
## neutral is void: flight's calibration_replaced() is called (a verifier
## measured 5.6° of twist on flat wrists right after a recalibration), for
## the automatic capture and a manual one. A refinement (no new neutral)
## does not call it. Fix round 4: nothing private of flight's is touched
## any more (round 3 zeroed WingInput._trim itself when the hook was
## missing, for flight code that no longer exists).
func test_new_neutral_clears_flights_trim() -> void:
	for kind in ["no hook", "hook"]:
		var rig := make_rig()
		var p := make_player("perched")
		var wi: RefCounted = _WingInputTrim.new() if kind == "no hook" else _WingInputHook.new()
		wi.set("calibration", CalMock.new())
		p.set("wing_input", wi)
		var node := make_node(rig, MemoryStore.new())
		var h := player(1.7, [0.0, 0.0])
		h.spread_pose()
		node.start_manual()
		run(node, rig, h, 2.5)
		check(node.calibrator.calibrated, "%s: (setup) captured" % kind)
		check(bool((wi.get("calibration") as Resource).get("calibrated")), "%s: written into wing_input.calibration" % kind)
		if kind == "no hook":
			var t: Array = wi.get("_trim")
			eq(t, [0.1, -0.1], "a WingInput without the hook: its private state is left alone")
		else:
			eq(int(wi.get("replaced")), 1, "flight's calibration_replaced() called once for the capture")
			var span0 := node.calibrator.arm_span
			h.arm_span += 0.08
			run_spreads(node, rig, h, 2)
			gt(node.calibrator.arm_span, span0 + 0.05, "(setup) the span grew")
			eq(int(wi.get("replaced")), 1, "a span refinement (same neutral) does not call it")
			node.start_manual()
			h.spread_pose()
			run(node, rig, h, 2.0)
			eq(int(wi.get("replaced")), 2, "a manual recapture calls it again")
		drop_player(p)
		node.queue_free()
		(rig["origin"] as Node).queue_free()


## Flight's WingInput refines the span by its own rule (any grip distance
## 5 cm wider for 0.5 s) even while VR owns the calibration; VR's span is
## the one the player flies, so a change made there is undone on VR's next
## tick (fix round 4: a controller set down on a table would otherwise
## still inflate what flight flies). The mock grows flight's copy the way
## wing_input.gd does.
func test_flights_own_span_growth_is_undone() -> void:
	var rig := make_rig()
	var p := make_player("perched")
	var node := make_node(rig, MemoryStore.new())
	var h := player(1.6, [0.0, 0.0])
	h.spread_pose()
	node.start_manual()
	run(node, rig, h, 2.5)
	check(node.calibrator.calibrated, "(setup) captured")
	var res: Resource = p.calibration
	near(float(res.get("arm_span")), node.calibrator.arm_span, 1e-6, "(setup) flight flies VR's span")
	# What flight's refinement does with a controller on a table 2 m away.
	res.set("arm_span", 2.0)
	res.set("shoulder_width", 0.46)
	node.tick(DT)
	near(float(res.get("arm_span")), node.calibrator.arm_span, 1e-6, "VR's span is back in flight's resource after one tick")
	near(float(res.get("shoulder_width")), node.calibrator.shoulder_width, 1e-6, "and its shoulder width")
	drop_player(p)
	node.queue_free()
	(rig["origin"] as Node).queue_free()


## A new WingCalibration on the same PlayerBird (a new WingInput) is found
## within half a second (RES_REFRESH ticks) and gets VR's calibration (mutant E03, never
## refreshed, survived).
func test_new_resource_on_the_same_player_is_found() -> void:
	var rig := make_rig()
	var p := make_player("perched")
	var node := make_node(rig, MemoryStore.new())
	var h := player(1.7, [0.0, 0.0])
	h.spread_pose()
	node.start_manual()
	run(node, rig, h, 2.5)
	check(node.calibrator.calibrated, "(setup) captured")
	# The old resource stays alive (flight may keep it around): the cache
	# must still move on to the new one.
	var old_res: Resource = p.calibration
	var fresh := CalMock.new()
	p.calibration = fresh
	# Within half a second at 72 Hz (the documented refresh is 30 ticks).
	for i in 36:
		drive(rig, h)
		node.tick(DT)
	check(bool(fresh.get("calibrated")), "the new resource is calibrated by VR")
	near(float(fresh.get("arm_span")), node.calibrator.arm_span, 1e-6, "with VR's span")
	check(is_instance_valid(old_res), "(the old resource was alive throughout)")
	drop_player(p)
	node.queue_free()
	(rig["origin"] as Node).queue_free()


## Seated detection has hysteresis: below 1.30 m for 5 s is seated, and
## only above 1.40 m for 5 s is standing again, so a player leaning or
## slouching around 1.35 m never flips (mutant E04 removed it).
func test_seated_detection_has_hysteresis() -> void:
	for span in [1.5, 2.0]:
		var h := player(span, [0.0, 0.0])
		var cal := calibrated_for(h)
		check(not cal.is_seated(), "span %.1f: (setup) standing" % span)
		var th := cal.seat_thresholds()
		var sit_y := th.x
		var stand_y := th.y
		# (For these ape-index-1 players the standing eyes do not bind: the
		# thresholds are round 3's span-derived ones.)
		var stature := cal.arm_span + WingCalibrator.SPAN_TO_STATURE
		near(sit_y, maxf(WingCalibrator.SEATED_HEAD_Y, WingCalibrator.SEATED_EYE_FRACTION * stature), 1e-6, "span %.1f: seated threshold" % span)
		near(stand_y, maxf(WingCalibrator.SEATED_HEAD_Y + 0.10, WingCalibrator.STANDING_EYE_FRACTION * stature), 1e-6, "span %.1f: standing threshold" % span)
		var band := 0.5 * (sit_y + stand_y)
		h.set_arms(deg_to_rad(-20.0))
		h.eye_height = sit_y - 0.05
		feed(cal, h, 5.2, 0.0)
		check(cal.is_seated(), "span %.1f: eyes at %.2f m for 5 s: seated" % [span, h.eye_height])
		h.eye_height = band
		feed(cal, h, 10.0, 0.0)
		check(cal.is_seated(), "span %.1f: eyes at %.2f m for 10 s: still seated (inside the band)" % [span, band])
		h.eye_height = stand_y + 0.05
		feed(cal, h, 4.8, 0.0)
		check(cal.is_seated(), "span %.1f: above %.2f m for 4.8 s: not yet standing" % [span, stand_y])
		feed(cal, h, 0.4, 0.0)
		check(not cal.is_seated(), "span %.1f: above %.2f m for 5 s: standing" % [span, stand_y])
		h.eye_height = band
		feed(cal, h, 10.0, 0.0)
		check(not cal.is_seated(), "span %.1f: %.2f m again: stays standing (inside the band)" % [span, band])
		metric("seated_band_span_%.1f" % span, [snappedf(sit_y, 0.001), snappedf(stand_y, 0.001)])


## The span only grows for a spread clearly wider than the capture (5 cm):
## a stretch of 3 cm is tracker noise and posture, 7 cm is a real reach
## (mutant E05 removed the margin).
func test_span_grows_only_past_the_margin() -> void:
	var h := player(1.6, [0.0, 0.0])
	var cal := calibrated_for(h)
	var span0 := cal.arm_span
	h.arm_span += 0.03
	spreads(cal, h, 3)
	near(cal.arm_span, span0, 1e-6, "3 cm wider, three spreads: unchanged")
	h.arm_span += 0.04
	spreads(cal, h, 2)
	gt(cal.arm_span, span0 + 0.05, "7 cm wider, two spreads: grown (%.3f -> %.3f)" % [span0, cal.arm_span])


## Crossed arms flip the hand line by 180°; the torso yaw must not follow
## (FLIGHT_SPEC §5.2: a jump > 75° is accepted only if the head agrees),
## else a player folding their arms across the chest would spin the body
## frame round (mutant E06 removed the gate).
func test_crossed_arms_do_not_flip_the_body() -> void:
	var h := player(1.6, [0.0, 0.0])
	var cal := calibrated_for(h)
	near(cal.body_yaw, 0.0, 0.02, "(setup) facing forward")
	var worst := 0.0
	# Straight arms swept forward and across the chest until the hands have
	# swapped sides far apart (the hand line is then flipped and long
	# enough to steer the torso estimate).
	for i in 60:
		var t := float(i) / 59.0
		h.set_arms(deg_to_rad(-10.0), deg_to_rad(lerpf(0.0, 155.0, t)))
		feed(cal, h, DT, 0.0)
	var w := VRMath.horiz(cal.hands[1].origin - cal.hands[0].origin)
	lt(w.dot(Vector3.RIGHT), 0.0, "(setup) the arms are crossed: the right hand is left of the left one")
	for i in int(1.5 / DT):
		feed(cal, h, DT, 0.0)
		worst = maxf(worst, absf(rad_to_deg(VRMath.wrap_angle(cal.body_yaw))))
	lt(worst, 20.0, "crossed arms, head forward: the body frame stays forward (worst %.1f°)" % worst)
	metric("crossed_arms_worst_yaw_deg", worst)


## Where swing-twist is ill-conditioned (a forearm swung ~180° from its
## neutral, the hand brought back to the shoulder), the last well-defined
## twist is held rather than read (FLIGHT_SPEC §5.7; mutant E15 read it).
func test_ill_conditioned_twist_is_held() -> void:
	var h := player(1.6, [0.0, 0.0])
	var cal := calibrated_for(h)
	var last_good := [0.0, 0.0]
	var low := 0
	var worst := 0.0
	for i in 200:
		var t := float(i) / 199.0
		h.set_arms(deg_to_rad(-20.0), deg_to_rad(lerpf(0.0, 60.0, t)), deg_to_rad(lerpf(0.0, 50.0, t)), deg_to_rad(lerpf(0.0, 178.0, t)))
		feed(cal, h, DT, 0.0)
		for side in 2:
			if cal.twist_conf[side] >= 0.25:
				last_good[side] = cal.twist[side]
			else:
				low += 1
				worst = maxf(worst, absf(cal.twist[side] - float(last_good[side])))
	gt(float(low), 0.0, "(setup) the path passes through ill-conditioned poses (%d samples)" % low)
	lt(worst, 1e-6, "there the twist holds its last well-defined value (worst change %.4f rad)" % worst)


## FLIGHT_SPEC §5.10 as flight's WingInput implements it (this suite's
## own mock of it, so the suite never loads flight's in-progress code):
## arm span = grip-to-grip, drop assuming the arms 5° low (clamped to
## 0.15-0.35), the neutral as held, forearm axis from those shoulders.
func flight_like_capture(h: VRHumanPose, res: Resource) -> void:
	var hd := h.head_transform()
	var l := h.hand_transform(0)
	var r := h.hand_transform(1)
	var span := clampf((r.origin - l.origin).length(), 1.0, 2.2)
	var sw := 0.23 * span
	var l_arm := (span - sw) * 0.5
	var drop := clampf(hd.origin.y - 0.5 * (l.origin.y + r.origin.y) - l_arm * sin(deg_to_rad(5.0)), 0.15, 0.35)
	var f := Vector3.UP.cross(VRMath.horiz(r.origin - l.origin)).normalized()
	var b := Basis(Vector3.UP, VRMath.yaw_of(f))
	var rt := f.cross(Vector3.UP)
	var neck := hd.origin + hd.basis * Vector3(0.0, -0.08, 0.09)
	var centre := neck + Vector3(0.0, -(drop - 0.08), 0.0) - f * 0.02
	var sh := [centre - rt * sw * 0.5, centre + rt * sw * 0.5]
	var hands := [l, r]
	var names := ["left", "right"]
	for i in 2:
		var hb: Basis = (hands[i] as Transform3D).basis
		var a := (hb.transposed() * ((hands[i] as Transform3D).origin - (sh[i] as Vector3)).normalized()).normalized()
		var c := hb.transposed() * f
		c = (c - a * c.dot(a)).normalized()
		res.set("neutral_" + names[i], b.transposed() * hb)
		res.set("forearm_axis_" + names[i], a)
		res.set("chord_axis_" + names[i], c)
	res.set("arm_span", span)
	res.set("shoulder_width", sw)
	res.set("shoulder_drop", drop)
	res.set("calibrated", true)


## Flight's WingInput captured before VR (the extras attached late, or its
## own begin_calibration): VR adopts it, refined to its own maths, writes
## it back to flight and persists it. Fix round 2 (both verifiers): read as
## is, a half fold read 0.09-0.61 of extension depending on how high the
## arms were held at capture; refined, it reads what VR's own capture of
## the same hold reads, for every capture height.
func test_adopted_capture_is_refined_to_vrs_maths() -> void:
	var fold_refined: Array[float] = []
	var pitch_refined: Array[float] = []
	var fold_raw: Array[float] = []
	var rows := {}
	for elev in [-12.0, -5.0, 0.0, 8.0]:
		var rig := make_rig()
		var store := MemoryStore.new()
		var p := make_player("perched")
		var res: Resource = p.calibration
		var h := player(1.75, [15.0, -10.0])
		h.set_arms(deg_to_rad(elev))
		drive(rig, h)
		flight_like_capture(h, res)
		var raw := WingCalibrator.new()
		raw.read_from(res)
		var node := make_node(rig, store)
		node.tick(DT)
		var tag := "arms %+.0f°" % elev
		check(node.calibrator.calibrated and not node.calibrator.capturing and node.flow == VRCalibration.Flow.IDLE, "%s: adopted, no capture of its own" % tag)
		near(float(res.get("shoulder_drop")), node.calibrator.shoulder_drop, 1e-6, "%s: the refined drop is written back to flight" % tag)
		lt(VRMath.basis_angle(res.get("neutral_right"), node.calibrator.neutral[1]), 1e-4, "%s: and the refined neutral" % tag)
		near(float((store.get_value("wing_calibration", {}) as Dictionary).get("shoulder_drop", 0.0)), node.calibrator.shoulder_drop, 1e-6, "%s: persisted" % tag)
		# VR's own capture of the same hold.
		var own := perched()
		feed(own, h, 1.8)
		near(node.calibrator.shoulder_drop, own.shoulder_drop, 0.005, "%s: refined drop = VR's own estimate" % tag)
		near(node.calibrator.arm_span, own.arm_span, 0.005, "%s: refined span = VR's own full spread" % tag)
		# Every gesture, read through what flight now flies, as VR's own reads it.
		var flies := WingCalibrator.new()
		flies.read_from(res)
		var a := readings(flies, h)
		var b := readings(own, h)
		var we := 0.0
		var wt := 0.0
		var wp := 0.0
		for g in GESTURES:
			we = maxf(we, maxf(absf(a[g][0] - b[g][0]), absf(a[g][1] - b[g][1])))
			if twist_comparable(a[g], b[g]):
				wt = maxf(wt, maxf(absf(a[g][2] - b[g][2]), absf(a[g][3] - b[g][3])))
				wp = maxf(wp, absf(a[g][4] - b[g][4]))
		lt(we, 0.02, "%s: every gesture's extension as VR's own capture (worst %.4f)" % [tag, we])
		lt(wt, 0.5, "%s: every wrist twist as VR's own (worst %.2f°)" % [tag, wt])
		lt(wp, 0.01, "%s: every pitch command as VR's own (worst %.4f)" % [tag, wp])
		var c := readings(raw, h)
		fold_refined.append(a["half_fold"][0])
		pitch_refined.append(a["half_fold"][4])
		fold_raw.append(c["half_fold"][0])
		rows[tag] = {"flight_drop": snappedf(raw.shoulder_drop, 0.001), "refined_drop": snappedf(node.calibrator.shoulder_drop, 0.001),
			"true_drop": snappedf(h.shoulder_drop, 0.001), "half_fold_raw": snappedf(c["half_fold"][0], 0.001),
			"half_fold_refined": snappedf(a["half_fold"][0], 0.001), "pitch_refined": snappedf(a["half_fold"][4], 0.001)}
		drop_player(p)
		node.queue_free()
		(rig["origin"] as Node).queue_free()
	metric("adoption_by_capture_height", rows)
	gt(fold_raw.max() - fold_raw.min(), 0.2, "(contrast) flight's capture read as is: the half fold depends on the capture height (range %.3f)" % (fold_raw.max() - fold_raw.min()))
	lt(fold_refined.max() - fold_refined.min(), 0.04, "refined: the half fold reads the same for every capture height (range %.4f)" % (fold_refined.max() - fold_refined.min()))
	lt(pitch_refined.max() - pitch_refined.min(), 0.02, "refined: and the same pitch command (range %.4f)" % (pitch_refined.max() - pitch_refined.min()))


## Flight's loader ORs the Settings "seated" preference into its flag, so an
## adopted capture must not turn the preference into "detected": switching
## seated play off afterwards has to work (a verifier's probe).
func test_adoption_keeps_the_seated_preference_out_of_the_saved_dict() -> void:
	var rig := make_rig()
	var store := MemoryStore.new()
	store.set_value("seated", true)
	var p := make_player("perched")
	var res: Resource = p.calibration
	var h := player(1.7, [0.0, 0.0])
	h.spread_pose()
	drive(rig, h)
	flight_like_capture(h, res)
	res.set("seated", true)
	var node := make_node(rig, store)
	node.tick(DT)
	check(node.calibrator.calibrated, "(setup) adopted")
	check(node.calibrator.is_seated(), "seated while the preference is on")
	check(bool(res.get("seated")), "flight flies seated")
	eq(bool((store.get_value("wing_calibration", {}) as Dictionary).get("seated", true)), false, "the saved calibration keeps only the detected flag (standing)")
	store.set_value("seated", false)
	Events.settings_changed.emit("seated", false)
	check(not node.calibrator.is_seated(), "switching the preference off leaves seated mode")
	check(not bool(res.get("seated")), "and flight's flag follows")
	drop_player(p)
	node.queue_free()
	(rig["origin"] as Node).queue_free()


## The seated preference is applied live, to VR's calibration and to the
## calibration flight flies, and never persisted as "detected".
func test_seated_setting_applies_live() -> void:
	var rig := make_rig()
	var store := MemoryStore.new()
	var node := make_node(rig, store)
	var p := make_player("perched")
	var res: Resource = p.calibration
	var h := player(1.7, [0.0, 0.0])
	h.spread_pose()
	node.start_manual()
	run(node, rig, h, 2.0)
	check(node.calibrator.calibrated and not bool(res.get("seated")), "(setup) a standing player, calibrated")
	store.set_value("seated", true)
	Events.settings_changed.emit("seated", true)
	check(node.calibrator.is_seated(), "Settings seated on: seated mode at once")
	check(bool(res.get("seated")), "flight's calibration is seated at once")
	eq(bool((store.get_value("wing_calibration", {}) as Dictionary).get("seated", true)), false, "the persisted flag stays 'not detected'")
	store.set_value("seated", false)
	Events.settings_changed.emit("seated", false)
	check(not node.calibrator.is_seated() and not bool(res.get("seated")), "Settings seated off: standing again, in flight too")
	drop_player(p)
	node.queue_free()
	(rig["origin"] as Node).queue_free()


## VR owns the calibration: the PlayerBird's own automatic capture
## (auto_calibrate) is switched off while VR's calibration runs and
## restored when it leaves; a new PlayerBird (respawn) is claimed and
## receives VR's calibration.
func test_vr_owns_the_automatic_capture() -> void:
	var rig := make_rig()
	var store := MemoryStore.new()
	var node := make_node(rig, store)
	var p1 := make_player("perched")
	node.tick(DT)
	check(not bool(p1.get("auto_calibrate")), "flight's own automatic capture switched off")
	var p2 := make_player("spawning")
	check(Birds.player() == p2, "(setup) a new PlayerBird")
	node.tick(DT)
	check(not bool(p2.get("auto_calibrate")), "the new PlayerBird is claimed")
	check(bool(p1.get("auto_calibrate")), "the previous one is given its own capture back")
	var h := player(1.8, [0.0, 0.0])
	h.spread_pose()
	p2.set("mode_label", "perched")
	node.start_manual()
	run(node, rig, h, 2.0)
	check(node.calibrator.calibrated, "VR captured")
	near(float(p2.calibration.get("arm_span")), node.calibrator.arm_span, 1e-6, "and wrote flight's calibration")
	# A respawned PlayerBird starts uncalibrated: VR's calibration reaches it
	# on the next tick (no player_spawned needed).
	var p3 := make_player("spawning")
	node.tick(DT)
	check(bool(p3.calibration.get("calibrated")), "a new PlayerBird flies VR's calibration")
	near(float(p3.calibration.get("arm_span")), node.calibrator.arm_span, 1e-6, "with VR's span")
	# The same PlayerBird's resource reset to defaults (flight rebuilt its
	# WingInput, or reset it): VR's calibration goes back in on the next tick.
	p3.calibration.set("calibrated", false)
	p3.calibration.set("arm_span", 1.5)
	node.tick(DT)
	check(bool(p3.calibration.get("calibrated")), "a reset flight calibration is refilled with VR's")
	near(float(p3.calibration.get("arm_span")), node.calibrator.arm_span, 1e-6, "(VR's span again)")
	remove_child(node)
	check(bool(p3.get("auto_calibrate")), "VR's calibration gone: flight captures by itself again")
	node.free()
	for p in [p1, p2, p3]:
		drop_player(p)
	(rig["origin"] as Node).queue_free()


## "Hold still" is part of the automatic capture: arms drifting at ~0.1 m/s
## through an otherwise perfect spread (wrists turning < 13°/s, so only the
## hand-speed gate can stop it) are not a hold; a drift under 0.02 m/s is.
## A wrist rolling at 60°/s with the hands still is not a hold either.
func test_capture_waits_for_still_hands() -> void:
	var h := player(1.6, [0.0, 0.0])
	var cal := perched()
	var top_speed := 0.0
	var top_ang := 0.0
	for i in int(4.0 / DT):
		h.set_arms(deg_to_rad(-5.0), deg_to_rad(4.0 * sin(i * DT * TAU * 0.5)))
		cal.measure(h.head_transform(), h.hand_transform(0), h.hand_transform(1), 7, DT)
		if i * DT > 1.0:
			top_speed = maxf(top_speed, cal.hand_speed[0])
			top_ang = maxf(top_ang, rad_to_deg(cal.hand_ang_speed[0]))
	check(not cal.calibrated, "arms drifting at %.2f m/s are not a hold" % top_speed)
	between(top_speed, 0.09, 0.2, "(the drift is a real one: %.3f m/s)" % top_speed)
	lt(top_ang, 20.0, "(wrists turn only %.1f°/s: the hand-speed gate is what waits)" % top_ang)
	cal = perched()
	for i in int(4.0 / DT):
		h.set_arms(deg_to_rad(-5.0), deg_to_rad(1.0 * sin(i * DT * TAU * 0.25)))
		cal.measure(h.head_transform(), h.hand_transform(0), h.hand_transform(1), 7, DT)
	check(cal.calibrated, "a slow sway under 0.02 m/s is a hold")
	cal = perched()
	for i in int(4.0 / DT):
		h.set_arms(deg_to_rad(-5.0), 0.0, deg_to_rad(10.0 * sin(i * DT * TAU)))
		cal.measure(h.head_transform(), h.hand_transform(0), h.hand_transform(1), 7, DT)
	check(not cal.calibrated, "a wrist rolling at 60°/s with still hands is not a hold")
	metric("drift_speed_m_s", top_speed)


## The standing eye height that bounds the seated thresholds comes only
## from a standing capture: a detected seated capture, or one taken with
## the Settings seated preference on (the player may be sitting), records
## none, so a seated player's eyes are never taken for standing ones.
func test_standing_eyes_only_from_a_standing_capture() -> void:
	var h := player(1.7, [0.0, 0.0])
	var cal := calibrated_for(h)
	near(cal.standing_eye, h.eye_height, 0.005, "standing capture: the eyes (%.3f m)" % cal.standing_eye)
	near(float(cal.to_dict().get("standing_eye", 0.0)), cal.standing_eye, 1e-6, "persisted")
	var pref := perched()
	pref.seated_setting = true
	h.spread_pose()
	feed(pref, h, 2.0)
	check(pref.calibrated, "(setup) captured with the seated preference on")
	eq(pref.standing_eye, -1.0, "seated preference on: no standing eyes recorded")
	var s := VRHumanPose.for_span(1.7, true)
	var sc := perched()
	s.spread_pose()
	feed(sc, s, 2.0)
	check(sc.calibrated and sc.is_seated(), "(setup) a seated capture")
	eq(sc.standing_eye, -1.0, "detected seated: no standing eyes recorded")


## Each documented gate of the span refinement's spread sample, alone
## (fix round 4): a genuine spread gives a sample (the calibrated span);
## each departure from it gives none, with the reason. Held 0.5 s so the
## hand-speed estimate has settled.
func test_spread_gates() -> void:
	var h := player(1.7, [0.0, 0.0])
	var cal := calibrated_for(h)
	var sample := func(setup: Callable) -> Array:
		h.set_arms(deg_to_rad(-5.0))
		h.head_pitch = 0.0
		setup.call()
		feed(cal, h, 0.5, 0.0)
		var v := cal.spread_span_sample()
		return [v, cal.spread_blocker]
	var ok: Array = sample.call(func() -> void: pass)
	near(float(ok[0]), cal.arm_span, 0.005, "a genuine spread: a sample of the calibrated span (%s)" % str(ok))
	eq(ok[1], "", "no blocker")
	var cases := {
		"not now (paused, menu, unfocused)": func() -> void: cal.refine_allowed = false,
		"head tilted": func() -> void: h.head_pitch = deg_to_rad(-45.0),
		"not at shoulder height": func() -> void: h.set_arms(deg_to_rad(35.0)),
		"not out to the side": func() -> void: h.set_arms(deg_to_rad(-5.0), deg_to_rad(40.0)),
		"uneven": func() -> void: h.elbow = [0.0, deg_to_rad(55.0)],
	}
	for why in cases:
		var r: Array = sample.call(cases[why])
		cal.refine_allowed = true
		eq(r[1], why, "blocked: %s" % why)
		eq(float(r[0]), -1.0, "%s: no sample" % why)
	# Grips straight out to the side but at 0.75 and 1.4 arm lengths from
	# the shoulders (hands pulled in; controllers further out than any arm).
	h.set_arms(deg_to_rad(0.0))
	for k in [0.75, 1.4]:
		for i in int(0.5 / DT):
			var g: Array[Transform3D] = []
			for side in 2:
				var x := h.hand_transform(side)
				var out := Vector3(float(WingCalibrator.SIDE_SIGN[side]), 0.0, 0.0)
				g.append(Transform3D(x.basis, h.shoulder(side) + out * (k * h.arm_length())))
			cal.measure(h.head_transform(), g[0], g[1], 7, DT)
		eq(cal.spread_span_sample(), -1.0, "grips at %.2f arm lengths: no sample" % k)
		eq(cal.spread_blocker, "out of arm's reach", "blocked at %.2f arm lengths: out of arm's reach" % k)
	# Hands moving: the player walks sideways at 0.4 m/s with the arms
	# spread (the hand-speed estimate over 0.25 m/s).
	h.set_arms(deg_to_rad(-5.0))
	for i in int(0.6 / DT):
		h.room_offset += Vector3(0.4 * DT, 0.0, 0.0)
		cal.measure(h.head_transform(), h.hand_transform(0), h.hand_transform(1), 7, DT)
	cal.spread_span_sample()
	eq(cal.spread_blocker, "hands moving", "blocked: hands moving (%.2f m/s)" % maxf(cal.hand_speed[0], cal.hand_speed[1]))
	h.room_offset = Vector3.ZERO
	# A controller without tracking.
	h.set_arms(deg_to_rad(-5.0))
	feed(cal, h, 0.5, 0.0, 5)
	cal.spread_span_sample()
	eq(cal.spread_blocker, "tracking", "blocked: tracking")


## In a headset a controller's pose counts only while it has tracking data
## (XRNode3D.get_has_tracking_data: a controller that lost tracking keeps
## its last pose, which must not be measured or captured). Mutant R15
## treated every node as tracked and survived: the desktop tests never
## asked. Here VR is briefly "active" with XRController3Ds whose trackers
## do not exist (no tracking data); on the desktop every node counts.
func test_untracked_controllers_are_not_measured_in_xr() -> void:
	var rig := make_rig()
	var node := make_node(rig, MemoryStore.new())
	node.force_valid = null
	var h := player(1.7, [0.0, 0.0])
	h.spread_pose()
	run(node, rig, h, 0.1)
	check(node.calibrator.valid[0] and node.calibrator.valid[1], "desktop (no XR): the rig's nodes are the pose source")
	var was := [VR.active, VR.focused]
	VR.active = true
	VR.focused = true
	node.start_manual()
	run(node, rig, h, 2.0)
	var valid_xr := [node.calibrator.valid[0], node.calibrator.valid[1]]
	var captured := node.calibrator.calibrated
	var blocker := node.calibrator.neutral_blocker()
	VR.active = was[0]
	VR.focused = was[1]
	eq(blocker, "tracking", "(the step was waiting for tracking)")
	check(not valid_xr[0] and not valid_xr[1], "in XR, controllers without tracking data are not measured")
	check(not captured, "and never captured")
	node.queue_free()
	(rig["origin"] as Node).queue_free()


## Startup glue: a saved calibration is loaded, final (no automatic
## capture), and pushed into the PlayerBird's WingCalibration, including a
## PlayerBird that spawns later.
func test_saved_calibration_reaches_the_player() -> void:
	var store := MemoryStore.new()
	var src := calibrated_for(player(1.9, [25.0, -25.0]))
	store.set_value("wing_calibration", src.to_dict())
	var p := make_player("perched")
	var node := VRCalibration.new()
	node.store = store
	node.auto_tick = false
	node.show_prompt = false
	add_child(node)
	check(node.calibrator.calibrated, "loaded at startup")
	check(not node.calibrator.capturing and node.flow == VRCalibration.Flow.IDLE and not node.first_launch_pending, "a loaded calibration is final (no step)")
	near(node.calibrator.arm_span, src.arm_span, 1e-6, "arm span loaded")
	near(float(p.calibration.get("arm_span")), src.arm_span, 1e-6, "pushed into the player's WingCalibration")
	lt(VRMath.basis_angle(p.calibration.get("neutral_left"), src.neutral[0]), 1e-4, "neutral basis pushed")
	vnear(p.calibration.get("forearm_axis_right"), src.forearm_axis[1], 1e-5, "forearm axis pushed")
	check(bool(p.calibration.get("calibrated")), "marked calibrated")
	# A respawned PlayerBird gets it too.
	drop_player(p)
	var p2 := make_player("spawning")
	Events.player_spawned.emit(p2)
	near(float(p2.calibration.get("arm_span")), src.arm_span, 1e-6, "a new PlayerBird receives the calibration on player_spawned")
	drop_player(p2)
	node.queue_free()


## Real people differ from the calibrator's body model, and hold the
## "spread your wings" pose their own way. The population is a box of adult
## ranges: span 1.4-2.0 m, shoulders 0.20-0.26 of the span, ape index
## 0.95-1.05, eyes-to-shoulder drop 0.14-0.16 of stature, eyes 0.925-0.945
## of stature, a floor ±3 cm off, wrist habits ±25° on each hand, and a
## capture style that combines the arm height (12° low .. 8° high), hands up
## to 10° forward, elbows up to 15° soft and a glance at a hand (25° aside,
## 15° down).
## The worst case is taken over every corner of that whole box: 64 body
## corners x 16 capture-style corners x 4 wrist-habit corners (4096
## players). Fix round 3: round 2 applied each style alone (8 styles x 2
## habits), and a verifier's probe showed that real, combined styles read
## worse (extension 0.192, twist 4.9°) than that "corner" bound claimed.
## Mirror symmetry covers a glance at the other hand (the habit corners
## include both mixed signs). Three seeds of 120 random players with
## continuously random combined styles must never read worse than the
## corners.
## The bounds are the corner worst case, rounded up (docs/areas/VR.md §8):
## shoulder width and the drop ratio cannot be seen in a still pose (the
## half fold, whose hand is ~20 cm from the shoulder, is the gesture that
## feels them); soft elbows at capture tilt the measured forearm axis
## (flight's auto-trim, ±10° at τ 60 s, absorbs a glide bias of that size).
const REAL_BOUNDS := {"ext": 0.20, "twist": 5.2, "pitch": 0.095, "pitch_folded": 0.16, "drop": 0.035}
## Named single styles (the breakdown test, and the evidence table):
## [arm elevation, hands forward (sweep), elbow bend, head yaw, head pitch].
const CAPTURE_STYLES := {
	"textbook": [-5.0, 0.0, 0.0, 0.0, 0.0],
	"arms_12_low": [-12.0, 0.0, 0.0, 0.0, 0.0],
	"arms_level": [0.0, 0.0, 0.0, 0.0, 0.0],
	"arms_5_high": [5.0, 0.0, 0.0, 0.0, 0.0],
	"arms_8_high": [8.0, 0.0, 0.0, 0.0, 0.0],
	"hands_forward_10": [-5.0, 10.0, 0.0, 0.0, 0.0],
	"soft_elbows_15": [-5.0, 0.0, 15.0, 0.0, 0.0],
	"looking_at_hand": [-5.0, 0.0, 0.0, 25.0, -15.0],
}


## The 16 corners of the capture-style box (bit 0 arms 8° high vs 12° low,
## bit 1 hands 10° forward, bit 2 elbows 15° soft, bit 3 a glance at the
## right hand).
static func style_corner(mask: int) -> Array:
	return [8.0 if mask & 1 else -12.0, 10.0 if mask & 2 else 0.0, 15.0 if mask & 4 else 0.0,
		25.0 if mask & 8 else 0.0, -15.0 if mask & 8 else 0.0]


## A player from the population box, posed in a capture style
## ([elevation, sweep, elbow, head yaw, head pitch] in degrees, or a
## CAPTURE_STYLES name).
func real_body(span: float, sr: float, ape: float, dr: float, er: float, floor_err: float, habit: Array, style: Variant) -> VRHumanPose:
	var h := VRHumanPose.new()
	var stature := span / ape + 0.16
	h.arm_span = span
	h.shoulder_width = sr * span
	h.shoulder_drop = dr * stature
	h.eye_height = er * stature
	h.room_offset = Vector3(0.0, floor_err, 0.0)
	h.twist_offset = [deg_to_rad(habit[0]), deg_to_rad(habit[1])]
	var st: Array = CAPTURE_STYLES[style] if style is String else style
	h.set_arms(deg_to_rad(st[0]), deg_to_rad(st[1]), 0.0, deg_to_rad(st[2]))
	h.head_yaw = deg_to_rad(st[3])
	h.head_pitch = deg_to_rad(st[4])
	return h


func new_worst() -> Dictionary:
	return {"ext": 0.0, "twist": 0.0, "pitch": 0.0, "pitch_folded": 0.0, "drop": 0.0, "missed": 0, "players": 0}


## Captures one player automatically (perched) and folds its readings of
## every gesture, against the reference, into `worst`.
func score_player(h: VRHumanPose, ref: Dictionary, worst: Dictionary, tag: String) -> void:
	var cal := perched()
	feed(cal, h, 1.8)
	h.head_yaw = 0.0
	h.head_pitch = 0.0
	worst["players"] += 1
	if not cal.calibrated:
		worst["missed"] += 1
		print("[vr] not captured: ", tag)
		return
	var pairs := [["drop", absf(cal.shoulder_drop - h.shoulder_drop), ""]]
	var r := readings(cal, h)
	for g in GESTURES:
		var a: Array = r[g]
		var b: Array = ref[g]
		var ok := twist_comparable(a, b)
		pairs.append(["ext", maxf(absf(a[0] - b[0]), absf(a[1] - b[1])), g])
		var dp := absf(a[4] - b[4]) if ok else 0.0
		if g in SPREAD_GESTURES:
			pairs.append(["twist", maxf(absf(a[2] - b[2]), absf(a[3] - b[3])) if ok else 0.0, g])
			pairs.append(["pitch", dp, g])
		else:
			pairs.append(["pitch_folded", dp, g])
	for pr in pairs:
		if float(pr[1]) > float(worst[pr[0]]):
			worst[pr[0]] = pr[1]
			worst[pr[0] + "_case"] = tag + (" / " + pr[2] if pr[2] != "" else "")


func worst_row(w: Dictionary) -> Dictionary:
	return {"ext": snappedf(w["ext"], 0.001), "twist_deg": snappedf(w["twist"], 0.01), "pitch": snappedf(w["pitch"], 0.001),
		"pitch_folded": snappedf(w["pitch_folded"], 0.001), "drop_m": snappedf(w["drop"], 0.001), "players": w["players"]}


func _merge_worst(into: Dictionary, w: Dictionary) -> void:
	for k in REAL_BOUNDS:
		if float(w[k]) > float(into[k]):
			into[k] = w[k]
			into[k + "_case"] = w.get(k + "_case", "")
	into["missed"] += w["missed"]
	into["players"] += w["players"]


func test_real_bodies_worst_case_is_bounded_at_the_corners() -> void:
	# The tracker noise of this test is its own (the same numbers whichever
	# tests ran before it).
	_rng.seed = 20260926
	var ref_h := player(1.6, [0.0, 0.0])
	var ref := readings(calibrated_for(ref_h), ref_h)
	# Every corner of the whole box: body x capture style x wrist habits.
	var corners := new_worst()
	var by_style := {}
	for sm in 16:
		var style := style_corner(sm)
		var ws := new_worst()
		for mask in 64:
			var f := [2.0 if mask & 1 else 1.4, 0.26 if mask & 2 else 0.20, 1.05 if mask & 4 else 0.95,
				0.16 if mask & 8 else 0.14, 0.945 if mask & 16 else 0.925, 0.03 if mask & 32 else -0.03]
			for habit in [[25.0, 25.0], [-25.0, -25.0], [25.0, -25.0], [-25.0, 25.0]]:
				var tag := "span %.2f sh %.2f ape %.2f drop %.2fH eyes %.3fH floor %+.2f habit %+.0f/%+.0f style %s" % [f[0], f[1], f[2], f[3], f[4], f[5],
					habit[0], habit[1], str(style)]
				score_player(real_body(f[0], f[1], f[2], f[3], f[4], f[5], habit, style), ref, ws, tag)
		by_style["elev %+.0f fwd %.0f elbow %.0f look %.0f" % [style[0], style[1], style[2], style[3]]] = worst_row(ws)
		_merge_worst(corners, ws)
	eq(corners["missed"], 0, "every corner player in every capture style is captured")
	eq(corners["players"], 4096, "64 body x 16 style x 4 habit corners")
	# Random players inside the box with continuously random, combined
	# capture styles, three seeds.
	var random := new_worst()
	var per_seed := {}
	for seed in [2026, 7, 42]:
		var rng := RandomNumberGenerator.new()
		rng.seed = seed
		var sw := new_worst()
		for n in 120:
			var f := [rng.randf_range(1.4, 2.0), rng.randf_range(0.20, 0.26), rng.randf_range(0.95, 1.05),
				rng.randf_range(0.14, 0.16), rng.randf_range(0.925, 0.945), rng.randf_range(-0.03, 0.03)]
			var habit := [rng.randf_range(-25.0, 25.0), rng.randf_range(-25.0, 25.0)]
			var style := [rng.randf_range(-12.0, 8.0), rng.randf_range(0.0, 10.0), rng.randf_range(0.0, 15.0),
				rng.randf_range(-25.0, 25.0), rng.randf_range(-15.0, 0.0)]
			var tag := "seed %d: span %.2f sh %.3f ape %.3f drop %.3fH eyes %.3fH floor %+.3f style %s" % [seed, f[0], f[1], f[2], f[3], f[4], f[5], str(style)]
			score_player(real_body(f[0], f[1], f[2], f[3], f[4], f[5], habit, style), ref, sw, tag)
		per_seed[str(seed)] = worst_row(sw)
		_merge_worst(random, sw)
	eq(random["missed"], 0, "every random player is captured")
	eq(random["players"], 360, "3 seeds x 120 random players")
	print("[vr] real bodies, corners: %s" % str(worst_row(corners)))
	print("[vr] real bodies, 3 x 120 random: %s" % str(worst_row(random)))
	for k in REAL_BOUNDS:
		print("[vr]   worst %-12s corner: %s | random: %s" % [k, corners.get(k + "_case", ""), random.get(k + "_case", "")])
	metric("real_bodies_corners_worst", worst_row(corners))
	metric("real_bodies_random_worst", worst_row(random))
	metric("real_bodies_corners_worst_by_style", by_style)
	metric("real_bodies_random_worst_by_seed", per_seed)
	var cases := {}
	for k in REAL_BOUNDS:
		cases[k] = {"corners": corners.get(k + "_case", ""), "random": random.get(k + "_case", "")}
	metric("real_bodies_worst_cases", cases)
	for k in REAL_BOUNDS:
		lt(float(corners[k]), float(REAL_BOUNDS[k]), "corner worst %s %.4f within the population bound %.3f" % [k, corners[k], REAL_BOUNDS[k]])
		lt(float(random[k]), float(corners[k]) + 0.005 * (10.0 if k == "twist" else 1.0),
			"random players never read worse than the corners (%s: random %.4f, corners %.4f)" % [k, random[k], corners[k]])


## The capture style alone (textbook body): arms held anywhere from 12° low
## to 8° high must not move the shoulder estimate (it did, 1.1 cm/deg, when
## the drop assumed the arms 5° low).
func test_capture_style_does_not_move_the_shoulders() -> void:
	var worst := 0.0
	for elev in [-12.0, -5.0, 0.0, 5.0, 8.0]:
		var h := player(1.6, [0.0, 0.0])
		h.set_arms(deg_to_rad(elev))
		var cal := perched()
		feed(cal, h, 2.2)
		check(cal.calibrated, "arms %+.0f° captured" % elev)
		worst = maxf(worst, absf(cal.shoulder_drop - h.shoulder_drop))
	lt(worst, 0.005, "shoulder drop within 5 mm for arms 12° low .. 8° high (worst %.4f m)" % worst)
	# Seated (eye height says nothing about stature): the span estimate.
	var s := VRHumanPose.for_span(1.8, true)
	s.set_arms(deg_to_rad(0.0))
	var sc := perched()
	sc.seated_setting = true
	feed(sc, s, 2.2)
	near(sc.shoulder_drop, s.shoulder_drop, 0.01, "seated: drop from the arm span")
	metric("capture_style_worst_drop_m", worst)


## One factor at a time (everything else textbook: 1.6 m, shoulders 0.23,
## ape 1, drop 0.15 H, eyes 0.935 H, no habit), so the evidence shows which
## assumption costs what. Capture styles must cost (almost) nothing now;
## body proportions the capture cannot observe are recorded.
func test_breakdown_one_factor_at_a_time() -> void:
	var base := {"span": 1.6, "sr": 0.23, "ape": 1.0, "dr": 0.15, "er": 0.935, "floor": 0.0, "style": [-5.0, 0.0, 0.0, 0.0, 0.0]}
	var cases := {
		"arms_12_low": {"style": [-12.0, 0.0, 0.0, 0.0, 0.0]}, "arms_level": {"style": [0.0, 0.0, 0.0, 0.0, 0.0]},
		"arms_5_high": {"style": [5.0, 0.0, 0.0, 0.0, 0.0]}, "arms_8_high": {"style": [8.0, 0.0, 0.0, 0.0, 0.0]},
		"hands_forward_10": {"style": [-5.0, 10.0, 0.0, 0.0, 0.0]}, "soft_elbows_15": {"style": [-5.0, 0.0, 15.0, 0.0, 0.0]},
		"looking_at_hand": {"style": [-5.0, 0.0, 0.0, 25.0, -15.0]},
		"shoulders_0.20": {"sr": 0.20}, "shoulders_0.26": {"sr": 0.26}, "ape_0.95": {"ape": 0.95}, "ape_1.05": {"ape": 1.05},
		"drop_0.14H": {"dr": 0.14}, "drop_0.16H": {"dr": 0.16}, "eyes_0.925H": {"er": 0.925}, "eyes_0.945H": {"er": 0.945},
		"floor_-3cm": {"floor": -0.03}, "floor_+3cm": {"floor": 0.03},
	}
	var ref_h := player(1.6, [0.0, 0.0])
	var ref := readings(calibrated_for(ref_h), ref_h)
	var rows := {}
	var style_worst := {"ext": 0.0, "pitch": 0.0}
	for name in cases:
		var f: Dictionary = base.duplicate()
		f.merge(cases[name], true)
		var stature: float = f["span"] / f["ape"] + 0.16
		var h := VRHumanPose.new()
		h.arm_span = f["span"]
		h.shoulder_width = f["sr"] * f["span"]
		h.shoulder_drop = f["dr"] * stature
		h.eye_height = f["er"] * stature
		h.room_offset = Vector3(0.0, f["floor"], 0.0)
		var st: Array = f["style"]
		h.set_arms(deg_to_rad(st[0]), deg_to_rad(st[1]), 0.0, deg_to_rad(st[2]))
		h.head_yaw = deg_to_rad(st[3])
		h.head_pitch = deg_to_rad(st[4])
		var cal := perched()
		feed(cal, h, 2.2)
		h.head_yaw = 0.0
		h.head_pitch = 0.0
		if not check(cal.calibrated, "%s captured" % name):
			continue
		var r := readings(cal, h)
		var we := 0.0
		var wp := 0.0
		for g in GESTURES:
			var a: Array = r[g]
			var b: Array = ref[g]
			we = maxf(we, maxf(absf(a[0] - b[0]), absf(a[1] - b[1])))
			if twist_comparable(a, b):
				wp = maxf(wp, absf(a[4] - b[4]))
		rows[name] = {"ext": snappedf(we, 0.001), "pitch": snappedf(wp, 0.001), "drop_err_m": snappedf(cal.shoulder_drop - h.shoulder_drop, 0.001)}
		print("[vr] breakdown %-17s drop err %+.3f m  worst ext %.3f  pitch %.3f" % [name, cal.shoulder_drop - h.shoulder_drop, we, wp])
		if (cases[name] as Dictionary).has("style"):
			style_worst["ext"] = maxf(style_worst["ext"], we)
			style_worst["pitch"] = maxf(style_worst["pitch"], wp)
	metric("breakdown", rows)
	lt(style_worst["ext"], 0.02, "capture style alone moves extension < 0.02 (was up to 0.43 with the 5°-low drop, 0.04 before the full-spread span)")
	lt(style_worst["pitch"], 0.08, "capture style alone moves the pitch command < 0.08 (was up to 0.28)")
	for name in ["arms_12_low", "arms_level", "arms_5_high", "arms_8_high", "looking_at_hand"]:
		lt(float(rows[name]["pitch"]), 0.005, "%s: arm height and gaze at capture leave pitch unchanged (canonical neutral)" % name)
		lt(absf(float(rows[name]["drop_err_m"])), 0.002, "%s: shoulder height unchanged (anthropometric drop)" % name)


## The instruction card: world-locked with a lazy follow (still for small
## glances, re-centres once the gaze is > 28° away), sized by world_scale
## without node scale, shows the flow's step and progress, hidden when idle.
func test_prompt_card_follows_lazily() -> void:
	var rig := make_rig()
	var node := make_node(rig, MemoryStore.new())
	node.show_prompt = true
	var h := player(1.7, [0.0, 0.0])
	h.set_arms(deg_to_rad(-60.0))
	node.start_manual()
	run(node, rig, h, 0.2)
	var card := node.prompt
	check(card != null and card.visible, "card shown while the flow runs")
	var head := (rig["camera"] as Node3D).transform
	var to_card := card.position - head.origin
	near(VRMath.horiz(to_card).length(), CalibrationPrompt.DISTANCE, 0.02, "1.25 m in front")
	near(rad_to_deg(VRMath.yaw_of(VRMath.horiz(to_card).normalized())), rad_to_deg(CalibrationPrompt.gaze_yaw(head.basis)), 1.0, "centred on the gaze")
	eq(card.step, CalibrationPrompt.Step.POSE, "the pose to hold is drawn")
	eq(card.text.text, VRCalibration.PROMPT, "the instruction, word for word")
	# A 20° glance: the card stays put.
	var yaw0 := card.yaw
	h.head_yaw = deg_to_rad(20.0)
	run(node, rig, h, 1.0)
	near(card.yaw, yaw0, 1e-6, "a 20° glance leaves the card where it is")
	# Looking 60° away: it glides back in front within ~1 s.
	h.head_yaw = deg_to_rad(60.0)
	run(node, rig, h, 0.05)
	check(card.following, "re-centring after a 60° look away")
	run(node, rig, h, 1.2)
	near(rad_to_deg(VRMath.wrap_angle(card.yaw - CalibrationPrompt.gaze_yaw((rig["camera"] as Node3D).transform.basis))), 0.0, 3.5, "back in front of the gaze")
	# Progress shows while the spread is held.
	h.head_yaw = 0.0
	h.spread_pose()
	run(node, rig, h, 1.1)
	gt(card.progress, 0.3, "the ring fills while the pose is held (%.2f)" % card.progress)
	# World scale: sized, never node-scaled.
	(rig["origin"] as XROrigin3D).world_scale = 0.2
	run(node, rig, h, 0.05)
	near((card.card.mesh as QuadMesh).size.x, card.width * 0.2, 1e-6, "card sized x world_scale")
	check(card.width >= CalibrationPrompt.SIZE.x, "(never narrower than its base size)")
	var b := card.transform.basis
	lt(maxf(absf(b.x.length() - 1.0), maxf(absf(b.y.length() - 1.0), absf(b.z.length() - 1.0))), 1e-5, "never node-scaled")
	(rig["origin"] as XROrigin3D).world_scale = 1.0
	node.cancel()
	run(node, rig, h, 0.05)
	check(card.visible and card.step == CalibrationPrompt.Step.FAILED, "cancelled: a short 'unchanged' card")
	run(node, rig, h, VRCalibration.CANCEL_SHOW)
	check(not card.visible, "hidden when idle (no draw calls)")
	node.queue_free()
	(rig["origin"] as Node).queue_free()
