extends TestCase
## Verifier probe (round 1): water and shorelines. ground_height() promises
## max(terrain, water); that only holds physically if the collided water
## surface covers every patch of terrain below the water level. Dense rays
## along every shore and riverbank look for gaps a bird could dive into.
## Also: per-kind perch ratings and static memory after generation.

var world: SoaringWorld
var space: PhysicsDirectSpaceState3D


func before_all() -> void:
	world = load("res://scenes/world/world.tscn").instantiate()
	add_child(world)
	await wait_physics(2)
	space = world.get_world_3d().direct_space_state


func after_all() -> void:
	if world:
		world.queue_free()


func _ray(a: Vector3, b: Vector3) -> Dictionary:
	var q := PhysicsRayQueryParameters3D.create(a, b)
	q.collision_mask = 1
	return space.intersect_ray(q)


func test_water_surface_has_no_gaps() -> void:
	var wy := WorldLayout.WATER_Y
	var gaps := 0
	var probed := 0
	var mism := 0
	var examples: PackedStringArray = []
	# Region: lake bbox plus the river corridor (and the canyon floor).
	var cells := []
	var x := -40.0
	while x <= 420.0:
		var z := -600.0
		while z <= 360.0:
			cells.append(Vector2(x, z))
			z += 0.5
		x += 0.5
	for c in cells:
		var cx: float = c.x
		var cz: float = c.y
		var t := world.terrain.height_at(cx, cz)
		# Only submerged terrain close to the waterline (banks, shores).
		if t >= wy - 0.01 or t < wy - 2.0:
			continue
		probed += 1
		var hit := _ray(Vector3(cx, 12.0, cz), Vector3(cx, -30.0, cz))
		if hit.is_empty():
			gaps += 1
			continue
		var hy: float = (hit["position"] as Vector3).y
		if hy < wy - 0.03:
			gaps += 1
			if examples.size() < 8:
				examples.append("(%.1f, %.1f) hit %.2f terrain %.2f" % [cx, cz, hy, t])
		elif absf(hy - world.ground_height(cx, cz)) > 0.05 and absf(hy - wy) < 0.05:
			mism += 1
	print("[world-verify] shore probes %d, gaps below the water surface %d %s" % [probed, gaps, examples])
	metric("shore_probes", probed)
	metric("water_gaps", gaps)
	metric("water_gap_examples", Array(examples))
	gt(float(probed), 1000.0, "enough shoreline samples")
	eq(gaps, 0, "the collided water surface covers all submerged terrain near the shores")
	eq(mism, 0, "ground_height equals the water surface where it is hit")


func test_perch_ratings_by_kind() -> void:
	var by := {}
	for p in world.get_perches():
		var k: String = Perch.Kind.keys()[p.kind]
		var e: Array = by.get(k, [INF, 0.0, 0])
		e[0] = minf(e[0], p.max_span)
		e[1] = maxf(e[1], p.max_span)
		e[2] += 1
		by[k] = e
	var out := {}
	for k in by:
		out[k] = {"min": snappedf(by[k][0], 0.01), "max": snappedf(by[k][1], 0.01), "n": by[k][2]}
	print("[world-verify] perch max_span by kind: ", out)
	metric("perch_span_by_kind", out)
	# Twigs and wires never carry more than an eagle; nothing absurd.
	for k in by:
		lt(float(by[k][1]), 12.0, "%s perches rated below 12 m span" % k)


func test_static_memory_after_generation() -> void:
	var mb := Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0
	var objs := Performance.get_monitor(Performance.OBJECT_COUNT)
	var nodes := Performance.get_monitor(Performance.OBJECT_NODE_COUNT)
	print("[world-verify] static memory %.0f MB, objects %d, nodes %d" % [mb, objs, nodes])
	metric("static_mb", mb)
	metric("nodes", nodes)
	lt(mb, 1500.0, "world fits comfortably in Quest memory")
