extends Node
## The composed game in the Meta XR Simulator (integration). Runs INSIDE
## scenes/main.tscn (main.gd adds it for --harness=sim), with
## tests/shots/integration_sim_driver.py moving the simulator's own
## controllers over SimRpc; start both with tests/shots/integration_sim.sh.
##
## What it checks (artifacts/integration/sim_result.json, "[integration] SIM
## PASS|FAIL <check>" lines, verdict "[integration] SIM RESULT PASS|FAIL"):
##   session    the OpenXR session reaches FOCUSED; physics tick == refresh
##   loading    the loading card was shown before the valley was built, and
##              the longest frame gap of the load
##   menu       BOOT -> MENU with the main menu in front of the head, and
##              no calibration card over it (integration round 1)
##   pointer    the real right controller's aim ray (driven by the driver
##              until it hovers Play) and its real trigger press Play
##   gate       a first launch (the wrapper empties the run's own user://):
##              Play closes the menu and VR's card asks for the spread; the
##              driver spreads the real controllers and holds still; the run
##              starts only after the capture (integration round 1)
##   flaps      the driver's real controller strokes reach the game: flight
##              credits wingbeats (Events.player_flapped) through WingInput
##   fps        frames over a 20 s window of play >= 0.95 x refresh, frame
##              pacing percentiles, draw calls / primitives (stereo)
##   wings      the first-person wings are in the head-view mirror (pixels
##              with and without them)
##   errors     none logged (the wrapper also greps the full log)
## Mirror screenshots: artifacts/integration/sim_*.png.

const Log := preload("res://tests/unit/integration/integration_log.gd")
## Coordination files. With --sim_io=<run id> (the wrapper) they are this
## run's own, artifacts/integration/sim_io/<id>_{state,driver,result}.json:
## the driver starts before the simulator lock is ours and must never read
## another run's state.
var STATE := "sim_state.json"
var RESULT := "sim_result.json"
var DRIVER := "sim_driver.json"

var main: GameMain
var log: Logger
var result := {"checks": {}, "metrics": {}}
var _flaps := 0
var _flap_strengths: Array[float] = []
var _hovered := ""


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var io := Paths.arg("sim_io", "")
	if not io.is_empty():
		DirAccess.make_dir_recursive_absolute(Paths.artifacts("integration").path_join("sim_io"))
		STATE = "sim_io/%s_state.json" % io
		RESULT = "sim_io/%s_result.json" % io
		DRIVER = "sim_io/%s_driver.json" % io
	main = get_parent() as GameMain
	log = Log.install()
	DirAccess.remove_absolute(Paths.artifacts("integration").path_join(RESULT))
	_write_state("boot")
	Events.player_flapped.connect(func(_side: int, s: float) -> void:
		_flaps += 1
		_flap_strengths.append(s))
	Events.game_state_changed.connect(func(_n: int, _o: int) -> void: _write_state(_phase))
	_run.call_deferred()


func _process(_dt: float) -> void:
	if main.ui != null and main.ui.pointer != null:
		var h := main.ui.pointer.hovered()
		var name_now := String(h.name) if h != null else ""
		if name_now != _hovered:
			_hovered = name_now
			_write_state(_phase)


var _phase := "boot"


func _write_state(phase: String) -> void:
	_phase = phase
	var f := FileAccess.open(Paths.artifacts("integration").path_join(STATE), FileAccess.WRITE)
	if f:
		var cal := main.rig_extras.calibration if main.rig_extras != null else null
		f.store_string(JSON.stringify({"phase": phase, "pid": OS.get_process_id(), "hovered": _hovered,
			"state": Game.state_name(), "t": Time.get_unix_time_from_system(),
			"calibration_step": String(cal._step_name(cal.flow)) if cal != null else "",
			"calibrated": cal != null and cal.calibrator.calibrated}))


## Image names carry the run's tag (sim_<tag>_<name>.png; the wrapper
## passes --tag): the Mobile runs' mirror shows MoltenVK's magenta tiles,
## the Forward+ run's is the clean one.
func _img(n: String) -> String:
	var tag := Paths.arg("tag", "")
	return "sim_%s.png" % n if tag.is_empty() else "sim_%s_%s.png" % [tag, n]


func _check(cname: String, ok: bool, detail: Variant) -> void:
	result["checks"][cname] = {"ok": ok, "detail": detail}
	print("[integration] SIM %s %s: %s" % ["PASS" if ok else "FAIL", cname, str(detail)])


