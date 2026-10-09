extends Node3D
## Verifier probe, round 4 (experience lens): an independent W7 budget check
## on the Quest renderer aimed at views earlier random searches sampled
## little: the whole valley from the rim, steep look-downs from under the
## lid, low along the hedge grid (251 hedges with bulges), the forest edge
## looking at the village, and the village street looking at the forest.
## 1280x720, 90 deg FOV, far 3000 m, MSAA 4x, shadow pass counted; each view
## cold (arriving from the far corner) and warm (after circling it at 25 m).
##
##   tools/gd.sh world_r4perf --rendering-method mobile --resolution 1280x720 res://tests/probes/world/world_r4exp_perf.tscn
##
## Writes artifacts/world/verify/r4exp/r4exp_perf_<renderer>.json; exits 1 over budget.

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
	var worst := {"dc": [0, ""], "pr": [0, ""]}
	var over := 0
	var stale := 0
	for v: Array in views:
		var pos: Vector3 = v[1]
		var look: Vector3 = v[2]
		cam.global_position = Vector3(560, 250, 560)
		cam.look_at(Vector3.ZERO, Vector3.UP)
		for i in 3:
			await get_tree().process_frame
		_place(pos, look)
		var ok_c := await _drawn(5)
		var cold := _info()
		for k in 8:
			var a := TAU * k / 8.0
			_place(pos + Vector3(cos(a) * 25.0, 0.0, sin(a) * 25.0), look + Vector3(cos(a) * 25.0, 0.0, sin(a) * 25.0))
			await get_tree().process_frame
			await get_tree().process_frame
		_place(pos, look)
		var ok_w := await _drawn(5)
		var warm := _info()
		if not (ok_c and ok_w):
			stale += 1
		results[v[0]] = {"cold": cold, "warm": warm, "camera": [pos.x, pos.y, pos.z], "look": [look.x, look.y, look.z]}
		for r: Array in [cold, warm]:
			if int(r[0]) > int(worst["dc"][0]):
				worst["dc"] = [r[0], v[0]]
			if int(r[1]) > int(worst["pr"][0]):
				worst["pr"] = [r[1], v[0]]
			if int(r[0]) > 150 or int(r[1]) > 300000:
				over += 1
		print("[world-r4] perf %-18s cold %3d dc %7d pr | warm %3d dc %7d pr" % [v[0], cold[0], cold[1], warm[0], warm[1]])
	var rm := RenderingServer.get_current_rendering_method()
	var out := Paths.artifacts("world").path_join("verify").path_join("r4exp")
	DirAccess.make_dir_recursive_absolute(out)
	var fa := FileAccess.open(out.path_join("r4exp_perf_%s.json" % rm), FileAccess.WRITE)
	fa.store_string(JSON.stringify({"renderer": rm, "resolution": [get_viewport().size.x, get_viewport().size.y], "fov": 90.0,
		"views": results, "worst": worst, "over_budget_measurements": over, "stale": stale}, "  "))
	fa.close()
	print("[world-r4] perf %s: %d views (stale %d); worst %s dc / %s pr; over budget: %d" % [rm, views.size(), stale, worst["dc"], worst["pr"], over])
	get_tree().quit(1 if over > 0 else 0)


func _drawn(n: int) -> bool:
	var f0 := Engine.get_frames_drawn()
	for i in 400:
		await get_tree().process_frame
		if Engine.get_frames_drawn() - f0 >= n:
			return true
	return false


func _place(pos: Vector3, look: Vector3) -> void:
	cam.global_position = pos
	cam.look_at(look, Vector3.UP)


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
	rng.seed = 20_260_926
	var mid := (WorldLayout.FOREST + WorldLayout.VILLAGE) * 0.5
	# Whole valley from the rim.
	for i in 24:
		var a := TAU * i / 24.0 + rng.randf_range(-0.1, 0.1)
		var r := rng.randf_range(560.0, 630.0)
		var p := Vector2.from_angle(a) * r
		var y := maxf(world.ground_height(p.x, p.y) + 10.0, rng.randf_range(120.0, 280.0))
		if y > 295.0:
			y = 295.0
		var tgt := Vector2(rng.randf_range(-150, 150), rng.randf_range(-150, 150))
		v.append(["rim_%02d" % i, Vector3(p.x, y, p.y), Vector3(tgt.x, 0.0, tgt.y)])
	# Steep look-downs from under the lid over the forest-village axis.
	for i in 12:
		var p := mid + Vector2(rng.randf_range(-250, 250), rng.randf_range(-250, 250))
		var tgt := mid + Vector2(rng.randf_range(-120, 120), rng.randf_range(-120, 120))
		v.append(["lid_%02d" % i, Vector3(p.x, rng.randf_range(260.0, 295.0), p.y), Vector3(tgt.x, 0.0, tgt.y)])
	# Low along the south field hedge grid.
	for i in 14:
		var p := WorldLayout.FIELDS_ORIGIN + Vector2(rng.randf_range(0, WorldLayout.FIELDS_SIZE.x), rng.randf_range(0, WorldLayout.FIELDS_SIZE.y))
		var yaw := (PI * 0.5 * rng.randi_range(0, 3)) + rng.randf_range(-0.2, 0.2)
		var y := world.ground_height(p.x, p.y) + rng.randf_range(2.0, 9.0)
		var d := Vector3(cos(yaw), rng.randf_range(-0.12, 0.05), sin(yaw))
		v.append(["hedges_%02d" % i, Vector3(p.x, y, p.y), Vector3(p.x, y, p.y) + d * 50.0])
	# Forest edge (village side) at canopy height, looking at the village.
	for i in 12:
		var to_v := (WorldLayout.VILLAGE - WorldLayout.FOREST).normalized()
		var p := WorldLayout.FOREST + to_v.rotated(rng.randf_range(-0.6, 0.6)) * rng.randf_range(120.0, 175.0)
		var y := world.ground_height(p.x, p.y) + rng.randf_range(12.0, 30.0)
		var tgt := WorldLayout.VILLAGE + Vector2(rng.randf_range(-80, 80), rng.randf_range(-40, 40))
		v.append(["edge_%02d" % i, Vector3(p.x, y, p.y), Vector3(tgt.x, world.ground_height(tgt.x, tgt.y) + 5.0, tgt.y)])
	# Village street looking at the forest and orchard.
	for i in 10:
		var p := Vector2(rng.randf_range(WorldLayout.STREET_X0, WorldLayout.STREET_X1), WorldLayout.STREET_Z + rng.randf_range(-6, 6))
		var y := world.ground_height(p.x, p.y) + rng.randf_range(1.5, 14.0)
		var tgt := (WorldLayout.FOREST if i % 2 == 0 else WorldLayout.ORCHARD) + Vector2(rng.randf_range(-60, 60), rng.randf_range(-60, 60))
		v.append(["street_%02d" % i, Vector3(p.x, y, p.y), Vector3(tgt.x, world.ground_height(tgt.x, tgt.y) + 8.0, tgt.y)])
	return v
