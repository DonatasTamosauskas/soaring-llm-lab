extends TestCase
## Round-4 engineering verifier probes (birds). Headless checks of the
## round-3 marker batch on the paths the game actually uses, which the
## builder's suite leaves to the rendered highlight shot:
##   * GameLoop writes `highlight` on NPCs that are already drawn (the suite
##     only marks birds whose highlight was set before add_child);
##   * NPCs move every frame (the suite only checks the marker's data in the
##     frame the bird joins the marker batch);
##   * the marker batch's GPU copy (the suite checks gpu_in_sync on bird
##     batches only).
## Each probe fails on a one-line mutation of bird_batch.gd that the suite
## passes (see artifacts/birds/verify/r4eng_mutations.txt).

const DT := 1.0 / 72.0

var _cam: Camera3D


func before_each() -> void:
	_cam = Camera3D.new()
	add_child(_cam)
	_cam.current = true


func after_each() -> void:
	for c in get_children():
		c.free()
	BirdBatch.sync_all(DT)


static func _slot_data(b: BirdBatch, slot: int) -> PackedFloat32Array:
	return b.buf.slice(slot * BirdBatch.STRIDE, (slot + 1) * BirdBatch.STRIDE)


func test_r4_bird_highlighted_after_it_is_drawn_gets_a_marker() -> void:
	# The production path: an NPC is spawned and drawn, later GameLoop sets
	# its highlight. Its marker must appear within a frame or two and reach
	# the GPU (the marker batch's buffer uploaded like any other).
	var m := BirdModels.create(&"crow")
	m.position = Vector3(0, 0, -30)
	add_child(m)
	for f in 5:
		BirdBatch.sync_all(DT)
	check(m._mark == null, "unhighlighted: no marker")
	m.highlight = 2
	BirdBatch.sync_all(DT)
	BirdBatch.sync_all(DT)
	check(m._mark != null, "highlighted after it was drawn: marked within 2 frames")
	eq(BirdBatch.marker_total(), 1, "one marker")
	var synced := true
	for b: BirdBatch in BirdBatch.markers():
		synced = synced and b.gpu_in_sync()
	check(BirdBatch.markers().size() == 1 and synced, "the marker batch's GPU buffer equals its CPU buffer")


func test_r4_marker_follows_a_moving_bird() -> void:
	# NPCs move every frame; the marker instance must carry its bird's
	# current transform and packed data (phase, highlight weight), not the
	# ones it had when it joined the marker batch.
	var ms: Array[BirdModel] = []
	for i in 3:
		var m := BirdModels.create(BirdSpecies.IDS[i + 3])
		m.position = Vector3(i * 4.0 - 4.0, 0, -25)
		m.highlight = 1 + i % 2
		m.flap_amount = 1.0
		add_child(m)
		m.snap()
		ms.append(m)
	BirdBatch.sync_all(DT)
	var worst := 0.0
	for f in 30:
		for i in ms.size():
			ms[i].position += Vector3(0.3, 0.05 * i, -0.4)
			ms[i].rotation.y += 0.05
			ms[i].flap_phase = fposmod(ms[i].flap_phase + DT * 7.0, 1.0)
		BirdBatch.sync_all(DT)
		for m in ms:
			var a := _slot_data(m._mark, m._mark_slot)
			var b := _slot_data(m._batch, m._slot)
			for k in BirdBatch.STRIDE:
				worst = maxf(worst, absf(a[k] - b[k]))
	lt(worst, 1e-6, "every frame, each marker instance equals its bird's instance (largest difference %.4f)" % worst)
	var synced := true
	for b: BirdBatch in BirdBatch.markers():
		synced = synced and b.gpu_in_sync()
	check(synced, "marker batch uploaded after the birds moved")


## A fixed pure-GDScript workload (~40 us): timed right before and right
## after each sync, it tells a slow machine (both slow) from slow bird code.
static func _canary() -> int:
	var t0 := Time.get_ticks_usec()
	var acc := 0.0
	var v := Vector3(0.3, 0.2, 0.1)
	for k in 600:
		v = Basis(Vector3.UP, 0.001 * k) * v
		acc += v.x * 0.5 + sin(acc * 0.001)
	return Time.get_ticks_usec() - t0 + (1 if acc == 12345.678 else 0)