var _drv_cache := {}
var _drv_ms := -1000


## The driver's report (read at most 5 times a second; a file caught
## mid-write just reads as the last good one, silently).
func _driver() -> Dictionary:
	if Time.get_ticks_msec() - _drv_ms < 200:
		return _drv_cache
	_drv_ms = Time.get_ticks_msec()
	var f := FileAccess.open(Paths.artifacts("integration").path_join(DRIVER), FileAccess.READ)
	if f == null:
		return _drv_cache
	var j := JSON.new()
	if j.parse(f.get_as_text()) == OK and j.data is Dictionary:
		_drv_cache = j.data
	return _drv_cache


func _wall(seconds: float) -> void:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < int(seconds * 1000.0):
		await get_tree().process_frame


func _run() -> void:
	# --- session and loading ---------------------------------------------------
	if not main.is_loaded:
		await main.loaded
	var t0 := Time.get_ticks_msec()
	while VR.session_state != "focused" and Time.get_ticks_msec() - t0 < 20000:
		await get_tree().process_frame
	_check("session_focused", VR.session_state == "focused", VR.session_state)
	var hz := VR.refresh_rate
	_check("physics_tick_is_refresh", Engine.physics_ticks_per_second == int(round(hz)),
		"%d ticks/s, refresh %.1f Hz" % [Engine.physics_ticks_per_second, hz])
	var lr := main.load_report
	result["metrics"]["load"] = lr
	# In the headset the long steps run before our first frame (the runtime's
	# own loading indicator shows meanwhile); after it, no frame of ours may
	# stand for long while the card is up.
	var pre := 0.0
	for st: Dictionary in lr.get("steps", []):
		if st.get("before_first_frame", false):
			pre += float(st["ms"])
	_check("loading_never_freezes_a_frame", lr.get("mode", "") == "early" and float(lr.get("worst_frame_gap_ms", 1e9)) < 250.0,
		"mode %s: %.0f ms of work before the first frame (engine start to main %d ms), then the card; worst frame gap after the first frame %.0f ms; menu after %.0f ms" % [
		lr.get("mode", "?"), pre, lr.get("engine_to_main_ms", -1), lr.get("worst_frame_gap_ms", -1), lr.get("total_ms", -1)])
	# --- the main menu in front of the head -------------------------------------
	await _wall(1.0)
	var cam := main.player.camera
	var menu_dir := (main.ui.menu_panel.control_to_world(main.ui.get_screen(&"main").get_button(&"play")) - cam.global_position).normalized()
	var head_fwd := -cam.global_basis.z
	var ang := rad_to_deg(head_fwd.angle_to(menu_dir))
	_check("main_menu_in_front", Game.state == Game.State.MENU and main.ui.current_screen_id() == &"main" and ang < 35.0,
		"state %s, screen %s, Play %.1f deg from the gaze" % [Game.state_name(), main.ui.current_screen_id(), ang])
	await main.mirror.capture(Paths.artifacts("integration").path_join(_img("menu")))
	# Nothing over the menu: the first-launch card waits for Play (the menu
	# has been up ~2 s with the headset focused by now).
	var cal := main.rig_extras.calibration
	var due := cal.first_launch_due()
	result["metrics"]["first_launch_due_at_menu"] = due
	_check("no_card_over_the_menu", cal.flow == VRCalibration.Flow.IDLE and (cal.prompt == null or not cal.prompt.visible),
		"calibration step %s at the menu (first launch due: %s)" % [cal._step_name(cal.flow), str(due)])
	# --- the driver aims the real right controller at Play and pulls ----------
	_write_state("menu")
	var gate_seen := {}
	t0 = Time.get_ticks_msec()
	while Game.state != Game.State.PLAYING and Time.get_ticks_msec() - t0 < 60000:
		await get_tree().process_frame
		if main.gate != null and main.gate.gating:
			break
		if _driver().get("menu_done", false) and Game.state != Game.State.PLAYING:
			await _wall(1.0)
			break
	if main.gate != null and main.gate.gating:
		# --- the first-flight gate: the card, the spread, the capture ----------
		await _wall(0.3)
		gate_seen = {"state": Game.state_name(), "screen": String(main.ui.current_screen_id()),
			"step": String(cal._step_name(cal.flow)), "reason": String(cal.flow_reason),
			"card": cal.prompt != null and cal.prompt.visible, "hint": cal.hint_text(),
			"body_still": not main.player.auto_process}
		await main.mirror.capture(Paths.artifacts("integration").path_join(_img("calib_card")))
		_write_state("calibrate")
		var t_card := Time.get_ticks_msec()
		var done_img := false
		while Game.state != Game.State.PLAYING and Time.get_ticks_msec() - t_card < 90000:
			await get_tree().process_frame
			if not done_img and cal.flow == VRCalibration.Flow.DONE:
				done_img = true
				gate_seen["captured_after_s"] = (Time.get_ticks_msec() - t_card) / 1000.0
				gate_seen["span"] = cal.calibrator.arm_span
				gate_seen["state_at_capture"] = Game.state_name()
				await main.mirror.capture(Paths.artifacts("integration").path_join(_img("calib_done")))
		gate_seen["outcome"] = main.gate.last_outcome
		gate_seen["run_started_after_s"] = (Time.get_ticks_msec() - t_card) / 1000.0
		gate_seen["calibrated"] = cal.calibrator.calibrated
		result["metrics"]["first_flight_gate"] = gate_seen
		_check("first_flight_gate", gate_seen["state"] == "MENU" and gate_seen["screen"] == "" and gate_seen["step"] == "capture"
			and gate_seen["reason"] == "first_launch" and gate_seen["card"] and gate_seen["body_still"]
			and gate_seen.get("state_at_capture", "") == "MENU" and main.gate.last_outcome == "captured"
			and cal.calibrator.calibrated and Game.state == Game.State.PLAYING, gate_seen)
	elif due:
		_check("first_flight_gate", false, "a first launch, but Play did not ask for the calibration (state %s)" % Game.state_name())
	var drv := _driver()
	await _wall(1.5)
	drv = _driver()
	_check("menu_play_with_the_controller", Game.state == Game.State.PLAYING,
		"hovered %s at the pull, %s pull(s), state %s" % [drv.get("hovered_at_pull", "?"), drv.get("pulls", "?"), Game.state_name()])
	if Game.state != Game.State.PLAYING:
		# Keep going (the rest of the checks still say something).
		main.game_loop.start_run()
	main.game_loop.set_protection(main.player, 1e6)
	await _wall(1.5)
	await main.mirror.capture(Paths.artifacts("integration").path_join(_img("play")))
	# --- real controller strokes --------------------------------------------------
	var flaps0 := _flaps
	_write_state("flap")
	t0 = Time.get_ticks_msec()
	while not _driver().get("spread_done", false) and Time.get_ticks_msec() - t0 < 60000:
		await get_tree().process_frame
	# Arms spread (the controllers out along the arms, as a player holds
	# them): the wings in the head view, and each wing looked at.
	await main.mirror.capture(Paths.artifacts("integration").path_join(_img("spread")))
	var cam_node := main.player.camera
	var wings := main.rig_extras.wings
	var wing_px := []
	for side: Array in [["left", 55.0], ["right", -55.0]]:
		var img: Image = await _capture_look(cam_node, float(side[1]))
		wings.visible = false
		var img_off: Image = await _capture_look(cam_node, float(side[1]))
		wings.visible = true
		if img:
			img.save_png(Paths.artifacts("integration").path_join(_img("look_%s_wing" % side[0])))
		wing_px.append(_diff_fraction(img, img_off))
	_check("wings_in_the_mirror", wing_px.size() == 2 and wing_px[0] > 0.01 and wing_px[1] > 0.01,
		"a glance at each spread wing: %.1f%% (left) and %.1f%% (right) of the head view is wing" % [wing_px[0] * 100.0, wing_px[1] * 100.0])
	_write_state("stroke")
	while not _driver().get("flaps_done", false) and Time.get_ticks_msec() - t0 < 90000:
		await get_tree().process_frame
	await _wall(0.5)
	var n := _flaps - flaps0
	_check("controller_strokes_flap", n >= 2, "%d wingbeats credited (strengths %s)" % [n, _flap_strengths.slice(-6)])
	result["metrics"]["flaps"] = n
	var img_after: Image = await main.mirror.capture_image()
	if img_after:
		img_after.save_png(Paths.artifacts("integration").path_join(_img("after_strokes")))
	# --- frame rate over 20 s of play ---------------------------------------------
	# In flight (integration round 2, the engineering verifier: after the
	# strokes the bird sat on the meadow, so the window measured neither
	# flight nor, once the governor had stepped, the tier's budget): the
	# bird is put 70 m over the valley's middle, gliding on the controllers'
	# last pose, and the share of the window it flew is reported and judged.
	var spawn_o := main.world.get_player_spawn().origin
	var mid := Vector3(spawn_o.x * 0.5, 0.0, spawn_o.z * 0.5)
	var start_at := Vector3(mid.x, main.world.ground_height(mid.x, mid.z) + 70.0, mid.z)
	main.player.start_flying(start_at, atan2(-(0.0 - mid.x), -(0.0 - mid.z)) if mid.length() > 1.0 else 0.0)
	await _wall(0.5)
	var budget0 := main.ecosystem.max_npcs
	var steps0 := main.governor.steps_taken if main.governor != null else 0
	var flying_frames := 0
	_write_state("fps")
	var intervals := PackedFloat32Array()
	var draws := 0.0
	var prims := 0.0
	var worst_draws := 0
	var worst_prims := 0
	var draws3d := 0.0
	var worst_draws3d := 0
	var worst_at := {}
	var frames := 0
	var tw := Time.get_ticks_usec()
	var prev := tw
	while Time.get_ticks_usec() - tw < 20000000:
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		intervals.append((now - prev) / 1000.0)
		prev = now
		frames += 1
		var d := int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
		var p := int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
		# The headset's own 3D view (visible + shadow passes), without the
		# UI SubViewports' 2D batches.
		var rid := get_viewport().get_viewport_rid()
		var d3 := RenderingServer.viewport_get_render_info(rid, RenderingServer.VIEWPORT_RENDER_INFO_TYPE_VISIBLE, RenderingServer.VIEWPORT_RENDER_INFO_DRAW_CALLS_IN_FRAME) \
			+ RenderingServer.viewport_get_render_info(rid, RenderingServer.VIEWPORT_RENDER_INFO_TYPE_SHADOW, RenderingServer.VIEWPORT_RENDER_INFO_DRAW_CALLS_IN_FRAME)
		draws += d
		prims += p
		draws3d += d3
		if d > worst_draws:
			worst_at = {"draws": d, "draws_3d": d3, "state": Game.state_name(), "pos": str(main.player.camera.global_position),
				"hud_rendering": main.ui.hud_panel.is_rendering_enabled(), "menu_rendering": main.ui.menu_panel.is_rendering_enabled()}
		worst_draws = maxi(worst_draws, d)
		worst_draws3d = maxi(worst_draws3d, d3)
		worst_prims = maxi(worst_prims, p)
		if main.player.mode == PlayerBird.Mode.FLYING:
			flying_frames += 1
	var secs := (Time.get_ticks_usec() - tw) / 1e6
	var fps := frames / secs
	var pacing := _pacing(intervals, hz)
	result["metrics"]["fps"] = {"fps": fps, "refresh": hz, "pacing": pacing, "draw_calls_mean": draws / frames,
		"draw_calls_max": worst_draws, "primitives_mean": prims / frames, "primitives_max": worst_prims,
		"draw_calls_3d_mean": draws3d / frames, "draw_calls_3d_max": worst_draws3d, "worst_frame": worst_at,
		"npcs": main.ecosystem.count(), "machine_load": _load_avg(), "flying_share": float(flying_frames) / frames,
		"npc_budget": main.ecosystem.max_npcs, "npc_budget_at_start": budget0, "tier_budget": main.quality.max_npcs,
		"governor_steps": (main.governor.steps_taken if main.governor != null else 0)}
	# (Forward+ runs are for clean mirror images; frame rate is judged on
	# the Mobile renderer, what the Quest runs.)
	var fps_ok := fps >= 0.95 * hz or RenderingServer.get_current_rendering_method() != "mobile"
	_check("fps_at_refresh", fps_ok, "%.2f fps over %.1f s (refresh %.0f Hz, %s renderer); p50 %.2f p95 %.2f p99 %.2f ms; %d NPCs (budget %d, the tier's %d); in flight %.0f%% of the frames" % [
		fps, secs, hz, RenderingServer.get_current_rendering_method(), pacing["p50"], pacing["p95"], pacing["p99"], main.ecosystem.count(),
		main.ecosystem.max_npcs, main.quality.max_npcs, 100.0 * flying_frames / frames])
	_check("fps_window_in_flight", float(flying_frames) / frames >= 0.9, "the bird flew %.0f%% of the fps window" % [100.0 * flying_frames / frames])
	# The tier's budget held for the whole run: a frame-rate check passed
	# after the governor thinned the sky judges a smaller sky than the tier.
	# (Judged with the frame rate, on the Mobile renderer: a Forward+ run on
	# this Mac draws at ~38 fps, and the governor thins its sky as it would
	# on a headset that slow.)
	var steps := main.governor.steps_taken if main.governor != null else 0
	var mobile := RenderingServer.get_current_rendering_method() == "mobile"
	_check("tier_budget_held", (steps == 0 and main.ecosystem.max_npcs == main.quality.max_npcs) or not mobile,
		"governor steps %d (%d before the window); NPC budget %d of the tier's %d; machine load %s; %s renderer" % [steps, steps0,
		main.ecosystem.max_npcs, main.quality.max_npcs, _load_avg(), RenderingServer.get_current_rendering_method()])
	_check("draw_budget", worst_draws3d <= 150 and worst_prims <= 300000,
		"headset view: %d draw calls mean, %d max (all passes incl. UI SubViewports: %d mean, %d max); %d primitives max; worst frame %s" % [
		int(draws3d / frames), worst_draws3d, int(draws / frames), worst_draws, worst_prims, worst_at])
	await main.mirror.capture(Paths.artifacts("integration").path_join(_img("flight")))
	# --- errors, verdict -----------------------------------------------------------
	_check("no_errors", log.errors == 0 and log.warnings == 0, log.summary())
	var ok := true
	for k in result["checks"]:
		ok = ok and bool(result["checks"][k]["ok"])
	result["pass"] = ok
	var f := FileAccess.open(Paths.artifacts("integration").path_join(RESULT), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(result, "  "))
	print("[integration] SIM RESULT %s" % ("PASS" if ok else "FAIL"))
	_write_state("done")
	log.uninstall()
	main.quit_game()


