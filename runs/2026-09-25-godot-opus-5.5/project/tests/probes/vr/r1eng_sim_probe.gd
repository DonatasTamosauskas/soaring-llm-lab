extends "res://tests/sim/vr_sim.gd"
## Verifier probe (round 1, engineering lens): an independent re-run of the
## V1 / V6 simulator claims on the area's own harness scene, but writing
## only into artifacts/vr/verify/ (no driver, no mirror shots, so none of
## the builder's evidence files are overwritten).
##
##   tools/xr.sh 90 res://tests/probes/vr/r1eng_sim_probe.tscn -- --tag=r1eng
##
## Checks: session FOCUSED, physics ticks == refresh, fps over 20 s flying
## the stand-in over the real world with 60 NPC stand-ins >= 0.95 x refresh,
## focus held, and every haptic pattern reaching the real XR call path.
## Also records the frame-time distribution (p50/p95/p99) so a pass at the
## bar can be told from a pass by averaging.

var _ft: Array[float] = []


func _write_state(_phase: String) -> void:
	pass


func _run() -> void:
	var waited := 0.0
	while VR.session_state != "focused" and waited < 20.0:
		await get_tree().process_frame
		waited += get_process_delta_time()
	_check("session_focused", VR.active and VR.session_state == "focused", {"state": VR.session_state, "after_s": snappedf(waited, 0.1)})
	if not VR.active:
		_finish()
		return
	await get_tree().create_timer(2.0).timeout
	var refresh := VR.xr.display_refresh_rate
	_check("physics_tick_equals_refresh", Engine.physics_ticks_per_second == roundi(refresh),
		{"physics_ticks": Engine.physics_ticks_per_second, "refresh": refresh})
	extras.vignette.setting_override = 0.6
	_fly = true
	player.set(&"mode_label", "flying")
	await get_tree().create_timer(3.0).timeout
	var losses0 := VR.focus_losses
	var t_start := Time.get_ticks_usec()
	var last := t_start
	var frames := 0
	while (Time.get_ticks_usec() - t_start) / 1e6 < 20.0:
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		_ft.append((now - last) / 1000.0)
		last = now
		frames += 1
	var secs := (Time.get_ticks_usec() - t_start) / 1e6
	_fly = false
	var sorted := _ft.duplicate()
	sorted.sort()
	var pct := func(p: float) -> float: return snappedf(float(sorted[clampi(int(p * (sorted.size() - 1)), 0, sorted.size() - 1)]), 0.01)
	var fps := frames / secs
	_check("fps_at_least_95pct_refresh", fps >= 0.95 * refresh, {"fps": snappedf(fps, 0.01), "bar": 0.95 * refresh,
		"p50_ms": pct.call(0.5), "p95_ms": pct.call(0.95), "p99_ms": pct.call(0.99), "max_ms": snappedf(float(sorted.back()), 0.01),
		"load_avg": _load_avg(), "ws": snappedf((rig["origin"] as XROrigin3D).world_scale, 0.0001),
		"near": snappedf((rig["camera"] as Camera3D).near, 0.00001)})
	_check("focused_through_window", VR.focus_losses == losses0 and VR.focused, {"losses": VR.focus_losses - losses0})
	# V7 in the live rig: near plane follows world_scale (0.03 x ws), rig unscaled.
	var o := rig["origin"] as XROrigin3D
	var unscaled := true
	var n: Node = o
	while n != null:
		if n is Node3D and not (n as Node3D).scale.is_equal_approx(Vector3.ONE):
			unscaled = false
		n = n.get_parent()
	_check("near_follows_scale_and_rig_unscaled", unscaled and absf((rig["camera"] as Camera3D).near - WorldScaleDriver.near_for(o.world_scale)) < 1e-6,
		{"ws": o.world_scale, "near": (rig["camera"] as Camera3D).near})
	# V6: every pattern through the real XR interface.
	var sink := VR.haptics.sink as VRHaptics.XRSink
	var per := {}
	for name in HapticPatterns.names():
		var c0 := sink.calls if sink else 0
		VR.haptics.play(name, VRHaptics.MASK_BOTH, 0.8)
		await get_tree().create_timer(0.6).timeout
		per[String(name)] = (sink.calls if sink else 0) - c0
	_check("haptics_real_call_path", sink != null and per.values().all(func(k: int) -> bool: return k >= 2), per)
	_finish()


func _finish() -> void:
	var ok := true
	for k in result["checks"]:
		ok = ok and bool(result["checks"][k]["ok"])
	result["pass"] = ok
	var path := Paths.artifacts("vr/verify").path_join("r1eng_sim_result.json")
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(result, "  "))
		f.close()
	print("[vr] R1ENG SIM RESULT %s -> %s" % ["PASS" if ok else "FAIL", path])
	get_tree().quit(0 if ok else 1)
