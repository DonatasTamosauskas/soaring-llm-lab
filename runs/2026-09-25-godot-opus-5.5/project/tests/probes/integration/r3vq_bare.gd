extends Node3D
## VERIFIER PROBE (integration verify round 3, VR/Quest lens): a control for
## the simulator's frame rate on this shared Mac. An XR rig, the game's day
## sky, nothing else: if this cannot hold the refresh at the current machine
## load, a frame-rate failure of the game at the same load says nothing about
## the game. Writes artifacts/integration/verify/r3vq/bare_<tag>.json.

var _t0 := 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_t0 = Time.get_ticks_msec()
	var env := WorldEnvironment.new()
	env.environment = WorldSky.make_environment(&"day")
	add_child(env)
	var o := XROrigin3D.new()
	add_child(o)
	var c := XRCamera3D.new()
	c.near = 0.06
	o.add_child(c)
	o.current = true
	c.current = true
	_run.call_deferred()


func _run() -> void:
	var t := Time.get_ticks_msec()
	while VR.session_state != "focused" and Time.get_ticks_msec() - t < 30000:
		await get_tree().process_frame
	for i in 72:
		await get_tree().process_frame
	var intervals := PackedFloat32Array()
	var tw := Time.get_ticks_usec()
	var prev := tw
	var n := 0
	while Time.get_ticks_usec() - tw < 20000000:
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		intervals.append((now - prev) / 1000.0)
		prev = now
		n += 1
	var secs := (Time.get_ticks_usec() - tw) / 1e6
	intervals.sort()
	var pct := func(q: float) -> float: return intervals[clampi(int(ceil(q * n)) - 1, 0, n - 1)]
	var out := []
	OS.execute("sysctl", ["-n", "vm.loadavg"], out)
	var r := {"fps": n / secs, "refresh": VR.refresh_rate, "p50": pct.call(0.5), "p95": pct.call(0.95), "p99": pct.call(0.99),
		"frames": n, "load": String(out[0]).strip_edges() if not out.is_empty() else "", "state": VR.session_state}
	var tag := Paths.arg("tag", "run")
	var dir := Paths.artifacts("integration").path_join("verify/r3vq")
	DirAccess.make_dir_recursive_absolute(dir)
	var f := FileAccess.open(dir.path_join("bare_%s.json" % tag), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(r, "  "))
		f.close()
	print("[integration-verify] BARE %s" % JSON.stringify(r))
	get_tree().quit()
