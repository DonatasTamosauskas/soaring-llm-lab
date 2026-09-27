extends Node
## VERIFIER PROBE (integration, player-experience lens, round 1).
## The desktop game played on the keyboard (the real DesktopPoseSource ->
## WingInput -> FlightModel chain, keys through Input.parse_input_event,
## menus with the mouse): does flying feel like the brief?
##  - flat flap vs flap with wrists down (lift direction),
##  - leading edge up: balloon, then slower; hold it: stall and recovery,
##  - bank: heading follows, sideslip small, camera never rolls,
##  - tuck: dive, speed builds,
##  - sprint: how fast can the sparrow go flapping with wrists down,
##  - a thermal: circling in it without flapping, vs the same outside.
## Also: which onboarding lessons complete on the keyboard, and screenshots.
##
##   tools/gd.sh pxv_desk --rendering-method forward_plus --resolution 1280x720 --fixed-fps 72 res://tests/probes/integration/px_desk.tscn -- --fresh-settings
##
## Writes artifacts/integration/verify/px_desk.json, px_desk_*.png.

const Kit := preload("res://tests/unit/integration/game_kit.gd")

var kit: Kit
var main: GameMain
var out := {}
var lessons := []
var phases := {}
var cur_phase := ""
var cur_rows: Array = []
var shots := []


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_run.call_deferred()


func _key(code: Key, down: bool) -> void:
	var e := InputEventKey.new()
	e.keycode = code
	e.physical_keycode = code
	e.pressed = down
	Input.parse_input_event(e)


func _mouse_click(c: Control) -> void:
	var at := c.get_screen_transform() * (c.size * 0.5)
	var mv := InputEventMouseMotion.new()
	mv.position = at
	mv.global_position = at
	get_viewport().push_input(mv, true)
	await kit.frames(2)
	for down in [true, false]:
		var e := InputEventMouseButton.new()
		e.button_index = MOUSE_BUTTON_LEFT
		e.position = at
		e.global_position = at
		e.pressed = down
		get_viewport().push_input(e, true)
		await kit.frames(2)


