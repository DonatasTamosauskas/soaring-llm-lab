extends Node3D
## Verifier probe, round 3 (engineering lens): W7 render budget measured
## independently of the builder's routes and view lists.
##
##   walk   a seeded random-walk "bird" flight over the whole valley (heading
##          and height above ground wander, the head looks around +-70 deg
##          and -35..+10 deg pitch), measured every frame, so every
##          visibility-range hysteresis state a real flight produces occurs;
##   climb  hill-climbing from the walk's 8 worst frames: perturb position
##          (+-12 m), yaw (+-25 deg) and pitch (+-12 deg), keep what costs
##          more, each candidate measured warm (the builder's protocol:
##          arrive from the far corner, circle the point at 25 m, return).
##
## Same protocol as tests/shots/world_perf.gd: Mobile renderer, 1280x720,
## 90 deg vertical FOV, near 0.05, far 3000, MSAA 4x, visible + shadow pass.
##
##   tools/gd.sh world_verify2 --rendering-method mobile --resolution 1280x720 \
##       res://tests/probes/world/world_verify3_perf.tscn -- [--frames=5000] [--iters=24]
##
## Writes artifacts/world/verify/r3/perf_walk_mobile.json.

const BUDGET_DRAWS := 150
const BUDGET_PRIMS := 300000

var world: SoaringWorld
var cam: Camera3D
var _vp: Viewport
var _space: PhysicsDirectSpaceState3D


func _ready() -> void:
	var args := Paths.user_args()
	world = load("res://scenes/world/world.tscn").instantiate()
	add_child(world)
	cam = Camera3D.new()
	cam.fov = 90.0
	cam.near = 0.05
	cam.far = 3000.0
	add_child(cam)
	cam.current = true
	_vp = get_viewport()
	_vp.msaa_3d = Viewport.MSAA_4X
	if not world.is_generated:
		await world.generated
	for i in 6:
		await get_tree().process_frame
	_space = world.get_world_3d().direct_space_state
	var out := {"renderer": RenderingServer.get_current_rendering_method(), "fov": cam.fov,
		"resolution": [_vp.get_visible_rect().size.x, _vp.get_visible_rect().size.y], "generation_ms": world.generation_ms}
	var walk: Dictionary = await _walk(int(args.get("frames", "5000")))
	out["walk"] = walk
	out["climb"] = await _climb(walk["top"], int(args.get("iters", "24")))
	var worst := maxi(int(walk["worst_primitives"]), int(out["climb"]["worst_primitives"]))
	var worst_dc := maxi(int(walk["worst_draw_calls"]), int(out["climb"]["worst_draw_calls"]))
	out["worst_primitives"] = worst
	out["worst_draw_calls"] = worst_dc
	out["within_budget"] = worst <= BUDGET_PRIMS and worst_dc <= BUDGET_DRAWS
	print("[world-verify3] perf: worst %d primitives, %d draw calls (budget %d / %d)" % [worst, worst_dc, BUDGET_PRIMS, BUDGET_DRAWS])
	var dir := Paths.artifacts("world").path_join("verify/r3")
	DirAccess.make_dir_recursive_absolute(dir)
	var fa := FileAccess.open(dir.path_join("perf_walk_%s.json" % out["renderer"]), FileAccess.WRITE)
	fa.store_string(JSON.stringify(out, "  "))
	get_tree().quit()


func _info() -> Array:
	var dc := _vp.get_render_info(Viewport.RENDER_INFO_TYPE_VISIBLE, Viewport.RENDER_INFO_DRAW_CALLS_IN_FRAME) \
		+ _vp.get_render_info(Viewport.RENDER_INFO_TYPE_SHADOW, Viewport.RENDER_INFO_DRAW_CALLS_IN_FRAME)
	var vis := _vp.get_render_info(Viewport.RENDER_INFO_TYPE_VISIBLE, Viewport.RENDER_INFO_PRIMITIVES_IN_FRAME)
	var sh := _vp.get_render_info(Viewport.RENDER_INFO_TYPE_SHADOW, Viewport.RENDER_INFO_PRIMITIVES_IN_FRAME)
	return [dc, vis + sh, vis, sh]


func _look_dir(yaw: float, pitch: float) -> Vector3:
	return Vector3(cos(yaw) * cos(pitch), sin(pitch), sin(yaw) * cos(pitch))


