extends Node3D
## Verifier probe (experience lens), V1/V5/V6 in the Meta XR Simulator,
## independent of the area's harness (which writes into artifacts/vr/):
## session FOCUSED, physics tick == display refresh, fps over 20 s flying
## the stand-in rig over the real world with every VR feature on, the real
## haptic call path, and a mirror shot of the wings on the real simulated
## controllers. Writes artifacts/vr/verify/sim_probe_<tag>.json/.png.
##
##   tools/xr.sh 75 res://tests/probes/vr/exp_sim_probe.tscn -- --tag=hz72 --refresh=72

const Env := preload("res://scenes/dev/vr_dev_env.gd")
const MemoryStore := preload("res://tests/unit/vr/vr_memory_store.gd")

var rig: Dictionary
var player: Node3D
var mirror: XRMirror
var out := {}
var _fly := false
var _t := 0.0
var _frames := 0
var _centre := Vector3.ZERO


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var spawn := Transform3D(Basis.IDENTITY, Vector3(0, 12, 0))
	if ResourceLoader.exists("res://scenes/world/world.tscn"):
		var world := (load("res://scenes/world/world.tscn") as PackedScene).instantiate()
		add_child(world)
		var w := world as World
		if w != null:
			if not w.is_generated:
				await w.generated
			spawn = w.get_player_spawn()
		out["scene"] = "world"
	else:
		Env.build_environment(self)
		out["scene"] = "field"
	_centre = spawn.origin + Vector3(0, 6.0, 0)
	rig = Env.build_rig(self, _centre, MemoryStore.new(), false, false)
	player = rig["player"]
	mirror = XRMirror.new()
	mirror.source = rig["camera"]
	mirror.fov = 100.0
	add_child(mirror)
	_run.call_deferred()


func _process(_dt: float) -> void:
	_frames += 1


func _physics_process(dt: float) -> void:
	if _fly:
		_t += dt
		var a := _t * 9.0 / 30.0
		player.position = _centre + Vector3(cos(a) * 30.0 - 30.0, 0.0, -sin(a) * 30.0)
		player.rotation.y = a


func _run() -> void:
	var waited := 0.0
	while VR.session_state != "focused" and waited < 20.0:
		await get_tree().process_frame
		waited += get_process_delta_time()
	out["focused"] = VR.active and VR.session_state == "focused"
	out["focused_after_s"] = snappedf(waited, 0.01)
	if not VR.active:
		_finish()
		return
	await get_tree().create_timer(2.0).timeout
	var refresh := VR.xr.display_refresh_rate
	out["refresh"] = refresh
	out["available_rates"] = VR.xr.get_available_display_refresh_rates()
	out["physics_ticks"] = Engine.physics_ticks_per_second
	out["tick_equals_refresh"] = Engine.physics_ticks_per_second == roundi(refresh)
	# fps over 20 s of flight with wings, vignette, calibration and world scale.
	(rig["extras"] as VRRigExtras).vignette.setting_override = 0.6
	_fly = true
	await get_tree().create_timer(3.0).timeout
	_frames = 0
	var t0 := Time.get_ticks_usec()
	var p0 := Engine.get_physics_frames()
	var worst_gap := 0.0
	var slow := 0
	var last := t0
	while (Time.get_ticks_usec() - t0) / 1e6 < 20.0:
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		var gap := (now - last) / 1e6
		worst_gap = maxf(worst_gap, gap)
		if gap > 1.5 / refresh:
			slow += 1
		last = now
	var secs := (Time.get_ticks_usec() - t0) / 1e6
	out["fps"] = snappedf(_frames / secs, 0.01)
	out["fps_bar"] = snappedf(0.95 * refresh, 0.01)
	out["fps_ok"] = _frames / secs >= 0.95 * refresh
	out["physics_per_s"] = snappedf((Engine.get_physics_frames() - p0) / secs, 0.1)
	out["slow_frames"] = slow
	out["worst_frame_ms"] = snappedf(worst_gap * 1000.0, 0.1)
	out["world_scale"] = (rig["origin"] as XROrigin3D).world_scale
	out["load_avg"] = _load_avg()
	_fly = false
	# Haptics through the real XR call path.
	var sink := VR.haptics.sink as VRHaptics.XRSink
	var c0 := sink.calls if sink else -1
	for name in HapticPatterns.names():
		VR.haptics.play(name, VRHaptics.MASK_BOTH, 0.8)
		await get_tree().create_timer(0.5).timeout
	out["haptic_calls"] = (sink.calls - c0) if sink else -1
	# Mirror of the head view with the real (fixed) simulated controllers.
	player.position = _centre
	player.rotation = Vector3.ZERO
	await get_tree().create_timer(0.5).timeout
	var dir := Paths.artifacts("vr/verify")
	await mirror.capture(dir.path_join("sim_probe_%s.png" % Paths.arg("tag", "run")))
	(rig["extras"] as VRRigExtras).wings.visible = false
	await mirror.capture(dir.path_join("sim_probe_%s_nowings.png" % Paths.arg("tag", "run")))
	(rig["extras"] as VRRigExtras).wings.visible = true
	_finish()


func _load_avg() -> String:
	var o: Array = []
	OS.execute("sysctl", ["-n", "vm.loadavg"], o)
	return String(o[0]).strip_edges() if not o.is_empty() else ""


func _finish() -> void:
	var path := Paths.artifacts("vr/verify").path_join("sim_probe_%s.json" % Paths.arg("tag", "run"))
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(out, "  "))
		f.close()
	print("[vr-verify] SIM PROBE ", JSON.stringify(out))
	get_tree().quit()
