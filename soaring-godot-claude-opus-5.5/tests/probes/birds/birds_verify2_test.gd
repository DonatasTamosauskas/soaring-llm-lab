extends TestCase
## Verifier probes, round 1 (engineering & contract lens) for the birds area.
## Independent of the builder's suite: its own triangle-crossing detector
## (self-checked on synthetic cases), the poses a BirdModel actually draws
## while its smoothing blends real owner transitions (fly -> perch, perch ->
## take off, flap -> dive tuck -> flap), a seeded random sweep of the whole
## (phase, amount, fold, perch) cube, folded wings against the tail, the
## perched-feet contract against SizeRules (not the builder's constant),
## deterministic mesh generation, batch bookkeeping under random churn, and
## the CPU cost of 60 birds with every bird highlighted and LOD churning.
##
##   tools/gd.sh birds_verify2 --headless res://tests/runner.tscn -- --dir=res://tests/probes/birds --suite=birds_verify2
##
## Prints "[birds-verify] ..." lines; numbers land in the report metrics.

const DT := 1.0 / 72.0


# --- Own geometry helpers (not the builder's bird_geo.gd) -----------------

static func _groups(arr: Array) -> PackedInt32Array:
	var c0: PackedFloat32Array = arr[Mesh.ARRAY_CUSTOM0]
	var out := PackedInt32Array()
	out.resize(c0.size() / 4)
	for i in out.size():
		out[i] = int(roundf(c0[i * 4]))
	return out


static func _sides(arr: Array) -> PackedFloat32Array:
	var c0: PackedFloat32Array = arr[Mesh.ARRAY_CUSTOM0]
	var out := PackedFloat32Array()
	out.resize(c0.size() / 4)
	for i in out.size():
		out[i] = c0[i * 4 + 1]
	return out


static func _wing(g: int) -> bool:
	return g == BirdPose.G_ARM or g == BirdPose.G_HAND


## Segment p-q passes through the interior of triangle abc (not grazing its
## rim, not ending on it).
static func _through(p: Vector3, q: Vector3, a: Vector3, b: Vector3, c: Vector3) -> bool:
	var hit: Variant = Geometry3D.segment_intersects_triangle(p, q, a, b, c)
	if hit == null:
		return false
	var h: Vector3 = hit
	var l := p.distance_to(q)
	if h.distance_to(p) < 1e-4 * l + 1e-6 or h.distance_to(q) < 1e-4 * l + 1e-6:
		return false
	var n := (b - a).cross(c - a)
	var area := n.length()
	if area < 1e-12:
		return false
	var wa := (c - b).cross(h - b).length() / area
	var wb := (a - c).cross(h - c).length() / area
	var wc := (b - a).cross(h - a).length() / area
	return wa > 2e-3 and wb > 2e-3 and wc > 2e-3


static func _tris_cross(v: PackedVector3Array, t1: int, t2: int) -> bool:
	for e in 3:
		if _through(v[t1 + e], v[t1 + (e + 1) % 3], v[t2], v[t2 + 1], v[t2 + 2]):
			return true
		if _through(v[t2 + e], v[t2 + (e + 1) % 3], v[t1], v[t1 + 1], v[t1 + 2]):
			return true
	return false


## Triangles that share a rest-mesh vertex position are neighbours (seams).
static func _neighbours(rest: PackedVector3Array, t1: int, t2: int) -> bool:
	for i in 3:
		for j in 3:
			if rest[t1 + i].distance_squared_to(rest[t2 + j]) < 1e-12:
				return true
	return false


static func _box(v: PackedVector3Array, t: int) -> AABB:
	return AABB(v[t], Vector3.ZERO).expand(v[t + 1]).expand(v[t + 2]).grow(1e-5)


## Number of crossing pairs between triangle sets a and b (same = a is b).
static func _crossings(v: PackedVector3Array, rest: PackedVector3Array, a: PackedInt32Array, b: PackedInt32Array, same: bool) -> int:
	var bb: Array[AABB] = []
	for t in b:
		bb.append(_box(v, t))
	var n := 0
	for i in a.size():
		var ba := _box(v, a[i])
		for j in range(i + 1 if same else 0, b.size()):
			if not ba.intersects(bb[j]):
				continue
			if _neighbours(rest, a[i], b[j]):
				continue
			if _tris_cross(v, a[i], b[j]):
				n += 1
	return n


