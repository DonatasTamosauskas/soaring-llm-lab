extends Node3D
## Meta XR Simulator harness for the VR area. Runs under tools/xr.sh (use
## tests/sim/run_vr_sim.sh, which also starts the controller driver) and
## verifies itself, writing artifacts/vr/sim_result.json and a
## "[vr] SIM RESULT PASS|FAIL" line:
##
##   session   the OpenXR session reaches FOCUSED
##   refresh   physics ticks == display refresh (policy rate applied)
##   fps       frames over a 20 s window in a representative scene (the
##             real world, the player rig with wings + vignette + world
##             scale, flying a circle) >= 0.95 x refresh
##   tracked   both grip controllers and the head have tracking data
##   input     real simulated controllers driven over SimRpc by
##             tests/sim/sim_driver.py: a two-hand flap (both hands stroke
##             >= 0.25 m relative to a still head, >= 0.6 m/s) and a left
##             wrist roll (>= 15° of twist through the calibration maths,
##             the right hand unmoved), seen by the game
##   foveation the main viewport's VRS mode is VRS_XR (what makes the Mobile
##             renderer use the runtime's foveation map)
##   recenter  the driver turns the simulated head left; VR.recenter() then
##             makes it face the rig's forward again, height kept
##   haptics   every pattern through the real XRInterface haptic call path
##   mirror    wings visible in mirror screenshots (pixel difference with
##             the wings hidden), for the real controllers and a scripted
##             "hybrid" pose (real head, puppet arms), at world_scale 0.15
##             and 1.3, and the vignette in a hard turn
## Script errors are checked by the wrapper on the full log.
##
## User args: --no-world (practice field instead of the world),
## --fps_window=<s> (default 20), --refresh=<hz> (VR autoload override),
## --npcs=<n> (default 60: the NPC budget as stand-ins, see _add_npcs).

const Env := preload("res://scenes/dev/vr_dev_env.gd")
const MemoryStore := preload("res://tests/unit/vr/vr_memory_store.gd")
const STATE := "sim_state.json"
const DRIVER := "sim_driver.json"

var rig: Dictionary
var extras: VRRigExtras
var puppet: VRPosePuppet
var mirror: XRMirror
var player: Node3D
var result := {"checks": {}, "metrics": {}}
var _centre := Vector3.ZERO
var _fly := false
var _fly_t := 0.0
var _turn_rate := 0.0
var _frames := 0
var _rec: Array = []
var _recording := false
var _t0 := 0
var _bare := false
var _with_world := true
var _bare_ws := -1.0
var _proc_first: _Bracket
var _proc_last: _Bracket
## NPC stand-ins: [node, centre, radius, angular speed, phase, height].
var _npcs: Array = []
var _npc_t := 0.0


