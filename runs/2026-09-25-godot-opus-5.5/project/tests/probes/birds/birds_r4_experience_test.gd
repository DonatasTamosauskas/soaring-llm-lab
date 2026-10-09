extends TestCase
## Round-4 verifier probes (birds, experience & requirements lens). Written
## by the verifier, not the builder. Uses only the birds area's public
## factory, its meshes and BirdPose (proven equal to the shader by the area's
## GPU check), SizeRules (core) and the shader's own source text. Nothing
## from other areas.
##
##   tools/gd.sh birds_verify --headless res://tests/runner.tscn -- \
##       --dir=res://tests/probes/birds --suite=birds_r4
##
## 1. The round-3 highlight: markers now surround every highlighted bird at
##    every size. The design says the ring sits "just outside the wingtips"
##    and the triangle's "edges pass outside the wingtips too". Does the
##    line clear the bird in every pose and from every view, at every size?
## 2. Colour identity under the CURRENT shader (the round-3 probe mirrored
##    the round-2 fragment): an independent mirror of the tint share, with
##    uniforms parsed from bird.gdshader and each species' readable angle
##    from its own vertex alpha. Where in GameLoop's highlight range does a
##    prey show its own plumage?
## 3. Perched posture: raptors are the birds "hunting from perches"
##    (DESIGN.md NPC intent); do they sit like raptors?
## 4. The marker close up: how big is a threat's triangle when the threat is
##    a few spans away (a stoop's last second)?
## 5. Marker-batch bookkeeping fuzz: two worlds, reparenting between them,
##    species/layer/visibility/highlight churn, frees; invariants after
##    every sync.

const SHADER_PATH := "res://scripts/birds/bird.gdshader"
const DT := 1.0 / 72.0
const GLIDE := Vector4(0.25, 0.0, 0.0, 0.0)

var _u := {}


func before_all() -> void:
	_u = _shader_uniforms()


# --- helpers ---------------------------------------------------------------

## Float uniforms and consts with literal defaults, parsed from the shader.
static func _shader_uniforms() -> Dictionary:
	var f := FileAccess.open(SHADER_PATH, FileAccess.READ)
	var out := {}
	if f == null:
		return out
	var re := RegEx.new()
	re.compile("(?m)^(?:uniform|const) float (\\w+)\\s*(?::[^=]*)?=\\s*([-0-9.eE]+)\\s*;")
	for m in re.search_all(f.get_as_text()):
		out[m.get_string(1)] = float(m.get_string(2))
	return out


static func _fib_dirs(n: int) -> PackedVector3Array:
	var out := PackedVector3Array()
	var ga := PI * (3.0 - sqrt(5.0))
	for i in n:
		var y := 1.0 - 2.0 * (i + 0.5) / n
		var r := sqrt(maxf(0.0, 1.0 - y * y))
		out.append(Vector3(cos(ga * i) * r, y, sin(ga * i) * r))
	return out


static func _poses() -> Array[Vector4]:
	var out: Array[Vector4] = [GLIDE, Vector4(0.25, 0.0, 0.5, 0.0), Vector4(0.25, 0.0, 1.0, 0.0),
		Vector4(0.25, 0.0, 1.0, 1.0), Vector4(0.25, 0.0, 0.6, 1.0)]
	for i in 20:
		out.append(Vector4(i / 20.0, 1.0, 0.0, 0.0))
	for i in 10:
		# A perched balance flap and a flapping take-off blend.
		out.append(Vector4(i / 10.0, 1.0, 0.3, 0.6))
	return out


## Marker line, in radians from the marker's centre, for a bird whose
## wingspan subtends `a` radians: [inner, outer] for the ring (at an edge's
## midpoint, where the 32-gon is closest to the centre) and for the
## triangle (its edges' distance from the centre).
func _marker_band(a: float, tri: bool) -> Vector2:
	var r_out: float = maxf(_u["mark_radius"], _u["mark_bird_scale"] * a) * (_u["mark_tri_scale"] if tri else 1.0)
	var w: float = clampf(_u["mark_width_k"] * r_out, _u["mark_width"], _u["mark_width_max"])
	if tri:
		# Edge distance = circumradius / 2; the inner triangle's circumradius
		# is r_out - 2 w (shader), so the band is [(r_out - 2w)/2, r_out/2].
		return Vector2((r_out - 2.0 * w) * 0.5, r_out * 0.5)
	var c := cos(PI / _u["MARK_RING_SIDES"])
	return Vector2(r_out * c - w, r_out * c)


