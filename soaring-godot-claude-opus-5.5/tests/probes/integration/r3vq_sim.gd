extends Node3D
## VERIFIER PROBE (integration verify round 3; lens: VR comfort, simulator
## and Quest readiness). Not a game file and not part of any suite.
## Derived from round 2's r2vq_sim.gd; extended for round 2's fixes (turn
## speed setting, recenter while paused turns once, the recalibration card
## hides the menus, player.tscn near plane) and the hold-to-quit path.
##
## Runs the shipped scenes/main.tscn in the Meta XR Simulator (as a child of
## this node) on a FIRST LAUNCH (the wrapper empties this sandbox's user://)
## while tests/probes/integration/r3vq_sim_driver.py moves the simulator's
## own controllers and headset over SimRpc. Judged from what the composed
## game does with real XR input:
##   session     FOCUSED, runtime refresh vs physics tick
##   menu        nothing over the main menu; Settings (Turn speed there) ->
##               Back with the real pointer
##   gate/skip   Play (real pointer) -> the card alone; a real B press skips:
##               "Calibration skipped / Using default wings", the run starts
##   flaps       real strokes with DEFAULT wings: wingbeats, haptic pulses
##   haptics     every pattern through the real runtime: no errors
##   fps         20 s windows (sparrow, eagle), draw calls, render CPU
##   growth      world_scale sparrow -> eagle: near plane, wings, HUD, menus
##   pause       real left menu button; head/hands keep tracking; A/X hold
##               recenters while paused; Resume (real pointer) turns nothing
##   recal       Y held in play (eagle) -> paused + card, menus hidden;
##               spread -> capture -> menus back
##   presence    headset off/on -> paused, "New player?" -> card, menus
##               hidden -> B cancels, nothing changed -> menus back
##   quit        hold Quit to menu (real trigger) -> MENU on the perch;
##               hold Quit (real trigger) -> the game's quit path
##   comfort     every physics tick: the rig never pitches/rolls; yaw rate
##               and acceleration within the player's Turn speed caps
## Output: artifacts/integration/verify/r3vq/<tag>_result.json, PNGs.

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

var _ticks := 0
var _tick_hist := {}
var _hist_on := false
var comfort := {"ticks": 0, "max_tilt_deg": 0.0, "max_basis_scale_err": 0.0, "max_yaw_rate_dps": 0.0,
	"max_yaw_acc_dps2": 0.0, "flagged_ticks": 0, "flagged_yaw_steps": [], "max_flagged_yaw_step_deg": 0.0,
	"max_near_err": 0.0, "near_err_at": {}, "yaw_rate_over_cap_ticks": 0, "yaw_acc_over_cap_ticks": 0, "worst_acc_at": {},
	"worst_rate_at": {}, "yaw_rate_hist": {}, "max_ws_rate": 0.0, "max_vignette": 0.0, "playing_ticks": 0,
	"ticks_over_90dps": 0, "ticks_over_150dps": 0, "max_step_after_resume_deg": {}}
var _yaw_prev := NAN
var _rate_prev := NAN
var _ws_prev := NAN
var _origin_id := 0
var _haptics := {}
var _flaps := 0
var _pause_track := {}
var _tracking_pause := false
var _render_on := false
var _render_cpu := PackedFloat32Array()
var _setup_cpu := PackedFloat32Array()
## Ticks left in a "just resumed" window and its label (the view must not
## turn at Resume: round 2's recenter-while-paused fix).
var _resume_watch := 0
var _resume_label := ""
var _menu_hidden_frames := {}
## Ticks to leave out of the yaw checks after a probe teleport
## (PlayerBird.start_flying is a dev/test API the game never calls).
var _skip_comfort := 0
var _over_cap_events: Array = []


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	process_physics_priority = 1000
	process_priority = 1000
	_t0_ms = Time.get_ticks_msec()
	tag = Paths.arg("tag", "run")
	out_dir = Paths.artifacts("integration").path_join("verify/r3vq")
	DirAccess.make_dir_recursive_absolute(out_dir)
	DirAccess.remove_absolute(out_dir.path_join("driver.json"))
	DirAccess.remove_absolute(out_dir.path_join("%s_quit.json" % tag))
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
	main.quit_started.connect(_on_quit_started)
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


func _until(cond: Callable, timeout: float) -> bool:
	var t := Time.get_ticks_msec()
	while not cond.call() and Time.get_ticks_msec() - t < int(timeout * 1000.0):
		await get_tree().process_frame
	return cond.call()


## "spiral" mode: extra main-thread work per physics tick (us), to bring
## the M1's per-tick cost up to the Quest Pro estimate (x3-4).
var _pad_us := 0


func _physics_process(dt: float) -> void:
	if _pad_us > 0:
		OS.delay_usec(_pad_us)
	_ticks += 1
	_sample_comfort(dt)


