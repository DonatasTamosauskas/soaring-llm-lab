extends Node3D
## W7 render budgets on the Quest renderer, measured the hard way (the
## still views of `world_shots.gd --perf` teleport the camera, and
## visibility-range hysteresis makes a frame's cost depend on where the
## camera came from, so still views alone under-report the forest).
##
##   tools/gd.sh world --rendering-method mobile --resolution 1280x720 \
##       res://tests/shots/world_perf.tscn -- --mode=all
##
## Modes (all at 1280x720, 90 deg vertical FOV, far 3000 m, MSAA 4x, visible
## + shadow passes counted, the same protocol as world_shots --perf):
##   warm    300 random views, 200 of them in and around the forest (canopy
##           height from its rim, inside it, above it), each measured cold
##           (arriving from the far corner of the valley) and warm (after
##           circling 25 m around the point first, so every visibility range
##           is in its "was near" state, the most expensive one);
##   scan    head directions over the old wood: 25 positions x 4 heights x
##           12 yaws x 4 pitches = 4,800 views, measured in sequence;
##   flight  a continuous ~7 km flight at 2.5 m per frame: canopy skims from
##           every side of the wood, dives into it and climbs out, the
##           village, lake, mast, canyon, cliff, and 360-degree pans;
##   breakdown --at=x,y,z --look=x,y,z  where one warm view's primitives go;
##   all     warm + scan + flight -> artifacts/world/perf_budget_<renderer>.json
##
## Budget (ARCHITECTURE 7.4): <= 150 draw calls and <= 300k primitives. The
## world keeps a margin below that (TARGET_PRIMS) for the birds, wings and
## UI that the game adds on top.

const BUDGET_DRAWS := 150
const BUDGET_PRIMS := 300000
const TARGET_PRIMS := 270000

var world: SoaringWorld
var cam: Camera3D
var _vp: Viewport


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
	var mode := String(args.get("mode", "all"))
	var out := {"renderer": RenderingServer.get_current_rendering_method(),
		"resolution": [_vp.get_visible_rect().size.x, _vp.get_visible_rect().size.y],
		"fov": cam.fov, "far": cam.far, "msaa": "4x", "generation_ms": world.generation_ms,
		"budget": {"draw_calls": BUDGET_DRAWS, "primitives": BUDGET_PRIMS, "target_primitives": TARGET_PRIMS}}
	if mode == "breakdown":
		await _breakdown(_vec(String(args.get("at", "-276.6,16,-331.2"))), _vec(String(args.get("look", "-247.8,20,-290.4"))))
		get_tree().quit()
		return
	if mode in ["warm", "all"]:
		out["warm"] = await _warm(int(args.get("n", "300")))
	if mode in ["scan", "all"]:
		out["scan"] = await _scan()
	if mode in ["flight", "all"]:
		out["flight"] = await _flight()
	var worst_dc := 0
	var worst_pr := 0
	for k in ["warm", "scan", "flight"]:
		if out.has(k):
			worst_dc = maxi(worst_dc, int(out[k]["worst_draw_calls"]))
			worst_pr = maxi(worst_pr, int(out[k]["worst_primitives"]))
	out["worst_draw_calls"] = worst_dc
	out["worst_primitives"] = worst_pr
	out["within_budget"] = worst_dc <= BUDGET_DRAWS and worst_pr <= BUDGET_PRIMS
	out["within_target"] = worst_pr <= TARGET_PRIMS
	print("[world] perf %s: worst %d draw calls, %d primitives (budget %d / %d, target %d)" % [mode, worst_dc, worst_pr, BUDGET_DRAWS, BUDGET_PRIMS, TARGET_PRIMS])
	var path := Paths.artifacts("world").path_join("perf_%s_%s.json" % ["budget" if mode == "all" else mode, out["renderer"]])
	var fa := FileAccess.open(path, FileAccess.WRITE)
	fa.store_string(JSON.stringify(out, "  "))
	print("[world] perf -> ", path)
	# A gate, not just a report: over the budget fails the run (exit 1).
	print("[world] perf %s" % ("PASS: within budget" if out["within_budget"] else "FAIL: over budget"))
	get_tree().quit(0 if out["within_budget"] else 1)


static func _vec(s: String) -> Vector3:
	var p := s.split(",")
	return Vector3(float(p[0]), float(p[1]), float(p[2]))


func _g(x: float, z: float) -> float:
	return world.ground_height(x, z)