# --- 1. the marker clears the bird -----------------------------------------

func test_r4_marker_line_clears_the_bird() -> void:
	check(_u.has("mark_bird_scale") and _u.has("mark_tri_scale") and _u.has("MARK_RING_SIDES"), "shader uniforms parsed")
	var dirs := _fib_dirs(60)
	var poses := _poses()
	# Largest projected distance from the model origin (span units) of any
	# posed vertex, per species: in the glide pose (wingtips, tail, bill) and
	# over the whole pose set.
	var ext_glide := {}
	var ext_all := {}
	var ext_all_pose := {}
	for sp: StringName in BirdSpecies.IDS:
		var arr := BirdModels.mesh(sp, 0).surface_get_arrays(0)
		var g := 0.0
		var best := 0.0
		var best_pose := Vector4()
		for p in poses:
			var v := BirdPose.pose_arrays(arr, p)
			var worst := 0.0
			for d in dirs:
				for q in v:
					var r := (q - d * q.dot(d)).length()
					if r > worst:
						worst = r
			if p == GLIDE:
				g = worst
			if worst > best:
				best = worst
				best_pose = p
		ext_glide[sp] = g
		ext_all[sp] = best
		ext_all_pose[sp] = best_pose
	# Sizes: 0.5 deg .. 40 deg of wingspan, in 0.25 deg steps. Small-angle
	# model (the shader places the marker at distance x angle in the view
	# plane, and the bird's span is distance x angle there too).
	var ring_fail := {}
	var tri_fail := {}
	var ring_worst := [INF, "", 0.0]
	var tri_worst := [INF, "", 0.0]
	var tri_glide_worst := [INF, "", 0.0]
	for sp: StringName in BirdSpecies.IDS:
		var deg := 0.5
		while deg <= 40.0:
			var a := deg_to_rad(deg)
			var ring := _marker_band(a, false) / a
			var tri := _marker_band(a, true) / a
			var cr: float = ring.x - ext_all[sp]
			var ct: float = tri.x - ext_all[sp]
			var ctg: float = tri.x - ext_glide[sp]
			# Gated from 1 deg (20 px) up: below it the fixed far marker and
			# its 2 px minimum line around a bird of 10-15 px touch the tips by
			# a pixel by construction (reported in the per-species rows).
			if deg >= 1.0 and cr < ring_worst[0]:
				ring_worst = [cr, sp, deg]
			if deg >= 1.0 and ct < tri_worst[0]:
				tri_worst = [ct, sp, deg]
			if deg >= 1.0 and ctg < tri_glide_worst[0]:
				tri_glide_worst = [ctg, sp, deg]
			if cr < 0.0:
				ring_fail[sp] = ring_fail.get(sp, []) + [deg]
			if ct < 0.0:
				tri_fail[sp] = tri_fail.get(sp, []) + [deg]
			deg += 0.25
	var rows := {}
	for sp: StringName in BirdSpecies.IDS:
		var rf: Array = ring_fail.get(sp, [])
		var tf: Array = tri_fail.get(sp, [])
		rows[sp] = {"extent_glide": snappedf(ext_glide[sp], 0.001), "extent_any_pose": snappedf(ext_all[sp], 0.001),
			"worst_pose": str(ext_all_pose[sp]),
			"ring_overlaps_deg": [rf.front(), rf.back()] if not rf.is_empty() else [],
			"triangle_overlaps_deg": [tf.front(), tf.back()] if not tf.is_empty() else []}
		print("[birds-r4] %-8s extent glide %.3f any pose %.3f (%s); ring overlaps at %s deg; triangle at %s deg" % [
			sp, ext_glide[sp], ext_all[sp], ext_all_pose[sp], rows[sp]["ring_overlaps_deg"], rows[sp]["triangle_overlaps_deg"]])
	print("[birds-r4] worst clearance (span units, <0 = the line lies on the bird): ring %.3f (%s at %.2f deg), triangle %.3f (%s at %.2f deg), triangle vs glide pose %.3f (%s at %.2f deg)" % [
		ring_worst[0], ring_worst[1], ring_worst[2], tri_worst[0], tri_worst[1], tri_worst[2],
		tri_glide_worst[0], tri_glide_worst[1], tri_glide_worst[2]])
	metric("marker_clearance", {"per_species": rows, "ring_worst": [snappedf(ring_worst[0], 0.001), ring_worst[1], ring_worst[2]],
		"triangle_worst": [snappedf(tri_worst[0], 0.001), tri_worst[1], tri_worst[2]],
		"triangle_vs_glide_worst": [snappedf(tri_glide_worst[0], 0.001), tri_glide_worst[1], tri_glide_worst[2]]})
	# The design's own claims (BIRDS.md: "just outside the wingtips"; "its
	# edges pass outside the wingtips too"), for the wingtips (glide pose)
	# and for the whole bird in every pose it is drawn in.
	# (Tolerance 0.002 span: at exactly 1 deg the moth's tip touches the
	# ring's inner edge by 0.0002 span, a hundredth of a pixel.)
	gt(ring_worst[0], -0.002, "from 1 deg up the edible ring never lies on its bird (worst %s at %.2f deg)" % [ring_worst[1], ring_worst[2]])
	gt(tri_glide_worst[0], 0.0, "from 1 deg up the danger triangle's edges clear a gliding bird's wingtips in any roll (worst %s at %.2f deg)" % [tri_glide_worst[1], tri_glide_worst[2]])
	gt(tri_worst[0], 0.0, "from 1 deg up the danger triangle's edges clear the bird in every pose (worst %s at %.2f deg)" % [tri_worst[1], tri_worst[2]])


