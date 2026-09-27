extends TestCase
## Verifier round 1 (engineering / contract lens) probes for the flight area.
## Independent of the builder's tests: scene contract, real tree pause,
## product-vs-fixture leaks, whole-chain fuzz (poses -> PlayerBird), tick
## cost and PlayerBird-level determinism.
##   tools/gd.sh flight_verify2 --headless res://tests/runner.tscn -- --dir=res://tests/probes/flight

const PLAYER := preload("res://scenes/player/player.tscn")
const TW := preload("res://tests/unit/flight/flight_test_world.gd")
const FX := preload("res://tests/unit/flight/pb_fixture.gd")
const DT := 1.0 / 72.0


## Random, frequently corrupt tracking: NaN / inf / degenerate bases, huge
## jumps, validity flicker, on top of a flapping airplane pose.
class FuzzSource:
	extends PoseSource
	var body := HumanPoseModel.new(5)
	var rng := RandomNumberGenerator.new()
	var tick := 0

	func _init() -> void:
		rng.seed = 4242

	func sample(out: PoseFrame, dt: float) -> void:
		tick += 1
		body.t = tick * DT
		body.set_airplane()
		ScriptedPoseSource.flap(body, body.t, rng.randf_range(0.0, 60.0), rng.randf_range(0.5, 3.0))
		for a in body.arms:
			a.twist = rng.randf_range(-1.2, 1.2)
		body.torso_yaw = rng.randf_range(-PI, PI) if rng.randf() < 0.01 else body.torso_yaw
		body.frame(out)
		out.grip = Vector2(rng.randf(), rng.randf())
		var r := rng.randf()
		if r < 0.02:
			out.left.origin = Vector3(NAN, 0, 0)
		elif r < 0.04:
			out.right.basis = Basis(Vector3(INF, 0, 0), Vector3.UP, Vector3.BACK)
		elif r < 0.06:
			out.head.origin = Vector3(1e7, -1e7, 3.0)
		elif r < 0.08:
			out.left.basis = Basis(Vector3.ZERO, Vector3.ZERO, Vector3.ZERO)
		elif r < 0.10:
			out.head.basis = Basis(Vector3(NAN, 0, 0), Vector3(0, NAN, 0), Vector3(0, 0, 1))
		elif r < 0.13:
			out.left_valid = false
		elif r < 0.16:
			out.right_valid = false
		elif r < 0.18:
			out.head_valid = false
		elif r < 0.20:
			out.left.origin += Vector3(rng.randf_range(-3, 3), rng.randf_range(-3, 3), rng.randf_range(-3, 3))
		out.discontinuity = rng.randf() < 0.005

	func drives_nodes() -> bool:
		return true


func _player(world: Node = null) -> PlayerBird:
	var p := PLAYER.instantiate() as PlayerBird
	p.auto_process = false
	p.use_settings = false
	p.default_source = &"none"
	p.drive_world_scale = true
	p.auto_calibrate = false
	add_child(p)
	return p