func _process(_dt: float) -> void:
	if _hist_on:
		_tick_hist[_ticks] = int(_tick_hist.get(_ticks, 0)) + 1
	_ticks = 0
	if _render_on:
		var rid := get_viewport().get_viewport_rid()
		_render_cpu.append(RenderingServer.viewport_get_measured_render_time_cpu(rid))
		_setup_cpu.append(RenderingServer.get_frame_setup_time_cpu())
	_update_aim()
	_update_status()
	if _tracking_pause:
		_track_pause()
	# While a calibration card for a step the player asked for is up, is any
	# menu shown with it? (round 2's fix: the menus make way.)
	if main != null and main.rig_extras != null and main.ui != null:
		var cal := main.rig_extras.calibration
		if cal != null and cal.flow == VRCalibration.Flow.CAPTURE and cal.flow_reason == &"manual":
			var k := "menu_shown" if main.ui.menu_panel.shown else "menu_hidden"
			_menu_hidden_frames[k] = int(_menu_hidden_frames.get(k, 0)) + 1
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
	var nerr := absf(p.camera.near - near_want) / near_want
	if nerr > comfort["max_near_err"]:
		comfort["max_near_err"] = nerr
		comfort["near_err_at"] = {"t": (Time.get_ticks_msec() - _t0_ms) / 1000.0, "near": p.camera.near, "ws": ws, "phase": phase,
			"state": Game.state_name()}
	if main.rig_extras != null and main.rig_extras.vignette != null:
		comfort["max_vignette"] = maxf(comfort["max_vignette"], main.rig_extras.vignette.strength())
	var f := -b.z
	var yaw := atan2(-f.x, -f.z)
	var oid := o.get_instance_id()
	if oid != _origin_id:
		_origin_id = oid
		_yaw_prev = NAN
		_rate_prev = NAN
		_ws_prev = NAN
	if _skip_comfort > 0:
		_skip_comfort -= 1
		_yaw_prev = yaw
		_rate_prev = NAN
		_ws_prev = ws
		return
	if _resume_watch > 0 and not get_tree().paused and not is_nan(_yaw_prev):
		_resume_watch -= 1
		var st := rad_to_deg(absf(wrapf(yaw - _yaw_prev, -PI, PI)))
		comfort["max_step_after_resume_deg"][_resume_label] = maxf(float(comfort["max_step_after_resume_deg"].get(_resume_label, 0.0)), st)
	if p.yaw_flagged:
		comfort["flagged_ticks"] += 1
		if not is_nan(_yaw_prev):
			var step := rad_to_deg(absf(wrapf(yaw - _yaw_prev, -PI, PI)))
			comfort["max_flagged_yaw_step_deg"] = maxf(comfort["max_flagged_yaw_step_deg"], step)
			if step > 1.0 and (comfort["flagged_yaw_steps"] as Array).size() < 40:
				comfort["flagged_yaw_steps"].append({"t": (Time.get_ticks_msec() - _t0_ms) / 1000.0, "deg": snappedf(step, 0.1),
					"mode": p.mode_name(), "state": Game.state_name(), "phase": phase})
		_yaw_prev = yaw
		_rate_prev = NAN
		_ws_prev = ws
		return
	if not is_nan(_ws_prev) and dt > 0.0 and ws > 0.0 and _ws_prev > 0.0 and not get_tree().paused:
		comfort["max_ws_rate"] = maxf(comfort["max_ws_rate"], absf(log(ws / _ws_prev)) / dt)
	_ws_prev = ws
	if get_tree().paused or not p.auto_process:
		if not is_nan(_yaw_prev):
			var pst := rad_to_deg(absf(wrapf(yaw - _yaw_prev, -PI, PI)))
			if pst > 1.0 and (comfort["flagged_yaw_steps"] as Array).size() < 40:
				comfort["flagged_yaw_steps"].append({"t": (Time.get_ticks_msec() - _t0_ms) / 1000.0, "deg": snappedf(pst, 0.1),
					"mode": p.mode_name(), "state": Game.state_name(), "phase": phase, "unflagged_while_still": true})
		_yaw_prev = yaw
		_rate_prev = NAN
		return
	comfort["playing_ticks"] += 1
	if not is_nan(_yaw_prev) and dt > 0.0:
		var rate := wrapf(yaw - _yaw_prev, -PI, PI) / dt
		var rd := rad_to_deg(absf(rate))
		var bucket := str(int(rd / 30.0) * 30)
		comfort["yaw_rate_hist"][bucket] = int(comfort["yaw_rate_hist"].get(bucket, 0)) + 1
		if rd > 90.0:
			comfort["ticks_over_90dps"] += 1
		if rd > 150.0:
			comfort["ticks_over_150dps"] += 1
		if rd > comfort["max_yaw_rate_dps"]:
			comfort["max_yaw_rate_dps"] = rd
			comfort["worst_rate_at"] = {"t": (Time.get_ticks_msec() - _t0_ms) / 1000.0, "mode": p.mode_name(),
				"state": Game.state_name(), "phase": phase, "species": String(p.species)}
		var cap_r := rad_to_deg(p.model.comfort_yaw_rate)
		var cap_a := rad_to_deg(p.model.comfort_yaw_accel)
		comfort["cap_rate_dps"] = cap_r
		comfort["cap_acc_dps2"] = cap_a
		if cap_r > 0.0 and rd > cap_r * 1.001:
			comfort["yaw_rate_over_cap_ticks"] += 1
			if _over_cap_events.size() < 30:
				_over_cap_events.append({"t": (Time.get_ticks_msec() - _t0_ms) / 1000.0, "rate_dps": snappedf(rd, 0.1), "phase": phase,
					"mode": p.mode_name(), "state": Game.state_name(), "species": String(p.species)})
		if not is_nan(_rate_prev):
			var acc := rad_to_deg(absf(rate - _rate_prev)) / dt
			if acc > comfort["max_yaw_acc_dps2"]:
				comfort["max_yaw_acc_dps2"] = acc
				comfort["worst_acc_at"] = {"t": (Time.get_ticks_msec() - _t0_ms) / 1000.0, "mode": p.mode_name(),
					"state": Game.state_name(), "phase": phase}
			if cap_a > 0.0 and acc > cap_a * 1.01:
				comfort["yaw_acc_over_cap_ticks"] += 1
				if _over_cap_events.size() < 30:
					_over_cap_events.append({"t": (Time.get_ticks_msec() - _t0_ms) / 1000.0, "acc_dps2": snappedf(acc, 0.1), "phase": phase,
						"mode": p.mode_name(), "state": Game.state_name(), "species": String(p.species)})
		_rate_prev = rate
	_yaw_prev = yaw


# ---------------------------------------------------------------------------
# Aim help for the driver: how far (tracking metres, rig axes) the right
# controller must translate so its laser lands on the wanted button.

