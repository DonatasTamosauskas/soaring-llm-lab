extends TestCase
## Verifier probe (round 1): does the forest demand weaving? The brief asks
## for "trees with real branch structure to weave through" and places "that
## make acrobatic flight required and rewarding". Measured here:
## - mean free path: how far a bird flies in a straight line through the
##   forest (random headings, 3-12 m up) before its body touches anything;
## - canopy cover: fraction of forest ground points with a tree overhead;
## - nearest-neighbour spacing of trunks.
## For comparison the same is measured in the village and the orchard.

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


func _cast(from: Vector3, to: Vector3, r: float) -> float:
	var sp := SphereShape3D.new()
	sp.radius = r
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = sp
	q.collision_mask = 1
	q.transform = Transform3D(Basis.IDENTITY, from)
	q.motion = to - from
	var res := space.cast_motion(q)
	return res[0] if res.size() > 0 else 1.0


func _overlaps(c: Vector3, r: float) -> bool:
	var sp := SphereShape3D.new()
	sp.radius = r
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = sp
	q.collision_mask = 1
	q.transform = Transform3D(Basis.IDENTITY, c)
	return not space.intersect_shape(q, 1).is_empty()


func _is_ground(hit: Dictionary) -> bool:
	var n := String((hit["collider"] as Node).name)
	return n.begins_with("terrain_") or n.begins_with("water")


func _mfp(centre: Vector2, radius: float, r_body: float, seed_: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_
	var total := 0.0
	var n := 0
	var hits_tree := 0
	var L := 120.0
	for i in 400:
		var a := rng.randf() * TAU
		var rr := sqrt(rng.randf()) * radius * 0.8
		var p2 := centre + Vector2(cos(a), sin(a)) * rr
		var h := rng.randf_range(3.0, 12.0)
		var p := Vector3(p2.x, world.ground_height(p2.x, p2.y) + h, p2.y)
		if _overlaps(p, r_body):
			continue
		var hd := rng.randf() * TAU
		var d := Vector3(cos(hd), 0.0, sin(hd))
		# Follow the terrain loosely: aim the end point at the same AGL.
		var e2 := p2 + Vector2(d.x, d.z) * L
		var e := Vector3(e2.x, world.ground_height(e2.x, e2.y) + h, e2.y)
		var f := _cast(p, e, r_body)
		total += f * L
		n += 1
		if f < 1.0:
			hits_tree += 1
	return {"mean_free_path_m": snappedf(total / maxf(n, 1), 0.1), "blocked_within_120m": snappedf(float(hits_tree) / maxf(n, 1), 0.01), "n": n}


func _cover(centre: Vector2, radius: float) -> float:
	var covered := 0
	var n := 0
	var x := -radius
	while x <= radius:
		var z := -radius
		while z <= radius:
			if Vector2(x, z).length() <= radius:
				var q := centre + Vector2(x, z)
				var g := world.ground_height(q.x, q.y)
				var qq := PhysicsRayQueryParameters3D.create(Vector3(q.x, g + 60.0, q.y), Vector3(q.x, g - 1.0, q.y))
				qq.collision_mask = 1
				var hit := space.intersect_ray(qq)
				n += 1
				if not hit.is_empty() and not _is_ground(hit):
					covered += 1
			z += 2.0
		x += 2.0
	return float(covered) / maxf(n, 1)


func test_forest_demands_weaving() -> void:
	var fc := WorldLayout.FOREST
	var fr := WorldLayout.FOREST_R
	var out := {}
	for sp in [["sparrow", 0.24], ["crow", 0.95], ["eagle", 2.1]]:
		out["forest_" + String(sp[0])] = _mfp(fc, fr, 0.16 * float(sp[1]), 5)
	out["orchard_sparrow"] = _mfp(WorldLayout.ORCHARD, 40.0, 0.16 * 0.24, 6)
	out["village_sparrow"] = _mfp(WorldLayout.VILLAGE, 110.0, 0.16 * 0.24, 7)
	var cover := _cover(fc, fr * 0.8)
	# Trunk spacing inside the forest circle.
	var lib: TreeLib = world.build.get_meta(&"tree_lib")
	var pts := PackedVector2Array()
	for inst in lib.instances:
		var p: Vector3 = inst["pos"]
		if Vector2(p.x, p.z).distance_to(fc) < fr * 0.8:
			pts.append(Vector2(p.x, p.z))
	var nn_sum := 0.0
	for i in pts.size():
		var best := INF
		for j in pts.size():
			if i != j:
				best = minf(best, pts[i].distance_to(pts[j]))
		nn_sum += best
	var nn := nn_sum / maxf(pts.size(), 1)
	var area := PI * pow(fr * 0.8, 2.0)
	out["forest_canopy_cover"] = snappedf(cover, 0.001)
	out["forest_trees_in_core"] = pts.size()
	out["forest_mean_nn_spacing_m"] = snappedf(nn, 0.1)
	out["forest_m2_per_tree"] = snappedf(area / maxf(pts.size(), 1), 1.0)
	print("[world-verify] forest: ", out)
	metric("forest", out)
	# A forest you must weave through: a sparrow cannot fly 60 m straight at
	# canopy height, and at least a third of the ground is under canopy.
	lt(float(out["forest_sparrow"]["mean_free_path_m"]), 60.0, "sparrow mean free path in the forest < 60 m")
	gt(cover, 0.33, "forest canopy covers > 1/3 of the forest floor")