static func _sets(arr: Array) -> Dictionary:
	var g := _groups(arr)
	var sd := _sides(arr)
	var r := PackedInt32Array()
	var l := PackedInt32Array()
	var tail := PackedInt32Array()
	for t in range(0, g.size(), 3):
		if _wing(g[t]):
			if sd[t] > 0.0:
				r.append(t)
			else:
				l.append(t)
		elif g[t] == BirdPose.G_TAIL:
			tail.append(t)
	return {"r": r, "l": l, "tail": tail, "g": g}


## Worst inverted wing/tail triangle count in a posed mesh.
static func _inverted(arr: Array, inst: Vector4, g: PackedInt32Array) -> int:
	var res := BirdPose.pose_arrays_with_normals(arr, inst)
	var v: PackedVector3Array = res[0]
	var nn: PackedVector3Array = res[1]
	var rest: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var bad := 0
	for t in range(0, v.size(), 3):
		if not _wing(g[t]) and g[t] != BirdPose.G_TAIL:
			continue
		var cr := (v[t + 1] - v[t]).cross(v[t + 2] - v[t])
		var cr0 := (rest[t + 1] - rest[t]).cross(rest[t + 2] - rest[t])
		var ns := nn[t] + nn[t + 1] + nn[t + 2]
		if cr.dot(ns) > 1e-4 * cr0.length() * ns.length():
			bad += 1
	return bad


## Outer wing vertices (hand; arm beyond 60 % to the wrist) inside the body.
static func _inside_body(sp: StringName, arr: Array, inst: Vector4, g: PackedInt32Array) -> Array:
	var v := BirdPose.pose_arrays(arr, inst, 0.0, 0.0, true)
	var rest: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var c1: PackedFloat32Array = arr[Mesh.ARRAY_CUSTOM1]
	var c2: PackedFloat32Array = arr[Mesh.ARRAY_CUSTOM2]
	var inside := 0
	var worst := INF
	for i in v.size():
		if not _wing(g[i]):
			continue
		var sx := c1[i * 4]
		var wx := c2[i * 4]
		if g[i] == BirdPose.G_ARM and absf(rest[i].x) <= sx + 0.6 * (wx - sx) + 1e-4:
			continue
		var sec := BirdMeshBuilder.body_section(sp, v[i].z)
		if sec == Vector3.ZERO:
			continue
		var e := pow(v[i].x / sec.x, 2.0) + pow((v[i].y - sec.z) / sec.y, 2.0)
		worst = minf(worst, e)
		if e < 0.98:
			inside += 1
	return [inside, worst]


# --- Tests ------------------------------------------------------------------

func test_probe_crossing_detector_self_check() -> void:
	# Two triangles piercing each other, two touching along an edge, two apart.
	var v := PackedVector3Array([
		Vector3(-1, 0, -1), Vector3(1, 0, -1), Vector3(0, 0, 1),
		Vector3(0, -1, 0), Vector3(0, 1, 0.2), Vector3(0.3, 1, -0.4),
		Vector3(-1, 0, -1), Vector3(1, 0, -1), Vector3(0, 1, -2),
		Vector3(5, 5, 5), Vector3(6, 5, 5), Vector3(5, 6, 5),
	])
	var rest := PackedVector3Array()
	for i in v.size():
		rest.append(Vector3(i * 10, 0, 0))
	check(_tris_cross(v, 0, 3), "detector: piercing triangles cross")
	check(not _tris_cross(v, 0, 6), "detector: edge-sharing triangles do not cross")
	check(not _tris_cross(v, 0, 9), "detector: separate triangles do not cross")
	eq(_crossings(v, rest, PackedInt32Array([0]), PackedInt32Array([3, 6, 9]), false), 1, "detector counts one crossing pair")


