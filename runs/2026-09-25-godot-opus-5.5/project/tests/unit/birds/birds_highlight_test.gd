extends TestCase
## B4 (headless part): how big a highlighted bird is drawn, the marker that
## carries far readability instead, and a model's robustness to bad owner
## values. The colours and readability themselves are measured rendered, in
## the world's light (tests/shots/birds_highlight.gd).
##
## A highlighted bird is drawn at its true size at every distance: it looms
## exactly as it should while the player closes in, and prey never looks
## bigger than the hunter. What makes a far one readable is the marker (a
## ring = edible, a triangle = danger) the shader draws around it.

const DT := 1.0 / 72.0


## A stand-in for the player: the bird the highlights are drawn for.
class Hunter:
	extends Bird

	func is_player() -> bool:
		return true


var _cam: Camera3D


func before_each() -> void:
	_cam = Camera3D.new()
	add_child(_cam)
	_cam.current = true


func after_each() -> void:
	for c in get_children():
		c.free()
	BirdBatch.sync_all(DT)


func _hunter(sp: StringName) -> Hunter:
	var h := Hunter.new()
	h.species = sp
	h.mass = float(SizeRules.species_data(sp)["mass"])
	add_child(h)
	return h


func _prey(sp: StringName, state: int) -> BirdModel:
	var m := BirdModels.create(sp)
	m.scale = Vector3.ONE * float(SizeRules.species_data(sp)["span"])
	m.highlight = state
	add_child(m)
	m.snap()
	return m


## Drawn wingspans (m) and angles (rad) of `m` flown in from `far` to 0.3 m.
func _approach(m: BirdModel, far: float) -> Array:
	var spans := PackedFloat32Array()
	var angles := PackedFloat32Array()
	var d := far
	while d > 0.3:
		m.position = Vector3(0.0, 0.0, -d)
		BirdBatch.sync_all(DT)
		var s := m._xf.basis.x.length()
		spans.append(s)
		angles.append(s / m._xf.origin.distance_to(_cam.global_position))
		d *= 0.97
	return [spans, angles]


func test_highlighted_prey_looms_and_stays_smaller_than_the_hunter() -> void:
	# Every hunter/prey pair the game can highlight (the player is never
	# smaller than GameLoop's start mass, a sparrow), from beyond the
	# highlight range to a catch: the prey's drawn angle grows at every step
	# (as 1 / distance: true size), and it is never drawn wider than the
	# hunter's own wingspan. The same with no player registered at all.
	var worst_share := [0.0, ""]
	var worst_growth := 0.0
	var pairs := 0
	var shrink_steps := 0
	for hsp: StringName in BirdSpecies.IDS:
		var hmass := float(SizeRules.species_data(hsp)["mass"])
		if hmass < 0.03:
			continue
		var h := _hunter(hsp)
		var hspan := h.get_wingspan()
		for psp: StringName in BirdSpecies.IDS:
			var pd := SizeRules.species_data(psp)
			if not SizeRules.is_worthwhile(hmass, float(pd["mass"])):
				continue
			pairs += 1
			var m := _prey(psp, 1)
			var r := _approach(m, 160.0)
			var spans: PackedFloat32Array = r[0]
			var angles: PackedFloat32Array = r[1]
			var span := float(pd["span"])
			for i in spans.size():
				if i > 0 and angles[i] <= angles[i - 1]:
					shrink_steps += 1
				worst_growth = maxf(worst_growth, absf(spans[i] / span - 1.0))
				if spans[i] / hspan > worst_share[0]:
					worst_share = [spans[i] / hspan, "%s hunting %s" % [hsp, psp]]
			m.free()
		h.free()
	for sp: StringName in BirdSpecies.IDS:
		for st in [1, 2]:
			var m := _prey(sp, st)
			var r := _approach(m, 160.0)
			var spans: PackedFloat32Array = r[0]
			var angles: PackedFloat32Array = r[1]
			for i in spans.size():
				if i > 0 and angles[i] <= angles[i - 1]:
					shrink_steps += 1
				worst_growth = maxf(worst_growth, absf(spans[i] / float(SizeRules.species_data(sp)["span"]) - 1.0))
			m.free()
	gt(pairs, 10, "every edible pair was flown (%d)" % pairs)
	eq(shrink_steps, 0, "a highlighted bird's drawn size grows at every step of an approach")
	lt(worst_share[0], 1.0, "prey never drawn wider than the hunter's own wingspan (widest %.2f x, %s)" % [worst_share[0], worst_share[1]])
	lt(worst_growth, 1e-4, "highlighted birds are drawn at their true size (off by %.5f)" % worst_growth)
	metric("edible_pairs_flown", pairs)
	metric("widest_prey_vs_hunter_span", [snappedf(worst_share[0], 0.001), worst_share[1]])


