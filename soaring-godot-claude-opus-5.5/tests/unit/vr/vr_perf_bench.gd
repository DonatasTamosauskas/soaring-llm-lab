extends RefCounted
## The VR area's per-frame CPU bench (shared by tests/unit/vr/perf_test.gd,
## which pins the work, and tests/sim/perf/vr_perf_test.gd, which gates the
## time): every VR feature ticked by hand for FRAMES frames of low flapping
## flight down a corridor (a floor and two walls inside the vignette's ray
## probe rays' reach: the worst case for their cost), with
## the arms moving every frame (every feather re-laid every frame), timed
## per feature in BLOCKS blocks.

const Env := preload("res://scenes/dev/vr_dev_env.gd")
const MemoryStore := preload("res://tests/unit/vr/vr_memory_store.gd")
const DT := 1.0 / 90.0
const FRAMES := 900
const BLOCKS := 5


## A floor 0.9 m under the eyes and walls 1.0 m either side, all inside
## the vignette probes' reach (8 body spans, 1.9 m even at a sparrow's
## world_scale): every probe but the one straight ahead hits, the worst
## case for its cost.
static func build_corridor(t: Node, eye_y: float) -> Node3D:
	var root := Node3D.new()
	for spec in [[Vector3(0, eye_y - 0.9 - 0.1, -150), Vector3(20, 0.2, 400)], [Vector3(-1.1, eye_y, -150), Vector3(0.2, 8, 400)],
			[Vector3(1.1, eye_y, -150), Vector3(0.2, 8, 400)]]:
		var body := StaticBody3D.new()
		body.collision_layer = 1
		var cs := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = spec[1]
		cs.shape = box
		body.add_child(cs)
		body.position = spec[0]
		root.add_child(body)
	t.add_child(root)
	return root


## Runs the bench under test node `t` (a TestCase, for its frame waits).
## Returns {best_us, median_us, mean_us, blocks_us, parts_us, relays,
## ray_hits, calibrated, load}.
static func run(t: TestCase) -> Dictionary:
	var rig := Env.build_rig(t, Vector3(0, 3, 0), MemoryStore.new(), true, false)
	await t.wait_frames(3)
	var extras: VRRigExtras = rig["extras"]
	var puppet: VRPosePuppet = rig["puppet"]
	puppet.set_process(false)
	extras.calibration.auto_tick = false
	extras.wings.auto_update = false
	extras.vignette.auto_update = false
	extras.world_scale_driver.auto_step = false
	extras.world_scale_driver.step(DT)
	puppet.pose_for(&"spread", 0.0)
	puppet.apply()
	var corridor := build_corridor(t, (rig["camera"] as Node3D).global_position.y)
	await t.wait_physics(2)
	var h := VRHaptics.new()
	h.auto_tick = false
	h.listen_to_events = false
	h.intensity_override = 1.0
	t.add_child(h)
	var c := VRControls.new()
	c.auto_tick = false
	c.emit_events = false
	t.add_child(c)
	# Calibrate first (the explicit step): in play nothing captures.
	puppet.pose_for(&"spread", 0.0)
	puppet.apply()
	extras.calibration.start_manual()
	for i in 200:
		extras.calibration.tick(DT)
	var calibrated := extras.calibration.calibrator.calibrated
	puppet.gesture = &"flap"
	# Warm up (first calls compile/allocate).
	for i in 30:
		puppet.pose_for(&"flap", i * DT)
		puppet.apply()
		extras.calibration.tick(DT)
		extras.wings.update_wings(DT)
	var parts := {"calibration": 0, "wings": 0, "vignette": 0, "haptics": 0, "controls": 0, "world_scale": 0}
	var total := 0
	var blocks: Array[float] = []
	var block_us := 0
	var updates0 := extras.wings.updates
	var body := rig["player"] as Node3D
	var hits := 0
	for i in FRAMES:
		puppet.pose_for(&"flap", i * DT)
		puppet.apply()
		# Low flight down the corridor at 8 m/s, weaving gently about its
		# centre line (±0.3 m).
		body.rotation.y = 0.05 * cos(i * DT * 1.3)
		body.position += -body.global_basis.z * 8.0 * DT
		var t0 := Time.get_ticks_usec()
		extras.calibration.tick(DT)
		var t1 := Time.get_ticks_usec()
		extras.wings.update_wings(DT)
		var t2 := Time.get_ticks_usec()
		extras.vignette.measure(DT)
		extras.vignette.update_strength(DT)
		var t3 := Time.get_ticks_usec()
		if extras.vignette.nearest < INF:
			hits += 1
		h.tick(DT)
		var t4 := Time.get_ticks_usec()
		c.tick(DT)
		var t5 := Time.get_ticks_usec()
		extras.world_scale_driver.step(DT)
		var t6 := Time.get_ticks_usec()
		parts["calibration"] += t1 - t0
		parts["wings"] += t2 - t1
		parts["vignette"] += t3 - t2
		parts["haptics"] += t4 - t3
		parts["controls"] += t5 - t4
		parts["world_scale"] += t6 - t5
		total += t6 - t0
		block_us += t6 - t0
		if (i + 1) % (FRAMES / BLOCKS) == 0:
			blocks.append(float(block_us) / (FRAMES / BLOCKS))
			block_us = 0
	var sorted_blocks := blocks.duplicate()
	sorted_blocks.sort()
	var per := {}
	for k in parts:
		per[k] = snappedf(float(parts[k]) / FRAMES, 0.1)
	var out := {"best_us": sorted_blocks[0], "median_us": sorted_blocks[BLOCKS / 2], "mean_us": float(total) / FRAMES,
		"blocks_us": blocks.map(func(b: float) -> float: return snappedf(b, 0.1)), "parts_us": per,
		"relays": extras.wings.updates - updates0, "ray_hits": hits, "calibrated": calibrated, "load": load_avg()}
	h.queue_free()
	c.queue_free()
	(rig["player"] as Node).queue_free()
	puppet.queue_free()
	corridor.queue_free()
	XRServer.world_scale = 1.0
	await t.wait_frames(2)
	return out


static func load_avg() -> String:
	var out: Array = []
	if OS.execute("sysctl", ["-n", "vm.loadavg"], out) == 0 and not out.is_empty():
		return str(out[0]).strip_edges()
	return "?"