# --- 2. colour identity under the current shader ---------------------------

func test_r4_highlighted_prey_shows_its_plumage_where_it_matters() -> void:
	var tint_end: float = _u.get("tint_end", -1.0)
	var rmax: float = _u.get("READABLE_MAX", -1.0)
	check(tint_end > 1.0 and rmax > 0.0, "tint_end and READABLE_MAX parsed from the shader")
	var ends := {}
	var worst_end := [0.0, ""]
	for sp: StringName in BirdSpecies.IDS:
		var arr := BirdModels.mesh(sp, 0).surface_get_arrays(0)
		var cols: PackedColorArray = arr[Mesh.ARRAY_COLOR]
		var lo := INF
		var hi := -INF
		for c in cols:
			lo = minf(lo, c.a)
			hi = maxf(hi, c.a)
		check(absf(hi - lo) < 1e-6, "%s: every vertex carries one readable angle" % sp)
		var readable := hi * rmax
		near(readable, BirdModels.min_highlight_angle(sp), 1e-4, "%s: vertex alpha = min_highlight_angle" % sp)
		# The shader: tint = 1 - smoothstep(readable, readable * tint_end, ang)
		# (0 exactly from readable * tint_end on).
		var end := readable * tint_end
		ends[sp] = end
		if end > worst_end[0]:
			worst_end = [end, sp]
		for deg in [3.0, 10.0, 25.0]:
			var a := deg_to_rad(deg)
			var t := 1.0 - smoothstep(readable, readable * tint_end, a)
			eq(t, 0.0, "%s at %.0f deg: highlighted plumage is untouched" % [sp, deg])
	print("[birds-r4] the last species to show its own plumage does so at %.2f deg (%s)" % [rad_to_deg(worst_end[0]), worst_end[1]])
	lt(rad_to_deg(worst_end[0]), 2.95, "every species wears its own plumage from under 2.95 deg (BIRDS.md: 2.9)")
	# Where that is in play: for every eater/prey pair GameLoop can highlight
	# (the player starts as a sparrow; worthwhile prey by SizeRules), the
	# distance at which the prey stops being a tinted blob, against the
	# highlight radius (mirrors GameLoop's documented max(70 player spans,
	# 6 s of cruise); not its code).
	var rows := []
	var ids := BirdSpecies.IDS
	for ei in ids.size():
		var e: StringName = ids[ei]
		if SizeRules.species_index(e) < SizeRules.species_index(&"sparrow"):
			continue
		var em: float = SizeRules.species_data(e)["mass"]
		var espan: float = SizeRules.species_data(e)["span"]
		var hl_r := maxf(70.0 * espan, 6.0 * SizeRules.cruise_speed(em))
		for pi in ids.size():
			var p: StringName = ids[pi]
			var pm: float = SizeRules.species_data(p)["mass"]
			if not SizeRules.can_eat(em, pm) or not SizeRules.is_worthwhile(em, pm):
				continue
			var pspan: float = SizeRules.species_data(p)["span"]
			# Plumage from ang >= end, i.e. closer than span / end; fully tinted
			# beyond span / readable.
			var d_plum: float = pspan / ends[p]
			var d_tint: float = pspan / (ends[p] / tint_end)
			rows.append({"eater": e, "prey": p, "highlight_range_m": snappedf(hl_r, 0.1),
				"own_plumage_within_m": snappedf(d_plum, 0.1), "fully_tinted_beyond_m": snappedf(d_tint, 0.1),
				"share_of_range_tinted": snappedf(clampf((hl_r - d_plum) / hl_r, 0.0, 1.0), 0.01)})
	for r in rows:
		print("[birds-r4]   %-8s eats %-8s: highlighted within %5.1f m, own plumage within %5.1f m, fully tinted beyond %5.1f m" % [
			r["eater"], r["prey"], r["highlight_range_m"], r["own_plumage_within_m"], r["fully_tinted_beyond_m"]])
	metric("plumage_distances", rows)
	check(not rows.is_empty(), "some pairs are highlightable")


