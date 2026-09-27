extends Node3D
## Verifier probe, round 2 (engineering lens): an adversarial render-budget
## search on the Quest renderer. 1280x720, 90 deg FOV, far 3000 m, MSAA 4x,
## shadow pass included (as W7 and the builder's perf run).
##
## Views: 150 random cameras in and around the forest (the builder's worst
## district), 60 around the village and 90 anywhere, with random yaw and
## pitch (seeds the builder did not use). Each view is measured twice:
##   cold - arriving from the far corner of the valley (LODs that were far
##          stay coarse until well inside their switch distance);
##   warm - after circling the view point at 25 m first, so every
##          visibility range is in its "was near" hysteresis state (what a
##          bird that has been flying around there sees).
##
##   tools/gd.sh world_verify2 --rendering-method mobile --resolution 1280x720 res://tests/probes/world/world_verify2_perf.tscn
##
## Writes artifacts/world/verify/r2/perf_<renderer>_verify2.json.

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
	var views := _views()
	var results := {}
	var worst := {"cold_dc": [0, ""], "cold_pr": [0, ""], "warm_dc": [0, ""], "warm_pr": [0, ""]}
	var over := 0
	for v in views:
		var pos: Vector3 = v[1]
		var look: Vector3 = v[2]
		# Cold: from the far corner.
		cam.global_position = Vector3(560, 250, 560)
		cam.look_at(Vector3.ZERO, Vector3.UP)
		for i in 3:
			await get_tree().process_frame
		_place(pos, look)
		for i in 5:
			await get_tree().process_frame
		var cold := _info()
		# Warm: circle the point at 25 m, then come back.
		for k in 8:
			var a := TAU * k / 8.0
			_place(pos + Vector3(cos(a) * 25.0, 0.0, sin(a) * 25.0), look)
			await get_tree().process_frame
			await get_tree().process_frame
		_place(pos, look)
		for i in 5:
			await get_tree().process_frame
		var warm := _info()
		results[v[0]] = {"cold": cold, "warm": warm, "camera": [pos.x, pos.y, pos.z], "look": [look.x, look.y, look.z]}
		for mode in ["cold", "warm"]:
			var r: Array = cold if mode == "cold" else warm
			if int(r[0]) > int(worst[mode + "_dc"][0]):
				worst[mode + "_dc"] = [r[0], v[0]]
			if int(r[1]) > int(worst[mode + "_pr"][0]):
				worst[mode + "_pr"] = [r[1], v[0]]
			if int(r[0]) > 150 or int(r[1]) > 300000:
				over += 1
		print("[world-verify2] perf %-14s cold %3d dc %7d pr | warm %3d dc %7d pr" % [v[0], cold[0], cold[1], warm[0], warm[1]])
	var rm := RenderingServer.get_current_rendering_method()
	var out := Paths.artifacts("world").path_join("verify").path_join("r2")
	DirAccess.make_dir_recursive_absolute(out)
	var fa := FileAccess.open(out.path_join("perf_%s_verify2.json" % rm), FileAccess.WRITE)
	fa.store_string(JSON.stringify({"renderer": rm, "resolution": [get_viewport().size.x, get_viewport().size.y], "fov": 90.0, "far": 3000.0,
		"views": results, "worst": worst, "over_budget_measurements": over, "generation_ms": world.generation_ms}, "  "))
	print("[world-verify2] perf %s: %d views; worst cold %s dc / %s pr; worst warm %s dc / %s pr; over budget: %d" % [rm, views.size(),
		worst["cold_dc"], worst["cold_pr"], worst["warm_dc"], worst["warm_pr"], over])
	get_tree().quit()


func _place(pos: Vector3, look: Vector3) -> void:
	cam.global_position = pos
	cam.look_at(look, Vector3.UP)


## [draw calls, primitives] of the last frame, shadow pass included.
func _info() -> Array:
	var vp := get_viewport()
	var dc := vp.get_render_info(Viewport.RENDER_INFO_TYPE_VISIBLE, Viewport.RENDER_INFO_DRAW_CALLS_IN_FRAME) \
		+ vp.get_render_info(Viewport.RENDER_INFO_TYPE_SHADOW, Viewport.RENDER_INFO_DRAW_CALLS_IN_FRAME)
	var pr := vp.get_render_info(Viewport.RENDER_INFO_TYPE_VISIBLE, Viewport.RENDER_INFO_PRIMITIVES_IN_FRAME) \
		+ vp.get_render_info(Viewport.RENDER_INFO_TYPE_SHADOW, Viewport.RENDER_INFO_PRIMITIVES_IN_FRAME)
	return [dc, pr]


func _views() -> Array:
	var v := []
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260926
	var groups := [["forest", WorldLayout.FOREST, 200.0, 150, 60.0], ["village", WorldLayout.VILLAGE, 150.0, 60, 40.0],
		["any", Vector2.ZERO, 640.0, 90, 150.0]]
	for g in groups:
		var made := 0
		while made < int(g[3]):
			var c: Vector2 = g[1]
			var p := c + Vector2.from_angle(rng.randf() * TAU) * sqrt(rng.randf()) * float(g[2])
			if p.length() > world.bounds_radius - 5.0:
				continue
			var gy := world.ground_height(p.x, p.y)
			var y := gy + rng.randf_range(2.0, float(g[4]))
			if y > world.ceiling - 5.0:
				continue
			var yaw := rng.randf() * TAU
			var pitch := deg_to_rad(rng.randf_range(-35.0, 15.0))
			var d := Vector3(cos(yaw) * cos(pitch), sin(pitch), sin(yaw) * cos(pitch))
			var pos := Vector3(p.x, y, p.y)
			v.append(["%s_%03d" % [g[0], made], pos, pos + d * 50.0])
			made += 1
	return v
