extends TestCase
## BirdModel keeps a per-bird node API while BirdBatch draws each species
## and LOD as one MultiMesh: grouping, slot bookkeeping on removal,
## visibility, species/LOD changes, RID release, pause and the packed
## per-instance data the shader decodes.

const DT := 1.0 / 72.0


func after_each() -> void:
	for c in get_children():
		c.free()
	BirdBatch.sync_all(DT)


func _add(sp: StringName, parent: Node = self) -> BirdModel:
	var m := BirdModels.create(sp)
	m.lod_override = 0
	parent.add_child(m)
	return m


func test_batches_group_by_species() -> void:
	var models: Array[BirdModel] = []
	for i in 30:
		models.append(_add(BirdSpecies.IDS[i % 10]))
	eq(BirdBatch.count(), 10, "one batch per species (LOD pinned)")
	eq(BirdBatch.instance_total(), 30, "30 instances")
	# Slots stay consistent through removals from the middle.
	models[3].free()
	models[13].free()
	models[0].free()
	var ok := true
	for b: BirdBatch in BirdBatch.all():
		for i in b.models.size():
			if b.models[i]._slot != i or b.models[i]._batch != b:
				ok = false
	check(ok, "every model knows its batch and slot after removals")
	eq(BirdBatch.instance_total(), 27, "27 instances left")


func test_rids_released_when_empty() -> void:
	var m := _add(&"crow")
	BirdBatch.sync_all(DT)
	var b: BirdBatch = m._batch
	var mm := b.mm
	var inst := b.inst
	check(mm.is_valid() and inst.is_valid(), "batch holds a MultiMesh and an instance")
	# Ask the RenderingServer itself, not the batch's variables: a value
	# stored on the instance and the MultiMesh's buffer are readable while
	# they exist and gone once the server has freed them.
	RenderingServer.instance_geometry_set_shader_parameter(inst, &"probe", 7)
	eq(_server_probe(mm, inst), [true, true], "the server holds the batch's MultiMesh and instance")
	m.free()
	eq(BirdBatch.count(), 0, "batch gone with its last bird")
	eq(_server_probe(mm, inst), [false, false], "the server freed the MultiMesh and the instance")
	check(not b.mm.is_valid() and not b.inst.is_valid(), "its RIDs cleared")


## [MultiMesh alive, instance alive] as the RenderingServer sees them
## (reading a freed RID logs an engine error: silenced for the probe).
func _server_probe(mm: RID, inst: RID) -> Array:
	var was := Engine.print_error_messages
	Engine.print_error_messages = false
	var mm_alive := not RenderingServer.multimesh_get_buffer(mm).is_empty()
	var inst_alive: bool = RenderingServer.instance_geometry_get_shader_parameter(inst, &"probe") == 7
	Engine.print_error_messages = was
	return [mm_alive, inst_alive]


func test_visibility_hides_and_restores() -> void:
	var holder := Node3D.new()
	add_child(holder)
	var m := _add(&"gull", holder)
	eq(BirdBatch.instance_total(), 1, "drawn")
	m.visible = false
	eq(BirdBatch.instance_total(), 0, "hidden model leaves its batch")
	m.visible = true
	eq(BirdBatch.instance_total(), 1, "shown again")
	holder.visible = false
	eq(BirdBatch.instance_total(), 0, "hidden parent hides it too")
	holder.visible = true
	eq(BirdBatch.instance_total(), 1, "parent shown again")
	holder.remove_child(m)
	eq(BirdBatch.instance_total(), 0, "out of the tree, not drawn")
	holder.add_child(m)
	eq(BirdBatch.instance_total(), 1, "back in the tree")


func test_species_change_moves_batch() -> void:
	var m := _add(&"sparrow")
	var b0: BirdBatch = m._batch
	m.species = &"hawk"
	check(m._batch != b0, "new batch for the new species")
	check(m._batch.key.contains("hawk"), "hawk batch")
	eq(BirdBatch.count(), 1, "old batch released")


## Every model is drawn with the mesh of the LOD it reports, and (after a
## sync, which always runs right before drawing) every batch's GPU buffer
## holds what its CPU buffer says, slot by slot.
func _drawn_ok(models: Array, synced: bool = true) -> String:
	for m: BirdModel in models:
		if m._batch == null:
			return "%s has no batch" % m.species
		if m._batch.mesh != BirdModels.mesh(m.species, m.get_lod()):
			return "%s reports LOD%d but draws %s" % [m.species, m.get_lod(), m._batch.mesh.resource_name]
		if m._batch.models[m._slot] != m:
			return "%s slot bookkeeping" % m.species
	if not synced:
		return ""
	for b: BirdBatch in BirdBatch.all():
		if not b.gpu_in_sync():
			return "batch %s: GPU buffer differs from the CPU buffer" % b.key
		var o := 0
		for m: BirdModel in b.models:
			# The slot the GPU draws for this model is this model's transform.
			if not is_equal_approx(b.buf[o * BirdBatch.STRIDE + 3], m._xf.origin.x) or not is_equal_approx(b.buf[o * BirdBatch.STRIDE + 11], m._xf.origin.z):
				return "batch %s slot %d holds another bird" % [b.key, o]
			o += 1
	return ""