## Timestamps the start and end of the scripts' _process phase each frame
## (one node runs first, one last, by process_priority), so the harness can
## split frame time into script work vs render / compositor pacing.
class _Bracket:
	extends Node
	var first := true
	var t_start := 0
	var other: _Bracket
	var total_us := 0
	var frames := 0

	func _process(_dt: float) -> void:
		if first:
			t_start = Time.get_ticks_usec()
		elif other != null:
			total_us += Time.get_ticks_usec() - other.t_start
			frames += 1


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_t0 = Time.get_ticks_msec()
	DirAccess.remove_absolute(Paths.artifacts("vr").path_join(DRIVER))
	_write_state("boot")
	var spawn := Transform3D(Basis.IDENTITY, Vector3(0, 12, 0))
	_bare = Paths.user_args().has("bare")
	_with_world = not Paths.user_args().has("no-world") and ResourceLoader.exists("res://scenes/world/world.tscn")
	if _with_world:
		var world := (load("res://scenes/world/world.tscn") as PackedScene).instantiate()
		add_child(world)
		var w := world as World
		if w != null:
			if not w.is_generated:
				await w.generated
			spawn = w.get_player_spawn()
			result["metrics"]["scene"] = "world"
	else:
		Env.build_environment(self)
		result["metrics"]["scene"] = "field"
	_centre = spawn.origin + Vector3(0, 6.0, 0)
	_add_npcs(int(Paths.arg("npcs", "60")))
	rig = Env.build_rig(self, _centre, MemoryStore.new(), false, false)
	extras = rig["extras"]
	# This harness measures the session, pacing, input and the wings: no
	# first-launch calibration card over them (its own simulator check is
	# tests/sim/vr_calibration_sim.tscn).
	extras.calibration.first_launch_prompt = false
	player = rig["player"]
	if _bare:
		# Baseline: the same rig without any VR feature running.
		extras.process_mode = Node.PROCESS_MODE_DISABLED
		extras.set_process(false)
		for n in [extras.wings, extras.vignette]:
			n.visible = false
			n.process_mode = Node.PROCESS_MODE_DISABLED
		# Same viewpoint as with the features on (sparrow scale), so the A/B
		# differs only by the VR features, not by what the camera sees.
		_bare_ws = WorldScaleDriver.target_scale(0.03, 1.5)
	puppet = VRPosePuppet.new()
	puppet.origin = rig["origin"]
	puppet.camera = rig["camera"]
	puppet.hands = [rig["left"], rig["right"]]
	puppet.drive_head = false
	puppet.gesture = &"spread"
	add_child(puppet)
	puppet.set_process(false)
	mirror = XRMirror.new()
	mirror.source = rig["camera"]
	mirror.fov = 100.0
	add_child(mirror)
	_proc_first = _Bracket.new()
	_proc_first.process_priority = -100000
	_proc_first.process_mode = Node.PROCESS_MODE_ALWAYS
	_proc_last = _Bracket.new()
	_proc_last.first = false
	_proc_last.other = _proc_first
	_proc_last.process_priority = 100000
	_proc_last.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(_proc_first)
	add_child(_proc_last)
	_run.call_deferred()


func _process(_dt: float) -> void:
	_frames += 1
	if _recording:
		_record()


## The game's NPC budget (ARCHITECTURE: <= 60 active NPC birds), as
## stand-ins of this harness's own (the AI and birds areas are in progress;
## the harness depends only on core contracts): each a separate ~1k-triangle
## flat-shaded body with its own material and shadow, circling at 8-150 m
## around the flight line and moved every physics tick, so the frame carries
## the budget's extra draw calls, shadow casters, triangles and transform
## updates. 0 = the lighter round-1 scene (world and VR only).
func _add_npcs(n: int) -> void:
	if n <= 0:
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = 60
	var mesh := SphereMesh.new()
	mesh.radial_segments = 24
	mesh.rings = 20
	mesh.radius = 0.5
	mesh.height = 1.0
	for i in n:
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color.from_hsv(rng.randf_range(0.02, 0.12), rng.randf_range(0.3, 0.7), rng.randf_range(0.25, 0.7))
		mat.roughness = 1.0
		mi.material_override = mat
		# A bird-sized ellipsoid, sparrow to eagle (NPCs are not the rig: a
		# node scale is fine here).
		var size := rng.randf_range(0.12, 1.0)
		mi.scale = Vector3(size * 0.45, size * 0.35, size)
		add_child(mi)
		_npcs.append([mi, _centre + Vector3(rng.randf_range(-60, 60), rng.randf_range(-4, 20), rng.randf_range(-60, 60)),
			rng.randf_range(8.0, 90.0), rng.randf_range(0.1, 0.5) * (1.0 if rng.randf() < 0.5 else -1.0), rng.randf() * TAU, rng.randf_range(0.5, 3.0)])
	result["metrics"]["npc_stand_ins"] = n


func _move_npcs(dt: float) -> void:
	_npc_t += dt
	for e in _npcs:
		var a: float = float(e[4]) + float(e[3]) * _npc_t
		var r: float = e[2]
		var mi: Node3D = e[0]
		mi.position = (e[1] as Vector3) + Vector3(cos(a) * r, sin(_npc_t * 1.7 + float(e[4])) * float(e[5]), sin(a) * r)
		mi.rotation.y = -a if float(e[3]) > 0.0 else PI - a