func _place(pos: Vector3, dir: Vector3) -> void:
	var d := dir.normalized()
	if absf(d.y) > 0.98:
		d = (d + Vector3(0.3, 0, 0)).normalized()
	cam.look_at_from_position(pos, pos + d, Vector3.UP)


## A camera is only where a bird could be: not inside anything solid.
func _clear(pos: Vector3) -> bool:
	var sp := SphereShape3D.new()
	sp.radius = 0.15
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = sp
	q.collision_mask = 1
	q.transform = Transform3D(Basis.IDENTITY, pos)
	return _space.intersect_shape(q, 1).is_empty() and world.is_inside(pos)


func _walk(frames: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = 314159
	var p2 := Vector2(-150, 60)
	var heading := rng.randf() * TAU
	var agl := 20.0
	var agl_target := 20.0
	var look_phase := rng.randf() * TAU
	var step := 3.0
	var res := {"frames": 0, "skipped": 0, "worst_draw_calls": 0, "worst_primitives": 0, "over_budget": 0, "top": []}
	var prims: Array = []
	var top: Array = []
	var by_region := {}
	for f in frames:
		# Wander; steer back in near the edge (the arena is closed).
		heading += rng.randf_range(-0.09, 0.09)
		var r := p2.length()
		if r > 560.0:
			var inward := (-p2).angle()
			heading = lerp_angle(heading, inward, 0.08)
		# Forests and the village pull the flight low; elsewhere it roams.
		if f % 60 == 0:
			var low := p2.distance_to(WorldLayout.FOREST) < WorldLayout.FOREST_R + 60.0 or p2.distance_to(WorldLayout.VILLAGE) < 140.0
			agl_target = rng.randf_range(3.0, 35.0) if low else rng.randf_range(4.0, 110.0)
		agl = lerpf(agl, agl_target, 0.04)
		p2 += Vector2(cos(heading), sin(heading)) * step
		var g := world.ground_height(p2.x, p2.y)
		var pos := Vector3(p2.x, minf(g + agl, world.ceiling - 3.0), p2.y)
		look_phase += 0.035
		var yaw := heading + sin(look_phase) * deg_to_rad(70.0)
		var pitch := deg_to_rad(-12.5 + sin(look_phase * 0.37 + 1.0) * 22.5)
		if not _clear(pos):
			res["skipped"] = int(res["skipped"]) + 1
			continue
		_place(pos, _look_dir(yaw, pitch))
		await get_tree().process_frame
		var m := _info()
		res["frames"] = int(res["frames"]) + 1
		prims.append(m[1])
		var region := _region(p2)
		by_region[region] = maxi(int(by_region.get(region, 0)), int(m[1]))
		if int(m[0]) > BUDGET_DRAWS or int(m[1]) > BUDGET_PRIMS:
			res["over_budget"] = int(res["over_budget"]) + 1
		res["worst_draw_calls"] = maxi(int(res["worst_draw_calls"]), int(m[0]))
		if int(m[1]) > int(res["worst_primitives"]):
			res["worst_primitives"] = int(m[1])
			res["worst_at"] = {"pos": _arr(pos), "yaw_deg": snappedf(rad_to_deg(yaw), 0.1), "pitch_deg": snappedf(rad_to_deg(pitch), 0.1), "split": [m[2], m[3]], "draws": m[0]}
		top.append([int(m[1]), pos, yaw, pitch])
		if top.size() > 400:
			top.sort_custom(func(a: Array, b: Array) -> bool: return a[0] > b[0])
			top.resize(60)
	top.sort_custom(func(a: Array, b: Array) -> bool: return a[0] > b[0])
	# Keep 8 worst frames that are at least 25 m apart (distinct places).
	var picked: Array = []
	for t in top:
		var far_enough := true
		for q in picked:
			if (q[1] as Vector3).distance_to(t[1]) < 25.0:
				far_enough = false
		if far_enough:
			picked.append(t)
		if picked.size() >= 8:
			break
	prims.sort()
	res["p50_primitives"] = prims[prims.size() / 2]
	res["p99_primitives"] = prims[int(prims.size() * 0.99)]
	res["worst_by_region"] = by_region
	res["top"] = picked.map(func(t: Array) -> Array: return [t[0], _arr(t[1]), snappedf(rad_to_deg(t[2]), 0.1), snappedf(rad_to_deg(t[3]), 0.1)])
	print("[world-verify3] walk: %d frames (%d skipped inside solids), worst %d prims / %d draws, p99 %d; over budget %d; by region %s" % [
		res["frames"], res["skipped"], res["worst_primitives"], res["worst_draw_calls"], res["p99_primitives"], res["over_budget"], by_region])
	return res


func _region(p: Vector2) -> String:
	if p.distance_to(WorldLayout.FOREST) < WorldLayout.FOREST_R + 60.0:
		return "forest"
	if p.distance_to(WorldLayout.VILLAGE) < 160.0:
		return "village"
	if p.length() > 520.0:
		return "rim"
	return "valley"


static func _arr(v: Vector3) -> Array:
	return [snappedf(v.x, 0.1), snappedf(v.y, 0.1), snappedf(v.z, 0.1)]


func _warm(pos: Vector3, dir: Vector3) -> Array:
	_place(Vector3(560, 250, 560), -Vector3(560, 250, 560))
	for i in 3:
		await get_tree().process_frame
	_place(pos, dir)
	for i in 4:
		await get_tree().process_frame
	var cold := _info()
	for k in 8:
		var a := TAU * k / 8.0
		_place(pos + Vector3(cos(a) * 25.0, 0.0, sin(a) * 25.0), dir)
		await get_tree().process_frame
		await get_tree().process_frame
	_place(pos, dir)
	for i in 4:
		await get_tree().process_frame
	var warm := _info()
	return [cold, warm]


func _climb(top: Array, iters: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = 2718
	var res := {"starts": top.size(), "worst_primitives": 0, "worst_draw_calls": 0, "over_budget": 0, "paths": []}
	for t in top:
		var pos := Vector3(t[1][0], t[1][1], t[1][2])
		var yaw := deg_to_rad(float(t[2]))
		var pitch := deg_to_rad(float(t[3]))
		var cw: Array = await _warm(pos, _look_dir(yaw, pitch))
		var best := maxi(int(cw[0][1]), int(cw[1][1]))
		var best_dc := maxi(int(cw[0][0]), int(cw[1][0]))
		var start := best
		for it in iters:
			var np := pos + Vector3(rng.randf_range(-12, 12), rng.randf_range(-6, 8), rng.randf_range(-12, 12))
			np.y = maxf(np.y, world.ground_height(np.x, np.z) + 2.0)
			if not _clear(np):
				continue
			var ny := yaw + deg_to_rad(rng.randf_range(-25, 25))
			var npi := clampf(pitch + deg_to_rad(rng.randf_range(-12, 12)), deg_to_rad(-60), deg_to_rad(30))
			var m: Array = await _warm(np, _look_dir(ny, npi))
			var v := maxi(int(m[0][1]), int(m[1][1]))
			for x: Array in m:
				if int(x[0]) > BUDGET_DRAWS or int(x[1]) > BUDGET_PRIMS:
					res["over_budget"] = int(res["over_budget"]) + 1
				res["worst_draw_calls"] = maxi(int(res["worst_draw_calls"]), int(x[0]))
			if v > best:
				best = v
				best_dc = maxi(int(m[0][0]), int(m[1][0]))
				pos = np
				yaw = ny
				pitch = npi
		res["worst_draw_calls"] = maxi(int(res["worst_draw_calls"]), best_dc)
		(res["paths"] as Array).append({"start_prims_walk": t[0], "start_prims_warm": start, "end_prims": best, "end_draws": best_dc,
			"end_pos": _arr(pos), "end_yaw_deg": snappedf(rad_to_deg(yaw), 0.1), "end_pitch_deg": snappedf(rad_to_deg(pitch), 0.1)})
		if best > int(res["worst_primitives"]):
			res["worst_primitives"] = best
			res["worst_at"] = {"pos": _arr(pos), "yaw_deg": snappedf(rad_to_deg(yaw), 0.1), "pitch_deg": snappedf(rad_to_deg(pitch), 0.1)}
		print("[world-verify3] climb from %s: walk %d, warm %d -> %d prims (%d draws)" % [_arr(Vector3(t[1][0], t[1][1], t[1][2])), t[0], start, best, best_dc])
	return res
