extends Node3D
## Meta XR Simulator check of the calibration step (the redesign after fix
## round 6). Runs under tools/xr.sh with the SimRpc driver alongside (use
## tests/sim/run_calibration_sim.sh) and verifies itself, writing
## artifacts/vr/sim_calibration_result.json and a
## "[vr] SIM CALIBRATION RESULT PASS|FAIL" line:
##
##   first_launch_card   no saved calibration: once the session is FOCUSED
##                       the card comes up by itself, saying exactly "Stand
##                       tall. Spread your wings, hands flat. Hold still."
##   rest_not_captured   the simulator's resting controllers (0.6 m apart in
##                       front) are held 3 s: nothing is captured, the card
##                       names the problem
##   driven_capture      tests/sim/sim_driver.py (mode "calibrate") moves and
##                       turns the REAL simulated controllers over SimRpc
##                       into a spread at shoulder height (keys only, closed
##                       loop on this harness's own reading): nothing is
##                       captured while they move; once still, the spread is
##                       captured, confirmed, and the body is plausible
##   button_cancel       a new step is cancelled by the driver pressing the
##                       simulator's B/Y key: the calibration is unchanged
##   presence_flag       the driver takes the headset off and puts it back on
##                       (DeviceService/SetUserPresent): nothing is
##                       recalibrated, only VR.recalibration_suggested rises
##                       (reported as not driven if the runtime has no such
##                       call; not a failure then)
## Script errors are checked by the wrapper on the full log. Mirror shots:
## sim_calibration_card / _holding / _done / _cancelled.png.

const Env := preload("res://scenes/dev/vr_dev_env.gd")
const MemoryStore := preload("res://tests/unit/vr/vr_memory_store.gd")
const STATE := "sim_state.json"
const DRIVER := "sim_driver.json"

var rig: Dictionary
var extras: VRRigExtras
var cal: VRCalibration
var mirror: XRMirror
var result := {"checks": {}, "metrics": {}, "timeline": []}
var _t0 := 0
var _phase := "boot"
var _status_t := 0.0
var _events: Array = []


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_t0 = Time.get_ticks_msec()
	DirAccess.remove_absolute(Paths.artifacts("vr").path_join(DRIVER))
	_write_state("boot")
	Env.build_environment(self)
	# A first launch: nothing saved (a private store, never user://).
	rig = Env.build_rig(self, Vector3.ZERO, MemoryStore.new(), false, false)
	extras = rig["extras"]
	cal = extras.calibration
	mirror = XRMirror.new()
	mirror.source = rig["camera"]
	mirror.fov = 90.0
	add_child(mirror)
	cal.flow_changed.connect(func(step: StringName, _p: String, _g: float) -> void:
		if _events.is_empty() or _events.back()[1] != String(step):
			_events.append([_now(), String(step)]))
	cal.calibrator.captured.connect(func(_k: StringName) -> void: _events.append([_now(), "captured"]))
	VR.user_presence_changed.connect(func(p: bool) -> void: _events.append([_now(), "presence_%s" % str(p)]))
	VR.recalibration_suggested_changed.connect(func(on: bool) -> void: _events.append([_now(), "suggested_%s" % str(on)]))
	_run.call_deferred()


func _now() -> float:
	return (Time.get_ticks_msec() - _t0) / 1000.0


func _process(dt: float) -> void:
	# While the driver works it reads what this harness sees, 5 times a
	# second (closed loop on the game's own reading of the controllers).
	if _phase in ["input", "cancel", "presence"]:
		_status_t -= dt
		if _status_t <= 0.0:
			_status_t = 0.2
			_write_state(_phase)


func _check(name: String, ok: bool, detail: Variant) -> void:
	result["checks"][name] = {"ok": ok, "detail": detail}
	print("[vr] SIM %s %s: %s" % ["PASS" if ok else "FAIL", name, JSON.stringify(detail)])


## The forearm axis each grip shows now, in degrees from the grip
## convention (the capture refuses > 45°), from the calibrator's shoulders.
func _axis_deg() -> Array:
	var c := cal.calibrator
	var out := []
	for i in 2:
		var arm := (c.hands[i].origin - c.shoulders[i]).normalized()
		var a := (c.hands[i].basis.transposed() * arm).normalized()
		out.append(snappedf(rad_to_deg(a.angle_to(WingCalibrator.DEFAULT_FOREARM)), 0.1))
	return out