func test_lod_follows_distance_with_hysteresis() -> void:
	var cam := Camera3D.new()
	add_child(cam)
	cam.current = true
	var m := BirdModels.create(&"eagle")
	m.scale = Vector3.ONE * 2.1
	add_child(m)
	var lods := []
	var bad := ""
	# Walk away from the camera and back: LOD0 -> 1 -> 2 -> 1 -> 0.
	for d in [5.0, 40.0, 80.0, 150.0, 250.0, 150.0, 80.0, 40.0, 5.0]:
		m.position = Vector3(0, 0, -d)
		BirdBatch.sync_all(DT)
		# Drawn right in the frame the LOD changed (no blank frame).
		if bad == "":
			bad = _drawn_ok([m])
		BirdBatch.sync_all(DT)
		lods.append(m.get_lod())
	eq(bad, "", "the new LOD's mesh is drawn in the very frame it changes")
	eq(lods[0], 0, "close: LOD0")
	eq(lods[4], 2, "far: LOD2")
	eq(lods[8], 0, "close again: LOD0")
	check(lods.max() == 2 and lods.has(1), "passes through LOD1 (%s)" % str(lods))
	# At the LOD0/1 threshold, small jitter must not flip the LOD every frame.
	var th := 2.1 / BirdModel.LOD0_ANGLE
	var flips := 0
	var last := m.get_lod()
	for i in 40:
		m.position = Vector3(0, 0, -th * (1.0 + (0.05 if i % 2 == 0 else -0.05)))
		BirdBatch.sync_all(DT)
		if m.get_lod() != last:
			flips += 1
			last = m.get_lod()
	lt(flips, 2, "hysteresis: no LOD flicker at the threshold (%d flips)" % flips)
	metric("lod_walk", lods)


func test_drawn_lod_matches_reported_lod() -> void:
	# The mesh a model is drawn with is chosen when it joins a batch: at
	# spawn, when shown again, when re-parented. It must be the LOD for where
	# the bird is then, not whatever it had before.
	var cam := Camera3D.new()
	add_child(cam)
	cam.current = true
	BirdBatch.sync_all(DT)
	var far_holder := Node3D.new()
	far_holder.position = Vector3(0, 0, -150)
	add_child(far_holder)
	var near_holder := Node3D.new()
	near_holder.position = Vector3(0, 0, -3)
	add_child(near_holder)
	# Spawned far away (never synced yet): drawn at LOD2 from the start.
	var m := BirdModels.create(&"hawk")
	far_holder.add_child(m)
	eq(m.get_lod(), 2, "spawned 150 m away: LOD2")
	eq(_drawn_ok([m], false), "", "spawned far: joins the batch of the LOD it reports")
	BirdBatch.sync_all(DT)
	eq(_drawn_ok([m]), "", "spawned far: drawn at that LOD")
	# Hidden far away, moved close, shown again: LOD0 at once.
	m.visible = false
	far_holder.remove_child(m)
	near_holder.add_child(m)
	m.visible = true
	eq(m.get_lod(), 0, "shown again 3 m away: LOD0")
	eq(_drawn_ok([m], false), "", "re-shown close: joins LOD0 (not the stale LOD2)")
	BirdBatch.sync_all(DT)
	eq(_drawn_ok([m]), "", "re-shown close: drawn at LOD0")
	# Re-parented far again.
	near_holder.remove_child(m)
	far_holder.add_child(m)
	eq(_drawn_ok([m], false), "", "re-parented far: joins the LOD it reports")
	BirdBatch.sync_all(DT)
	eq(_drawn_ok([m]), "", "re-parented far: drawn at that LOD")
	# The Ecosystem's pattern: added at its parent's origin, then moved; the
	# first sync puts it right, in the frame it is first drawn.
	var n := BirdModels.create(&"crow")
	near_holder.add_child(n)
	n.position = Vector3(0, 0, -200)
	BirdBatch.sync_all(DT)
	eq(n.get_lod(), 2, "moved away after spawning: LOD2 after the first sync")
	eq(_drawn_ok([m, n]), "", "and drawn at LOD2 in that same frame")