func test_scaled_to_nothing_stays_nothing() -> void:
	# A highlighted bird scaled to 0 (or nearly) is drawn at that size, with
	# finite numbers: no NaN in its batch, no re-inflation.
	for s in [0.0, 1e-9]:
		var m := _prey(&"crow", 1)
		m.scale = Vector3.ONE * s
		m.position = Vector3(0, 0, -30)
		BirdBatch.sync_all(DT)
		var ok := true
		var o := m._slot * BirdBatch.STRIDE
		for f in BirdBatch.STRIDE:
			ok = ok and is_finite(m._batch.buf[o + f])
		check(ok, "scale %s: the batch holds finite numbers" % s)
		lt(m._xf.basis.x.length(), s + 1e-12, "scale %s: drawn at that size" % s)
		m.free()


func test_bad_owner_values_do_not_stick() -> void:
	# One frame of NaN or INF in a field is ignored (the last good value
	# stays), never written into the batch, and the model keeps working.
	var cases := [["flap_phase", NAN], ["flap_phase", INF], ["flap_amount", NAN], ["wing_fold", NAN],
		["wing_fold", -INF], ["bank", NAN], ["bank", INF]]
	for c in cases:
		var m := _prey(&"hawk", 0)
		m.position = Vector3(0, 0, -8)
		m.flap_amount = 1.0
		m.snap()
		BirdBatch.sync_all(DT)
		m.set(c[0], c[1])
		var bad := 0
		for f in 72:
			if f == 1:
				# Sane values again after the one bad frame.
				m.flap_phase = 0.3
				m.flap_amount = 1.0
				m.wing_fold = 0.0
				m.bank = 0.4
			m.flap_phase = fposmod(m.flap_phase + DT * 5.0, 1.0) if f > 1 else m.flap_phase
			BirdBatch.sync_all(DT)
			var o := m._slot * BirdBatch.STRIDE
			for k in BirdBatch.STRIDE:
				if not is_finite(m._batch.buf[o + k]):
					bad += 1
		eq(bad, 0, "%s = %s for a frame: batch data stays finite" % c)
		near(m.displayed_bank(), 0.4, 0.01, "%s = %s: bank works again" % c)
		near(m.displayed_pose().y, 1.0, 0.01, "%s = %s: the beat is drawn again" % c)
		m.free()


func test_nan_position_draws_nothing_then_recovers() -> void:
	# An owner that puts its bird at NaN or INF for a frame: nothing
	# non-finite reaches the GPU (the bird is drawn at scale 0 at the origin),
	# and it is drawn at its position again as soon as that is sane.
	for bad in [Vector3(NAN, 1, 1), Vector3(1, INF, 1)]:
		var m := _prey(&"gull", 1)
		m.lod_override = 0
		m.position = bad
		BirdBatch.sync_all(DT)
		var o := m._slot * BirdBatch.STRIDE
		var finite := true
		for k in BirdBatch.STRIDE:
			finite = finite and is_finite(m._batch.buf[o + k])
		check(finite, "%s: batch data finite" % bad)
		near(m._xf.basis.x.length(), 0.0, 1e-9, "%s: drawn at scale 0" % bad)
		m.position = Vector3(1, 2, 3)
		BirdBatch.sync_all(DT)
		o = m._slot * BirdBatch.STRIDE
		vnear(Vector3(m._batch.buf[o + 3], m._batch.buf[o + 7], m._batch.buf[o + 11]), Vector3(1, 2, 3), 1e-5, "%s then sane: drawn at its position" % bad)
		near(m._xf.basis.x.length(), float(SizeRules.species_data(&"gull")["span"]), 1e-4, "%s then sane: at its size" % bad)
		m.free()