func _update_aim() -> void:
	var is_aim := phase.begins_with("aim:") or phase.begins_with("hold:")
	if not is_aim or main == null or main.ui == null or main.ui.pointer == null:
		if not aim.is_empty():
			aim = {}
		return
	var id := StringName(phase.substr(phase.find(":") + 1))
	var scr := main.ui.current_screen()
	if scr == null:
		aim = {"error": "no screen"}
		return
	var btn := scr.get_button(id)
	if btn == null or not btn.is_visible_in_tree():
		aim = {"error": "no visible button %s on %s" % [id, main.ui.current_screen_id()]}
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
		"gap": snappedf((c.hands[1].origin - c.hands[0].origin).length(), 0.001), "hint": cal.hint_text()}


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
	res["metrics"]["quality"] = main.quality.describe()
	res["metrics"]["npcs_at_menu"] = main.ecosystem.count()
	res["metrics"]["turn_comfort_setting"] = Settings.get_value("turn_comfort", -1.0)
	await _wall(1.5)
	if Paths.arg("mode", "") == "spiral":
		# Experiment only (the game is not edited): --max_steps=N caps the
		# physics catch-up ticks per frame for this run.
		if Paths.arg("max_steps", "") != "":
			Engine.max_physics_steps_per_frame = int(Paths.arg("max_steps", "4"))
		res["metrics"]["max_physics_steps_per_frame"] = Engine.max_physics_steps_per_frame
		await _menu_and_gate_skip()
		var spawn_o := main.world.get_player_spawn().origin
		var mid := Vector3(spawn_o.x * 0.5, 0.0, spawn_o.z * 0.5)
		_skip_comfort = 3
		main.player.start_flying(Vector3(mid.x, main.world.ground_height(mid.x, mid.z) + 70.0, mid.z), atan2(mid.x, mid.z))
		await _wall(1.0)
		for pad in [0, int(Paths.arg("pad_us", "4800"))]:
			_pad_us = pad
			await _wall(1.0)
			await _fps_plain("pad%d_before_hitch" % pad, 5.0)
			# One long frame (a GC-free spike, a shader, a big re-plan).
			OS.delay_msec(60)
			await _fps_plain("pad%d_after_hitch_0_4s" % pad, 4.0)
			await _fps_plain("pad%d_after_hitch_4_8s" % pad, 4.0)
			res["metrics"]["governor_steps_pad%d" % pad] = main.governor.steps_taken if main.governor != null else -1
			res["metrics"]["npc_budget_pad%d" % pad] = main.ecosystem.max_npcs
		_pad_us = 0
		await _quit_path()
		return
	if Paths.arg("mode", "") == "fpsab":
		# Frame rate by what runs: the menu (sky and valley live, the body
		# still), a paused run (gameplay frozen: only the rig, UI, audio),
		# then flying - at the same machine load, one after the other.
		await _fps_plain("menu", 12.0)
		await _menu_and_gate_skip()
		await _fps_plain("playing_grounded", 12.0)
		_set_phase("pause_button")
		await _until(func() -> bool: return Game.state == Game.State.PAUSED, 20.0)
		await _wall(1.0)
		await _fps_plain("paused", 12.0)
		main.ui.resume()
		await _wall(1.0)
		await _fps_window("sparrow")
		await _quit_path()
		return
	if Paths.arg("mode", "") == "short":
		await _howto_with_pointer()
		await _menu_and_gate_skip()
		await _flaps_and_haptics()
		await _fps_window("sparrow")
		await _fps_window("sparrow_again")
		await _quit_path()
		return
	await _menu_and_gate_skip()
	await _flaps_and_haptics()
	await _haptics_all_patterns()
	await _fps_window("sparrow")
	await _bank_turns()
	await _growth()
	await _fps_window("eagle")
	await _pause_and_head()
	await _resume_with_pointer("resume1")
	await _y_hold_capture()
	await _presence_and_cancel()
	await _resume_with_pointer("resume2")
	await _quit_path()


func _card_detail(cal: VRCalibration) -> Dictionary:
	var d := {}
	if cal.prompt == null:
		return {"prompt": "none"}
	var pr := cal.prompt
	var cam := main.player.camera
	var ws := main.player.origin.world_scale
	var to := pr.global_position - cam.global_position
	d["visible"] = pr.visible
	d["angle_from_gaze_deg"] = snappedf(rad_to_deg((-cam.global_basis.z).angle_to(to.normalized())), 0.1)
	d["distance_over_ws"] = snappedf(to.length() / ws, 0.001)
	d["width_m"] = snappedf(pr.width, 0.001)
	d["angular_width_deg"] = snappedf(rad_to_deg(2.0 * atan(pr.width * 0.5 / maxf(to.length() / ws, 1e-3))), 0.1)
	var q: Variant = pr.get("_quad")
	d["quad_width_over_ws_m"] = snappedf((q as QuadMesh).size.x / ws, 0.001) if q is QuadMesh else -1.0
	d["text"] = cal.prompt_text()
	d["hint"] = cal.hint_text()
	d["menu_panel_shown"] = main.ui.menu_panel.shown
	d["screen"] = String(main.ui.current_screen_id())
	d["ws"] = snappedf(ws, 0.001)
	return d


## Nothing over the menu; Settings/Back; Play -> the gate; B skips.
func _menu_and_gate_skip() -> void:
	_set_phase("menu")
	var cal := main.rig_extras.calibration
	var cam := main.player.camera
	var menu_dir := (main.ui.menu_panel.control_to_world(main.ui.get_screen(&"main").get_button(&"play")) - cam.global_position).normalized()
	var ang := rad_to_deg((-cam.global_basis.z).angle_to(menu_dir))
	_check("menu_alone_in_front", Game.state == Game.State.MENU and main.ui.current_screen_id() == &"main" and ang < 35.0
		and cal.flow == VRCalibration.Flow.IDLE and cal.first_launch_due(),
		"state %s, screen %s, Play %.1f deg from the gaze, calibration step %s, first launch due %s" % [Game.state_name(),
		main.ui.current_screen_id(), ang, VRCalibration.Flow.keys()[cal.flow], cal.first_launch_due()])
	res["metrics"]["menu_panel_scale_over_ws_sparrow"] = main.ui.menu_panel.global_basis.get_scale().x / main.player.origin.world_scale
	res["metrics"]["menu_dist_over_ws_sparrow"] = main.ui.menu_panel.global_position.distance_to(cam.global_position) / main.player.origin.world_scale
	await main.mirror.capture(out_dir.path_join("%s_menu.png" % tag))
	var ok1 := await _click("settings", func() -> bool: return main.ui.current_screen_id() == &"settings")
	var turn_found := _find_text(main.ui.current_screen(), "Turn speed")
	await main.mirror.capture(out_dir.path_join("%s_settings.png" % tag))
	var ok2 := await _click("back", func() -> bool: return main.ui.current_screen_id() == &"main")
	var ok3 := await _click("play", func() -> bool: return main.gate.gating or Game.state == Game.State.PLAYING)
	await _wall(0.6)
	var c1 := _card_detail(cal)
	_check("menus_usable_with_real_pointer", ok1 and ok2 and ok3 and turn_found, "Settings %s (Turn speed shown %s), Back %s, Play %s" % [ok1, turn_found, ok2, ok3])
	_check("play_opens_the_card_alone", main.gate.gating and Game.state == Game.State.MENU and cal.flow == VRCalibration.Flow.CAPTURE
		and main.ui.current_screen_id() == &"" and not main.player.auto_process and c1.get("visible", false)
		and float(c1.get("angle_from_gaze_deg", 99.0)) < 25.0 and String(c1.get("hint", "")).contains("skip"), c1)
	await main.mirror.capture(out_dir.path_join("%s_card.png" % tag))
	# A real B press (right controller) skips.
	_set_phase("skip")
	var t0 := Time.get_ticks_msec()
	var ended := await _until(func() -> bool: return cal.flow != VRCalibration.Flow.CAPTURE, 20.0)
	var result_text := cal.prompt_text()
	var result_flow: String = VRCalibration.Flow.keys()[cal.flow]
	await _wall(0.3)
	await main.mirror.capture(out_dir.path_join("%s_skipped.png" % tag))
	var run := await _until(func() -> bool: return Game.state == Game.State.PLAYING, 8.0)
	var after_s := (Time.get_ticks_msec() - t0) / 1000.0
	_check("b_skips_to_default_wings_and_the_run_starts", ended and run and main.gate.last_outcome == "skipped"
		and result_text.begins_with("Calibration skipped") and not cal.calibrator.calibrated and not cal.first_launch_due(),
		{"ended": ended, "result_card": result_text, "flow_after": result_flow, "outcome": main.gate.last_outcome,
		"state": Game.state_name(), "calibrated": cal.calibrator.calibrated, "still_due": cal.first_launch_due(),
		"run_started_after_s": after_s, "driver_skip": _driver().get("skip_pressed", false)})
	if Game.state != Game.State.PLAYING:
		main.game_loop.start_run()
	main.game_loop.set_protection(main.player, 1e6)
	_set_phase("relax")
	await _until(func() -> bool: return bool(_driver().get("relaxed", false)), 20.0)


