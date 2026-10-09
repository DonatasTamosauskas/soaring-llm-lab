extends TestCase
## L2: WingInput, poses -> WingState (FLIGHT_SPEC §14.3 WI-01...WI-26).
## Synthetic, anatomically consistent poses from HumanPoseModel (arm span
## 1.50 m, eyes 1.62 m, seeded). Covers F1 (the wing angle sets the flap
## direction), F4 (opposite tilts and arm dihedral bank), look-never-steers
## and every scale-free / robustness property of the input chain.

const WR := preload("res://tests/unit/flight/wing_rig.gd")
const DEG := PI / 180.0


func _still(setup: Callable) -> Callable:
	return func(_tick: int, _t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		setup.call(b)


# --- WI-01: the model's neutral is the measured grip convention ---------------------
func test_wi01_model_neutral_matches_measured_axes() -> void:
	var b := HumanPoseModel.new()
	b.set_airplane()
	for side in 2:
		var sig := -1.0 if side == 0 else 1.0
		var hb := b.hand_basis(side)
		var a_local := hb.transposed() * Vector3(sig, 0, 0)
		var c := hb.transposed() * Vector3(0, 0, -1)
		c = (c - a_local * c.dot(a_local)).normalized()
		vnear(a_local, HumanPoseModel.A_LOCAL, 1e-3, "side %d forearm axis in grip frame" % side)
		vnear(c, HumanPoseModel.C_LOCAL, 1e-3, "side %d chord axis in grip frame" % side)
		var up := hb * (Vector3(sig, 0, 0))   # +X_grip right, -X_grip left
		vnear(up, Vector3.UP, 1e-3, "side %d palm normal points up (palms down)" % side)
	var r := WR.new(WR.airplane())
	r.run(0.5)
	lt(absf(r.ws.twist_l) + absf(r.ws.twist_r), 1e-3, "default neutral reads zero twist")


# --- WI-02 / WI-03: glide poses read fully spread and level --------------------------
func test_wi02_wi03_glide_poses() -> void:
	var r := WR.new(WR.airplane())
	# Lambdas capture locals by value: accumulate in a Dictionary.
	var acc := {"worst": 0.0}
	r.on_tick = func(_i: int, w: WingState, _rig: Variant) -> void:
		acc["worst"] = maxf(acc["worst"], maxf(w.flap_l, w.flap_r))
	r.run(2.0)
	between(r.ws.mean_extension(), 0.95, 1.0, "airplane glide extension")
	lt(absf(r.ws.pitch), 0.02, "airplane glide pitch")
	lt(absf(r.ws.roll), 0.02, "airplane glide roll")
	eq(acc["worst"], 0.0, "no flap while gliding")
	eq(r.tick, 144, "ran 2 s")
	for pose in [[-45.0, 40.0], [-60.0, 0.0]]:
		var rr := WR.new(_still(func(b: HumanPoseModel) -> void:
			for a in b.arms:
				a.dihedral = pose[0] * DEG
				a.elbow = pose[1] * DEG))
		rr.run(1.5)
		gt(rr.ws.mean_extension(), 0.95, "relaxed pose (%d deg, elbows %d) is full spread (fatigue design)" % [pose[0], pose[1]])


# --- WI-04 / PB-07: looking around never steers --------------------------------------
func test_wi04_head_look_changes_nothing() -> void:
	var ref := WR.new(WR.airplane())
	ref.run(1.5)
	var base := WR.snap(ref.ws)
	for look in [[80, 0, 0], [-80, 0, 0], [0, 60, 0], [0, -60, 0], [0, 0, 20], [0, 0, -20], [60, 40, 10]]:
		var r := WR.new(_still(func(b: HumanPoseModel) -> void:
			b.head_yaw = look[0] * DEG
			b.head_pitch = look[1] * DEG
			b.head_roll = look[2] * DEG))
		r.run(1.5)
		var d := WR.max_diff(base, WR.snap(r.ws))
		lt(d[0], 0.01, "head %s: every WingState field unchanged (worst %s)" % [str(look), d[1]])
		lt(absf(rad_to_deg(r.ws.body_yaw)), 1.0, "head %s: body yaw from the wings, not the gaze" % str(look))


# --- WI-05 / WI-06: whole-body yaw and room offset are invariant -------------------
func test_wi05_wi06_body_rotation_and_room_offset() -> void:
	var gesture := func(b: HumanPoseModel) -> void:
		b.arms[0].twist = 15.0 * DEG
		b.arms[1].twist = -5.0 * DEG
		b.arms[0].dihedral = 10.0 * DEG
		b.arms[1].dihedral = -12.0 * DEG
	var ref := WR.new(_still(gesture))
	ref.run(1.5)
	var base := WR.snap(ref.ws)
	for psi in [90.0, 180.0, -135.0]:
		var r := WR.new(_still(func(b: HumanPoseModel) -> void:
			gesture.call(b)
			b.torso_yaw = psi * DEG))
		r.run(1.5)
		var d := WR.max_diff(base, WR.snap(r.ws))
		lt(d[0], 0.01, "torso yaw %d: WingState identical (worst %s)" % [psi, d[1]])
		near(rad_to_deg(FlightMath.wrap_angle(r.ws.body_yaw - psi * DEG)), 0.0, 1.0, "torso yaw %d: body_yaw follows" % psi)
	var r2 := WR.new(_still(func(b: HumanPoseModel) -> void:
		gesture.call(b)
		b.room_offset = Vector3(1.2, 0, -0.8)))
	r2.run(1.5)
	var d2 := WR.max_diff(base, WR.snap(r2.ws))
	lt(d2[0], 1e-6, "room offset: identical (worst %s)" % d2[1])


# --- WI-07: world_scale never reaches WingInput -------------------------------------
func test_wi07_world_scale_invariance_through_xr_nodes() -> void:
	var origin := XROrigin3D.new()
	var cam := XRCamera3D.new()
	var lh := XRController3D.new()
	var rh := XRController3D.new()
	origin.add_child(cam)
	origin.add_child(lh)
	origin.add_child(rh)
	add_child(origin)
	var src := XRPoseSource.new(origin, cam, lh, rh)
	src.assume_tracked = true
	var outs := []
	var body := HumanPoseModel.new(3)
	for ws_val in [0.141, 1.235]:
		origin.world_scale = ws_val
		var wi := WingInput.new()
		wi.auto_calibrate = false
		var fr := PoseFrame.new()
		var truth := PoseFrame.new()
		for i in 108:
			body.set_airplane()
			ScriptedPoseSource.flap(body, i / 72.0, 40.0, 1.0)
			body.arms[0].twist = 12.0 * DEG
			body.frame(truth)
			cam.transform = Transform3D(truth.head.basis, truth.head.origin * ws_val)
			lh.transform = Transform3D(truth.left.basis, truth.left.origin * ws_val)
			rh.transform = Transform3D(truth.right.basis, truth.right.origin * ws_val)
			src.sample(fr, 1.0 / 72.0)
			wi.update(fr, 1.0 / 72.0)
		outs.append(WR.snap(wi.state))
	var d := WR.max_diff(outs[0], outs[1])
	lt(d[0], 1e-5, "WingState identical at world_scale 0.141 and 1.235 (worst %s)" % d[1])
	# A world_scale ramp while standing still never reads as a flap.
	var wi2 := WingInput.new()
	wi2.auto_calibrate = false
	var fr2 := PoseFrame.new()
	var truth2 := PoseFrame.new()
	var flap_max := 0.0
	body.set_airplane()
	for i in 144:
		var s := 0.16 + (0.44 - 0.16) * clampf((i - 36) / 72.0, 0.0, 1.0)
		origin.world_scale = s
		body.frame(truth2)
		cam.transform = Transform3D(truth2.head.basis, truth2.head.origin * s)
		lh.transform = Transform3D(truth2.left.basis, truth2.left.origin * s)
		rh.transform = Transform3D(truth2.right.basis, truth2.right.origin * s)
		src.sample(fr2, 1.0 / 72.0)
		wi2.update(fr2, 1.0 / 72.0)
		flap_max = maxf(flap_max, maxf(wi2.state.flap_l, wi2.state.flap_r))
	eq(flap_max, 0.0, "world_scale ramp 0.16 -> 0.44 while still: no flap")
	origin.world_scale = 1.0
	origin.queue_free()


# --- WI-08: wrist twist -> pitch and aileron (F4 opposite tilts) --------------------
func test_wi08_twist_reference_values() -> void:
	var cases := [[20, 20, 0.25, 0.37, "pitch"], [-20, -20, -0.55, -0.43, "pitch"], [20, -20, 0.62, 0.78, "roll"]]
	for c in cases:
		var r := WR.new(_still(func(b: HumanPoseModel) -> void:
			b.arms[0].twist = c[0] * DEG
			b.arms[1].twist = c[1] * DEG))
		r.run(1.5)
		if c[4] == "pitch":
			between(r.ws.pitch, c[2], c[3], "wrists %d/%d -> pitch" % [c[0], c[1]])
			lt(absf(r.ws.roll), 0.02, "wrists %d/%d -> no roll" % [c[0], c[1]])
		else:
			between(r.ws.roll, c[2], c[3], "L +20 / R -20 -> right bank (roll)")
			lt(absf(r.ws.pitch), 0.02, "opposite twists leak no pitch")
		metric("twist_%d_%d" % [c[0], c[1]], [r.ws.pitch, r.ws.roll])


# --- WI-09: swings never read as twist ---------------------------------------------
func test_wi09_swings_are_not_twist() -> void:
	var swings := [["dihedral", 40.0], ["dihedral", -40.0], ["dihedral", -60.0], ["sweep", 30.0], ["sweep", -30.0], ["elbow", 60.0]]
	for sw in swings:
		var r := WR.new(_still(func(b: HumanPoseModel) -> void:
			for a in b.arms:
				a.set(sw[0], sw[1] * DEG)))
		r.run(1.5)
		var u_l := FlightMath.shape(r.ws.twist_l, 5.0 * DEG, 40.0 * DEG, 30.0 * DEG, 1.4)
		var u_r := FlightMath.shape(r.ws.twist_r, 5.0 * DEG, 40.0 * DEG, 30.0 * DEG, 1.4)
		lt(maxf(absf(u_l), absf(u_r)), 0.05, "%s %d deg reads no twist (u)" % [sw[0], sw[1]])
		lt(maxf(absf(r.ws.twist_l), absf(r.ws.twist_r)), 1.0 * DEG, "%s %d deg: raw twist < 1 deg" % [sw[0], sw[1]])


# --- WI-10: arm dihedral banks (F4) --------------------------------------------------
func test_wi10_arm_dihedral_banks() -> void:
	var r := WR.new(_still(func(b: HumanPoseModel) -> void:
		b.arms[1].dihedral = -30.0 * DEG))
	r.run(1.5)
	between(r.ws.roll, 0.3, 0.5, "right hand 30 deg lower -> right bank")
	var ref := WR.new(WR.airplane())
	ref.run(1.5)
	near(r.ws.pitch, ref.ws.pitch, 0.02, "arm tilt leaves pitch unchanged")
	var r2 := WR.new(_still(func(b: HumanPoseModel) -> void:
		b.arms[0].dihedral = -15.0 * DEG
		b.arms[1].dihedral = 15.0 * DEG))
	r2.run(1.5)
	lt(r2.ws.roll, -0.3, "left hand lower -> left bank")


# --- WI-11: grip-convention robustness after recalibration -------------------------
func _gesture_library() -> Array:
	return [
		func(b: HumanPoseModel) -> void: pass,
		func(b: HumanPoseModel) -> void:
			b.arms[0].twist = 20.0 * DEG
			b.arms[1].twist = 20.0 * DEG,
		func(b: HumanPoseModel) -> void:
			b.arms[0].twist = -20.0 * DEG
			b.arms[1].twist = -20.0 * DEG,
		func(b: HumanPoseModel) -> void:
			b.arms[0].twist = 20.0 * DEG
			b.arms[1].twist = -20.0 * DEG,
		func(b: HumanPoseModel) -> void:
			b.arms[1].dihedral = -30.0 * DEG,
		func(b: HumanPoseModel) -> void:
			for a in b.arms:
				a.dihedral = 40.0 * DEG,
	]


## Calibrate on a natural spread (arms 5 deg low), then run each gesture.
func _library_readings(offsets: Array) -> Array:
	var out := []
	var cal := WingCalibration.new()
	var body := HumanPoseModel.new(11)
	body.grip_offset = [offsets[0], offsets[1]]
	var rc := WR.new(func(_tick: int, _t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		for a in b.arms:
			a.dihedral = -5.0 * DEG, true, body, cal)
	rc.run(2.0)
	check(cal.calibrated, "calibration captured")
	for g in _gesture_library():
		var r := WR.new(func(_tick: int, _t: float, b: HumanPoseModel) -> void:
			b.set_airplane()
			g.call(b), false, body, cal)
		r.run(1.5)
		out.append([r.ws.pitch, r.ws.roll, r.ws.mean_extension()])
	return out


func test_wi11_grip_convention_robustness() -> void:
	var ref := _library_readings([Basis(), Basis()])
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	for k in 3:
		var offs := []
		for side in 2:
			var axis := Vector3(rng.randf_range(-1, 1), rng.randf_range(-1, 1), rng.randf_range(-1, 1)).normalized()
			offs.append(Basis(axis, deg_to_rad(rng.randf_range(10.0, 40.0))))
		var got := _library_readings(offs)
		var worst := 0.0
		for i in ref.size():
			for j in 3:
				worst = maxf(worst, absf(float(got[i][j]) - float(ref[i][j])))
		lt(worst, 0.02, "random grip rotation set %d: gesture library within 0.02" % k)
		metric("grip_offset_%d_worst" % k, worst)


# --- WI-12 lives in flap_detector_test; WI-16..19: body motion, loss, tuck --------
func test_wi16_crouch_jump_walk_are_not_flaps() -> void:
	var cases := {
		"crouch": func(_tick: int, t: float, b: HumanPoseModel) -> void:
			b.set_airplane()
			b.crouch = 0.4 * clampf((t - 0.5) / 0.3, 0.0, 1.0),
		"jump": func(_tick: int, t: float, b: HumanPoseModel) -> void:
			b.set_airplane()
			var tt := t - 0.5
			b.crouch = -maxf(0.0, 2.4 * tt - 4.9 * tt * tt) if tt > 0.0 else 0.0,
		"walk": func(_tick: int, t: float, b: HumanPoseModel) -> void:
			b.set_airplane()
			b.room_offset = Vector3(0, 0.02 * sin(TAU * 1.8 * t), -1.0 * t),
	}
	for k in cases:
		var r := WR.new(cases[k])
		var acc := {"worst": 0.0, "n": 0}
		r.on_tick = func(_i: int, w: WingState, _rig: Variant) -> void:
			acc["worst"] = maxf(acc["worst"], maxf(w.flap_l, w.flap_r))
			acc["n"] += 1
		r.run(2.0)
		eq(acc["worst"], 0.0, "%s: flap stays 0" % k)
		eq(acc["n"], 144, "%s: observed every tick" % k)


func test_wi17_one_wing_flap_rolls_by_force_not_dihedral() -> void:
	var r := WR.new(func(_tick: int, t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		ScriptedPoseSource.flap(b, t, 45.0, 1.0, 1))
	var acc := {"fl": 0.0, "fr": 0.0, "roll_max": 0.0}
	r.on_tick = func(i: int, w: WingState, _rig: Variant) -> void:
		acc["fl"] = maxf(acc["fl"], w.flap_l)
		acc["fr"] = maxf(acc["fr"], w.flap_r)
		if i >= 216:
			acc["roll_max"] = maxf(acc["roll_max"], absf(w.roll))
	r.run(6.0)
	gt(acc["fr"], 0.5, "right-only strokes: right flap")
	eq(acc["fl"], 0.0, "right-only strokes: left flap stays 0")
	lt(acc["roll_max"], 0.1, "cycle-mean dihedral cancels the +-45 deg stroke swing (|roll| every tick after 3 s)")
	metric("one_wing_roll_max", acc["roll_max"])


func test_wi18_tracking_loss() -> void:
	var gesture := func(b: HumanPoseModel) -> void:
		b.arms[0].twist = 10.0 * DEG
		b.arms[1].dihedral = -20.0 * DEG
	# Right hand lost 0.2 s: unchanged.
	var r := WR.new(func(_tick: int, t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		gesture.call(b)
		b.right_valid = not (t >= 1.5 and t < 1.7))
	r.run(1.49)
	var before := WR.snap(r.ws)
	var acc := {"worst": 0.0, "n": 0}
	r.on_tick = func(_i: int, w: WingState, _rig: Variant) -> void:
		acc["worst"] = maxf(acc["worst"], WR.max_diff(before, WR.snap(w))[0])
		acc["n"] += 1
	r.run(0.5)
	lt(acc["worst"], 0.02, "right hand lost 0.2 s: WingState held")
	eq(acc["n"], 36, "observed the loss window")
	# Right hand lost 2 s: mirrored within 0.6 s.
	var r2 := WR.new(func(_tick: int, t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		b.arms[0].dihedral = 10.0 * DEG
		b.arms[0].twist = 12.0 * DEG
		b.arms[1].dihedral = -25.0 * DEG
		b.right_valid = not (t >= 1.5 and t < 3.5))
	r2.run(1.5 + 0.9)
	near(r2.ws.twist_r, r2.ws.twist_l, 0.5 * DEG, "lost wing mirrors the other's twist within 0.9 s")
	near(r2.ws.dihedral_r, r2.ws.dihedral_l, 0.5 * DEG, "lost wing mirrors the other's dihedral")
	lt(absf(r2.ws.roll), 0.05, "mirrored wings: no roll")
	var acc2 := {"max_droll": 0.0, "prev": r2.ws.roll, "n": 0}
	r2.on_tick = func(_i: int, w: WingState, _rig: Variant) -> void:
		acc2["max_droll"] = maxf(acc2["max_droll"], absf(w.roll - acc2["prev"]))
		acc2["prev"] = w.roll
		acc2["n"] += 1
	r2.run(2.0)
	lt(acc2["max_droll"], 0.1, "reacquire: no jump (roll change per tick)")
	gt(acc2["n"], 100, "observed the reacquire")
	# Both lost: neutral glide within 1 s, tracking = 0.
	var r3 := WR.new(func(_tick: int, t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		b.arms[0].twist = 25.0 * DEG
		b.arms[1].twist = 25.0 * DEG
		b.left_valid = t < 1.5
		b.right_valid = t < 1.5)
	r3.run(1.5)
	gt(r3.ws.pitch, 0.3, "pitched up before the loss")
	r3.run(1.1)
	lt(absf(r3.ws.pitch), 0.01, "both hands lost: neutral pitch within 1.1 s")
	lt(r3.ws.tracking, 0.01, "both hands lost: tracking = 0")


func test_wi19_crossed_arms_and_tuck() -> void:
	# Crossed arms: the hand line flips 180 deg; the jump gate holds the yaw.
	var r := WR.new(func(_tick: int, t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		if t > 1.0:
			for a in b.arms:
				a.elbow = 150.0 * DEG
				a.sweep = 20.0 * DEG)
	r.run(1.0)
	var y0 := r.ws.body_yaw
	var acc := {"worst": 0.0, "n": 0}
	r.on_tick = func(_i: int, w: WingState, _rig: Variant) -> void:
		acc["worst"] = maxf(acc["worst"], absf(FlightMath.wrap_angle(w.body_yaw - y0)))
		acc["n"] += 1
	r.run(2.0)
	lt(rad_to_deg(acc["worst"]), 10.0, "hands crossed at the chest: body yaw holds (deg)")
	eq(acc["n"], 144, "observed")
	# Hands at the chest from the start (novice floor) vs after a spread.
	var r2 := WR.new(func(_tick: int, _t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		for a in b.arms:
			a.elbow = 150.0 * DEG)
	r2.run(1.0)
	gt(r2.ws.mean_extension(), 0.85 - 1e-6, "before ever spreading: extension floor 0.85 (no accidental dive)")
	check(not r2.ws.tucked, "before ever spreading: not tucked")
	var r3 := WR.new(func(_tick: int, t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		if t > 1.0:
			for a in b.arms:
				a.elbow = 150.0 * DEG)
	r3.run(2.0)
	lt(r3.ws.mean_extension(), 0.05, "after a spread: hands at the chest fold the wings")
	check(r3.ws.tucked, "after a spread: tucked")


# --- WI-20 / WI-21: latency and physical turns --------------------------------------
func _time_to(r: WR, cond: Callable, max_s: float) -> float:
	var t0 := r.tick
	while (r.tick - t0) * WR.DT < max_s:
		r.step()
		if cond.call(r.ws):
			return (r.tick - t0) * WR.DT
	return INF


func test_wi20_latency_budget() -> void:
	# Twist step 0 -> 20 deg: 90% within 90 ms.
	var r := WR.new(func(tick: int, _t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		b.arms[0].twist = 20.0 * DEG if tick >= 72 else 0.0)
	r.run(1.0)
	var t_tw := _time_to(r, func(w: WingState) -> bool: return w.twist_l >= 0.9 * 20.0 * DEG, 0.5)
	lt(t_tw, 0.090 + 1e-6, "twist step 90%% latency (s)")
	metric("twist_latency_ms", t_tw * 1000.0)
	# Dihedral step: 90% within 120 ms.
	var r2 := WR.new(func(tick: int, _t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		b.arms[1].dihedral = -30.0 * DEG if tick >= 72 else 0.0)
	r2.run(1.0)
	var t_dh := _time_to(r2, func(w: WingState) -> bool: return w.dihedral_r <= -0.9 * 30.0 * DEG, 0.5)
	lt(t_dh, 0.120 + 1e-6, "dihedral step 90%% latency (s)")
	metric("dihedral_latency_ms", t_dh * 1000.0)
	# Extension tuck -> spread: 90% within 150 ms of the pose arriving. The
	# elbow straightens over 4 ticks (56 ms, ~9 m/s at the hand, faster than
	# any arm): a one-tick 0.5 m teleport of the hands is a tracker glitch
	# and is rejected since WI-30.
	var r3 := WR.new(func(tick: int, _t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		var fold := clampf(float(tick - 72) / 4.0, 0.0, 1.0) * (1.0 - clampf(float(tick - 140) / 4.0, 0.0, 1.0))
		for a in b.arms:
			a.elbow = 150.0 * DEG * fold)
	r3.run(2.0)
	var t_ex := _time_to(r3, func(w: WingState) -> bool: return w.mean_extension() >= 0.9, 0.5)
	lt(t_ex, 0.150 + 1e-6, "extension tuck->spread 90%% latency (s)")
	metric("extension_latency_ms", t_ex * 1000.0)
	# Nod +-30 deg: the shoulders move <= 2 cm.
	var r4 := WR.new(func(_tick: int, t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		b.head_pitch = 30.0 * DEG * sin(TAU * 1.0 * t))
	r4.run(0.5)
	var s0 := r4.wi.shoulders[1]
	var acc := {"smax": 0.0, "n": 0}
	r4.on_tick = func(_i: int, _w: WingState, rig: Variant) -> void:
		acc["smax"] = maxf(acc["smax"], (rig.wi.shoulders[1] - s0).length())
		acc["n"] += 1
	r4.run(2.0)
	lt(acc["smax"], 0.02, "a +-30 deg nod moves the estimated shoulders (m)")
	eq(acc["n"], 144, "observed")
	metric("nod_shoulder_m", acc["smax"])


func test_wi21_physical_turn_tracking() -> void:
	# 180 deg turn in 2 s with the arms spread: lag <= 8 deg.
	var r := WR.new(func(_tick: int, t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		b.torso_yaw = PI * clampf((t - 0.5) / 2.0, 0.0, 1.0))
	var acc := {"lag": 0.0, "n": 0}
	r.on_tick = func(_i: int, w: WingState, rig: Variant) -> void:
		acc["lag"] = maxf(acc["lag"], absf(FlightMath.wrap_angle(w.body_yaw - rig.body.torso_yaw)))
		acc["n"] += 1
	r.run(3.0)
	lt(rad_to_deg(acc["lag"]), 8.0, "spread 180 deg turn: body yaw lag (deg)")
	eq(acc["n"], 216, "observed")
	metric("turn_lag_deg", rad_to_deg(acc["lag"]))
	# The same while tucked, then spread: converges within 0.5 s, no flip.
	var r2 := WR.new(func(_tick: int, t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		b.torso_yaw = PI * clampf((t - 1.0) / 2.0, 0.0, 1.0)
		if t > 0.8 and t < 3.5:
			for a in b.arms:
				a.elbow = 150.0 * DEG)
	r2.run(3.5)
	var t_conv := _time_to(r2, func(w: WingState) -> bool: return absf(FlightMath.wrap_angle(w.body_yaw - PI)) < 5.0 * DEG, 1.0)
	lt(t_conv, 0.5 + 1e-6, "tucked turn then spread: converges (s)")
	metric("tucked_turn_converge_s", t_conv)


# --- WI-22: calibration across bodies ------------------------------------------------
func test_wi22_calibration_across_bodies() -> void:
	for span in [1.30, 1.50, 1.90]:
		for seated in [false, true]:
			for off_deg in [-25.0, 0.0, 25.0]:
				var body := HumanPoseModel.new(5)
				body.set_body(span, 1.20 if seated else 1.62)
				# The player's "flat" wrist: a neutral twist offset held throughout.
				var cal := WingCalibration.new()
				var rc := WR.new(func(_tick: int, _t: float, b: HumanPoseModel) -> void:
					b.set_airplane()
					for a in b.arms:
						a.dihedral = -5.0 * DEG
						a.twist = off_deg * DEG, true, body, cal)
				rc.run(2.0)
				var tag := "span %.2f %s offset %d" % [span, "seated" if seated else "standing", off_deg]
				check(cal.calibrated, "%s: captured" % tag)
				near(cal.arm_span, span, 0.01, "%s: arm span" % tag)
				# WI-02 airplane glide with the offset as the new flat.
				var r := WR.new(func(_tick: int, _t: float, b: HumanPoseModel) -> void:
					b.set_airplane()
					for a in b.arms:
						a.twist = off_deg * DEG, false, body, cal)
				r.run(1.5)
				lt(absf(r.ws.pitch), 0.02, "%s: flat reads level" % tag)
				lt(absf(r.ws.roll), 0.02, "%s: flat reads no roll" % tag)
				gt(r.ws.mean_extension(), 0.95, "%s: spread" % tag)
				# WI-08 both +20 from the new neutral.
				var r2 := WR.new(func(_tick: int, _t: float, b: HumanPoseModel) -> void:
					b.set_airplane()
					for a in b.arms:
						a.twist = (off_deg + 20.0) * DEG, false, body, cal)
				r2.run(1.5)
				between(r2.ws.pitch, 0.25, 0.37, "%s: +20 deg twist -> pitch" % tag)
				# WI-09 arm raise reads no twist.
				var r3 := WR.new(func(_tick: int, _t: float, b: HumanPoseModel) -> void:
					b.set_airplane()
					for a in b.arms:
						a.twist = off_deg * DEG
						a.dihedral = 40.0 * DEG, false, body, cal)
				r3.run(1.5)
				lt(absf(r3.ws.pitch), 0.05, "%s: 40 deg arm raise leaks no pitch" % tag)


# --- WI-23 / WI-24: auto-trim and soar lock ------------------------------------------
func test_wi23_auto_trim() -> void:
	var r := WR.new(_still(func(b: HumanPoseModel) -> void:
		b.arms[0].twist = 5.0 * DEG
		b.arms[1].twist = 5.0 * DEG))
	r.run(1.0)
	var t0 := r.ws.twist_l
	r.run(120.0)
	lt(r.ws.twist_l / t0, 0.2, "a 5 deg drift held 120 s is >= 80% absorbed")
	var r2 := WR.new(_still(func(b: HumanPoseModel) -> void:
		b.arms[0].twist = 20.0 * DEG
		b.arms[1].twist = 20.0 * DEG))
	r2.run(1.0)
	var t1 := r2.ws.twist_l
	r2.run(60.0)
	near(r2.ws.twist_l, t1, 0.2 * DEG, "a deliberate 20 deg input is untouched")


func test_wi24_soar_lock() -> void:
	var r := WR.new(func(_tick: int, t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		if t > 1.0:
			b.grip = Vector2(1, 1)
		if t > 1.5:
			for a in b.arms:
				a.dihedral = -85.0 * DEG
				a.twist = 20.0 * DEG)
	r.run(3.0)
	check(r.ws.soar_lock, "both grips with spread wings: soar lock on")
	gt(r.ws.mean_extension(), 0.95, "arms dropped to -85 deg: wings stay spread")
	gt(r.ws.pitch, 0.25, "twist still reads under soar lock (pitch)")
	var r2 := WR.new(func(_tick: int, t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		if t > 1.5:
			for a in b.arms:
				a.dihedral = -85.0 * DEG)
	r2.run(3.0)
	lt(r2.ws.mean_extension(), 0.1, "without the lock, arms at the sides fold the wings")


# --- WI-25: determinism ----------------------------------------------------------------
func test_wi25_determinism() -> void:
	var hashes := []
	for k in 3:
		var body := HumanPoseModel.new(99)
		body.tremor_mm = 1.5
		body.twist_noise_deg = 1.5
		var r := WR.new(func(_tick: int, t: float, b: HumanPoseModel) -> void:
			b.set_airplane()
			ScriptedPoseSource.flap(b, t, 40.0, 1.1)
			b.arms[0].twist = 10.0 * DEG * sin(t)
			b.torso_yaw = 0.3 * sin(0.5 * t), false, body)
		r.run(5.0)
		hashes.append(hash(WR.snap(r.ws)))
	check(hashes[0] == hashes[1] and hashes[1] == hashes[2], "identical state hash over 3 runs")


# --- WI-26: round trip commands -> arms -> WingInput ----------------------------------
func test_wi26_round_trip() -> void:
	var cal := WingCalibration.new()
	var worst := Vector3.ZERO
	var worst_dir := 0.0
	for p in [-1.0, -0.5, 0.0, 0.5, 1.0]:
		for rl in [-1.0, -0.5, 0.0, 0.5, 1.0]:
			for sp in [0.0, 0.5, 1.0]:
				var r := WR.new(func(tick: int, _t: float, b: HumanPoseModel) -> void:
					b.set_airplane()
					if tick >= 36:
						b.synth(p, rl, sp, cal))
				r.run(1.6)
				var want := WingState.new()
				want.set_commands(p, rl, sp, 0.0, 0.0)
				worst.x = maxf(worst.x, absf(r.ws.pitch - p))
				worst.y = maxf(worst.y, absf(r.ws.roll - rl))
				worst.z = maxf(worst.z, absf(r.ws.mean_extension() - sp))
				if rl == 0.0 and sp == 1.0:
					var d := 0.5 * (r.ws.flap_dir_l + r.ws.flap_dir_r)
					worst_dir = maxf(worst_dir, absf(rad_to_deg(atan2(-d.z, d.y)) - WingState.tilt_for_pitch(p)))
	lt(worst.x, 0.03, "round trip pitch error")
	lt(worst.y, 0.03, "round trip roll error")
	lt(worst.z, 0.03, "round trip spread error")
	lt(worst_dir, 2.0, "round trip flap tilt error (deg)")
	metric("round_trip_worst", [worst.x, worst.y, worst.z, worst_dir])
	# Mirror symmetry: a mirrored pose gives -roll and swaps L/R exactly.
	var a := WR.new(_still(func(b: HumanPoseModel) -> void:
		b.arms[0].twist = 18.0 * DEG
		b.arms[1].twist = -7.0 * DEG
		b.arms[0].dihedral = 12.0 * DEG))
	var m := WR.new(_still(func(b: HumanPoseModel) -> void:
		b.arms[1].twist = 18.0 * DEG
		b.arms[0].twist = -7.0 * DEG
		b.arms[1].dihedral = 12.0 * DEG))
	a.run(1.5)
	m.run(1.5)
	near(a.ws.roll, -m.ws.roll, 1e-4, "mirrored pose: roll negates")
	near(a.ws.pitch, m.ws.pitch, 1e-4, "mirrored pose: same pitch")
	near(a.ws.twist_l, m.ws.twist_r, 1e-4, "mirrored pose: twists swap")


# --- WI-28: symmetric strokes after a bank gesture never roll ------------------
## Found by the WingInput channel plot: flapping 0-1.5 s after a bank gesture
## rolled the bird by up to 0.36 for three beats. Each wing's cycle-mean
## window came from its own detector's period estimate, which the bank
## gesture had seeded differently, so a symmetric beat averaged to a phantom
## dihedral difference. Both wings now share one window, and a stroking
## episode never averages the ring's pre-stroke history.
func test_wi28_no_phantom_roll_after_bank() -> void:
	for pause in [0.0, 0.5, 1.5]:
		var acc := {"worst": 0.0}
		var r := WR.new(func(_tick: int, t: float, b: HumanPoseModel) -> void:
			b.set_airplane()
			if t >= 1.0 and t < 3.0:
				b.arms[0].twist = 20.0 * DEG
				b.arms[1].twist = -20.0 * DEG
				b.arms[0].dihedral = 15.0 * DEG
				b.arms[1].dihedral = -15.0 * DEG
			elif t >= 3.0 + pause:
				ScriptedPoseSource.flap(b, t - 3.0 - pause, 45.0, 1.0)
			b.humanize(WR.DT))
		r.on_tick = func(tick: int, w: WingState, _rig: Variant) -> void:
			# From 0.3 s after the bank is released (the release itself is a
			# real, decaying roll input).
			if (tick + 1) * WR.DT > 3.3 + pause:
				acc["worst"] = maxf(acc["worst"], absf(w.roll))
		r.run(8.0 + pause)
		# Straight from the bank into strokes the first beat still carries
		# the release (the arms were moving); with any pause, nothing.
		var lim := 0.2 if pause == 0.0 else 0.03
		lt(acc["worst"], lim, "pause %.1f s: worst |roll| during symmetric strokes" % pause)
		metric("pause_%.1f_worst_roll" % pause, acc["worst"])


# --- WI-29: record and replay are tick-aligned (FLIGHT_SPEC R5) -------------------
## A scripted session (glide, bank, flaps, tuck, a lost hand) recorded with
## PoseRecorder and replayed with ReplayPoseSource into a fresh WingInput
## gives the same commands on the same ticks (round 1 replayed one tick
## ahead and dropped the first frame).
func test_wi29_record_replay_round_trip() -> void:
	var path := Paths.artifacts("flight").path_join("wi29_replay.jsonl")
	var drive := func(_tick: int, t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		var cal := WingCalibration.new()
		if t < 2.0:
			pass
		elif t < 4.0:
			b.synth(0.0, 0.7, 1.0, cal)
		elif t < 8.0:
			ScriptedPoseSource.flap(b, t, 45.0, 1.0)
			for a in b.arms:
				a.twist = -10.0 * DEG
		elif t < 9.5:
			b.synth(-1.0, 0.0, 0.0, cal)
		else:
			b.right_valid = t > 10.5
		b.humanize(WR.DT)
	var r := WR.new(drive, false, HumanPoseModel.new(9))
	var rec := PoseRecorder.new()
	check(rec.start(path), "recorder opens its file")
	var live: Array = []
	var acc := {"onsets": 0}
	r.on_tick = func(_i: int, w: WingState, rig: Variant) -> void:
		rec.record(rig.frame, WR.DT)
		live.append(WR.snap(w))
		acc["onsets"] += (1 if w.onset_l else 0) + (1 if w.onset_r else 0)
	r.run(12.0)
	rec.stop()
	var onsets_live: int = acc["onsets"]
	var rp := ReplayPoseSource.new(path)
	eq(rp.samples.size(), live.size(), "one recorded line per tick")
	var wi2 := WingInput.new()
	wi2.auto_calibrate = false
	var fr := PoseFrame.new()
	var worst := 0.0
	var worst_key := ""
	var onsets_rep := 0
	for i in live.size():
		rp.sample(fr, WR.DT)
		if i == 0:
			near(fr.t, 0.0, 1e-9, "the first replayed tick is the first recorded frame")
		var w2 := wi2.update(fr, WR.DT)
		onsets_rep += (1 if w2.onset_l else 0) + (1 if w2.onset_r else 0)
		var d := WR.max_diff(live[i], WR.snap(w2))
		if d[0] > worst:
			worst = d[0]
			worst_key = d[1]
	lt(worst, 0.01, "replayed commands match the live ones on the same tick (worst %s)" % worst_key)
	eq(onsets_rep, onsets_live, "replay reproduces every flap onset")
	gt(onsets_live, 4, "the session flapped")
	metric("worst_aligned_diff", worst)


# --- WI-30: pose sanity (§3.1 glitch rejection) ------------------------------------
## A tracker that glitches while still flagged valid (NaN or inf origin, a
## NaN, zero or squashed basis, a teleport of 0.6 m or 25 m) is rejected;
## a hand is bridged with its own motion, the head is held. Mid-downstroke:
## - WingState finite on every tick (round 1: a NaN head or hand left
##   pitch, roll and body_yaw NaN for good when the check was removed);
## - a one-tick glitch: commands within 0.12 of a clean run of the same
##   gestures;
## - a 70 ms burst: within 0.3 (the bridge cannot see the stroke speed up),
##   no stroke lost or invented (same onsets), and back on the clean run
##   within 0.5 s.
func test_wi30_glitching_trackers_are_rejected_and_held() -> void:
	var drive := func(_tick: int, t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		ScriptedPoseSource.flap(b, t, 35.0, 1.0)
		b.arms[0].twist = 10.0 * DEG * sin(0.7 * t)
		b.arms[1].twist = -8.0 * DEG
		b.torso_yaw = 0.3 * sin(0.4 * t)
		b.humanize(WR.DT)
	var kinds := ["nan_origin", "inf_origin", "nan_basis", "zero_basis", "squashed_basis", "jump_0.6m", "jump_25m"]
	# Default: the head and one hand (the right mirrors the left; the 60 s
	# budget, fix round 4); --full adds the right hand.
	for tracker in (["head", "left", "right"] if Paths.arg("full", "") != "" else ["head", "left"]):
		for kind in kinds:
			for burst in [1, 5]:
				var a := WR.new(drive, false, HumanPoseModel.new(3))
				var b := WR.new(drive, false, HumanPoseModel.new(3))
				a.run(2.0)
				b.run(2.0)
				var worst := 0.0
				var wkey := ""
				var late := 0.0
				var finite := true
				var on_a := 0
				var on_b := 0
				for i in 108:
					a.src.sample(a.frame, WR.DT)
					b.src.sample(b.frame, WR.DT)
					if i >= 10 and i < 10 + burst:
						_corrupt(b.frame, tracker, kind)
					var wa := a.wi.update(a.frame, WR.DT)
					var wb := b.wi.update(b.frame, WR.DT)
					on_a += (1 if wa.onset_l else 0) + (1 if wa.onset_r else 0)
					on_b += (1 if wb.onset_l else 0) + (1 if wb.onset_r else 0)
					var sb := WR.snap(wb)
					for k in sb:
						if not is_finite(float(sb[k])):
							finite = false
					finite = finite and is_finite(wb.body_yaw)
					var md := WR.max_diff(WR.snap(wa), sb)
					if md[0] > worst:
						worst = md[0]
						wkey = "%s@%d" % [md[1], i]
					if i >= 10 + burst + 36:
						late = maxf(late, md[0])
				var tag := "%s %s x%d" % [tracker, kind, burst]
				check(finite, "%s: WingState finite on every tick" % tag)
				var lim := 0.12 if burst == 1 else 0.3
				lt(worst, lim, "%s: commands within %.2f of a clean run (worst %s)" % [tag, lim, wkey])
				eq(on_b, on_a, "%s: same flap onsets as the clean run (no stroke lost or invented)" % tag)
				lt(late, 0.02, "%s: back on the clean run 0.5 s after the glitch" % tag)
				metric(tag, [worst, late])


static func _corrupt(f: PoseFrame, tracker: String, kind: String) -> void:
	var tr: Transform3D = f.head if tracker == "head" else (f.left if tracker == "left" else f.right)
	match kind:
		"nan_origin":
			tr.origin = Vector3(NAN, tr.origin.y, tr.origin.z)
		"inf_origin":
			tr.origin = Vector3(tr.origin.x, INF, tr.origin.z)
		"nan_basis":
			tr.basis = Basis(Vector3(NAN, 0, 0), Vector3.UP, Vector3.BACK)
		"zero_basis":
			tr.basis = Basis(Vector3.ZERO, Vector3.ZERO, Vector3.ZERO)
		"squashed_basis":
			tr.basis = tr.basis.scaled(Vector3(0.1, 0.1, 0.1))
		"jump_0.6m":
			tr.origin += Vector3(0.6, 0.0, 0.0)
		"jump_25m":
			tr.origin += Vector3(0.0, 0.0, 25.0)
	if tracker == "head":
		f.head = tr
	elif tracker == "left":
		f.left = tr
	else:
		f.right = tr


# --- WI-31: a neutral replaced from outside (VR's request, ARCHITECTURE) ----------
## VR writes a new neutral into the shared WingCalibration and calls
## calibration_replaced(): nothing learnt against the old neutral survives,
## so flat wrists read flat at once (not ~6 deg of stale auto-trim for a
## minute).
func test_wi31_calibration_replaced_clears_old_neutral_state() -> void:
	var r := WR.new(func(_tick: int, _t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		b.arms[0].twist = 8.0 * DEG
		b.arms[1].twist = -7.0 * DEG)
	# A long calm glide with a small constant twist: the auto-trim learns it.
	r.run(40.0)
	gt(absf(r.wi._trim[0]) + absf(r.wi._trim[1]), 4.0 * DEG, "auto-trim learnt the old neutral's offset")
	# VR captures the current pose as the new neutral and tells WingInput.
	var cal := r.wi.calibration
	var b := r.body
	var bb := Basis(Vector3.UP, r.wi.state.body_yaw)
	cal.neutral_left = bb.transposed() * b.hand_basis(0)
	cal.neutral_right = bb.transposed() * b.hand_basis(1)
	r.wi.calibration_replaced()
	eq(r.wi._trim[0], 0.0, "left trim cleared")
	eq(r.wi._trim[1], 0.0, "right trim cleared")
	r.run(0.2)
	lt(absf(rad_to_deg(r.ws.twist_l)), 0.5, "left wrist reads flat 0.2 s after the new neutral (deg)")
	lt(absf(rad_to_deg(r.ws.twist_r)), 0.5, "right wrist reads flat 0.2 s after the new neutral (deg)")
	lt(absf(r.ws.pitch) + absf(r.ws.roll), 0.02, "no pitch or roll from the old neutral")


# --- WI-32: no span refinement while another owner calibrates (fix round 4) ---
## VR's request (round 4): while the VR area's calibration runs (PlayerBird
## auto_calibrate false), a controller put down on a table must not inflate
## flight's arm span between VR's corrections.
func test_wi32_span_refinement_off_while_another_owner_calibrates() -> void:
	for refine in [true, false]:
		var r := WR.new(func(_tick: int, t: float, b: HumanPoseModel) -> void:
			b.set_airplane()
			# The right controller put down 0.4 m further out after 1 s.
			b.hand_offset[1] = Vector3(0.4, 0.0, 0.0) if t > 1.0 else Vector3.ZERO)
		r.wi.calibration.calibrated = true
		r.wi.auto_calibrate = false
		r.wi.refine_span = refine
		var span0 := r.wi.calibration.arm_span
		r.run(3.0)
		if refine:
			gt(r.wi.calibration.arm_span, span0 + 0.3, "refining (flight owns the calibration): the span grows to the reach (m)")
		else:
			eq(r.wi.calibration.arm_span, span0, "another owner calibrates: the span is left alone")


# --- WI-33: every form of a saved calibration is validated (fix round 4) -------
## VR's request (round 4): from_dict took a native Basis without the finite /
## determinant check its flat-array path had.
func test_wi33_from_dict_rejects_corrupt_values_in_every_form() -> void:
	var c := WingCalibration.new()
	var n0 := c.neutral_left
	var a0 := c.forearm_axis_left
	var span0 := c.arm_span
	c.from_dict({"neutral_left": Basis(Vector3(NAN, 0, 0), Vector3.UP, Vector3.BACK), "neutral_right": Basis(Vector3.ZERO, Vector3.ZERO, Vector3.BACK),
		"forearm_axis_left": Vector3(INF, 0, 0), "chord_axis_left": Vector3.ZERO, "arm_span": NAN})
	check(c.neutral_left.is_equal_approx(n0), "a non-finite native Basis is ignored")
	check(FlightMath.bfinite(c.neutral_right) and absf(c.neutral_right.determinant()) > 0.5, "a singular native Basis is ignored")
	check(c.forearm_axis_left.is_equal_approx(a0), "a non-finite native axis is ignored")
	check(FlightMath.vfinite(c.chord_axis_left) and c.chord_axis_left.length() > 0.9, "a zero native axis is ignored")
	eq(c.arm_span, span0, "a non-finite span is ignored")
	var good := Basis(Vector3.UP, 0.3)
	c.from_dict({"neutral_left": good, "arm_span": 1.8})
	check(c.neutral_left.is_equal_approx(good), "a sane native Basis is taken")
	near(c.arm_span, 1.8, 1e-6, "a sane span is taken (m)")


# --- WI-34: engine frame hitches through the XR pose source ----------------------
## The XR server writes the tracked nodes once per engine frame, before that
## frame's physics ticks. After a slow frame (a shader compile, a hitch) the
## engine runs several fixed ticks on ONE pose: the first sees it jump by the
## whole hitch, the rest repeat it. XRPoseSource with frame_timing stamps the
## samples (PoseFrame.pose_dt: the real time since the previous frame's pose,
## 0 for the repeats), and the stroke detectors measure velocity and arcs
## over that interval. Emulated here with an injected engine clock: 72 Hz
## frames, a 100 ms hitch (7 ticks on one pose) every 0.5 s.
##  - slow +-25 deg arm sweeps at 0.25 Hz (far below a stroke): no onset and
##    no flap effort (round 4 read the jump as a 7x faster hand: 4 spurious
##    flaps in 20 s at every size, round-5 engineering verifier); the same
##    hitches with frame_timing off still flap (the scenario bites);
##  - real strokes (45 deg at 1 Hz) keep their onsets and their mean effort
##    within 10 % of the same strokes without hitches.
func _xr_hitch_run(kind: int, hitch: bool, timing: bool) -> Dictionary:
	var origin := XROrigin3D.new()
	var cam := XRCamera3D.new()
	var lh := XRController3D.new()
	var rh := XRController3D.new()
	origin.add_child(cam)
	origin.add_child(lh)
	origin.add_child(rh)
	add_child(origin)
	var src := XRPoseSource.new(origin, cam, lh, rh)
	src.assume_tracked = true
	# By name: the old-code check runs this on the round-4 sources, which
	# have neither (the hitches then flap there).
	src.set("frame_timing", timing)
	var clock := {"frame": 0, "t": 0.0}
	src.set("clock", func() -> Vector2: return Vector2(float(clock["frame"]), float(clock["t"])))
	var wi := WingInput.new()
	wi.auto_calibrate = false
	var body := HumanPoseModel.new(3)
	var fr := PoseFrame.new()
	var truth := PoseFrame.new()
	var dt := 1.0 / 72.0
	var out := {"onsets": 0, "flap_max": 0.0, "flap_sum": 0.0, "ticks": 0}
	var real_t := 0.0
	while real_t < 12.0:
		# One engine frame: the server writes the pose at the frame's time.
		var ticks := 1
		var frame_len := dt
		if hitch and int(clock["frame"]) % 36 == 35:
			ticks = 7
			frame_len = 7.0 * dt
		real_t += frame_len
		clock["frame"] = int(clock["frame"]) + 1
		clock["t"] = real_t
		body.set_airplane()
		if kind == 0:
			var e := deg_to_rad(25.0) * sin(TAU * 0.25 * real_t)
			body.arms[0].dihedral = e
			body.arms[1].dihedral = e
		else:
			ScriptedPoseSource.flap(body, real_t, 45.0, 1.0)
		body.frame(truth)
		cam.transform = truth.head
		lh.transform = truth.left
		rh.transform = truth.right
		for k in ticks:
			src.sample(fr, dt)
			var w := wi.update(fr, dt)
			if w.onset_l or w.onset_r:
				out["onsets"] += 1
			out["flap_max"] = maxf(out["flap_max"], maxf(w.flap_l, w.flap_r))
			out["flap_sum"] += 0.5 * (w.flap_l + w.flap_r)
			out["ticks"] += 1
	origin.queue_free()
	return out


func test_wi34_engine_frame_hitches_through_the_xr_source() -> void:
	var slow_ref: Dictionary = _xr_hitch_run(0, false, true)
	var slow: Dictionary = _xr_hitch_run(0, true, true)
	var slow_r4: Dictionary = _xr_hitch_run(0, true, false)
	eq(slow_ref["onsets"], 0, "slow sweeps without hitches: no onset")
	eq(slow["onsets"], 0, "slow sweeps with a 100 ms hitch every 0.5 s: no onset (round 4: 4 flaps in 20 s)")
	lt(float(slow["flap_max"]), float(slow_ref["flap_max"]) + 0.02, "hitches add no flap effort to slow sweeps")
	gt(slow_r4["onsets"], 0, "the same hitches without frame timing flap (the round-4 defect this pins)")
	var str_ref: Dictionary = _xr_hitch_run(1, false, true)
	var str_h: Dictionary = _xr_hitch_run(1, true, true)
	near(float(str_h["onsets"]), float(str_ref["onsets"]), 1.0, "strokes keep their onsets through hitches (%d without)" % str_ref["onsets"])
	var m_ref := float(str_ref["flap_sum"]) / float(str_ref["ticks"])
	var m_h := float(str_h["flap_sum"]) / float(str_h["ticks"])
	between(m_h / m_ref, 0.9, 1.1, "strokes keep their mean flap effort through hitches (ratio)")
	metric("slow_onsets", {"ref": slow_ref["onsets"], "hitch": slow["onsets"], "hitch_no_timing": slow_r4["onsets"]})
	metric("stroke_effort_ratio", m_h / m_ref)


# --- WS-copy: WingState.copy_from copies every field -----------------------------------
## Fix round 6 replaced the reflective copy (set/get over _FIELDS, ~20 us a
## player tick) by field-by-field assignments; this keeps the two in step: a
## state with every field set to a distinct value copies exactly.
func test_ws_copy_copies_every_field() -> void:
	var a := WingState.new()
	var k := 0
	for f in WingState._FIELDS:
		var v: Variant = a.get(f)
		k += 1
		if v is bool:
			a.set(f, not v)
		elif v is Vector3:
			a.set(f, Vector3(k, k + 1, k + 2).normalized())
		else:
			a.set(f, 0.125 * k + 0.5)
	var b := WingState.new()
	b.copy_from(a)
	var bad := PackedStringArray()
	for f in WingState._FIELDS:
		if str(a.get(f)) != str(b.get(f)):
			bad.append(f)
	eq(bad.size(), 0, "every WingState field copied (%d fields; missing: %s)" % [WingState._FIELDS.size(), ", ".join(bad)])