## The flight stand-in moves the body in physics ticks, like PlayerBird.
func _physics_process(dt: float) -> void:
	_move_npcs(dt)
	if _bare_ws > 0.0:
		(rig["origin"] as XROrigin3D).world_scale = _bare_ws
		(rig["camera"] as Camera3D).near = WorldScaleDriver.near_for(_bare_ws)
	if _fly:
		# The flight stand-in: a level circle at cruise (translation + yaw).
		_fly_t += dt
		var w := 9.0 / 30.0
		var a := _fly_t * w
		player.position = _centre + Vector3(cos(a) * 30.0 - 30.0, 0.0, -sin(a) * 30.0)
		player.rotation.y = a
	elif _turn_rate != 0.0:
		player.rotate_y(_turn_rate * dt)


## One sample of what the game sees: the rig's XR nodes in tracking space
## (origin-local, divided by world_scale), and the calibration's readings.
func _record() -> void:
	var o := rig["origin"] as XROrigin3D
	var ws := maxf(o.world_scale, 1e-4)
	var s := {"t": (Time.get_ticks_msec() - _t0) / 1000.0}
	for pair in [["head", rig["camera"]], ["left", rig["left"]], ["right", rig["right"]]]:
		var n := pair[1] as Node3D
		# XRCamera3D is not an XRNode3D: the head's validity comes from its tracker.
		var ok := (n as XRNode3D).get_has_tracking_data() if n is XRNode3D else _head_tracked()
		s[pair[0]] = Transform3D(n.transform.basis, n.transform.origin / ws) if ok else null
	var cal := extras.calibration.calibrator
	s["twist"] = [cal.twist[0], cal.twist[1]]
	_rec.append(s)


func _head_tracked() -> bool:
	var tr := XRServer.get_tracker(&"head") as XRPositionalTracker
	var pose := tr.get_pose(&"default") if tr else null
	return pose != null and pose.has_tracking_data


## Frame-time percentiles (ms) of a window's intervals, the frame budget,
## and how many frames ran longer than 1.5 intervals (a visible hitch at
## the display rate). Reported, not gated: on this shared Mac the tail is
## the machine's load (1-3% of frames at load 10-11 in round 5); on the
## device OVR Metrics judges it.
static func frame_pacing(intervals: PackedFloat32Array, refresh: float) -> Dictionary:
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
		"p99": pct.call(0.99), "max": snappedf(v[n - 1], 0.01) if n > 0 else 0.0,
		"over_1_5_intervals": over, "over_pct": snappedf(100.0 * over / maxf(n, 1), 0.01)}


func _check(name: String, ok: bool, detail: Variant) -> void:
	result["checks"][name] = {"ok": ok, "detail": detail}
	print("[vr] SIM %s %s: %s" % ["PASS" if ok else "FAIL", name, str(detail)])


func _write_state(phase: String) -> void:
	var f := FileAccess.open(Paths.artifacts("vr").path_join(STATE), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify({"phase": phase, "pid": OS.get_process_id(), "t": Time.get_unix_time_from_system()}))