func test_wingtip_is_where_it_is_drawn() -> void:
	# get_wingtip is the tip that is drawn (trails and haptics sit on it),
	# highlighted or not: the instance transform x the posed tip.
	for st in [0, 1]:
		var m := _prey(&"sparrow", st)
		m.position = Vector3(0, 0, -40)
		m.bank = 0.3
		m.snap()
		BirdBatch.sync_all(DT)
		var rec := BirdModels.tip_record(&"sparrow")
		var posed: Vector3 = BirdPose.pose(rec[0], rec[1], rec[2], rec[3], rec[4], rec[5], m.displayed_pose(), 0.0, 0.0, false, rec[6], rec[7])[0]
		vnear(m.get_wingtip(1), m._xf * posed, 1e-4, "highlight %d: wingtip = the drawn transform x the posed tip" % st)
		m.free()


func test_render_layers_and_shadows_move_the_bird() -> void:
	var m := BirdModels.create(&"pigeon")
	m.lod_override = 0
	add_child(m)
	BirdBatch.sync_all(DT)
	var k0: String = m._batch.key
	m.render_layers = 4
	var k1: String = m._batch.key
	eq(k1.split("|")[2], "4", "render_layers: the bird is drawn by a batch on layer mask 4")
	check(k1 != k0, "a different batch from the default layers")
	m.cast_shadows = false
	eq(m._batch.key.split("|")[3], "0", "cast_shadows off: a batch without the shadow pass")
	eq(BirdBatch.instance_total(), 1, "the bird is drawn once, not left behind in the old batches")


func test_marker_geometry() -> void:
	# The marker is its own mesh: a 32-sided ring (edible) and a triangle
	# (danger), every vertex at the origin (the shader places it; the state
	# not shown stays collapsed there), wound to face the viewer.
	var arr := BirdModels.marker_mesh().surface_get_arrays(0)
	var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var c0: PackedFloat32Array = arr[Mesh.ARRAY_CUSTOM0]
	var c1: PackedFloat32Array = arr[Mesh.ARRAY_CUSTOM1]
	var at_origin := true
	var ring := 0
	var tri := 0
	var groups_ok := true
	var wound := true
	for t in range(0, v.size(), 3):
		# Laid out in the view plane (x right, y up; outer edge at 1, inner
		# at 0.8): clockwise, Godot's front faces towards the eye.
		var p := []
		for k in 3:
			var j := (t + k) * 4
			p.append(Vector2(c1[j], c1[j + 1]) * (1.0 if c1[j + 3] > 0.5 else 0.8))
		wound = wound and ((p[1] as Vector2) - p[0]).cross((p[2] as Vector2) - p[0]) < 0.0
	for i in v.size():
		groups_ok = groups_ok and int(roundf(c0[i * 4])) == BirdPose.G_MARK
		at_origin = at_origin and v[i] == Vector3.ZERO
		if c1[i * 4 + 2] > 0.5:
			tri += 1
		else:
			ring += 1
	check(groups_ok, "every marker vertex is group 6")
	check(at_origin, "every marker vertex rests at the origin")
	eq(ring / 3, 64, "a 32-sided ring (edible)")
	eq(tri / 3, 6, "a triangle (danger)")
	check(wound, "marker triangles face the viewer")
	check(BirdModels.marker_mesh().surface_get_material(0) == BirdModels.material(), "drawn with the one bird material")
	# The shader keeps its own copies of two constants: they must agree.
	eq(_shader_const("MARK_RING_SIDES"), float(BirdMeshBuilder.MARK_RING_SIDES), "shader and mesh agree on the ring's sides")
	near(_shader_const("READABLE_MAX"), BirdModels.READABLE_MAX, 1e-9, "shader and meshes agree on READABLE_MAX")


static func _shader_const(name: String) -> float:
	var m := RegEx.create_from_string("const float %s = ([-0-9.]+);" % name).search(BirdModels.SHADER.code)
	return float(m.get_string(1)) if m else NAN