## The mirror from the head's position turned by yaw_deg and 25 deg down
## (evidence of what a glance at a wing shows; the simulated head itself
## stays where the simulator has it).
func _capture_look(cam_node: Node3D, yaw_deg: float) -> Image:
	var xf := cam_node.global_transform
	var yaw := xf.basis.get_euler().y
	var look := Camera3D.new()
	look.current = false
	add_child(look)
	look.global_transform = Transform3D(Basis(Vector3.UP, yaw + deg_to_rad(yaw_deg)) * Basis(Vector3.RIGHT, deg_to_rad(-25.0)), xf.origin)
	look.near = (cam_node as Camera3D).near
	main.mirror.source = look
	var img: Image = await main.mirror.capture_image()
	main.mirror.source = main.player.camera
	look.queue_free()
	return img


static func _diff_fraction(a: Image, b: Image) -> float:
	if a == null or b == null or a.get_size() != b.get_size():
		return 0.0
	var n := 0
	var tot := 0
	for y in range(0, a.get_height(), 2):
		for x in range(0, a.get_width(), 2):
			tot += 1
			var ca := a.get_pixel(x, y)
			var cb := b.get_pixel(x, y)
			if absf(ca.r - cb.r) + absf(ca.g - cb.g) + absf(ca.b - cb.b) > 0.06:
				n += 1
	return float(n) / maxf(tot, 1.0)


static func _pacing(intervals: PackedFloat32Array, refresh: float) -> Dictionary:
	var v := intervals.duplicate()
	v.sort()
	var n := v.size()
	var pct := func(q: float) -> float:
		return snappedf(v[clampi(int(ceil(q * n)) - 1, 0, n - 1)], 0.01) if n > 0 else 0.0
	var budget := 1000.0 / maxf(refresh, 1.0)
	var over := 0
	for x in v:
		if x > 1.5 * budget:
			over += 1
	return {"frames": n, "budget_ms": snappedf(budget, 0.01), "p50": pct.call(0.50), "p95": pct.call(0.95),
		"p99": pct.call(0.99), "max": snappedf(v[n - 1], 0.01) if n > 0 else 0.0, "over_1_5_intervals": over}


func _load_avg() -> String:
	var out := []
	OS.execute("sysctl", ["-n", "vm.loadavg"], out)
	return String(out[0]).strip_edges() if not out.is_empty() else ""