## Owner field settings before (step 0) and after (step 1) a transition.
static func _apply(m: BirdModel, kind: String, step: int) -> void:
	match kind + str(step):
		"fly->perch0", "flap->dive0", "half-tuck flapping0":
			m.flap_amount = 1.0
		"fly->perch1":
			m.perched = true
			m.wing_fold = 1.0
			m.flap_amount = 0.0
		"perch->takeoff0":
			m.perched = true
			m.wing_fold = 1.0
		"perch->takeoff1":
			m.perched = false
			m.wing_fold = 0.0
			m.flap_amount = 1.0
		"flap->dive1":
			m.wing_fold = 1.0
			m.flap_amount = 0.0
		"dive->flap0":
			m.wing_fold = 1.0
		"dive->flap1":
			m.wing_fold = 0.0
			m.flap_amount = 1.0
		"half-tuck flapping1":
			m.wing_fold = 0.5


## Drives a model through an owner transition and returns every drawn pose
## (BirdModel.displayed_pose) frame by frame.
func _drawn_poses(sp: StringName, kind: String, frames: int) -> Array[Vector4]:
	var m := BirdModels.create(sp)
	add_child(m)
	_apply(m, kind, 0)
	m.snap()
	BirdBatch.sync_all(DT)
	_apply(m, kind, 1)
	var out: Array[Vector4] = []
	var phase := m.flap_phase
	for f in frames:
		# The owner keeps beating at 5 Hz whenever it flaps.
		phase = fposmod(phase + DT * 5.0, 1.0)
		m.flap_phase = phase
		BirdBatch.sync_all(DT)
		out.append(m.displayed_pose())
	m.free()
	return out


func test_probe_transition_poses_are_clean() -> void:
	# The suite checks 36 hand-picked poses. What is drawn in a transition is
	# a blend with different time constants per field (fold 0.10 s, perch
	# 0.16 s, amount 0.12 s): check every other drawn frame of real
	# transitions.
	var trans := ["fly->perch", "perch->takeoff", "flap->dive", "dive->flap", "half-tuck flapping"]
	var report := {}
	var total_bad := 0
	for sp in BirdSpecies.IDS:
		var arr := BirdModels.mesh(sp, 0).surface_get_arrays(0)
		var rest: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var s := _sets(arr)
		var row := {}
		for k in trans:
			var poses := _drawn_poses(sp, k, 40)
			var lr := 0
			var selfx := 0
			var inv := 0
			var inside := 0
			var worst_e := INF
			var first := ""
			for i in range(0, poses.size(), 2):
				var inst := poses[i]
				var v := BirdPose.pose_arrays(arr, inst)
				var a := _crossings(v, rest, s["r"], s["l"], false)
				var b := _crossings(v, rest, s["r"], s["r"], true)
				var c := _inverted(arr, inst, s["g"])
				var ib: Array = _inside_body(sp, arr, inst, s["g"])
				if (a + b + c + int(ib[0])) > 0 and first == "":
					first = "frame %d %s" % [i, str(inst)]
				lr += a
				selfx += b
				inv += c
				inside += int(ib[0])
				worst_e = minf(worst_e, float(ib[1]))
			row[k] = {"lr": lr, "self": selfx, "inverted": inv, "inside_body": inside, "closest_e": snappedf(worst_e, 0.001), "first": first}
			total_bad += lr + selfx + inv + inside
			if lr + selfx + inv + inside > 0:
				print("[birds-verify] %s %s: lr %d self %d inverted %d inside %d (%s)" % [sp, k, lr, selfx, inv, inside, first])
		report[String(sp)] = row
	metric("transitions", report)
	eq(total_bad, 0, "drawn transition frames: no crossing, inverted or in-body wing geometry")


func test_probe_random_pose_sweep() -> void:
	# The whole (phase, amount, fold, perch) cube, seeded, LOD0 and LOD1.
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260926
	var report := {}
	var total := 0
	for sp in BirdSpecies.IDS:
		for lod in 2:
			var arr := BirdModels.mesh(sp, lod).surface_get_arrays(0)
			var rest: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var s := _sets(arr)
			var bad := 0
			var worst := ""
			for i in 40:
				var inst := Vector4(rng.randf(), rng.randf(), rng.randf(), rng.randf())
				var v := BirdPose.pose_arrays(arr, inst)
				var n := _crossings(v, rest, s["r"], s["l"], false) + _crossings(v, rest, s["r"], s["r"], true) + _inverted(arr, inst, s["g"])
				if n > 0:
					bad += 1
					if worst == "":
						worst = str(inst)
			report["%s_lod%d" % [sp, lod]] = [bad, worst]
			total += bad
			if bad > 0:
				print("[birds-verify] random sweep %s LOD%d: %d/40 poses with crossings/inversions (first %s)" % [sp, lod, bad, worst])
	metric("random_sweep_bad_poses", report)
	eq(total, 0, "random (phase, amount, fold, perch) poses: no crossing or inverted wing")


