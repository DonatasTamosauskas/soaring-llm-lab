extends TestCase
## Round-2 engineering verifier probes for the flight area (not part of the
## area's suite). Each probe pins a contract or spec threshold that the
## area's own tests do not measure directly.
##   tools/gd.sh flight_verify2 --headless res://tests/runner.tscn -- --dir=res://tests/probes/flight --suite=r2eng_contract

const FX := preload("res://tests/unit/flight/pb_fixture.gd")
const PLAYER := preload("res://scenes/player/player.tscn")
const DEG := PI / 180.0
const DT := 1.0 / 72.0

var fx: FX


func after_each() -> void:
	if fx != null:
		fx.teardown()
		fx = null
	get_tree().paused = false
	await get_tree().process_frame


func _bare_player(auto := false) -> PlayerBird:
	var p := PLAYER.instantiate() as PlayerBird
	p.auto_process = auto
	p.use_settings = false
	p.default_source = &"none"
	p.mass = FlightParams.species_mass(&"sparrow")
	return p


# --- Bird contract: the registry forgets a freed player --------------------------
## Bird._enter_tree registers with Birds and Bird._exit_tree unregisters.
## PlayerBird overrides _exit_tree (pose recorder); in Godot 4 the parent's
## virtual is only called if the override chains to it.
func test_registry_forgets_the_player_on_exit() -> void:
	var n0 := Birds.count()
	var p := _bare_player()
	add_child(p)
	await get_tree().process_frame
	check(Birds.player() == p, "Birds.player() is the PlayerBird while in the tree")
	eq(Birds.count(), n0 + 1, "registered once")
	remove_child(p)
	var still := Birds.player() == p
	var cnt := Birds.count()
	p.free()
	check(not still, "Birds.player() cleared when the PlayerBird leaves the tree")
	eq(cnt, n0, "Birds.count() back to its value before the player")
	metric("registry_after_exit", {"player_still_registered": still, "count": cnt, "count_before": n0})
	# Keep the registry clean for whatever runs next if the probe found a leak.
	if still:
		var arr := Birds.all()
		for i in range(arr.size() - 1, -1, -1):
			if not is_instance_valid(arr[i]):
				arr.remove_at(i)
		Birds._player = null


## What a consumer sees after a PlayerBird is freed: Birds.nearby() walks the
## registry and touches the dangling entry (prints a SCRIPT ERROR if the
## player was never unregistered). Look for "SCRIPT ERROR" in the run log.
func test_registry_consumer_after_player_freed() -> void:
	var p := _bare_player()
	add_child(p)
	await get_tree().process_frame
	remove_child(p)
	p.free()
	var dangling := 0
	for b in Birds.all():
		if not is_instance_valid(b):
			dangling += 1
	eq(dangling, 0, "no freed birds left in Birds.all() after the PlayerBird is freed")
	print("[flight-verify] calling Birds.nearby() with %d dangling entries" % dangling)
	var near := Birds.nearby(Vector3.ZERO, 1e6)
	print("[flight-verify] Birds.nearby() returned %d" % near.size())
	# How an NPC asks (exclude = itself): the dangling entry is no longer
	# skipped by the `b == exclude` test and its `alive` is read.
	var npc := Bird.new()
	add_child(npc)
	print("[flight-verify] calling Birds.nearby(exclude = an NPC)")
	var near2 := Birds.nearby(Vector3.ZERO, 1e6, npc)
	print("[flight-verify] Birds.nearby(exclude) returned %d" % near2.size())
	remove_child(npc)
	npc.free()
	var arr := Birds.all()
	for i in range(arr.size() - 1, -1, -1):
		if not is_instance_valid(arr[i]):
			arr.remove_at(i)
	if not is_instance_valid(Birds._player):
		Birds._player = null


