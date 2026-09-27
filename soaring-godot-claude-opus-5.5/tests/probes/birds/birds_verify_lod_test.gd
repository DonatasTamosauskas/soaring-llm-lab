extends TestCase
## Verifier probe (birds, round 1): the level of detail a BirdModel reports
## (get_lod) must be the mesh it is actually drawn with (its BirdBatch),
## including when the model is first attached far from the camera, re-shown
## close after being hidden far away (pooling), or re-parented.
##
## Suspected defect: BirdModel._attach() calls _tick(0.0), which may change
## _lod, but ignores its "LOD changed" result, so the model stays in the
## batch of the old LOD while reporting the new one; later syncs see
## want == _lod and never move it.

const DT := 1.0 / 72.0


func after_each() -> void:
	for c in get_children():
		c.free()
	BirdBatch.sync_all(DT)


func _cam() -> Camera3D:
	var cam := Camera3D.new()
	add_child(cam)
	cam.current = true
	return cam


## The LOD of the mesh the model's batch draws (-1 not drawn, -2 unknown).
func _drawn_lod(m: BirdModel) -> int:
	if m._batch == null:
		return -1
	for l in BirdModels.LOD_COUNT:
		if m._batch.mesh == BirdModels.mesh(m.species, l):
			return l
	return -2


func _sync(n: int = 3) -> void:
	for i in n:
		BirdBatch.sync_all(DT)


func test_spawned_far_is_drawn_at_its_lod() -> void:
	_cam()
	var m := BirdModels.create(&"eagle")
	m.scale = Vector3.ONE * 2.1
	m.position = Vector3(0, 0, -300)
	add_child(m)
	_sync()
	eq(m.get_lod(), 2, "eagle 300 m away reports LOD2")
	eq(_drawn_lod(m), m.get_lod(), "spawned far: drawn mesh LOD == reported LOD")
	metric("spawn_far_reported_drawn", [m.get_lod(), _drawn_lod(m)])


func test_reshown_close_after_hidden_far() -> void:
	_cam()
	var m := BirdModels.create(&"hawk")
	m.scale = Vector3.ONE * 1.6
	m.position = Vector3(0, 0, -4)
	add_child(m)
	_sync()
	# Walk away through every LOD so the batches are right before hiding.
	for d in [40.0, 90.0, 200.0, 300.0]:
		m.position = Vector3(0, 0, -d)
		_sync()
	eq(_drawn_lod(m), 2, "far: drawn at LOD2")
	# Pooling: hide far away, place it close, show it.
	m.visible = false
	m.position = Vector3(0, 0, -4)
	m.visible = true
	_sync()
	eq(m.get_lod(), 0, "re-shown 4 m away reports LOD0")
	eq(_drawn_lod(m), 0, "re-shown 4 m away is DRAWN at LOD0 (not the 52-tri LOD2)")
	metric("reshown_close_reported_drawn", [m.get_lod(), _drawn_lod(m)])


func test_reparented_close_after_far() -> void:
	_cam()
	var holder := Node3D.new()
	add_child(holder)
	var m := BirdModels.create(&"crow")
	m.scale = Vector3.ONE * 0.95
	holder.add_child(m)
	for d in [3.0, 30.0, 80.0, 200.0]:
		holder.position = Vector3(0, 0, -d)
		_sync()
	holder.remove_child(m)
	holder.position = Vector3(0, 0, -3)
	holder.add_child(m)
	_sync()
	eq(_drawn_lod(m), m.get_lod(), "re-parented close: drawn LOD == reported LOD")
	eq(_drawn_lod(m), 0, "re-parented 3 m away is drawn at LOD0")


func test_flock_like_budget_test_draws_what_it_reports() -> void:
	# The builder's 60-bird budget scenario: birds are created at the
	# origin 63 m from the camera, then circle. Count birds whose drawn mesh
	# differs from the LOD they report (the budget test's LOD histogram and
	# the flock shot's primitive counts rely on get_lod()).
	var cam := _cam()
	cam.position = Vector3(0, 20, 60)
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
	var t := 0.0
	for f in 150:
		t += DT
		for i in 60:
			var a := t * 0.3 + i * 0.37
			holders[i].position = Vector3(cos(a) * (20.0 + i), 10.0 + sin(a * 2.0) * 3.0, sin(a) * (20.0 + i))
		BirdBatch.sync_all(DT)
	var mismatched := 0
	var reported := [0, 0, 0]
	var drawn := [0, 0, 0]
	for m in models:
		reported[m.get_lod()] += 1
		var dl := _drawn_lod(m)
		if dl >= 0:
			drawn[dl] += 1
		if dl != m.get_lod():
			mismatched += 1
	metric("reported_lod_histogram", reported)
	metric("drawn_lod_histogram", drawn)
	metric("mismatched", mismatched)
	eq(mismatched, 0, "every bird is drawn with the LOD it reports (%s reported vs %s drawn)" % [str(reported), str(drawn)])