## How to fly with the real pointer: two tabs, then Back.
func _howto_with_pointer() -> void:
	var ok1 := await _click("howto", func() -> bool: return main.ui.current_screen_id() == &"howto")
	await main.mirror.capture(out_dir.path_join("%s_howto.png" % tag))
	var ok2 := await _click("tab_turn", func() -> bool: return _find_text(main.ui.current_screen(), "Bank to turn"))
	await main.mirror.capture(out_dir.path_join("%s_howto_turn.png" % tag))
	var ok3 := await _click("tab_controls", func() -> bool: return _find_text(main.ui.current_screen(), "only for menus"))
	await main.mirror.capture(out_dir.path_join("%s_howto_buttons.png" % tag))
	var ok4 := await _click("back", func() -> bool: return main.ui.current_screen_id() == &"main")
	_check("how_to_fly_with_real_pointer", ok1 and ok2 and ok3 and ok4, "How to fly %s, Turn tab %s, Buttons tab %s, Back %s" % [ok1, ok2, ok3, ok4])


func _find_text(n: Node, s: String) -> bool:
	if n == null:
		return false
	if (n is Label and (n as Label).text.contains(s)) or (n is Button and (n as Button).text.contains(s)):
		return (n as CanvasItem).is_visible_in_tree()
	for c in n.get_children():
		if _find_text(c, s):
			return true
	return false


func _click(id: String, want: Callable, timeout := 45.0) -> bool:
	_set_phase("aim:" + id)
	var ok := await _until(want, timeout)
	_event("click %s -> %s (screen %s, state %s)" % [id, ok, main.ui.current_screen_id(), Game.state_name()])
	_set_phase("aimed")
	await _wall(0.8)
	return ok


func _hold(id: String, want: Callable, timeout := 45.0) -> bool:
	_set_phase("hold:" + id)
	var ok := await _until(want, timeout)
	_event("hold %s -> %s (screen %s, state %s)" % [id, ok, main.ui.current_screen_id(), Game.state_name()])
	_set_phase("aimed")
	await _wall(0.8)
	return ok


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
	await main.mirror.capture(out_dir.path_join("%s_after_strokes.png" % tag))
	_check("real_strokes_flap_default_wings_and_pulse_haptics", _flaps - f0 >= 2 and calls1 - calls0 > 0 and (_logger.errors + _logger.warnings) == e0,
		"%d wingbeats (uncalibrated: default wings), %d trigger_haptic_pulse calls to the runtime, patterns %s, stats %s, new errors/warnings %d" % [
		_flaps - f0, calls1 - calls0, diff, VR.haptics.stats, _logger.errors + _logger.warnings - e0])


## Every haptic pattern once through the real OpenXR runtime, plus the
## danger heartbeat for 2 s: no error, pulses reach the runtime.
func _haptics_all_patterns() -> void:
	_set_phase("haptics_all")
	var sink: Object = VR.haptics.sink
	var calls0 := int(sink.get("calls")) if sink != null and "calls" in sink else -1
	var e0: int = _logger.errors + _logger.warnings
	var names := HapticPatterns.names()
	for n: StringName in names:
		VR.haptics.play(n)
		await _wall(0.35)
	VR.haptics.set_danger(0.9)
	await _wall(2.0)
	VR.haptics.set_danger(0.0)
	await _wall(0.3)
	var calls1 := int(sink.get("calls")) if sink != null and "calls" in sink else -1
	_check("every_haptic_pattern_through_the_runtime", calls1 - calls0 >= names.size() and (_logger.errors + _logger.warnings) == e0,
		"%d patterns %s -> %d runtime calls, new errors/warnings %d, stats %s" % [names.size(), names, calls1 - calls0,
		_logger.errors + _logger.warnings - e0, VR.haptics.stats])


