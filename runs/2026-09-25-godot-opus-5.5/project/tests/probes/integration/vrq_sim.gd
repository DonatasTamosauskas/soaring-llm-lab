extends Node3D
## VERIFIER PROBE (integration verify, round 1; lens: VR comfort, simulator
## and Quest readiness). Not a game file and not part of any suite.
##
## Runs the shipped scenes/main.tscn in the Meta XR Simulator (as a child of
## this node) while tests/probes/integration/vrq_sim_driver.py moves the
## simulator's own controllers and headset over SimRpc. Everything is
## judged from what the composed game does with real XR input:
##   session       FOCUSED, runtime refresh vs physics tick, ticks per frame
##   comfort       the rig (XROrigin3D) never pitches/rolls, yaw rate/accel
##   first launch  the calibration card vs the main menu; the explicit
##                 capture driven with the real controllers at the menu
##   pointer       Settings -> Back -> Play clicked with the real controller
##   growth        world_scale sparrow -> eagle: near plane, wings, UI sizes
##   pause         the real left menu button; head and hands keep tracking
##                 while paused (head turned with the simulator's keys)
##   resume        the real controller clicks Resume
##   flaps         real strokes: wingbeats and haptic pulses (no errors)
##   fps           20 s of play, frame pacing, draw calls
## Output: artifacts/integration/verify/vrq/<tag>_result.json, PNGs.
## Coordination with the driver: <dir>/state.json and <dir>/driver.json.

const MAIN := preload("res://scenes/main.tscn")
const LogScript := preload("res://tests/unit/integration/integration_log.gd")

var main: GameMain
var _logger: Object
var out_dir := ""
var tag := "run"
var res := {"checks": {}, "metrics": {}, "events": []}
var phase := "boot"
var aim := {}
var status := {}
var _drv := {}
var _drv_ms := -1000
var _state_ms := -1000
var _t0_ms := 0

# Per physics tick / per frame sampling.
var _ticks := 0
var _tick_hist := {}
var _hist_on := false
var comfort := {"ticks": 0, "max_tilt_deg": 0.0, "max_basis_scale_err": 0.0, "max_yaw_rate_dps": 0.0,
	"max_yaw_acc_dps2": 0.0, "flagged_ticks": 0, "origin_switches": 0, "max_near_err": 0.0,
	"yaw_rate_over_cap_ticks": 0, "yaw_acc_over_cap_ticks": 0, "worst_acc_at": {}}
var _yaw_prev := NAN
var _rate_prev := NAN
var _skip := 0
var _origin_id := 0
var _haptics := {}
var _flaps := 0
var _pause_track := {}
var _tracking_pause := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	process_physics_priority = 1000
	process_priority = 1000
	_t0_ms = Time.get_ticks_msec()
	tag = Paths.arg("tag", "run")
	out_dir = Paths.artifacts("integration").path_join("verify/vrq")
	DirAccess.make_dir_recursive_absolute(out_dir)
	DirAccess.remove_absolute(out_dir.path_join("driver.json"))
	_logger = LogScript.install()
	_write_state(true)
	Events.player_flapped.connect(func(_s: int, _st: float) -> void: _flaps += 1)
	Events.game_state_changed.connect(func(n: int, o: int) -> void:
		_event("state %s -> %s" % [Game.State.keys()[o], Game.State.keys()[n]]))
	VR.haptics.pulse_sent.connect(func(_h: int, _a: float, _d: float, pattern: StringName) -> void:
		_haptics[String(pattern)] = int(_haptics.get(String(pattern), 0)) + 1)
	main = MAIN.instantiate() as GameMain
	main.name = "Main"
	add_child(main)
	_run.call_deferred()


func _event(s: String) -> void:
	var line := "%.2f %s" % [(Time.get_ticks_msec() - _t0_ms) / 1000.0, s]
	res["events"].append(line)
	print("[integration-verify] ", line)


func _check(n: String, ok: bool, detail: Variant) -> void:
	res["checks"][n] = {"ok": ok, "detail": detail}
	print("[integration-verify] CHECK %s %s: %s" % ["PASS" if ok else "FAIL", n, str(detail)])


