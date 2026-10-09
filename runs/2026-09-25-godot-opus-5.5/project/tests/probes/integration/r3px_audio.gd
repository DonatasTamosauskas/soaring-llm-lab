extends Node
## VERIFIER PROBE (integration, player-experience lens, round 1; re-run in round 3 as r3px_audio).
## What the integrated game's mixer does while a desktop player plays (real
## time, keyboard through DesktopPoseSource): per-bus peak levels each frame
## in the menu, perched, flapping, gliding, diving, stalling and paused,
## against airspeed. Headless: the Dummy audio driver still mixes, nothing
## is played on the speakers.
##
##   tools/gd.sh pxv_audio --headless res://tests/probes/integration/px_audio.tscn -- --fresh-settings

const Kit := preload("res://tests/unit/integration/game_kit.gd")
const BUSES := ["Master", "Music", "SFX", "Wind", "Body", "Calls", "Danger", "Ambience", "UI"]

var kit: Kit
var main: GameMain
var rows := []
var phase := "boot"
var sampling := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_run.call_deferred()


func _key(code: Key, down: bool) -> void:
	var e := InputEventKey.new()
	e.keycode = code
	e.physical_keycode = code
	e.pressed = down
	Input.parse_input_event(e)


func _process(_dt: float) -> void:
	if not sampling:
		return
	var r := {"ph": phase, "t": Time.get_ticks_msec()}
	for b in BUSES:
		var i := AudioServer.get_bus_index(b)
		if i >= 0:
			r[b] = maxf(AudioServer.get_bus_peak_volume_left_db(i, 0), AudioServer.get_bus_peak_volume_right_db(i, 0))
	if main != null and main.player != null:
		r["as"] = float(main.player.telemetry()["airspeed"])
		r["stall"] = bool(main.player.telemetry()["stalled"])
	rows.append(r)


func _secs(s: float) -> void:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < int(s * 1000.0):
		await get_tree().process_frame


func _ph(name: String, keys: Array, s: float) -> void:
	phase = name
	for k in keys:
		_key(k, true)
	await _secs(s)
	for k in keys:
		_key(k, false)


func _run() -> void:
	kit = Kit.new()
	if not await kit.boot(self, true):
		get_tree().quit()
		return
	main = kit.main
	# Real time: undo the kit's 3x.
	Engine.time_scale = 1.0
	Engine.physics_ticks_per_second = 72
	Engine.max_physics_steps_per_frame = 4
	OS.low_processor_usage_mode_sleep_usec = 6900
	sampling = true
	await _ph("menu", [], 5.0)
	await kit.click(&"main", &"play")
	await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 3.0)
	main.game_loop.set_protection(main.player, 1e6)
	await _ph("perched", [], 3.0)
	await _ph("flap", [KEY_SPACE], 5.0)
	await _ph("glide", [], 3.0)
	await _ph("speed_W", [KEY_W], 3.0)
	await _ph("dive_tuck", [KEY_SHIFT], 2.5)
	await _ph("pullout_flap", [KEY_SPACE], 4.0)
	await _ph("stall_S", [KEY_S], 3.0)
	await _ph("recover", [], 3.0)
	_key(KEY_ESCAPE, true)
	await kit.frames(2)
	_key(KEY_ESCAPE, false)
	await _ph("paused", [], 4.0)
	sampling = false
	var sumr := {}
	for r: Dictionary in rows:
		var ph: String = r["ph"]
		if not sumr.has(ph):
			sumr[ph] = {"n": 0, "as_mean": 0.0}
			for b in BUSES:
				sumr[ph][b + "_max"] = -200.0
				sumr[ph][b + "_mean_lin"] = 0.0
		var s: Dictionary = sumr[ph]
		s["n"] += 1
		s["as_mean"] += float(r.get("as", 0.0))
		for b in BUSES:
			if r.has(b):
				s[b + "_max"] = maxf(s[b + "_max"], r[b])
				s[b + "_mean_lin"] += db_to_linear(maxf(r[b], -80.0))
	for ph in sumr:
		var s: Dictionary = sumr[ph]
		s["as_mean"] = snappedf(s["as_mean"] / s["n"], 0.01)
		for b in BUSES:
			s[b + "_max"] = snappedf(s[b + "_max"], 0.1)
			s[b + "_mean_db"] = snappedf(linear_to_db(maxf(s[b + "_mean_lin"] / s["n"], 1e-5)), 0.1)
			s.erase(b + "_mean_lin")
	var over := 0
	for r: Dictionary in rows:
		if float(r.get("Master", -200.0)) > -1.0:
			over += 1
	var out := {"phases": sumr, "master_frames_over_minus1db": over, "frames": rows.size(), "errors": kit.log.errors,
		"log": kit.log.samples, "audio_driver": AudioServer.get_driver_name() if AudioServer.has_method(&"get_driver_name") else "?",
		"director": main.audio.debug_snapshot() if main.audio else {}}
	var f := FileAccess.open(Paths.artifacts("integration").path_join("verify/r3px/r3px_audio.json"), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(out, "  "))
		f.close()
	for ph in sumr:
		var s: Dictionary = sumr[ph]
		print("[integration] px_audio %-12s as %5.1f  master %6.1f/%6.1f  music %6.1f  wind %6.1f/%6.1f  body %6.1f  calls %6.1f  danger %6.1f  amb %6.1f  ui %6.1f" % [
			ph, s["as_mean"], s["Master_max"], s["Master_mean_db"], s["Music_mean_db"], s["Wind_max"], s["Wind_mean_db"], s["Body_max"], s["Calls_max"], s["Danger_max"], s["Ambience_mean_db"], s["UI_max"]])
	print("[integration] px_audio done: master>-1dB frames %d of %d; %s" % [over, rows.size(), kit.log.summary()])
	await kit.teardown()
	get_tree().quit()