## [draw calls, primitives, visible primitives, shadow primitives] of the
## frame just rendered.
func _info() -> Array:
	var dc := _vp.get_render_info(Viewport.RENDER_INFO_TYPE_VISIBLE, Viewport.RENDER_INFO_DRAW_CALLS_IN_FRAME) \
		+ _vp.get_render_info(Viewport.RENDER_INFO_TYPE_SHADOW, Viewport.RENDER_INFO_DRAW_CALLS_IN_FRAME)
	var vis := _vp.get_render_info(Viewport.RENDER_INFO_TYPE_VISIBLE, Viewport.RENDER_INFO_PRIMITIVES_IN_FRAME)
	var sh := _vp.get_render_info(Viewport.RENDER_INFO_TYPE_SHADOW, Viewport.RENDER_INFO_PRIMITIVES_IN_FRAME)
	return [dc, vis + sh, vis, sh]


func _place(pos: Vector3, look: Vector3) -> void:
	if (look - pos).normalized().abs().y > 0.98:
		look += Vector3(0.3, 0.0, 0.0)
	cam.look_at_from_position(pos, look, Vector3.UP)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


## Cold: arrive from the far corner of the valley. Warm: circle the point
## at 25 m first (every nearby visibility range flips to "near" and stays
## there inside its hysteresis margin), then come back.
func _measure_cold_warm(pos: Vector3, look: Vector3) -> Array:
	_place(Vector3(560, 250, 560), Vector3.ZERO)
	await _frames(3)
	_place(pos, look)
	await _frames(5)
	var cold := _info()
	for k in 8:
		var a := TAU * k / 8.0
		_place(pos + Vector3(cos(a) * 25.0, 0.0, sin(a) * 25.0), look)
		await _frames(2)
	_place(pos, look)
	await _frames(5)
	return [cold, _info()]