# --- 3. perched posture ----------------------------------------------------

func test_r4_perched_raptors_sit_like_raptors() -> void:
	# The body's perched pitch is CUSTOM3.w (BirdPose: q = rx(q, perch * c3.w)).
	# Measured from the posed mesh as the line from the tail's base to the
	# crown, against the horizontal.
	var rows := {}
	for sp: StringName in BirdSpecies.IDS:
		var arr := BirdModels.mesh(sp, 0).surface_get_arrays(0)
		var c0: PackedFloat32Array = arr[Mesh.ARRAY_CUSTOM0]
		var c3: PackedFloat32Array = arr[Mesh.ARRAY_CUSTOM3]
		var v := BirdPose.pose_arrays(arr, Vector4(0.25, 0.0, 1.0, 1.0))
		var body_pitch := 0.0
		var head := Vector3.ZERO
		var nh := 0
		var body_back := -INF
		var back_pt := Vector3.ZERO
		for i in v.size():
			var g := int(roundf(c0[i * 4]))
			if g == BirdPose.G_BODY:
				body_pitch = c3[i * 4 + 3]
				# The rearmost body vertex (the rump).
				if v[i].z > body_back:
					body_back = v[i].z
					back_pt = v[i]
			elif g == BirdPose.G_HEAD:
				head += v[i]
				nh += 1
		head /= maxf(nh, 1)
		var axis := head - back_pt
		var axis_deg := rad_to_deg(atan2(axis.y, -axis.z))
		rows[sp] = {"body_pitch_deg": snappedf(rad_to_deg(body_pitch), 0.1), "rump_to_head_deg": snappedf(axis_deg, 0.1)}
		print("[birds-r4] %-8s perched: body pitch %5.1f deg, rump-to-head line %5.1f deg above horizontal" % [sp, rad_to_deg(body_pitch), axis_deg])
	metric("perched_posture", rows)
	# Buteos and eagles perch upright (body 50-70 deg); pigeons, gulls and
	# starlings near-horizontal. A game director reading a perched silhouette
	# at a distance: a raptor on a pole must not look like a pigeon.
	for sp: StringName in [&"hawk", &"eagle"]:
		gt(rows[sp]["rump_to_head_deg"], 40.0, "%s perches upright like a raptor (rump-to-head line > 40 deg)" % sp)
		gt(rows[sp]["rump_to_head_deg"], rows[&"pigeon"]["rump_to_head_deg"] + 15.0, "%s sits clearly more upright than a pigeon" % sp)