func _fps_window(label: String) -> void:
	_set_phase("fps_" + label)
	var xr := XRServer.find_interface("OpenXR") as OpenXRInterface
	var hz := xr.display_refresh_rate if xr else 72.0
	var rid := get_viewport().get_viewport_rid()
	# In flight, 70 m over the valley's middle (as the builder's harness).
	var spawn_o := main.world.get_player_spawn().origin
	var mid := Vector3(spawn_o.x * 0.5, 0.0, spawn_o.z * 0.5)
	var start_at := Vector3(mid.x, main.world.ground_height(mid.x, mid.z) + 70.0, mid.z)
	_skip_comfort = 3
	main.player.start_flying(start_at, atan2(mid.x, mid.z) if mid.length() > 1.0 else 0.0)
	RenderingServer.viewport_set_measure_render_time(rid, true)
	await _wall(0.5)
	_render_cpu.clear()
	_setup_cpu.clear()
	_render_on = true
	_tick_hist.clear()
	_hist_on = true
	var intervals := PackedFloat32Array()
	var d3max := 0
	var d3sum := 0.0
	var pmax := 0
	var n := 0
	var flying := 0
	var tp := PackedFloat32Array()
	var tw := Time.get_ticks_usec()
	var prev := tw
	while Time.get_ticks_usec() - tw < 20000000:
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		intervals.append((now - prev) / 1000.0)
		prev = now
		n += 1
		if main.player.mode == PlayerBird.Mode.FLYING:
			flying += 1
		var d3 := RenderingServer.viewport_get_render_info(rid, RenderingServer.VIEWPORT_RENDER_INFO_TYPE_VISIBLE, RenderingServer.VIEWPORT_RENDER_INFO_DRAW_CALLS_IN_FRAME) \
			+ RenderingServer.viewport_get_render_info(rid, RenderingServer.VIEWPORT_RENDER_INFO_TYPE_SHADOW, RenderingServer.VIEWPORT_RENDER_INFO_DRAW_CALLS_IN_FRAME)
		d3max = maxi(d3max, d3)
		d3sum += d3
		pmax = maxi(pmax, int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)))
		tp.append((Performance.get_monitor(Performance.TIME_PROCESS) + Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)) * 1000.0)
	_hist_on = false
	_render_on = false
	RenderingServer.viewport_set_measure_render_time(rid, false)
	var secs := (Time.get_ticks_usec() - tw) / 1e6
	var stats := func(a: PackedFloat32Array) -> Dictionary:
		var v := a.duplicate()
		v.sort()
		if v.is_empty():
			return {}
		var s := 0.0
		for x in v:
			s += x
		return {"mean": snappedf(s / v.size(), 0.001), "p50": snappedf(v[v.size() / 2], 0.001),
			"p95": snappedf(v[clampi(int(ceil(0.95 * v.size())) - 1, 0, v.size() - 1)], 0.001), "max": snappedf(v[v.size() - 1], 0.001)}
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
	var m := {"fps": fps, "hz": hz, "p50": pct.call(0.5), "p95": pct.call(0.95), "p99": pct.call(0.99),
		"late_frames": late, "frames": n, "ticks_per_frame_hist": hist, "draw3d_max": d3max, "draw3d_mean": d3sum / maxi(n, 1),
		"prims_max": pmax, "npcs": main.ecosystem.count(), "npc_budget": main.ecosystem.max_npcs, "species": String(main.player.species),
		"render_cpu_ms": stats.call(_render_cpu), "frame_setup_cpu_ms": stats.call(_setup_cpu),
		"script_worst_per_second_ms": stats.call(tp), "flying_share": float(flying) / maxi(n, 1),
		"governor_steps": main.governor.steps_taken if main.governor != null else -1,
		"load": String(out[0]).strip_edges() if not out.is_empty() else "", "state": Game.state_name(), "mode": main.player.mode_name()}
	res["metrics"]["fps_" + label] = m
	_check("fps_at_refresh_" + label, fps >= 0.95 * hz, "%.2f fps at %.0f Hz, p50 %.2f p95 %.2f p99 %.2f ms, %d late, ticks/frame %s, %d NPCs (budget %d), flying %.0f%%, 3D draws mean %.0f max %d, prims max %d, render CPU %s ms, setup %s, load %s" % [
		fps, hz, pct.call(0.5), pct.call(0.95), pct.call(0.99), late, hist, main.ecosystem.count(), main.ecosystem.max_npcs, 100.0 * flying / maxi(n, 1),
		m["draw3d_mean"], d3max, pmax, m["render_cpu_ms"], m["frame_setup_cpu_ms"], m["load"]])
	_check("draw_budget_" + label, d3max <= 150 and pmax <= 300000, "3D draws max %d (<= 150), primitives max %d (<= 300k)" % [d3max, pmax])
	await main.mirror.capture(out_dir.path_join("%s_flight_%s.png" % [tag, label]))


## Real-controller banking (one hand raised: arm dihedral; then the other):
## the view's yaw rate and acceleration stay within the Turn speed caps.
func _bank_turns() -> void:
	var spawn_o := main.world.get_player_spawn().origin
	var start_at := Vector3(spawn_o.x * 0.3, main.world.ground_height(spawn_o.x * 0.3, spawn_o.z * 0.3) + 90.0, spawn_o.z * 0.3)
	_skip_comfort = 3
	main.player.start_flying(start_at, 0.0)
	var over0: int = comfort["yaw_rate_over_cap_ticks"]
	var acc0: int = comfort["yaw_acc_over_cap_ticks"]
	var max_rate := 0.0
	var max_bank := 0.0
	var yaws := []
	_set_phase("bank")
	var t := Time.get_ticks_msec()
	var prev := NAN
	while not bool(_driver().get("bank_done", false)) and Time.get_ticks_msec() - t < 60000:
		await get_tree().physics_frame
		var tel := main.player.telemetry()
		max_bank = maxf(max_bank, rad_to_deg(absf(float(tel.get("bank", 0.0)))))
		var f := -main.player.origin.global_basis.z
		var y := atan2(-f.x, -f.z)
		if not is_nan(prev):
			max_rate = maxf(max_rate, rad_to_deg(absf(wrapf(y - prev, -PI, PI))) * Engine.physics_ticks_per_second)
		prev = y
		if yaws.size() < 4000 and Engine.get_physics_frames() % 6 == 0:
			yaws.append([snappedf((Time.get_ticks_msec() - t) / 1000.0, 0.01), snappedf(rad_to_deg(y), 0.1), snappedf(rad_to_deg(float(tel.get("bank", 0.0))), 0.1), main.player.mode_name()])
	res["metrics"]["bank_series"] = yaws
	_check("real_bank_turns_within_turn_speed", max_rate > 20.0 and comfort["yaw_rate_over_cap_ticks"] == over0 and comfort["yaw_acc_over_cap_ticks"] == acc0,
		"max rig yaw rate %.1f deg/s (cap %.0f), max bank %.1f deg, over-cap ticks rate %d accel %d, driver %s, mode now %s" % [max_rate,
		rad_to_deg(main.player.model.comfort_yaw_rate), max_bank, comfort["yaw_rate_over_cap_ticks"] - over0, comfort["yaw_acc_over_cap_ticks"] - acc0,
		_driver().get("bank", {}), main.player.mode_name()])
	await main.mirror.capture(out_dir.path_join("%s_bank.png" % tag))