# --- ARCHITECTURE §4 / §7.6: pause freezes flight, the rig keeps processing -------
func test_real_tree_pause_freezes_flight_and_keeps_the_rig() -> void:
	var p := _bare_player(true)
	add_child(p)
	p.start_flying(Vector3(0, 300, 0), 0.0, 0.0)
	await wait_physics(6)
	var t0 := p.tick_count
	gt(t0, 3, "ticks while unpaused (auto_process)")
	var pos0 := p.model.position
	get_tree().paused = true
	await wait_physics(10)
	eq(p.tick_count, t0, "no flight ticks while the tree is paused")
	vnear(p.model.position, pos0, 1e-9, "model frozen while paused")
	check(not p.can_process(), "PlayerBird is pausable")
	var rig_ok := true
	var bad: Array[String] = []
	var stack: Array[Node] = [p.origin]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if not n.can_process():
			rig_ok = false
			bad.append(str(n.get_path()))
		stack.append_array(n.get_children())
	check(rig_ok, "every node under XROrigin3D processes while paused (bad: %s)" % str(bad))
	get_tree().paused = false
	await wait_physics(4)
	gt(p.tick_count, t0, "ticks resume after unpause")
	remove_child(p)
	p.free()


# --- PB-14 as the spec states it ------------------------------------------------
## FLIGHT_SPEC PB-14: "right hand lost 3 s mid-turn: no NaN; abs(phi) < 5 deg
## within 1.5 s after the loss decays; no flap events". The area's test
## asserts abs(phi) < 65 deg at the end (after the hand is back and turning
## again), which never measures the glide during the loss.
func test_pb14_spec_bank_levels_during_the_loss() -> void:
	fx = FX.new(self)
	await fx.setup(&"pigeon")
	var f := fx
	f.player.start_flying(Vector3(0, 300, 0), 0.0, 0.0)
	var cal := f.player.wing_input.calibration
	f.driver = func(_tick: int, t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		b.synth(0.0, 0.7, 1.0, cal)
		b.right_valid = not (t >= 2.0 and t < 5.0)
	var tr := {"phi_at": [], "roll_at": []}
	f.on_tick = func(_tick: int, fix: Variant) -> void:
		var t: float = fix.ticks * DT
		if t >= 2.0 + 0.85 + 1.5 and t < 5.0:
			tr["phi_at"].append(absf(rad_to_deg(fix.player.model.phi)))
			tr["roll_at"].append(absf(fix.player.wing_state().roll))
	f.run(2.0)
	gt(absf(f.player.model.phi), 0.3, "turning before the loss")
	f.run(3.0)
	var worst := 0.0
	for v in tr["phi_at"]:
		worst = maxf(worst, v)
	var worst_roll := 0.0
	for v in tr["roll_at"]:
		worst_roll = maxf(worst_roll, v)
	gt(tr["phi_at"].size(), 30, "sampled the window 1.5 s after the mirror blend")
	lt(worst, 5.0, "PB-14 (spec): |bank| < 5 deg from 1.5 s after the loss decays to the end of the loss")
	metric("pb14_worst_bank_deg_during_loss", worst)
	metric("pb14_worst_roll_input_during_loss", worst_roll)
	f.assert_comfort(self, "PB-14 probe")


# --- Determinism of the whole PlayerBird chain -----------------------------------
func _fly_once() -> Array:
	fx = FX.new(self)
	await fx.setup(&"sparrow")
	var f := fx
	f.player.start_flying(Vector3(0, 100, 0), 0.3, 0.0)
	var cal := f.player.wing_input.calibration
	f.driver = func(_tick: int, t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		# synth() writes the dihedral, so the stroke goes on top of it.
		b.synth(0.1 * sin(t), 0.5 * sin(0.4 * t), 1.0, cal)
		ScriptedPoseSource.flap(b, t, 40.0, 1.2)
		b.humanize(DT)
	f.run(12.0)
	var out := [f.player.model.position, f.player.model.velocity, f.player.rig_yaw, f.player.camera.global_position,
		f.player._heave_off]
	fx.teardown()
	fx = null
	return out


func test_playerbird_chain_is_deterministic() -> void:
	var a: Array = await _fly_once()
	var b: Array = await _fly_once()
	var same := true
	for i in a.size():
		if a[i] != b[i]:
			same = false
	check(same, "two identical scripted runs give bit-identical state (a %s / b %s)" % [str(a), str(b)])


# --- set_controls_enabled(false) removes thrust, not only events ---------------------
func test_controls_disabled_gives_no_thrust() -> void:
	var heights := []
	for flap in [false, true]:
		fx = FX.new(self)
		await fx.setup(&"sparrow")
		var f := fx
		f.player.start_flying(Vector3(0, 300, 0), 0.0, 0.0)
		f.player.set_controls_enabled(false)
		f.driver = func(_tick: int, t: float, b: HumanPoseModel) -> void:
			b.set_airplane()
			if flap:
				ScriptedPoseSource.flap(b, t, 45.0, 1.0)
		f.run(6.0)
		heights.append(f.player.model.position.y)
		fx.teardown()
		fx = null
	lt(absf(heights[1] - heights[0]), 0.05, "controls off: hard flapping changes altitude by < 5 cm vs holding still (m)")
	metric("controls_off_flap_minus_still_m", heights[1] - heights[0])


# --- Events: player_stalled once per stall; telemetry units ------------------------
func test_stall_event_once_per_stall_and_units() -> void:
	fx = FX.new(self)
	await fx.setup(&"sparrow")
	var f := fx
	f.player.start_flying(Vector3(0, 300, 0), 0.0, 0.0)
	f.driver = f.synth(1.0, 0.0)
	f.reset_events()
	var n0 := f.player.model.stall_count
	var tel := {"aoa_max": 0.0, "mismatch": 0}
	f.on_tick = func(_tick: int, fix: Variant) -> void:
		var t: Dictionary = fix.player.telemetry()
		tel["aoa_max"] = maxf(tel["aoa_max"], absf(float(t["aoa"])))
		if absf(float(t["aoa"]) - fix.player.model.alpha) > 1e-9 and not bool(t["perched"]):
			tel["mismatch"] += 1
	f.run(4.0)
	var n := f.player.model.stall_count - n0
	gt(n, 0, "held full nose-up stalls the player")
	eq(f.events["stalled"], n, "Events.player_stalled once per model stall")
	lt(tel["aoa_max"], 1.6, "telemetry aoa is in radians (|aoa| < pi/2)")
	eq(tel["mismatch"], 0, "telemetry aoa equals the model's alpha while flying")
	metric("stalls", n)


# --- Quest rules: growth is world_scale; near plane; no node scale -----------------
func test_growth_is_world_scale_only() -> void:
	fx = FX.new(self)
	await fx.setup(&"sparrow")
	var f := fx
	f.player.start_flying(Vector3(0, 300, 0), 0.0, 0.0)
	f.run(1.0)
	var ws0 := f.player.origin.world_scale
	var st := {"worst_step": 0.0, "prev": ws0, "near_ok": true, "scale_ok": true}
	f.on_tick = func(_tick: int, fix: Variant) -> void:
		var p: PlayerBird = fix.player
		var ws := p.origin.world_scale
		st["worst_step"] = maxf(st["worst_step"], absf(log(ws) - log(float(st["prev"]))))
		st["prev"] = ws
		var nr := p.camera.near / ws
		if (nr < 0.02 - 1e-6 or nr > 0.05 + 1e-6) and p.camera.near > 0.001 + 1e-9:
			st["near_ok"] = false
		for n: Node3D in [p, p.origin, p.camera, p.left_hand, p.right_hand]:
			if not n.scale.is_equal_approx(Vector3.ONE):
				st["scale_ok"] = false
	f.player.mass = FlightParams.species_mass(&"eagle")
	f.run(12.0)
	var ws1 := f.player.origin.world_scale
	gt(ws1 / ws0, 3.0, "world_scale grows sparrow -> eagle")
	check(st["near_ok"], "camera near stays within 0.02..0.05 x world_scale (ARCHITECTURE 7.5)")
	check(st["scale_ok"], "no node scale on the rig or the PlayerBird while growing")
	lt(st["worst_step"], 0.05, "world_scale ramps (log step per tick < 0.05)")
	metric("ws_sparrow", ws0)
	metric("ws_eagle", ws1)
	metric("near_over_ws", f.player.camera.near / ws1)
	f.assert_comfort(self, "growth probe")


# --- FLIGHT_SPEC 14.7 PERF-01: player tick <= 0.35 ms mean (dev Mac, debug) ----
## Not asserted or recorded anywhere in the area's suite. Measured here on the
## real rig in the flight test world (ground, a perch, a window), flapping and
## turning; the machine is shared, so the median of 5 batches is reported.
func test_perf01_player_tick_mean() -> void:
	for sp: StringName in [&"sparrow", &"eagle"]:
		fx = FX.new(self)
		await fx.setup(sp, func(w: Variant) -> void:
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
		var batches := PackedFloat64Array()
		for k in 5:
			var s := 0.0
			var n := 0
			for i in 144:
				f.step()
				s += f.player.tick_us
				n += 1
			batches.append(s / n)
		var arr := Array(batches)
		arr.sort()
		var med: float = arr[2]
		metric("%s_tick_mean_us_median_of_5" % sp, med)
		metric("%s_batches_us" % sp, arr)
		lt(med / 1000.0, 0.35, "%s PERF-01: player tick mean <= 0.35 ms (debug, shared machine)" % sp)
		fx.teardown()
		fx = null


# --- The whole PlayerBird chain at 72 / 90 / 120 Hz ------------------------------
## VR sets the physics rate to the display rate (ARCHITECTURE 5), so the
## player chain runs at 72, 90 or 120 Hz. The area's FM-24 checks the model
## alone; here the same scripted flapping turn is flown through poses ->
## WingInput -> PlayerBird at each rate: the end state agrees and the comfort
## caps (240 deg/s, 720 deg/s^2 +5 %) hold per tick at every rate.
func _fly_at(hz: float) -> Dictionary:
	fx = FX.new(self)
	await fx.setup(&"pigeon")
	var f := fx
	var p := f.player
	p.start_flying(Vector3(0, 200, 0), 0.0, 0.0)
	var cal := p.wing_input.calibration
	var src := ScriptedPoseSource.new(f.body, func(_tick: int, t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		b.synth(0.1, 0.7 if (t > 2.0 and t < 9.0) else -0.4 if t < 12.0 else 0.0, 1.0, cal)
		if t < 6.0:
			ScriptedPoseSource.flap(b, t, 40.0, 1.1))
	p.set_pose_source(src)
	var dt := 1.0 / hz
	var st := {"rate": 0.0, "acc": 0.0, "basis_bad": 0}
	var n := int(round(15.0 * hz))
	for i in n:
		p.tick(dt)
		if i > 3 and not p.yaw_flagged:
			st["rate"] = maxf(st["rate"], absf(rad_to_deg(p.rig_yaw_rate)))
			st["acc"] = maxf(st["acc"], absf(rad_to_deg(p.rig_yaw_accel)))
		if p.global_basis.y.dot(Vector3.UP) < 1.0 - 1e-6:
			st["basis_bad"] += 1
	var out := {"pos": p.model.position, "heading": p.model.heading(), "rate": st["rate"], "acc": st["acc"],
		"basis_bad": st["basis_bad"], "flaps": f.events["flapped"]}
	fx.teardown()
	fx = null
	return out


func test_chain_rate_independence_72_90_120() -> void:
	var r72: Dictionary = await _fly_at(72.0)
	gt(r72["flaps"], 3, "the scenario really flaps (72 Hz)")
	var res := {}
	for hz in [90.0, 120.0]:
		var r: Dictionary = await _fly_at(hz)
		res[hz] = r
		var d: float = (r["pos"] as Vector3).distance_to(r72["pos"])
		var travelled: float = (r72["pos"] as Vector3).distance_to(Vector3(0, 200, 0))
		lt(d / travelled, 0.03, "%d Hz: end position within 3%% of the path length of the 72 Hz run" % int(hz))
		lt(absf(rad_to_deg(wrapf(float(r["heading"]) - float(r72["heading"]), -PI, PI))), 5.0, "%d Hz: heading within 5 deg" % int(hz))
		lt(r["rate"], 240.0 + 1e-3, "%d Hz: rig yaw rate cap" % int(hz))
		lt(r["acc"], 756.0, "%d Hz: rig yaw accel cap" % int(hz))
		eq(r["basis_bad"], 0, "%d Hz: rig never pitches or rolls" % int(hz))
		near(float(r["flaps"]), float(r72["flaps"]), 1.0, "%d Hz: same number of flap events (+-1)" % int(hz))
		metric("hz_%d" % int(hz), {"d_m": d, "path_m": travelled, "heading_deg": rad_to_deg(r["heading"]), "rate": r["rate"], "acc": r["acc"], "flaps": r["flaps"]})
	metric("hz_72", {"heading_deg": rad_to_deg(r72["heading"]), "rate": r72["rate"], "acc": r72["acc"], "flaps": r72["flaps"]})