func _set_phase(p: String) -> void:
	phase = p
	_event("phase " + p)
	_write_state(true)


func _write_state(force := false) -> void:
	if not force and Time.get_ticks_msec() - _state_ms < 100:
		return
	_state_ms = Time.get_ticks_msec()
	var hov := ""
	if main != null and main.ui != null and main.ui.pointer != null:
		var h := main.ui.pointer.hovered()
		hov = String(h.name) if h != null else ""
	var d := {"phase": phase, "pid": OS.get_process_id(), "hovered": hov, "state": Game.state_name(),
		"aim": aim, "status": status, "t": Time.get_unix_time_from_system()}
	var f := FileAccess.open(out_dir.path_join("state.json"), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(d))


func _driver() -> Dictionary:
	if Time.get_ticks_msec() - _drv_ms < 150:
		return _drv
	_drv_ms = Time.get_ticks_msec()
	var f := FileAccess.open(out_dir.path_join("driver.json"), FileAccess.READ)
	if f == null:
		return _drv
	var j := JSON.new()
	if j.parse(f.get_as_text()) == OK and j.data is Dictionary:
		_drv = j.data
	return _drv


func _wall(s: float) -> void:
	var t := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t < int(s * 1000.0):
		await get_tree().process_frame


## Waits until cond() is true or `timeout` s pass; returns cond().
func _until(cond: Callable, timeout: float) -> bool:
	var t := Time.get_ticks_msec()
	while not cond.call() and Time.get_ticks_msec() - t < int(timeout * 1000.0):
		await get_tree().process_frame
	return cond.call()


func _physics_process(dt: float) -> void:
	_ticks += 1
	_sample_comfort(dt)


func _process(_dt: float) -> void:
	if _hist_on:
		_tick_hist[_ticks] = int(_tick_hist.get(_ticks, 0)) + 1
	_ticks = 0
	_update_aim()
	_update_status()
	if _tracking_pause:
		_track_pause()
	_write_state()


# ---------------------------------------------------------------------------
# Comfort: the rig's pose every physics tick (after PlayerBird's tick).

func _sample_comfort(dt: float) -> void:
	if main == null or main.player == null or not is_instance_valid(main.player):
		return
	var p := main.player
	var o := p.origin
	if o == null:
		return
	var g := o.global_transform
	var b := g.basis
	comfort["ticks"] += 1
	var tilt := rad_to_deg(b.y.normalized().angle_to(Vector3.UP))
	comfort["max_tilt_deg"] = maxf(comfort["max_tilt_deg"], tilt)
	var serr := maxf(absf(b.x.length() - 1.0), maxf(absf(b.y.length() - 1.0), absf(b.z.length() - 1.0)))
	comfort["max_basis_scale_err"] = maxf(comfort["max_basis_scale_err"], serr)
	var ws := o.world_scale
	var near_want := WorldScaleDriver.near_for(ws)
	comfort["max_near_err"] = maxf(comfort["max_near_err"], absf(p.camera.near - near_want) / near_want)
	var f := -b.z
	var yaw := atan2(-f.x, -f.z)
	var oid := o.get_instance_id()
	if oid != _origin_id:
		_origin_id = oid
		comfort["origin_switches"] += 1
		_yaw_prev = NAN
		_rate_prev = NAN
	if p.yaw_flagged or get_tree().paused or not p.auto_process:
		# A deliberate yaw step (respawn, recenter) or a still body: restart.
		if p.yaw_flagged:
			comfort["flagged_ticks"] += 1
		_yaw_prev = yaw
		_rate_prev = NAN
		return
	if not is_nan(_yaw_prev) and dt > 0.0:
		var rate := wrapf(yaw - _yaw_prev, -PI, PI) / dt
		var rd := rad_to_deg(absf(rate))
		comfort["max_yaw_rate_dps"] = maxf(comfort["max_yaw_rate_dps"], rd)
		var cap_r := rad_to_deg(p.model.comfort_yaw_rate)
		var cap_a := rad_to_deg(p.model.comfort_yaw_accel)
		comfort["cap_rate_dps"] = cap_r
		comfort["cap_acc_dps2"] = cap_a
		if cap_r > 0.0 and rd > cap_r * 1.001:
			comfort["yaw_rate_over_cap_ticks"] += 1
		if not is_nan(_rate_prev):
			var acc := rad_to_deg(absf(rate - _rate_prev)) / dt
			if acc > comfort["max_yaw_acc_dps2"]:
				comfort["max_yaw_acc_dps2"] = acc
				comfort["worst_acc_at"] = {"t": (Time.get_ticks_msec() - _t0_ms) / 1000.0, "mode": p.mode_name(),
					"state": Game.state_name(), "phase": phase}
			if cap_a > 0.0 and acc > cap_a * 1.01:
				comfort["yaw_acc_over_cap_ticks"] += 1
		_rate_prev = rate
	_yaw_prev = yaw