func _run() -> void:
	# --- session ---------------------------------------------------------------
	var waited := 0.0
	while VR.session_state != "focused" and waited < 20.0:
		await get_tree().process_frame
		waited += get_process_delta_time()
	_check("session_focused", VR.active and VR.session_state == "focused", {"state": VR.session_state, "after_s": snappedf(waited, 0.1), "active": VR.active})
	if not VR.active:
		_finish()
		return
	await get_tree().create_timer(2.0).timeout
	var refresh := VR.xr.display_refresh_rate
	_check("physics_tick_equals_refresh", Engine.physics_ticks_per_second == roundi(refresh),
		{"physics_ticks": Engine.physics_ticks_per_second, "refresh": refresh, "policy": VR.refresh_rate})
	# Fix round 5 (engineering verifier): at 72 Hz the project's own tick
	# already equals the display, so the check above cannot see whether the
	# refresh policy ran at session start at all. It did if it counted a run
	# and the runtime now shows the rate it chose from the runtime's list.
	var chose := VRManager.choose_refresh_rate(VR.xr.get_available_display_refresh_rates(), VR.requested_refresh())
	_check("refresh_policy_applied", VR.refresh_policy_runs >= 1 and absf(VR.refresh_rate - chose) < 0.5 and absf(refresh - chose) < 0.5,
		{"runs": VR.refresh_policy_runs, "chosen": chose, "vr_refresh_rate": VR.refresh_rate, "runtime": refresh,
		"offered": VR.xr.get_available_display_refresh_rates()})
	var tracked := {}
	for name in [&"head", &"left_hand", &"right_hand"]:
		var tr := XRServer.get_tracker(name) as XRPositionalTracker
		var pose := tr.get_pose(&"default" if name == &"head" else &"grip") if tr else null
		tracked[name] = pose != null and pose.has_tracking_data
	_check("tracked_controllers", tracked.values().all(func(v: bool) -> bool: return v), tracked)
	# Foveation only reaches the Mobile renderer through the main viewport's
	# VRS mode (the simulator itself reports foveation unsupported).
	var fov_level := clampi(int(Settings.get_value("vr_foveation_level", 3)), 0, 3)
	_check("foveation_reaches_the_renderer", get_viewport().vrs_mode == VRManager.vrs_mode_for(fov_level),
		{"level": fov_level, "vrs_mode": get_viewport().vrs_mode, "runtime_supports_foveation": VR.xr.is_foveation_supported()})

	if Paths.user_args().has("shots_only"):
		# Clean evidence images (Forward+ has no MoltenVK magenta tiles).
		await _shots()
		_finish()
		return

	# --- fps over a representative flight ---------------------------------------
	var window := float(Paths.arg("fps_window", "20"))
	extras.vignette.setting_override = 0.6
	_fly = true
	# The stand-in reports it is flying (as the game's bird would).
	player.set(&"mode_label", "flying")
	await get_tree().create_timer(3.0).timeout
	_frames = 0
	var t_start := Time.get_ticks_usec()
	var ticks0 := Engine.get_physics_frames()
	# The fps only counts if the session stayed focused the whole window.
	var losses0 := VR.focus_losses
	VRProfile.enabled = true
	VRProfile.reset()
	_proc_last.total_us = 0
	_proc_last.frames = 0
	var draws := 0
	var prims := 0
	var worst_draws := 0
	var samples := 0
	var cpu_ms := 0.0
	var phys_ms := 0.0
	var gpu_ms := 0.0
	var slow := 0
	# Every frame interval, for pacing (fix round 6, experience verifier:
	# the mean fps hides hitches; integration needs the percentiles).
	var intervals := PackedFloat32Array()
	var vp_rid := get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(vp_rid, true)
	var last_us := Time.get_ticks_usec()
	while (Time.get_ticks_usec() - t_start) / 1e6 < window:
		await get_tree().process_frame
		var vp := get_viewport()
		var d := vp.get_render_info(Viewport.RENDER_INFO_TYPE_VISIBLE, Viewport.RENDER_INFO_DRAW_CALLS_IN_FRAME) + vp.get_render_info(Viewport.RENDER_INFO_TYPE_SHADOW, Viewport.RENDER_INFO_DRAW_CALLS_IN_FRAME)
		draws += d
		worst_draws = maxi(worst_draws, d)
		prims += vp.get_render_info(Viewport.RENDER_INFO_TYPE_VISIBLE, Viewport.RENDER_INFO_PRIMITIVES_IN_FRAME)
		samples += 1
		cpu_ms += Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
		phys_ms += Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
		gpu_ms += RenderingServer.viewport_get_measured_render_time_gpu(vp_rid)
		var now_us := Time.get_ticks_usec()
		if (now_us - last_us) / 1e6 > 1.5 / refresh:
			slow += 1
		intervals.append((now_us - last_us) / 1000.0)
		last_us = now_us
	var secs := (Time.get_ticks_usec() - t_start) / 1e6
	var fps := _frames / secs
	var tps := (Engine.get_physics_frames() - ticks0) / secs
	_fly = false
	player.set(&"mode_label", "perched")
	result["metrics"]["fps"] = {"fps": snappedf(fps, 0.01), "window_s": snappedf(secs, 0.01), "refresh": refresh,
		"physics_per_s": snappedf(tps, 0.1), "mean_draw_calls": draws / maxi(samples, 1), "worst_draw_calls": worst_draws,
		"mean_primitives": prims / maxi(samples, 1), "mean_process_ms": snappedf(cpu_ms / maxi(samples, 1), 0.01),
		"mean_physics_ms": snappedf(phys_ms / maxi(samples, 1), 0.01), "mean_gpu_ms": snappedf(gpu_ms / maxi(samples, 1), 0.01),
		"frames_over_1_5_intervals": slow, "load_avg": _load_avg(), "vr_usec_per_call": VRProfile.report(),
		"script_process_ms_per_frame": snappedf(_proc_last.total_us / 1000.0 / maxi(_proc_last.frames, 1), 0.01),
		"variant": "bare" if _bare else ("no-world" if not _with_world else "world")}
	var pacing := frame_pacing(intervals, refresh)
	result["metrics"]["fps"]["frame_ms"] = pacing
	print("[vr] SIM pacing: frame ms p50 %.2f p95 %.2f p99 %.2f max %.2f (budget %.2f), %d of %d frames over 1.5 intervals (%.1f%%)" % [
		pacing["p50"], pacing["p95"], pacing["p99"], pacing["max"], pacing["budget_ms"], pacing["over_1_5_intervals"], pacing["frames"], pacing["over_pct"]])
	_check("fps_at_least_95pct_refresh", fps >= 0.95 * refresh, result["metrics"]["fps"])
	_check("focused_through_the_fps_window", VR.focus_losses == losses0 and VR.focused,
		{"focus_losses": VR.focus_losses - losses0, "focused_at_end": VR.focused})
	if Paths.user_args().has("fps_only"):
		_finish()
		return

	# --- input path: real simulated controllers --------------------------------
	player.position = _centre
	player.rotation = Vector3.ZERO
	_rec.clear()
	_recording = true
	_write_state("input")
	var drv := {}
	var t_in := 0.0
	var drv_path := Paths.artifacts("vr").path_join(DRIVER)
	while t_in < 45.0:
		await get_tree().create_timer(0.25).timeout
		t_in += 0.25
		if FileAccess.file_exists(drv_path):
			var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(drv_path))
			if parsed is Dictionary and (parsed as Dictionary).get("done", false) and int((parsed as Dictionary).get("pid", -1)) == OS.get_process_id():
				drv = parsed
				break
	_recording = false
	_analyse_input(drv)
	await _recenter_check(drv)

	# --- haptics through the real call path -------------------------------------
	var sink := VR.haptics.sink as VRHaptics.XRSink
	var before := sink.calls if sink else 0
	var per := {}
	for name in HapticPatterns.names():
		var c0 := sink.calls if sink else 0
		VR.haptics.play(name, VRHaptics.MASK_BOTH, 0.8)
		await get_tree().create_timer(0.6).timeout
		per[String(name)] = (sink.calls if sink else 0) - c0
	var sent := (sink.calls if sink else 0) - before
	_check("haptics_real_call_path", sink != null and per.values().all(func(n: int) -> bool: return n >= 2), {"pulses": sent, "per_pattern": per})

	# --- mirror screenshots -------------------------------------------------------
	await _shots()
	_finish()