func _status() -> Dictionary:
	var c := cal.calibrator
	return {"flow": VRCalibration.Flow.keys()[cal.flow], "reason": String(cal.flow_reason), "blocker": c.neutral_blocker(),
		"progress": snappedf(float(c.capture_status()["progress"]), 0.01), "calibrated": c.calibrated,
		"axis_deg": _axis_deg(), "gap": snappedf((c.hands[1].origin - c.hands[0].origin).length(), 0.001),
		"left": _v(c.hands[0].origin), "right": _v(c.hands[1].origin), "head": _v(c.head.origin),
		"elev_deg": [snappedf(rad_to_deg(c.elevation[0]), 0.1), snappedf(rad_to_deg(c.elevation[1]), 0.1)],
		"sweep_deg": [snappedf(rad_to_deg(c.sweep[0]), 0.1), snappedf(rad_to_deg(c.sweep[1]), 0.1)],
		"speed": [snappedf(c.hand_speed[0], 0.001), snappedf(c.hand_speed[1], 0.001)],
		"valid": [c.valid[0], c.valid[1], c.head_valid], "suggested": VR.recalibration_suggested,
		"focused": VR.focused, "present": VR.user_present}


static func _v(p: Vector3) -> Array:
	return [snappedf(p.x, 0.001), snappedf(p.y, 0.001), snappedf(p.z, 0.001)]


func _write_state(phase: String) -> void:
	_phase = phase
	var d := {"phase": phase, "pid": OS.get_process_id(), "t": Time.get_unix_time_from_system()}
	if phase != "boot":
		d["status"] = _status()
	var path := Paths.artifacts("vr").path_join(STATE)
	var f := FileAccess.open(path + ".tmp", FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(d))
		f.close()
		DirAccess.rename_absolute(path + ".tmp", path)


func _driver() -> Dictionary:
	var p := Paths.artifacts("vr").path_join(DRIVER)
	if not FileAccess.file_exists(p):
		return {}
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(p))
	return d if d is Dictionary else {}


func _shot(name: String) -> void:
	var img := await mirror.capture_image()
	if img != null:
		# Forward+ runs (clean images) end in _fplus, as tests/sim/vr_sim.gd's.
		var suffix := "_fplus" if RenderingServer.get_current_rendering_method() == "forward_plus" else ""
		var out := Paths.artifacts("vr").path_join(name + suffix + ".png")
		img.save_png(out)
		print("[capture] OK -> ", out)


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


