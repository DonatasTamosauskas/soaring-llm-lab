class_name SoaringWorld
extends World
## The valley: a closed arena ~1.36 km across (mountain ring + invisible
## boundary + 300 m ceiling) with a village, farm, power-line corridor,
## forest, orchard, hedgerows, lake and river with an arched bridge, a cliff
## with a swallow colony, a canyon with a rock arch, a water tower, a radio
## mast and nest boxes, plus thermals and ridge lift.
##
## Everything is generated in _ready from world_seed (deterministic: the
## district plan is fixed in WorldLayout, the seed varies the details).
## Root of scenes/world/world.tscn.

## Lighting preset from Palette.LIGHT ("day", "dusk").
@export var lighting: StringName = &"day"
## Build the environment (sky, sun, fog). Off when a host scene brings its own.
@export var with_environment := true
## Build soft decoration (grass, flowers, reeds, clouds, motes).
@export var with_decoration := true

var terrain: WorldTerrain
var wind: WindField
var build: WorldBuild
var environment_node: WorldEnvironment
var sun: DirectionalLight3D
var motes: ThermalMotes
## Generation time and per-step breakdown (ms).
var generation_ms := 0.0
var timings := {}

var _landmarks: Array[Dictionary] = []
var _refuges: Array[Dictionary] = []
var _spawn := Transform3D(Basis.IDENTITY, Vector3(0, 30, 0))
var _time := 0.0
var _perch_grid := {}
const PERCH_CELL := 48.0
## What perch validation kept, shrank and dropped (see _validate_perches).
var perch_report := {}
## Measured rock-arch passages (see _measure_openings).
var opening_report := {}
## The 16 final-approach directions a perch is tried from (built once).
static var _approach_dirs: Array[Vector3] = []