func _warm(n: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7070
	var views: Array = []
	var fc := WorldLayout.FOREST
	# In and around the forest: 80 at canopy height from its rim looking
	# in (the view a bird skimming the wood has), 70 anywhere over the wood
	# at 2-60 m with a random heading, 50 on the core's edge looking across.
	while views.size() < 200:
		var k := views.size()
		var p: Vector2
		var h: float
		var look: Vector3
		if k < 80:
			var a := rng.randf() * TAU
			p = fc + Vector2.from_angle(a) * rng.randf_range(WorldLayout.FOREST_CORE_R * 0.6, WorldLayout.FOREST_R + 20.0)
			h = rng.randf_range(10.0, 26.0)
			var tgt := fc + Vector2.from_angle(rng.randf() * TAU) * rng.randf_range(0.0, 60.0)
			look = Vector3(tgt.x, _g(tgt.x, tgt.y) + rng.randf_range(4.0, 26.0), tgt.y)
		elif k < 150:
			p = fc + Vector2.from_angle(rng.randf() * TAU) * sqrt(rng.randf()) * (WorldLayout.FOREST_R + 30.0)
			h = rng.randf_range(2.0, 60.0)
			var yaw := rng.randf() * TAU
			var pitch := deg_to_rad(rng.randf_range(-35.0, 25.0))
			look = Vector3(p.x, 0, p.y) + Vector3(cos(yaw) * cos(pitch), 0.0, sin(yaw) * cos(pitch)) * 50.0
			look.y = _g(p.x, p.y) + h + sin(pitch) * 50.0
		else:
			var a2 := rng.randf() * TAU
			p = fc + Vector2.from_angle(a2) * rng.randf_range(WorldLayout.FOREST_CORE_R - 10.0, WorldLayout.FOREST_CORE_R + 30.0)
			h = rng.randf_range(4.0, 40.0)
			var across := fc - Vector2.from_angle(a2) * rng.randf_range(0.0, WorldLayout.FOREST_CORE_R)
			look = Vector3(across.x, _g(across.x, across.y) + rng.randf_range(0.0, 20.0), across.y)
		var pos := Vector3(p.x, _g(p.x, p.y) + h, p.y)
		views.append(["forest_%03d" % k, pos, look])
	# Anywhere in the valley.
	while views.size() < n:
		var p := Vector2.from_angle(rng.randf() * TAU) * sqrt(rng.randf()) * (world.bounds_radius - 20.0)
		var y := _g(p.x, p.y) + rng.randf_range(2.0, 150.0)
		if y > world.ceiling - 5.0:
			continue
		var yaw := rng.randf() * TAU
		var pitch := deg_to_rad(rng.randf_range(-35.0, 15.0))
		var pos := Vector3(p.x, y, p.y)
		views.append(["any_%03d" % views.size(), pos, pos + Vector3(cos(yaw) * cos(pitch), sin(pitch), sin(yaw) * cos(pitch)) * 50.0])
	var res := {"views": views.size(), "worst_draw_calls": 0, "worst_primitives": 0, "worst_at": "", "over_budget": 0, "over_target": 0, "detail": {}}
	for v in views:
		var cw: Array = await _measure_cold_warm(v[1], v[2])
		res["detail"][v[0]] = {"camera": _arr(v[1]), "look": _arr(v[2]), "cold": cw[0], "warm": cw[1]}
		for m: Array in cw:
			_tally(res, m, "%s %s" % [v[0], (v[1] as Vector3).snapped(Vector3.ONE * 0.1)])
	print("[world] perf warm: %d views x cold/warm, worst %d draw calls, %d primitives at %s; %d over budget, %d over target" % [
		views.size(), res["worst_draw_calls"], res["worst_primitives"], res["worst_at"], res["over_budget"], res["over_target"]])
	return res


static func _arr(v: Vector3) -> Array:
	return [snappedf(v.x, 0.1), snappedf(v.y, 0.1), snappedf(v.z, 0.1)]


func _tally(res: Dictionary, m: Array, at: String) -> void:
	res["worst_draw_calls"] = maxi(int(res["worst_draw_calls"]), int(m[0]))
	if int(m[1]) > int(res["worst_primitives"]):
		res["worst_primitives"] = int(m[1])
		res["worst_at"] = at
		res["worst_split"] = {"visible": m[2], "shadow": m[3]}
	if int(m[0]) > BUDGET_DRAWS or int(m[1]) > BUDGET_PRIMS:
		res["over_budget"] = int(res["over_budget"]) + 1
	if int(m[1]) > TARGET_PRIMS:
		res["over_target"] = int(res["over_target"]) + 1


## Every head direction a VR player can take in and over the old wood (the
## densest place in the valley): the round-2 verifier's scan, kept here.
func _scan() -> Dictionary:
	var res := {"views": 0, "worst_draw_calls": 0, "worst_primitives": 0, "worst_at": "", "over_budget": 0, "over_target": 0}
	var c := WorldLayout.FOREST
	var prims: Array = []
	for gx in range(-2, 3):
		for gz in range(-2, 3):
			var x := c.x + gx * 20.0
			var z := c.y + gz * 20.0
			for h: float in [4.0, 10.0, 18.0, 30.0]:
				var p := Vector3(x, _g(x, z) + h, z)
				for yi in 12:
					var yaw := TAU * yi / 12.0
					for pitch_deg: float in [-20.0, 0.0, 20.0, 40.0]:
						var pt := deg_to_rad(pitch_deg)
						_place(p, p + Vector3(cos(yaw) * cos(pt), sin(pt), sin(yaw) * cos(pt)))
						await _frames(2)
						var m := _info()
						res["views"] = int(res["views"]) + 1
						prims.append(m[1])
						_tally(res, m, "%s yaw %d pitch %d" % [p.snapped(Vector3.ONE * 0.1), int(rad_to_deg(yaw)), int(pitch_deg)])
	prims.sort()
	res["p50_primitives"] = prims[prims.size() / 2]
	res["p99_primitives"] = prims[int(prims.size() * 0.99)]
	print("[world] perf scan: %d views, worst %d draw calls, %d primitives at %s (p99 %d); %d over budget, %d over target" % [
		res["views"], res["worst_draw_calls"], res["worst_primitives"], res["worst_at"], res["p99_primitives"], res["over_budget"], res["over_target"]])
	return res


## Waypoints: Vector3 = fly there (looking ahead, slightly down); ["pan",
## pitch] = turn 360 degrees in place.
func _route() -> Array:
	var r: Array = []
	var fc := WorldLayout.FOREST
	var gp := func(x: float, z: float, h: float) -> Vector3: return Vector3(x, _g(x, z) + h, z)
	r.append(world.get_player_spawn().origin + Vector3(0, 0.3, 0))
	r.append(gp.call(-90, 48, 20))
	r.append(Vector3(-160, 30, -150))
	# Canopy skims into the wood from every side, then down into the core
	# and back up out of it (the round-2 verifiers' worst cases).
	for a_deg: float in [45.0, 100.0, 160.0, 220.0, 280.0, 340.0]:
		var a := deg_to_rad(a_deg)
		var rim := fc + Vector2.from_angle(a) * (WorldLayout.FOREST_R + 25.0)
		var edge := fc + Vector2.from_angle(a) * (WorldLayout.FOREST_CORE_R + 10.0)
		r.append(gp.call(rim.x, rim.y, 16.0))
		r.append(gp.call(edge.x, edge.y, 14.0))
		r.append(gp.call(fc.x, fc.y, 5.0))
		r.append(gp.call(edge.x - (fc.x - edge.x) * 0.1, edge.y, 12.0))
	r.append(gp.call(-300, -300, 4))
	r.append(gp.call(-262, -258, 60))
	r.append(["pan", -0.25])
	r.append(gp.call(-298.8, -298.7, 10.6))
	r.append(gp.call(-276.6, -331.2, 16.0))
	r.append(gp.call(-247.8, -290.4, 20.0))
	r.append(["pan", 0.1])
	r.append(gp.call(-150, -120, 12))
	r.append(gp.call(-60, 40, 5))
	r.append(gp.call(20, 40, 5))
	r.append(gp.call(110, 150, 8))
	r.append(Vector3(290, 12, 250))
	r.append(Vector3(468, 60, 110))
	r.append(Vector3(335, 40, -140))
	r.append(Vector3(135, 20, -380))
	r.append(Vector3(160, 40, -470))
	r.append(Vector3(0, 280, 0))
	r.append(["pan", -0.25])
	r.append(Vector3(-400, 40, 120))
	r.append(gp.call(-420, -250, 20))
	r.append(gp.call(-262, -258, 20))
	r.append(["pan", -0.25])
	return r


func _flight() -> Dictionary:
	var res := {"frames": 0, "worst_draw_calls": 0, "worst_primitives": 0, "worst_at": "", "over_budget": 0, "over_target": 0}
	var prims: Array = []
	var step := 2.5
	var prev := Vector3.INF
	for wp in _route():
		if wp is Array:
			var c := cam.global_position
			for a in 72:
				var yaw := TAU * a / 72.0
				_place(c, c + Vector3(cos(yaw), float(wp[1]), sin(yaw)))
				await _frames(1)
				var m := _info()
				prims.append(m[1])
				res["frames"] = int(res["frames"]) + 1
				_tally(res, m, "pan %s" % c.snapped(Vector3.ONE * 0.1))
			continue
		var target: Vector3 = wp
		if prev == Vector3.INF:
			_place(target, target + Vector3(1, 0, 0))
			prev = target
			await _frames(4)
			continue
		var n := maxi(1, int(ceil(prev.distance_to(target) / step)))
		var ahead := (target - prev).normalized()
		for k in n:
			var p := prev.lerp(target, float(k + 1) / n)
			_place(p, p + ahead * 10.0 + Vector3(0, -1.5, 0))
			await _frames(1)
			var m := _info()
			prims.append(m[1])
			res["frames"] = int(res["frames"]) + 1
			_tally(res, m, "leg %s" % p.snapped(Vector3.ONE * 0.1))
		prev = target
	prims.sort()
	res["p50_primitives"] = prims[prims.size() / 2]
	res["p99_primitives"] = prims[int(prims.size() * 0.99)]
	print("[world] perf flight: %d frames, worst %d draw calls, %d primitives at %s (p99 %d); %d over budget, %d over target" % [
		res["frames"], res["worst_draw_calls"], res["worst_primitives"], res["worst_at"], res["p99_primitives"], res["over_budget"], res["over_target"]])
	return res


## Primitives of one warm view with each category of visual mesh hidden in
## turn: what the budget is spent on.
func _breakdown(pos: Vector3, look: Vector3) -> void:
	var cw: Array = await _measure_cold_warm(pos, look)
	print("[world] breakdown at %s -> %s: cold %s warm %s" % [pos, look, cw[0], cw[1]])
	var cats := {}
	for n in world.get_node("Visual").get_children():
		var nm := String(n.name)
		var cat := nm
		for pre in ["trees_shadowfar_", "trees_shadow_", "trees_lod_", "trees_far_", "trees_", "terrain_", "hedges_lod_", "hedges_", "backdrop", "water"]:
			if nm.begins_with(pre):
				cat = pre
				break
		if not cats.has(cat):
			cats[cat] = []
		cats[cat].append(n)
	for cat in cats:
		# Re-warm before every category: showing a hidden node again resets
		# its visibility-range hysteresis, which would skew the next reading.
		var base: Array = (await _measure_cold_warm(pos, look))[1]
		for n in cats[cat]:
			(n as Node3D).visible = false
		await _frames(3)
		var m := _info()
		for n in cats[cat]:
			(n as Node3D).visible = true
		var saved := int(base[1]) - int(m[1])
		if saved > 500:
			print("[world]   %-22s %7d prims (%6d visible, %6d shadow), %3d draws" % [cat, saved, int(base[2]) - int(m[2]), int(base[3]) - int(m[3]), int(base[0]) - int(m[0])])
	await _frames(3)
