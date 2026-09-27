extends TestCase
## Verifier probes (round 1, flight): the PlayerBird rig under abuse.
##   F8: corrupt poses (NaN / inf / degenerate bases / 5 m jumps / validity
##       flicker), dt spikes, random growth and world_scale, controls on/off,
##       tilted and scaled respawn transforms: the state and every node on the
##       rig path stay finite.
##   F11: over all of it, the rig never pitches or rolls, never scales, and its
##       yaw rate / acceleration stay inside the caps except on flagged ticks.
##   A long (10 min) human-like random flight: the same, plus bookkeeping drift.

const FX := preload("res://tests/unit/flight/pb_fixture.gd")
const DEG := PI / 180.0
const DT := 1.0 / 72.0

var fx: FX
var _lines := PackedStringArray()
var _dbg := 0
var _prev_mode := ""


func after_each() -> void:
	if fx != null:
		fx.teardown()
		fx = null
	await get_tree().process_frame


func after_all() -> void:
	var path := Paths.artifacts("flight").path_join("verify").path_join("rig_probe.txt")
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string("\n".join(_lines))


## A pose source that corrupts a human's poses (like a glitching runtime).
class EvilSource extends PoseSource:
	var body := HumanPoseModel.new(3)
	var rng := RandomNumberGenerator.new()
	var mode := 0
	var mode_left := 0.0
	var corrupt_rate := 0.03
	var skip_nan_head := false
	var nodes := false
	var last_kind := -1
	var t := 0.0
	var cal := WingCalibration.new()

	func sample(out: PoseFrame, dt: float) -> void:
		t += dt
		mode_left -= dt
		if mode_left <= 0.0:
			mode = rng.randi_range(0, 7)
			mode_left = rng.randf_range(0.3, 2.5)
		body.set_airplane()
		match mode:
			0:
				body.synth(rng.randf_range(-1, 1), rng.randf_range(-1, 1), 1.0, cal)
			1:
				ScriptedPoseSource.flap(body, t, rng.randf_range(20, 60), rng.randf_range(0.7, 3.0))
			2:
				body.synth(-1.0, 0.0, 0.0, cal)
			3:
				ScriptedPoseSource.flap(body, t, 45.0, 1.0, -1 if rng.randf() < 0.5 else 1)
			4:
				body.torso_yaw += rng.randf_range(-0.2, 0.2)
			5:
				body.head_yaw = rng.randf_range(-2, 2)
				body.head_pitch = rng.randf_range(-1, 1)
			6:
				body.crouch = rng.randf_range(-0.3, 0.5)
			7:
				body.synth(1.0, rng.randf_range(-1, 1), rng.randf_range(0, 1), cal)
		body.left_valid = rng.randf() > 0.02
		body.right_valid = rng.randf() > 0.02
		body.head_valid = rng.randf() > 0.01
		body.grip = Vector2(rng.randf(), rng.randf())
		body.t = t
		body.frame(out)
		last_kind = -1
		if rng.randf() < corrupt_rate:
			var which := rng.randi_range(0, 8)
			if skip_nan_head and which == 0:
				which = 4
			last_kind = which
			match which:
				0:
					out.head.origin = Vector3(NAN, 1.6, 0)
				1:
					out.left.origin = Vector3(INF, 0, 0)
				2:
					out.right.basis = Basis(Vector3.ZERO, Vector3.ZERO, Vector3.ZERO)
				3:
					out.left.basis = Basis(Vector3(NAN, 0, 0), Vector3.UP, Vector3.BACK)
				4:
					out.head.origin += Vector3(5, 0, 0)
				5:
					out.right.origin += Vector3(0, -3, 0)
				6:
					out.head.basis = Basis(Vector3(1e30, 0, 0), Vector3(0, 1e30, 0), Vector3(0, 0, 1e30))
				7:
					out.grip = Vector2(NAN, INF)
				8:
					out.head.basis = Basis.from_scale(Vector3(2, 0.5, 1))

	func drives_nodes() -> bool:
		return nodes


func _finite_xf(x: Transform3D) -> bool:
	return FlightMath.vfinite(x.origin) and FlightMath.vfinite(x.basis.x) and FlightMath.vfinite(x.basis.y) and FlightMath.vfinite(x.basis.z)


