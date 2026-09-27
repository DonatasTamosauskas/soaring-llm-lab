extends TestCase
## Round-3 engineering verifier probes for the flight area (not part of the
## area's suite). Each probe pins a contract or comfort property that the
## area's own tests do not measure directly.
##   tools/gd.sh flight_verify2 --headless res://tests/runner.tscn -- --dir=res://tests/probes/flight --suite=r3eng_contract

const FX := preload("res://tests/unit/flight/pb_fixture.gd")
const TW := preload("res://tests/unit/flight/flight_test_world.gd")
const PLAYER := preload("res://scenes/player/player.tscn")
const DEG := PI / 180.0
const DT := 1.0 / 72.0

var fx: FX


func after_each() -> void:
	if fx != null:
		fx.teardown()
		fx = null
	get_tree().paused = false
	XRServer.world_scale = 1.0
	await get_tree().process_frame


func _bare(sp: StringName) -> PlayerBird:
	var p := PLAYER.instantiate() as PlayerBird
	p.auto_process = false
	p.use_settings = false
	p.default_source = &"none"
	p.mass = FlightParams.species_mass(sp)
	return p


# --- groups and registry (ARCHITECTURE §3, §6) ----------------------------------
func test_groups_and_singletons() -> void:
	var p := _bare(&"sparrow")
	add_child(p)
	await get_tree().process_frame
	check(p.is_in_group(&"player"), "PlayerBird is in group player")
	check(p.is_in_group(&"birds"), "PlayerBird is in group birds")
	check(get_tree().get_first_node_in_group(&"player_rig") == p.origin, "group player_rig resolves to the XROrigin3D")
	check(Birds.player() == p, "Birds.player() is the PlayerBird")
	eq(p.origin.process_mode, Node.PROCESS_MODE_ALWAYS, "XROrigin3D PROCESS_MODE_ALWAYS")
	eq(p.process_mode, Node.PROCESS_MODE_PAUSABLE, "PlayerBird pausable")
	check(p.camera is XRCamera3D and p.left_hand.tracker == &"left_hand" and p.right_hand.tracker == &"right_hand",
		"camera + LeftHand/RightHand trackers")
	lt(p.camera.far, 3000.0 + 1e-3, "camera far <= 3000")
	remove_child(p)
	p.free()


# --- respawn / start_flying while turning: the view must not keep turning --------
## ARCHITECTURE §7.2 and F11: yaw changes are smooth and the view follows the
## heading. After respawn(xform) the rig yaw is the respawn yaw; the comfort
## safety net must not carry the previous flight's rig yaw rate into the new
## spawn (the spawn is a flagged discontinuity, not a continuation).
func test_respawn_while_turning_view_holds_still() -> void:
	var rows := []
	for sp in [&"sparrow", &"pigeon", &"eagle"]:
		fx = FX.new(self)
		await fx.setup(sp)
		var p := fx.player
		p.start_flying(Vector3(0, 300, 0), 0.0, 0.0)
		fx.driver = fx.synth(0.0, 1.0)
		fx.run(3.0)
		var rate0 := rad_to_deg(p.rig_yaw_rate)
		var yaw_t := 1.0
		p.respawn(Transform3D(Basis(Vector3.UP, yaw_t), Vector3(100, 200, 0)))
		fx.driver = func(_tick: int, _t: float, b: HumanPoseModel) -> void:
			b.set_airplane()
		var drift := 0.0
		for i in int(0.45 / DT):
			fx.step()
			drift = maxf(drift, absf(rad_to_deg(wrapf(p.rig_yaw - yaw_t, -PI, PI))))
		fx.run(2.0)
		var off := rad_to_deg(wrapf(p.model.heading() - yaw_t, -PI, PI))
		rows.append([sp, rate0, drift, off])
		print("[flight-verify] respawn while turning %s: rig rate before %.0f deg/s, view drift while spawning %.1f deg, heading 2 s after launch %.1f deg off the respawn yaw" % [sp, rate0, drift, off])
		lt(drift, 1.0, "%s: the view stays at the respawn yaw while SPAWNING (rig rate before respawn %.0f deg/s)" % [sp, rate0])
		lt(absf(off), 3.0, "%s: with neutral arms the bird launches along the respawn yaw" % sp)
		fx.teardown()
		fx = null
	metric("respawn_while_turning", rows)