func _analyse_input(drv: Dictionary) -> void:
	result["metrics"]["driver"] = {"done": drv.get("done", false), "both_selected": drv.get("both_controllers_selected", null),
		"left_selected": drv.get("left_selected", null), "restored": drv.get("restored_selection", null),
		"persistent_unchanged": drv.get("persistent_unchanged", null), "cycle_states": drv.get("cycle_states", null),
		"error": drv.get("error", "")}
	var ok_driver: bool = drv.get("done", false) and drv.get("persistent_unchanged", false)
	_check("driver_ran_and_left_simulator_settings_untouched", ok_driver, result["metrics"]["driver"])
	# Two-hand flap: hand height relative to the head, per hand.
	var rel: Array = [[], []]
	var times: Array[float] = []
	var head_y: Array[float] = []
	var bases: Array = [[], []]
	for s in _rec:
		if s["head"] == null or s["left"] == null or s["right"] == null:
			continue
		var hy: float = (s["head"] as Transform3D).origin.y
		head_y.append(hy)
		times.append(float(s["t"]))
		for i in 2:
			var tr: Transform3D = s["left" if i == 0 else "right"]
			rel[i].append(tr.origin.y - hy)
			bases[i].append(tr.basis)
	var strokes := [0, 0]
	var peak_speed := [0.0, 0.0]
	for i in 2:
		var series: Array = rel[i]
		if series.is_empty():
			continue
		var looking_for_drop := true
		var ref: float = series[0]
		for k in series.size():
			var y: float = series[k]
			if k > 0 and times[k] > times[k - 1]:
				peak_speed[i] = maxf(peak_speed[i], absf(y - float(series[k - 1])) / (times[k] - times[k - 1]))
			if looking_for_drop:
				ref = maxf(ref, y)
				if ref - y >= 0.25:
					strokes[i] += 1
					looking_for_drop = false
					ref = y
			else:
				ref = minf(ref, y)
				if y - ref >= 0.25:
					looking_for_drop = true
					ref = y
	var head_range := 0.0
	if not head_y.is_empty():
		head_range = head_y.max() - head_y.min()
	var flap := {"downstrokes": strokes, "peak_hand_speed_rel_head": [snappedf(peak_speed[0], 0.01), snappedf(peak_speed[1], 0.01)],
		"head_y_range": snappedf(head_range, 0.001), "samples": times.size()}
	_check("two_hand_flap_seen", strokes[0] >= 2 and strokes[1] >= 2 and peak_speed[0] >= 0.6 and peak_speed[1] >= 0.6 and head_range < 0.05, flap)
	# Wrist roll: rotation of each grip about its own forearm (aim) axis
	# since the start of the recording (swing-twist, as the calibration
	# maths reads it), plus the calibrator's own twist channel.
	var roll := [0.0, 0.0]
	for i in 2:
		if bases[i].is_empty():
			continue
		var b0: Basis = bases[i][0]
		for b in bases[i]:
			var q := (b0.transposed() * (b as Basis)).get_rotation_quaternion()
			roll[i] = maxf(roll[i], absf(rad_to_deg(VRMath.twist_about(q, WingCalibrator.DEFAULT_FOREARM).x)))
	var tw := [[INF, -INF], [INF, -INF]]
	for s in _rec:
		for i in 2:
			var v := rad_to_deg(float(s["twist"][i]))
			tw[i][0] = minf(tw[i][0], v)
			tw[i][1] = maxf(tw[i][1], v)
	var cal_l := float(tw[0][1]) - float(tw[0][0])
	_check("left_wrist_roll_seen", roll[0] >= 15.0 and roll[1] < 3.0 and cal_l >= 15.0, {"left_roll_deg": snappedf(roll[0], 0.1),
		"right_roll_deg": snappedf(roll[1], 0.1), "calibration_twist_range_left_deg": snappedf(cal_l, 0.1)})