# ---------------------------------------------------------------------------
# Aim help for the driver: how far (tracking metres, rig axes) the right
# controller must translate so its laser lands on the wanted button.

func _update_aim() -> void:
	if not phase.begins_with("aim:") or main == null or main.ui == null or main.ui.pointer == null:
		if not aim.is_empty():
			aim = {}
		return
	var id := StringName(phase.substr(4))
	var scr := main.ui.current_screen()
	if scr == null:
		aim = {"error": "no screen"}
		return
	var btn := scr.get_button(id)
	if btn == null:
		aim = {"error": "no button %s on %s" % [id, main.ui.current_screen_id()]}
		return
	var tw := main.ui.menu_panel.control_to_world(btn)
	var src := main.ui.pointer.active_source()
	if src == null:
		aim = {"error": "no pointer source"}
		return
	var at := src.aim_transform()
	var o := at.origin
	var d := (-at.basis.z).normalized()
	var n := (tw - o).normalized()
	var den := d.dot(n)
	if den < 0.1:
		aim = {"error": "ray points away", "den": den}
		return
	var p := o + d * ((tw - o).dot(n) / den)
	var rig := main.player.origin
	var ws := maxf(rig.world_scale, 1e-4)
	var dt := rig.global_basis.inverse() * (tw - p) / ws
	aim = {"dx": dt.x, "dy": dt.y, "dz": dt.z, "target": "Btn_%s" % id, "hand": String(src.hand)}


## The calibrator's view of the pose (the driver closes its loop on it).
func _update_status() -> void:
	if main == null or main.rig_extras == null or main.rig_extras.calibration == null:
		return
	var cal := main.rig_extras.calibration
	var c := cal.calibrator
	var ax := []
	for i in 2:
		ax.append(snappedf(rad_to_deg(c.grip_axis_error(i)), 0.1))
	status = {"flow": VRCalibration.Flow.keys()[cal.flow], "calibrated": c.calibrated, "axis_deg": ax,
		"blocker": c.neutral_blocker(), "progress": snappedf(float(c.capture_status()["progress"]), 0.01),
		"gap": snappedf((c.hands[1].origin - c.hands[0].origin).length(), 0.001)}


# ---------------------------------------------------------------------------

func _run() -> void:
	if not main.is_loaded:
		await main.loaded
	await _until(func() -> bool: return VR.session_state == "focused", 20.0)
	var xr := XRServer.find_interface("OpenXR") as OpenXRInterface
	var disp := xr.display_refresh_rate if xr else 0.0
	_check("session_focused", VR.session_state == "focused" and VR.active, "%s, active %s" % [VR.session_state, VR.active])
	_check("physics_tick_equals_runtime_refresh", xr != null and Engine.physics_ticks_per_second == roundi(disp),
		"runtime display_refresh_rate %.2f, VR.refresh_rate %.1f, physics %d/s, available %s" % [disp, VR.refresh_rate,
		Engine.physics_ticks_per_second, xr.get_available_display_refresh_rates() if xr else []])
	if xr:
		res["metrics"]["render_target_size"] = str(xr.get_render_target_size())
		res["metrics"]["system"] = str(xr.get_system_info())
		res["metrics"]["foveation"] = {"supported": xr.is_foveation_supported(), "level": xr.foveation_level,
			"dynamic": xr.foveation_dynamic, "vrs_mode": get_viewport().vrs_mode}
		res["metrics"]["user_presence_supported"] = VR.presence_supported
	res["metrics"]["load"] = main.load_report
	res["metrics"]["quality"] = main.quality.name
	await _wall(1.0)
	await _first_launch_card()
	await _calibrate_at_menu()
	await _menu_navigation()
	await _flaps_and_haptics()
	await _fps_window()
	await _growth()
	await _fps_window("eagle")
	await _pause_and_head()
	await _resume_with_pointer()
	_finish()