# --- 1. scene contract (ARCHITECTURE §6 flight, §7 rules 1, 6) ----------------------
func test_v2_scene_contract_and_real_pause() -> void:
	var p := PLAYER.instantiate()
	check(p is PlayerBird and p is Bird, "player.tscn root is a PlayerBird (extends Bird)")
	var o := p.get_node_or_null(^"XROrigin3D") as XROrigin3D
	check(o != null, "PlayerBird -> XROrigin3D child")
	check(o != null and o.is_in_group(&"player_rig"), "XROrigin3D in group player_rig (scene file)")
	eq(o.process_mode, Node.PROCESS_MODE_ALWAYS, "XROrigin3D PROCESS_MODE_ALWAYS")
	check(o.get_node_or_null(^"XRCamera3D") is XRCamera3D, "XROrigin3D -> XRCamera3D")
	var lh := o.get_node_or_null(^"LeftHand") as XRController3D
	var rh := o.get_node_or_null(^"RightHand") as XRController3D
	check(lh != null and rh != null, "LeftHand / RightHand XRController3D")
	eq(lh.tracker, &"left_hand", "LeftHand tracker")
	eq(rh.tracker, &"right_hand", "RightHand tracker")
	p.free()
	var pl := _player()
	check(pl.is_in_group(&"player") and pl.is_in_group(&"birds"), "PlayerBird in groups player + birds")
	check(Birds.player() == pl, "Birds.player() returns the PlayerBird")
	check(get_tree().get_first_node_in_group(&"player_rig") == pl.origin, "player_rig group resolves to its origin")
	for m in ["respawn", "set_controls_enabled", "telemetry", "get_body_position", "get_forward"]:
		check(pl.has_method(m), "API %s" % m)
	# Real pause: gameplay freezes, the whole rig subtree keeps processing.
	pl.start_flying(Vector3(0, 300, 0), 0.0, 0.0)
	pl.auto_process = true
	await wait_physics(3)
	var y_run := pl.model.position
	await wait_physics(3)
	check(pl.model.position != y_run, "auto_process ticks while unpaused")
	get_tree().paused = true
	await wait_physics(1)
	var y0 := pl.model.position
	await wait_physics(6)
	var frozen := pl.model.position == y0
	var pausable := not pl.can_process()
	var all_always := true
	var stack: Array[Node] = [pl.origin]
	var n_rig := 0
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		n_rig += 1
		if not n.can_process():
			all_always = false
		for c in n.get_children():
			stack.append(c)
	get_tree().paused = false
	check(frozen, "paused: the flight integration does not advance")
	check(pausable, "paused: PlayerBird is pausable")
	check(all_always, "paused: every node under XROrigin3D still processes (%d nodes)" % n_rig)
	pl.queue_free()
	await wait_frames(2)


# --- 2. telemetry contract: keys and types ----------------------------------------
func test_v2_telemetry_types() -> void:
	var w := TW.new()
	add_child(w)
	var pl := _player()
	pl.set_pose_source(ScriptedPoseSource.new(HumanPoseModel.new(3), func(_k: int, t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		ScriptedPoseSource.flap(b, t, 45.0, 1.0)))
	pl.start_flying(Vector3(0, 40, 0), 0.0, 0.0)
	for i in 144:
		pl.tick(DT)
	var t := pl.telemetry()
	var bools := ["stalled", "tucked", "perched"]
	for k in ["airspeed", "groundspeed", "vertical_speed", "altitude_agl", "aoa", "bank", "flapping",
			"wing_extension", "in_updraft", "g_load", "lift", "drag"]:
		check(t.has(k) and t[k] is float and is_finite(t[k]), "telemetry %s is a finite float (%s)" % [k, str(t.get(k))])
	for k in bools:
		check(t.has(k) and t[k] is bool, "telemetry %s is a bool" % k)
	between(float(t["flapping"]), 0.0, 1.0, "flapping in 0..1")
	between(float(t["wing_extension"]), 0.0, 1.0, "wing_extension in 0..1")
	near(float(t["altitude_agl"]), pl.model.position.y, 1e-3, "altitude_agl over flat ground at y=0")
	metric("telemetry_sample", {"airspeed": t["airspeed"], "aoa": t["aoa"], "lift": t["lift"], "g_load": t["g_load"]})
	pl.queue_free()
	w.queue_free()
	await wait_frames(2)


# --- 3. leaks: the product vs the test fixture --------------------------------------
func _count() -> Vector2i:
	return Vector2i(int(Performance.get_monitor(Performance.OBJECT_COUNT)),
		int(Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT)))