func _shot(name: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png(Paths.artifacts("integration").path_join("verify/px_desk_%s.png" % name))
	var tel: Dictionary = main.player.telemetry()
	shots.append({"name": name, "state": Game.state_name(), "airspeed": tel["airspeed"], "bank_deg": rad_to_deg(tel["bank"]),
		"cam_roll_deg": rad_to_deg(main.player.camera.global_basis.get_euler().z)})


## Runs `secs` of game time holding `keys`, logging telemetry.
func _phase(name: String, keys: Array, secs: float) -> void:
	for k in keys:
		_key(k, true)
	var rows := []
	var n := int(secs * 72.0)
	for i in n:
		await get_tree().physics_frame
		var p := main.player
		var t: Dictionary = p.telemetry()
		var cb := p.camera.global_basis
		rows.append({
			"vx": p.velocity.x, "vy": p.velocity.y, "vz": p.velocity.z, "y": p.global_position.y,
			"as": t["airspeed"], "aoa": t["aoa"], "bank": t["bank"], "hdg": t["heading"], "yaw_rate": t["yaw_rate"],
			"slip": t["sideslip"], "stalled": t["stalled"], "flap": t["flapping"], "mode": t["mode"],
			"pitch_in": t["pitch_input"], "roll_in": t["roll_input"], "flap_force": t["flap_force"],
			"upd": t["in_updraft"], "cam_roll": cb.get_euler().z, "cam_pitch": cb.get_euler().x, "agl": t["altitude_agl"],
			"tuck": t["tucked"],
		})
	for k in keys:
		_key(k, false)
	phases[name] = _digest(rows)
	print("[integration] px_desk phase %-14s %s" % [name, phases[name]])


func _digest(rows: Array) -> Dictionary:
	if rows.is_empty():
		return {}
	var a: Dictionary = rows[0]
	var b: Dictionary = rows[rows.size() - 1]
	var dt := rows.size() / 72.0
	var v0 := Vector3(a["vx"], a["vy"], a["vz"])
	var v1 := Vector3(b["vx"], b["vy"], b["vz"])
	var h0 := Vector2(v0.x, v0.z)
	var fwd := h0.normalized() if h0.length() > 0.5 else Vector2(0, -1)
	var dv := v1 - v0
	var max_as := 0.0
	var min_as := INF
	var max_y := -INF
	var max_bank := 0.0
	var max_slip := 0.0
	var max_cam_roll := 0.0
	var stall_ticks := 0
	var flap_ticks := 0
	var upd_sum := 0.0
	var vy_sum := 0.0
	var t_max_y := 0.0
	var i := 0
	for r: Dictionary in rows:
		max_as = maxf(max_as, r["as"])
		min_as = minf(min_as, r["as"])
		if float(r["y"]) > max_y:
			max_y = r["y"]
			t_max_y = i / 72.0
		max_bank = maxf(max_bank, absf(r["bank"]))
		if absf(r["bank"]) > 0.1:
			max_slip = maxf(max_slip, absf(r["slip"]))
		max_cam_roll = maxf(max_cam_roll, absf(r["cam_roll"]))
		stall_ticks += 1 if r["stalled"] else 0
		flap_ticks += 1 if r["flap"] else 0
		upd_sum += float(r["upd"])
		vy_sum += float(r["vy"])
		i += 1
	var hdg_change := wrapf(float(b["hdg"]) - float(a["hdg"]), -PI, PI)
	return {
		"secs": snappedf(dt, 0.01), "as0": snappedf(a["as"], 0.01), "as1": snappedf(b["as"], 0.01),
		"as_max": snappedf(max_as, 0.01), "as_min": snappedf(min_as, 0.01),
		"dy": snappedf(float(b["y"]) - float(a["y"]), 0.01), "rise_max": snappedf(max_y - float(a["y"]), 0.01), "t_rise_max": snappedf(t_max_y, 0.01),
		"vy_mean": snappedf(vy_sum / rows.size(), 0.01),
		"dv_fwd": snappedf(Vector2(dv.x, dv.z).dot(fwd), 0.01), "dv_up": snappedf(dv.y, 0.01),
		"bank_max_deg": snappedf(rad_to_deg(max_bank), 0.1), "slip_max_deg": snappedf(rad_to_deg(max_slip), 0.1),
		"hdg_change_deg": snappedf(rad_to_deg(hdg_change), 0.1), "cam_roll_max_deg": snappedf(rad_to_deg(max_cam_roll), 0.01),
		"stall_frac": snappedf(float(stall_ticks) / rows.size(), 0.01), "flap_frac": snappedf(float(flap_ticks) / rows.size(), 0.01),
		"updraft_mean": snappedf(upd_sum / rows.size(), 0.01), "aoa0_deg": snappedf(rad_to_deg(a["aoa"]), 0.1),
		"aoa1_deg": snappedf(rad_to_deg(b["aoa"]), 0.1), "agl1": snappedf(b["agl"], 0.1), "mode1": b["mode"],
	}


func _run() -> void:
	kit = Kit.new()
	var ok := await kit.boot(self, false)
	main = kit.main
	if not ok:
		get_tree().quit()
		return
	main.ui.onboarding.lesson_completed.connect(func(i: int, id: StringName, timed_out: bool) -> void:
		lessons.append({"i": i, "id": String(id), "timed_out": timed_out, "t": snappedf(Game.run_time, 0.1)}))
	await kit.frames(10)
	await _shot("menu")
	await _mouse_click(kit.button(&"main", &"play"))
	await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 3.0)
	out["pose_source"] = main.player.pose_source.get_class() if main.player.pose_source else "none"
	out["desktop_source"] = main.player.pose_source is DesktopPoseSource
	await kit.advance(1.0)
	await _shot("play")
	main.game_loop.set_protection(main.player, 9999.0)
	# Onboarding as a keyboard player would do it: spread (arms are out by default), flap...
	await _phase("takeoff_flap", [KEY_SPACE], 5.0)
	await _shot("climb")
	await _phase("glide1", [], 3.0)
	await _phase("flat_flap", [KEY_SPACE], 3.0)
	await _phase("glide2", [], 3.0)
	await _phase("flap_wrists_down", [KEY_SPACE, KEY_W], 3.0)
	await _phase("glide3", [], 2.0)
	await _phase("wrists_down_noflap", [KEY_W], 3.0)
	await _phase("balloon_S_1_5s", [KEY_S], 1.5)
	await _phase("after_balloon", [], 3.0)
	await _phase("climb_again", [KEY_SPACE], 4.0)
	await _phase("hold_S_4s", [KEY_S], 4.0)
	await _phase("recover", [], 3.0)
	await _phase("climb_again2", [KEY_SPACE], 4.0)
	_key(KEY_D, true)
	await _phase("bank_right_a", [], 1.5)
	await _shot("bank_right")
	await _phase("bank_right_b", [], 2.5)
	_key(KEY_D, false)
	await _phase("level", [], 2.0)
	await _phase("bank_left", [KEY_A], 4.0)
	await _phase("climb_again3", [KEY_SPACE], 5.0)
	_key(KEY_SHIFT, true)
	await _phase("tuck_dive_a", [], 1.5)
	await _shot("dive")
	await _phase("tuck_dive_b", [], 1.5)
	_key(KEY_SHIFT, false)
	await _phase("pullout", [KEY_SPACE], 3.0)
	await _phase("sprint_flap_W", [KEY_SPACE, KEY_W], 10.0)
	await _shot("sprint")
	await _phase("sprint_flap_flat", [KEY_SPACE], 6.0)
	out["lessons"] = lessons.duplicate()
	# Pause with Escape and look at it.
	_key(KEY_ESCAPE, true)
	await kit.frames(2)
	_key(KEY_ESCAPE, false)
	await kit.frames(20)
	out["paused"] = Game.state == Game.State.PAUSED
	await _shot("pause")
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 500:
		await kit.frames(1)
	await _mouse_click(kit.button(&"pause", &"resume"))
	await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 2.0)
	out["resumed"] = Game.state == Game.State.PLAYING
	# A thermal: the meadow's (strongest, open ground). Circle in it with a
	# gentle bank and no flapping, then the same 250 m away from any thermal.
	var th: Dictionary = {}
	for x in main.world.get_thermals():
		if String(x["name"]) == "meadow":
			th = x
	if not th.is_empty():
		var c: Vector3 = th["position"]
		var p := main.player
		p.start_flying(c + Vector3(12, 45, 0), 0.0, 0.0)
		main.game_loop.teleported(p)
		await kit.advance(0.5)
		_key(KEY_A, true)
		await kit.advance(0.25)
		_key(KEY_A, false)
		# Tap A to hold a gentle left circle.
		var rows_start_y := p.global_position.y
		var t := 0.0
		var dist_max := 0.0
		while t < 25.0:
			_key(KEY_A, true)
			await kit.advance(0.35)
			_key(KEY_A, false)
			await kit.advance(0.35)
			t += 0.7
			dist_max = maxf(dist_max, Vector2(p.global_position.x - c.x, p.global_position.z - c.z).length())
		phases["thermal_circle"] = {"dy": snappedf(p.global_position.y - rows_start_y, 0.1), "secs": t,
			"max_dist_from_core": snappedf(dist_max, 0.1), "radius": th["radius"], "strength": th["strength"]}
		await _shot("thermal")
		var c2 := c + Vector3(-120, 0, 200)
		c2.y = main.world.ground_height(c2.x, c2.z)
		p.start_flying(c2 + Vector3(12, 45, 0), 0.0, 0.0)
		main.game_loop.teleported(p)
		await kit.advance(0.5)
		var y0 := p.global_position.y
		t = 0.0
		while t < 25.0:
			_key(KEY_A, true)
			await kit.advance(0.35)
			_key(KEY_A, false)
			await kit.advance(0.35)
			t += 0.7
		phases["no_thermal_circle"] = {"dy": snappedf(p.global_position.y - y0, 0.1), "secs": t}
		print("[integration] px_desk thermal %s vs %s" % [phases["thermal_circle"], phases["no_thermal_circle"]])
	out["phases"] = phases
	out["shots"] = shots
	out["errors"] = kit.log.errors
	out["warnings"] = kit.log.warnings
	out["log"] = kit.log.samples
	var f := FileAccess.open(Paths.artifacts("integration").path_join("verify/px_desk.json"), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(out, "  "))
		f.close()
	print("[integration] px_desk done: lessons %s; %s" % [lessons, kit.log.summary()])
	await kit.teardown()
	get_tree().quit()