## The first-launch card vs the main menu (both in front of the head).
func _first_launch_card() -> void:
	_set_phase("menu_card")
	var cal := main.rig_extras.calibration
	var up := cal.flow == VRCalibration.Flow.CAPTURE and cal.flow_reason == &"first_launch"
	var cam := main.player.camera
	var eye := cam.global_position
	var covered := []
	var detail := {}
	if up and cal.prompt != null:
		var pr := cal.prompt
		var ws := main.player.origin.world_scale
		var inv := pr.global_transform.affine_inverse()
		var half := Vector2(pr.width, CalibrationPrompt.SIZE.y) * ws * 0.5
		var scr := main.ui.get_screen(&"main")
		for id: StringName in [&"play", &"howto", &"settings", &"quit"]:
			var b := scr.get_button(id)
			if b == null:
				continue
			var w := main.ui.menu_panel.control_to_world(b)
			# Where the eye's line to the button's centre crosses the card.
			var le := inv * eye
			var lw := inv * w
			var dz := lw.z - le.z
			if absf(dz) < 1e-6:
				continue
			var t := -le.z / dz
			var hit := le + (lw - le) * t
			var inside := t > 0.0 and t < 1.0 and absf(hit.x) <= half.x and absf(hit.y) <= half.y
			detail[String(id)] = {"inside_card": inside, "card_xy": [snappedf(hit.x / ws, 0.001), snappedf(hit.y / ws, 0.001)]}
			if inside:
				covered.append(String(id))
		detail["card_m"] = [snappedf(pr.width, 0.01), CalibrationPrompt.SIZE.y]
	res["metrics"]["first_launch_card"] = detail
	_check("first_launch_card_shown_at_menu", up, "flow %s reason %s, state %s" % [VRCalibration.Flow.keys()[cal.flow], cal.flow_reason, Game.state_name()])
	_check("first_launch_card_leaves_menu_buttons_visible", covered.is_empty(), "main-menu buttons hidden behind the card: %s" % [covered])
	await main.mirror.capture(out_dir.path_join("%s_menu_card.png" % tag))


## A new player does what the card says with the real controllers: the
## driver spreads them (closed loop on the calibrator's reading).
func _calibrate_at_menu() -> void:
	var cal := main.rig_extras.calibration
	var blockers := {}
	_set_phase("calibrate")
	var t := Time.get_ticks_msec()
	var done := false
	while Time.get_ticks_msec() - t < 60000:
		await get_tree().process_frame
		if cal.flow == VRCalibration.Flow.CAPTURE:
			var bl := String(status.get("blocker", ""))
			blockers[bl] = int(blockers.get(bl, 0)) + 1
		if cal.calibrator.calibrated:
			done = true
			break
		if _driver().get("spread_error", "") != "":
			break
	var drv := _driver()
	_check("calibration_captured_at_menu_with_real_controllers", done and Game.state == Game.State.MENU,
		{"calibrated": cal.calibrator.calibrated, "flow": VRCalibration.Flow.keys()[cal.flow], "text": cal.prompt_text(),
		"span": snappedf(cal.calibrator.arm_span, 0.001), "blocker_frames": blockers, "status": status,
		"driver_error": drv.get("spread_error", ""), "state": Game.state_name()})
	await _wall(0.3)
	await main.mirror.capture(out_dir.path_join("%s_calibrated.png" % tag))
	_set_phase("relax")
	await _until(func() -> bool: return bool(_driver().get("relaxed", false)), 20.0)
	await _until(func() -> bool: return cal.flow == VRCalibration.Flow.IDLE, 5.0)
	_check("card_gone_after_capture", cal.flow == VRCalibration.Flow.IDLE and (cal.prompt == null or not cal.prompt.visible),
		"flow %s" % VRCalibration.Flow.keys()[cal.flow])


