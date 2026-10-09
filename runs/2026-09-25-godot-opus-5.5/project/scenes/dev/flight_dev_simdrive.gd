extends Node
## SIM-05 (F14): the Meta XR Simulator's own controllers, moved through its
## SimRpc keybindings by tests/shots/flight_sim_driver.py, fly the bird
## through XRPoseSource -> WingInput -> FlightModel. The lab runs with
## --pose=xr --simdrive; tests/shots/flight_sim_run.sh starts both.
##
## Coordination through two small JSON files in artifacts/flight/:
##   sim_state.json   lab -> driver   {"phase": "input" | "done", "pid"}
##   sim_driver.json  driver -> lab   {"steps": [[t, name], ...], "done"}
## The driver's steps: spread_left, spread_right, spread_done (the lab then
## captures the neutral calibration from the spread arms, exactly as the
## game's calibration prompt does), tilt_left / tilt_back (one wrist twisted
## about the arm: the simulator's DownArrow on a controller that points out
## along the arm), raise_left / lower_left (one arm raised: dihedral), and
## strokes_begin / strokes_end (interleaved one-wing strokes, MOVE_UP then
## MOVE_DOWN at the simulator's 1 m/s), and look_left_wing / look_back (the
## headset alone yawed ~60 deg toward the left wing about the neck, and back: the head view
## shows the wing, and looking never steers; fix round 3, the verifier found
## no XR capture with the rig's wings in view).
##
## Each step's window is measured against the moment before it and
## reported as "[flight] SIM-05 PASS|FAIL <check>: ..." plus
## artifacts/flight/sim05_result.json. Head-view captures go to
## artifacts/flight/xr_simdrive_<step>.png (the lab mirror).

var player: PlayerBird
var mirror: Node
var _t := 0.0
var _flying_since := -1.0
var _state_written := false
var _poll := 0.0
var _steps := {}              ## name -> lab time
var _rec: Array = []          ## per tick: [t, roll_in, pitch_in, bank_deg, ext_l, ext_r, flap_n, onset_l, onset_r, calibrated, vz, twist_l_deg, dih_l_deg]
var _flaps := 0
var _done := false
var _shots := {"spread_done": 2.4, "tilt_left": 1.6, "raise_left": 1.6, "strokes_begin": 2.0, "look_left_wing": 0.8}
## During the head look: [t, rig_yaw_deg, head_yaw_deg (tracking), wing_in_view, roll_in]
var _look: Array = []
var _pending_shots: Array = []
var _driver_done_t := -1.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	DirAccess.make_dir_recursive_absolute(Paths.artifacts("flight"))
	for f in ["sim_state.json", "sim_driver.json", "sim05_result.json"]:
		var p := Paths.artifacts("flight").path_join(f)
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)
	if has_node(^"/root/Events"):
		Events.player_flapped.connect(func(_s: int, _st: float) -> void: _flaps += 1)
	print("[flight] SIM-05 simdrive: waiting for the XR session and the driver")


func _physics_process(delta: float) -> void:
	if player == null or _done:
		return
	_t += delta
	var vr_active: bool = has_node(^"/root/VR") and bool(get_node(^"/root/VR").get("active"))
	if not vr_active:
		return
	if _flying_since < 0.0 and player.mode == PlayerBird.Mode.FLYING:
		_flying_since = _t
	if not _state_written and _flying_since >= 0.0 and _t - _flying_since > 2.0:
		_write_state("input")
		_state_written = true
	for e in player.wing_input.calib_events:
		print("[flight] SIM-05 calibration event: %s" % e)
	var ws := player.wing_state()
	var tel := player.telemetry()
	_rec.append([_t, float(tel["roll_input"]), float(tel["pitch_input"]), rad_to_deg(player.model.phi),
		ws.ext_l, ws.ext_r, player.model.flap_n, 1 if ws.onset_l else 0, 1 if ws.onset_r else 0,
		1 if ws.calibrated else 0, player.model.velocity.y, rad_to_deg(ws.twist_l), rad_to_deg(ws.dihedral_l), rad_to_deg(ws.dihedral_r)])
	if _steps.has("diag_begin") and not _steps.has("diag_end") and Engine.get_physics_frames() % 7 == 0:
		var wi := player.wing_input
		print("[flight] SIM-05 diag t=%.2f twist_l %.1f raw %.1f conf %.2f dihedral_l %.1f sweep_l %.1f elev_l %.1f roll %.2f pitch %.2f" % [_t,
			rad_to_deg(ws.twist_l), rad_to_deg(wi.twist_raw[0]), wi.twist_conf[0], rad_to_deg(ws.dihedral_l), rad_to_deg(wi.sweep_raw[0]),
			rad_to_deg(wi.elevation[0]), float(tel["roll_input"]), float(tel["pitch_input"])])
	if _steps.has("strokes_end") and not _steps.has("look_back"):
		var cam := player.camera
		var anchor: Node3D = player.wing_anchors[0]
		var local := cam.global_transform.affine_inverse() * anchor.global_position
		# In view: in front of the eye and inside a 90 x 90 deg frustum.
		var in_view := local.z < 0.0 and absf(local.x) < -local.z and absf(local.y) < -local.z
		_look.append([_t, rad_to_deg(player.rig_yaw), rad_to_deg(cam.transform.basis.get_euler().y),
			1 if in_view else 0, float(tel["roll_input"])])
	_poll -= delta
	if _poll <= 0.0 and _state_written:
		_poll = 0.2
		_read_driver()
	while not _pending_shots.is_empty() and _t >= float(_pending_shots[0][0]):
		var s: Array = _pending_shots.pop_front()
		if mirror != null:
			mirror.call("capture", Paths.artifacts("flight").path_join("xr_simdrive_%s.png" % s[1]))
	if _driver_done_t > 0.0 and _t > _driver_done_t + 1.0:
		_finish()