## The driver turned the simulated head left (ROTATE_H_POS) and left it
## there; VR.recenter() (Events.recenter_requested, the A/X long press)
## must re-centre the tracking space so the head faces the rig's forward
## again (XRServer.center_on_hmd, yaw only, height kept).
func _recenter_check(drv: Dictionary) -> void:
	await get_tree().create_timer(0.3).timeout
	var cam: Node3D = extras.camera
	var yaw_of := func() -> float: return rad_to_deg(VRMath.yaw_of(VRMath.head_forward(cam.transform.basis)))
	var h0: float = yaw_of.call()
	var y0 := cam.transform.origin.y
	var n0 := VR.recenter_count
	VR.recenter()
	for i in 3:
		await get_tree().process_frame
	var h1: float = yaw_of.call()
	var turned := bool(drv.get("head_selected", false))
	result["metrics"]["recenter"] = {"head_yaw_before_deg": snappedf(h0, 0.1), "head_yaw_after_deg": snappedf(h1, 0.1),
		"height_before": snappedf(y0, 0.001), "height_after": snappedf(cam.transform.origin.y, 0.001), "driver_turned_head": turned}
	_check("recenter_faces_forward", turned and absf(h0) >= 10.0 and absf(h1) <= 3.0 and VR.recenter_count == n0 + 1
		and absf(cam.transform.origin.y - y0) < 0.02, result["metrics"]["recenter"])


