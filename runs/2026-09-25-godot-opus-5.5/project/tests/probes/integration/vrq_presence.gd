extends Node3D
## VERIFIER PROBE (integration verify round 1). The shipped main.tscn in
## the Meta XR Simulator: the headset taken off during a run (SimRpc
## DeviceService/SetUserPresent, runtime state only) must pause the game
## with the pause menu up while the head keeps tracking, and putting it back
## on must leave it paused (the player resumes deliberately) and raise the
## "New player? Recalibrate wings" hint. Driver: vrq_presence_driver.py.

const MAIN := preload("res://scenes/main.tscn")
const LogScript := preload("res://tests/unit/integration/integration_log.gd")

var main: GameMain
var _logger: Object
var out_dir := ""
var phase := "boot"
var res := {"checks": {}, "events": []}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	out_dir = Paths.artifacts("integration").path_join("verify/vrq")
	DirAccess.make_dir_recursive_absolute(out_dir)
	DirAccess.remove_absolute(out_dir.path_join("presence_driver.json"))
	_logger = LogScript.install()
	_state()
	VR.user_presence_changed.connect(func(p: bool) -> void: res["events"].append("presence %s, state %s" % [p, Game.state_name()]))
	main = MAIN.instantiate() as GameMain
	main.name = "Main"
	add_child(main)
	_run.call_deferred()


func _state() -> void:
	var f := FileAccess.open(out_dir.path_join("presence_state.json"), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify({"phase": phase, "pid": OS.get_process_id(), "state": Game.state_name()}))


func _drv() -> Dictionary:
	var f := FileAccess.open(out_dir.path_join("presence_driver.json"), FileAccess.READ)
	if f == null:
		return {}
	var j := JSON.new()
	return j.data if j.parse(f.get_as_text()) == OK and j.data is Dictionary else {}


func _until(cond: Callable, timeout: float) -> bool:
	var t := Time.get_ticks_msec()
	while not cond.call() and Time.get_ticks_msec() - t < int(timeout * 1000.0):
		await get_tree().process_frame
	return cond.call()


func _check(n: String, ok: bool, detail: Variant) -> void:
	res["checks"][n] = {"ok": ok, "detail": detail}
	print("[integration-verify] CHECK %s %s: %s" % ["PASS" if ok else "FAIL", n, str(detail)])


func _run() -> void:
	if not main.is_loaded:
		await main.loaded
	await _until(func() -> bool: return VR.session_state == "focused", 20.0)
	# Out of the first-launch card if there is one (not what this checks).
	main.rig_extras.calibration.cancel()
	await _until(func() -> bool: return Game.state == Game.State.MENU, 5.0)
	main.game_loop.start_run()
	main.game_loop.set_protection(main.player, 1e6)
	await _until(func() -> bool: return Game.state == Game.State.PLAYING, 5.0)
	await get_tree().create_timer(2.0, true, false, true).timeout
	phase = "off"
	_state()
	var paused := await _until(func() -> bool: return Game.state == Game.State.PAUSED, 15.0)
	var screen := main.ui.current_screen_id()
	var cam0 := main.player.camera.transform
	await _until(func() -> bool: return bool(_drv().get("off_done", false)), 15.0)
	_check("headset_off_pauses_with_menu", paused and screen == &"pause" and not VR.focused,
		"state %s, screen %s, VR.focused %s, presence_supported %s" % [Game.state_name(), screen, VR.focused, VR.presence_supported])
	phase = "on"
	_state()
	await _until(func() -> bool: return VR.focused, 15.0)
	await get_tree().create_timer(1.5, true, false, true).timeout
	_check("headset_on_stays_paused_and_suggests", Game.state == Game.State.PAUSED and VR.focused and VR.recalibration_suggested
		and main.ui.current_screen_id() == &"pause",
		"state %s, focused %s, recalibration_suggested %s, screen %s, pause button shown %s" % [Game.state_name(), VR.focused,
		VR.recalibration_suggested, main.ui.current_screen_id(), main.ui.context().get("recalibrate_suggested", "?")])
	await main.mirror.capture(out_dir.path_join("presence_back_on.png"))
	_check("no_errors_or_warnings", _logger.errors == 0 and _logger.warnings == 0, _logger.summary())
	res["events"].append("done")
	var f := FileAccess.open(out_dir.path_join("presence_result.json"), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(res, "  "))
	phase = "done"
	_state()
	_logger.uninstall()
	main.quit_game()