func _read_driver() -> void:
	var p := Paths.artifacts("flight").path_join("sim_driver.json")
	if not FileAccess.file_exists(p):
		return
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(p))
	if not (d is Dictionary):
		return
	for st in (d as Dictionary).get("steps", []):
		var name := String(st[1])
		if _steps.has(name):
			continue
		_steps[name] = _t
		print("[flight] SIM-05 step %s at %.2f s (lab)" % [name, _t])
		if name == "spread_done":
			# The game's calibration prompt: hold the spread pose, capture it.
			player.begin_calibration(&"neutral")
		if _shots.has(name):
			_pending_shots.append([_t + float(_shots[name]), name])
			_pending_shots.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	if bool((d as Dictionary).get("done", false)) and _driver_done_t < 0.0:
		_driver_done_t = _t


## Mean of column c over lab time [a, b).
func _mean(c: int, a: float, b: float) -> float:
	var s := 0.0
	var n := 0
	for r in _rec:
		if r[0] >= a and r[0] < b:
			s += float(r[c])
			n += 1
	return s / maxf(n, 1)


func _extreme(c: int, a: float, b: float, ref: float) -> float:
	var best := ref
	for r in _rec:
		if r[0] >= a and r[0] < b and absf(float(r[c]) - ref) > absf(best - ref):
			best = float(r[c])
	return best


func _sum(c: int, a: float, b: float) -> float:
	var s := 0.0
	for r in _rec:
		if r[0] >= a and r[0] < b:
			s += float(r[c])
	return s