func _check_rig(p: PlayerBird, acc: Dictionary) -> void:
	acc["ticks"] += 1
	if not FlightMath.vfinite(p.model.position) or not FlightMath.vfinite(p.model.velocity) or not is_finite(p.model.theta + p.model.phi + p.model.chi):
		acc["model_nan"] += 1
	if not _finite_xf(p.global_transform) or not _finite_xf(p.origin.transform) or not _finite_xf(p.camera.global_transform):
		acc["node_nan"] += 1
		if acc["first_node_nan"] < 0:
			acc["first_node_nan"] = acc["ticks"]
	var b := p.global_basis
	if b.y.dot(Vector3.UP) < 1.0 - 1e-6 or absf(b.determinant() - 1.0) > 1e-5:
		acc["tilt"] += 1
	if not p.origin.transform.basis.is_equal_approx(Basis.IDENTITY) or not p.origin.global_basis.y.is_equal_approx(Vector3.UP):
		acc["origin_tilt"] += 1
	if not p.scale.is_equal_approx(Vector3.ONE) or not p.origin.scale.is_equal_approx(Vector3.ONE):
		acc["scaled"] += 1
	if p.yaw_flagged:
		acc["flagged"] += 1
		acc["skip"] = 2
	elif acc["skip"] > 0:
		acc["skip"] -= 1
	else:
		acc["max_rate"] = maxf(acc["max_rate"], absf(p.rig_yaw_rate))
		acc["max_acc"] = maxf(acc["max_acc"], absf(p.rig_yaw_accel))
	var t := p.telemetry()
	for k in t:
		var v: Variant = t[k]
		if (v is float and not is_finite(v)) and not (k == "altitude_agl"):
			acc["telem_nan"] += 1
			acc["telem_bad_keys"][k] = true


func _new_acc() -> Dictionary:
	return {"ticks": 0, "model_nan": 0, "node_nan": 0, "first_node_nan": -1, "tilt": 0, "origin_tilt": 0, "scaled": 0,
		"flagged": 0, "skip": 0, "max_rate": 0.0, "max_acc": 0.0, "telem_nan": 0, "telem_bad_keys": {}}


func _world(w: Variant) -> void:
	# Obstacles so collisions, stuns, slides and perching all happen.
	for i in 12:
		var a := Vector3(-60 + i * 11, 0, -40 - i * 7)
		w.add_rod(a, a + Vector3(0, 80, 0), 0.02)
		w.add_rod(a + Vector3(0, 20 + i, 0), a + Vector3(30, 22 + i, -5), 0.006)
	w.add_wall(Vector3(0, 30, -150), Vector3(80, 60, 1))
	w.add_wall(Vector3(-90, 30, -60), Vector3(1, 60, 200))
	for i in 6:
		w.add_perch(Vector3(-20 + 8 * i, 15 + 2 * i, -30 - 10 * i), Vector3.FORWARD, 3.0)


func test_f8_f11_rig_fuzz_corrupt_poses() -> void:
	await _fuzz(false, "all corruptions")


func test_f8_f11_rig_fuzz_no_nan_head() -> void:
	await _fuzz(true, "no NaN head")


