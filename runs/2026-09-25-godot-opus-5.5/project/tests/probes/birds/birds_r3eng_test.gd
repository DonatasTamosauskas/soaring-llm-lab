extends TestCase
## Round-3 engineering verifier probes for the birds area (read-only on the
## area's sources). Each probe states what it pins; numbers land in the
## report (artifacts/tests/report_<suite>.json) for the verdict.

const Geo := preload("res://tests/unit/birds/bird_geo.gd")
const Anim := preload("res://tests/unit/birds/birds_animation_test.gd")
const DT := 1.0 / 72.0


func after_each() -> void:
	for c in get_children():
		c.free()
	BirdBatch.sync_all(DT)


## The builder's wing/tail and left/right crossing sweeps over the whole
## fold x perch x beat space run at LOD0 (tail) or over the 35-pose set
## (left/right). The hug is baked from LOD0 and applied to LOD1/LOD2 by
## spanwise position, and far LODs rescale body/chords: pin the far LODs over
## the same 420-pose space.
func test_r3_far_lods_clean_over_the_pose_space() -> void:
	var report := {}
	var total := 0
	for sp in BirdSpecies.IDS:
		for lod in [1, 2]:
			var arr := Geo.arrays(sp, lod)
			var rest: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var right := Geo.wing_tris(arr, 1.0)
			var left := Geo.wing_tris(arr, -1.0)
			var wings := right.duplicate()
			wings.append_array(left)
			var tail := Geo.tail_tris(arr)
			var r := Geo.rig(sp, lod)
			var n := 0
			var first := ""
			for inst in Anim._space():
				var v := Geo.posed_subset(r, inst, r["wing_tail_idx"])
				var c := Geo.count_crossings(v, rest, right, left, false)
				if not tail.is_empty() and inst.z >= 0.35:
					c += Geo.count_crossings(v, rest, wings, tail, false)
				if c > 0 and first == "":
					first = str(inst)
				n += c
			report["%s_lod%d" % [sp, lod]] = [n, first]
			total += n
	metric("far_lod_crossings", report)
	eq(total, 0, "LOD1/LOD2: no wing/wing or wing/tail crossings over the fold x perch x beat space")


## An owner that puts its bird at NaN for a frame: nothing NaN reaches the
## GPU, and the bird is drawn again once the position is sane.
func test_r3_nan_position_draws_nothing_then_recovers() -> void:
	var m := BirdModels.create(&"gull")
	m.lod_override = 0
	add_child(m)
	m.position = Vector3(NAN, 1, 1)
	BirdBatch.sync_all(DT)
	var o := m._slot * BirdBatch.STRIDE
	var finite := true
	for k in BirdBatch.STRIDE:
		finite = finite and is_finite(m._batch.buf[o + k])
	check(finite, "NaN position: batch data finite")
	m.position = Vector3(1, 2, 3)
	BirdBatch.sync_all(DT)
	near(m._batch.buf[m._slot * BirdBatch.STRIDE + 3], 1.0, 1e-5, "sane again: drawn at its position")


## A bird under a PROCESS_MODE_ALWAYS parent (e.g. anything under the XR
## rig) keeps animating while the tree is paused; a pausable one holds.
func test_r3_pause_respects_process_mode() -> void:
	var holder := Node3D.new()
	holder.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(holder)
	var a := BirdModels.create(&"sparrow")
	holder.add_child(a)
	var p := BirdModels.create(&"sparrow")
	p.process_mode = Node.PROCESS_MODE_PAUSABLE
	add_child(p)
	for m in [a, p]:
		m.flap_amount = 0.0
		m.snap()
	BirdBatch.sync_all(DT)
	get_tree().paused = true
	a.flap_amount = 1.0
	p.flap_amount = 1.0
	for i in 20:
		BirdBatch.sync_all(DT)
	get_tree().paused = false
	gt(a.displayed_pose().y, 0.8, "ALWAYS parent: animates while paused")
	near(p.displayed_pose().y, 0.0, 1e-6, "pausable: holds while paused")


## The hug table (and the whole mesh) builds identically twice.
func test_r3_mesh_and_hug_deterministic() -> void:
	var same := true
	for sp in BirdSpecies.IDS:
		for lod in BirdModels.LOD_COUNT:
			var a := BirdMeshBuilder.build(sp, lod, BirdModels.normalisation(sp) if lod > 0 else {})
			var b := BirdMeshBuilder.build(sp, lod, BirdModels.normalisation(sp) if lod > 0 else {})
			var aa: Array = a["arrays"]
			var bb: Array = b["arrays"]
			for k in [Mesh.ARRAY_VERTEX, Mesh.ARRAY_TEX_UV2, Mesh.ARRAY_CUSTOM0, Mesh.ARRAY_COLOR]:
				if aa[k] != bb[k]:
					same = false
	check(same, "every mesh (hug UV2 included) builds bit-identically twice")


## Readable angles per species (for the docs' list) and the marker fade band.
func test_r3_readable_angles() -> void:
	var t := {}
	for sp in BirdSpecies.IDS:
		var a := BirdModels.min_highlight_angle(sp)
		var span := float(SizeRules.species_data(sp)["span"])
		t[String(sp)] = {"deg": snappedf(rad_to_deg(a), 0.01), "fade_band_m": [snappedf(span / (a * 1.15), 0.1), snappedf(span / a, 0.1)]}
	metric("readable_angle_and_fade_band", t)
	check(true, "reported")


## 40 fast birds whose trails all start wanting to draw in the same frame:
## how many trails draw at once in the first frames (budget MAX_ACTIVE).
func test_r3_trail_budget_on_a_simultaneous_start() -> void:
	var cam := Camera3D.new()
	add_child(cam)
	cam.current = true
	var trails: Array[WingTrails] = []
	for i in 40:
		var h := Node3D.new()
		add_child(h)
		var m := BirdModels.create(&"hawk")
		h.add_child(m)
		var tr := BirdFX.attach_trails(m)
		tr.min_speed = 1.0
		trails.append(tr)
	var per_frame := []
	var worst := 0
	for f in 30:
		for i in 40:
			(trails[i].get_parent().get_parent() as Node3D).position = Vector3(i * 2.0, 0.0, -10.0 - i * 3.0 - f * 0.5)
		for tr in trails:
			tr.step(DT)
		BirdBatch.sync_all(DT)
		var n := 0
		for tr in trails:
			if tr._drawn:
				n += 1
		per_frame.append(n)
		worst = maxi(worst, n)
	metric("trails_drawing_per_frame", per_frame)
	metric("trails_drawing_max", worst)
	check(true, "reported (budget %d)" % WingTrails.MAX_ACTIVE)