func _click(id: String, want: Callable, timeout := 45.0) -> bool:
	_set_phase("aim:" + id)
	var ok := await _until(want, timeout)
	_event("click %s -> %s (screen %s, state %s)" % [id, ok, main.ui.current_screen_id(), Game.state_name()])
	_set_phase("aimed")
	await _wall(0.8)
	return ok


func _menu_navigation() -> void:
	await main.mirror.capture(out_dir.path_join("%s_menu.png" % tag))
	var ok1 := await _click("settings", func() -> bool: return main.ui.current_screen_id() == &"settings")
	await main.mirror.capture(out_dir.path_join("%s_settings.png" % tag))
	var ok2 := await _click("back", func() -> bool: return main.ui.current_screen_id() == &"main")
	var ok3 := await _click("play", func() -> bool: return Game.state == Game.State.PLAYING)
	_check("menus_usable_with_real_pointer", ok1 and ok2 and ok3, "Settings %s, Back %s, Play %s" % [ok1, ok2, ok3])
	if Game.state != Game.State.PLAYING:
		main.game_loop.start_run()
	main.game_loop.set_protection(main.player, 1e6)


## Growth sparrow -> eagle through the game loop's own mass path.
func _growth() -> void:
	_set_phase("growth")
	await _wall(1.0)
	var rows := []
	var cam := main.player.camera
	var o := main.player.origin
	var wings := main.rig_extras.wings
	var drv := main.rig_extras.world_scale_driver
	var max_rate := 0.0
	await main.mirror.capture(out_dir.path_join("%s_grow_sparrow.png" % tag))
	for i in range(SizeRules.species_index(&"sparrow"), SizeRules.SPECIES.size()):
		var m := float(SizeRules.SPECIES[i]["mass"]) * 1.02
		if i > SizeRules.species_index(&"sparrow"):
			main.game_loop.call(&"_set_player_mass", main.player, m, &"meal")
		var t := Time.get_ticks_msec()
		var prev := o.world_scale
		var n_ticks := 0
		while Time.get_ticks_msec() - t < 15000:
			await get_tree().physics_frame
			n_ticks += 1
			# Per physics tick (the driver steps once per tick).
			max_rate = maxf(max_rate, absf(log(o.world_scale / prev)) * Engine.physics_ticks_per_second)
			prev = o.world_scale
			if n_ticks > 3 and absf(o.world_scale - drv.target) < 1e-4:
				break
		await _wall(0.2)
		var ws := o.world_scale
		var hud_d := main.ui.hud_panel.global_position.distance_to(cam.global_position) / ws
		var lh := main.rig_extras.left_hand
		var tip_d := (wings.wingtip(0) - lh.transform.origin).length() / ws if lh else -1.0
		rows.append({"species": String(SizeRules.SPECIES[i]["id"]), "mass": snappedf(main.player.mass, 0.0001),
			"ws": snappedf(ws, 0.0001), "target": snappedf(drv.target, 0.0001), "near": snappedf(cam.near, 0.00001),
			"near_over_ws": snappedf(cam.near / ws, 0.0001), "hud_dist_over_ws": snappedf(hud_d, 0.001),
			"wingtip_from_grip_over_ws": snappedf(tip_d, 0.001), "npcs": main.ecosystem.count(),
			"mode": main.player.mode_name()})
	res["metrics"]["growth"] = rows
	res["metrics"]["growth_max_rate_ln_per_s"] = max_rate
	var first: Dictionary = rows[0]
	var last: Dictionary = rows[rows.size() - 1]
	var hud_const := absf(float(first["hud_dist_over_ws"]) - float(last["hud_dist_over_ws"])) < 0.05
	var near_ok := true
	for r: Dictionary in rows:
		near_ok = near_ok and absf(float(r["near_over_ws"]) - WorldScaleDriver.NEAR_K) < 0.001 and absf(float(r["ws"]) - float(r["target"])) < 0.002
	_check("growth_world_scale_near_hud", near_ok and hud_const and max_rate <= WorldScaleDriver.MAX_RATE * 1.05 and float(last["ws"]) > 5.0 * float(first["ws"]),
		"ws %.3f -> %.3f, near/ws %.4f -> %.4f, HUD distance/ws %.3f -> %.3f, wingtip-grip/ws %.3f -> %.3f, max ramp %.3f ln/s" % [
		first["ws"], last["ws"], first["near_over_ws"], last["near_over_ws"], first["hud_dist_over_ws"], last["hud_dist_over_ws"],
		first["wingtip_from_grip_over_ws"], last["wingtip_from_grip_over_ws"], max_rate])
	await main.mirror.capture(out_dir.path_join("%s_grow_eagle.png" % tag))