# --- 4. the marker close up ------------------------------------------------

func test_r4_threat_marker_close_up() -> void:
	# The triangle around a threat `k` of its own spans away: how wide it is
	# (degrees across, the shader's tangent-plane placement: corners at
	# distance x r_out from the bird's centre, i.e. atan(r_out) each side).
	var rows := {}
	for k in [8.0, 4.0, 2.0, 1.0, 0.6]:
		var a := 2.0 * atan(0.5 / k)
		var r_out: float = maxf(_u["mark_radius"], _u["mark_bird_scale"] * a) * _u["mark_tri_scale"]
		# Equilateral triangle, apex up: half-width = r_out * sin(60).
		var half_w := atan(r_out * sin(PI / 3.0))
		var top := atan(r_out)
		var bottom := atan(r_out * 0.5)
		var ring := 2.0 * atan(maxf(_u["mark_radius"], _u["mark_bird_scale"] * a))
		rows["%.1f_spans" % k] = {"bird_deg": snappedf(rad_to_deg(a), 0.1),
			"triangle_wide_deg": snappedf(rad_to_deg(2.0 * half_w), 0.1),
			"triangle_tall_deg": snappedf(rad_to_deg(top + bottom), 0.1),
			"ring_deg": snappedf(rad_to_deg(ring), 0.1)}
		print("[birds-r4] threat %.1f spans away: bird %.1f deg; triangle %.1f x %.1f deg; ring %.1f deg" % [
			k, rad_to_deg(a), rad_to_deg(2.0 * half_w), rad_to_deg(top + bottom), rad_to_deg(ring)])
	metric("close_marker", rows)
	# Report-only: a Quest Pro eye sees ~96 deg vertically. Asserted only
	# that the maths is finite.
	finite(rows["0.6_spans"]["triangle_wide_deg"], "close marker size finite")


# --- 5. marker bookkeeping fuzz --------------------------------------------