func test_probe_folded_wings_vs_tail() -> void:
	# Not in the suite: a folded wing lying along the tail must not pass
	# through it (perched, dive tuck, and the perch blend).
	var report := {}
	var total := 0
	for sp in BirdSpecies.IDS:
		if sp == &"moth":
			continue
		var arr := BirdModels.mesh(sp, 0).surface_get_arrays(0)
		var rest: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var s := _sets(arr)
		var wings := PackedInt32Array(s["r"])
		wings.append_array(s["l"])
		var row := {}
		for inst in [Vector4(0.25, 0, 1, 1), Vector4(0.25, 0, 1, 0), Vector4(0.25, 0, 1, 0.5), Vector4(0.25, 0, 0.7, 0.4), Vector4(0.6, 1, 0.3, 0)]:
			var v := BirdPose.pose_arrays(arr, inst)
			var n := _crossings(v, rest, wings, s["tail"], false)
			row[str(inst)] = n
			total += n
			if n > 0:
				print("[birds-verify] %s wing passes through tail at %s: %d pairs" % [sp, str(inst), n])
		report[String(sp)] = row
	metric("wing_tail_crossings", report)
	eq(total, 0, "folded wings never pass through the tail")


func test_probe_perched_feet_match_sizerules() -> void:
	# Contract: feet on the perch grip = SizeRules.body_radius_for_mass /
	# wingspan below the body centre. The suite compares against the
	# builder's own FOOT_DEPTH, so a drift on either side would go unseen.
	var report := {}
	for i in SizeRules.SPECIES.size():
		var d: Dictionary = SizeRules.SPECIES[i]
		var sp: StringName = d["id"]
		var m: float = d["mass"]
		var want := SizeRules.body_radius_for_mass(m) / SizeRules.wingspan_for_mass(m)
		var arr := BirdModels.mesh(sp, 0).surface_get_arrays(0)
		var g := _groups(arr)
		var v := BirdPose.pose_arrays(arr, Vector4(0.25, 0.0, 1.0, 1.0))
		var low := INF
		for k in v.size():
			if g[k] == BirdPose.G_LEG:
				low = minf(low, v[k].y)
		near(-low, want, 0.006, "%s perched feet at SizeRules body radius / span" % sp)
		report[String(sp)] = [snappedf(-low, 1e-4), snappedf(want, 1e-4)]
	metric("feet_vs_sizerules", report)


func test_probe_mesh_generation_is_deterministic() -> void:
	for sp in BirdSpecies.IDS:
		for lod in BirdModels.LOD_COUNT:
			var a: Dictionary = BirdMeshBuilder.build(sp, lod, BirdModels.normalisation(sp) if lod > 0 else {})
			var b: Dictionary = BirdMeshBuilder.build(sp, lod, BirdModels.normalisation(sp) if lod > 0 else {})
			var va: PackedVector3Array = a["arrays"][Mesh.ARRAY_VERTEX]
			var vb: PackedVector3Array = b["arrays"][Mesh.ARRAY_VERTEX]
			var cached: PackedVector3Array = BirdModels.mesh(sp, lod).surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
			check(va == vb, "%s LOD%d: two builds are identical" % [sp, lod])
			eq(va.size(), cached.size(), "%s LOD%d: build matches the cached mesh" % [sp, lod])