func test_r4_soak_spikes_are_the_machine_not_the_birds() -> void:
	# The round-3 soak (60 birds, respawns as other species, hides, LOD
	# changes, highlights) measured max syncs of 5-21 ms on a loaded machine
	# (load average 11-14). Here every sync is bracketed by a canary: a spike
	# with both canaries normal is the birds' own work, a spike with a slow
	# canary is the machine. The birds' own spikes must stay under 2 ms.
	var cam := Camera3D.new()
	add_child(cam)
	cam.current = true
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	var ids := BirdSpecies.IDS
	var models: Array[BirdModel] = []
	var state: Array[Vector4] = []
	for i in 60:
		var m := BirdModels.create(ids[i % ids.size()])
		m.scale = Vector3.ONE * float(SizeRules.species_data(m.species).get("span", 0.3))
		add_child(m)
		models.append(m)
		state.append(Vector4(rng.randf_range(3, 150), rng.randf_range(0, TAU), rng.randf_range(0.1, 0.8), rng.randf_range(4, 14)))
	var dt := 1.0 / 72.0
	var syncs := PackedInt32Array()
	var before := PackedInt32Array()
	var after := PackedInt32Array()
	var info := []
	for f in 72 * 60 * 5:
		var t := f * dt
		cam.position = Vector3(sin(t * 0.05) * 80.0, 20.0 + sin(t * 0.13) * 10.0, sin(t * 0.1) * 60.0 + 0.01)
		cam.look_at(Vector3(0, 10, 0), Vector3.UP)
		for i in models.size():
			var m := models[i]
			var s := state[i]
			var ang := s.y + t * s.z
			m.position = Vector3(cos(ang) * s.x, s.w, sin(ang) * s.x)
			m.flap_phase = fposmod(m.flap_phase + dt * (4.0 + (i % 7)), 1.0)
			m.flap_amount = 0.5 + 0.5 * sin(t * 0.7 + i)
			m.bank = 0.5 * sin(t * 0.3 + i)
			var ph := int(t * 0.25 + i * 0.37) % 4
			m.perched = ph == 3
			m.wing_fold = 1.0 if ph >= 2 else 0.0
			m.highlight = (int(t * 0.5) + i) % 3
		if f % 97 == 0:
			var k := rng.randi() % models.size()
			var sp: StringName = ids[rng.randi() % ids.size()]
			models[k].species = sp
			models[k].scale = Vector3.ONE * float(SizeRules.species_data(sp).get("span", 0.3))
		if f % 131 == 0:
			var h := models[rng.randi() % models.size()]
			h.visible = not h.visible
		var nb := BirdBatch.count() + BirdBatch.markers().size()
		var c0 := _canary()
		var a := Time.get_ticks_usec()
		BirdBatch.sync_all(dt)
		var us := Time.get_ticks_usec() - a
		var c1 := _canary()
		syncs.append(us)
		before.append(c0)
		after.append(c1)
		info.append([BirdBatch.last_phases, BirdBatch.last_lod_moves, BirdBatch.count() + BirdBatch.markers().size() - nb])
	var med := func(a: PackedInt32Array) -> float:
		var s := Array(a)
		s.sort()
		return float(s[s.size() / 2])
	var ms: float = med.call(syncs)
	var mb: float = med.call(before)
	var ma: float = med.call(after)
	var own_worst := 0
	var own_at := []
	var machine := 0
	var spikes := 0
	for i in syncs.size():
		if syncs[i] < 3.0 * ms:
			continue
		spikes += 1
		if before[i] < 1.5 * mb and after[i] < 1.5 * ma:
			if syncs[i] > own_worst:
				own_worst = syncs[i]
				own_at = [i, info[i][0], info[i][1], info[i][2]]
		else:
			machine += 1
	var sorted := Array(syncs)
	sorted.sort()
	print("[birds-r4eng] soak: %d frames, sync median %d us, p99 %d, max %d; %d spikes (>3x median): %d with a slow canary, worst with both canaries normal %d us at %s" % [
		syncs.size(), ms, sorted[int(sorted.size() * 0.99)], sorted[sorted.size() - 1], spikes, machine, own_worst, str(own_at)])
	metric("soak_sync_us", {"median": ms, "p99": sorted[int(sorted.size() * 0.99)], "max": sorted[sorted.size() - 1],
		"spikes": spikes, "spikes_with_slow_canary": machine, "worst_own_spike_us": own_worst, "worst_own_spike_frame_phases_moves_batches": str(own_at)})
	# Reported, not gated: on a loaded machine (load average 11-14 when this
	# was written) the thread is also preempted INSIDE a sync with both
	# canaries normal, so "own" spikes of 2-3 ms appeared that the repeated
	# measurement below (test_r4_batch_create_and_release_cost: the same LOD
	# move 400 times, median 11-13 us, max 87-240 us) shows are not the
	# birds' work.
	lt(ms, 1000.0, "median sync under 1 ms (%d us)" % ms)