## Frame rate over `secs` of whatever the game is doing now.
func _fps_plain(label: String, secs: float) -> void:
	var xr := XRServer.find_interface("OpenXR") as OpenXRInterface
	var hz := xr.display_refresh_rate if xr else 72.0
	_tick_hist.clear()
	_hist_on = true
	var n := 0
	var tw := Time.get_ticks_usec()
	var prev := tw
	var iv := PackedFloat32Array()
	while Time.get_ticks_usec() - tw < int(secs * 1e6):
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		iv.append((now - prev) / 1000.0)
		prev = now
		n += 1
	_hist_on = false
	iv.sort()
	var out := []
	OS.execute("sysctl", ["-n", "vm.loadavg"], out)
	var hist := {}
	for k in _tick_hist:
		hist[str(k)] = _tick_hist[k]
	var m := {"fps": n / ((Time.get_ticks_usec() - tw) / 1e6), "p50": iv[iv.size() / 2], "p95": iv[int(0.95 * (iv.size() - 1))],
		"ticks_per_frame_hist": hist, "state": Game.state_name(), "tree_paused": get_tree().paused, "npcs": main.ecosystem.count(),
		"load": String(out[0]).strip_edges() if not out.is_empty() else ""}
	res["metrics"]["fps_plain_" + label] = m
	_event("fps %s: %s" % [label, JSON.stringify(m)])


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
			max_rate = maxf(max_rate, absf(log(o.world_scale / prev)) * Engine.physics_ticks_per_second)
			prev = o.world_scale
			if n_ticks > 3 and absf(o.world_scale - drv.target) < 1e-4:
				break
		await _wall(0.2)
		await RenderingServer.frame_pre_draw
		var ws := o.world_scale
		var hud_d := main.ui.hud_panel.global_position.distance_to(cam.global_position) / ws
		var hud_s := main.ui.hud_panel.global_basis.get_scale().x / ws
		var lh := main.rig_extras.left_hand
		var tip_d := (wings.wingtip(0) - lh.transform.origin).length() / ws if lh else -1.0
		var wing_s := wings.global_basis.get_scale().x / ws
		rows.append({"species": String(SizeRules.SPECIES[i]["id"]), "mass": snappedf(main.player.mass, 0.0001),
			"ws": snappedf(ws, 0.0001), "target": snappedf(drv.target, 0.0001), "near": snappedf(cam.near, 0.00001),
			"near_over_ws": snappedf(cam.near / ws, 0.0001), "hud_dist_over_ws": snappedf(hud_d, 0.001),
			"hud_scale_over_ws": snappedf(hud_s, 0.0001), "wing_node_scale_over_ws": snappedf(wing_s, 0.0001),
			"wingtip_from_grip_over_ws": snappedf(tip_d, 0.001), "npcs": main.ecosystem.count(),
			"mode": main.player.mode_name(), "species_now": String(main.player.species),
			"vignette_node_scale_over_ws": snappedf(main.rig_extras.vignette.global_basis.get_scale().x / ws, 0.0001) if main.rig_extras.vignette else -1.0})
	res["metrics"]["growth"] = rows
	res["metrics"]["growth_max_rate_ln_per_s"] = max_rate
	var first: Dictionary = rows[0]
	var last: Dictionary = rows[rows.size() - 1]
	var near_ok := true
	for r: Dictionary in rows:
		near_ok = near_ok and absf(float(r["near_over_ws"]) - WorldScaleDriver.NEAR_K) < 0.001 and absf(float(r["ws"]) - float(r["target"])) < 0.002
	var hud_const := absf(float(first["hud_dist_over_ws"]) - float(last["hud_dist_over_ws"])) < 0.05 \
		and absf(float(first["hud_scale_over_ws"]) - float(last["hud_scale_over_ws"])) < 0.01
	var wing_const := absf(float(first["wingtip_from_grip_over_ws"]) - float(last["wingtip_from_grip_over_ws"])) < 0.01
	_check("growth_world_scale_near_hud_wings", near_ok and hud_const and wing_const and max_rate <= WorldScaleDriver.MAX_RATE * 1.05 and float(last["ws"]) > 5.0 * float(first["ws"])
		and last["species_now"] == "eagle",
		"ws %.3f -> %.3f, near/ws %.4f -> %.4f, HUD distance/ws %.3f -> %.3f, HUD scale/ws %.4f -> %.4f, wingtip-grip/ws %.3f -> %.3f, max ramp %.3f ln/s" % [
		first["ws"], last["ws"], first["near_over_ws"], last["near_over_ws"], first["hud_dist_over_ws"], last["hud_dist_over_ws"],
		first["hud_scale_over_ws"], last["hud_scale_over_ws"], first["wingtip_from_grip_over_ws"], last["wingtip_from_grip_over_ws"], max_rate])
	await main.mirror.capture(out_dir.path_join("%s_grow_eagle.png" % tag))


func _pause_and_head() -> void:
	_set_phase("pause_button")
	var paused := await _until(func() -> bool: return Game.state == Game.State.PAUSED, 20.0)
	await _wall(0.8)
	_check("real_menu_button_pauses", paused and main.ui.current_screen_id() == &"pause" and get_tree().paused,
		"state %s, screen %s, tree paused %s" % [Game.state_name(), main.ui.current_screen_id(), get_tree().paused])
	await main.mirror.capture(out_dir.path_join("%s_pause.png" % tag))
	var o := main.player.origin
	var ws := o.world_scale
	res["metrics"]["pause_menu_dist_over_ws_eagle"] = main.ui.menu_panel.global_position.distance_to(main.player.camera.global_position) / ws
	res["metrics"]["menu_panel_scale_over_ws_eagle"] = main.ui.menu_panel.global_basis.get_scale().x / ws
	var ms := float(res["metrics"].get("menu_panel_scale_over_ws_sparrow", -1.0))
	var md := float(res["metrics"].get("menu_dist_over_ws_sparrow", -1.0))
	_check("menu_panel_scales_with_world_scale", absf(float(res["metrics"]["menu_panel_scale_over_ws_eagle"]) - ms) < 0.01 * ms
		and absf(float(res["metrics"]["pause_menu_dist_over_ws_eagle"]) - md) < 0.1,
		"panel scale/ws sparrow %.4f eagle %.4f; distance/ws sparrow %.3f eagle %.3f (ws %.3f)" % [ms, res["metrics"]["menu_panel_scale_over_ws_eagle"],
		md, res["metrics"]["pause_menu_dist_over_ws_eagle"], ws])
	_pause_track = {"yaw0": NAN, "yaw_min": 0.0, "yaw_max": 0.0, "origin0": o.global_transform, "origin_moved": 0.0,
		"hmd_yaw_min": 0.0, "hmd_yaw_max": 0.0, "hmd_yaw0": NAN, "right0": main.rig_extras.right_hand.position,
		"right_moved": 0.0, "frames": 0, "paused_frames": 0, "body_pos0": main.player.global_position, "body_moved": 0.0}
	_tracking_pause = true
	var rc0 := VR.recenter_count
	_set_phase("head_turn")
	await _until(func() -> bool: return bool(_driver().get("head_turned", false)), 30.0)
	await _wall(0.4)
	var yaw_before := _cam_local_yaw()
	var gyaw_before := _cam_global_yaw()
	_set_phase("recenter")
	var rc_ok := await _until(func() -> bool: return VR.recenter_count > rc0, 12.0)
	await _wall(0.5)
	var yaw_after := _cam_local_yaw()
	var gyaw_after := _cam_global_yaw()
	res["metrics"]["recenter_paused"] = {"local_yaw_before": yaw_before, "local_yaw_after": yaw_after,
		"global_view_yaw_before": gyaw_before, "global_view_yaw_after": gyaw_after}
	_check("recenter_with_ax_hold_while_paused", rc_ok and absf(yaw_after) < 3.0 and absf(yaw_before) > 10.0,
		"recenters %d -> %d; head yaw in the rig %.1f deg before, %.1f deg after; view yaw in the world %.1f -> %.1f (state %s)" % [rc0, VR.recenter_count,
		yaw_before, yaw_after, gyaw_before, gyaw_after, Game.state_name()])
	_set_phase("head_back")
	await _until(func() -> bool: return bool(_driver().get("head_turn_done", false)), 30.0)
	await _wall(0.5)
	_tracking_pause = false
	var pt := _pause_track
	var yaw_span := rad_to_deg(float(pt["yaw_max"]) - float(pt["yaw_min"]))
	var hmd_span := rad_to_deg(float(pt["hmd_yaw_max"]) - float(pt["hmd_yaw_min"]))
	_check("pause_keeps_head_and_hands_tracking", Game.state == Game.State.PAUSED and yaw_span > 10.0 and hmd_span > 10.0
		and float(pt["right_moved"]) > 0.02 and float(pt["body_moved"]) < 1e-4,
		"while paused (%d frames): XRCamera3D yaw span %.1f deg, XRServer HMD yaw span %.1f deg, right grip moved %.3f m, rig moved %.4f (the recenter re-aims it), body moved %.6f" % [
		pt["paused_frames"], yaw_span, hmd_span, pt["right_moved"], pt["origin_moved"], pt["body_moved"]])
	await main.mirror.capture(out_dir.path_join("%s_pause_after_head.png" % tag))