func test_probe_batch_bookkeeping_under_churn() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 77
	var cam := Camera3D.new()
	add_child(cam)
	cam.current = true
	var holders: Array[Node3D] = []
	var models: Array[BirdModel] = []
	for i in 24:
		var h := Node3D.new()
		add_child(h)
		var m := BirdModels.create(BirdSpecies.IDS[i % 10])
		h.add_child(m)
		holders.append(h)
		models.append(m)
	var broken := 0
	for step in 400:
		var i := rng.randi() % models.size()
		var m := models[i]
		match rng.randi() % 7:
			0:
				m.visible = not m.visible
			1:
				holders[i].visible = not holders[i].visible
			2:
				m.species = BirdSpecies.IDS[rng.randi() % 10]
			3:
				holders[i].position = Vector3(0, 0, -rng.randf_range(1.0, 200.0))
			4:
				m.render_layers = 1 if m.render_layers == 2 else 2
			5:
				if m.get_parent() == holders[i]:
					holders[i].remove_child(m)
				else:
					holders[i].add_child(m)
			6:
				m.cast_shadows = not m.cast_shadows
		m.highlight = rng.randi() % 3
		BirdBatch.sync_all(DT)
		# Invariants: every drawn model sits in exactly one batch at its slot;
		# hidden or detached models in none; each slot's buffer holds its
		# model's transform origin.
		var drawn := 0
		for mm in models:
			if mm.is_inside_tree() and mm.is_visible_in_tree():
				drawn += 1
				if mm._batch == null or mm._slot < 0 or mm._batch.models[mm._slot] != mm:
					broken += 1
				else:
					var o: int = mm._slot * BirdBatch.STRIDE
					var org := Vector3(mm._batch.buf[o + 3], mm._batch.buf[o + 7], mm._batch.buf[o + 11])
					if org.distance_to(mm.global_position) > 1e-4:
						broken += 1
			elif mm._batch != null:
				broken += 1
		if BirdBatch.instance_total() != drawn:
			broken += 1
	eq(broken, 0, "batch bookkeeping stays consistent over 400 random operations")
	for h in holders:
		h.free()
	for m in models:
		if is_instance_valid(m):
			m.free()
	cam.free()
	BirdBatch.sync_all(DT)
	eq(BirdBatch.count(), 0, "every batch released after the churn")


func test_probe_cpu_worst_case_all_highlighted_lod_churn() -> void:
	# The suite's 60-bird cost has a third of the birds highlighted and LODs
	# that settle. Here every bird is highlighted (the min-size path) and
	# half of them oscillate across a LOD threshold every frame, forcing a
	# batch move per frame each (the worst the LOD code can be driven to).
	var cam := Camera3D.new()
	add_child(cam)
	cam.current = true
	var holders: Array[Node3D] = []
	var models: Array[BirdModel] = []
	for i in 60:
		var h := Node3D.new()
		add_child(h)
		var sp: StringName = BirdSpecies.IDS[i % 10]
		var m := BirdModels.create(sp)
		var span: float = SizeRules.species_data(sp)["span"]
		m.scale = Vector3.ONE * span
		m.highlight = 1 + i % 2
		h.add_child(m)
		holders.append(h)
		models.append(m)
	var times := PackedFloat32Array()
	var moves := 0
	for f in 120:
		for i in 60:
			var span: float = models[i].scale.x
			# Alternate well inside LOD0 and well inside LOD1 for half the flock.
			var d := span / BirdModel.LOD0_ANGLE * (0.6 if (f + i) % 2 == 0 else 1.6) if i % 2 == 0 else 30.0 + i
			holders[i].position = Vector3(sin(i) * 0.2 * d, 0, -d)
			models[i].flap_phase = fposmod(f * DT * 5.0 + i * 0.1, 1.0)
			models[i].flap_amount = 1.0
		var lods0 := []
		for m in models:
			lods0.append(m.get_lod())
		var t0 := Time.get_ticks_usec()
		BirdBatch.sync_all(DT)
		var us := float(Time.get_ticks_usec() - t0)
		for i in 60:
			if models[i].get_lod() != lods0[i]:
				moves += 1
		if f >= 10:
			times.append(us)
	var sorted := Array(times)
	sorted.sort()
	var med: float = sorted[sorted.size() / 2]
	var p95: float = sorted[int(sorted.size() * 0.95)]
	print("[birds-verify] worst-case 60 birds: median %.0f us, p95 %.0f us, %d LOD moves" % [med, p95, moves])
	metric("worst_case_sync_us_median", med)
	metric("worst_case_sync_us_p95", p95)
	metric("lod_moves", moves)
	gt(moves, 1000, "the churn really moved birds between LOD batches")
	lt(med, 1000.0, "60 highlighted birds with LOD churn: median < 1 ms (headless: RenderingServer is a dummy)")
	for h in holders:
		h.free()
	cam.free()


