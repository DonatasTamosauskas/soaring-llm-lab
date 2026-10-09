extends TestCase
## B3: budgets. LOD0 <= 300 triangles for small birds (span < 0.5 m: moth ..
## starling) and <= 600 for large ones (pigeon .. eagle), LOD1 about half,
## LOD2 a tiny silhouette; one shared material for every bird; 60 animated
## birds cost <= 1 ms of CPU per frame (the whole per-frame job of the birds
## area: smoothing, transforms, LOD choice, MultiMesh uploads), measured.

const Geo := preload("res://tests/unit/birds/bird_geo.gd")


func test_triangle_budgets() -> void:
	var table := {}
	# The birds' meshes hold only the bird: the highlight marker is its own
	# mesh, drawn only around highlighted birds (BirdBatch's marker batch).
	var marks := 0
	for sp in BirdSpecies.IDS:
		var t0 := BirdModels.triangle_count(sp, 0)
		var t1 := BirdModels.triangle_count(sp, 1)
		var t2 := BirdModels.triangle_count(sp, 2)
		for lod in BirdModels.LOD_COUNT:
			var c0: PackedFloat32Array = BirdModels.mesh(sp, lod).surface_get_arrays(0)[Mesh.ARRAY_CUSTOM0]
			for i in range(0, c0.size(), 4):
				if int(roundf(c0[i])) == BirdPose.G_MARK:
					marks += 1
		var budget := BirdModels.triangle_budget(sp)
		check(t0 <= budget, "%s LOD0 %d tris <= %d" % [sp, t0, budget])
		check(t1 <= int(t0 * 0.55), "%s LOD1 %d tris <= 55%% of LOD0 (%d)" % [sp, t1, t0])
		check(t2 <= 64, "%s LOD2 %d tris <= 64" % [sp, t2])
		check(t2 < t1, "%s LOD2 < LOD1" % sp)
		table[String(sp)] = [t0, t1, t2, budget]
	eq(marks, 0, "no marker geometry in any bird mesh")
	var mk: int = BirdModels.marker_mesh().surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size() / 3
	eq(mk, BirdMeshBuilder.marker_triangles(), "the marker mesh: a ring and a triangle")
	metric("marker_mesh_tris", mk)
	# The small/large split follows the ladder's wingspans.
	eq(BirdModels.triangle_budget(&"starling"), 300, "starling is a small bird")
	eq(BirdModels.triangle_budget(&"pigeon"), 600, "pigeon is a large bird")
	metric("tris_lod0_lod1_lod2_budget", table)


func test_one_shared_material() -> void:
	var mats := {}
	for sp in BirdSpecies.IDS:
		for lod in BirdModels.LOD_COUNT:
			var m := BirdModels.mesh(sp, lod)
			eq(m.get_surface_count(), 1, "%s LOD%d is one surface" % [sp, lod])
			mats[m.surface_get_material(0)] = true
	eq(mats.size(), 1, "one material for all 30 meshes")
	var mat: ShaderMaterial = mats.keys()[0]
	check(mat == BirdModels.material(), "it is BirdModels.material()")
	eq(mat.shader.resource_path, "res://scripts/birds/bird.gdshader", "the bird shader")