func test_r4_marker_batches_hold_under_churn() -> void:
	var cam := Camera3D.new()
	add_child(cam)
	cam.position = Vector3(0, 2, 10)
	cam.make_current()
	var sv := SubViewport.new()
	sv.own_world_3d = true
	sv.size = Vector2i(64, 64)
	add_child(sv)
	var cam2 := Camera3D.new()
	sv.add_child(cam2)
	cam2.position = Vector3(0, 2, 10)
	var parents: Array[Node] = [self, sv]
	var rng := RandomNumberGenerator.new()
	rng.seed = 424242
	var ms: Array[BirdModel] = []
	for i in 40:
		var m := BirdModels.create(BirdSpecies.IDS[rng.randi() % BirdSpecies.IDS.size()])
		m.position = Vector3(rng.randf_range(-30, 30), rng.randf_range(0, 20), rng.randf_range(-150, 5))
		m.highlight = rng.randi() % 3
		parents[rng.randi() % 2].add_child(m)
		ms.append(m)
	var bad := 0
	var bad_msgs: PackedStringArray = []
	var max_markers := 0
	for step in 1500:
		# Random operations.
		for n in 3:
			if ms.is_empty():
				break
			var m: BirdModel = ms[rng.randi() % ms.size()]
			match rng.randi() % 10:
				0, 1:
					m.highlight = rng.randi() % 3
				2:
					m.visible = not m.visible
				3:
					m.species = BirdSpecies.IDS[rng.randi() % BirdSpecies.IDS.size()]
				4:
					m.render_layers = [1, 1, 2, 5][rng.randi() % 4]
				5:
					# Reparent into the other world.
					var to: Node = parents[rng.randi() % 2]
					if m.get_parent() != to:
						m.get_parent().remove_child(m)
						to.add_child(m)
				6:
					m.position = Vector3(rng.randf_range(-30, 30), rng.randf_range(0, 20), rng.randf_range(-400, 8))
				7:
					m.lod_override = [-1, -1, 0, 2][rng.randi() % 4]
				8:
					if rng.randf() < 0.3:
						ms.erase(m)
						m.free()
						var nm := BirdModels.create(BirdSpecies.IDS[rng.randi() % BirdSpecies.IDS.size()])
						nm.highlight = rng.randi() % 3
						nm.position = Vector3(rng.randf_range(-30, 30), rng.randf_range(0, 20), rng.randf_range(-150, 5))
						parents[rng.randi() % 2].add_child(nm)
						ms.append(nm)
				9:
					m.scale = Vector3.ONE * [1.0, 0.3, 2.1][rng.randi() % 3]
		BirdBatch.sync_all(DT)
		# Invariants.
		var marked := {}
		for b: BirdBatch in BirdBatch.markers():
			if not b.is_marker:
				bad += 1
				bad_msgs.append("step %d: a marker batch not flagged as one" % step)
			if not b.inst.is_valid() or not b.mm.is_valid():
				bad += 1
				bad_msgs.append("step %d: marker batch %s with freed RIDs" % [step, b.key])
			for i in b.models.size():
				var m := b.models[i]
				if not is_instance_valid(m):
					bad += 1
					bad_msgs.append("step %d: freed model in marker batch" % step)
					continue
				if marked.has(m):
					bad += 1
					bad_msgs.append("step %d: model marked twice" % step)
				marked[m] = true
				if m._mark != b or m._mark_slot != i:
					bad += 1
					bad_msgs.append("step %d: marker slot bookkeeping wrong" % step)
				if m._batch == null or m._batch.scenario != b.scenario:
					bad += 1
					bad_msgs.append("step %d: marker in another world than its bird (%s)" % [step, m.species])
				elif int(b.key.split("|")[2]) != m.render_layers:
					bad += 1
					bad_msgs.append("step %d: marker on other layers than its bird" % step)
				else:
					for k in BirdBatch.STRIDE:
						if b.buf[i * BirdBatch.STRIDE + k] != m._batch.buf[m._slot * BirdBatch.STRIDE + k]:
							bad += 1
							bad_msgs.append("step %d: marker data differs from its bird's" % step)
							break
		for m in ms:
			var drawn := m._batch != null
			if drawn and m._hl_on and not marked.has(m):
				bad += 1
				bad_msgs.append("step %d: highlighted drawn %s has no marker" % [step, m.species])
			if (not drawn or not m._hl_on) and marked.has(m):
				bad += 1
				bad_msgs.append("step %d: unhighlighted or hidden %s still marked" % [step, m.species])
			if drawn != (m.is_inside_tree() and m.is_visible_in_tree()):
				bad += 1
				bad_msgs.append("step %d: drawn state wrong" % step)
		max_markers = maxi(max_markers, marked.size())
	for msg in bad_msgs.slice(0, 8):
		print("[birds-r4] ", msg)
	print("[birds-r4] fuzz: 1500 syncs, %d invariant breaks, up to %d markers, %d marker batches at the end" % [bad, max_markers, BirdBatch.markers().size()])
	eq(bad, 0, "marker batches hold exactly the drawn highlighted birds through 1500 churned syncs")
	check(max_markers > 5, "the fuzz exercised markers")
	for m in ms:
		m.free()
	BirdBatch.sync_all(DT)
	eq(BirdBatch.markers().size(), 0, "every marker batch released when the birds are gone")
	eq(BirdBatch.count(), 0, "every bird batch released when the birds are gone")
	sv.queue_free()
	cam.queue_free()


# --- 6. independent budget / convention / CPU re-measure --------------------