## The real left menu button pauses; the head and hands keep tracking.
func _pause_and_head() -> void:
	_set_phase("pause_button")
	var paused := await _until(func() -> bool: return Game.state == Game.State.PAUSED, 20.0)
	_check("real_menu_button_pauses", paused and main.ui.current_screen_id() == &"pause" and get_tree().paused,
		"state %s, screen %s, tree paused %s" % [Game.state_name(), main.ui.current_screen_id(), get_tree().paused])
	await _wall(0.8)
	await main.mirror.capture(out_dir.path_join("%s_pause.png" % tag))
	var o := main.player.origin
	var ws := o.world_scale
	var menu_d := main.ui.menu_panel.global_position.distance_to(main.player.camera.global_position) / ws
	res["metrics"]["pause_menu_dist_over_ws_at_eagle"] = menu_d
	_pause_track = {"yaw0": NAN, "yaw_min": 0.0, "yaw_max": 0.0, "origin0": o.global_transform, "origin_moved": 0.0,
		"hmd_yaw_min": 0.0, "hmd_yaw_max": 0.0, "hmd_yaw0": NAN, "right0": main.rig_extras.right_hand.position,
		"right_moved": 0.0, "frames": 0, "paused_frames": 0, "body_pos0": main.player.global_position, "body_moved": 0.0}
	_tracking_pause = true
	var rc0 := VR.recenter_count
	_set_phase("head_turn")
	await _until(func() -> bool: return bool(_driver().get("head_turned", false)), 30.0)
	await _wall(0.4)
	var yaw_before := _cam_local_yaw()
	_set_phase("recenter")
	var rc_ok := await _until(func() -> bool: return VR.recenter_count > rc0, 12.0)
	await _wall(0.5)
	var yaw_after := _cam_local_yaw()
	_check("recenter_with_ax_hold_while_paused", rc_ok and absf(yaw_after) < 3.0 and absf(yaw_before) > 10.0,
		"recenters %d -> %d; head yaw in the rig %.1f deg before, %.1f deg after (state %s)" % [rc0, VR.recenter_count, yaw_before, yaw_after, Game.state_name()])
	_set_phase("head_back")
	await _until(func() -> bool: return bool(_driver().get("head_turn_done", false)), 30.0)
	await _wall(0.5)
	_tracking_pause = false
	var pt := _pause_track
	var yaw_span := rad_to_deg(float(pt["yaw_max"]) - float(pt["yaw_min"]))
	var hmd_span := rad_to_deg(float(pt["hmd_yaw_max"]) - float(pt["hmd_yaw_min"]))
	_check("pause_keeps_head_and_hands_tracking", Game.state == Game.State.PAUSED and yaw_span > 10.0 and hmd_span > 10.0
		and float(pt["right_moved"]) > 0.02 and float(pt["origin_moved"]) < 1e-4 and float(pt["body_moved"]) < 1e-4,
		"while paused (%d frames): XRCamera3D yaw span %.1f deg, XRServer HMD yaw span %.1f deg, right grip moved %.3f m (tracking), rig moved %.6f, body moved %.6f" % [
		pt["paused_frames"], yaw_span, hmd_span, pt["right_moved"], pt["origin_moved"], pt["body_moved"]])