## Mirror screenshots with a wings-visible check: the same view with and
## without the wings must differ in >= 0.3% of the pixels.
func _shots() -> void:
	# [name, scripted arms, gesture, gesture time, extra sweep deg, torso turn deg]
	var views := [
		["sim_wings_real_controllers", false, &"", 0.0, 0.0, 0.0],
		["sim_wings_hybrid_forward", true, &"wings_forward", 0.0, 0.0, 0.0],
		["sim_wings_hybrid_flap", true, &"flap", 0.2, 55.0, 0.0],
		["sim_wings_hybrid_ws015", true, &"wings_forward", 0.0, 0.0, 0.0],
		["sim_wings_hybrid_ws130", true, &"wings_forward", 0.0, 0.0, 0.0],
		# Looking over the right shoulder at the spread wing (the body turns
		# 60° under the simulator's fixed head), and at a downstroke.
		["sim_wings_hybrid_look_spread", true, &"spread_high", 0.0, 0.0, 66.0],
		["sim_wings_hybrid_look_flap", true, &"flap", 0.0, 0.0, 62.0],
	]
	var visible := {}
	for v in views:
		var name: String = v[0]
		var scripted: bool = v[1]
		puppet.set_process(scripted)
		if scripted:
			puppet.gesture = v[2]
			puppet.speed = 0.0
			puppet.t = v[3]
			puppet.extra_sweep = deg_to_rad(v[4])
			puppet.torso_yaw_offset = deg_to_rad(v[5])
		extras.world_scale_driver.enabled = true
		if name.ends_with("ws015") or name.ends_with("ws130"):
			extras.world_scale_driver.enabled = false
			(rig["origin"] as XROrigin3D).world_scale = 0.15 if name.ends_with("ws015") else 1.3
			(rig["camera"] as Camera3D).near = WorldScaleDriver.near_for((rig["origin"] as XROrigin3D).world_scale)
		await get_tree().create_timer(0.4).timeout
		if scripted:
			var ws0 := (rig["origin"] as XROrigin3D).world_scale
			print("[vr] hybrid diag %s: puppet wants R %s, node R %s (at harness process), calibrator R %s, ext %.2f/%.2f" % [name,
				(puppet.human.hand_transform(1).origin * ws0).snapped(Vector3.ONE * 0.001), (rig["right"] as Node3D).position.snapped(Vector3.ONE * 0.001),
				(extras.calibration.calibrator.hands[1].origin * ws0).snapped(Vector3.ONE * 0.001),
				extras.calibration.calibrator.extension[0], extras.calibration.calibrator.extension[1]])
		var with_img := await mirror.capture_image()
		extras.wings.visible = false
		var without := await mirror.capture_image()
		extras.wings.visible = true
		var frac := _diff_fraction(with_img, without)
		var out := Paths.artifacts("vr").path_join(name + _shot_suffix() + ".png")
		with_img.save_png(out)
		print("[capture] OK -> ", out)
		visible[name] = snappedf(frac, 0.0001)
	extras.world_scale_driver.enabled = true
	puppet.torso_yaw_offset = 0.0
	puppet.extra_sweep = 0.0
	_check("wings_visible_in_mirror", visible.values().all(func(f: float) -> bool: return f >= 0.003), visible)
	# Vignette in a hard turn, seen through the mirror (drawn per eye in view space).
	puppet.gesture = &"glide"
	extras.vignette.setting_override = 1.0
	var calm := await mirror.capture_image()
	_turn_rate = deg_to_rad(200.0)
	await get_tree().create_timer(1.0).timeout
	var turning := await mirror.capture_image()
	var strength := extras.vignette.strength()
	_turn_rate = 0.0
	turning.save_png(Paths.artifacts("vr").path_join("sim_vignette_turn%s.png" % _shot_suffix()))
	calm.save_png(Paths.artifacts("vr").path_join("sim_vignette_rest%s.png" % _shot_suffix()))
	var edge_turn := _edge_luma(turning)
	var edge_calm := _edge_luma(calm)
	_check("vignette_in_hard_turn", strength > 0.8 and edge_turn < 0.5 * edge_calm, {"strength": snappedf(strength, 0.001),
		"edge_luma_turn": snappedf(edge_turn, 0.001), "edge_luma_rest": snappedf(edge_calm, 0.001)})
	extras.vignette.setting_override = -1.0