func _cam_local_yaw() -> float:
	var f := -main.player.camera.transform.basis.z
	return rad_to_deg(atan2(-f.x, -f.z))


func _cam_global_yaw() -> float:
	var f := -main.player.camera.global_basis.z
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


## Resume with the real pointer; the view must not turn at Resume (the
## rig's yaw step on the first 36 ticks after it stays a normal turn).
func _resume_with_pointer(label: String) -> void:
	var detail := {"screen_before": String(main.ui.current_screen_id())}
	var gy0 := _cam_global_yaw()
	_resume_label = label
	_resume_watch = 36
	var ok := await _click("resume", func() -> bool: return Game.state == Game.State.PLAYING)
	detail["state"] = Game.state_name()
	detail["aims"] = (_driver().get("aims", []) as Array).slice(-1)
	await _wall(0.3)
	var step := float(comfort["max_step_after_resume_deg"].get(label, -1.0))
	detail["max_rig_yaw_step_first_36_ticks_deg"] = step
	detail["view_yaw_before_click"] = gy0
	# A normal turn at the Turn speed cap is <= 180/72 = 2.5 deg a tick.
	var cap_step := rad_to_deg(main.player.model.comfort_yaw_rate) / Engine.physics_ticks_per_second
	detail["cap_step_deg"] = cap_step
	_check("resume_with_real_pointer_turns_nothing_" + label, ok and step >= 0.0 and step <= cap_step * 1.05 + 0.01, detail)
	if Game.state != Game.State.PLAYING:
		main.ui.resume()
	await _wall(1.0)


## Y held 1.5 s in play (an eagle): the game pauses, the card asks and the
## menus make way; a real spread is captured; the menus come back.
func _y_hold_capture() -> void:
	var cal := main.rig_extras.calibration
	var span0 := cal.calibrator.arm_span
	var ws0 := main.player.origin.world_scale
	_menu_hidden_frames.clear()
	_set_phase("y_hold")
	var up := await _until(func() -> bool: return cal.flow == VRCalibration.Flow.CAPTURE, 20.0)
	await _wall(0.6)
	var d := _card_detail(cal)
	d["state"] = Game.state_name()
	d["tree_paused"] = get_tree().paused
	d["reason"] = String(cal.flow_reason)
	d["hiding_for_step"] = main.gate.hiding_for_step
	await main.mirror.capture(out_dir.path_join("%s_yhold_card.png" % tag))
	_check("y_hold_pauses_asks_and_menus_make_way", up and Game.state == Game.State.PAUSED and get_tree().paused and cal.flow_reason == &"manual"
		and not main.ui.menu_panel.shown and d.get("visible", false) and absf(float(d.get("quad_width_over_ws_m", 0.0)) - float(d.get("width_m", -9.0))) < 0.01
		and absf(float(d.get("distance_over_ws", 0.0)) - 1.26) < 0.1, d)
	_set_phase("calibrate_again")
	var t := Time.get_ticks_msec()
	var cap := await _until(func() -> bool: return cal.flow == VRCalibration.Flow.DONE, 45.0)
	var dd := {"captured": cap, "after_s": (Time.get_ticks_msec() - t) / 1000.0, "result_card": cal.prompt_text(),
		"span": [span0, cal.calibrator.arm_span], "calibrated": cal.calibrator.calibrated, "menu_frames_during_card": _menu_hidden_frames.duplicate(),
		"driver_error": _driver().get("spread_error2", "")}
	await main.mirror.capture(out_dir.path_join("%s_yhold_captured.png" % tag))
	var back := await _until(func() -> bool: return cal.flow == VRCalibration.Flow.IDLE and main.ui.current_screen_id() == &"pause", 8.0)
	await _wall(0.5)
	dd["screen_after"] = String(main.ui.current_screen_id())
	dd["menu_shown_after"] = main.ui.menu_panel.shown
	dd["state"] = Game.state_name()
	dd["ws"] = [ws0, main.player.origin.world_scale]
	dd["ws_target"] = main.rig_extras.world_scale_driver.target
	_check("y_hold_spread_captures_and_the_menus_come_back", cap and cal.calibrator.calibrated and back and main.ui.menu_panel.shown
		and int(_menu_hidden_frames.get("menu_shown", 0)) == 0 and Game.state == Game.State.PAUSED, dd)
	await main.mirror.capture(out_dir.path_join("%s_yhold_menu_back.png" % tag))
	_set_phase("relax")
	await _until(func() -> bool: return bool(_driver().get("relaxed2", false)), 20.0)


