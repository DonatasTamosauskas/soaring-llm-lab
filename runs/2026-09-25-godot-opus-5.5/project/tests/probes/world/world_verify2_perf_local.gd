extends Node3D
## Verifier probe, round 2: local search around the worst view the random
## search found (forest_034), to tell a one-off from a region. Same
## protocol as world_verify2_perf.gd (Mobile, 1280x720, 90 deg FOV, far
## 3000, shadow pass included; cold = arriving from the far corner, warm =
## after circling the point at 25 m). Also reports the visible/shadow split
## and a Quest-Pro-like single-eye frustum (square 1:1, 96 deg vertical).
##
##   tools/gd.sh world_verify2 --rendering-method mobile --resolution 1280x720 res://tests/probes/world/world_verify2_perf_local.tscn
##
## Writes artifacts/world/verify/r2/perf_local_verify2.json.

var world: SoaringWorld
var cam: Camera3D


func _ready() -> void:
	world = load("res://scenes/world/world.tscn").instantiate()
	add_child(world)
	cam = Camera3D.new()
	cam.fov = 90.0
	cam.near = 0.05
	cam.far = 3000.0
	add_child(cam)
	cam.current = true
	get_viewport().msaa_3d = Viewport.MSAA_4X
	await get_tree().process_frame
	var base_pos := Vector3(-276.6, 16.0, -331.2)
	var base_look := Vector3(-247.8, 20.0, -290.4)
	# --calib: measure the builder's reported worst view (inside_forest_to_mast)
	# with this protocol, to check the two protocols agree.
	var calib := Paths.user_args().has("calib")
	if calib:
		base_pos = Vector3(-262, 3, -258)
		base_look = Vector3(468, 40, 110)
	var rng := RandomNumberGenerator.new()
	rng.seed = 34
	var results := []
	var over_cold := 0
	var over_warm := 0
	var n := 1 if calib else 60
	for i in n:
		var pos := base_pos
		var look := base_look
		if i > 0:
			pos += Vector3(rng.randf_range(-15, 15), rng.randf_range(-8, 12), rng.randf_range(-15, 15))
			pos.y = maxf(pos.y, world.ground_height(pos.x, pos.z) + 2.0)
			var d := (base_look - base_pos).normalized().rotated(Vector3.UP, deg_to_rad(rng.randf_range(-30, 30)))
			d.y += rng.randf_range(-0.2, 0.15)
			look = pos + d.normalized() * 50.0
		await _from_far()
		_place(pos, look)
		for k in 5:
			await get_tree().process_frame
		var cold := _info()
		for k in 8:
			var a := TAU * k / 8.0
			_place(pos + Vector3(cos(a) * 25.0, 0.0, sin(a) * 25.0), look)
			await get_tree().process_frame
			await get_tree().process_frame
		_place(pos, look)
		for k in 5:
			await get_tree().process_frame
		var warm := _info()
		if cold[1] + cold[3] > 300000:
			over_cold += 1
		if warm[1] + warm[3] > 300000:
			over_warm += 1
		results.append({"pos": [pos.x, pos.y, pos.z], "look": [look.x, look.y, look.z], "cold": cold, "warm": warm})
		print("[world-verify2] local %02d cold vis %3d/%7d shadow %3d/%6d = %7d | warm vis %3d/%7d shadow %3d/%6d = %7d" % [i,
			cold[0], cold[1], cold[2], cold[3], cold[1] + cold[3], warm[0], warm[1], warm[2], warm[3], warm[1] + warm[3]])
	# The worst view again through a Quest-Pro-like eye: square, 96 deg.
	get_window().size = Vector2i(1024, 1024)
	cam.fov = 96.0
	await _from_far()
	_place(base_pos, base_look)
	for k in 5:
		await get_tree().process_frame
	var q_cold := _info()
	for k in 8:
		var a := TAU * k / 8.0
		_place(base_pos + Vector3(cos(a) * 25.0, 0.0, sin(a) * 25.0), base_look)
		await get_tree().process_frame
		await get_tree().process_frame
	_place(base_pos, base_look)
	for k in 5:
		await get_tree().process_frame
	var q_warm := _info()
	print("[world-verify2] quest-like eye (1:1, 96 deg): cold %s warm %s" % [q_cold, q_warm])
	var out := Paths.artifacts("world").path_join("verify").path_join("r2")
	DirAccess.make_dir_recursive_absolute(out)
	var fa := FileAccess.open(out.path_join("perf_local_verify2%s.json" % ("_calib" if calib else "")), FileAccess.WRITE)
	fa.store_string(JSON.stringify({"views": results, "over_cold": over_cold, "over_warm": over_warm, "n": n,
		"quest_like_eye": {"cold": q_cold, "warm": q_warm}}, "  "))
	print("[world-verify2] local search: %d views, %d over 300k cold, %d over 300k warm" % [n, over_cold, over_warm])
	get_tree().quit()


func _from_far() -> void:
	cam.global_position = Vector3(560, 250, 560)
	cam.look_at(Vector3.ZERO, Vector3.UP)
	for i in 3:
		await get_tree().process_frame


func _place(pos: Vector3, look: Vector3) -> void:
	cam.global_position = pos
	cam.look_at(look, Vector3.UP)


## [visible draws, visible prims, shadow draws, shadow prims] of the last frame.
func _info() -> Array:
	var vp := get_viewport()
	return [vp.get_render_info(Viewport.RENDER_INFO_TYPE_VISIBLE, Viewport.RENDER_INFO_DRAW_CALLS_IN_FRAME),
		vp.get_render_info(Viewport.RENDER_INFO_TYPE_VISIBLE, Viewport.RENDER_INFO_PRIMITIVES_IN_FRAME),
		vp.get_render_info(Viewport.RENDER_INFO_TYPE_SHADOW, Viewport.RENDER_INFO_DRAW_CALLS_IN_FRAME),
		vp.get_render_info(Viewport.RENDER_INFO_TYPE_SHADOW, Viewport.RENDER_INFO_PRIMITIVES_IN_FRAME)]
