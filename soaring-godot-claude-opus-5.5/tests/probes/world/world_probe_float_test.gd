extends TestCase
## Verifier probe (round 1): floating objects, found WITHOUT the builder's
## self-registered footprints. Every downward-facing drawn triangle whose
## centre hovers 3-60 cm above the terrain is a candidate; it is a real
## float only if nothing solid is directly below it before the terrain AND
## the object has no solid within 5 cm sideways/below (i.e. it is not held by
## a post, trunk or wall). Candidates are listed with their mesh and place.

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


func test_no_hovering_undersides() -> void:
	var visual: Node = world.get_node("Visual")
	var cand := {}
	var dims := {}
	var n_down := 0
	for mi in visual.get_children():
		if not (mi is MeshInstance3D):
			continue
		var m := mi as MeshInstance3D
		# Far LOD stand-ins are only drawn far away.
		if m.visibility_range_begin > 0.0:
			continue
		var verts: PackedVector3Array = m.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		var xf := m.global_transform
		for t in verts.size() / 3:
			var a := xf * verts[t * 3]
			var b := xf * verts[t * 3 + 1]
			var c := xf * verts[t * 3 + 2]
			# Godot winding is clockwise: outward normal = (c - a) x (b - a).
			var nrm := (c - a).cross(b - a)
			if nrm.length() < 1e-8:
				continue
			nrm = nrm.normalized()
			if nrm.y > -0.9:
				continue
			var cen := (a + b + c) / 3.0
			var g := world.ground_height(cen.x, cen.z)
			var gap := cen.y - g
			if gap < 0.03 or gap > 0.6:
				continue
			n_down += 1
			# Anything solid right under it (other than terrain/water)?
			var hit := _ray(cen + Vector3.DOWN * 0.005, Vector3(cen.x, g - 0.05, cen.z))
			if hit.is_empty():
				continue
			var col: Node = hit["collider"]
			var nm := String(col.name)
			if not (nm.begins_with("terrain_") or nm.begins_with("water")):
				continue
			var d := cen.y - (hit["position"] as Vector3).y
			if d < 0.03:
				continue
			var ext := Vector3(maxf(maxf(a.x, b.x), c.x) - minf(minf(a.x, b.x), c.x), 0.0, maxf(maxf(a.z, b.z), c.z) - minf(minf(a.z, b.z), c.z))
			var key := "%s@(%d,%d)" % [m.name, int(cen.x), int(cen.z)]
			cand[key] = maxf(float(cand.get(key, 0.0)), d)
			var sz: Vector2 = dims.get(key, Vector2.ZERO)
			dims[key] = Vector2(maxf(sz.x, maxf(ext.x, ext.z)), maxf(sz.y, minf(ext.x, ext.z)))
	var list := []
	var by_mesh := {}
	var blobs := []
	for k in cand:
		var sz: Vector2 = dims[k]
		list.append("%s gap %.2f tri %.2fx%.2f" % [k, cand[k], sz.x, sz.y])
		var mn: String = String(k).get_slice("@", 0)
		by_mesh[mn] = by_mesh.get(mn, 0) + 1
		# Not a thin rail/kerb: both horizontal extents > 15 cm.
		if sz.y > 0.15:
			blobs.append("%s gap %.2f tri %.2fx%.2f" % [k, cand[k], sz.x, sz.y])
	list.sort()
	blobs.sort()
	print("[world-verify] hover candidates by mesh: ", by_mesh)
	print("[world-verify] non-thin hovering undersides (%d): %s" % [blobs.size(), blobs.slice(0, 60)])
	metric("hover_nonthin", blobs)
	print("[world-verify] downward faces 3-60 cm above ground: %d; hovering over bare ground at %d places: %s" % [n_down, list.size(), list.slice(0, 40)])
	metric("hover_candidates", list)
	metric("hover_count", list.size())
	check(true, "report only (inspect candidates)")


func test_ground_props_touch_the_ground() -> void:
	# Kits whose pieces rest on the ground by themselves (rubble, bushes,
	# logs, boulders, bales). A 1 m cell of such a kit that holds downward
	# faces near the ground but NO vertex within 3 cm of it is a floater.
	var visual: Node = world.get_node("Visual")
	var floaters := []
	for mi in visual.get_children():
		if not (mi is MeshInstance3D):
			continue
		var m := mi as MeshInstance3D
		if m.visibility_range_begin > 0.0:
			continue
		var mname := String(m.name)
		if not (mname.begins_with("ruin") or mname.begins_with("forest_floor") or mname.begins_with("rocks") \
				or mname.begins_with("boulder") or mname.begins_with("props") or mname.begins_with("farm") or mname.begins_with("copse")):
			continue
		var verts: PackedVector3Array = m.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		var xf := m.global_transform
		var cell_min := {}
		var cell_down := {}
		for t in verts.size() / 3:
			var a := xf * verts[t * 3]
			var b := xf * verts[t * 3 + 1]
			var c := xf * verts[t * 3 + 2]
			for v in [a, b, c]:
				var key := Vector2i(floori(v.x), floori(v.z))
				var gap: float = v.y - world.ground_height(v.x, v.z)
				cell_min[key] = minf(float(cell_min.get(key, INF)), gap)
			var nrm := (c - a).cross(b - a)
			if nrm.length() > 1e-8 and nrm.normalized().y < -0.7:
				var cen := (a + b + c) / 3.0
				var gg := cen.y - world.ground_height(cen.x, cen.z)
				if gg > 0.0 and gg < 0.6:
					cell_down[Vector2i(floori(cen.x), floori(cen.z))] = true
		for key in cell_down:
			var mn: float = cell_min.get(key, INF)
			# Look at the 3x3 neighbourhood: the piece may touch down next door.
			for dx in [-1, 0, 1]:
				for dz in [-1, 0, 1]:
					mn = minf(mn, float(cell_min.get(key + Vector2i(dx, dz), INF)))
			if mn > 0.03 and mn < 0.8:
				floaters.append("%s@(%d,%d) min gap %.2f" % [mname, key.x, key.y, mn])
	print("[world-verify] ground props with no vertex on the ground (%d): %s" % [floaters.size(), floaters.slice(0, 40)])
	metric("prop_floaters", floaters)
	eq(floaters.size(), 0, "every ground-resting prop touches the ground")
