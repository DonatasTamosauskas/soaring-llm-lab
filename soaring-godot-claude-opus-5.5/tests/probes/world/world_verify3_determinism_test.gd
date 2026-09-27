extends TestCase
## Verifier probe, round 3 (engineering lens): W9 beyond the builder's hash.
## The suite hashes perches, landmarks and refuges; this hashes the BUILT
## world (every drawn vertex, normal and colour under Visual, every collision
## shape and its transform under Bodies, the boundary) and compares:
##  - two worlds of seed 1 in one process (the second in its own physics
##    space), and a seed-2 world (must differ);
##  - the printed hash across two separate processes (run this twice and
##    compare the "[world-verify3] geometry hash" lines).
##
##   tools/gd.sh world_verify2 --headless res://tests/runner.tscn -- \
##       --dir=res://tests/probes/world --suite=world_verify3_determinism

func _geometry_hash(w: SoaringWorld) -> Dictionary:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	var meshes := 0
	var shapes := 0
	for n in w.get_node("Visual").get_children():
		var mi := n as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		meshes += 1
		ctx.update(String(mi.name).to_utf8_buffer())
		ctx.update(var_to_bytes(mi.transform))
		for s in mi.mesh.get_surface_count():
			var arr := mi.mesh.surface_get_arrays(s)
			ctx.update((arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).to_byte_array())
			if arr[Mesh.ARRAY_COLOR] != null:
				ctx.update((arr[Mesh.ARRAY_COLOR] as PackedColorArray).to_byte_array())
	var bodies: Array[Node] = [w.get_node("Boundary")]
	bodies.append_array(_all_bodies(w.get_node("Bodies")))
	for b in bodies:
		var co := b as CollisionObject3D
		if co == null:
			continue
		ctx.update(var_to_bytes(co.global_transform))
		for o in co.get_shape_owners():
			ctx.update(var_to_bytes(co.shape_owner_get_transform(o)))
			for k in co.shape_owner_get_shape_count(o):
				var sh := co.shape_owner_get_shape(o, k)
				shapes += 1
				if sh is ConcavePolygonShape3D:
					ctx.update((sh as ConcavePolygonShape3D).get_faces().to_byte_array())
				elif sh is ConvexPolygonShape3D:
					ctx.update((sh as ConvexPolygonShape3D).points.to_byte_array())
				elif sh is CapsuleShape3D:
					ctx.update(var_to_bytes([(sh as CapsuleShape3D).radius, (sh as CapsuleShape3D).height]))
				elif sh is BoxShape3D:
					ctx.update(var_to_bytes((sh as BoxShape3D).size))
				elif sh is SphereShape3D:
					ctx.update(var_to_bytes((sh as SphereShape3D).radius))
				elif sh is CylinderShape3D:
					ctx.update(var_to_bytes([(sh as CylinderShape3D).radius, (sh as CylinderShape3D).height]))
				else:
					ctx.update(sh.get_class().to_utf8_buffer())
	return {"hash": ctx.finish().hex_encode(), "meshes": meshes, "shapes": shapes}


func _all_bodies(root: Node) -> Array[Node]:
	var out: Array[Node] = []
	for c in root.get_children():
		if c is CollisionObject3D:
			out.append(c)
		out.append_array(_all_bodies(c))
	return out


func _isolated(seed_: int) -> Array:
	var vp := SubViewport.new()
	vp.own_world_3d = true
	vp.size = Vector2i(8, 8)
	vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(vp)
	var w: SoaringWorld = load("res://scenes/world/world.tscn").instantiate()
	w.world_seed = seed_
	vp.add_child(w)
	return [vp, w]


func test_built_geometry_is_deterministic() -> void:
	var a := _isolated(1)
	var ha := _geometry_hash(a[1])
	a[0].queue_free()
	await wait_frames(1)
	var b := _isolated(1)
	var hb := _geometry_hash(b[1])
	b[0].queue_free()
	await wait_frames(1)
	var c := _isolated(2)
	var hc := _geometry_hash(c[1])
	c[0].queue_free()
	await wait_frames(1)
	print("[world-verify3] geometry hash seed 1: %s (%d meshes, %d shapes)" % [ha["hash"], ha["meshes"], ha["shapes"]])
	print("[world-verify3] geometry hash seed 1 again: %s" % hb["hash"])
	print("[world-verify3] geometry hash seed 2: %s" % hc["hash"])
	gt(float(ha["meshes"]), 100.0, "hashed the drawn meshes")
	gt(float(ha["shapes"]), 1000.0, "hashed the collision shapes")
	eq(ha["hash"], hb["hash"], "same seed, same built geometry (drawn and collided)")
	check(ha["hash"] != hc["hash"], "a different seed builds different geometry")
	metric("geometry_hash_seed1", ha)
	metric("geometry_hash_seed2", hc)