## Mean luminance of the image's periphery (outside 80% of the half-diagonal).
static func _edge_luma(img: Image) -> float:
	if img == null:
		return 0.0
	var c := Vector2(img.get_width(), img.get_height()) * 0.5
	var r := c.length()
	var sum := 0.0
	var n := 0
	for y in range(0, img.get_height(), 6):
		for x in range(0, img.get_width(), 6):
			if (Vector2(x, y) - c).length() / r > 0.8:
				sum += img.get_pixel(x, y).get_luminance()
				n += 1
	return sum / maxf(n, 1)


## The machine's 1-minute load average (the simulator shares it with other
## agents' Godot runs): context for the fps number.
static func _load_avg() -> String:
	var out := []
	OS.execute("sysctl", ["-n", "vm.loadavg"], out)
	return String(out[0]).strip_edges() if not out.is_empty() else ""


static func _diff_fraction(a: Image, b: Image) -> float:
	if a == null or b == null or a.get_size() != b.get_size():
		return 0.0
	var n := 0
	var diff := 0
	var step := 4
	for y in range(0, a.get_height(), step):
		for x in range(0, a.get_width(), step):
			n += 1
			var ca := a.get_pixel(x, y)
			var cb := b.get_pixel(x, y)
			# The Mobile renderer under MoltenVK paints random magenta tiles
			# (never on Quest): they are not wings.
			if _magenta(ca) or _magenta(cb):
				continue
			if absf(ca.r - cb.r) + absf(ca.g - cb.g) + absf(ca.b - cb.b) > 0.06:
				diff += 1
	return float(diff) / maxf(n, 1)


## Shots from a Forward+ run get "_fplus" (the Mobile renderer's shots on
## this Mac carry MoltenVK magenta tiles; Quest does not).
func _shot_suffix() -> String:
	return "_fplus" if RenderingServer.get_current_rendering_method() == "forward_plus" else ""


static func _magenta(c: Color) -> bool:
	return c.r > 0.85 and c.b > 0.85 and c.g < 0.2


func _finish() -> void:
	var ok := true
	for k in result["checks"]:
		ok = ok and bool(result["checks"][k]["ok"])
	result["pass"] = ok
	result["refresh_override"] = Paths.arg("refresh", "")
	var path := Paths.artifacts("vr").path_join("sim_result%s.json" % ("_" + Paths.arg("tag", "") if Paths.arg("tag", "") != "" else ""))
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(result, "  "))
		f.close()
	_write_state("done")
	print("[vr] SIM RESULT %s (%d checks) -> %s" % ["PASS" if ok else "FAIL", result["checks"].size(), path])
	get_tree().quit(0 if ok else 1)