## The LOD a model is actually drawn with: its batch's mesh.
static func _drawn_lod(m: BirdModel) -> int:
	if m._batch == null:
		return -1
	for l in BirdModels.LOD_COUNT:
		if m._batch.mesh == BirdModels.mesh(m.species, l):
			return l
	return -2


func test_probe_drawn_lod_matches_reported_lod() -> void:
	# get_lod() is what the model reports; the batch's mesh is what is
	# drawn. Spawning far, hiding far and re-showing close, re-parenting and
	# the ordinary walk must keep the two equal.
	var cam := Camera3D.new()
	add_child(cam)
	cam.current = true
	BirdBatch.sync_all(DT)  # the camera cache now knows this camera
	var report := {}
	# 1. Spawned far away (like an Ecosystem spawn out of view).
	var holder := Node3D.new()
	add_child(holder)
	holder.position = Vector3(0, 0, -150)
	var m := BirdModels.create(&"hawk")
	holder.add_child(m)
	for f in 5:
		BirdBatch.sync_all(DT)
	report["spawn_far"] = [m.get_lod(), _drawn_lod(m)]
	eq(_drawn_lod(m), m.get_lod(), "spawned 150 m away: drawn LOD == reported LOD")
	eq(_drawn_lod(m), 2, "spawned 150 m away: drawn at LOD2")
	# 2. Hidden far, moved close, shown again (pooling / refuge exit).
	m.visible = false
	holder.position = Vector3(0, 0, -4)
	m.visible = true
	for f in 5:
		BirdBatch.sync_all(DT)
	report["reshown_close"] = [m.get_lod(), _drawn_lod(m)]
	eq(_drawn_lod(m), m.get_lod(), "re-shown 4 m away: drawn LOD == reported LOD")
	eq(_drawn_lod(m), 0, "re-shown 4 m away: drawn at LOD0")
	# 3. The builder's own 60-bird budget scene: how many draw a LOD other
	# than the one they report.
	var holders: Array[Node3D] = []
	var models: Array[BirdModel] = []
	cam.position = Vector3(0, 20, 60)
	for i in 60:
		var h := Node3D.new()
		add_child(h)
		var sp: StringName = BirdSpecies.IDS[i % 10]
		var bm := BirdModels.create(sp)
		bm.scale = Vector3.ONE * float(SizeRules.species_data(sp)["span"])
		h.add_child(bm)
		holders.append(h)
		models.append(bm)
	var t := 0.0
	for f in 150:
		t += DT
		for i in 60:
			var a := t * 0.3 + i * 0.37
			holders[i].position = Vector3(cos(a) * (20.0 + i), 10.0 + sin(a * 2.0) * 3.0, sin(a) * (20.0 + i))
		BirdBatch.sync_all(DT)
	var rep := [0, 0, 0]
	var drawn := [0, 0, 0]
	var wrong := 0
	for bm in models:
		rep[bm.get_lod()] += 1
		var d := _drawn_lod(bm)
		if d >= 0:
			drawn[d] += 1
		if d != bm.get_lod():
			wrong += 1
	report["budget_scene"] = {"reported": rep, "drawn": drawn, "mismatched": wrong}
	print("[birds-verify] LOD reported vs drawn: %s" % str(report))
	metric("lod_reported_vs_drawn", report)
	eq(wrong, 0, "60-bird budget scene: every bird drawn at the LOD it reports")
	for h in holders:
		h.free()
	holder.free()
	cam.free()
	BirdBatch.sync_all(DT)