func _fuzz(skip_nan_head: bool, tag: String) -> void:
	fx = FX.new(self)
	await fx.setup(&"sparrow", _world)
	var p := fx.player
	var src := EvilSource.new()
	src.skip_nan_head = skip_nan_head
	src.rng.seed = 1234
	p.set_pose_source(src)
	p.start_flying(Vector3(0, 40, 0), 0.0)
	var rng := RandomNumberGenerator.new()
	rng.seed = 77
	var acc := _new_acc()
	var dts := [DT, DT, DT, DT, 1.0 / 90.0, 1.0 / 120.0, 1.0 / 30.0, 0.1, 0.25, 1e-4]
	var masses := [0.03, 0.055, 0.1, 0.3, 0.5, 1.3, 3.0]
	var respawns := 0
	var kinds := {}
	for i in 20000:
		var dt: float = dts[rng.randi_range(0, dts.size() - 1)] if rng.randf() < 0.1 else DT
		if rng.randf() < 0.001:
			p.mass = masses[rng.randi_range(0, masses.size() - 1)]
		if rng.randf() < 0.002:
			p.origin.world_scale = rng.randf_range(0.05, 3.0)
		if rng.randf() < 0.002:
			p.set_controls_enabled(not p.controls_enabled)
		if rng.randf() < 0.0015:
			# A respawn transform with pitch, roll and scale in it (a careless caller).
			var bx := Basis(Vector3.UP, rng.randf_range(-3, 3)) * Basis(Vector3.RIGHT, rng.randf_range(-1, 1)) \
				* Basis(Vector3.BACK, rng.randf_range(-1, 1)) * Basis.from_scale(Vector3.ONE * rng.randf_range(0.2, 3.0))
			p.respawn(Transform3D(bx, Vector3(rng.randf_range(-50, 50), rng.randf_range(5, 80), rng.randf_range(-100, 20))))
			respawns += 1
		if rng.randf() < 0.001:
			Events.recenter_requested.emit()
		if p.model.position.y < 3.0 or p.model.position.length() > 400.0:
			p.start_flying(Vector3(rng.randf_range(-30, 30), 60, rng.randf_range(-60, 0)), rng.randf_range(-3, 3))
		var nn0: int = acc["node_nan"]
		p.tick(dt)
		_check_rig(p, acc)
		if acc["node_nan"] > nn0:
			kinds[src.last_kind] = int(kinds.get(src.last_kind, 0)) + 1
	p.set_controls_enabled(true)
	_lines.append("node-NaN ticks by corruption kind this tick (-1 = none): %s" % str(kinds))
	_lines.append("F8/F11 fuzz (%s): %s respawns %d contacts %s" % [tag, str(acc), respawns, str(p.contacts)])
	eq(acc["model_nan"], 0, "%s: model state finite on every tick" % tag)
	eq(acc["node_nan"], 0, "%s: PlayerBird / XROrigin3D / camera transforms finite on every tick (first bad tick %d)" % [tag, acc["first_node_nan"]])
	eq(acc["tilt"], 0, "PlayerBird basis: yaw only, unit scale, every tick")
	eq(acc["origin_tilt"], 0, "XROrigin3D: identity local basis, level, every tick")
	eq(acc["scaled"], 0, "no node scale on the rig path")
	eq(acc["telem_nan"], 0, "telemetry finite (bad keys %s)" % str(acc["telem_bad_keys"].keys()))
	lt(rad_to_deg(acc["max_rate"]), 240.0 + 1e-3, "rig yaw rate <= 240 deg/s outside flagged ticks")
	lt(rad_to_deg(acc["max_acc"]), 756.0, "rig yaw accel <= 756 deg/s^2 outside flagged ticks")
	lt(float(acc["flagged"]) / acc["ticks"], 0.01, "flagged (exempt) ticks stay rare")
	metric("fuzz_" + tag.replace(" ", "_"), acc)


func test_f8_nan_head_one_tick() -> void:
	# One corrupt head sample (NaN origin, flagged invalid), everything else fine.
	fx = FX.new(self)
	await fx.setup(&"pigeon")
	var p := fx.player
	p.start_flying(Vector3(0, 100, 0), 0.0)
	var s2 := OneBadHead.new()
	p.set_pose_source(s2)
	var acc2 := _new_acc()
	for i in 144:
		p.tick(DT)
		_check_rig(p, acc2)
	_lines.append("NaN head tick: %s" % str(acc2))
	eq(acc2["node_nan"], 0, "a single invalid NaN head sample never reaches the rig nodes (first bad tick %d)" % acc2["first_node_nan"])
	eq(acc2["model_nan"], 0, "a single NaN head sample never reaches the model")
	metric("nan_head_node_nan_ticks", acc2["node_nan"])


class OneBadHead extends PoseSource:
	var body := HumanPoseModel.new(4)
	var n := 0

	func sample(out: PoseFrame, _dt: float) -> void:
		body.set_airplane()
		body.frame(out)
		n += 1
		if n == 40:
			out.head.origin = Vector3(NAN, NAN, NAN)
			out.head_valid = false