func test_start_flying_while_turning_view_matches_heading() -> void:
	var rows := []
	for sp in [&"sparrow", &"eagle"]:
		fx = FX.new(self)
		await fx.setup(sp)
		var p := fx.player
		p.start_flying(Vector3(0, 300, 0), 0.0, 0.0)
		fx.driver = fx.synth(0.0, 1.0)
		fx.run(3.0)
		var rate0 := rad_to_deg(p.rig_yaw_rate)
		p.start_flying(Vector3(100, 300, 0), 2.0, 0.0)
		fx.driver = func(_tick: int, _t: float, b: HumanPoseModel) -> void:
			b.set_airplane()
		var worst := 0.0
		for i in int(1.0 / DT):
			fx.step()
			var view := p.rig_yaw + p.wing_state().body_yaw
			worst = maxf(worst, absf(rad_to_deg(wrapf(view - p.model.heading(), -PI, PI))))
		rows.append([sp, rate0, worst])
		print("[flight-verify] start_flying while turning %s: rig rate before %.0f deg/s, worst view-heading gap in 1 s %.1f deg" % [sp, rate0, worst])
		lt(worst, 2.0, "%s: after start_flying the view faces the heading (rig rate before %.0f deg/s)" % [sp, rate0])
		fx.teardown()
		fx = null
	metric("start_flying_while_turning", rows)


# --- a World that enters the tree after the player -------------------------------
## ARCHITECTURE §3: find singletons in scene with get_first_node_in_group and
## tolerate them being absent. A World added (or regenerated) after the
## PlayerBird must still be found: wind, perches, ground height.
func test_world_added_after_the_player_is_found() -> void:
	var p := _bare(&"pigeon")
	add_child(p)
	await get_tree().process_frame
	p.start_flying(Vector3(0, 50, 0), 0.0, 0.0)
	for i in 10:
		p.tick(DT)
	var w := TW.new()
	w.uniform_wind = Vector3(0, 3.0, 0)
	add_child(w)
	await get_tree().physics_frame
	await get_tree().physics_frame
	for i in 72:
		p.tick(DT)
	var t := p.telemetry()
	print("[flight-verify] world added after the player: in_updraft %.2f, agl %.2f (y %.2f)" % [t["in_updraft"], t["altitude_agl"], p.model.position.y])
	gt(t["in_updraft"], 2.5, "the player feels the updraft of a World added after it")
	metric("late_world", {"in_updraft": t["in_updraft"], "agl": t["altitude_agl"], "y": p.model.position.y})
	remove_child(p)
	p.free()
	remove_child(w)
	w.free()


# --- telemetry in every mode ------------------------------------------------------
func _all_finite(t: Dictionary) -> Array:
	var bad := []
	for k in t:
		var v: Variant = t[k]
		if v is float and not is_finite(v):
			bad.append(k)
	return bad