func _finish() -> void:
	_done = true
	var checks := {}
	var ok_all := true
	var need := ["spread_done", "tilt_start", "tilt_left", "tilt_back", "raise_start", "raise_left", "lower_left", "strokes_begin", "strokes_end"]
	for n in need:
		if not _steps.has(n):
			checks["driver_step_%s" % n] = {"ok": false, "detail": "step not seen"}
	if checks.is_empty():
		var t_sp: float = _steps["spread_done"]
		var ext_l := _mean(4, t_sp + 0.3, t_sp + 1.0)
		var ext_r := _mean(5, t_sp + 0.3, t_sp + 1.0)
		checks["arms_spread_read"] = {"ok": ext_l >= 0.9 and ext_r >= 0.9, "detail": {"ext_l": ext_l, "ext_r": ext_r}}
		var cal := _mean(9, t_sp + 2.2, t_sp + 2.4)
		var p_after := _mean(2, t_sp + 2.2, _steps["tilt_start"])
		checks["neutral_calibrated"] = {"ok": cal > 0.5 and absf(p_after) < 0.2, "detail": {"calibrated": cal, "pitch_input_after": p_after}}
		# One wrist twisted: roll input and a bank the same way. Baseline:
		# the 0.6 s before the driver announced the press.
		var ts: float = _steps["tilt_start"]
		var t0: float = _steps["tilt_left"]
		var t1: float = _steps["tilt_back"]
		var r_base := _mean(1, ts - 0.6, ts)
		var r_tilt := _mean(1, t0 + 0.3, t1)
		var b_base := _mean(3, ts - 0.6, ts)
		var b_tilt := _extreme(3, t0, t1 + 0.3, b_base)
		var dr := r_tilt - r_base
		var db := b_tilt - b_base
		checks["wrist_tilt_rolls_the_bird"] = {"ok": absf(dr) >= 0.15 and absf(db) >= 5.0 and signf(dr) == signf(db),
			"detail": {"roll_input_before": r_base, "roll_input_tilted": r_tilt, "bank_before_deg": b_base, "bank_peak_deg": b_tilt,
				"twist_l_deg": _mean(11, t0 + 0.3, t1), "twist_l_before_deg": _mean(11, ts - 0.6, ts)}}
		# One arm raised: arm dihedral rolls too.
		var t2s: float = _steps["raise_start"]
		var t2: float = _steps["raise_left"]
		var t3: float = _steps["lower_left"]
		var r2b := _mean(1, t2s - 0.6, t2s)
		var r2 := _mean(1, t2 + 0.3, t3)
		var b2b := _mean(3, t2s - 0.6, t2s)
		var b2 := _extreme(3, t2, t3 + 0.3, b2b)
		checks["arm_dihedral_rolls_the_bird"] = {"ok": absf(r2 - r2b) >= 0.15 and absf(b2 - b2b) >= 5.0 and signf(r2 - r2b) == signf(b2 - b2b),
			"detail": {"roll_input_before": r2b, "roll_input_raised": r2, "bank_before_deg": b2b, "bank_peak_deg": b2,
				"dihedral_l_deg": _mean(12, t2 + 0.6, t3)}}
		# Strokes: credited onsets on both wings and real flap force.
		var t4: float = _steps["strokes_begin"]
		var t5: float = _steps["strokes_end"] + 0.5
		var on_l := _sum(7, t4, t5)
		var on_r := _sum(8, t4, t5)
		var f_max := _extreme(6, t4, t5, 0.0)
		checks["simulated_strokes_flap"] = {"ok": on_l >= 3 and on_r >= 3 and f_max > 0.0,
			"detail": {"onsets_left": on_l, "onsets_right": on_r, "peak_flap_force_n": f_max, "player_flapped_events": _flaps}}
	# The head look (an optional sixth check: an older driver has no such step).
	if _steps.has("look_left_wing") and _steps.has("look_back_start") and not _look.is_empty():
		var t_l: float = _steps["look_left_wing"]
		var t_b: float = _steps["look_back_start"]
		var head_turn := 0.0
		var rig_turn := 0.0
		var in_view := 0
		var n := 0
		var roll_dev := 0.0
		# References: the head and the roll input just before the look (the
		# driver levels the arms after the strokes, waits 1.8 s for the bank to
		# settle, then turns the headset; an older driver has no arms_level
		# step and waited 1 s); the rig at the start of the held look.
		var t_ref: float = float(_steps["arms_level"]) + 1.6 if _steps.has("arms_level") else float(_steps["strokes_end"]) + 0.9
		var r0: Array = _look[0]
		var r_a: Array = []
		for row: Array in _look:
			if float(row[0]) <= t_ref:
				r0 = row
				if r_a.is_empty() and float(row[0]) >= t_ref - 0.7:
					r_a = row
		# "Never steers" is judged against the turn the bird was already
		# flying: key-timed strokes can leave the arms a little uneven, and
		# that gentle turn goes on through the look (fix round 4 run: 5.9 deg
		# over the hold at roll input 0.09, unchanged by the look). The rate
		# over the 0.7 s before the headset turns is the counterfactual.
		var flown_rate := 0.0
		if not r_a.is_empty() and float(r0[0]) > float(r_a[0]) + 0.3:
			flown_rate = wrapf(float(r0[1]) - float(r_a[1]), -180.0, 180.0) / (float(r0[0]) - float(r_a[0]))
		var rig0 := NAN
		var t_0 := 0.0
		var rig_rel := 0.0
		for row: Array in _look:
			if float(row[0]) < t_l + 0.3 or float(row[0]) > t_b:
				continue
			if is_nan(rig0):
				rig0 = float(row[1])
				t_0 = float(row[0])
			n += 1
			var d_rig := wrapf(float(row[1]) - rig0, -180.0, 180.0)
			head_turn = maxf(head_turn, absf(wrapf(float(row[2]) - float(r0[2]), -180.0, 180.0)))
			rig_turn = maxf(rig_turn, absf(d_rig))
			rig_rel = maxf(rig_rel, absf(d_rig - flown_rate * (float(row[0]) - t_0)))
			in_view += int(row[3])
			roll_dev = maxf(roll_dev, absf(float(row[4]) - float(r0[4])))
		var share := float(in_view) / maxf(n, 1)
		var t_arms := t_ref - 0.7
		checks["head_look_shows_the_wing_and_never_steers"] = {"ok": n > 0 and head_turn >= 45.0 and share >= 0.9 and rig_rel < 2.0 and roll_dev < 0.05,
			"detail": {"head_turn_deg": head_turn, "left_wing_in_view_share": share, "rig_turn_deg": rig_turn,
				"flown_turn_rate_before_deg_s": flown_rate, "rig_turn_beyond_flown_deg": rig_rel, "roll_input_change": roll_dev,
				"roll_input_before": float(r0[4]), "dihedral_l_r_deg_before": [_mean(12, t_arms, t_ref), _mean(13, t_arms, t_ref)], "ticks": n}}
	for k in checks:
		var ok: bool = checks[k]["ok"]
		ok_all = ok_all and ok
		print("[flight] SIM-05 %s %s: %s" % ["PASS" if ok else "FAIL", k, JSON.stringify(checks[k]["detail"])])
	var out := {"pass": ok_all, "checks": checks, "steps": _steps, "flap_events": _flaps}
	var f := FileAccess.open(Paths.artifacts("flight").path_join("sim05_result.json"), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(out, "  "))
	print("[flight] SIM-05 RESULT %s (%d checks)" % ["PASS" if ok_all else "FAIL", checks.size()])
	_write_state("done")


func _write_state(phase: String) -> void:
	var f := FileAccess.open(Paths.artifacts("flight").path_join("sim_state.json"), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify({"phase": phase, "pid": OS.get_process_id(), "t": _t}))
	print("[flight] SIM-05 state %s (pid %d)" % [phase, OS.get_process_id()])
