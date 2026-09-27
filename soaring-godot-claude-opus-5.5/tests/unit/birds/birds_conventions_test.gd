extends TestCase
## B6: model conventions every other area relies on (docs/ARCHITECTURE.md,
## birds): wingspan exactly 1.0 at scale 1 (measured AABB, every LOD, rest
## mesh and drawn glide pose), beak towards -Z, origin at the body centre,
## mirror symmetry, outward-facing flat triangles, feet on the perch grip
## (one SizeRules body radius below the body centre), and the factory API.

const Geo := preload("res://tests/unit/birds/bird_geo.gd")


func test_wingspan_is_exactly_one_at_every_lod() -> void:
	var table := {}
	for sp in BirdSpecies.IDS:
		var row := []
		for lod in BirdModels.LOD_COUNT:
			var arr := Geo.arrays(sp, lod)
			var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var mn := INF
			var mx := -INF
			for p in v:
				mn = minf(mn, p.x)
				mx = maxf(mx, p.x)
			near(mx - mn, 1.0, 1e-4, "%s LOD%d rest AABB width" % [sp, lod])
			near(mx + mn, 0.0, 1e-4, "%s LOD%d centred on x" % [sp, lod])
			# The glide pose (what the shader draws at amount 0, fold 0).
			var g := Geo.posed(arr, Vector4(0.25, 0.0, 0.0, 0.0))
			var gmn := INF
			var gmx := -INF
			for p in g:
				gmn = minf(gmn, p.x)
				gmx = maxf(gmx, p.x)
			near(gmx - gmn, 1.0, 1e-4, "%s LOD%d glide-pose span" % [sp, lod])
			row.append(snappedf(mx - mn, 1e-6))
		table[String(sp)] = row
	metric("span_by_lod", table)


func test_beak_points_minus_z() -> void:
	for sp in BirdSpecies.IDS:
		var arr := Geo.arrays(sp)
		var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var g := Geo.groups(arr)
		var best := 0
		for i in v.size():
			if v[i].z < v[best].z:
				best = i
		eq(g[best], BirdPose.G_HEAD, "%s: the foremost vertex is the head/beak" % sp)
		lt(v[best].z, -0.2, "%s: beak well ahead of the body centre (-Z)" % sp)
		lt(absf(v[best].x), 0.13, "%s: foremost point near the midline" % sp)
		# The tail end is at +Z (behind).
		var back := -INF
		for p in v:
			back = maxf(back, p.z)
		gt(back, 0.1, "%s: tail towards +Z" % sp)


func test_origin_at_body_centre() -> void:
	for sp in BirdSpecies.IDS:
		var b := BirdModels.body_aabb(sp)
		vnear(b.get_center(), Vector3.ZERO, 1e-4, "%s body bounds centred on the origin" % sp)
		gt(b.size.y, 0.05, "%s body has depth" % sp)


func test_left_right_mirror_symmetry() -> void:
	for sp in BirdSpecies.IDS:
		for lod in BirdModels.LOD_COUNT:
			var v: PackedVector3Array = Geo.arrays(sp, lod)[Mesh.ARRAY_VERTEX]
			var keys := {}
			for p in v:
				keys[Vector3i(roundi(p.x * 1e5), roundi(p.y * 1e5), roundi(p.z * 1e5))] = true
			var missing := 0
			for p in v:
				if not keys.has(Vector3i(roundi(-p.x * 1e5), roundi(p.y * 1e5), roundi(p.z * 1e5))):
					missing += 1
			eq(missing, 0, "%s LOD%d: every vertex has a mirror twin" % [sp, lod])


func test_flat_triangles_face_their_normals() -> void:
	# Godot draws clockwise-from-the-viewer triangles; the stored flat normal
	# must point to the viewer side, i.e. opposite to cross(b - a, c - a).
	for sp in BirdSpecies.IDS:
		for lod in BirdModels.LOD_COUNT:
			var arr := Geo.arrays(sp, lod)
			var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var n: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
			var bad := 0
			var nonflat := 0
			for t in range(0, v.size(), 3):
				var cr := (v[t + 1] - v[t]).cross(v[t + 2] - v[t])
				if cr.dot(n[t]) >= 0.0:
					bad += 1
				if not (n[t].is_equal_approx(n[t + 1]) and n[t].is_equal_approx(n[t + 2])):
					nonflat += 1
			eq(bad, 0, "%s LOD%d triangles wound against their normals" % [sp, lod])
			eq(nonflat, 0, "%s LOD%d triangles not flat-shaded" % [sp, lod])


func test_feet_reach_the_perch_grip() -> void:
	# The contract (ARCHITECTURE, Perch): a perched bird's body centre sits
	# one SizeRules body radius above the grip, so the feet must reach down
	# exactly that far, in wingspans (from SizeRules, not our own constant).
	var table := {}
	for d: Dictionary in SizeRules.SPECIES:
		var sp: StringName = d["id"]
		var mass: float = d["mass"]
		var grip := SizeRules.body_radius_for_mass(mass) / SizeRules.wingspan_for_mass(mass)
		for lod in 2:
			var arr := Geo.arrays(sp, lod)
			var g := Geo.groups(arr)
			var v := Geo.posed(arr, Vector4(0.25, 0.0, 1.0, 1.0))
			var low := INF
			var zc := 0.0
			var n := 0
			for i in v.size():
				if g[i] == BirdPose.G_LEG:
					low = minf(low, v[i].y)
					zc += v[i].z
					n += 1
			check(n > 0, "%s LOD%d has legs" % [sp, lod])
			near(low, -grip, 0.006, "%s LOD%d perched feet on the grip (%.3f span below the centre)" % [sp, lod, grip])
			lt(absf(zc / maxf(n, 1)), 0.12, "%s LOD%d feet under the body" % [sp, lod])
			if lod == 0:
				table[String(sp)] = snappedf(low, 1e-4)
		# In flight the legs are tucked up out of the way.
		var arr0 := Geo.arrays(sp, 0)
		var g0 := Geo.groups(arr0)
		var vf := Geo.posed(arr0, Vector4(0.25, 0.0, 0.0, 0.0))
		var lowf := INF
		for i in vf.size():
			if g0[i] == BirdPose.G_LEG:
				lowf = minf(lowf, vf[i].y)
		gt(lowf, -0.11, "%s legs tucked in flight" % sp)
	metric("perched_foot_y", table)


func test_factory_and_fields() -> void:
	for sp in BirdSpecies.IDS:
		var m := BirdModels.create(sp)
		check(m is BirdModel, "%s: create() returns a BirdModel" % sp)
		eq(m.species, sp, "%s: species set" % sp)
		eq(m.get_child_count(), 0, "%s: no child nodes (drawn by a shared batch)" % sp)
		for f in ["flap_phase", "flap_amount", "wing_fold", "bank", "perched", "highlight"]:
			check(f in m, "%s has field %s" % [sp, f])
		m.free()
	var u := BirdModels.create(&"dodo")
	eq(u.species, &"sparrow", "unknown species falls back to a sparrow")
	u.free()
	eq(BirdSpecies.IDS.size(), SizeRules.SPECIES.size(), "every ladder species has a model")
	for i in SizeRules.SPECIES.size():
		eq(BirdSpecies.IDS[i], SizeRules.SPECIES[i]["id"], "species order matches the ladder")