func _cam_local_yaw() -> float:
	var f := -main.player.camera.transform.basis.z
	return rad_to_deg(atan2(-f.x, -f.z))


func _track_pause() -> void:
	var pt := _pause_track
	pt["frames"] += 1
	if get_tree().paused:
		pt["paused_frames"] += 1
	var cam := main.player.camera
	var f := -cam.transform.basis.z
	var yaw := atan2(-f.x, -f.z)
	if is_nan(float(pt["yaw0"])):
		pt["yaw0"] = yaw
	var dy := wrapf(yaw - float(pt["yaw0"]), -PI, PI)
	pt["yaw_min"] = minf(pt["yaw_min"], dy)
	pt["yaw_max"] = maxf(pt["yaw_max"], dy)
	var hf := -XRServer.get_hmd_transform().basis.z
	var hy := atan2(-hf.x, -hf.z)
	if is_nan(float(pt["hmd_yaw0"])):
		pt["hmd_yaw0"] = hy
	var dh := wrapf(hy - float(pt["hmd_yaw0"]), -PI, PI)
	pt["hmd_yaw_min"] = minf(pt["hmd_yaw_min"], dh)
	pt["hmd_yaw_max"] = maxf(pt["hmd_yaw_max"], dh)
	var ws := maxf(main.player.origin.world_scale, 1e-4)
	pt["right_moved"] = maxf(pt["right_moved"], (main.rig_extras.right_hand.position - (pt["right0"] as Vector3)).length() / ws)
	var og := main.player.origin.global_transform
	pt["origin_moved"] = maxf(pt["origin_moved"], (og.origin - (pt["origin0"] as Transform3D).origin).length())
	pt["body_moved"] = maxf(pt["body_moved"], (main.player.global_position - (pt["body_pos0"] as Vector3)).length())


func _resume_with_pointer() -> void:
	var ok := await _click("resume", func() -> bool: return Game.state == Game.State.PLAYING)
	_check("resume_with_real_pointer", ok, "state %s" % Game.state_name())
	if Game.state != Game.State.PLAYING:
		main.ui.resume()


func _flaps_and_haptics() -> void:
	var f0 := _flaps
	var h0 := _haptics.duplicate()
	var sink: Object = VR.haptics.sink
	var calls0 := int(sink.get("calls")) if sink != null and "calls" in sink else -1
	var e0: int = _logger.errors + _logger.warnings
	_set_phase("spread_flap")
	await _until(func() -> bool: return bool(_driver().get("flaps_done", false)), 90.0)
	await _wall(0.5)
	var calls1 := int(sink.get("calls")) if sink != null and "calls" in sink else -1
	var diff := {}
	for k: String in _haptics:
		var d := int(_haptics[k]) - int(h0.get(k, 0))
		if d != 0:
			diff[k] = d
	_check("real_strokes_flap_and_pulse_haptics", _flaps - f0 >= 2 and calls1 - calls0 > 0 and (_logger.errors + _logger.warnings) == e0,
		"%d wingbeats, %d trigger_haptic_pulse calls to the runtime, patterns %s, stats %s, new errors/warnings %d" % [
		_flaps - f0, calls1 - calls0, diff, VR.haptics.stats, _logger.errors + _logger.warnings - e0])


