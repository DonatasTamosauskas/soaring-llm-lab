extends TestCase
## L3: PlayerBird, the rig and the comfort contract (FLIGHT_SPEC PB-01...09,
## PB-13, PB-14, PB-17, PB-18) and F11: across every scenario the rig never
## pitches or rolls, yaw changes are smooth (bounded yaw rate and accel), the
## head is the body, and nothing on the rig path is ever scaled.

const FX := preload("res://tests/unit/flight/pb_fixture.gd")
const PLAYER := preload("res://scenes/player/player.tscn")
const HM := preload("res://tests/unit/flight/heave_metrics.gd")
const DEG := PI / 180.0
const DT := 1.0 / 72.0

var fx: FX


func after_each() -> void:
	if fx != null:
		fx.teardown()
		fx = null
	get_tree().paused = false
	await get_tree().process_frame


func _fx(sp: StringName, world_setup: Callable = Callable()) -> FX:
	fx = FX.new(self)
	await fx.setup(sp, world_setup)
	return fx


# --- F11 / PB-01 / PB-02: a composite scenario ------------------------------------
func test_f11_comfort_across_a_composite_flight() -> void:
	await _fx(&"sparrow")
	var f := fx
	f.player.start_flying(Vector3(0, 120, 0), 0.0, 0.0)
	var cal := f.player.wing_input.calibration
	# Glide, flap, bank both ways with twist and arm tilt, dive, flare,
	# physical torso turn, one-wing flaps, look around, growth to eagle.
	f.driver = func(tick: int, t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		if t < 3.0:
			pass
		elif t < 7.0:
			ScriptedPoseSource.flap(b, t, 40.0, 1.2)
			b.arms[0].twist = -10.0 * DEG
			b.arms[1].twist = -10.0 * DEG
		elif t < 10.0:
			b.synth(0.2, 1.0, 1.0, cal)
		elif t < 13.0:
			b.synth(0.0, -0.8, 1.0, cal, 1.0, 1.0, 0.5)
		elif t < 16.0:
			b.synth(-1.0, 0.0, 0.0, cal)
		elif t < 19.0:
			b.synth(0.9, 0.0, 1.0, cal)
		elif t < 23.0:
			b.torso_yaw = -PI * 0.5 * clampf((t - 19.0) / 2.0, 0.0, 1.0)
		elif t < 26.0:
			b.torso_yaw = -PI * 0.5
			ScriptedPoseSource.flap(b, t, 45.0, 1.0, -1)
		else:
			b.torso_yaw = -PI * 0.5
			b.head_yaw = 1.2 * sin(t)
			b.head_pitch = 0.6 * sin(1.7 * t)
		# Gestures change at human arm speeds (tau 0.12 s), never teleport.
		b.humanize(DT)
	f.on_tick = func(tick: int, fix: Variant) -> void:
		if tick > 26 * 72:
			fix.player.mass = lerpf(0.03, FlightParams.species_mass(&"eagle"), clampf((tick - 26 * 72) / (6.0 * 72.0), 0.0, 1.0))
	f.run(34.0)
	f.assert_comfort(self, "composite flight")
	check(FlightMath.vfinite(f.player.model.position), "no NaN")
	check(f.player.origin.world_scale > 0.9, "grew to eagle (world_scale follows span, never node scale)")
	vnear(f.player.scale, Vector3.ONE, 1e-5, "PlayerBird node scale stays 1")
	vnear(f.player.origin.scale, Vector3.ONE, 1e-5, "XROrigin3D node scale stays 1")
	# The physics caps keep the heading inside the limits; the rig's safety
	# net should barely ever act (the view shows the true heading).
	lt(float(f.player.rig_limited_ticks) / f.player.tick_count, 0.02, "rig comfort safety net acts on < 2% of ticks")
	metric("rig_limited_ticks", f.player.rig_limited_ticks)
	metric("max_rig_yaw_rate_deg", rad_to_deg(f.comfort["max_rate"]))
	metric("max_rig_yaw_accel_deg", rad_to_deg(f.comfort["max_accel"]))


# --- PB-03 / PB-18: the camera is the body through yaw, lean and growth --------
func test_pb03_pb18_camera_is_the_body() -> void:
	await _fx(&"sparrow")
	var f := fx
	f.player.start_flying(Vector3(0, 80, 0), 0.0, 0.0)
	f.driver = func(_tick: int, t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		b.room_offset = Vector3(0.3 * sin(t), 0.1 * sin(2.0 * t), 0.2 * cos(t))
		b.synth(0.0, 0.5 * sin(0.7 * t), 1.0, WingCalibration.new())
	var acc := {"path_bad": 0, "prev": f.player.camera.global_position}
	f.on_tick = func(tick: int, fix: Variant) -> void:
		if tick > 72:
			fix.player.mass = 0.03 + 0.3 * clampf((tick - 72) / 216.0, 0.0, 1.0)
		var cam: Vector3 = fix.player.camera.global_position
		var step: float = cam.distance_to(acc["prev"])
		# Continuous head path: never more than one tick of motion (+ head, + 1 mm).
		if step > fix.player.model.velocity.length() * DT + 0.5 * DT * fix.player.origin.world_scale + 0.001 + absf(fix.player._heave_off) * 0.2:
			acc["path_bad"] += 1
		acc["prev"] = cam
	f.run(6.0)
	f.assert_comfort(self, "lean + growth")
	eq(acc["path_bad"], 0, "the head's world path is continuous through growth")
	species_ok(f)


func species_ok(f: FX) -> void:
	eq(f.player.species, SizeRules.species_for_mass(f.player.mass), "species follows mass")
	near(f.player.model.params.mass, f.player.mass, 1e-9, "FlightParams re-derived in the same tick (S6)")


# --- PB-04: physical head motion moves camera and body; walls stop it ------------
func test_pb04_head_motion_moves_the_body() -> void:
	await _fx(&"pigeon", func(w: Variant) -> void:
		w.add_wall(Vector3(0, 100, -3.0), Vector3(20, 20, 1)))
	var f := fx
	f.player.start_flying(Vector3(0, 100, 0), 0.0, 0.0)
	f.player.model.velocity = Vector3.ZERO
	f.step()
	f.player.model.position = Vector3(0, 100, 0)
	f.player.model.velocity = Vector3.ZERO
	f.step()
	var ws := f.player.origin.world_scale
	var body0 := f.player.model.position
	var cam0 := f.player.camera.global_position
	# A 0.3 m real step to the right (x) in 0.3 s, gravity off by resetting.
	f.driver = func(_tick: int, t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		b.room_offset = Vector3(0.3 * clampf(t / 0.3, 0.0, 1.0), 0, 0)
	for i in 36:
		f.player.model.velocity = Vector3.ZERO
		f.player.model.position.y = 100.0
		f.step()
	var moved := f.player.camera.global_position - cam0
	near(moved.x, 0.3 * ws, 0.002, "camera moved 0.3 m x world_scale")
	near((f.player.model.position - body0).x, 0.3 * ws, 0.002, "the body moved with the head")
	# Walk into the wall (world z -3, 1 m thick): the camera stops outside it.
	f.driver = func(_tick: int, t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		b.room_offset = Vector3(0.3, 0, -40.0 * clampf(t / 3.0, 0.0, 1.0))
	for i in 3 * 72:
		f.player.model.velocity = Vector3.ZERO
		f.player.model.position.y = 100.0
		f.step()
	var gap := f.player.camera.global_position.z - (-2.5)
	gt(gap, f.player.model.params.r_body - 0.002, "camera stays >= r_body from the wall")


# --- PB-05: body steer turns the bird, not the view --------------------------------
func test_pb05_body_steer() -> void:
	for sp in [&"sparrow", &"eagle"]:
		await _fx(sp)
		var f := fx
		f.player.start_flying(Vector3(0, 300, 0), 0.0, 0.0)
		f.run(0.5)
		var rig0 := f.player.rig_yaw
		var h0 := f.player.model.heading()
		f.driver = func(_tick: int, t: float, b: HumanPoseModel) -> void:
			b.set_airplane()
			b.torso_yaw = -PI * 0.5 * clampf(t / 1.0, 0.0, 1.0)
		var p := f.player.model.params
		var omega := FlightMath.G * tan(0.8 * p.phi_max) / p.v_c
		var limit := 1.25 * (PI * 0.5) / omega + 2.0
		var acc := {"t": -1.0}
		f.on_tick = func(tick: int, fix: Variant) -> void:
			var target: float = h0 - PI * 0.5
			if acc["t"] < 0.0 and absf(FlightMath.wrap_angle(fix.player.model.heading() - target)) < 5.0 * DEG:
				acc["t"] = tick * DT
		var t0 := f.ticks
		f.on_tick = func(tick: int, fix: Variant) -> void:
			var target: float = h0 - PI * 0.5
			if acc["t"] < 0.0 and absf(FlightMath.wrap_angle(fix.player.model.heading() - target)) < 5.0 * DEG:
				acc["t"] = (tick - t0) * DT
		f.run(limit + 1.0)
		check(acc["t"] >= 0.0 and acc["t"] <= limit, "%s: heading follows a 90 deg torso turn within %.1f s (got %.2f)" % [sp, limit, acc["t"]])
		lt(absf(rad_to_deg(FlightMath.wrap_angle(f.player.rig_yaw - rig0))), 2.0, "%s: the rig does not rotate for a physical turn (deg)" % sp)
		f.assert_comfort(self, "%s body steer" % sp)
		metric("%s_body_steer_s" % sp, acc["t"])
		fx.teardown()
		fx = null
	# With body steer off the heading ignores the torso.
	await _fx(&"sparrow")
	fx.player.body_steer = false
	fx.player.start_flying(Vector3(0, 300, 0), 0.0, 0.0)
	var h1 := fx.player.model.heading()
	fx.driver = func(_tick: int, t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		b.torso_yaw = -PI * 0.5 * clampf(t / 1.0, 0.0, 1.0)
	fx.run(4.0)
	lt(absf(rad_to_deg(FlightMath.wrap_angle(fx.player.model.heading() - h1))), 2.0, "body steer off: heading unchanged (deg)")


# --- PB-06: a tilt turn rotates the world around the player -------------------
func test_pb06_tilt_turn_rotates_the_rig() -> void:
	await _fx(&"pigeon")
	var f := fx
	f.player.start_flying(Vector3(0, 300, 0), 0.0, 0.0)
	f.run(0.3)
	var rig0 := f.player.rig_yaw
	var h0 := f.player.model.heading()
	f.driver = f.synth(0.0, 0.6)
	f.run(3.0)
	var dh := FlightMath.wrap_angle(f.player.model.heading() - h0)
	var dr := FlightMath.wrap_angle(f.player.rig_yaw - rig0)
	lt(dh, -0.5, "roll 0.6 turns right")
	near(rad_to_deg(dr), rad_to_deg(dh), 2.0, "rig yaw change = heading change (deg)")
	f.assert_comfort(self, "tilt turn")


# --- PB-07: looking around never steers ------------------------------------------
func test_pb07_look_never_steers() -> void:
	await _fx(&"sparrow")
	var f := fx
	f.player.start_flying(Vector3(0, 300, 0), 0.0, 0.0)
	f.run(1.0)
	var h0 := f.player.model.heading()
	var acc := {"cmd": 0.0}
	f.driver = func(_tick: int, t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		b.head_yaw = 90.0 * DEG * sin(1.5 * t)
		b.head_pitch = 45.0 * DEG * sin(1.1 * t)
		b.head_roll = 20.0 * DEG * sin(0.9 * t)
	f.on_tick = func(_tick: int, fix: Variant) -> void:
		var w: WingState = fix.player.wing_state()
		acc["cmd"] = maxf(acc["cmd"], maxf(absf(w.pitch), absf(w.roll)))
	f.run(4.0)
	lt(acc["cmd"], 0.01, "head look: pitch/roll commands stay 0")
	lt(absf(rad_to_deg(FlightMath.wrap_angle(f.player.model.heading() - h0))), 0.5, "head look: heading unchanged (deg)")


# --- PB-08: flap bob (camera heave) ---------------------------------------------
## Half peak-to-peak of y minus its centred 1-period moving average: the
## wingbeat ripple with the flight path (and any constant offset) removed.
static func _ripple(ys: PackedFloat64Array) -> float:
	var n := 36
	var lo := INF
	var hi := -INF
	for i in range(n, ys.size() - n):
		var m := 0.0
		for k in range(-n, n + 1):
			m += ys[i + k]
		m /= 2 * n + 1
		lo = minf(lo, ys[i] - m)
		hi = maxf(hi, ys[i] - m)
	return 0.5 * (hi - lo)


## -> [camera cm, raw body cm] perceived (/ world_scale) over [warm, warm + 4 s].
func _bob(sp: StringName, kind: String, warm: float) -> Array:
	await _fx(sp)
	var f := fx
	if kind == "hover":
		f.player.start_flying(Vector3(0, 200, 0), 0.0, 0.5)
		f.player.model.velocity = Vector3.ZERO
		f.driver = func(_tick: int, t: float, b: HumanPoseModel) -> void:
			b.set_airplane()
			ScriptedPoseSource.flap(b, t, 45.0, 1.0)
			for a in b.arms:
				a.twist = 20.0 * DEG
	elif kind == "cruise":
		f.player.start_flying(Vector3(0, 200, 0), 0.0, 0.0)
		f.driver = func(_tick: int, t: float, b: HumanPoseModel) -> void:
			b.set_airplane()
			ScriptedPoseSource.flap(b, t, 25.0, 1.0)
			for a in b.arms:
				a.twist = -20.0 * DEG
	else:
		f.player.start_flying(Vector3(0, 200, 0), 0.0, 0.0)
		f.driver = func(_tick: int, t: float, b: HumanPoseModel) -> void:
			b.set_airplane()
			ScriptedPoseSource.flap(b, t, 45.0, 1.0)
	var hm := HM.new()
	f.on_tick = func(_tick: int, fix: Variant) -> void:
		hm.push(fix.player)
	f.run(warm + 4.0)
	var i0 := int(round(warm / DT))
	var ys := hm.cam.slice(i0)
	var bs := hm.body.slice(i0)
	var ws := f.player.origin.world_scale
	fx.teardown()
	fx = null
	# [moving-average bob cam, raw; wingbeat (path-separated) cam, raw]
	return [_ripple(ys) / ws * 100.0, _ripple(bs) / ws * 100.0,
		hm.wingbeat(hm.cam, i0, hm.size(), 1.0), hm.wingbeat(hm.body, i0, hm.size(), 1.0)]


func test_pb08_flap_bob_is_smoothed() -> void:
	# Steady regimes (8 s in): the spec's hover / flapping cruise / hard climb.
	var limits := {"sparrow": {"hover": 30.0, "cruise": 45.0, "climb": 40.0},
		"pigeon": {"cruise": 20.0, "climb": 40.0}, "eagle": {"cruise": 12.0, "climb": 20.0}}
	if Paths.arg("full", "") != "":
		limits["starling"] = {"hover": 30.0, "cruise": 45.0, "climb": 40.0}
	else:
		# Default (the 60 s budget): every sparrow regime, the others' cruise.
		limits["pigeon"] = {"cruise": 20.0}
		limits["eagle"] = {"cruise": 12.0}
	for sp in limits:
		for kind in limits[sp]:
			var r: Array = await _bob(StringName(sp), kind, 8.0)
			lt(r[0], limits[sp][kind], "%s %s: perceived camera bob (cm, / world_scale)" % [sp, kind])
			metric("%s_%s_bob_cm" % [sp, kind], r)
	# While a hard climb is being established the smoother waits for the
	# rhythm (three regular strokes, then a jerk-limited ease in: round 2's
	# do-no-harm gates) and never amplifies the wingbeat (4-8 s); from the
	# 6th second it at least halves it (6-10 s). Measured path-separated
	# (heave_metrics wingbeat): the moving-average bob counts the climb's own
	# curvature as bob, and a camera that follows the flight path 1:1 must
	# show that.
	var tr: Array = await _bob(&"sparrow", "climb", 4.0)
	lt(tr[2], 1.0 * tr[3], "sparrow climb transient (4-8 s): camera wingbeat <= the raw wingbeat")
	metric("sparrow_climb_transient_cm", tr)
	var tr6: Array = await _bob(&"sparrow", "climb", 6.0)
	lt(tr6[2], 0.5 * tr6[3], "sparrow climb transient (6-10 s): camera wingbeat <= half the raw wingbeat")
	metric("sparrow_climb_transient_6s_cm", tr6)


# --- PB-09: the camera never clips ------------------------------------------------
func test_pb09_camera_never_clips_a_low_ceiling() -> void:
	var span := SizeRules.wingspan_for_mass(0.03)
	await _fx(&"sparrow", func(w: Variant) -> void:
		w.add_wall(Vector3(0, 50.0 + 0.3 * span + 0.5, 0), Vector3(10, 1, 10)))
	var f := fx
	f.player.start_flying(Vector3(0, 50, 0), 0.0, 0.5)
	f.player.model.velocity = Vector3.ZERO
	f.driver = func(_tick: int, t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		ScriptedPoseSource.flap(b, t, 45.0, 1.0)
		for a in b.arms:
			a.twist = 25.0 * DEG
	var space := f.player.get_world_3d().direct_space_state
	var q := PhysicsShapeQueryParameters3D.new()
	var sh := SphereShape3D.new()
	q.shape = sh
	q.collision_mask = 1
	var acc := {"hits": 0}
	f.on_tick = func(_tick: int, fix: Variant) -> void:
		sh.radius = maxf(0.001, 0.03 * fix.player.origin.world_scale)
		q.transform = Transform3D(Basis.IDENTITY, fix.player.camera.global_position)
		if not space.intersect_shape(q, 1).is_empty():
			acc["hits"] += 1
	f.run(6.0)
	eq(acc["hits"], 0, "camera near sphere never intersects geometry (hovering under a ceiling 0.3 span up)")


# --- PB-13: state and API ------------------------------------------------------------
func test_pb13_state_and_api() -> void:
	await _fx(&"sparrow", func(w: Variant) -> void:
		w.add_perch(Vector3(10, 20, 0), Vector3.FORWARD, 1.0))
	var f := fx
	var p := f.player
	# S1: controls off -> wings level within 2 t90, flaps ignored.
	p.start_flying(Vector3(0, 200, 0), 0.0, 0.0)
	f.driver = f.synth(0.0, 0.8)
	f.run(2.0)
	gt(absf(p.model.phi), 0.5, "banked before disabling controls")
	p.set_controls_enabled(false)
	f.driver = func(_tick: int, t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		ScriptedPoseSource.flap(b, t, 45.0, 1.0)
		b.synth(0.0, 0.8, 1.0, WingCalibration.new())
	f.reset_events()
	f.run(2.0 * 0.43 + 0.3)
	lt(absf(rad_to_deg(p.model.phi)), 3.0, "S1: controls off -> wings level within 2 t90")
	eq(f.events["flapped"], 0, "S1: flaps ignored with controls off")
	p.set_controls_enabled(true)
	# S2: pause 1 s -> model unchanged, head moves the camera, no jump on unpause.
	p.start_flying(Vector3(0, 200, 0), 0.0, 0.0)
	f.driver = func(_tick: int, _t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
	f.run(0.5)
	var pos_before := p.model.position
	var cam_before := p.camera.global_position
	var ws := p.origin.world_scale
	# While paused the tick is not called; the XR node (ALWAYS) still moves.
	p.camera.transform.origin += Vector3(0.3, 0, 0) * ws
	vnear(p.model.position, pos_before, 1e-9, "S2: paused model unchanged")
	near(p.camera.global_position.distance_to(cam_before), 0.3 * ws, 1e-4, "S2: head motion moves the camera while paused")
	f.driver = func(_tick: int, _t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		b.room_offset = Vector3(0.3, 0, 0)
	var cam_paused := p.camera.global_position
	f.step()
	var jump := p.camera.global_position - cam_paused
	lt((jump - p.model.velocity * DT).length(), 0.002, "S2: no camera jump on unpause")
	# S3: respawn -> eye at xf, yaw, PERCHED if a perch is within 1 span.
	f.reset_events()
	var xf := Transform3D(Basis(Vector3.UP, 0.7), Vector3(10, 20.0 + p.model.params.r_body, 0.1))
	p.respawn(xf)
	eq(p.mode, PlayerBird.Mode.PERCHED, "S3: respawn next to a fitting perch perches")
	near(p.rig_yaw, 0.7, 1e-6, "S3: rig yaw from the respawn transform")
	eq(f.events["spawned"], 1, "S3: player_spawned once")
	var xf2 := Transform3D(Basis(Vector3.UP, -1.0), Vector3(-50, 60, 20))
	p.respawn(xf2)
	eq(p.mode, PlayerBird.Mode.SPAWNING, "S3: open air respawn is SPAWNING")
	vnear(p.camera.global_position, xf2.origin, 0.001, "S3: eye at the respawn point")
	f.run(0.6)
	eq(p.mode, PlayerBird.Mode.FLYING, "S3: SPAWNING -> FLYING after 0.5 s")
	# S4: every contract key present and finite.
	var t := p.telemetry()
	for k in ["airspeed", "groundspeed", "vertical_speed", "altitude_agl", "aoa", "bank", "stalled", "flapping",
			"wing_extension", "tucked", "perched", "in_updraft", "g_load", "lift", "drag"]:
		check(t.has(k), "S4: telemetry has %s" % k)
		if t.has(k) and t[k] is float:
			check(is_finite(t[k]), "S4: telemetry %s finite" % k)
	# S6: the mass setter reconfigures within the same tick.
	p.mass = 0.3
	near(p.model.params.mass, 0.3, 1e-9, "S6: FlightParams follow the mass immediately")
	eq(p.species, &"pigeon", "S6: species follows mass")


# --- PB-14: tracking loss mid-turn -----------------------------------------------
func test_pb14_tracking_loss_glides() -> void:
	await _fx(&"pigeon")
	var f := fx
	f.player.start_flying(Vector3(0, 300, 0), 0.0, 0.0)
	var cal := f.player.wing_input.calibration
	f.driver = func(_tick: int, t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		b.synth(0.0, 0.7, 1.0, cal)
		b.right_valid = not (t >= 2.0 and t < 5.0)
	# The lost wing mirrors the other within 0.85 s (WingInput §5.12: the
	# mirror weight ramps from 0.25 s to 0.85 s of loss), so the roll input
	# cancels; FLIGHT_SPEC PB-14: |bank| < 5 deg within 1.5 s after that,
	# i.e. from 2.0 + 0.85 + 1.5 s to the end of the loss at 5.0 s.
	var tr := {"phi": []}
	f.on_tick = func(_tick: int, fix: Variant) -> void:
		var t: float = fix.ticks * DT
		if t >= 2.0 + 0.85 + 1.5 and t < 5.0:
			tr["phi"].append(absf(rad_to_deg(fix.player.model.phi)))
	f.run(2.0)
	gt(absf(f.player.model.phi), 0.3, "turning before the loss")
	f.reset_events()
	f.run(3.0 + 1.5)
	check(FlightMath.vfinite(f.player.model.position), "no NaN through tracking loss")
	var worst := 0.0
	for v in tr["phi"]:
		worst = maxf(worst, v)
	gt(tr["phi"].size(), 30, "sampled 1.5 s after the loss decays (%d ticks)" % tr["phi"].size())
	lt(worst, 5.0, "PB-14: |bank| < 5 deg from 1.5 s after the loss decays to the end of the loss")
	metric("worst_bank_deg_during_loss", worst)
	eq(f.events["flapped"], 0, "no flap events from a lost hand")
	f.assert_comfort(self, "tracking loss")


# --- PB-13 S2: a real paused tree (ARCHITECTURE §4, §7.6) --------------------------
## The pause menu pauses the SceneTree: PlayerBird (PAUSABLE) must stop
## flying and the XR rig (XROrigin3D, PROCESS_MODE_ALWAYS, and everything
## under it) must keep processing so the head and hands still track.
## S2 above simulates the pause by not calling tick(); this is the tree.
func test_pb13_s2_real_tree_pause() -> void:
	var p := PLAYER.instantiate() as PlayerBird
	p.use_settings = false
	p.default_source = &"none"
	p.mass = FlightParams.species_mass(&"sparrow")
	add_child(p)
	p.start_flying(Vector3(0, 300, 0), 0.0, 0.0)
	await wait_physics(6)
	var t0 := p.tick_count
	gt(t0, 3, "S2: ticks while unpaused (auto_process)")
	var pos0 := p.model.position
	get_tree().paused = true
	await wait_physics(10)
	eq(p.tick_count, t0, "S2: no flight ticks while the tree is paused")
	vnear(p.model.position, pos0, 1e-9, "S2: model frozen while paused")
	check(not p.can_process(), "S2: PlayerBird is pausable")
	var bad: Array[String] = []
	var stack: Array[Node] = [p.origin]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if not n.can_process():
			bad.append(str(n.name))
		stack.append_array(n.get_children())
	eq(bad.size(), 0, "S2: every node under XROrigin3D processes while paused (%s)" % ", ".join(bad))
	get_tree().paused = false
	await wait_physics(4)
	gt(p.tick_count, t0, "S2: ticks resume after unpause")
	remove_child(p)
	p.free()


# --- PB-13 S5: each event exactly once per occurrence --------------------------------
## Audio, haptics and the onboarding UI hang off these: a missing or doubled
## event is a missing or doubled sound. Every occurrence is counted from the
## PlayerBird's own state (onset flags, the model's stall counter, the
## contact counters, mode transitions) and must equal the events received.
func test_pb13_s5_events_once_per_occurrence() -> void:
	const PERCH := Vector3(0, 20, -10)
	await _fx(&"sparrow", func(w: Variant) -> void:
		w.add_perch(PERCH, Vector3.FORWARD, 10.0, 0.015, 1.0)
		w.add_wall(Vector3(60, 80, -60), Vector3(40, 40, 1.0)))
	var f := fx
	var p := f.player
	var n := {"onsets": [], "perch": 0, "takeoff": 0, "prev_mode": p.mode}
	f.on_tick = func(tick: int, fix: Variant) -> void:
		var pl: PlayerBird = fix.player
		var w := pl.wing_state()
		if pl.controls_enabled and pl.mode != PlayerBird.Mode.CAUGHT:
			if w.onset_l and w.onset_r:
				n["onsets"].append([tick * DT, 0])
			elif w.onset_l:
				n["onsets"].append([tick * DT, -1])
			elif w.onset_r:
				n["onsets"].append([tick * DT, 1])
		var m: int = pl.mode
		var was: int = n["prev_mode"]
		var down := [PlayerBird.Mode.PERCHED, PlayerBird.Mode.GROUNDED]
		if m in down and not was in down:
			n["perch"] += 1
		if was in down and m == PlayerBird.Mode.FLYING:
			n["takeoff"] += 1
		n["prev_mode"] = m
	# player_spawned: once per respawn.
	f.reset_events()
	p.respawn(Transform3D(Basis.IDENTITY, Vector3(0, 80, 0)))
	p.respawn(Transform3D(Basis.IDENTITY, Vector3(0, 80, 0)))
	eq(f.events["spawned"], 2, "S5: player_spawned once per respawn")
	f.run(0.6)
	# player_flapped: once per stroke (ARCHITECTURE §5: the two wings' onsets
	# within 60 ms are one stroke, side 0; a one-wing stroke carries its
	# side). Both wings, then alternating one-wing strokes.
	var sides := {-1: 0, 0: 0, 1: 0}
	var on_flap := func(side: int, _st: float) -> void: sides[side] += 1
	Events.player_flapped.connect(on_flap)
	f.reset_events()
	n["onsets"] = []
	f.driver = func(_tick: int, t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		ScriptedPoseSource.flap(b, t, 40.0, 1.0, 0 if t < 3.0 else (-1 if int(t) % 2 == 0 else 1))
	f.run(6.0 + 0.1)
	Events.player_flapped.disconnect(on_flap)
	# Pair the onsets the same way, independently.
	var want := {-1: 0, 0: 0, 1: 0}
	var ons: Array = n["onsets"]
	var i := 0
	while i < ons.size():
		var side: int = ons[i][1]
		if side != 0 and i + 1 < ons.size() and int(ons[i + 1][1]) == -side and float(ons[i + 1][0]) - float(ons[i][0]) <= 0.0601:
			want[0] += 1
			i += 2
			continue
		want[side] += 1
		i += 1
	gt(want[0], 2, "S5: two-wing strokes credited (%d)" % want[0])
	gt(want[-1] + want[1], 1, "S5: one-wing strokes credited (%d)" % (want[-1] + want[1]))
	eq(f.events["flapped"], want[-1] + want[0] + want[1], "S5: player_flapped once per stroke")
	eq(sides[0], want[0], "S5: two-wing strokes carry side 0")
	eq(sides[-1] + sides[1], want[-1] + want[1], "S5: one-wing strokes carry their side")
	# player_stalled: once per model stall (held full nose-up).
	f.reset_events()
	var s0 := p.model.stall_count
	f.driver = f.synth(1.0, 0.0)
	f.run(4.0)
	gt(p.model.stall_count - s0, 0, "S5: held full nose-up stalls")
	eq(f.events["stalled"], p.model.stall_count - s0, "S5: player_stalled once per model stall")
	# player_collided: once per slide / stun contact and once per wing brush
	# start. Head-on into the wall at cruise.
	var c0: int = p.contacts["slide"] + p.contacts["stun"] + p.contacts["brush"]
	p.start_flying(Vector3(60, 80, -60 + 6.0 * p.model.params.span + 2.0), 0.0, 0.0)
	f.driver = func(_tick: int, _t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
	f.reset_events()
	f.run(2.0)
	var c1: int = p.contacts["slide"] + p.contacts["stun"] + p.contacts["brush"]
	gt(c1 - c0, 0, "S5: the wall was hit")
	eq(f.events["collided"], c1 - c0, "S5: player_collided once per contact")
	# player_perched / player_took_off: once per landing and per launch.
	var pr := p.model.params
	var start := PERCH + Vector3.UP * pr.r_body + Vector3(0, 0.1 * pr.span, 2.0 * pr.span)
	p.start_flying(start, 0.0, 0.0)
	p.model.reset(start, Vector3(0, 0, -0.72 * pr.v_min), 0.0)
	f.reset_events()
	n["perch"] = 0
	n["takeoff"] = 0
	n["prev_mode"] = p.mode
	f.run(1.5)
	eq(p.mode, PlayerBird.Mode.PERCHED, "S5: perched")
	f.driver = func(_tick: int, t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		ScriptedPoseSource.flap(b, t + 0.75, 45.0, 1.0)
	f.run(2.0)
	eq(n["perch"], 1, "S5: one landing")
	eq(f.events["perched"], n["perch"], "S5: player_perched once per landing")
	eq(n["takeoff"], 1, "S5: one launch")
	eq(f.events["took_off"], n["takeoff"], "S5: player_took_off once per launch")
	metric("events", f.events)


# --- PB-23: the Bird lifecycle (ARCHITECTURE §5) ---------------------------------
## Bird._enter_tree registers with Birds and Bird._exit_tree unregisters;
## PlayerBird overrides _exit_tree (the pose recorder) and Godot 4 does not
## chain virtual callbacks by itself. Round 2: without super() a freed
## player stayed in Birds.all() and Birds.nearby(exclude = <npc>) hit a
## freed instance (SCRIPT ERROR) for every AI and game-loop query.
func test_pb23_registry_lifecycle() -> void:
	var n0 := Birds.count()
	var removed := {"n": 0}
	var cb := func(_b: Bird) -> void: removed["n"] += 1
	Events.bird_removed.connect(cb)
	var p := PLAYER.instantiate() as PlayerBird
	p.auto_process = false
	p.use_settings = false
	p.default_source = &"none"
	add_child(p)
	check(Birds.player() == p, "Birds.player() is the PlayerBird while in the tree")
	eq(Birds.count(), n0 + 1, "registered once")
	remove_child(p)
	check(Birds.player() == null, "Birds.player() cleared when it leaves the tree")
	eq(Birds.count(), n0, "Birds.count() back to its value before")
	eq(removed["n"], 1, "Events.bird_removed once")
	# Re-entering registers again (scene reloads re-parent the player).
	add_child(p)
	check(Birds.player() == p, "re-registered on re-entry")
	remove_child(p)
	p.free()
	Events.bird_removed.disconnect(cb)
	var dangling := 0
	for b in Birds.all():
		if not is_instance_valid(b):
			dangling += 1
	eq(dangling, 0, "no freed birds left in Birds.all()")
	# A consumer query that skips another bird walks every entry.
	var npc := Bird.new()
	add_child(npc)
	var near := Birds.nearby(Vector3.ZERO, 1e6, npc)
	eq(near.size(), 0, "Birds.nearby(exclude = an NPC) returns no freed player")
	remove_child(npc)
	npc.free()
	# Every fixture in this suite frees its player: none may be left over.
	await _fx(&"sparrow")
	fx.teardown()
	fx = null
	eq(Birds.count(), n0, "a fixture's player is unregistered by its teardown")


# --- PERF-01: the player tick ---------------------------------------------------
## FLIGHT_SPEC 14.7: pose + WingInput + model + sweep + rig <= 0.35 ms mean
## on the dev Mac (debug build). Real rig in a test world with a perch and a
## window, flapping and turning; median of 5 batches of 2 s. Strict with
## `-- --perf` on an idle machine; the default suite runs on a shared, busy
## machine and asserts a 2.5 x regression bound.
func test_perf01_player_tick() -> void:
	var strict := Paths.user_args().has("perf")
	for sp: StringName in [&"sparrow", &"eagle"]:
		await _fx(sp, func(w: Variant) -> void:
			w.add_perch(Vector3(0, 20, -60), Vector3.FORWARD, 10.0)
			w.add_window(Vector3(0, 30, -120), Vector3.BACK, 4.0, 3.0, 0.3))
		var f := fx
		f.player.start_flying(Vector3(0, 40, 0), 0.0, 0.0)
		var cal := f.player.wing_input.calibration
		f.driver = func(_tick: int, t: float, b: HumanPoseModel) -> void:
			b.set_airplane()
			b.synth(0.1, 0.4 * sin(0.5 * t), 1.0, cal)
			ScriptedPoseSource.flap(b, t, 40.0, 1.2)
		f.run(1.0)
		var batches: Array = []
		for k in 5:
			var s := 0.0
			for i in 144:
				f.step()
				s += f.player.tick_us
			batches.append(s / 144.0)
		batches.sort()
		var med: float = batches[2]
		metric("%s_tick_us_median_of_5" % sp, med)
		metric("%s_batches_us" % sp, batches)
		lt(med / 1000.0, 0.35 * (1.0 if strict else 2.5), "%s PERF-01: player tick mean (ms; strict with --perf)" % sp)
		fx.teardown()
		fx = null


# --- FM-24c: the whole chain at the headset's rates -------------------------------
## VR runs physics at the display rate (72 / 90 / 120 Hz). FM-24 pins the
## model alone (1.5 % of the path vs 720 Hz); this flies the round-2
## verifier's flapping turn through poses -> WingInput -> PlayerBird at each
## rate. The flap and roll commands agree within 0.5 % in integral across
## tick rates (onsets land on tick boundaries, effort is held per tick) and
## the 15 s turn at up to ~150 deg/s loops the path twice, which amplifies
## that (FLIGHT.md §3). The end state agrees within 3 % of the flown path and
## 5 deg of heading, flap events match, and the comfort caps hold per tick
## at every rate.
func _chain_at(hz: float) -> Dictionary:
	await _fx(&"pigeon")
	var f := fx
	var p := f.player
	p.start_flying(Vector3(0, 200, 0), 0.0, 0.0)
	var cal := p.wing_input.calibration
	p.set_pose_source(ScriptedPoseSource.new(f.body, func(_tick: int, t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		b.synth(0.1, 0.7 if (t > 2.0 and t < 9.0) else -0.4 if t < 12.0 else 0.0, 1.0, cal)
		if t < 6.0:
			ScriptedPoseSource.flap(b, t, 40.0, 1.1)))
	var ev := {"n": 0}
	var cb := func(_side: int, _st: float) -> void: ev["n"] += 1
	Events.player_flapped.connect(cb)
	var dt := 1.0 / hz
	var st := {"rate": 0.0, "acc": 0.0, "basis": 0, "path": 0.0}
	var prev := p.model.position
	for i in int(round(15.0 * hz)):
		p.tick(dt)
		st["path"] += p.model.position.distance_to(prev)
		prev = p.model.position
		if i > 3 and not p.yaw_flagged:
			st["rate"] = maxf(st["rate"], absf(rad_to_deg(p.rig_yaw_rate)))
			st["acc"] = maxf(st["acc"], absf(rad_to_deg(p.rig_yaw_accel)))
		if p.global_basis.y.dot(Vector3.UP) < 1.0 - 1e-6:
			st["basis"] += 1
	Events.player_flapped.disconnect(cb)
	var out := {"pos": p.model.position, "heading": p.model.heading(), "flaps": ev["n"], "path": st["path"],
		"rate": st["rate"], "acc": st["acc"], "basis": st["basis"]}
	fx.teardown()
	fx = null
	return out


func test_fm24c_chain_at_headset_rates() -> void:
	var r72: Dictionary = await _chain_at(72.0)
	gt(r72["flaps"], 3, "the scenario flaps (%d events)" % r72["flaps"])
	for hz in [72.0, 90.0, 120.0]:
		var r: Dictionary = r72 if hz == 72.0 else await _chain_at(hz)
		var d: float = (r["pos"] as Vector3).distance_to(r72["pos"])
		if hz != 72.0:
			lt(d / float(r72["path"]), 0.03, "%d Hz: end position within 3%% of the flown path of the 72 Hz run (%.2f of %.0f m)" % [int(hz), d, r72["path"]])
			lt(absf(rad_to_deg(wrapf(float(r["heading"]) - float(r72["heading"]), -PI, PI))), 5.0, "%d Hz: heading within 5 deg" % int(hz))
			near(float(r["flaps"]), float(r72["flaps"]), 0.5, "%d Hz: the same flap events" % int(hz))
		lt(r["rate"], 240.0 + 1e-3, "%d Hz: rig yaw rate cap (deg/s)" % int(hz))
		lt(r["acc"], 756.0, "%d Hz: rig yaw acceleration cap (deg/s^2)" % int(hz))
		eq(r["basis"], 0, "%d Hz: the rig never pitches or rolls" % int(hz))
		metric("hz_%d" % int(hz), {"d_m": d, "path_m": r72["path"], "heading_deg": rad_to_deg(r["heading"]), "flaps": r["flaps"]})


# --- PB-17: recenter mid-flight -------------------------------------------------
func test_pb17_recenter() -> void:
	await _fx(&"sparrow")
	var f := fx
	f.player.start_flying(Vector3(0, 300, 0), 0.0, 0.0)
	f.run(1.0)
	var h0 := f.player.model.heading()
	# The runtime recenters: tracking space rotates by 60 deg under the player.
	f.driver = func(_tick: int, _t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		b.torso_yaw = 60.0 * DEG
		b.room_offset = Vector3(0.5, 0, 0.2)
	Events.recenter_requested.emit()
	f.step()
	lt(absf(rad_to_deg(FlightMath.wrap_angle(f.player.model.heading() - h0))), 0.1 + rad_to_deg(absf(f.player.model.yaw_rate)) * DT, "heading continuous through a recenter (deg)")
	near(rad_to_deg(FlightMath.wrap_angle(f.player.rig_yaw - (f.player.model.heading() - f.player.wing_state().body_yaw))), 0.0, 1.0, "rig yaw = heading - body yaw (deg)")
	check(f.player.yaw_flagged, "recenter is a flagged yaw tick")


# --- PB-19: corrupt poses and long frames never reach the rig ----------------------
## A pose source that glitches (NaN / inf origins, degenerate bases,
## teleports, in the head and both hands, flagged valid) plus frame hitches
## (a 1.5 s tick, 0.3 s ticks): every rig node stays finite on every tick and
## the view never jumps by more than the body's own motion plus the player's
## head motion that tick (round 1: a NaN head sample made the XROrigin3D and
## camera NaN for a tick; one 1.5 s tick left the heave offset NaN for good).
class GlitchSource extends PoseSource:
	var inner: ScriptedPoseSource
	var rng := RandomNumberGenerator.new()
	var glitches := 0

	func _init(p_inner: ScriptedPoseSource) -> void:
		inner = p_inner
		rng.seed = 11

	func sample(out: PoseFrame, dt: float) -> void:
		inner.sample(out, dt)
		if rng.randf() < 0.06:
			glitches += 1
			var which := rng.randi_range(0, 2)
			var tr: Transform3D = out.head if which == 0 else (out.left if which == 1 else out.right)
			match rng.randi_range(0, 4):
				0: tr.origin.x = NAN
				1: tr.origin.y = INF
				2: tr.basis = Basis(Vector3(NAN, 0, 0), Vector3.UP, Vector3.BACK)
				3: tr.basis = Basis(Vector3.ZERO, Vector3.ZERO, Vector3.ZERO)
				4: tr.origin += Vector3(0.0, 0.0, 3.0)
			if which == 0:
				out.head = tr
			elif which == 1:
				out.left = tr
			else:
				out.right = tr

	func drives_nodes() -> bool:
		return true

	func reset() -> void:
		inner.reset()


func test_pb19_corrupt_poses_and_hitches_never_reach_the_rig() -> void:
	await _fx(&"sparrow")
	var f := fx
	f.player.start_flying(Vector3(0, 300, 0), 0.0, 0.0)
	f.driver = func(_tick: int, t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		ScriptedPoseSource.flap(b, t, 35.0, 1.0)
		b.arms[0].twist = 12.0 * DEG * sin(0.5 * t)
		b.head_yaw = 0.6 * sin(0.9 * t)
		b.humanize(DT)
	var gs := GlitchSource.new(f.src)
	f.player.set_pose_source(gs)
	var st := {"bad": 0, "jump": 0.0, "prev_cam": f.player.camera.global_position, "prev_body": f.player.model.position}
	var p := f.player
	var nodes: Array[Node3D] = [p, p.origin, p.camera, p.left_hand, p.right_hand, p.left_aim, p.right_aim]
	for i in int(20.0 / DT):
		var dt := DT
		if i == 400:
			dt = 1.5
		elif i % 250 == 0:
			dt = 0.3
		p.tick(dt)
		for n in nodes:
			var g := n.global_transform
			if not (FlightMath.vfinite(g.origin) and FlightMath.bfinite(g.basis)):
				st["bad"] += 1
		var tel := p.telemetry()
		for k in ["airspeed", "vertical_speed", "aoa", "bank", "g_load", "heave_offset", "rig_yaw"]:
			if not is_finite(float(tel[k])):
				st["bad"] += 1
		var cam := p.camera.global_position
		var body := p.model.position
		# The view moves with the body (+ the heave offset change + head motion).
		var excess: float = (cam - st["prev_cam"]).length() - (body - st["prev_body"]).length()
		st["jump"] = maxf(st["jump"], excess / p.origin.world_scale)
		st["prev_cam"] = cam
		st["prev_body"] = body
	gt(gs.glitches, 50, "the source glitched (%d)" % gs.glitches)
	eq(st["bad"], 0, "every rig node and telemetry value finite on every tick")
	# Per tick: heave change (<= a few cm perceived) + head yaw motion (the
	# eyes swing ~9 cm about the neck): 0.3 m perceived is a generous bound
	# that a NaN, a teleport or a 3 m tracker jump would blow through.
	lt(st["jump"], 0.3, "the view never jumps beyond the body's motion (m perceived per tick)")
	metric("glitches", gs.glitches)
	metric("max_view_excess_m", st["jump"])


# --- PB-20: head tracking lost for 1 s asks for the pause menu once -------------
func test_pb20_head_loss_requests_pause_once() -> void:
	await _fx(&"sparrow")
	var f := fx
	f.player.start_flying(Vector3(0, 300, 0), 0.0, 0.0)
	f.driver = func(_tick: int, t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		b.head_valid = not (t >= 1.0 and t < 3.0)
	var prev := Game.state
	var acc := {"menu": 0}
	var cb := func() -> void: acc["menu"] += 1
	Events.menu_requested.connect(cb)
	Game.set_state(Game.State.PLAYING)
	f.run(1.9)
	var paused_before := Game.state
	eq(acc["menu"], 0, "no pause request before 1 s of loss")
	f.run(0.2)
	eq(acc["menu"], 1, "one menu request after 1 s of head loss (the menu button's route)")
	eq(Game.state, Game.State.PAUSED, "no UI in this scene: paused directly")
	# Resumed while the head is still lost: no second request (edge-triggered).
	Game.set_state(Game.State.PLAYING)
	f.run(0.5)
	eq(acc["menu"], 1, "no repeat request while the same loss continues")
	Events.menu_requested.disconnect(cb)
	Game.set_state(prev)
	eq(paused_before, Game.State.PLAYING, "still playing at 0.9 s of loss")


# --- PB-21: nothing leaks (DoD: no leaks in its runs) ---------------------------
## Object and resource counts return to where they were after several full
## player lives: scripted flight, the bot pilot on the course, desktop keys,
## a perch capture and launch, respawn, growth, and a plot. Round 1 leaked
## ~5 objects per fixture (a fixture -> source -> lambda -> fixture cycle)
## and every FlightPlot (panel -> plot back-reference): 778 at suite exit.
func test_pb21_no_leaks() -> void:
	const BC := preload("res://tests/unit/flight/bot_course.gd")
	# Warm-up life (first-use caches: shaders, script statics, the reference
	# stroke table).
	await _life(BC)
	await get_tree().process_frame
	var o0 := Performance.get_monitor(Performance.OBJECT_COUNT)
	var r0 := Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT)
	var n0 := Performance.get_monitor(Performance.OBJECT_NODE_COUNT)
	for k in 3:
		await _life(BC)
	await get_tree().process_frame
	await get_tree().process_frame
	var o1 := Performance.get_monitor(Performance.OBJECT_COUNT)
	var r1 := Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT)
	var n1 := Performance.get_monitor(Performance.OBJECT_NODE_COUNT)
	metric("objects_before_after", [o0, o1])
	metric("resources_before_after", [r0, r1])
	metric("nodes_before_after", [n0, n1])
	lt(o1 - o0, 3.0, "objects after 3 more lives (before %d, after %d)" % [o0, o1])
	lt(r1 - r0, 1.0, "resources after 3 more lives (before %d, after %d)" % [r0, r1])
	lt(n1 - n0, 1.0, "nodes after 3 more lives (before %d, after %d)" % [n0, n1])


func _life(BC: GDScript) -> void:
	# Scripted flight with a perch capture, launch, respawn and growth.
	fx = FX.new(self)
	await fx.setup(&"sparrow", func(w: Variant) -> void:
		w.add_perch(Vector3(0, 20, -10), Vector3.FORWARD, 1.0))
	var p := fx.player
	p.start_flying(Vector3(0, 20.1, -8), 0.0, 0.0)
	p.model.reset(Vector3(0, 20.1, -8), Vector3(0, 0, -0.7 * p.model.params.v_min), 0.0)
	fx.driver = func(_tick: int, t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		if t > 2.0 and t < 3.0:
			ScriptedPoseSource.flap(b, t - 2.0, 45.0, 1.0)
	fx.on_tick = func(tick: int, f: Variant) -> void:
		if tick == 250:
			f.player.mass = 0.05
	fx.run(4.0)
	p.respawn(Transform3D(Basis.IDENTITY, Vector3(0, 40, 0)))
	fx.run(0.5)
	p.set_pose_source(DesktopPoseSource.new())
	fx.run(0.5)
	var pl := FlightPlot.new(400, 300, "leak check")
	var pn := pl.panel(Rect2i(20, 40, 360, 240), "p", "x", "y")
	pn.line(PackedFloat64Array([0, 1]), PackedFloat64Array([0, 1]), 0, "l")
	pl.render()
	fx.teardown()
	fx = null
	# The bot pilot on the course, 2 s.
	fx = FX.new(self)
	var b: RefCounted = BC.new(fx, &"pigeon")
	await b.call(&"setup")
	fx.run(2.0)
	fx.teardown()
	fx = null
	await get_tree().process_frame


# --- PB-22: record a real session, replay it (FLIGHT_SPEC R5) --------------------
## PlayerBird's recorder (Settings "record_poses" / --record-poses) writes
## what the pose source gave each tick; ReplayPoseSource played into a fresh
## PlayerBird flies the same flight: every stroke onset on the same tick and
## the path within millimetres (the file stores 1e-5 m / 1e-6 quaternions).
func test_pb22_record_and_replay_a_session() -> void:
	var path := Paths.artifacts("flight").path_join("pb22_session.jsonl")
	await _fx(&"sparrow")
	var f := fx
	var p := f.player
	p.recorder = PoseRecorder.new()
	check(p.recorder.start(path), "recorder opens its file")
	p.start_flying(Vector3(0, 200, 0), 0.0, 0.0)
	var cal := p.wing_input.calibration
	f.driver = func(_tick: int, t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		if t < 1.5:
			pass
		elif t < 5.0:
			ScriptedPoseSource.flap(b, t, 40.0, 1.0)
		elif t < 7.0:
			b.synth(0.2, 0.7, 1.0, cal)
		else:
			b.synth(-0.6, -0.4, 0.3, cal)
		b.head_yaw = 0.4 * sin(t)
		b.humanize(DT)
	var live := {"pos": [], "onsets": []}
	f.on_tick = func(tick: int, fix: Variant) -> void:
		live["pos"].append(fix.player.model.position)
		var w: WingState = fix.player.wing_state()
		if w.onset_l or w.onset_r:
			live["onsets"].append(tick)
	f.run(9.0)
	p.recorder.stop()
	var lines: int = p.recorder.lines
	fx.teardown()
	fx = null
	await _fx(&"sparrow")
	var g := fx
	var rp := ReplayPoseSource.new(path)
	eq(rp.samples.size(), lines, "the file holds one frame per tick (%d)" % lines)
	g.player.set_pose_source(rp)
	g.player.start_flying(Vector3(0, 200, 0), 0.0, 0.0)
	var rep := {"pos": [], "onsets": []}
	g.on_tick = func(tick: int, fix: Variant) -> void:
		rep["pos"].append(fix.player.model.position)
		var w: WingState = fix.player.wing_state()
		if w.onset_l or w.onset_r:
			rep["onsets"].append(tick)
	g.run(9.0)
	var worst := 0.0
	for i in mini(live["pos"].size(), rep["pos"].size()):
		worst = maxf(worst, (live["pos"][i] as Vector3).distance_to(rep["pos"][i]))
	eq(rep["onsets"], live["onsets"], "every stroke onset replays on the same tick")
	gt(live["onsets"].size(), 3, "the session flapped")
	lt(worst, 0.005, "the replayed flight follows the live one within 5 mm over 9 s (m)")
	metric("replay_path_error_m", worst)


# --- PB-24: a teleport while turning starts the view at rest (fix round 3) --------
## Round 3 verifier: respawn(), start_flying() and perch_on() kept the rig's
## yaw rate (and the body-steer lags), so after "Restart run" from a pause
## taken mid-turn the comfort clamp wound the old 206 deg/s down over the
## spawn: 28 deg of view rotation with no heading change, and body steer then
## launched the bird 30 deg off the respawn yaw. Pinned for every teleport,
## at the three sizes, straight out of a full-rate turn: the view holds the
## respawn yaw (< 1 deg) while SPAWNING, the bird launches along it (< 3 deg
## 2 s later), start_flying faces the view along the heading (< 2 deg for
## 1 s) and a forced perch never turns the view (< 1 deg).
func test_pb24_teleport_while_turning_starts_the_view_at_rest() -> void:
	for sp: StringName in [&"sparrow", &"pigeon", &"eagle"]:
		for kind in ["respawn", "start_flying", "perch_on"]:
			await _fx(sp, func(w: Variant) -> void:
				w.add_perch(Vector3(500, 60, 0), Vector3.FORWARD, 10.0))
			var p := fx.player
			p.start_flying(Vector3(0, 300, 0), 0.0, 0.0)
			fx.driver = fx.synth(0.0, 1.0)
			fx.run(3.0)
			var rate0 := rad_to_deg(p.rig_yaw_rate)
			gt(absf(rate0), 30.0, "%s %s: turning hard before the teleport (%.0f deg/s)" % [sp, kind, rate0])
			var yaw_t := 1.0
			fx.driver = func(_tick: int, _t: float, b: HumanPoseModel) -> void:
				b.set_airplane()
			var drift := 0.0
			var off := 0.0
			match kind:
				"respawn":
					p.respawn(Transform3D(Basis(Vector3.UP, yaw_t), Vector3(100, 200, 0)))
					for i in int(0.45 / DT):
						fx.step()
						drift = maxf(drift, absf(rad_to_deg(wrapf(p.rig_yaw - yaw_t, -PI, PI))))
					fx.run(2.0)
					off = absf(rad_to_deg(wrapf(p.model.heading() - yaw_t, -PI, PI)))
					lt(off, 3.0, "%s respawn: the bird launches along the respawn yaw (deg)" % sp)
				"start_flying":
					p.start_flying(Vector3(100, 300, 0), yaw_t, 0.0)
					for i in int(1.0 / DT):
						fx.step()
						drift = maxf(drift, absf(rad_to_deg(wrapf(p.rig_yaw + p.wing_state().body_yaw - p.model.heading(), -PI, PI))))
				"perch_on":
					var yaw0 := p.rig_yaw
					p.perch_on(fx.world.get_perches()[0])
					for i in int(0.5 / DT):
						fx.step()
						drift = maxf(drift, absf(rad_to_deg(wrapf(p.rig_yaw - yaw0, -PI, PI))))
					eq(p.mode, PlayerBird.Mode.PERCHED, "%s perch_on: perched" % sp)
			lt(drift, 2.0 if kind == "start_flying" else 1.0, "%s %s out of a %.0f deg/s turn: the view does not keep turning (deg)" % [sp, kind, rate0])
			fx.assert_comfort(self, "%s %s" % [sp, kind])
			metric("%s_%s" % [sp, kind], {"rate_before": rate0, "view_drift_deg": drift, "launch_off_deg": off})
			fx.teardown()
			fx = null


## The same through the game's real path: the tree paused mid-turn (the pause
## menu), respawn (Restart run -> GameLoop -> respawn), unpause.
func test_pb24_restart_from_a_real_pause_mid_turn() -> void:
	var w := FX.TW.new()
	add_child(w)
	var p := PLAYER.instantiate() as PlayerBird
	p.use_settings = false
	p.default_source = &"none"
	p.mass = FlightParams.species_mass(&"sparrow")
	p.drive_world_scale = true
	add_child(p)
	await get_tree().physics_frame
	var body := HumanPoseModel.new(3)
	var cal := p.wing_input.calibration
	var roll := [1.0]
	var src := ScriptedPoseSource.new(body, func(_tick: int, _t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		if roll[0] != 0.0:
			b.synth(0.0, roll[0], 1.0, cal))
	p.set_pose_source(src)
	p.start_flying(Vector3(0, 300, 0), 0.0, 0.0)
	await wait_physics(int(0.7 * Engine.physics_ticks_per_second))
	get_tree().paused = true
	await wait_physics(5)
	var rate0 := rad_to_deg(p.rig_yaw_rate)
	gt(absf(rate0), 100.0, "turning hard when paused (%.0f deg/s)" % rate0)
	var yaw_t := 0.3
	p.respawn(Transform3D(Basis(Vector3.UP, yaw_t), Vector3(0, 60, 0)))
	roll[0] = 0.0
	get_tree().paused = false
	var drift := 0.0
	for i in int(0.45 * Engine.physics_ticks_per_second):
		await get_tree().physics_frame
		drift = maxf(drift, absf(rad_to_deg(wrapf(p.rig_yaw - yaw_t, -PI, PI))))
	lt(drift, 1.0, "real tree: after Restart run from a pause taken mid-turn the view holds the respawn yaw (deg)")
	metric("real_tree_restart", {"rate_before": rate0, "view_drift_deg": drift})
	src.driver = Callable()
	remove_child(p)
	p.free()
	remove_child(w)
	w.free()


# --- PB-25: the World is found late; in_updraft; the groups -----------------------
## ARCHITECTURE §3: singletons may appear late. Round 2 looked for the World
## once, at spawn: a World added (or regenerated) afterwards brought no wind,
## no perches and no ground. Also pins two contract items no test read
## (verifier round 3: their mutants survived): the telemetry key in_updraft
## (audio and haptics read it) is the vertical wind at the body, and the
## PlayerBird is in the groups player and birds.
func test_pb25_late_world_in_updraft_and_groups() -> void:
	var p := PLAYER.instantiate() as PlayerBird
	p.auto_process = false
	p.use_settings = false
	p.default_source = &"none"
	p.mass = FlightParams.species_mass(&"pigeon")
	add_child(p)
	await get_tree().process_frame
	check(p.is_in_group(&"player"), "PlayerBird is in group player (ARCHITECTURE §3)")
	check(p.is_in_group(&"birds"), "PlayerBird is in group birds")
	check(get_tree().get_first_node_in_group(&"player_rig") == p.origin, "group player_rig is the XROrigin3D")
	p.start_flying(Vector3(0, 50, 0), 0.0, 0.0)
	for i in 10:
		p.tick(DT)
	near(float(p.telemetry()["in_updraft"]), 0.0, 1e-9, "no World: in_updraft 0")
	var w := FX.TW.new()
	w.uniform_wind = Vector3(0, 3.0, 0)
	add_child(w)
	await get_tree().physics_frame
	await get_tree().physics_frame
	for i in 72:
		p.tick(DT)
	var t := p.telemetry().duplicate()
	near(float(t["in_updraft"]), 3.0, 1e-6, "a World added after the player: in_updraft is its 3 m/s updraft")
	near(float(t["altitude_agl"]), p.model.position.y - w.ground_height(p.model.position.x, p.model.position.z), 1e-6,
		"a World added after the player: AGL from its ground")
	gt(p.model.velocity.y, -0.5, "a World added after the player: its updraft carries the bird")
	w.uniform_wind = Vector3(0, -2.0, 0)
	p.tick(DT)
	near(float(p.telemetry()["in_updraft"]), 0.0, 1e-9, "sink: in_updraft is 0, not negative")
	metric("late_world", {"in_updraft": t["in_updraft"], "vy": p.model.velocity.y})
	remove_child(p)
	p.free()
	remove_child(w)
	w.free()


# --- PB-26: a gust front turns the view smoothly ----------------------------------
## Round 3 verifier: a 2.64 m/s crosswind front ramped over 0.5 s stepped the
## rig's yaw rate in one tick (720 deg/s^2, the cap) because the heading
## followed the air path instantly. The body now lags the air in the
## sideslip channel and weathercocks round. Pinned at three sizes: the view's
## yaw acceleration stays under 150 deg/s^2 (0.5 s ramp) and 60 (2 s), the
## comfort safety net never acts, the heading turns into the wind by 0.25-0.5
## of the air path's turn and settles (< 1 deg/s after 9 s).
func test_pb26_gust_front_turns_the_view_smoothly() -> void:
	for sp: StringName in [&"sparrow", &"pigeon", &"eagle"]:
		# The slow ramp only for the sparrow (its air path turns most).
		for ramp in ([0.5, 2.0] if sp == &"sparrow" else [0.5]):
			await _fx(sp)
			var p := fx.player
			var w: Variant = fx.world
			p.start_flying(Vector3(0, 400, 0), 0.0, 0.0)
			var v0 := p.model.airspeed()
			var st := {"acc": 0.0, "rate": 0.0, "h0": 0.0, "late": 0.0}
			fx.on_tick = func(tick: int, f: Variant) -> void:
				var t := tick * DT
				var k := clampf((t - 3.0) / ramp, 0.0, 1.0)
				f.world.uniform_wind = Vector3(2.64 * k, 0, 0)
				var pl: PlayerBird = f.player
				if t < 3.0:
					st["h0"] = pl.model.heading()
					return
				st["acc"] = maxf(st["acc"], absf(pl.rig_yaw_accel))
				st["rate"] = maxf(st["rate"], absf(pl.rig_yaw_rate))
				if t > 12.0:
					st["late"] = maxf(st["late"], absf(pl.rig_yaw_rate))
			fx.run(13.0)
			var tag := "%s ramp %.1f s" % [sp, ramp]
			var turn := rad_to_deg(FlightMath.wrap_angle(p.model.heading() - float(st["h0"])))
			var air_turn := rad_to_deg(atan2(2.64, v0))
			lt(rad_to_deg(st["acc"]), 150.0 if ramp < 1.0 else 60.0, "%s: the view's yaw acceleration stays gentle (deg/s^2)" % tag)
			eq(p.rig_limited_ticks, 0, "%s: the comfort safety net never acts" % tag)
			between(turn / air_turn, 0.25, 0.5, "%s: the heading turns into the wind by part of the air path's turn (%.1f of %.1f deg)" % [tag, turn, air_turn])
			lt(rad_to_deg(st["late"]), 1.0, "%s: the turn settles (deg/s after 9 s)" % tag)
			fx.assert_comfort(self, tag)
			metric(tag.replace(" ", "_"), {"max_accel": rad_to_deg(st["acc"]), "max_rate": rad_to_deg(st["rate"]), "turn_deg": turn, "air_turn_deg": air_turn})
			fx.teardown()
			fx = null


# --- PB-27: natural asymmetry in a symmetric stroke never shakes the view -------
## Round-4 experience verifier: through the arms each wing's force followed
## that wing's instantaneous normal, which droops 20-45 deg late in the
## downstroke, and the roll kick and paddle yaw read the instantaneous flap
## difference: one arm 10 % smaller or 30 ms late wobbled a sparrow's view
## 5.5-6.8 deg every wingbeat, 25 % and 60 ms 12-15 deg with 30-47 deg of
## drift in 10 s (perfectly even strokes: 0). Now the wing's force across the
## body is not applied, and the kick acts on the stroke-mean effort asymmetry
## beyond a dead zone (human arms up to ~25 % unequal are a symmetric stroke).
## Pinned at three sizes, reference strokes (1 Hz, 45 deg) with the right arm
## 20 % smaller or larger, 50 ms late or early, and 20 % smaller and 50 ms
## late; and a sparrow's brisk 2 Hz 30 deg stroke 20 % uneven: the view's
## yaw wobble per wingbeat (peak-to-peak about its 1 s moving mean) < 1 deg,
## its mean drift < 1 deg/s, and the specific force across the body (what a
## rider would feel sideways) within 0.05 g.
static func _wobble(yaws: PackedFloat64Array, half: int) -> float:
	var lo := INF
	var hi := -INF
	for i in range(half, yaws.size() - half):
		var m := 0.0
		for k in range(-half, half + 1):
			m += yaws[i + k]
		m /= 2 * half + 1
		lo = minf(lo, yaws[i] - m)
		hi = maxf(hi, yaws[i] - m)
	return hi - lo


## The specific force (m/s^2, g units) along the banked body's right axis:
## zero in a coordinated turn, the sideways shove a rider feels otherwise.
static func _lat_g(m: FlightModel) -> float:
	var rh := Vector3(cos(m.chi), 0.0, -sin(m.chi))
	var r_b := rh * cos(m.phi) - Vector3.UP * sin(m.phi)
	return (m.last_accel() + Vector3(0.0, FlightMath.G, 0.0)).dot(r_b) / FlightMath.G


func _uneven(sp: StringName, hz: float, amp: float, k_r: float, lag: float) -> Dictionary:
	await _fx(sp)
	var p := fx.player
	p.start_flying(Vector3(0, 400, 0), 0.0, 0.0)
	fx.run(0.5)
	fx.driver = func(_tick: int, t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		ScriptedPoseSource.flap(b, maxf(t + minf(lag, 0.0), 0.0), amp, hz, -1)
		ScriptedPoseSource.flap(b, maxf(t - maxf(lag, 0.0), 0.0), amp * k_r, hz, 1)
	var yaws := PackedFloat64Array()
	var st := {"unwrap": 0.0, "prev": p.rig_yaw, "lat": 0.0}
	fx.on_tick = func(tick: int, f: Variant) -> void:
		var pl: PlayerBird = f.player
		st["unwrap"] += FlightMath.wrap_angle(pl.rig_yaw - float(st["prev"]))
		st["prev"] = pl.rig_yaw
		if tick * DT > 2.5:
			yaws.append(rad_to_deg(st["unwrap"]))
			st["lat"] = maxf(st["lat"], absf(_lat_g(pl.model)))
	fx.run(5.5)
	var drift := (yaws[yaws.size() - 1] - yaws[0]) / ((yaws.size() - 1) * DT)
	var out := {"wobble": _wobble(yaws, int(0.5 / DT)), "drift": drift, "lat": st["lat"]}
	fx.assert_comfort(self, "%s uneven" % sp)
	fx.teardown()
	fx = null
	return out


func test_pb27_uneven_symmetric_strokes_never_shake_the_view() -> void:
	var worst := {"wobble": 0.0, "drift": 0.0, "lat": 0.0}
	var cases := [[1.0, 45.0, 0.8, 0.0], [1.0, 45.0, 1.2, 0.0], [1.0, 45.0, 1.0, 0.05], [1.0, 45.0, 1.0, -0.05], [1.0, 45.0, 0.8, 0.05]]
	var full := Paths.arg("full", "") != ""
	for sp: StringName in [&"sparrow", &"pigeon", &"eagle"]:
		# Default (the 60 s budget): every case at the sparrow (the lightest
		# bird, the largest per-stroke kicks), the combined case at the
		# others; --full: every case at every size.
		var set_: Array = cases.duplicate() if (full or sp == &"sparrow") else [cases[4]]
		if sp == &"sparrow":
			set_.append([2.0, 30.0, 0.8, 0.0])
		for c in set_:
			var r: Dictionary = await _uneven(sp, c[0], c[1], c[2], c[3])
			var tag := "%s %.0f Hz %.0f deg, right x%.1f, %+.0f ms" % [sp, c[0], c[1], c[2], 1000.0 * float(c[3])]
			lt(float(r["wobble"]), 1.0, "%s: view yaw wobble per wingbeat (deg p-p)" % tag)
			lt(absf(float(r["drift"])), 1.0, "%s: mean drift (deg/s)" % tag)
			lt(float(r["lat"]), 0.05, "%s: sideways specific force (g)" % tag)
			worst["wobble"] = maxf(worst["wobble"], r["wobble"])
			worst["drift"] = maxf(worst["drift"], absf(float(r["drift"])))
			worst["lat"] = maxf(worst["lat"], r["lat"])
	metric("worst", worst)


# --- PB-28: one-arm strokes turn the bird away, the same way every stroke --------
## Round-4 experience verifier: a single left stroke turned the bird right
## (FM-18, the desktop Q/E help: "roll and yaw kick away"), but sustained
## left strokes turned the pigeon 47 deg and the eagle 15 deg LEFT, banked
## right, because each drooped wing shoved the body toward its own side at up
## to 0.76 g. Pinned through the arms at three sizes: 10 one-arm reference
## strokes, each wing, turn the bird away from the stroking wing every second
## after the first (no reversal), by >= 20 deg in all, mirror-symmetric,
## banked the way it turns (coordinated), sideslip < 5 deg, and the sideways
## specific force within 0.08 g (round 3: 0.76 g).
func test_pb28_one_arm_strokes_turn_away_consistently() -> void:
	for sp: StringName in [&"sparrow", &"pigeon", &"eagle"]:
		var res := {}
		for side in [-1, 1]:
			await _fx(sp)
			var p := fx.player
			p.start_flying(Vector3(0, 400, 0), 0.0, 0.0)
			fx.run(0.5)
			var s: int = side
			fx.driver = func(_tick: int, t: float, b: HumanPoseModel) -> void:
				b.set_airplane()
				if t < 10.25:
					ScriptedPoseSource.flap(b, t + 0.25, 45.0, 1.0, s)
			var h0 := p.model.heading()
			var st := {"bank": 0.0, "n": 0, "slip": 0.0, "lat": 0.0}
			fx.on_tick = func(_tick: int, f: Variant) -> void:
				var m: FlightModel = f.player.model
				st["bank"] += m.phi
				st["n"] += 1
				st["slip"] = maxf(st["slip"], absf(m.dpsi))
				st["lat"] = maxf(st["lat"], absf(_lat_g(m)))
			var per_s := PackedFloat64Array()
			var hp := h0
			for k in 10:
				fx.run(1.0)
				per_s.append(rad_to_deg(FlightMath.wrap_angle(p.model.heading() - hp)))
				hp = p.model.heading()
			res[side] = {"turn": rad_to_deg(FlightMath.wrap_angle(p.model.heading() - h0)), "per_s": per_s,
				"bank": rad_to_deg(st["bank"] / maxf(st["n"], 1)), "slip": rad_to_deg(st["slip"]), "lat": st["lat"]}
			fx.assert_comfort(self, "%s one arm %d" % [sp, side])
			fx.teardown()
			fx = null
		for side in [-1, 1]:
			var r: Dictionary = res[side]
			# Away from the stroking wing: a left stroke turns right (heading
			# decreases), a right stroke turns left.
			var away := float(side)
			var tag := "%s %s-arm strokes" % [sp, "left" if side < 0 else "right"]
			gt(float(r["turn"]) * away, 20.0, "%s: turn away from the stroking wing in 10 s (deg)" % tag)
			var reversals := 0
			for k in range(1, 10):
				if float(r["per_s"][k]) * away < 0.0:
					reversals += 1
			eq(reversals, 0, "%s: every second after the first turns the same way (%s)" % [tag, str(r["per_s"])])
			# Coordinated: a right bank (+) turns right (heading decreasing).
			check(signf(float(r["bank"])) == -away, "%s: banked the way it turns (mean bank %+.1f deg)" % [tag, r["bank"]])
			lt(float(r["slip"]), 5.0, "%s: sideslip (deg)" % tag)
			# What is left is the paddle yaw's own sideslip force (the yaw part
			# of a one-wing turn; 0.02-0.055 g measured). Round 3: 0.76 g.
			lt(float(r["lat"]), 0.08, "%s: sideways specific force (g)" % tag)
		near(float(res[-1]["turn"]), -float(res[1]["turn"]), 2.0, "%s: left and right mirror (deg)" % sp)
		metric(String(sp), {"left_turn": res[-1]["turn"], "right_turn": res[1]["turn"], "bank": res[-1]["bank"],
			"slip": res[-1]["slip"], "lat_g": res[-1]["lat"]})


# --- PB-19b: a long frame hitch advances the flight by 0.1 s at most -------------
## The documented tick contract (tick() clamps dt to 0.1 s: a hitch loses
## time instead of feeding every filter one enormous step) was not pinned
## (round-4 engineering verifier: removing the clamp passed every test).
func test_pb19b_a_hitch_advances_at_most_a_tenth_of_a_second() -> void:
	await _fx(&"pigeon")
	var p := fx.player
	p.start_flying(Vector3(0, 300, 0), 0.0, 0.0)
	fx.run(0.5)
	var v := p.model.velocity.length()
	var x0 := p.model.position
	p.tick(1.0)
	var moved := p.model.position.distance_to(x0)
	lt(moved, 0.1 * v * 1.05 + 0.02, "a 1 s tick moves the bird at most 0.1 s of flight (m, V %.1f m/s)" % v)
	gt(moved, 0.1 * v * 0.8, "... and does advance it (m)")
	check(FlightMath.vfinite(p.model.position) and FlightMath.vfinite(p.model.velocity), "finite after the hitch")
	metric("moved_m", moved)


# --- PB-29: resuming from the pause menu is no wingbeat and no manoeuvre ----------
## The round-5 experience verifier's scenario: paused mid-flight, the player
## points at "Resume" (right arm raised 35 deg and swept 60 deg forward, the
## left hanging at the side, head turned 20 deg, 0.5 m walked) and then
## spreads the arms again over 0.8 s. Round 4 trusted the new poses but kept
## the stroke detectors: the pigeon and eagle got a credited downstroke 0.3-
## 0.4 s after resume (player_flapped, 0.36 of the weight in flap force), and
## the arms' way back flew at full authority (up to 70 deg of bank and 79 deg
## of view turn in 3 s). Now: no stroke carries over the pause, and the
## controls stay neutral until the arms are out and settled, then fade in.
## They do come back: a wrist roll 1.5 s after resume banks the bird.
func test_pb29_resume_from_the_pause_menu_is_no_wingbeat() -> void:
	for sp: StringName in [&"sparrow", &"pigeon", &"eagle"]:
		await _fx(sp)
		var p := fx.player
		var cal := p.wing_input.calibration
		p.start_flying(Vector3(0, 120, 0), 0.0, 0.0)
		var st := {"phase": 0, "t_res": 0.0}
		fx.driver = func(_tick: int, t: float, b: HumanPoseModel) -> void:
			b.set_airplane()
			if int(st["phase"]) >= 1:
				var k := clampf((t - float(st["t_res"])) / 0.8, 0.0, 1.0)
				var e := k * k * (3.0 - 2.0 * k)
				b.arms[0].dihedral = lerpf(-80.0 * DEG, 0.0, e)
				b.arms[1].dihedral = lerpf(35.0 * DEG, 0.0, e)
				b.arms[1].sweep = lerpf(60.0 * DEG, 0.0, e)
				b.arms[1].elbow = lerpf(20.0 * DEG, 0.0, e)
				b.head_yaw = lerpf(20.0 * DEG, 0.0, e)
				b.room_offset = Vector3(0.3, 0.0, -0.4)
			if int(st["phase"]) == 2:
				b.synth(0.0, 0.6, 1.0, cal)
		fx.run(2.0)
		var hdg0 := p.model.heading()
		st["phase"] = 1
		st["t_res"] = fx.src.tick * DT
		p.notification(Node.NOTIFICATION_UNPAUSED)
		fx.reset_events()
		fx.reset_comfort()
		var mx := {"bank": 0.0, "flapf": 0.0, "rate": 0.0}
		fx.on_tick = func(_i: int, f: Variant) -> void:
			var pl: PlayerBird = f.player
			mx["bank"] = maxf(mx["bank"], absf(pl.model.phi))
			mx["flapf"] = maxf(mx["flapf"], absf(pl.model.flap_n))
			mx["rate"] = maxf(mx["rate"], absf(pl.rig_yaw_rate))
		fx.run(3.0)
		var dh := rad_to_deg(absf(FlightMath.wrap_angle(p.model.heading() - hdg0)))
		var w := p.mass * FlightMath.G
		eq(fx.events["flapped"], 0, "%s: no wingbeat from the resume" % sp)
		lt(float(mx["flapf"]) / w, 0.01, "%s: no flap force from the resume (x weight; round 4 0.36)" % sp)
		lt(rad_to_deg(mx["bank"]), 3.0, "%s: bank while the arms come back (deg; round 4 56-71)" % sp)
		lt(dh, 3.0, "%s: heading change in the 3 s after resume (deg; round 4 30-79)" % sp)
		fx.assert_comfort(self, "%s resume" % sp)
		# The controls are back: a wrist roll now banks the bird.
		st["phase"] = 2
		mx["bank"] = 0.0
		fx.run(1.5)
		gt(rad_to_deg(mx["bank"]), 10.0, "%s: a roll input after resume banks the bird (deg)" % sp)
		metric(String(sp), {"flap_force_w": float(mx["flapf"]) / w, "heading_deg": dh})
		fx.teardown()
		fx = null


# --- PB-30: a recenter during a view payout stops the rig's own turn -----------------
## Round-5 engineering verifier: the recenter branch snapped rig_yaw and
## dropped the debt but kept the rig's yaw rate, so the rig turned on the old
## way, braking at the 720 deg/s^2 safety net (8 ticks, up to v^2/2a = 10 deg
## at a 120 deg/s payout), and owed that back: every in-air safety-net tick
## of its random play. Now the rig's turn stops with the snap.
func test_pb30_recenter_during_a_view_payout() -> void:
	for sp: StringName in [&"sparrow", &"eagle"]:
		await _fx(sp, func(w: Variant) -> void:
			w.add_wall(Vector3(0, 40, -30), Vector3(80, 80, 1)))
		var p := fx.player
		var v := p.model.params.v_c
		p.start_flying(Vector3(0, 40, -30 + 0.3 * v + 0.5), 0.0, 0.0)
		var i := 0
		while i < 400 and not (p.view_turn.active() and absf(p.view_turn.rate) > deg_to_rad(60.0)):
			fx.step()
			i += 1
		check(absf(p.view_turn.rate) > deg_to_rad(60.0), "%s: the view is paying a stun's turn" % sp)
		var paying := rad_to_deg(p.view_turn.rate)
		Events.recenter_requested.emit()
		var lim0 := p.rig_limited_ticks
		fx.step()
		var r1 := rad_to_deg(p.rig_yaw_rate)
		var old_way := 0.0
		var prev := p.rig_yaw
		var sgn := signf(paying)
		for k in 144:
			fx.step()
			var d := wrapf(p.rig_yaw - prev, -PI, PI)
			prev = p.rig_yaw
			if k < 12 and signf(d) == sgn:
				old_way += absf(d)
		eq(p.rig_limited_ticks - lim0, 0, "%s: no safety-net tick after the recenter (round 5 verifier: 8)" % sp)
		lt(absf(r1), 10.0, "%s: the rig's rate right after the snap (deg/s; the payout was %.0f)" % [sp, paying])
		lt(rad_to_deg(old_way), 1.0, "%s: the rig does not run on the old way (deg in 1/6 s)" % sp)
		fx.assert_comfort(self, "%s recenter mid-payout" % sp)
		metric(String(sp), {"paying": paying, "rate_after": r1, "old_way_deg": rad_to_deg(old_way)})
		fx.teardown()
		fx = null


# --- PB-31: frame hitches never turn slow arm motion into flaps --------------------
## A 0.1 s tick every 0.5 s (tick(dt) with a real long frame) while the arms
## sweep slowly (+-25 deg at 0.25 Hz, far below a stroke). Round 4 clamped
## the detectors' dt to 1/30 s, read the hitch's hand motion 3x too fast and
## flapped 4 times in 20 s (round-5 engineering verifier). The engine's own
## pattern (fixed ticks, one XR pose per frame) is WI-34.
func test_pb31_long_ticks_never_flap_slow_arms() -> void:
	for sp: StringName in [&"sparrow", &"eagle"]:
		await _fx(sp)
		var p := fx.player
		p.start_flying(Vector3(0, 300, 0), 0.0, 0.0)
		var clk := {"t": 0.0}
		fx.driver = func(_tick: int, _t: float, b: HumanPoseModel) -> void:
			b.set_airplane()
			var e := deg_to_rad(25.0) * sin(TAU * 0.25 * float(clk["t"]))
			b.arms[0].dihedral = e
			b.arms[1].dihedral = e
		fx.reset_events()
		var t := 0.0
		var i := 0
		var fmax := 0.0
		while t < 8.0:
			var dt := 0.1 if i % 36 == 18 else DT
			# The pose at the end of the tick: tick(dt) covers dt of the arms'
			# motion (a pose that jumps inside a normal-length tick is an engine
			# frame's: WI-34).
			t += dt
			clk["t"] = t
			p.tick(dt)
			fmax = maxf(fmax, maxf(p.wing_input.state.flap_l, p.wing_input.state.flap_r))
			i += 1
		eq(fx.events["flapped"], 0, "%s: 0.1 s ticks among slow arm sweeps flap nothing" % sp)
		lt(fmax, 0.05, "%s: and add no flap effort" % sp)
		fx.teardown()
		fx = null


# --- PB-32: growth ramps world_scale; the near plane and the XR nodes follow --------
## Flight's fallback growth driver (the lab; the VR area's WorldScaleDriver in
## the game): the scale moves in log space at most world_scale_ramp per
## second and reaches its target; the camera's near plane is 0.03 x
## world_scale (min 1 mm, Quest rule 7.5) on every tick (round-5 engineering
## verifier: neither was pinned). A snap (the first tick) rescales the
## tracked nodes at once: the XR server writes them with the new scale only
## at its next update, and round 4's lab read the head 1.04 m off the body
## on its first XR tick.
func test_pb32_growth_ramps_world_scale_and_the_rig_follows() -> void:
	await _fx(&"sparrow")
	var p := fx.player
	p.start_flying(Vector3(0, 200, 0), 0.0, 0.0)
	fx.run(0.5)
	var ws0 := p.origin.world_scale
	p.mass = FlightParams.species_mass(&"pigeon")
	var st := {"worst_step": 0.0, "near_bad": 0, "t_done": -1.0, "prev": ws0}
	fx.on_tick = func(i: int, f: Variant) -> void:
		var pl: PlayerBird = f.player
		var ws := pl.origin.world_scale
		st["worst_step"] = maxf(st["worst_step"], absf(log(ws) - log(float(st["prev"]))))
		st["prev"] = ws
		if absf(pl.camera.near - maxf(0.001, PlayerBird.NEAR_PER_WORLD_SCALE * ws)) > 1e-7:
			st["near_bad"] += 1
		if float(st["t_done"]) < 0.0 and absf(ws / pl.world_scale_target - 1.0) < 1e-6:
			st["t_done"] = i * DT
	var t0 := fx.ticks * DT
	fx.run(8.0)
	var ramp := p.tuning.world_scale_ramp
	lt(float(st["worst_step"]), ramp * DT * (1.0 + 1e-4), "world_scale moves at most ramp x dt per tick in log space")
	eq(st["near_bad"], 0, "camera near = max(0.001, NEAR_PER_WORLD_SCALE (%.2f) x world_scale) on every tick" % PlayerBird.NEAR_PER_WORLD_SCALE)
	var t_need := absf(log(p.world_scale_target / ws0)) / ramp
	between(float(st["t_done"]) - t0, t_need - 0.05, t_need + 0.1, "reaches the target at the ramp (s)")
	fx.teardown()
	fx = null
	# The first tick's snap with XR-style nodes: written at world_scale 1 by the
	# "server" before the tick, read again before its next update.
	await _fx(&"sparrow")
	p = fx.player
	var xs := XRPoseSource.new(p.origin, p.camera, p.left_hand, p.right_hand)
	xs.assume_tracked = true
	p.set_pose_source(xs)
	var body := HumanPoseModel.new(3)
	body.set_airplane()
	var truth := PoseFrame.new()
	body.frame(truth)
	var server := func(ws: float) -> void:
		p.camera.transform = Transform3D(truth.head.basis, truth.head.origin * ws)
		p.left_hand.transform = Transform3D(truth.left.basis, truth.left.origin * ws)
		p.right_hand.transform = Transform3D(truth.right.basis, truth.right.origin * ws)
	p.origin.world_scale = 1.0
	server.call(1.0)
	p.start_flying(Vector3(0, 200, 0), 0.0, 0.0)
	var worst := 0.0
	for k in 12:
		p.tick(DT)
		var off: Vector3 = p.call(&"view_offset") if p.has_method(&"view_offset") else Vector3.UP * p.heave_offset()
		var err := p.camera.global_position.distance_to(p.model.position + off)
		worst = maxf(worst, err)
		if k >= 1:
			server.call(p.origin.world_scale)   # the server's next update
	gt(1.0 - p.origin.world_scale, 0.5, "the first tick snapped world_scale (%.3f)" % p.origin.world_scale)
	lt(worst, 0.001, "camera on the body on every tick through the snap (m; round 4 lab: 1.04)")
	metric("snap_worst_cam_err_m", worst)


# --- PB-33: the game's own XR source is frame-timed ------------------------------------
## The round-5 hitch fix reaches the game through PlayerBird's default XR
## source (default_source "xr", or "auto" with VR on): it must stamp its
## samples with the real pose interval (XRPoseSource.frame_timing). The
## round-6 engineering verifier deleted that one line and every test still
## passed (WI-34 builds its own source). Here WI-34's slow sweeps run through
## the player's own source: an emulated engine clock, a 100 ms hitch every
## 0.5 s (7 ticks on one pose), the XR "server" writing the tracked nodes
## once per engine frame. 0 flaps; the same run with frame timing switched
## off on that source flaps (the defect this pins is live).
func _game_xr_hitch_run(timing: bool) -> Dictionary:
	var w := preload("res://tests/unit/flight/flight_test_world.gd").new()
	add_child(w)
	var p := PLAYER.instantiate() as PlayerBird
	p.auto_process = false
	p.use_settings = false
	p.default_source = &"xr"
	p.mass = FlightParams.species_mass(&"pigeon")
	add_child(p)
	p.auto_calibrate = false
	var xs := p.pose_source as XRPoseSource
	var out := {"is_xr": xs != null, "timed": xs != null and xs.frame_timing, "flaps": 0}
	if xs == null:
		p.queue_free()
		w.queue_free()
		return out
	xs.assume_tracked = true
	xs.frame_timing = timing
	var clock := {"frame": 0, "t": 0.0}
	xs.clock = func() -> Vector2: return Vector2(float(clock["frame"]), float(clock["t"]))
	var conn := func(_s: int, _st: float) -> void: out["flaps"] += 1
	Events.player_flapped.connect(conn)
	p.start_flying(Vector3(0, 300, 0), 0.0, 0.0)
	var body := HumanPoseModel.new(3)
	var truth := PoseFrame.new()
	var real_t := 0.0
	while real_t < 10.0:
		var ticks := 7 if int(clock["frame"]) % 36 == 35 else 1
		real_t += ticks * DT
		clock["frame"] = int(clock["frame"]) + 1
		clock["t"] = real_t
		body.set_airplane()
		var e := deg_to_rad(25.0) * sin(TAU * 0.25 * real_t)
		body.arms[0].dihedral = e
		body.arms[1].dihedral = e
		body.frame(truth)
		var ws := p.origin.world_scale
		p.camera.transform = Transform3D(truth.head.basis, truth.head.origin * ws)
		p.left_hand.transform = Transform3D(truth.left.basis, truth.left.origin * ws)
		p.right_hand.transform = Transform3D(truth.right.basis, truth.right.origin * ws)
		for k in ticks:
			p.tick(DT)
	Events.player_flapped.disconnect(conn)
	remove_child(p)
	p.free()
	remove_child(w)
	w.free()
	return out


func test_pb33_the_game_xr_source_is_frame_timed() -> void:
	var r: Dictionary = _game_xr_hitch_run(true)
	check(bool(r["is_xr"]), "default_source xr: the player's pose source is an XRPoseSource")
	# Read before the run switched it: the player's own wiring.
	check(bool(r["timed"]), "the player's XR source stamps the real pose interval (frame_timing)")
	eq(r["flaps"], 0, "slow sweeps through 100 ms engine hitches on the player's own XR source: no flap")
	var off: Dictionary = _game_xr_hitch_run(false)
	gt(off["flaps"], 0, "the same hitches with frame timing off flap (the defect this pins)")
	metric("flaps", {"timed": r["flaps"], "untimed": off["flaps"]})


# --- PB-34: telemetry read inside an event handler -------------------------------------
## telemetry() is built on the first read in a tick (round 5). A read from
## inside an Events handler (player_perched fires at the touchdown, before
## the rig and the legs are placed) must not hold those mid-tick values for
## the rest of the tick: the next read after the tick is the finished tick's
## (the round-6 engineering verifier found altitude_agl and heave_offset
## stuck). No consumer reads in a handler today (audio, haptics and
## onboarding poll); this keeps the contract's "same values" true.
func test_pb34_telemetry_read_in_a_handler_is_not_kept() -> void:
	await _fx(&"sparrow")
	var p := fx.player
	var pr := p.model.params
	var start := Vector3(0, pr.r_body + 0.25, 0)
	p.start_flying(start, 0.0, 0.0)
	p.model.reset(start, Vector3(0, -0.2 * pr.v_min, -0.6 * pr.v_min), 0.0)
	var st := {"mid": {}, "tick": -1}
	var conn := func(_pos: Vector3) -> void:
		if st["mid"].is_empty():
			st["mid"] = p.telemetry().duplicate()
			st["tick"] = p.tick_count
	Events.player_perched.connect(conn)
	var k := 0
	while (st["mid"] as Dictionary).is_empty() and k < 144:
		fx.step()
		k += 1
	Events.player_perched.disconnect(conn)
	check(not (st["mid"] as Dictionary).is_empty(), "touched down (player_perched)")
	eq(p.tick_count, int(st["tick"]), "the read after the touchdown tick is in the same tick")
	var after: Dictionary = p.telemetry().duplicate()
	p._tel_tick = -1
	var fresh: Dictionary = p.telemetry()
	var differ := PackedStringArray()
	var mid_differ := PackedStringArray()
	for key in fresh:
		if str(after.get(key)) != str(fresh[key]):
			differ.append(key)
		if str((st["mid"] as Dictionary).get(key)) != str(fresh[key]):
			mid_differ.append(key)
	eq(differ.size(), 0, "the read after the tick equals the finished tick's build (keys that differ: %s)" % ", ".join(differ))
	gt(mid_differ.size(), 0, "the handler's read was mid-tick (it differs: %s)" % ", ".join(mid_differ))


# --- Integration round 2: the player's turn-speed comfort choice ---------------
## Settings "turn_comfort" caps how fast the view (and the bird: the bank
## limit, FlightModel's comfort caps) turns: a sparrow at full input yawed
## the view at ~205 deg/s with no player setting (both round-2 verifiers).
## Each step's cap holds at full input, the game's default (Brisk) is 180
## deg/s, and the gentlest (90 deg/s) still turns the bird.
func test_pb28_turn_comfort_setting_caps_the_turn() -> void:
	var saved: Variant = Settings.get_value("turn_comfort")
	# The full-input turn below banks with arms and wrists together; pin the
	# spec tilt direction (the playtest default inverts it).
	var pinned := {"dev_tilt_invert": false, "dev_turn_deadzone": 0.2, "dev_turn_sensitivity": 1.0, "dev_turn_curve": 0.1}
	var saved_dev := {}
	for k in pinned:
		saved_dev[k] = Settings.get_value(k)
		Settings.set_value(k, pinned[k])
	eq(float(Settings.DEFAULTS["turn_comfort"]), 0.75, "the default is Brisk")
	eq(FlightTuning.turn_comfort_rate(0.75), 180.0, "Brisk is 180 deg/s")
	var peaks := {}
	for v: float in [0.25, 0.5, 0.75, 1.0]:
		await _fx(&"sparrow")
		var f := fx
		Settings.set_value("turn_comfort", v)
		f.player.use_settings = true
		f.player.call(&"_apply_settings")
		f.player.start_flying(Vector3(0, 300, 0), 0.0, 0.0)
		f.run(0.5)
		f.reset_comfort()
		f.driver = f.synth(0.0, 1.0)
		f.run(4.0)
		var cap := FlightTuning.turn_comfort_rate(v)
		var peak := rad_to_deg(f.comfort["max_rate"])
		peaks[str(cap)] = snappedf(peak, 0.1)
		lt(peak, cap + 1e-3, "turn speed %.2f: the rig never yaws faster than %.0f deg/s at full input (%.1f)" % [v, cap, peak])
		lt(rad_to_deg(f.comfort["max_accel"]), cap * FlightTuning.TURN_COMFORT_ACCEL_PER_RATE + 1e-3, "...nor accelerates faster than %.0f deg/s^2" % (cap * 3.0))
		gt(peak, minf(cap, 200.0) * 0.8, "...and a full-input turn does reach near it (%.1f)" % peak)
		f.assert_comfort(self, "turn comfort %.2f" % v)
		fx.teardown()
		fx = null
	metric("turn_comfort_peak_deg_s", peaks)
	Settings.set_value("turn_comfort", saved)
	for k in saved_dev:
		Settings.set_value(k, saved_dev[k])


## Integration round 2 (the Quest verifier): a recenter taken while paused
## (the body does not tick, the rig tracks) turned the view at the press and
## turned the world back 51.5 deg at Resume, when the next tick re-aimed the
## rig. The re-aim now happens while paused, and Resume turns nothing.
func test_pb29_recenter_while_paused_turns_the_view_once() -> void:
	await _fx(&"sparrow")
	var f := fx
	f.player.process_mode = Node.PROCESS_MODE_PAUSABLE
	f.player.start_flying(Vector3(0, 300, 0), 0.0, 0.0)
	f.run(1.0)
	var h0 := f.player.model.heading()
	get_tree().paused = true
	# The runtime recenters: tracking space rotates by 50 deg under the player.
	f.driver = func(_tick: int, _t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		b.torso_yaw = 50.0 * DEG
	Events.recenter_requested.emit()
	for i in 4:
		await get_tree().process_frame
	var aim := FlightMath.wrap_angle(f.player.model.heading() - f.player.wing_state().body_yaw)
	near(rad_to_deg(FlightMath.wrap_angle(f.player.rig_yaw - aim)), 0.0, 1.0, "re-aimed while paused: rig yaw = heading - body yaw (deg)")
	near(rad_to_deg(FlightMath.wrap_angle(f.player.model.heading() - h0)), 0.0, 1e-3, "the bird's heading untouched while paused (deg)")
	var rig_paused := f.player.rig_yaw
	get_tree().paused = false
	f.step()
	var jump := rad_to_deg(absf(FlightMath.wrap_angle(f.player.rig_yaw - rig_paused)))
	metric("resume_rig_turn_deg", jump)
	lt(jump, 1.0, "Resume does not turn the world (%.2f deg in the first tick)" % jump)
	check(not f.player.yaw_flagged, "the first tick after Resume is not a flagged yaw step")