func test_probe_owner_max_flap_rate_drawn_monotonic() -> void:
	# NpcBird beats at up to SpeciesProfile.flap_hz * 1.15 (14 Hz cap, i.e.
	# ~16 Hz for a moth at full effort). A steady beat must be drawn moving
	# forward every frame (no reversal) at 72 and 90 Hz.
	var report := {}
	for fps in [72.0, 90.0]:
		for hz in [8.0, 12.0, 16.1]:
			var m := BirdModels.create(&"moth")
			add_child(m)
			m.flap_amount = 1.0
			m.snap()
			BirdBatch.sync_all(1.0 / fps)
			var phase := 0.0
			var back := 0
			var lag := 0.0
			var prev := m.displayed_pose().x
			for f in 144:
				phase = fposmod(phase + hz / fps, 1.0)
				m.flap_phase = phase
				BirdBatch.sync_all(1.0 / fps)
				var shown := m.displayed_pose().x
				if wrapf(shown - prev, -0.5, 0.5) < -1e-6:
					back += 1
				if f > 36:
					lag = maxf(lag, absf(wrapf(shown - phase, -0.5, 0.5)))
				prev = shown
			report["%d fps %.1f Hz" % [fps, hz]] = {"reversals": back, "late_lag": snappedf(lag, 0.001)}
			eq(back, 0, "%.0f fps, %.1f Hz beat: drawn phase never runs backwards" % [fps, hz])
			lt(lag, 0.01, "%.0f fps, %.1f Hz beat: drawn phase locks on after 0.5 s" % [fps, hz])
			m.free()
	metric("fast_beats", report)


func test_probe_perch_blend_wing_vs_tail() -> void:
	# Landing blends fold (tau 0.10 s) and perch (0.16 s): fold reaches ~1
	# while perch is still 0.5-0.95. Sweep that band for every species.
	var report := {}
	var total := 0
	for sp in BirdSpecies.IDS:
		if sp == &"moth":
			continue
		var arr := BirdModels.mesh(sp, 0).surface_get_arrays(0)
		var rest: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var s := _sets(arr)
		var wings := PackedInt32Array(s["r"])
		wings.append_array(s["l"])
		var hits := []
		for fi in 3:
			var fold := 0.95 + fi * 0.025
			for pi in 11:
				var perch := pi * 0.1
				var v := BirdPose.pose_arrays(arr, Vector4(0.25, 0.0, fold, perch))
				var n := _crossings(v, rest, wings, s["tail"], false)
				if n > 0:
					hits.append([snappedf(fold, 0.001), snappedf(perch, 0.01), n])
		report[String(sp)] = hits
		total += hits.size()
		if not hits.is_empty():
			print("[birds-verify] %s wing through tail during the perch blend: %s" % [sp, str(hits)])
	metric("perch_blend_wing_tail", report)
	eq(total, 0, "no wing passes through the tail anywhere in the landing blend")


func test_probe_landing_trajectory_wing_vs_tail() -> void:
	# The drawn frames of a real landing (NpcBird sets perched + fold 1
	# together), from a glide and from a dive tuck (fold already 1).
	var report := {}
	var total := 0
	for sp in BirdSpecies.IDS:
		if sp == &"moth":
			continue
		var arr := BirdModels.mesh(sp, 0).surface_get_arrays(0)
		var rest: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var s := _sets(arr)
		var wings := PackedInt32Array(s["r"])
		wings.append_array(s["l"])
		for kind in ["fly->perch", "dive->perch"]:
			var m := BirdModels.create(sp)
			add_child(m)
			m.wing_fold = 1.0 if kind == "dive->perch" else 0.0
			m.snap()
			BirdBatch.sync_all(DT)
			m.perched = true
			m.wing_fold = 1.0
			var bad := []
			for f in 150:
				BirdBatch.sync_all(DT)
				var inst := m.displayed_pose()
				var n := _crossings(BirdPose.pose_arrays(arr, inst), rest, wings, s["tail"], false)
				if n > 0:
					bad.append([f, snappedf(inst.z, 0.001), snappedf(inst.w, 0.001), n])
			m.free()
			report["%s %s" % [sp, kind]] = bad.size()
			total += bad.size()
			if not bad.is_empty():
				print("[birds-verify] %s %s: wing through tail on %d of 150 drawn frames (first %s, last %s)" % [sp, kind, bad.size(), str(bad[0]), str(bad[bad.size() - 1])])
	metric("landing_wing_tail_frames", report)
	eq(total, 0, "no drawn landing frame has a wing through the tail")