func test_r4_batch_create_and_release_cost() -> void:
	# The soak's worst unexplained spike was a sync with one LOD move that
	# released a batch (2.2 ms in the "LOD moves and markers" phase). Repeat
	# exactly that 200 times - one lone eagle crossing LOD1 <-> LOD2, so every
	# move releases its old batch and creates the new one - and look at the
	# median, which preemption cannot fake.
	var cam := Camera3D.new()
	add_child(cam)
	cam.current = true
	var m := BirdModels.create(&"eagle")
	add_child(m)
	var ph1 := PackedInt32Array()
	var total := PackedInt32Array()
	var moves := 0
	for k in 400:
		m.position = Vector3(0, 0, -(20.0 if k % 2 == 0 else 200.0))
		BirdBatch.sync_all(1.0 / 72.0)
		if BirdBatch.last_lod_moves > 0:
			moves += 1
			ph1.append(BirdBatch.last_phases.y)
			total.append(BirdBatch.last_sync_usec)
	var s1 := Array(ph1)
	s1.sort()
	var st := Array(total)
	st.sort()
	print("[birds-r4eng] lone-bird LOD move (release + create a batch): %d moves, phase median %d us, p95 %d, max %d; whole sync median %d us" % [
		moves, s1[s1.size() / 2], s1[int(s1.size() * 0.95)], s1[s1.size() - 1], st[st.size() / 2]])
	metric("lod_move_release_create_us", {"moves": moves, "median": s1[s1.size() / 2], "p95": s1[int(s1.size() * 0.95)], "max": s1[s1.size() - 1]})
	gt(moves, 300, "the bird changed LOD on (almost) every step")
	lt(float(s1[s1.size() / 2]), 200.0, "a LOD move that releases and creates a batch costs < 0.2 ms (median)")


func test_r4_marker_batches_are_per_world() -> void:
	# A second world (a SubViewport with its own World3D, as a UI preview or
	# a dev inset might have) gets its own marker batch; emptying one world
	# releases only its batch.
	var sv := SubViewport.new()
	sv.own_world_3d = true
	add_child(sv)
	var c2 := Camera3D.new()
	sv.add_child(c2)
	c2.current = true
	var a := BirdModels.create(&"gull")
	a.position = Vector3(0, 0, -20)
	a.highlight = 1
	add_child(a)
	var b := BirdModels.create(&"gull")
	b.position = Vector3(0, 0, -20)
	b.highlight = 2
	sv.add_child(b)
	a.snap()
	b.snap()
	BirdBatch.sync_all(DT)
	eq(BirdBatch.markers().size(), 2, "one marker batch per world")
	check(a._mark != b._mark, "the two birds are marked in different batches")
	b.free()
	BirdBatch.sync_all(DT)
	eq(BirdBatch.markers().size(), 1, "freeing the second world's bird releases only its marker batch")
	check(a._mark != null and BirdBatch.marker_total() == 1, "the first world's bird keeps its marker")