func _product_cycle() -> void:
	var w := TW.new()
	w.add_rod(Vector3(-2, 30, -5), Vector3(2, 30, -5), 0.01)
	w.add_perch(Vector3(0, 20, -10))
	add_child(w)
	await wait_physics(2)
	var pl := _player()
	pl.set_pose_source(ScriptedPoseSource.new(HumanPoseModel.new(3), func(_k: int, t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		ScriptedPoseSource.flap(b, t, 45.0, 1.0)))
	pl.start_flying(Vector3(0, 30, 0), 0.0, 0.0)
	for i in 300:
		pl.tick(DT)
	pl.respawn(Transform3D(Basis.IDENTITY, Vector3(0, 20.05, -10)))
	for i in 60:
		pl.tick(DT)
	remove_child(pl)
	pl.free()
	remove_child(w)
	w.free()
	await wait_frames(2)


func test_v2_leaks_product_vs_fixture() -> void:
	await _product_cycle()  # warm caches / statics
	var c0 := _count()
	for i in 4:
		await _product_cycle()
	var c1 := _count()
	metric("product_leak_objects_per_4_cycles", c1.x - c0.x)
	metric("product_leak_resources_per_4_cycles", c1.y - c0.y)
	lt(c1.x - c0.x, 5, "product: 4 PlayerBird + world cycles leak < 5 objects")
	lt(c1.y - c0.y, 2, "product: 4 cycles leak < 2 resources")
	# The builder's fixture (pb_fixture.gd), same scenario size.
	var f0 := _count()
	for i in 3:
		var fx := FX.new(self)
		await fx.setup(&"sparrow")
		fx.player.start_flying(Vector3(0, 30, 0), 0.0, 0.0)
		fx.run(1.0)
		fx.teardown()
		await wait_frames(2)
	var f1 := _count()
	metric("fixture_leak_objects_per_3_cycles", f1.x - f0.x)
	metric("fixture_leak_resources_per_3_cycles", f1.y - f0.y)


# --- 4. whole-chain fuzz: corrupt poses + dt spikes into a real PlayerBird ----------
func test_v2_chain_fuzz_10k() -> void:
	var w := TW.new()
	w.add_rod(Vector3(-50, 25, -40), Vector3(50, 25, -40), 0.01)
	w.add_wall(Vector3(0, 30, -120), Vector3(200, 60, 2))
	w.thermal_center = Vector3(0, 0, -60)
	w.thermal_core = 4.0
	add_child(w)
	await wait_physics(2)
	var pl := _player()
	var src := FuzzSource.new()
	pl.set_pose_source(src)
	pl.start_flying(Vector3(0, 40, 0), 0.0, 0.0)
	var rng := RandomNumberGenerator.new()
	rng.seed = 99
	var dts := [DT, DT, DT, 1.0 / 90.0, 1.0 / 30.0, 0.1, 0.25, 1.0, 1e-4, 0.0]
	var bad := 0
	var bad_rig := 0
	var bad_tel := 0
	var modes := {}
	for i in 10000:
		var dt: float = dts[rng.randi() % dts.size()] if i % 5 == 0 else DT
		pl.tick(dt)
		modes[pl.mode_name()] = int(modes.get(pl.mode_name(), 0)) + 1
		if not (FlightMath.vfinite(pl.model.position) and FlightMath.vfinite(pl.model.velocity)
				and FlightMath.vfinite(pl.camera.global_position) and is_finite(pl.rig_yaw)):
			bad += 1
		var b := pl.global_basis
		if absf(b.y.dot(Vector3.UP) - 1.0) > 1e-5 or absf(b.determinant() - 1.0) > 1e-4 \
				or not pl.origin.transform.basis.is_equal_approx(Basis.IDENTITY):
			bad_rig += 1
		if i % 10 == 0:
			for k in pl.telemetry():
				var v: Variant = pl.telemetry()[k]
				if v is float and not is_finite(v) and not (k == "perch_candidate"):
					bad_tel += 1
		if pl.model.position.y < 5.0 or pl.model.position.y > 400.0 or absf(pl.model.position.z) > 3000.0:
			pl.start_flying(Vector3(0, 40, 0), 0.0, 0.0)
	eq(bad, 0, "10k corrupt-pose ticks with dt spikes: state and camera stay finite")
	eq(bad_rig, 0, "10k corrupt-pose ticks: the rig stays yaw-only, unit scale")
	eq(bad_tel, 0, "10k corrupt-pose ticks: telemetry floats stay finite")
	metric("modes", modes)
	pl.queue_free()
	w.queue_free()
	await wait_frames(2)


## One corruption kind at a time (5% of ticks), to attribute non-finite state.
class KindSource:
	extends PoseSource
	var body := HumanPoseModel.new(6)
	var rng := RandomNumberGenerator.new()
	var tick := 0
	var kind := 0

	func sample(out: PoseFrame, dt: float) -> void:
		tick += 1
		body.t = tick * DT
		body.set_airplane()
		ScriptedPoseSource.flap(body, body.t, 45.0, 1.2)
		body.frame(out)
		if rng.randf() >= 0.05:
			return
		match kind:
			1: out.left.origin = Vector3(NAN, 0, 0)
			2: out.right.basis = Basis(Vector3(INF, 0, 0), Vector3.UP, Vector3.BACK)
			3: out.head.origin = Vector3(1e7, -1e7, 3.0)
			4: out.left.basis = Basis(Vector3.ZERO, Vector3.ZERO, Vector3.ZERO)
			5: out.head.basis = Basis(Vector3(NAN, 0, 0), Vector3(0, NAN, 0), Vector3(0, 0, 1))
			6: out.left_valid = false
			7: out.head_valid = false
			8: out.left.origin += Vector3(2.5, -1.0, 1.5)
			9: out.head.origin = Vector3(NAN, NAN, NAN)

	func drives_nodes() -> bool:
		return true


func test_v2_chain_fuzz_by_kind() -> void:
	var w := TW.new()
	add_child(w)
	await wait_physics(2)
	var names := ["none", "left_origin_nan", "right_basis_inf", "head_origin_1e7", "left_basis_zero",
		"head_basis_nan", "left_invalid", "head_invalid", "left_jump_3m", "head_origin_nan"]
	var summary := {}
	for kind in names.size():
		var pl := _player(w)
		var src := KindSource.new()
		src.kind = kind
		src.rng.seed = 1000 + kind
		pl.set_pose_source(src)
		pl.start_flying(Vector3(0, 60, 0), 0.0, 0.0)
		print("[flight_v2] fuzz kind %s begin" % names[kind])
		var bad := {"model": 0, "camera": 0, "rig_yaw": 0, "hands": 0, "tel": {}}
		for i in 1500:
			pl.tick(DT)
			if not (FlightMath.vfinite(pl.model.position) and FlightMath.vfinite(pl.model.velocity)):
				bad["model"] += 1
			if not FlightMath.vfinite(pl.camera.global_position):
				bad["camera"] += 1
			if not FlightMath.vfinite(pl.left_hand.global_position) or not FlightMath.vfinite(pl.right_hand.global_position):
				bad["hands"] += 1
			if not is_finite(pl.rig_yaw):
				bad["rig_yaw"] += 1
			var tel := pl.telemetry()
			for k in tel:
				if tel[k] is float and not is_finite(tel[k]) and k != "perch_candidate":
					bad["tel"][k] = int(bad["tel"].get(k, 0)) + 1
			if pl.model.position.y < 5.0 or not FlightMath.vfinite(pl.model.position):
				pl.start_flying(Vector3(0, 60, 0), 0.0, 0.0)
		print("[flight_v2] fuzz kind %s end %s" % [names[kind], str(bad)])
		summary[names[kind]] = bad
		remove_child(pl)
		pl.free()
	metric("by_kind", summary)
	var total := 0
	for k in summary:
		total += int(summary[k]["model"]) + int(summary[k]["rig_yaw"]) + summary[k]["tel"].size()
	eq(total, 0, "no corruption kind makes the model, rig yaw or telemetry non-finite")
	w.queue_free()
	await wait_frames(2)


## Clean poses, only dt spikes: which telemetry keys go non-finite, and at which dt.
func test_v2_dt_spikes_only() -> void:
	var w := TW.new()
	add_child(w)
	await wait_physics(2)
	var pl := _player(w)
	pl.set_pose_source(ScriptedPoseSource.new(HumanPoseModel.new(3), func(_k: int, t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		ScriptedPoseSource.flap(b, t, 45.0, 1.0)))
	pl.start_flying(Vector3(0, 60, 0), 0.0, 0.0)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var dts := [1.0 / 90.0, 1.0 / 30.0, 0.1, 0.25, 1.0, 1e-4, 1e-6]
	var bad := {}
	var bad_dt := {}
	for i in 5000:
		var dt: float = dts[rng.randi() % dts.size()] if i % 5 == 0 else DT
		pl.tick(dt)
		var tel := pl.telemetry()
		for k in tel:
			if tel[k] is float and not is_finite(tel[k]) and k != "perch_candidate":
				bad[k] = int(bad.get(k, 0)) + 1
				bad_dt[str(dt)] = int(bad_dt.get(str(dt), 0)) + 1
		if not is_finite(pl.rig_yaw) or not is_finite(pl.rig_yaw_rate):
			bad["rig_yaw(_rate)"] = int(bad.get("rig_yaw(_rate)", 0)) + 1
		if pl.model.position.y < 5.0:
			pl.start_flying(Vector3(0, 60, 0), 0.0, 0.0)
	print("[flight_v2] dt spikes: bad keys %s at dts %s" % [str(bad), str(bad_dt)])
	metric("bad_keys", bad)
	metric("bad_dts", bad_dt)
	eq(bad.size(), 0, "clean poses with dt spikes: telemetry and rig yaw stay finite")
	remove_child(pl)
	pl.free()
	w.queue_free()
	await wait_frames(2)


## Minimal repro: which single long tick poisons the heave smoother.
func test_v2_heave_single_long_tick() -> void:
	var w := TW.new()
	add_child(w)
	await wait_physics(2)
	var res := {}
	for spike in [0.1, 0.25, 0.3, 0.5, 1.0, 1.5, 2.0]:
		var pl := _player(w)
		pl.set_pose_source(ScriptedPoseSource.new(HumanPoseModel.new(3), func(_k: int, t: float, b: HumanPoseModel) -> void:
			b.set_airplane()
			ScriptedPoseSource.flap(b, t, 45.0, 1.0)))
		pl.start_flying(Vector3(0, 80, 0), 0.0, 0.0)
		for i in 360:
			pl.tick(DT)
		pl.tick(spike)
		# The same spike as the first tick after a heave reset (start_flying).
		pl.start_flying(Vector3(0, 80, 0), 0.0, 0.0)
		pl.tick(spike)
		var nan_ticks := 0
		for i in 720:
			pl.tick(DT)
			if not is_finite(pl._heave_off) or not FlightMath.vfinite(pl.camera.global_position) \
					or not FlightMath.vfinite(pl.origin.global_position):
				nan_ticks += 1
		res[str(spike)] = nan_ticks
		remove_child(pl)
		pl.free()
	print("[flight_v2] heave NaN ticks (of 720 after one long tick): %s" % str(res))
	metric("heave_nan_ticks_after_spike", res)
	for k in res:
		eq(res[k], 0, "one %s s tick: camera / origin / heave offset stay finite for the next 10 s" % k)
	w.queue_free()
	await wait_frames(2)


## What telemetry reports once perched after a flared, assisted approach.
func test_v2_perched_telemetry_is_not_stale() -> void:
	var w := TW.new()
	var grip := Vector3(0, 20, -10)
	w.add_perch(grip, Vector3.FORWARD, 10.0, 0.015, 1.0)
	add_child(w)
	await wait_physics(2)
	var out := {}
	for sp in [&"sparrow", &"pigeon"]:
		var pl := _player(w)
		pl.mass = FlightParams.species_mass(sp)
		var cal := pl.wing_input.calibration
		pl.set_pose_source(ScriptedPoseSource.new(HumanPoseModel.new(3), func(_k: int, _t: float, b: HumanPoseModel) -> void:
			b.set_airplane()
			b.synth(0.8, 0.0, 1.0, cal)))
		var pr := pl.model.params
		var start := grip + Vector3.UP * pr.r_body + Vector3(0, 0.3 * pr.span, 8.0 * pr.span)
		pl.start_flying(start, 0.0, 0.0)
		pl.model.reset(start, Vector3(0, 0, -1.15 * pr.v_min), 0.0)
		var at_capture := {}
		for i in 4 * 72:
			var was := pl.mode
			pl.tick(DT)
			if was == PlayerBird.Mode.FLYING and pl.mode == PlayerBird.Mode.PERCHED:
				at_capture = pl.telemetry().duplicate()
		for i in 72:
			pl.tick(DT)
		var t := pl.telemetry()
		out[sp] = {"mode": pl.mode_name(), "stalled": t["stalled"], "stall_warning": t["stall_warning"], "aoa_deg": rad_to_deg(t["aoa"]),
			"g_load": t["g_load"], "lift": t["lift"], "airspeed": t["airspeed"],
			"warn_at_capture": at_capture.get("stall_warning", -1.0)}
		remove_child(pl)
		pl.free()
	print("[flight_v2] perched telemetry 1 s after capture: %s" % str(out))
	metric("perched_telemetry", out)
	for sp in out:
		eq(out[sp]["mode"], "perched", "%s perched" % sp)
	w.queue_free()
	await wait_frames(2)


# --- 5. PlayerBird tick cost in a world with geometry -------------------------------
func test_v2_tick_cost() -> void:
	var w := TW.new()
	for k in 20:
		w.add_rod(Vector3(-3, 20 + k, -5 - 3 * k), Vector3(3, 20 + k, -5 - 3 * k), 0.01)
	w.add_perch(Vector3(0, 30, -30))
	add_child(w)
	await wait_physics(2)
	var pl := _player(w)
	pl.set_pose_source(ScriptedPoseSource.new(HumanPoseModel.new(3), func(_k: int, t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		ScriptedPoseSource.flap(b, t, 45.0, 1.0)
		b.arms[0].twist = 0.2 * sin(t)
		b.arms[1].twist = -0.2 * sin(t)))
	pl.start_flying(Vector3(0, 25, 0), 0.0, 0.0)
	var us := PackedFloat64Array()
	for i in 720:
		var t0 := Time.get_ticks_usec()
		pl.tick(DT)
		us.append(float(Time.get_ticks_usec() - t0))
		if pl.model.position.y < 5.0:
			pl.start_flying(Vector3(0, 25, 0), 0.0, 0.0)
	var arr := Array(us)
	arr.sort()
	var med: float = arr[arr.size() / 2]
	var p95: float = arr[int(arr.size() * 0.95)]
	metric("tick_us_median", med)
	metric("tick_us_p95", p95)
	lt(med, 700.0, "PlayerBird.tick median < 0.7 ms (5% of a 72 Hz frame)")
	pl.queue_free()
	w.queue_free()
	await wait_frames(2)


# --- 6. PlayerBird-level determinism ------------------------------------------------
func _det_run() -> Array:
	var w := TW.new()
	w.add_rod(Vector3(-3, 38, -20), Vector3(3, 38, -20), 0.01)
	w.add_perch(Vector3(1, 36, -45))
	add_child(w)
	await wait_physics(2)
	var pl := _player(w)
	var body := HumanPoseModel.new(11)
	body.tremor_mm = 1.5
	body.twist_noise_deg = 2.0
	var cal := pl.wing_input.calibration
	pl.set_pose_source(ScriptedPoseSource.new(body, func(_k: int, t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		if t < 4.0:
			ScriptedPoseSource.flap(b, t, 40.0, 1.2)
		else:
			b.synth(0.3, 0.4 * sin(t), 1.0, cal)
		b.humanize(DT)))
	pl.start_flying(Vector3(0, 40, 0), 0.0, 0.0)
	var trace := PackedFloat64Array()
	for i in 12 * 72:
		pl.tick(DT)
		trace.append(pl.model.position.x + 3.0 * pl.model.position.y + 7.0 * pl.model.position.z + pl.rig_yaw)
	var out := [pl.model.position, pl.rig_yaw, pl.mode_name(), pl.contacts.duplicate(), trace]
	remove_child(pl)
	pl.free()
	remove_child(w)
	w.free()
	await wait_frames(2)
	return out


func test_v2_player_determinism() -> void:
	var a: Array = await _det_run()
	var b: Array = await _det_run()
	check(a[0] == b[0], "bit-identical final position (%s vs %s)" % [a[0], b[0]])
	check(a[1] == b[1], "bit-identical rig yaw")
	eq(a[2], b[2], "same final mode")
	check(a[4] == b[4], "bit-identical position trace over 12 s")
	metric("det_final", [str(a[0]), a[2], a[3]])
