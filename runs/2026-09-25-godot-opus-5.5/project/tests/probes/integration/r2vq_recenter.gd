extends Node3D
## VERIFIER PROBE (integration verify round 2; lens: VR comfort). Not a game
## file. The shipped main.tscn in the Meta XR Simulator: what the headset
## shows around a recenter (A/X held 1 s) done IN PLAY and IN THE PAUSE MENU,
## with the head turned ~50 deg by the simulator's own keys (driver:
## r2vq_sim_driver.py phases head_turn / recenter / head_back).
## Every frame: the XRCamera3D's global yaw (what the eyes see), the rig's
## (XROrigin3D) global yaw and the camera's yaw inside the rig. A recenter
## should change the view once, or not at all; a jump that comes back within
## a few frames is a flicker, and one that comes back at Resume is a snap
## back.
## Output: artifacts/integration/verify/r2vq/recenter_result.json

const MAIN := preload("res://scenes/main.tscn")
const LogScript := preload("res://tests/unit/integration/integration_log.gd")

var main: GameMain
var _logger: Object
var out_dir := ""
var phase := "boot"
var res := {"checks": {}, "series": {}}
var _series: Array = []
var _rec := false
var _drv := {}
var _drv_ms := -1000


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	process_priority = 100000
	out_dir = Paths.artifacts("integration").path_join("verify/r2vq")
	DirAccess.make_dir_recursive_absolute(out_dir)
	DirAccess.remove_absolute(out_dir.path_join("driver.json"))
	_logger = LogScript.install()
	_state()
	main = MAIN.instantiate() as GameMain
	main.name = "Main"
	add_child(main)
	_run.call_deferred()


func _state() -> void:
	var f := FileAccess.open(out_dir.path_join("state.json"), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify({"phase": phase, "pid": OS.get_process_id(), "hovered": "", "state": Game.state_name(),
			"aim": {}, "status": {}, "t": Time.get_unix_time_from_system()}))


func _set_phase(p: String) -> void:
	phase = p
	print("[integration-verify] phase ", p)
	_state()


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


func _until(cond: Callable, timeout: float) -> bool:
	var t := Time.get_ticks_msec()
	while not cond.call() and Time.get_ticks_msec() - t < int(timeout * 1000.0):
		await get_tree().process_frame
	return cond.call()


func _wall(s: float) -> void:
	var t := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t < int(s * 1000.0):
		await get_tree().process_frame


static func _yaw(b: Basis) -> float:
	var f := -b.z
	return rad_to_deg(atan2(-f.x, -f.z))


func _process(_dt: float) -> void:
	if not _rec or main == null or main.player == null:
		return
	var cam := main.player.camera
	var o := main.player.origin
	var hmd := XRServer.get_hmd_transform()
	_series.append([Engine.get_process_frames(), Time.get_ticks_msec(), snappedf(_yaw(cam.global_basis), 0.01),
		snappedf(_yaw(o.global_basis), 0.01), snappedf(_yaw(cam.transform.basis), 0.01), snappedf(_yaw(hmd.basis), 0.01),
		Game.state_name(), VR.recenter_count])


## Largest one-frame change of the view's yaw, and whether it came back.
func _analyse(ser: Array) -> Dictionary:
	var jumps := []
	for i in range(1, ser.size()):
		var d := wrapf(float(ser[i][2]) - float(ser[i - 1][2]), -180.0, 180.0)
		if absf(d) > 10.0:
			var back := false
			var back_after := -1
			for k in range(i + 1, mini(ser.size(), i + 400)):
				var dk := wrapf(float(ser[k][2]) - float(ser[k - 1][2]), -180.0, 180.0)
				if absf(dk) > 10.0 and signf(dk) != signf(d):
					back = true
					back_after = k - i
					break
			jumps.append({"frame_index": i, "deg": snappedf(d, 0.1), "rig_step": snappedf(wrapf(float(ser[i][3]) - float(ser[i - 1][3]), -180.0, 180.0), 0.1),
				"cam_local_step": snappedf(wrapf(float(ser[i][4]) - float(ser[i - 1][4]), -180.0, 180.0), 0.1),
				"state": ser[i][6], "recenters": ser[i][7], "snaps_back_after_frames": back_after if back else -1})
	return {"frames": ser.size(), "jumps_over_10deg": jumps}


func _recenter_case(label: String, paused: bool) -> void:
	_series = []
	_rec = true
	var n0 := int(_driver().get("head_turned_n", 0))
	_set_phase("head_turn")
	await _until(func() -> bool: return int(_driver().get("head_turned_n", 0)) > n0, 30.0)
	await _wall(0.3)
	var rc0 := VR.recenter_count
	_set_phase("recenter")
	await _until(func() -> bool: return VR.recenter_count > rc0, 12.0)
	await _wall(1.0)
	if paused:
		# Resume the way the pause menu's Resume does.
		main.ui.resume()
		await _wall(1.0)
	_rec = false
	res["series"][label] = _series
	res["checks"][label] = _analyse(_series)
	print("[integration-verify] RECENTER %s: %s" % [label, JSON.stringify(res["checks"][label])])
	var d0 := int(_driver().get("head_turn_done_n", 0))
	_set_phase("head_back")
	await _until(func() -> bool: return int(_driver().get("head_turn_done_n", 0)) > d0, 30.0)


func _run() -> void:
	if not main.is_loaded:
		await main.loaded
	await _until(func() -> bool: return VR.session_state == "focused", 20.0)
	await _wall(1.0)
	_set_phase("menu")
	# Play through the bridge; skip the first-launch card (as B/Y does).
	main.ui.bridge.start_run()
	await _wall(0.5)
	var cal := main.rig_extras.calibration
	if cal.is_running():
		cal.cancel()
	await _until(func() -> bool: return Game.state == Game.State.PLAYING, 10.0)
	main.game_loop.set_protection(main.player, 1e6)
	await _wall(2.0)
	await _recenter_case("in_play", false)
	await _wall(1.0)
	Events.menu_requested.emit()
	await _until(func() -> bool: return Game.state == Game.State.PAUSED, 5.0)
	await _wall(0.5)
	await _recenter_case("in_pause", true)
	res["errors"] = _logger.summary()
	var f := FileAccess.open(out_dir.path_join("recenter_result.json"), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(res))
	_set_phase("done")
	_logger.uninstall()
	main.quit_game()