func test_telemetry_finite_and_typed_in_every_mode() -> void:
	const KEYS := ["airspeed", "groundspeed", "vertical_speed", "altitude_agl", "aoa", "bank", "stalled", "flapping",
		"wing_extension", "tucked", "perched", "in_updraft", "g_load", "lift", "drag"]
	var fresh := _bare(&"sparrow")
	add_child(fresh)
	var t0 := fresh.telemetry()
	eq(_all_finite(t0).size(), 0, "fresh player (no tick yet): telemetry finite")
	for k in KEYS:
		check(t0.has(k), "fresh player telemetry has %s" % k)
	remove_child(fresh)
	fresh.free()
	fx = FX.new(self)
	await fx.setup(&"sparrow", func(w: Variant) -> void:
		w.add_perch(Vector3(0, 40, -300), Vector3.FORWARD, 10.0)
		w.add_wall(Vector3(0, 100, -30), Vector3(60, 60, 1.0)))
	var p := fx.player
	var seen := {}
	var bad_total := 0
	var types_ok := true
	fx.on_tick = func(_tick: int, f: Variant) -> void:
		var t: Dictionary = f.player.telemetry()
		seen[t["mode"]] = true
		var bad := _all_finite(t)
		if not bad.is_empty():
			bad_total += 1
			print("[flight-verify] non-finite telemetry in %s: %s" % [t["mode"], bad])
		for k in ["stalled", "tucked", "perched"]:
			if not (t[k] is bool):
				types_ok = false
		for k in ["airspeed", "flapping", "wing_extension", "g_load"]:
			if not (t[k] is float):
				types_ok = false
	p.respawn(Transform3D(Basis.IDENTITY, Vector3(0, 100, 0)))
	fx.driver = func(_tick: int, t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		ScriptedPoseSource.flap(b, t, 45.0, 1.0)
	fx.run(0.6)
	p.start_flying(Vector3(0, 100, 0), 0.0, 0.0)
	fx.driver = func(_tick: int, _t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
	fx.run(6.0)  # into the wall at 30 m: STUNNED
	p.perch_on(World.find(get_tree()).get_perches()[0])
	fx.run(0.5)
	p.on_caught(null)
	fx.run(0.5)
	var modes := seen.keys()
	modes.sort()
	print("[flight-verify] telemetry modes seen: %s" % [modes])
	check(seen.has("spawning") and seen.has("flying") and seen.has("stunned") and seen.has("perched") and seen.has("caught"),
		"probe reached spawning, flying, stunned, perched, caught (%s)" % [modes])
	eq(bad_total, 0, "telemetry finite on every tick in every mode")
	check(types_ok, "telemetry bools are bool and floats are float")


# --- set_controls_enabled(false): no thrust from strokes ------------------------------
func test_controls_disabled_strokes_give_no_thrust() -> void:
	var res := {}
	for kind in ["glide", "flap_disabled", "flap_enabled"]:
		fx = FX.new(self)
		await fx.setup(&"pigeon")
		var p := fx.player
		p.start_flying(Vector3(0, 300, 0), 0.0, 0.0)
		if kind == "flap_disabled":
			p.set_controls_enabled(false)
		if kind != "glide":
			fx.driver = func(_tick: int, t: float, b: HumanPoseModel) -> void:
				b.set_airplane()
				ScriptedPoseSource.flap(b, t, 45.0, 1.0)
		fx.reset_events()
		fx.run(5.0)
		var e := p.model.position.y + p.model.velocity.length_squared() / (2.0 * 9.81)
		res[kind] = [e, fx.events["flapped"]]
		fx.teardown()
		fx = null
	print("[flight-verify] energy height after 5 s: %s" % [res])
	near(res["flap_disabled"][0], res["glide"][0], 0.05, "controls disabled: strokes add no energy (m of energy height vs a neutral glide)")
	eq(res["flap_disabled"][1], 0, "controls disabled: no player_flapped")
	gt(res["flap_enabled"][0] - res["glide"][0], 5.0, "controls enabled: the same strokes add energy (sanity)")
	metric("controls_energy", res)


# --- growth: flight never writes world_scale / near unless it owns them ----------------
func test_default_player_never_writes_world_scale_or_node_scale() -> void:
	XRServer.world_scale = 1.0
	var p := _bare(&"sparrow")
	add_child(p)
	await get_tree().process_frame
	var ws0 := p.origin.world_scale
	var near0 := p.camera.near
	p.start_flying(Vector3(0, 100, 0), 0.0, 0.0)
	for i in 30:
		p.tick(DT)
	p.mass = FlightParams.species_mass(&"eagle")
	for i in 30:
		p.tick(DT)
	eq(p.origin.world_scale, ws0, "drive_world_scale = false: world_scale untouched by growth (VR owns it)")
	eq(p.camera.near, near0, "drive_world_scale = false: camera near untouched (VR owns it)")
	vnear(p.scale, Vector3.ONE, 1e-6, "PlayerBird scale 1 after growth")
	vnear(p.origin.scale, Vector3.ONE, 1e-6, "XROrigin3D scale 1 after growth")
	eq(p.species, &"eagle", "species follows mass")
	print("[flight-verify] default player: world_scale %.3f near %.3f (scene near %.3f)" % [p.origin.world_scale, p.camera.near, near0])
	remove_child(p)
	p.free()


# --- event payloads -------------------------------------------------------------------
func test_event_payload_ranges() -> void:
	fx = FX.new(self)
	await fx.setup(&"sparrow", func(w: Variant) -> void:
		w.add_wall(Vector3(0, 100, -40), Vector3(60, 60, 1.0)))
	var p := fx.player
	var flaps := []
	var hits := []
	var on_f := func(side: int, s: float) -> void: flaps.append([side, s])
	var on_c := func(v: float, n: Vector3) -> void: hits.append([v, n])
	Events.player_flapped.connect(on_f)
	Events.player_collided.connect(on_c)
	p.start_flying(Vector3(0, 100, 0), 0.0, 0.0)
	fx.driver = func(_tick: int, t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		if t < 3.0:
			ScriptedPoseSource.flap(b, t, 45.0, 1.2)
		elif t < 5.0:
			ScriptedPoseSource.flap(b, t, 40.0, 1.0, -1)
	fx.run(8.0)
	Events.player_flapped.disconnect(on_f)
	Events.player_collided.disconnect(on_c)
	var bad_f := 0
	for e in flaps:
		if not (e[0] in [-1, 0, 1]) or not (e[1] >= 0.0 and e[1] <= 1.0):
			bad_f += 1
	var bad_c := 0
	for h in hits:
		if not (is_finite(h[0]) and h[0] >= 0.0 and absf((h[1] as Vector3).length() - 1.0) < 1e-3):
			bad_c += 1
	var zero_hits := hits.filter(func(h: Array) -> bool: return h[0] <= 0.0).size()
	print("[flight-verify] events: %d flapped (sides %s), %d collided (%d with impact 0)" % [flaps.size(), flaps.map(func(e: Array) -> int: return e[0]), hits.size(), zero_hits])
	gt(flaps.size(), 3, "strokes emitted player_flapped")
	eq(bad_f, 0, "player_flapped: side in {-1,0,1}, strength in 0..1")
	gt(hits.size(), 0, "wall hit emitted player_collided")
	eq(bad_c, 0, "player_collided: impact >= 0 finite, unit normal")
	metric("events", {"flapped": flaps.size(), "collided": hits.size(), "zero_impact": zero_hits})


# --- whole-chain determinism --------------------------------------------------------
func _chain_run() -> Array:
	fx = FX.new(self)
	await fx.setup(&"pigeon", func(w: Variant) -> void:
		w.add_wall(Vector3(40, 110, -60), Vector3(30, 60, 1.0))
		w.thermal_core = 3.5
		w.thermal_center = Vector3(0, 0, -40))
	var p := fx.player
	var cal := p.wing_input.calibration
	p.start_flying(Vector3(0, 100, 0), 0.0, 0.0)
	fx.driver = func(_tick: int, t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		if t < 4.0:
			ScriptedPoseSource.flap(b, t, 45.0, 1.1)
		elif t < 8.0:
			b.synth(0.1, -0.7, 1.0, cal)
		else:
			b.synth(-0.3, 0.4, 0.8, cal)
		b.humanize(DT)
	fx.run(14.0)
	var r := [p.model.position, p.model.velocity, p.model.heading(), p.rig_yaw, p.contacts.duplicate(), p._heave_off]
	fx.teardown()
	fx = null
	return r


func test_whole_chain_is_bitwise_deterministic() -> void:
	var a: Array = await _chain_run()
	var b: Array = await _chain_run()
	print("[flight-verify] chain run A %s | B %s" % [a, b])
	check(a[0] == b[0] and a[1] == b[1], "same poses -> bitwise the same position and velocity")
	check(a[2] == b[2] and a[3] == b[3], "same poses -> bitwise the same heading and rig yaw")
	check(str(a[4]) == str(b[4]) and a[5] == b[5], "same contacts and heave offset")


## The game's own respawn paths: after a catch (GameLoop: controls off, a
## 2.5 s beat, then respawn) and "Restart run" from a pause taken mid-turn
## (the tree is paused, the rig's yaw rate frozen, then respawn + unpause).
func test_game_respawn_paths_after_a_turn() -> void:
	var rows := []
	for path in ["after_catch_beat", "restart_from_pause"]:
		fx = FX.new(self)
		await fx.setup(&"sparrow")
		var p := fx.player
		p.start_flying(Vector3(0, 300, 0), 0.0, 0.0)
		fx.driver = fx.synth(0.0, 1.0)
		fx.run(3.0)
		if path == "after_catch_beat":
			p.on_caught(null)
			p.set_controls_enabled(false)
			fx.run(2.5)
			p.alive = true
		var rate0 := rad_to_deg(p.rig_yaw_rate)
		var yaw_t := -0.5
		p.respawn(Transform3D(Basis(Vector3.UP, yaw_t), Vector3(50, 120, 0)))
		p.set_controls_enabled(true)
		fx.driver = func(_tick: int, _t: float, b: HumanPoseModel) -> void:
			b.set_airplane()
		var drift := 0.0
		for i in int(0.45 / DT):
			fx.step()
			drift = maxf(drift, absf(rad_to_deg(wrapf(p.rig_yaw - yaw_t, -PI, PI))))
		rows.append([path, rate0, drift])
		print("[flight-verify] %s: rig rate at respawn %.0f deg/s, view drift while spawning %.1f deg" % [path, rate0, drift])
		lt(drift, 1.0, "%s: the view holds the respawn yaw (rig rate at respawn %.0f deg/s)" % [path, rate0])
		fx.teardown()
		fx = null
	metric("game_respawn_paths", rows)


## The same path in a real SceneTree: auto_process on, the tree paused
## mid-turn (the pause menu), respawn (UI Restart run -> GameLoop
## start_run -> respawn), unpause.
func test_restart_from_real_pause_mid_turn() -> void:
	var w := TW.new()
	add_child(w)
	var p := _bare(&"sparrow")
	p.auto_process = true
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
	await wait_physics(int(3.0 * Engine.physics_ticks_per_second))
	get_tree().paused = true
	await wait_physics(5)
	var rate0 := rad_to_deg(p.rig_yaw_rate)
	var yaw_t := 0.3
	p.respawn(Transform3D(Basis(Vector3.UP, yaw_t), Vector3(0, 60, 0)))
	roll[0] = 0.0
	get_tree().paused = false
	var drift := 0.0
	for i in int(0.45 * Engine.physics_ticks_per_second):
		await get_tree().physics_frame
		drift = maxf(drift, absf(rad_to_deg(wrapf(p.rig_yaw - yaw_t, -PI, PI))))
	print("[flight-verify] real-tree restart from pause: rig rate frozen at %.0f deg/s, view drift after unpause %.1f deg (mode %s)" % [rate0, drift, p.mode_name()])
	metric("real_tree_restart", {"rate0": rate0, "drift": drift})
	lt(drift, 1.0, "real tree: after a restart from a pause taken mid-turn the view holds the respawn yaw")
	src.driver = Callable()
	remove_child(p)
	p.free()
	remove_child(w)
	w.free()