func test_meshes_carry_the_readable_angle() -> void:
	# The shader tints a highlighted bird by its size against its species'
	# readable angle, read from COLOR.a: every vertex of every LOD carries
	# exactly min_highlight_angle (8-bit), and slim birds need a wider one.
	var ok := true
	var table := {}
	for sp: StringName in BirdSpecies.IDS:
		var ra := BirdModels.min_highlight_angle(sp)
		table[String(sp)] = snappedf(rad_to_deg(ra), 0.01)
		for lod in BirdModels.LOD_COUNT:
			var cols: PackedColorArray = BirdModels.mesh(sp, lod).surface_get_arrays(0)[Mesh.ARRAY_COLOR]
			for c in cols:
				if absf(c.a * BirdModels.READABLE_MAX - ra) > BirdModels.READABLE_MAX / 510.0:
					ok = false
	check(ok, "COLOR.a x READABLE_MAX = the species' readable angle at every vertex of every LOD")
	gt(BirdModels.min_highlight_angle(&"moth"), BirdModels.min_highlight_angle(&"sparrow") * 1.5, "a slim moth needs a wider readable angle")
	near(BirdModels.min_highlight_angle(&"wren"), BirdModel.MIN_HIGHLIGHT_ANGLE, BirdModels.READABLE_MAX / 255.0, "a round wren reads at the base angle")
	metric("readable_angle_deg", table)


func test_marker_batch_holds_exactly_the_highlighted_birds() -> void:
	# One marker batch per world and layers; its instances are the
	# highlighted birds with their own transform and packed data, at every
	# LOD (a far bird forced to LOD0 is marked too); a bird leaves it once its
	# highlight has faded, when hidden, and follows it to other layers.
	var ms: Array[BirdModel] = []
	for i in 6:
		var m := BirdModels.create(BirdSpecies.IDS[i + 2])
		m.position = Vector3(i * 3.0 - 8.0, 0.0, -20.0 - i * 15.0)
		m.highlight = [0, 1, 2][i % 3]
		add_child(m)
		m.snap()
		ms.append(m)
	ms[5].lod_override = 0
	BirdBatch.sync_all(DT)
	eq(BirdBatch.marker_total(), 4, "4 highlighted birds, 4 markers")
	eq(BirdBatch.markers().size(), 1, "one marker batch for the world")
	var same := true
	for m in ms:
		if m.highlight == 0:
			check(m._mark == null, "an unhighlighted bird has no marker")
			continue
		check(m._mark != null, "highlighted bird %s is marked (LOD%d)" % [m.species, m.get_lod()])
		if m._mark == null:
			continue
		for k in BirdBatch.STRIDE:
			same = same and m._mark.buf[m._mark_slot * BirdBatch.STRIDE + k] == m._batch.buf[m._slot * BirdBatch.STRIDE + k]
	check(same, "each marker instance carries its bird's transform and data")
	check(ms[5]._mark != null and ms[5].get_lod() == 0, "a far bird forced to LOD0 is marked too")
	# Fading out: marked until its weight reaches zero, then dropped.
	ms[1].highlight = 0
	BirdBatch.sync_all(DT)
	check(ms[1]._mark != null, "still marked while the highlight fades out")
	for f in 72:
		BirdBatch.sync_all(DT)
	check(ms[1]._mark == null, "dropped once the highlight has faded")
	eq(BirdBatch.marker_total(), 3, "3 markers left")
	ms[2].visible = false
	BirdBatch.sync_all(DT)
	eq(BirdBatch.marker_total(), 2, "a hidden bird leaves the marker batch")
	ms[4].render_layers = 4
	BirdBatch.sync_all(DT)
	eq(BirdBatch.markers().size(), 2, "a bird on other layers gets a marker batch on those layers")
	eq(ms[4]._mark.key.split("|")[2], "4", "the marker batch has the bird's layer mask")
	for m in ms:
		m.highlight = 0
	for f in 72:
		BirdBatch.sync_all(DT)
	eq(BirdBatch.markers().size(), 0, "no highlighted birds: marker batches released")
	metric("marker_batches_while_marked", 1)