func _fps_window(label := "sparrow") -> void:
	_set_phase("fps_" + label)
	var xr := XRServer.find_interface("OpenXR") as OpenXRInterface
	var hz := xr.display_refresh_rate if xr else 72.0
	_tick_hist.clear()
	_hist_on = true
	var intervals := PackedFloat32Array()
	var d3max := 0
	var d3sum := 0.0
	var pmax := 0
	var n := 0
	var tw := Time.get_ticks_usec()
	var prev := tw
	while Time.get_ticks_usec() - tw < 20000000:
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		intervals.append((now - prev) / 1000.0)
		prev = now
		n += 1
		var rid := get_viewport().get_viewport_rid()
		var d3 := RenderingServer.viewport_get_render_info(rid, RenderingServer.VIEWPORT_RENDER_INFO_TYPE_VISIBLE, RenderingServer.VIEWPORT_RENDER_INFO_DRAW_CALLS_IN_FRAME) \
			+ RenderingServer.viewport_get_render_info(rid, RenderingServer.VIEWPORT_RENDER_INFO_TYPE_SHADOW, RenderingServer.VIEWPORT_RENDER_INFO_DRAW_CALLS_IN_FRAME)
		d3max = maxi(d3max, d3)
		d3sum += d3
		pmax = maxi(pmax, int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)))
	_hist_on = false
	var secs := (Time.get_ticks_usec() - tw) / 1e6
	var v := intervals.duplicate()
	v.sort()
	var pct := func(q: float) -> float: return snappedf(v[clampi(int(ceil(q * v.size())) - 1, 0, v.size() - 1)], 0.01)
	var late := 0
	for x in v:
		if x > 1.5 * 1000.0 / hz:
			late += 1
	var hist := {}
	for k in _tick_hist:
		hist[str(k)] = _tick_hist[k]
	var out := []
	OS.execute("sysctl", ["-n", "vm.loadavg"], out)
	var fps := n / secs
	res["metrics"]["fps_" + label] = {"fps": fps, "hz": hz, "p50": pct.call(0.5), "p95": pct.call(0.95), "p99": pct.call(0.99),
		"late_frames": late, "frames": n, "ticks_per_frame_hist": hist, "draw3d_max": d3max, "draw3d_mean": d3sum / maxi(n, 1),
		"prims_max": pmax, "npcs": main.ecosystem.count(), "species": String(main.player.species),
		"load": String(out[0]).strip_edges() if not out.is_empty() else ""}
	_check("fps_at_refresh_" + label, fps >= 0.95 * hz, "%.2f fps at %.0f Hz, p50 %.2f p95 %.2f p99 %.2f ms, %d late frames, ticks/frame %s, %d NPCs, load %s" % [
		fps, hz, pct.call(0.5), pct.call(0.95), pct.call(0.99), late, hist, main.ecosystem.count(), res["metrics"]["fps_" + label]["load"]])
	await main.mirror.capture(out_dir.path_join("%s_flight_%s.png" % [tag, label]))


func _finish() -> void:
	res["metrics"]["comfort"] = comfort
	_check("rig_never_pitches_or_rolls", comfort["max_tilt_deg"] < 0.01 and comfort["max_basis_scale_err"] < 1e-4,
		"max tilt %.5f deg, basis scale error %.6f over %d ticks" % [comfort["max_tilt_deg"], comfort["max_basis_scale_err"], comfort["ticks"]])
	_check("yaw_within_comfort_caps", comfort["yaw_rate_over_cap_ticks"] == 0 and comfort["yaw_acc_over_cap_ticks"] == 0,
		"max yaw rate %.1f deg/s (cap %.1f), max yaw accel %.1f deg/s^2 (cap %.1f) at %s; %d flagged teleport ticks" % [
		comfort["max_yaw_rate_dps"], comfort.get("cap_rate_dps", -1.0), comfort["max_yaw_acc_dps2"], comfort.get("cap_acc_dps2", -1.0),
		comfort["worst_acc_at"], comfort["flagged_ticks"]])
	_check("near_plane_tracks_world_scale", comfort["max_near_err"] < 0.01, "max relative error %.4f" % comfort["max_near_err"])
	_check("no_errors_or_warnings", _logger.errors == 0 and _logger.warnings == 0, _logger.summary())
	var ok := true
	for k in res["checks"]:
		ok = ok and bool(res["checks"][k]["ok"])
	res["pass"] = ok
	var f := FileAccess.open(out_dir.path_join("%s_result.json" % tag), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(res, "  "))
	print("[integration-verify] RESULT %s" % ("PASS" if ok else "FAIL"))
	_set_phase("done")
	_logger.uninstall()
	main.quit_game()