## The headset off and on (SetUserPresent) while paused, then the pause
## menu's "New player? Recalibrate wings" with the real pointer; a real B
## press cancels: nothing changes; the menus come back.
func _presence_and_cancel() -> void:
	var cal := main.rig_extras.calibration
	var sugg0 := VR.recalibration_suggested
	_set_phase("presence_off")
	var off := await _until(func() -> bool: return not VR.focused, 15.0)
	var st_off := {"focused": VR.focused, "present": VR.user_present, "state": Game.state_name(), "presence_supported": VR.presence_supported}
	_set_phase("presence_on")
	var on := await _until(func() -> bool: return VR.focused, 15.0)
	await _wall(1.0)
	var btn: Button = main.ui.current_screen().get_button(&"recalibrate") if main.ui.current_screen() != null else null
	var shown := btn != null and btn.is_visible_in_tree()
	await main.mirror.capture(out_dir.path_join("%s_pause_new_player.png" % tag))
	_check("headset_off_on_pauses_and_suggests", off and on and Game.state == Game.State.PAUSED and VR.recalibration_suggested and shown,
		{"off": st_off, "suggested_before": sugg0, "suggested": VR.recalibration_suggested, "button_shown": shown,
		"screen": String(main.ui.current_screen_id()), "state": Game.state_name(), "driver": _driver().get("presence", {})})
	var span0 := cal.calibrator.arm_span
	_menu_hidden_frames.clear()
	var ok := await _click("recalibrate", func() -> bool: return cal.flow == VRCalibration.Flow.CAPTURE)
	await _wall(0.3)
	var d := _card_detail(cal)
	await main.mirror.capture(out_dir.path_join("%s_recal_card.png" % tag))
	_set_phase("by_cancel")
	var ended := await _until(func() -> bool: return cal.flow != VRCalibration.Flow.CAPTURE, 15.0)
	var txt := cal.prompt_text()
	await _wall(0.3)
	await main.mirror.capture(out_dir.path_join("%s_recal_cancelled.png" % tag))
	var back := await _until(func() -> bool: return cal.flow == VRCalibration.Flow.IDLE and main.ui.current_screen_id() == &"pause", 8.0)
	await _wall(0.4)
	d["ended"] = ended
	d["reason"] = cal.last_reason
	d["result_card"] = txt
	d["span"] = [span0, cal.calibrator.arm_span]
	d["menu_frames_during_card"] = _menu_hidden_frames.duplicate()
	d["screen_after"] = String(main.ui.current_screen_id())
	d["state"] = Game.state_name()
	d["suggested_after"] = VR.recalibration_suggested
	_check("recalibrate_from_pause_then_b_cancels_nothing_changes", ok and ended and cal.last_reason == "cancelled"
		and is_equal_approx(cal.calibrator.arm_span, span0) and cal.calibrator.calibrated and back and main.ui.menu_panel.shown
		and int(_menu_hidden_frames.get("menu_shown", 0)) == 0 and Game.state == Game.State.PAUSED, d)
	await main.mirror.capture(out_dir.path_join("%s_recal_menu_back.png" % tag))


## Pause -> hold Quit to menu (real trigger) -> MENU; hold Quit -> the
## game's quit path. The result is written before the last hold.
func _quit_path() -> void:
	_set_phase("pause_button")
	var paused := await _until(func() -> bool: return Game.state == Game.State.PAUSED and main.ui.current_screen_id() == &"pause", 20.0)
	await _wall(0.6)
	# A single short pull on Quit to menu does nothing (hold buttons).
	var ok_menu := await _hold("quit_menu", func() -> bool: return Game.state == Game.State.MENU and main.ui.current_screen_id() == &"main", 45.0)
	await _wall(1.0)
	var spawn := main.world.get_player_spawn()
	var body_d := main.player.global_position.distance_to(spawn.origin)
	await main.mirror.capture(out_dir.path_join("%s_back_in_menu.png" % tag))
	_check("hold_quit_to_menu_with_real_trigger", paused and ok_menu and not main.player.auto_process and body_d < 2.0,
		{"state": Game.state_name(), "screen": String(main.ui.current_screen_id()), "body_from_spawn_m": body_d,
		"ws": main.player.origin.world_scale, "aims": (_driver().get("aims", []) as Array).slice(-1)})
	_finish()
	_set_phase("hold:quit")
	var ok := await _until(func() -> bool: return _quit_seen, 45.0)
	_event("quit hold seen: %s" % ok)
	if not ok:
		_check("hold_quit_with_real_trigger", false, {"state": Game.state_name(), "screen": String(main.ui.current_screen_id())})
		_finish()
		main.quit_game()


var _quit_seen := false


func _on_quit_started() -> void:
	_quit_seen = true
	var f := FileAccess.open(out_dir.path_join("%s_quit.json" % tag), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify({"quit_started": true, "t": (Time.get_ticks_msec() - _t0_ms) / 1000.0,
			"state": Game.state_name(), "phase": phase, "errors": _logger.errors, "warnings": _logger.warnings,
			"messages": _logger.summary()}))
		f.close()
	print("[integration-verify] quit_started seen (phase %s)" % phase)


func _finish() -> void:
	res["metrics"]["comfort"] = comfort
	res["metrics"]["haptics_by_pattern"] = _haptics
	res["metrics"]["over_cap_events"] = _over_cap_events
	_check("rig_never_pitches_or_rolls", comfort["max_tilt_deg"] < 0.01 and comfort["max_basis_scale_err"] < 1e-4,
		"max tilt %.5f deg, basis scale error %.6f over %d ticks" % [comfort["max_tilt_deg"], comfort["max_basis_scale_err"], comfort["ticks"]])
	_check("yaw_within_turn_speed_caps", comfort["yaw_rate_over_cap_ticks"] == 0 and comfort["yaw_acc_over_cap_ticks"] == 0
		and float(comfort.get("cap_rate_dps", -1.0)) <= 180.5,
		"max yaw rate %.1f deg/s (cap %.1f) at %s, max yaw accel %.1f deg/s^2 (cap %.1f) at %s; ticks >90 deg/s %d, >150 deg/s %d of %d playing; flagged ticks %d, max flagged yaw step %.1f deg; steps %s" % [
		comfort["max_yaw_rate_dps"], comfort.get("cap_rate_dps", -1.0), comfort["worst_rate_at"], comfort["max_yaw_acc_dps2"],
		comfort.get("cap_acc_dps2", -1.0), comfort["worst_acc_at"], comfort["ticks_over_90dps"], comfort["ticks_over_150dps"],
		comfort["playing_ticks"], comfort["flagged_ticks"], comfort["max_flagged_yaw_step_deg"], comfort["flagged_yaw_steps"]])
	_check("near_plane_tracks_world_scale", comfort["max_near_err"] < 0.01, "max relative error %.4f at %s" % [comfort["max_near_err"], comfort["near_err_at"]])
	_check("no_errors_or_warnings", _logger.errors == 0 and _logger.warnings == 0, _logger.summary())
	var ok := true
	for k in res["checks"]:
		ok = ok and bool(res["checks"][k]["ok"])
	res["pass"] = ok
	res["driver"] = _driver()
	var f := FileAccess.open(out_dir.path_join("%s_result.json" % tag), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(res, "  "))
		f.close()
	print("[integration-verify] RESULT %s" % ("PASS" if ok else "FAIL"))
