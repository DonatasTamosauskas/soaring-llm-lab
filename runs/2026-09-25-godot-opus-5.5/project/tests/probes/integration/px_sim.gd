extends Node
## VERIFIER PROBE (integration, player-experience lens, round 1): the real
## main.tscn in the Meta XR Simulator, played with the simulator's own
## controllers moved over SimRpc by tests/probes/integration/px_sim_driver.py
## (menu laser + trigger on Play, spread, strokes, a wrist twist, one arm
## raised). Independent of the builder's harness: own state files under
## artifacts/integration/verify/, own checks, head-view mirror images.
##
##   python3 tests/probes/integration/px_sim_driver.py &   # waits for this run
##   tools/xr.sh 300 res://tests/probes/integration/px_sim.tscn -- --xrdiag
##
## Writes artifacts/integration/verify/px_sim_result.json, px_sim_*.png.

const MAIN := preload("res://scenes/main.tscn")
const Log := preload("res://tests/unit/integration/integration_log.gd")
const DIR := "verify"

var main: GameMain
var log: Logger
var out := {"phases": {}, "samples": []}
var _phase := "boot"
var _flaps := 0
var _rec: Array = []
var _recording := false
var _tick := 0
var _intervals := PackedFloat32Array()
var _prev_us := 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	log = Log.install()
	_write_state("boot")
	main = MAIN.instantiate() as GameMain
	add_child(main)
	Events.player_flapped.connect(func(_s: int, _st: float) -> void: _flaps += 1)
	_run.call_deferred()


func _path(n: String) -> String:
	return Paths.artifacts("integration").path_join(DIR).path_join(n)


func _write_state(phase: String) -> void:
	_phase = phase
	var hov := ""
	if main != null and main.ui != null and main.ui.pointer != null and main.ui.pointer.hovered() != null:
		hov = String(main.ui.pointer.hovered().name)
	var f := FileAccess.open(_path("px_sim_state.json"), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify({"phase": phase, "pid": OS.get_process_id(), "hovered": hov,
			"state": Game.state_name(), "t": Time.get_unix_time_from_system()}))


var _hov_prev := ""


func _process(_dt: float) -> void:
	if main != null and main.ui != null and main.ui.pointer != null:
		var h := main.ui.pointer.hovered()
		var n := String(h.name) if h != null else ""
		if n != _hov_prev:
			_hov_prev = n
			_write_state(_phase)
	if _recording:
		var now := Time.get_ticks_usec()
		if _prev_us > 0:
			_intervals.append((now - _prev_us) / 1000.0)
		_prev_us = now


func _physics_process(_dt: float) -> void:
	if not _recording or main == null or main.player == null:
		return
	_tick += 1
	if _tick % 9 != 0:
		return
	var p := main.player
	var t: Dictionary = p.telemetry()
	_rec.append({"ph": _phase, "t": snappedf(_tick / 72.0, 0.01), "y": snappedf(p.global_position.y, 0.01),
		"as": snappedf(t["airspeed"], 0.01), "vy": snappedf(p.velocity.y, 0.01), "bank": snappedf(rad_to_deg(t["bank"]), 0.1),
		"hdg": snappedf(rad_to_deg(t["heading"]), 0.1), "mode": t["mode"], "ext_l": snappedf(t["extension_l"], 0.01),
		"ext_r": snappedf(t["extension_r"], 0.01), "tw_l": snappedf(t["twist_l"], 0.01), "tw_r": snappedf(t["twist_r"], 0.01),
		"roll_in": snappedf(t["roll_input"], 0.01), "pitch_in": snappedf(t["pitch_input"], 0.01), "flaps": _flaps,
		"tracking": t["tracking"], "calibrated": t["calibrated"], "cam_roll": snappedf(rad_to_deg(p.camera.global_basis.get_euler().z), 0.01),
		"agl": snappedf(t["altitude_agl"], 0.1), "contacts": t["contacts"], "vignette": _vignette()})


func _vignette() -> float:
	var v: Node = main.rig_extras.get(&"vignette") if main.rig_extras != null else null
	if v != null and v.get(&"_shown_strength") != null:
		return snappedf(float(v.get(&"_shown_strength")), 0.01)
	return -1.0


var _drv := {}
var _drv_ms := -1000


func _driver() -> Dictionary:
	if Time.get_ticks_msec() - _drv_ms < 200:
		return _drv
	_drv_ms = Time.get_ticks_msec()
	var f := FileAccess.open(_path("px_sim_driver.json"), FileAccess.READ)
	if f:
		var j := JSON.new()
		if j.parse(f.get_as_text()) == OK and j.data is Dictionary:
			_drv = j.data
	return _drv


func _wall(s: float) -> void:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < int(s * 1000.0):
		await get_tree().process_frame


func _wait_driver(key: String, max_s: float) -> bool:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < int(max_s * 1000.0):
		if bool(_driver().get(key, false)):
			return true
		await get_tree().process_frame
	return false


func _shot(n: String) -> void:
	await main.mirror.capture(_path("px_sim_%s.png" % n))