func test_f11_tilted_respawn_is_yaw_only() -> void:
	fx = FX.new(self)
	await fx.setup(&"sparrow")
	var p := fx.player
	var bx := Basis(Vector3.UP, 0.4) * Basis(Vector3.RIGHT, 0.6) * Basis(Vector3.BACK, -0.5) * Basis.from_scale(Vector3(2, 2, 2))
	p.respawn(Transform3D(bx, Vector3(0, 50, 0)))
	var acc := _new_acc()
	_check_rig(p, acc)
	for i in 72:
		fx.step()
		_check_rig(p, acc)
	eq(acc["tilt"], 0, "respawn with a pitched/rolled/scaled transform: rig stays yaw-only, unit scale")
	eq(acc["scaled"], 0, "respawn never scales the rig")
	# A straight-down facing transform (no horizontal forward): defined yaw, no NaN.
	p.respawn(Transform3D(Basis(Vector3.RIGHT, -PI / 2), Vector3(0, 50, 0)))
	_check_rig(p, acc)
	eq(acc["node_nan"], 0, "vertical respawn transform stays finite")


func test_long_random_flight_10_min() -> void:
	# A human-like random pilot for 10 minutes: bounded bookkeeping, comfort.
	fx = FX.new(self)
	await fx.setup(&"sparrow", _world)
	var p := fx.player
	var src := EvilSource.new()
	src.corrupt_rate = 0.0
	src.nodes = true
	src.rng.seed = 4321
	src.body.tremor_mm = 1.5
	p.set_pose_source(src)
	p.start_flying(Vector3(0, 60, 0), 0.0)
	var acc := _new_acc()
	var worst_origin := 0.0
	var worst_cam := 0.0
	var restarts := 0
	var modes := {}
	for i in 72 * 600:
		if i == 72 * 200:
			p.mass = 0.3
		if i == 72 * 400:
			p.mass = 3.0
		if p.model.position.y < 3.0 or p.model.position.length() > 500.0 or p.mode == PlayerBird.Mode.GROUNDED:
			p.start_flying(Vector3(0, 60, 0), src.rng.randf_range(-3, 3))
			restarts += 1
		p.tick(DT)
		_check_rig(p, acc)
		modes[p.mode_name()] = int(modes.get(p.mode_name(), 0)) + 1
		# The origin offset is -head * ws + heave: it must stay near the room.
		worst_origin = maxf(worst_origin, p.origin.position.length() / maxf(p.origin.world_scale, 1e-3))
		if p.mode == PlayerBird.Mode.FLYING:
			var ce := p.camera.global_position.distance_to(p.model.position + Vector3.UP * p._heave_off)
			if ce > 0.001 and _dbg < 25:
				_dbg += 1
				_lines.append("  cam err %.4f at tick %d (t %.2f) mode %s ws %.3f head %s origin %s pos %s cam %s heave %.3f prev_mode %s" % [ce, i, i * DT,
					p.mode_name(), p.origin.world_scale, str(src.body.head_transform().origin), str(p.origin.position),
					str(p.model.position), str(p.camera.global_position), p._heave_off, _prev_mode])
			worst_cam = maxf(worst_cam, ce)
		_prev_mode = p.mode_name()
	_lines.append("10 min random flight: %s restarts %d modes %s worst origin/ws %.2f m worst cam %.4f" % [str(acc), restarts, str(modes), worst_origin, worst_cam])
	eq(acc["model_nan"] + acc["node_nan"] + acc["telem_nan"], 0, "10 min: everything finite")
	eq(acc["tilt"] + acc["origin_tilt"] + acc["scaled"], 0, "10 min: yaw-only, unscaled rig")
	lt(rad_to_deg(acc["max_rate"]), 240.0 + 1e-3, "10 min: rig yaw rate cap")
	lt(rad_to_deg(acc["max_acc"]), 756.0, "10 min: rig yaw accel cap")
	lt(worst_cam, 0.001, "10 min: the camera is the body while flying")
	metric("long", {"acc": acc, "restarts": restarts, "worst_origin": worst_origin})