func _generate() -> void:
	bounds_radius = WorldLayout.BOUNDS
	ceiling = WorldLayout.CEILING
	var t_all := Time.get_ticks_usec()
	var t := t_all
	var visual := _child_node("Visual")
	var bodies := _child_node("Bodies")
	var soft := _child_node("Soft")

	if with_environment:
		environment_node = WorldEnvironment.new()
		environment_node.name = "Environment"
		environment_node.environment = WorldSky.make_environment(lighting)
		add_child(environment_node)
		sun = WorldSky.make_sun(lighting)
		add_child(sun)

	terrain = WorldTerrain.new(world_seed)
	_prepare_crops()
	terrain.generate()
	t = _lap("terrain_heights", t)
	terrain.build(visual, bodies, Palette.solid_material())
	terrain.build_water(visual, bodies)
	terrain.build_backdrop(visual, bodies, Palette.solid_material())
	t = _lap("terrain_meshes", t)

	wind = WindField.new(world_seed)
	wind.build(terrain)
	t = _lap("wind", t)

	build = WorldBuild.new(world_seed, terrain, wind)
	build.visual_root = visual
	build.body_root = bodies
	build.soft_root = soft
	for step in [
		["village", VillageBuilder.build],
		["farm", FarmBuilder.build],
		["rocks", RockBuilder.build],
		["powerline", PowerLineBuilder.build],
		["flora", FloraBuilder.build],
		["props", PropsBuilder.build],
	]:
		(step[1] as Callable).call(build)
		t = _lap(step[0], t)
		if step[0] == "rocks":
			# The cliff and canyon walls are ground (the arches, like bridges
			# and buildings, are things you fly under).
			for kname in ["cliff", "canyon"]:
				terrain.add_rock((build.kits[kname] as MeshKit).faces)
			t = _lap("rock_ground", t)

	var committed := {}
	for kname in build.kit_order:
		var k: MeshKit = build.kits[kname]
		var mat: Material = Palette.foliage_material() if build.foliage_kits.has(kname) else Palette.solid_material()
		if kname == "street":
			# Paving over the ground wins its depth ties (Palette.paving_material).
			mat = Palette.paving_material()
		var has_lod := build.lod_of.has(kname) or build.lod_kits.has(kname)
		committed[kname] = k.commit(visual, bodies, mat, 1, not build.no_shadow_kits.has(kname), has_lod)
	# Wire distance LODs: the full kit hides beyond dist, its stand-in shows.
	for lname in build.lod_kits:
		var info: Dictionary = build.lod_kits[lname]
		var full: Dictionary = committed.get(info["full"], {})
		var lod: Dictionary = committed.get(lname, {})
		if full.has("mesh"):
			(full["mesh"] as GeometryInstance3D).visibility_range_end = info["dist"]
			(full["mesh"] as GeometryInstance3D).visibility_range_end_margin = 10.0
		if lod.has("mesh"):
			var mi: GeometryInstance3D = lod["mesh"]
			mi.visibility_range_begin = info["dist"]
			mi.visibility_range_begin_margin = 10.0
			if full.has("body"):
				mi.set_meta(&"collider", full["body"])
	# Kits that cast their shadows from their stand-in (see shadow_proxy).
	for fname in build.shadow_proxy:
		var full: Dictionary = committed.get(fname, {})
		var lod: Dictionary = committed.get(build.shadow_proxy[fname], {})
		if full.has("mesh") and lod.has("mesh"):
			(full["mesh"] as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			var src: MeshInstance3D = lod["mesh"]
			var sh := MeshInstance3D.new()
			sh.name = String(fname) + "_shadow"
			sh.mesh = src.mesh
			sh.material_override = src.material_override
			sh.position = src.position
			sh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
			sh.set_meta(&"shadow_only", true)
			visual.add_child(sh)
	# Nest boxes hang on trunks and poles against the committed colliders.
	var n_kits := build.kit_order.size()
	PropsBuilder.build_mounted(build)
	for i in range(n_kits, build.kit_order.size()):
		var kname := build.kit_order[i]
		(build.kits[kname] as MeshKit).commit(visual, bodies, Palette.solid_material(), 1, not build.no_shadow_kits.has(kname), false)
	t = _lap("commit", t)

	if with_decoration:
		SoftDecor.build(build)
		WorldSky.build_clouds(soft, world_seed, lighting)
		motes = ThermalMotes.new()
		motes.setup(wind, world_seed)
		motes.set_lighting(lighting)
		soft.add_child(motes)
		t = _lap("decoration", t)

	_build_boundary()
	_measure_openings()
	_validate_perches()
	t = _lap("perch_validate", t)
	_perches = build.perches
	_landmarks = build.landmarks
	_refuges = build.refuges
	_habitat_landmarks()
	for i in wind.thermal_count():
		var th: Dictionary = wind.thermals()[i]
		_landmarks.append({"name": "thermal_" + String(th["name"]), "kind": "thermal",
			"position": th["position"], "radius": float(th["radius"]) + WindField.DRIFT, "top": th["top"]})
	_index_perches()
	_choose_spawn()
	t = _lap("index", t)
	generation_ms = (Time.get_ticks_usec() - t_all) / 1000.0
	timings.merge(build.timings)
	print("[world] generated seed %d in %.0f ms: %d perches, %d landmarks (%d openings), %d refuges, %d kits" % [
		world_seed, generation_ms, _perches.size(), _landmarks.size(),
		_landmarks.filter(func(l: Dictionary) -> bool: return l["kind"] == "opening").size(),
		_refuges.size(), build.kits.size()])


## Coarse habitats for AI and the tutorial: water, fields, the meadow,
## hedgerows and roosts (in addition to what each builder registered).
func _habitat_landmarks() -> void:
	var lk := WorldLayout.LAKE
	build.add_landmark("lake", "lake", Vector3(lk.x, WorldLayout.WATER_Y, lk.y), WorldLayout.LAKE_R.x)
	var mc := WorldLayout.MEADOW
	build.add_landmark("meadow", "meadow", Vector3(mc.x, terrain.height_at(mc.x, mc.y), mc.y), WorldLayout.MEADOW_CLEAR)
	build.add_landmark("meadow_field", "field", Vector3(mc.x, terrain.height_at(mc.x, mc.y), mc.y), WorldLayout.MEADOW_CLEAR)
	var nx := int(ceil(WorldLayout.FIELDS_SIZE.x / WorldLayout.FIELDS_CELL.x))
	for c in terrain.south_crops:
		var ctr := WorldLayout.FIELDS_ORIGIN + Vector2((c % nx + 0.5) * WorldLayout.FIELDS_CELL.x, (c / nx + 0.5) * WorldLayout.FIELDS_CELL.y)
		build.add_landmark("field_%d" % c, "field", Vector3(ctr.x, terrain.height_at(ctr.x, ctr.y), ctr.y), WorldLayout.FIELDS_CELL.y * 0.5,
			{"crop": String(terrain.south_crops[c])})
	for l in build.landmarks.duplicate():
		match String(l["kind"]):
			"hedgerow":
				build.add_landmark("hedges", "hedge", l["position"], l["radius"])
			"tower", "forest", "orchard", "glade":
				build.add_landmark(String(l["name"]) + "_roost", "roost", l["position"], l["radius"])


func _lap(key: String, t0: int) -> int:
	var now := Time.get_ticks_usec()
	timings[key] = (now - t0) / 1000.0
	return now


func _child_node(n: String) -> Node3D:
	var node := Node3D.new()
	node.name = n
	add_child(node)
	return node


func _process(_delta: float) -> void:
	# Far terrain chunks follow the camera (see WorldTerrain.update_lod).
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	if terrain and cam:
		terrain.update_lod(cam.global_position)


func _physics_process(delta: float) -> void:
	if wind:
		_time += delta
		wind.update(_time)


## Field crops: seeded, except that patches under a thermal get the warm
## ground the thermal is sited on (wheat or ploughed soil).
func _prepare_crops() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = world_seed * 131 + 9
	var crops := [&"wheat", &"field_green", &"ploughed", &"wheat_dark", &"meadow", &"field_green"]
	var nx := int(ceil(WorldLayout.FIELDS_SIZE.x / WorldLayout.FIELDS_CELL.x))
	var ny := int(ceil(WorldLayout.FIELDS_SIZE.y / WorldLayout.FIELDS_CELL.y))
	# Only whole patches well inside the valley become fields (their edges
	# stay on grid lines); the rest of the grid is plain grass.
	for c in nx * ny:
		var crop: StringName = crops[rng.randi() % crops.size()]
		var ctr := WorldLayout.FIELDS_ORIGIN + Vector2((c % nx + 0.5) * WorldLayout.FIELDS_CELL.x, (c / nx + 0.5) * WorldLayout.FIELDS_CELL.y)
		if ctr.length() < 470.0:
			terrain.south_crops[c] = crop
	var ex := int(ceil(WorldLayout.EAST_FIELDS_SIZE.x / WorldLayout.EAST_FIELDS_CELL.x))
	var ey := int(ceil(WorldLayout.EAST_FIELDS_SIZE.y / WorldLayout.EAST_FIELDS_CELL.y))
	for c in ex * ey:
		var crop: StringName = crops[rng.randi() % crops.size()]
		var ctr := WorldLayout.EAST_FIELDS_ORIGIN + Vector2((c % ex + 0.5) * WorldLayout.EAST_FIELDS_CELL.x, (c / ex + 0.5) * WorldLayout.EAST_FIELDS_CELL.y)
		if ctr.length() < 470.0:
			terrain.east_crops[c] = crop
	for th in WorldLayout.THERMALS:
		var p: Vector2 = th["pos"]
		var g: StringName = th["ground"]
		var key: StringName = &"wheat" if g == &"wheat" else (&"ploughed" if g == &"ploughed" else &"")
		if key == &"":
			continue
		var c := WorldLayout.field_cell(p.x, p.y, WorldLayout.FIELDS_ORIGIN, WorldLayout.FIELDS_SIZE, WorldLayout.FIELDS_CELL, WorldLayout.FIELDS_ROT)
		if c >= 0 and terrain.south_crops.has(c):
			terrain.south_crops[c] = key
		c = WorldLayout.field_cell(p.x, p.y, WorldLayout.EAST_FIELDS_ORIGIN, WorldLayout.EAST_FIELDS_SIZE, WorldLayout.EAST_FIELDS_CELL, 0.0)
		if c >= 0 and terrain.east_crops.has(c):
			terrain.east_crops[c] = key


## The arena's hard edge: a ring of tall boxes whose inner faces sit exactly
## at bounds_radius, and a lid at the ceiling. Invisible; the mountain ring
## is what the player sees, this is what makes "closed" a guarantee.
func _build_boundary() -> void:
	var body := StaticBody3D.new()
	body.name = "Boundary"
	body.collision_mask = 0
	add_child(body)
	var segs := 96
	var r := bounds_radius
	var half_w := r * tan(PI / segs) + 1.0
	var h := ceiling + 80.0
	var thick := 6.0
	for i in segs:
		var ang := TAU * (float(i) + 0.5) / segs
		var dir := Vector3(cos(ang), 0.0, sin(ang))
		var box := BoxShape3D.new()
		box.size = Vector3(half_w * 2.0, h, thick)
		var basis := Basis.looking_at(-dir, Vector3.UP)
		var o := body.create_shape_owner(body)
		body.shape_owner_add_shape(o, box)
		body.shape_owner_set_transform(o, Transform3D(basis, dir * (r + thick * 0.5) + Vector3(0, h * 0.5 - 40.0, 0)))
	var lid := BoxShape3D.new()
	lid.size = Vector3(r * 2.4, 10.0, r * 2.4)
	var ol := body.create_shape_owner(body)
	body.shape_owner_add_shape(ol, lid)
	body.shape_owner_set_transform(ol, Transform3D(Basis.IDENTITY, Vector3(0, ceiling + 5.0, 0)))


func _index_perches() -> void:
	_perch_grid.clear()
	for i in _perches.size():
		var p := _perches[i]
		var key := Vector2i(floori(p.position.x / PERCH_CELL), floori(p.position.z / PERCH_CELL))
		# Packed arrays copy on write: fetch, append, store back.
		var arr: PackedInt32Array = _perch_grid.get(key, PackedInt32Array())
		arr.append(i)
		_perch_grid[key] = arr


## Every perch must sit on real geometry with room for its bird: a short ray
## finds the surface (and snaps to it), then a body-sized sphere must fit
## above it. Too-tight perches are shrunk to the largest bird that fits, or
## dropped. Counts are reported in stats() so pruning is never silent.
func _validate_perches() -> void:
	var space := get_world_3d().direct_space_state
	var sphere := SphereShape3D.new()
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = sphere
	q.collision_mask = 1
	var k := WorldBuild.body_k()
	var kept: Array[Perch] = []
	var dropped_support := 0
	var dropped_clear := 0
	var shrunk := 0
	var dropped_where := {}
	for p in build.perches:
		# Short probe first (thin wires and twigs), then a longer one for
		# rough surfaces (rock rims, bumpy tops) whose exact height the
		# builder only estimated.
		var rq := PhysicsRayQueryParameters3D.create(p.position + Vector3.UP * 0.12, p.position + Vector3.DOWN * 0.12)
		rq.collision_mask = 1
		var hit := space.intersect_ray(rq)
		if hit.is_empty():
			rq = PhysicsRayQueryParameters3D.create(p.position + Vector3.UP * 0.8, p.position + Vector3.DOWN * 0.8)
			rq.collision_mask = 1
			hit = space.intersect_ray(rq)
		if hit.is_empty() or (hit["normal"] as Vector3).y < 0.3:
			dropped_support += 1
			dropped_where[p.district] = dropped_where.get(p.district, 0) + 1
			continue
		p.position = hit["position"]
		var span := p.max_span
		var approach_fails := 0
		while span >= 0.15:
			var r := span * k
			sphere.radius = r
			var body := p.position + Vector3.UP * (r + 0.02)
			q.transform = Transform3D(Basis.IDENTITY, body)
			q.motion = Vector3.ZERO
			if not space.intersect_shape(q, 1).is_empty():
				span *= 0.85
				continue
			if _approachable(space, q, body, r):
				break
			# Boxed in: try a much smaller bird, twice, then give up.
			approach_fails += 1
			span = span * 0.6 if approach_fails < 3 else 0.0
		if span < 0.15:
			dropped_clear += 1
			continue
		if span < p.max_span:
			shrunk += 1
		p.max_span = span
		kept.append(p)
	perch_report = {"proposed": build.perches.size(), "kept": kept.size(), "dropped_no_support": dropped_support,
		"dropped_no_clearance": dropped_clear, "shrunk": shrunk, "dropped_by_district": dropped_where}
	build.perches = kept


## Rock arches are irregular (jittered sweeps between jagged walls), so
## their rating is measured on the built colliders, not assumed: rays from
## the nominal centre find the clear gap, the opening is re-centred in it,
## and bisection with sphere casts finds the largest body that flies the
## whole passage. The rating keeps the usual 20% margin (span_for_gap).
func _measure_openings() -> void:
	var space := get_world_3d().direct_space_state
	var k := WorldBuild.body_k()
	var sphere := SphereShape3D.new()
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = sphere
	q.collision_mask = 1
	for o in build.landmarks:
		if o["kind"] != "opening" or not o.get("measure", false):
			continue
		var n: Vector3 = o["normal"]
		var up: Vector3 = o["up"]
		var right := up.cross(n).normalized()
		var p: Vector3 = o["position"]
		var ext := [0.0, 0.0, 0.0, 0.0]
		for it in 3:
			var c := p - n * 0.008
			for d in 4:
				var dir: Vector3 = [right, -right, up, -up][d]
				var rq := PhysicsRayQueryParameters3D.create(c, c + dir * 120.0)
				rq.collision_mask = 1
				var hit := space.intersect_ray(rq)
				ext[d] = 120.0 if hit.is_empty() else c.distance_to(hit["position"])
			if it < 2:
				p += right * (ext[0] - ext[1]) * 0.5 + up * (ext[2] - ext[3]) * 0.5
		var depth: float = o["depth"]
		var lo := 0.0
		var hi := maxf(ext[0] + ext[1], ext[2] + ext[3])
		for it in 20:
			var r := (lo + hi) * 0.5
			sphere.radius = r
			q.transform = Transform3D(Basis.IDENTITY, p + n * (r + 1.0))
			q.motion = Vector3.ZERO
			# A body fits if it starts clear (a cast ignores what it already
			# overlaps) and then flies the whole passage untouched.
			var clear := space.intersect_shape(q, 1).is_empty()
			if clear:
				q.motion = -n * (r + 1.0 + depth)
				clear = space.cast_motion(q)[0] >= 1.0
			if clear:
				lo = r
			else:
				hi = r
		var nominal: float = o["max_span"]
		o["position"] = p
		o["width"] = ext[0] + ext[1]
		o["height"] = ext[2] + ext[3]
		o["max_span"] = lo / (k * 1.2)
		opening_report[o["name"]] = {"nominal_span": nominal, "measured_span": o["max_span"], "clear_radius": lo,
			"width": o["width"], "height": o["height"]}
	# Refuges reached through measured openings (the belfry): the largest
	# body that flies in through one of them (straight through the opening
	# to 1 m inside, then straight to the refuge) and fits there.
	var by_name := {}
	for o in build.landmarks:
		if o["kind"] == "opening":
			by_name[o["name"]] = o
	for rf in build.refuges:
		if not rf.has("measure_from"):
			continue
		var target: Vector3 = rf["position"]
		var lo := 0.0
		var hi := 2.0
		for it in 18:
			var r := (lo + hi) * 0.5
			sphere.radius = r
			var ok := false
			for oname in rf["measure_from"]:
				var o: Dictionary = by_name.get(oname, {})
				if o.is_empty():
					continue
				var n: Vector3 = o["normal"]
				var p: Vector3 = o["position"]
				var legs := [[p + n * (r + 1.0), p - n * 1.0], [p - n * 1.0, target]]
				var clear := true
				for leg in legs:
					q.transform = Transform3D(Basis.IDENTITY, leg[0])
					q.motion = Vector3.ZERO
					if not space.intersect_shape(q, 1).is_empty():
						clear = false
						break
					q.motion = (leg[1] as Vector3) - (leg[0] as Vector3)
					if space.cast_motion(q)[0] < 1.0:
						clear = false
						break
				q.motion = Vector3.ZERO
				if clear:
					q.transform = Transform3D(Basis.IDENTITY, target)
					clear = space.intersect_shape(q, 1).is_empty()
				if clear:
					ok = true
					break
			if ok:
				lo = r
			else:
				hi = r
		var nominal: float = rf["max_span"]
		rf["max_span"] = lo / (k * 1.2)
		rf.erase("measure_from")
		opening_report[String(rf["name"]) + "_refuge"] = {"nominal_span": nominal, "measured_span": rf["max_span"], "clear_radius": lo}


## A perch is only usable if its bird can fly onto it AND off again: a clear
## 2.5 m final approach for the body from at least one of 16 directions
## (twelve all round, gently descending; four steep, from above), flown both
## ways. The start must be clear too: a cast ignores shapes it begins inside.
## Why both ways: trimesh faces only stop what meets their front, so a perch
## boxed in by inward-facing faces (round 3's inside-out cliff shelves) has
## a clear way in and no way out; flying the same line back catches it.
func _approachable(space: PhysicsDirectSpaceState3D, q: PhysicsShapeQueryParameters3D, body: Vector3, r: float) -> bool:
	if _approach_dirs.is_empty():
		for a in 16:
			var el := 0.3 if a < 12 else 1.4
			var h := Vector3.FORWARD.rotated(Vector3.UP, TAU * a / (12.0 if a < 12 else 4.0))
			_approach_dirs.append((h + Vector3.UP * el).normalized())
	var dist := 2.5 + r
	for d in _approach_dirs:
		var start := body + d * dist
		q.transform = Transform3D(Basis.IDENTITY, start)
		q.motion = Vector3.ZERO
		if not space.intersect_shape(q, 1).is_empty():
			continue
		q.motion = body - start
		# Stop 1 cm short: the body touches the perch surface at the end.
		if space.cast_motion(q)[0] < 0.99:
			continue
		# And back out along the same line.
		q.transform = Transform3D(Basis.IDENTITY, body)
		q.motion = start - body
		if space.cast_motion(q)[0] >= 1.0:
			q.motion = Vector3.ZERO
			return true
	q.motion = Vector3.ZERO
	return false


func _choose_spawn() -> void:
	var hint: Vector3 = build.get_meta(&"spawn_hint", Vector3(0, 0, 0))
	var best: Perch = null
	for p in _perches:
		if p.kind == Perch.Kind.ROOF and p.max_span >= 1.0 and Vector2(p.position.x - hint.x, p.position.z - hint.z).length() < 30.0:
			if best == null or p.position.y > best.position.y:
				best = p
	if best == null:
		return
	# Face down the street toward the bridge and lake (east).
	var fwd := Vector3(1, 0, 0.25).normalized()
	_spawn = Transform3D(Basis.looking_at(fwd, Vector3.UP), best.position)


# --- World API ---------------------------------------------------------

func get_wind(pos: Vector3) -> Vector3:
	return wind.wind_at(pos)


## The solid ground under (x, z): the terrain, the water surface, and the
## rock masses that stand on the floor (the west cliff and the canyon
## walls). Free-standing things you can fly under or around are not ground:
## buildings, trees, props, boulders, the bridge and the two rock arches.
## Under an overhanging rock face the ground is the floor below it (the air
## in front of the swallow band is flyable), see WorldTerrain.rock_ground_at.
func ground_height(x: float, z: float) -> float:
	var floor_y := maxf(terrain.height_at(x, z), WorldLayout.WATER_Y)
	return maxf(floor_y, terrain.rock_ground_at(x, z, floor_y))


## The lake and the river: pos within WATER_BAND of the water line where
## the terrain lies under it (the water surface bobs +-0.14 m, WATER_SHADER).
func is_water(pos: Vector3) -> bool:
	if absf(pos.y - WorldLayout.WATER_Y) > WATER_BAND:
		return false
	return terrain.height_at(pos.x, pos.z) < WorldLayout.WATER_Y - 0.02


const WATER_BAND := 0.35


func find_perches(pos: Vector3, radius: float, span: float) -> Array[Perch]:
	var out: Array[Perch] = []
	var r2 := radius * radius
	var i0 := floori((pos.x - radius) / PERCH_CELL)
	var i1 := floori((pos.x + radius) / PERCH_CELL)
	var j0 := floori((pos.z - radius) / PERCH_CELL)
	var j1 := floori((pos.z + radius) / PERCH_CELL)
	if (i1 - i0 + 1) * (j1 - j0 + 1) > _perch_grid.size():
		return super.find_perches(pos, radius, span)
	for j in range(j0, j1 + 1):
		for i in range(i0, i1 + 1):
			var cell: Variant = _perch_grid.get(Vector2i(i, j))
			if cell == null:
				continue
			for idx in cell:
				var p := _perches[idx]
				if p.is_free() and p.fits(span) and p.position.distance_squared_to(pos) <= r2:
					out.append(p)
	return out


func get_player_spawn() -> Transform3D:
	return _spawn


func get_landmarks() -> Array[Dictionary]:
	return _landmarks


func get_refuges() -> Array[Dictionary]:
	return _refuges


func get_thermals() -> Array[Dictionary]:
	return wind.thermals()


## Switches the light (sky, sun, fog) at runtime, e.g. "day" / "dusk".
func set_lighting(preset: StringName) -> void:
	lighting = preset
	if environment_node:
		WorldSky.apply_environment(environment_node.environment, preset)
	if sun:
		WorldSky.apply_sun(sun, preset)
	if motes:
		motes.set_lighting(preset)


## Advances the air to an absolute time (tests, deterministic replays).
func set_air_time(t: float) -> void:
	_time = t
	wind.update(t)


## Openings only (landmarks of kind "opening").
func get_openings() -> Array[Dictionary]:
	return _landmarks.filter(func(l: Dictionary) -> bool: return l["kind"] == "opening")


## Numbers for tests and the report.
func stats() -> Dictionary:
	var kinds := {}
	for p in _perches:
		var k: String = Perch.Kind.keys()[p.kind]
		kinds[k] = kinds.get(k, 0) + 1
	var tris := 0
	for k in build.kits.values():
		tris += (k as MeshKit).tri_count()
	return {
		"generation_ms": generation_ms, "timings": timings, "perches": _perches.size(),
		"perch_kinds": kinds, "landmarks": _landmarks.size(), "openings": get_openings().size(),
		"refuges": _refuges.size(), "kits": build.kits.size(), "kit_tris": tris,
		"features": build.features.size(), "footprints": build.footprints.size(),
		"perch_validation": perch_report, "measured_openings": opening_report,
	}