func _visible_prompts() -> Array:
	var o := []
	for n in get_tree().root.find_children("*", "", true, false):
		var s: Script = n.get_script()
		if s != null and String(s.get_global_name()) == "CalibrationPrompt" and n is Node3D and (n as Node3D).is_visible_in_tree():
			o.append(String(n.get_path()))
	return o


func _prompt_text() -> String:
	var o := []
	for n in get_tree().root.find_children("*", "Label3D", true, false):
		if (n as Node3D).is_visible_in_tree() and not String((n as Label3D).text).is_empty():
			o.append(String((n as Label3D).text).replace("\n", " / "))
	return " | ".join(o)


func _run() -> void:
	if not main.is_loaded:
		await main.loaded
	var t0 := Time.get_ticks_msec()
	while VR.session_state != "focused" and Time.get_ticks_msec() - t0 < 20000:
		await get_tree().process_frame
	out["session"] = VR.session_state
	out["refresh"] = VR.refresh_rate
	out["load"] = main.load_report
	await _wall(1.5)
	out["calibration_prompts_at_menu"] = _visible_prompts()
	out["calibration_prompt_text_at_menu"] = _prompt_text()
	await _shot("menu")
	if Paths.arg("px_first", "0") == "1":
		# First launch: do what the card says (spread, hold still), then look.
		_write_state("calib")
		var ok_c := await _wait_driver("calib_spread", 60.0)
		await _wall(0.2)
		await _shot("calib_spread")
		out["calib_prompt_text_spread"] = _prompt_text()
		ok_c = await _wait_driver("calib_done", 60.0) and ok_c
		await _wall(0.5)
		out["calibration_prompts_after_calib"] = _visible_prompts()
		out["calib_prompt_text_after"] = _prompt_text()
		out["calib_driver_ok"] = ok_c
		await _shot("after_calib")
	_write_state("menu")
	t0 = Time.get_ticks_msec()
	while Game.state != Game.State.PLAYING and Time.get_ticks_msec() - t0 < 90000:
		await get_tree().process_frame
		if bool(_driver().get("menu_done", false)):
			await _wall(1.5)
			break
	out["play_by_controller"] = Game.state == Game.State.PLAYING
	out["calibration_prompts_at_play"] = _visible_prompts()
	if Game.state != Game.State.PLAYING:
		main.game_loop.start_run()
		await _wall(0.5)
	main.game_loop.set_protection(main.player, 1e6)
	_recording = true
	await _wall(1.0)
	await _shot("play")
	for ph: Array in [["spread", "spread_done", 60.0], ["stroke", "strokes_done", 90.0], ["level", "level_done", 40.0],
			["twist", "twist_done", 40.0], ["dihedral", "dihedral_done", 40.0]]:
		var y0 := main.player.global_position.y
		var h0 := float(main.player.telemetry()["heading"])
		var f0 := _flaps
		var i0 := _rec.size()
		_write_state(ph[0])
		var ok := await _wait_driver(ph[1], ph[2])
		await _wall(0.3)
		if ph[0] == "stroke":
			await _shot("after_strokes")
		var bank_max := 0.0
		for r: Dictionary in _rec.slice(i0):
			bank_max = maxf(bank_max, absf(r["bank"]))
		out["phases"][ph[0]] = {"driver_ok": ok, "dy": snappedf(main.player.global_position.y - y0, 0.01),
			"dhdg_deg": snappedf(rad_to_deg(wrapf(float(main.player.telemetry()["heading"]) - h0, -PI, PI)), 0.1),
			"flaps": _flaps - f0, "bank_max_deg": bank_max, "mode_end": main.player.mode_name(),
			"airspeed_end": snappedf(float(main.player.telemetry()["airspeed"]), 0.01)}
		print("[integration] px_sim phase %s: %s" % [ph[0], out["phases"][ph[0]]])
		if ph[0] == "spread":
			await _shot("spread")
	await _shot("end")
	_write_state("glide")
	await _wall(4.0)
	await _shot("glide")
	_recording = false
	var v := _intervals.duplicate()
	v.sort()
	var n := v.size()
	if n > 0:
		var over := 0
		for x in v:
			if x > 1.5 * 1000.0 / maxf(out["refresh"], 1.0):
				over += 1
		out["frames"] = {"n": n, "p50": v[int(n * 0.5)], "p95": v[mini(int(n * 0.95), n - 1)], "p99": v[mini(int(n * 0.99), n - 1)],
			"max": v[n - 1], "over_1_5": over, "fps": 1000.0 * n / maxf(Array(v).reduce(func(a: float, b: float) -> float: return a + b, 0.0), 1.0)}
	out["samples"] = _rec
	out["errors"] = log.errors
	out["warnings"] = log.warnings
	out["log"] = log.samples
	out["driver"] = _driver()
	var f := FileAccess.open(_path("px_sim_result.json"), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(out, "  "))
		f.close()
	print("[integration] px_sim done: play %s, frames %s, %s" % [out["play_by_controller"], out.get("frames", {}), log.summary()])
	_write_state("done")
	log.uninstall()
	main.quit_game()