func test_sixty_birds_cpu_cost() -> void:
	var cam := Camera3D.new()
	add_child(cam)
	cam.position = Vector3(0, 20, 60)
	cam.current = true
	var holders: Array[Node3D] = []
	var models: Array[BirdModel] = []
	for i in 60:
		var h := Node3D.new()
		add_child(h)
		var sp: StringName = BirdSpecies.IDS[i % 10]
		var m := BirdModels.create(sp)
		m.scale = Vector3.ONE * float(SizeRules.species_data(sp)["span"])
		h.add_child(m)
		holders.append(h)
		models.append(m)
	eq(BirdBatch.instance_total(), 60, "60 instances batched")
	var dt := 1.0 / 72.0
	var times := PackedFloat32Array()
	var t := 0.0
	for f in 150:
		t += dt
		# What an owner does each frame: move the bird, set its fields.
		for i in 60:
			var a := t * 0.3 + i * 0.37
			holders[i].position = Vector3(cos(a) * (20.0 + i), 10.0 + sin(a * 2.0) * 3.0, sin(a) * (20.0 + i))
			holders[i].rotation.y = -a
			var m := models[i]
			m.flap_phase = fposmod(t * 6.0 + i * 0.1, 1.0)
			m.flap_amount = 0.5 + 0.5 * sin(t + i)
			m.wing_fold = clampf(sin(t * 0.7 + i) - 0.5, 0.0, 1.0)
			m.bank = sin(t + i * 0.2) * 0.6
			m.perched = (i % 7) == 0 and fposmod(t, 4.0) < 2.0
			m.highlight = (i + int(t)) % 3
		var t0 := Time.get_ticks_usec()
		BirdBatch.sync_all(dt)
		var us := float(Time.get_ticks_usec() - t0)
		if f >= 10:
			times.append(us)
	var sorted := Array(times)
	sorted.sort()
	var med: float = sorted[sorted.size() / 2]
	var p95: float = sorted[int(sorted.size() * 0.95)]
	lt(med, 1000.0, "60 animated birds: median CPU per frame < 1 ms (got %.0f us)" % med)
	lt(p95, 1500.0, "60 animated birds: 95th percentile < 1.5 ms")
	# LODs as drawn (the batch's mesh), which must be what each bird reports.
	var lods := [0, 0, 0]
	var disagree := 0
	for m in models:
		lods[m.get_lod()] += 1
		if m._batch.mesh != BirdModels.mesh(m.species, m.get_lod()):
			disagree += 1
	eq(disagree, 0, "every bird draws the mesh of the LOD it reports")
	var drawn := [0, 0, 0]
	for b: BirdBatch in BirdBatch.all():
		drawn[int(b.mesh.resource_name.right(1))] += b.models.size()
	eq(drawn, lods, "LOD histogram of the drawn meshes %s" % str(drawn))
	gt(lods[1] + lods[2], 0, "distant birds drop to cheaper LODs")
	check(BirdBatch.count() <= 30, "at most one batch per species and LOD (%d)" % BirdBatch.count())
	metric("sync_us_median", med)
	metric("sync_us_p95", p95)
	metric("batches", BirdBatch.count())
	metric("lod_histogram", lods)
	for h in holders:
		h.free()
	cam.free()
	eq(BirdBatch.count(), 0, "batches released when the birds are gone")


func test_building_every_mesh_is_quick() -> void:
	# Meshes are built on first use (or all at once by BirdModels.prewarm()
	# behind a loading screen): building all 30 must not stall a frame by
	# much, and the first-use cost of one species is small.
	var t0 := Time.get_ticks_usec()
	var norms := {}
	for sp in BirdSpecies.IDS:
		for lod in BirdModels.LOD_COUNT:
			var r: Dictionary = BirdMeshBuilder.build(sp, lod, norms.get(sp, {}))
			if lod == 0:
				norms[sp] = r["norm"]
	var ms := (Time.get_ticks_usec() - t0) / 1000.0
	lt(ms, 250.0, "all 30 meshes build in < 250 ms (%.0f ms)" % ms)
	metric("build_all_30_meshes_ms", snappedf(ms, 0.1))
	metric("build_per_species_ms", snappedf(ms / BirdSpecies.IDS.size(), 0.1))


func test_no_mesh_is_built_inside_a_sync() -> void:
	# The first bird of a species builds all three of its LODs when it is
	# attached (outside the frame's sync), so a bird flying out across a LOD
	# threshold never builds a mesh inside BirdBatch.sync_all (round-3
	# verifier: a 17 ms sync the first time a species went far).
	var cam := Camera3D.new()
	add_child(cam)
	cam.current = true
	BirdModels._forget_meshes()
	var m := BirdModels.create(&"crow")
	m.position = Vector3(0, 0, -3)
	var t0 := Time.get_ticks_usec()
	add_child(m)
	var attach_ms := (Time.get_ticks_usec() - t0) / 1000.0
	eq(m.get_lod(), 0, "close: LOD0")
	var built := 0
	for lod in BirdModels.LOD_COUNT:
		if BirdModels._meshes.has("crow:%d" % lod):
			built += 1
	eq(built, BirdModels.LOD_COUNT, "all LODs of a species exist once its first bird is attached")
	var worst := 0.0
	for d in [30.0, 120.0, 400.0]:
		m.position = Vector3(0, 0, -d)
		var t1 := Time.get_ticks_usec()
		BirdBatch.sync_all(1.0 / 72.0)
		worst = maxf(worst, (Time.get_ticks_usec() - t1) / 1000.0)
	eq(m.get_lod(), 2, "far: LOD2")
	metric("first_attach_of_a_species_ms", snappedf(attach_ms, 0.1))
	metric("worst_sync_with_lod_moves_ms", snappedf(worst, 0.01))
	m.free()
	cam.free()
	BirdBatch.sync_all(1.0 / 72.0)
	BirdModels.prewarm()