func test_lod_moves_are_uploaded_in_the_same_frame() -> void:
	# A model changing LOD joins another batch after the others were
	# written; the upload must follow the move (and a batch that grew or was
	# created by the move must be filled) or the bird blinks for a frame.
	var cam := Camera3D.new()
	add_child(cam)
	cam.current = true
	var models: Array[BirdModel] = []
	for i in 12:
		var m := BirdModels.create(&"sparrow")
		m.scale = Vector3.ONE * 0.24
		add_child(m)
		m.position = Vector3(i * 0.5, 0, -3.0)
		models.append(m)
	BirdBatch.sync_all(DT)
	eq(_drawn_ok(models), "", "12 close sparrows drawn at LOD0")
	var bad := ""
	var moves := 0
	# Send them away one by one (each move lands in a batch that is new,
	# growing or has room), then all back at once.
	for step in 12:
		models[step].position.z = -60.0
		BirdBatch.sync_all(DT)
		moves += BirdBatch.last_lod_moves
		var r := _drawn_ok(models)
		if r != "" and bad == "":
			bad = "step %d: %s" % [step, r]
	for m in models:
		m.position.z = -3.0
	BirdBatch.sync_all(DT)
	moves += BirdBatch.last_lod_moves
	if bad == "":
		bad = _drawn_ok(models)
	eq(bad, "", "after every LOD move the GPU holds every bird's slot")
	gt(moves, 12, "the walk moved birds between batches (%d moves)" % moves)
	metric("lod_moves_checked", moves)


func test_instance_data_encoding() -> void:
	var m := _add(&"starling")
	m.flap_phase = 0.37
	m.flap_amount = 0.6
	m.wing_fold = 0.25
	m.perched = true
	m.highlight = 2
	m.snap()
	BirdBatch.sync_all(DT)
	var c: Vector4 = m._inst
	near(c.x, 0.37, 1e-6, "x = phase")
	near(c.y, 0.6, 1e-6, "y = amount")
	# Decode exactly as the shader does.
	var perch_q := floorf(c.z / 4096.0)
	near((c.z - perch_q * 4096.0) / 4095.0, 0.25, 1.0 / 4095.0, "z low 12 bits = fold")
	near(perch_q / 4095.0, 1.0, 1e-6, "z high 12 bits = perch")
	var seed_q := floorf(c.w / 65536.0)
	var rest := c.w - seed_q * 65536.0
	var danger_q := floorf(rest / 256.0)
	near((rest - danger_q * 256.0) / 255.0, 0.0, 1e-6, "w low byte = edible")
	near(danger_q / 255.0, 1.0, 1e-6, "w middle byte = danger")
	between(seed_q, 0.0, 255.0, "w high byte = seed")
	lt(c.w, 16777216.0, "packed value exact in a float (< 2^24)")
	# The batch buffer holds the transform and this data.
	var b: BirdBatch = m._batch
	var o := m._slot * BirdBatch.STRIDE
	near(b.buf[o + 12], c.x, 1e-6, "buffer carries custom.x")
	near(b.buf[o + 15], c.w, 1.0, "buffer carries custom.w")


func test_transform_follows_owner_and_bank() -> void:
	var holder := Node3D.new()
	add_child(holder)
	holder.position = Vector3(3, 4, 5)
	holder.rotation.y = 0.7
	var m := _add(&"pigeon", holder)
	m.scale = Vector3.ONE * 0.66
	m.bank = 0.4
	m.snap()
	BirdBatch.sync_all(DT)
	var xf: Transform3D = m._xf
	vnear(xf.origin, Vector3(3, 4, 5), 1e-5, "instance at the owner's position")
	near(xf.basis.x.length(), 0.66, 1e-4, "instance scaled by the owner's wingspan")
	var want := m.global_transform.basis * Basis(Vector3.BACK, -0.4)
	vnear(xf.basis.x, want.x, 1e-4, "bank rolls about the body axis")


func test_pause_freezes_smoothing() -> void:
	var m := _add(&"crow")
	m.flap_amount = 0.0
	m.snap()
	BirdBatch.sync_all(DT)
	m.process_mode = Node.PROCESS_MODE_PAUSABLE
	get_tree().paused = true
	m.flap_amount = 1.0
	for i in 10:
		BirdBatch.sync_all(DT)
	near(m.displayed_pose().y, 0.0, 1e-6, "paused: the displayed pose holds")
	get_tree().paused = false
	for i in 10:
		BirdBatch.sync_all(DT)
	gt(m.displayed_pose().y, 0.5, "unpaused: it moves on")