func _run() -> void:
	# --- session ---------------------------------------------------------------
	var waited := 0.0
	while VR.session_state != "focused" and waited < 20.0:
		await get_tree().process_frame
		waited += get_process_delta_time()
	_check("session_focused", VR.active and VR.focused, {"state": VR.session_state, "after_s": snappedf(waited, 0.1)})
	if not VR.active:
		_finish()
		return
	# --- the first-launch card ----------------------------------------------------
	await _wait(1.0)
	var card := cal.prompt
	_check("first_launch_card", cal.flow == VRCalibration.Flow.CAPTURE and cal.flow_reason == &"first_launch"
		and card != null and card.visible and card.text.text == VRCalibration.PROMPT and not cal.calibrator.calibrated,
		{"flow": VRCalibration.Flow.keys()[cal.flow], "reason": String(cal.flow_reason), "text": card.text.text if card else "",
		"hint": card.hint.text if card else "", "calibrated": cal.calibrator.calibrated, "events": _events.duplicate()})
	await _shot("sim_calibration_card")
	# --- the resting controllers ------------------------------------------------
	await _wait(3.0)
	var rest := _status()
	_check("rest_not_captured", not cal.calibrator.calibrated and cal.flow == VRCalibration.Flow.CAPTURE and rest["blocker"] != "",
		{"blocker": rest["blocker"], "hint": card.hint.text if card else "", "gap": rest["gap"], "left": rest["left"], "right": rest["right"]})
	# --- the driver spreads the real simulated controllers -----------------------
	_write_state("input")
	var t := 0.0
	var holding_shot := false
	while not cal.calibrator.calibrated and t < 90.0:
		await get_tree().process_frame
		t += get_process_delta_time()
		var p := float(cal.calibrator.capture_status()["progress"])
		if not holding_shot and p >= 0.45 and p < 0.9:
			holding_shot = true
			await _shot("sim_calibration_holding")
		if _driver().has("error"):
			break
	var captured_at := _now()
	var captured_unix := Time.get_unix_time_from_system()
	var st := _status()
	await _wait(0.4)
	await _shot("sim_calibration_done")
	# The driver reads from the simulator's pose stream when the controllers
	# last moved: the capture came a full hold after that, never while they
	# moved (the stream's ~10 Hz allows 0.1 s), then it lowers the right
	# controller (the arms relax).
	_write_state("relax")
	t = 0.0
	while not _driver().has("relaxed") and not _driver().has("error") and t < 20.0:
		await _wait(0.2)
		t += 0.2
	var drv := _driver()
	var still_for := captured_unix - float(drv.get("last_motion_unix", captured_unix))
	var c := cal.calibrator
	var span_ok := c.calibrated and c.arm_span > 1.2 and c.arm_span < 2.2
	_check("driven_capture", span_ok and cal.flow != VRCalibration.Flow.CAPTURE and st["flow"] == "DONE" and st["axis_deg"][0] <= 45.0 and st["axis_deg"][1] <= 45.0
		and still_for >= WingCalibrator.NEUTRAL_HOLD - 0.1,
		{"calibrated": c.calibrated, "arm_span": snappedf(c.arm_span, 0.001), "shoulder_drop": snappedf(c.shoulder_drop, 0.001),
		"captured_at_s": snappedf(captured_at, 0.01), "still_before_capture_s": snappedf(still_for, 0.01),
		"driver_actions": drv.get("actions", []), "driver_error": drv.get("error", ""),
		"status_at_capture": st, "flow_text": cal.prompt_text()})
	result["metrics"]["capture"] = {"span": c.arm_span, "drop": c.shoulder_drop, "width": c.shoulder_width, "seated": c.is_seated()}
	var d0 := c.to_dict()
	await _wait(0.5)
	# --- a new step cancelled with the controller's B/Y button -------------------
	cal.start_manual()
	_write_state("cancel")
	t = 0.0
	while cal.flow == VRCalibration.Flow.CAPTURE and t < 20.0:
		await get_tree().process_frame
		t += get_process_delta_time()
	var cancel_ok := cal.flow == VRCalibration.Flow.FAILED and cal.last_reason == "cancelled"
	await _shot("sim_calibration_cancelled")
	_check("button_cancel", cancel_ok and c.to_dict() == d0 and t > 0.3, {"flow": VRCalibration.Flow.keys()[cal.flow], "reason": cal.last_reason,
		"after_s": snappedf(t, 0.01), "unchanged": c.to_dict() == d0, "text": cal.prompt_text(), "blocker_while_waiting": _status()["blocker"]})
	await _wait(VRCalibration.CANCEL_SHOW + 0.3)
	# --- headset off and on ---------------------------------------------------------
	var suggested0 := VR.recalibration_suggested
	var n_events := _events.size()
	_write_state("presence")
	t = 0.0
	var saw_off := false
	var saw_on := false
	while t < 20.0 and not (saw_off and saw_on and VR.focused):
		await get_tree().process_frame
		t += get_process_delta_time()
		for e in _events.slice(n_events):
			saw_off = saw_off or e[1] == "presence_false"
			saw_on = saw_on or e[1] == "presence_true"
		if bool(_driver().get("presence_done", false)) and t > 6.0:
			break
	t = 0.0
	while not bool(_driver().get("presence_done", false)) and t < 8.0:
		await _wait(0.2)
		t += 0.2
	var drv2 := _driver()
	var driven := saw_off and saw_on
	var pres := {"driven": driven, "rpc": drv2.get("presence", {}), "suggested_before": suggested0,
		"suggested_after": VR.recalibration_suggested, "unchanged": c.to_dict() == d0,
		"flow": VRCalibration.Flow.keys()[cal.flow], "events": _events.slice(n_events)}
	if driven:
		_check("presence_flag", not suggested0 and VR.recalibration_suggested and c.to_dict() == d0 and cal.flow == VRCalibration.Flow.IDLE, pres)
	else:
		result["metrics"]["presence_not_driven"] = pres
		print("[vr] SIM presence not driven (no presence events from the runtime): %s" % JSON.stringify(pres))
	_write_state("done")
	# Let the driver restore the simulator's selection and controller poses.
	t = 0.0
	while not bool(_driver().get("done", false)) and t < 20.0:
		await _wait(0.25)
		t += 0.25
	result["timeline"] = _events
	_finish()


func _finish() -> void:
	var ok := true
	for k in result["checks"]:
		ok = ok and bool(result["checks"][k]["ok"])
	result["pass"] = ok
	var suffix := "_fplus" if RenderingServer.get_current_rendering_method() == "forward_plus" else ""
	var f := FileAccess.open(Paths.artifacts("vr").path_join("sim_calibration_result%s.json" % suffix), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(result, "  "))
		f.close()
	_write_state("done")
	print("[vr] SIM CALIBRATION RESULT %s (%d checks)" % ["PASS" if ok else "FAIL", result["checks"].size()])
	get_tree().quit(0 if ok else 1)