func test_r4_independent_budgets_and_conventions() -> void:
	var mat := BirdModels.material()
	var worst_small := 0
	var worst_large := 0
	for sp: StringName in BirdSpecies.IDS:
		var large: bool = SizeRules.species_data(sp)["span"] >= 0.5
		for l in 3:
			var mesh := BirdModels.mesh(sp, l)
			eq(mesh.get_surface_count(), 1, "%s LOD%d: one surface" % [sp, l])
			check(mesh.surface_get_material(0) == mat, "%s LOD%d: the one shared material" % [sp, l])
			var arr := mesh.surface_get_arrays(0)
			var idx: Variant = arr[Mesh.ARRAY_INDEX]
			var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var tris := (idx as PackedInt32Array).size() / 3 if idx is PackedInt32Array and (idx as PackedInt32Array).size() > 0 else v.size() / 3
			if l == 0:
				if large:
					worst_large = maxi(worst_large, tris)
					lt(tris, 601, "%s LOD0 <= 600 triangles (%d)" % [sp, tris])
				else:
					worst_small = maxi(worst_small, tris)
					lt(tris, 301, "%s LOD0 <= 300 triangles (%d)" % [sp, tris])
			# B6 on the rest mesh: span 1.0 centred, beak -Z.
			var lo := Vector3.INF
			var hi := -Vector3.INF
			var fore := Vector3(0, 0, INF)
			for q in v:
				lo = lo.min(q)
				hi = hi.max(q)
				if q.z < fore.z:
					fore = q
			near(hi.x - lo.x, 1.0, 1e-4, "%s LOD%d rest span 1.0" % [sp, l])
			near(hi.x + lo.x, 0.0, 1e-4, "%s LOD%d centred on x = 0" % [sp, l])
			# (The moth's foremost points are its splayed antennae.)
			check(fore.z < -0.1 and (absf(fore.x) < 0.03 or sp == &"moth"), "%s LOD%d: foremost point ahead on the midline (beak -Z)" % [sp, l])
	metric("lod0_tris_worst", {"small": worst_small, "large": worst_large})
	eq(BirdModels.marker_mesh().surface_get_material(0), mat, "the marker uses the one material too")


func test_r4_sixty_birds_cpu_with_markers() -> void:
	var cam := Camera3D.new()
	add_child(cam)
	cam.position = Vector3(0, 10, 20)
	cam.make_current()
	var rng := RandomNumberGenerator.new()
	rng.seed = 99
	BirdModels.prewarm()
	var ms: Array[BirdModel] = []
	for i in 60:
		var sp: StringName = BirdSpecies.IDS[i % 10]
		var m := BirdModels.create(sp)
		m.scale = Vector3.ONE * float(SizeRules.species_data(sp)["span"])
		m.position = Vector3(rng.randf_range(-40, 40), rng.randf_range(2, 40), rng.randf_range(-120, 10))
		m.highlight = [0, 0, 1, 2][i % 4]
		add_child(m)
		ms.append(m)
	var times := PackedInt32Array()
	var t := 0.0
	for f in 900:
		t += DT
		for i in ms.size():
			var m := ms[i]
			m.flap_phase = fposmod(m.flap_phase + 8.0 * DT, 1.0)
			m.flap_amount = 0.5 + 0.5 * sin(t * 0.7 + i)
			m.wing_fold = clampf(sin(t * 0.3 + i * 0.5), 0.0, 1.0)
			m.bank = 0.6 * sin(t + i)
			m.perched = (i % 9 == 0) and sin(t * 0.2 + i) > 0.5
			m.position += Vector3(sin(t + i), 0.2 * cos(t * 2.0 + i), cos(t * 0.8 + i)) * 12.0 * DT
			if f % 97 == i % 97:
				m.highlight = (m.highlight + 1) % 3
		BirdBatch.sync_all(DT)
		if f >= 60:
			times.append(BirdBatch.last_sync_usec)
	var arr := Array(times)
	arr.sort()
	var med: int = arr[arr.size() / 2]
	var p95: int = arr[int(arr.size() * 0.95)]
	var mx: int = arr.back()
	print("[birds-r4] 60 birds (15 edible, 15 danger, every field moving), headless, machine load as is: sync median %d us, p95 %d, max %d; %d markers" % [med, p95, mx, BirdBatch.marker_total()])
	metric("sixty_birds_sync_us", {"median": med, "p95": p95, "max": mx})
	lt(float(p95), 1000.0, "60 animated birds with markers: p95 sync under 1 ms (M1)")
	for m in ms:
		m.free()
	BirdBatch.sync_all(DT)
	cam.queue_free()
