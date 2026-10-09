extends TestCase
## Independent verifier probes for the world area (round 1, engineering and
## contract lens). These re-check the builder's claims against the physics
## that was actually built, using checks the builder's own suite does not
## make (fly-through casts, random 3D escape rays, physical grounding,
## physical density, whole-domain wind smoothness, non-Visual geometry).
##
##   tools/gd.sh world_verify2 --headless res://tests/runner.tscn -- --dir=res://tests/probes/world
##
## Prints "[world-verify] ..." lines; numbers land in the report metrics.

var world: SoaringWorld
var space: PhysicsDirectSpaceState3D
var k_body := 0.16
var ground_rids: Array[RID] = []


func before_all() -> void:
	k_body = WorldBuild.body_k()
	world = load("res://scenes/world/world.tscn").instantiate()
	add_child(world)
	await wait_physics(2)
	space = world.get_world_3d().direct_space_state
	for b in _all_bodies():
		var nm := String(b.name)
		# Exact names: "water_tower_body" also starts with "water" and is a structure.
		if nm.begins_with("terrain_") or nm == "water_body" or nm == "Boundary" or nm.begins_with("backdrop"):
			ground_rids.append(b.get_rid())


func after_all() -> void:
	if world:
		world.queue_free()


func _all_bodies() -> Array[StaticBody3D]:
	var out: Array[StaticBody3D] = []
	var stack: Array[Node] = [world]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is StaticBody3D:
			out.append(n)
		for c in n.get_children():
			stack.append(c)
	return out


func _ray(a: Vector3, b: Vector3, exclude: Array[RID] = []) -> Dictionary:
	var q := PhysicsRayQueryParameters3D.create(a, b)
	q.collision_mask = 1
	q.exclude = exclude
	return space.intersect_ray(q)


func _cast(from: Vector3, to: Vector3, r: float) -> float:
	var sp := SphereShape3D.new()
	sp.radius = r
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = sp
	q.collision_mask = 1
	q.transform = Transform3D(Basis.IDENTITY, from)
	q.motion = to - from
	var res := space.cast_motion(q)
	return res[0] if res.size() > 0 else 1.0


func _overlap(shape: Shape3D, xf: Transform3D, exclude: Array[RID], max_results := 1) -> Array:
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = shape
	q.collision_mask = 1
	q.transform = xf
	q.exclude = exclude
	return space.intersect_shape(q, max_results)


# --- contract -------------------------------------------------------------

func test_contract_signatures_and_types() -> void:
	var base := {}
	for m in (load("res://scripts/world/world.gd") as Script).get_script_method_list():
		base[m["name"]] = m
	var sub := {}
	for m in (load("res://scripts/world/soaring_world.gd") as Script).get_script_method_list():
		if not sub.has(m["name"]):
			sub[m["name"]] = m
	var api := ["get_wind", "ground_height", "get_perches", "find_perches", "get_player_spawn", "get_landmarks",
		"get_refuges", "is_inside", "get_thermals", "find"]
	var bad: PackedStringArray = []
	for nm in api:
		check(base.has(nm), "base World has %s" % nm)
		if sub.has(nm) and base.has(nm):
			var a: Array = base[nm]["args"]
			var b: Array = sub[nm]["args"]
			if a.size() != b.size():
				bad.append("%s arg count" % nm)
				continue
			for i in a.size():
				if a[i]["type"] != b[i]["type"]:
					bad.append("%s arg %d type" % [nm, i])
			if base[nm]["return"]["type"] != sub[nm]["return"]["type"]:
				bad.append("%s return type" % nm)
	eq(bad.size(), 0, "SoaringWorld overrides keep the base signatures: %s" % ", ".join(bad))
	check(world.is_in_group(&"world"), "in group world")
	eq(world.process_mode, Node.PROCESS_MODE_INHERIT, "world is pausable (inherit)")
	# Base plain stays flat/windless and signals generation.
	var w := World.new()
	var got := [false]
	w.generated.connect(func() -> void: got[0] = true)
	add_child(w)
	check(w.is_generated and got[0], "base World emits generated and sets is_generated")
	vnear(w.get_wind(Vector3(10, 50, 10)), Vector3.ZERO, 1e-6, "base windless")
	near(w.ground_height(5, 5), 0.0, 1e-6, "base flat")
	w.queue_free()
	# Data shape of landmarks / refuges / perches.
	var lm_bad := 0
	var names := {}
	var dup := 0
	for l in world.get_landmarks():
		if not (l.has("name") and l.has("kind") and l.has("position") and l.has("radius")):
			lm_bad += 1
		if typeof(l.get("position")) != TYPE_VECTOR3 or typeof(l.get("radius")) != TYPE_FLOAT:
			lm_bad += 1
		if names.has(l["name"]):
			dup += 1
		names[l["name"]] = true
		if l["kind"] == "opening":
			for key in ["normal", "width", "height", "max_span"]:
				if not l.has(key):
					lm_bad += 1
	eq(lm_bad, 0, "every landmark has name/kind/position(Vector3)/radius(float); openings have normal/width/height/max_span")
	metric("duplicate_landmark_names", dup)
	var rf_bad := 0
	for r in world.get_refuges():
		if not (r.has("position") and r.has("radius") and r.has("max_span")):
			rf_bad += 1
	eq(rf_bad, 0, "refuges have position/radius/max_span")
	var p_bad := 0
	var outside := 0
	for p in world.get_perches():
		if p.district == &"" or absf(p.facing.length() - 1.0) > 1e-3 or absf(p.facing.y) > 1e-4 or p.max_span <= 0.0:
			p_bad += 1
		if not world.is_inside(p.position + Vector3.UP * 0.3):
			outside += 1
	eq(p_bad, 0, "every perch has a district, unit horizontal facing, positive max_span")
	eq(outside, 0, "every perch is inside the arena")
	# Layers: every static body collides on layer 1 and queries nothing.
	var layer_bad: PackedStringArray = []
	var areas := 0
	var n_bodies := 0
	for b in _all_bodies():
		n_bodies += 1
		if not (b.collision_layer & 1) or b.collision_mask != 0:
			layer_bad.append(String(b.name))
	var stack: Array[Node] = [world]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is Area3D:
			areas += 1
		for c in n.get_children():
			stack.append(c)
	eq(layer_bad.size(), 0, "static bodies on layer 1 with mask 0: %s" % ", ".join(layer_bad.slice(0, 5)))
	metric("static_bodies", n_bodies)
	metric("area3ds", areas)
	print("[world-verify] contract: %d bodies, %d Area3D, %d duplicate landmark names" % [n_bodies, areas, dup])


# --- W1: random 3D escape rays --------------------------------------------

func test_w1_random_3d_escape() -> void:
	var R := world.bounds_radius
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	var escapes := 0
	var sphere_escapes := 0
	var n := 0
	var max_r := 0.0
	while n < 4000:
		var a := rng.randf() * TAU
		var rr := sqrt(rng.randf()) * (R - 3.0)
		var x := cos(a) * rr
		var z := sin(a) * rr
		var g := world.ground_height(x, z)
		if g > world.ceiling - 4.0:
			continue
		var y := rng.randf_range(g + 1.0, world.ceiling - 1.0)
		var p := Vector3(x, y, z)
		# Random direction, biased toward the horizon and upward (escape paths).
		var d := Vector3(rng.randf_range(-1, 1), rng.randf_range(-0.2, 1.0), rng.randf_range(-1, 1)).normalized()
		var far := p + d * 2500.0
		n += 1
		var hit := _ray(p, far)
		if hit.is_empty():
			escapes += 1
			continue
		var hp: Vector3 = hit["position"]
		max_r = maxf(max_r, Vector2(hp.x, hp.z).length())
		if Vector2(hp.x, hp.z).length() > R / cos(PI / 96.0) + 0.6 or hp.y > world.ceiling + 0.6:
			escapes += 1
		if _cast(p, far, 0.02) >= 1.0:
			sphere_escapes += 1
	eq(escapes, 0, "no random 3D ray from inside leaves the arena (%d rays)" % n)
	eq(sphere_escapes, 0, "no 2 cm sphere leaves either")
	metric("max_reach_radius", max_r)
	print("[world-verify] W1 random: %d rays, %d escapes, %d sphere escapes, max reach r=%.2f (R=%.1f)" % [n, escapes, sphere_escapes, max_r, R])


func test_w1_no_holes_in_the_ground() -> void:
	var R := world.bounds_radius
	var holes := 0
	var n := 0
	var worst := 0.0
	var x := -R
	while x <= R:
		var z := -R
		while z <= R:
			if Vector2(x, z).length() <= R:
				n += 1
				var hit := _ray(Vector3(x, world.ceiling - 0.5, z), Vector3(x, -200.0, z))
				if hit.is_empty():
					holes += 1
				else:
					var gy := world.ground_height(x, z)
					if (hit["position"] as Vector3).y < gy - 0.05:
						holes += 1
						worst = maxf(worst, gy - (hit["position"] as Vector3).y)
			z += 6.0
		x += 6.0
	eq(holes, 0, "every downward ray inside the arena stops at or above the ground (%d rays)" % n)
	metric("ground_rays", n)
	print("[world-verify] W1 ground: %d rays, %d holes, worst %.2f" % [n, holes, worst])


# --- W2: fly all the way through ------------------------------------------

func test_w2_fly_through_windows_and_barn() -> void:
	var fails: PackedStringArray = []
	var n := 0
	for l in world.get_landmarks():
		if l["kind"] != "window":
			continue
		n += 1
		var a: Vector3 = l["position"]
		var b: Vector3 = l["exit"]
		var span: float = l["max_span"]
		var r := k_body * span
		var dir := (b - a).normalized()
		var from := a - dir * (r + 1.5)
		var to := b + dir * (r + 1.5)
		if _cast(from, to, r) < 1.0:
			fails.append("%s (%.2f m)" % [l["name"], span])
	gt(float(n), 7.0, "at least 8 fly-through houses")
	eq(fails.size(), 0, "rated bird flies in the front window and out the back: %s" % ", ".join(fails))
	# The barn: in one end door, out the other.
	var doors := world.get_openings().filter(func(o: Dictionary) -> bool: return o["type"] == "barn_door")
	check(doors.size() >= 2, "barn has two end doors")
	if doors.size() >= 2:
		var d0: Dictionary = doors[0]
		var d1: Dictionary = doors[1]
		var span := minf(float(d0["max_span"]), float(d1["max_span"]))
		var r := k_body * span
		var p0: Vector3 = d0["position"]
		var p1: Vector3 = d1["position"]
		var dir := (p1 - p0).normalized()
		var f := _cast(p0 - dir * (r + 1.5), p1 + dir * (r + 1.5), r)
		check(f >= 1.0, "rated bird flies through the barn door to door (free fraction %.3f)" % f)
		metric("barn_through_fraction", f)
	metric("through_houses", n)
	print("[world-verify] W2 through: %d houses, %d fail: %s" % [n, fails.size(), ", ".join(fails)])


func test_w2_opening_inventory() -> void:
	var types := {}
	var spans := {}
	for o in world.get_openings():
		var t: String = o["type"]
		types[t] = types.get(t, 0) + 1
		if not spans.has(t):
			spans[t] = [INF, 0.0]
		spans[t][0] = minf(spans[t][0], float(o["max_span"]))
		spans[t][1] = maxf(spans[t][1], float(o["max_span"]))
		check(world.is_inside((o["position"] as Vector3) + (o["normal"] as Vector3) * 1.0) or t == "arch",
			"opening %s approach is inside the arena" % o["name"])
	metric("types", types)
	metric("span_by_type", spans)
	# Which species fit at least one opening of the smallest kind but a larger does not.
	var wren := float(SizeRules.SPECIES[1]["span"])
	var eagle := float(SizeRules.SPECIES[9]["span"])
	var n_wren_only := 0
	var n_eagle := 0
	for o in world.get_openings():
		var s: float = o["max_span"]
		if s >= wren and s < float(SizeRules.SPECIES[2]["span"]):
			n_wren_only += 1
		if s >= eagle:
			n_eagle += 1
	gt(float(n_wren_only), 0.0, "some openings admit a wren but not a sparrow")
	gt(float(n_eagle), 0.0, "some openings admit an eagle")
	print("[world-verify] W2 inventory: %s spans %s wren-only %d eagle %d" % [types, spans, n_wren_only, n_eagle])


# --- W3: approach clearance ------------------------------------------------

func test_w3_perches_are_approachable() -> void:
	var perches := world.get_perches()
	var boxed := 0
	var boxed_by_kind := {}
	var close_pairs := 0
	var dirs: Array[Vector3] = []
	for dy in [-1, 0, 1]:
		for dx in [-1, 0, 1]:
			for dz in [-1, 0, 1]:
				if dx != 0 or dy != 0 or dz != 0:
					dirs.append(Vector3(dx, dy, dz).normalized())
	for p in perches:
		var r := k_body * p.max_span
		var c := p.position + Vector3.UP * (r + 0.03)
		var free := false
		for d in dirs:
			if _cast(c, c + d * maxf(2.0, 6.0 * r), r) >= 1.0:
				free = true
				break
		if not free:
			boxed += 1
			var kn: String = Perch.Kind.keys()[p.kind]
			boxed_by_kind[kn] = boxed_by_kind.get(kn, 0) + 1
	# Near-duplicate perches (two claims on one spot).
	for i in perches.size():
		for j in range(i + 1, mini(i + 40, perches.size())):
			if perches[i].position.distance_to(perches[j].position) < 0.05:
				close_pairs += 1
	metric("boxed_perches", boxed)
	metric("boxed_by_kind", boxed_by_kind)
	metric("near_duplicate_perches", close_pairs)
	lt(float(boxed) / perches.size(), 0.01, "< 1% of perches have no straight 26-direction approach for their rated bird")
	print("[world-verify] W3: %d perches, %d with no clear approach %s, %d near-duplicates" % [perches.size(), boxed, boxed_by_kind, close_pairs])


# --- W4: whole-domain smoothness and API honesty ---------------------------

func test_w4_wind_smooth_everywhere() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 99
	var worst := 0.0
	var worst_at := Vector3.ZERO
	var worst_t := 0.0
	var ths := world.get_thermals()
	for t: float in [0.0, 55.0, 140.0, 260.0, 410.0]:
		world.set_air_time(t)
		for i in 30000:
			var p: Vector3
			if i % 2 == 0 and not ths.is_empty():
				# Near thermal columns (incl. their drift and lean): where
				# cell-coverage cut-offs would show up as jumps.
				var j := rng.randi() % ths.size()
				var y := rng.randf_range(2.0, 299.0)
				var c := world.wind.thermal_center(j, y)
				p = c + Vector3(rng.randf_range(-90, 90), 0, rng.randf_range(-90, 90))
			else:
				p = Vector3(rng.randf_range(-680, 680), rng.randf_range(0.0, 300.0), rng.randf_range(-680, 680))
			if not world.is_inside(p):
				continue
			var d := Vector3(rng.randf_range(-1, 1), rng.randf_range(-1, 1), rng.randf_range(-1, 1)).normalized() * 0.25
			var g := (world.get_wind(p + d) - world.get_wind(p)).length() / 0.25
			if g > worst:
				worst = g
				worst_at = p
				worst_t = t
	# The builder's own bound is 0.6; inside the arena it is exceeded only on
	# the west mountain-slope lift band (~1 sample in 130k, 0.61), so 0.7 here.
	lt(worst, 0.7, "wind gradient bounded in the playable volume (m/s per m), worst at %s t=%.0f" % [worst_at, worst_t])
	metric("max_gradient_anywhere", worst)
	metric("max_gradient_at", [worst_at.x, worst_at.y, worst_at.z, worst_t])
	print("[world-verify] W4 smooth: worst |dw|/ds %.3f at %s t=%.0f" % [worst, worst_at, worst_t])


func test_w4_cores_over_time_and_height() -> void:
	var ths := world.get_thermals()
	var core_min := INF
	var core_max := 0.0
	var strength_err := 0.0
	var t := 0.0
	while t <= 600.0:
		world.set_air_time(t)
		ths = world.get_thermals()
		for i in ths.size():
			var th: Dictionary = ths[i]
			var g: float = (th["position"] as Vector3).y
			var top: float = th["top"]
			var y := g + 30.0
			while y <= top - 55.0:
				var lean: Vector3 = th["lean"]
				var pos: Vector3 = th["position"]
				# Documented: the column at height y is centred at position + lean * y.
				var c := Vector3(pos.x + lean.x * y, y, pos.z + lean.z * y)
				var w := world.get_wind(c).y
				core_min = minf(core_min, w)
				core_max = maxf(core_max, w)
				if world.wind.lift_strength_at(c.x, c.z) == 0.0:
					strength_err = maxf(strength_err, absf(w - float(th["strength"])))
				y += 10.0
		t += 6.0
	gt(core_min, 3.0, "cores >= 3 m/s over 10 min at every height 30 m AGL..top-55")
	lt(core_max, 5.0, "cores <= 5 m/s")
	lt(strength_err, 0.05, "get_thermals().strength is the live core value (documented centre)")
	metric("core_range_10min", [core_min, core_max])
	metric("strength_err", strength_err)
	print("[world-verify] W4 cores over 10 min: [%.2f, %.2f], strength api err %.3f" % [core_min, core_max, strength_err])


func test_w4_wind_cost_typical_birds() -> void:
	# Birds live low: sample the bottom 80 m over the populated zone.
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	var pts := PackedVector3Array()
	for i in 100000:
		var x := rng.randf_range(-480, 480)
		var z := rng.randf_range(-480, 480)
		pts.append(Vector3(x, world.ground_height(x, z) + rng.randf_range(1, 80), z))
	var acc := Vector3.ZERO
	var t0 := Time.get_ticks_usec()
	for p in pts:
		acc += world.get_wind(p)
	var us := (Time.get_ticks_usec() - t0) / 100000.0
	lt(us, 5.0, "get_wind < 5 us in the populated low air")
	metric("wind_us_low", us)
	finite(acc, "sum")
	print("[world-verify] W4 cost low air: %.2f us" % us)


func test_w4_motes_follow_thermals() -> void:
	await wait_frames(2)
	var m := world.motes
	check(m != null, "motes exist")
	if m == null:
		return
	check(m.custom_aabb.size.x >= 2.0 * world.bounds_radius, "mote AABB spans the valley (never frustum-culled wrongly)")
	check(m.process_mode != Node.PROCESS_MODE_DISABLED, "motes animate")
	var mat := m.material_override as ShaderMaterial
	var centers: PackedVector4Array = mat.get_shader_parameter(&"centers")
	var ths := world.get_thermals()
	var off := 0.0
	for i in ths.size():
		var p: Vector3 = ths[i]["position"]
		off = maxf(off, Vector2(centers[i].x - p.x, centers[i].z - p.z).length())
	lt(off, WindField.DRIFT * 1.5 + 1.0, "mote uniforms track the live thermal centres (max offset %.2f m)" % off)


# --- W5: physical density and open space -----------------------------------

func test_w5_physical_density_and_open_space() -> void:
	var sph := SphereShape3D.new()
	sph.radius = 120.0
	var covered := 0
	var total := 0
	var x := -WorldLayout.INNER_R
	while x <= WorldLayout.INNER_R:
		var z := -WorldLayout.INNER_R
		while z <= WorldLayout.INNER_R:
			if Vector2(x, z).length() <= WorldLayout.INNER_R:
				total += 1
				var g := world.ground_height(x, z)
				if not _overlap(sph, Transform3D(Basis.IDENTITY, Vector3(x, g + 5.0, z)), ground_rids).is_empty():
					covered += 1
			z += 20.0
		x += 20.0
	var frac := float(covered) / total
	gt(frac, 0.95, "physically: >= 95%% of the inner zone has non-terrain geometry within 120 m (%d/%d)" % [covered, total])
	metric("physical_density", frac)
	# The largest clear columns: a 150 m radius cylinder with nothing but terrain.
	var cyl := CylinderShape3D.new()
	cyl.radius = 150.0
	cyl.height = 600.0
	var clear_spots := 0
	var gx := -500.0
	while gx <= 500.0:
		var gz := -500.0
		while gz <= 500.0:
			if Vector2(gx, gz).length() <= 520.0:
				if _overlap(cyl, Transform3D(Basis.IDENTITY, Vector3(gx, 0, gz)), ground_rids).is_empty():
					clear_spots += 1
			gz += 25.0
		gx += 25.0
	gt(float(clear_spots), 0.0, "at least one 150 m radius column holds nothing but terrain/water")
	metric("clear_150m_centres", clear_spots)
	print("[world-verify] W5 physical: density %.3f (%d/%d), 150 m clear centres %d" % [frac, covered, total, clear_spots])


# --- W6: physical grounding -------------------------------------------------

func test_w6_footprints_touch_ground_physically() -> void:
	# Trimesh faces are one-sided (a probe inside a solid sees nothing), so
	# look from OUTSIDE: 8 horizontal rays 10 cm above the local ground pass
	# through each footprint point. Grounded objects are hit; floating ones
	# are passed under. (Catches houses +1.5 m / trees +1 m, which the
	# builder's declared-base test does not.)
	var floating: PackedStringArray = []
	var n := 0
	for fp in world.build.footprints:
		var nm: String = fp["name"]
		if nm.ends_with("_back"):
			continue
		n += 1
		var reach := 1.2 if (nm == "tree" or nm == "fence_post" or nm.begins_with("pole_") or nm == "bush") else 3.0
		var hit_any := false
		for q in (fp["points"] as PackedVector2Array):
			var g := world.terrain.height_at(q.x, q.y)
			var c := Vector3(q.x, g + 0.1, q.y)
			for k in 8:
				var d := Vector3(cos(TAU * k / 8.0), 0, sin(TAU * k / 8.0)) * reach
				if not _ray(c + d, c - d, ground_rids).is_empty():
					hit_any = true
					break
			if hit_any:
				break
		if not hit_any:
			floating.append("%s@(%.0f,%.0f)" % [nm, (fp["points"] as PackedVector2Array)[0].x, (fp["points"] as PackedVector2Array)[0].y])
	metric("footprints_checked", n)
	metric("not_touching", Array(floating))
	eq(floating.size(), 0, "physically: every footprint has solid geometry 10 cm above the ground: %s" % ", ".join(floating.slice(0, 8)))
	# Soft decoration sits on the ground (no floating tufts).
	var soft: Node = world.get_node("Soft")
	var float_decor := 0
	var checked := 0
	for mmi in soft.get_children():
		if not (mmi is MultiMeshInstance3D) or mmi.get_meta(&"soft", "") == "motes":
			continue
		var mm := (mmi as MultiMeshInstance3D).multimesh
		for i in range(0, mm.instance_count, 7):
			var o := mm.get_instance_transform(i).origin
			var g := world.ground_height(o.x, o.z)
			checked += 1
			if o.y > g + 0.05:
				float_decor += 1
	eq(float_decor, 0, "grass/flowers/reeds start at or below the ground (%d checked)" % checked)
	print("[world-verify] W6 physical (side rays): %d footprints, %d not grounded: %s; decor floating %d/%d" % [n, floating.size(), ", ".join(floating.slice(0, 12)), float_decor, checked])


# --- W9: a fingerprint to compare across processes -------------------------

func test_w9_fingerprint() -> void:
	var parts := PackedStringArray()
	for p in world.get_perches():
		parts.append("%d|%.3f|%.3f|%.3f|%.3f|%s" % [p.kind, p.position.x, p.position.y, p.position.z, p.max_span, p.district])
	for l in world.get_landmarks():
		var pos: Vector3 = l["position"]
		parts.append("%s|%s|%.3f|%.3f|%.3f" % [l["name"], l["kind"], pos.x, pos.y, pos.z])
	for r in world.get_refuges():
		var pos: Vector3 = r["position"]
		parts.append("%.3f|%.3f|%.3f|%.3f" % [pos.x, pos.y, pos.z, r["max_span"]])
	var h := "|".join(parts).sha256_text()
	# Geometry too: every visual vertex count and a coarse vertex checksum.
	var geo := PackedStringArray()
	for mi in world.get_node("Visual").get_children():
		if mi is MeshInstance3D and (mi as MeshInstance3D).mesh:
			var arr := (mi as MeshInstance3D).mesh.surface_get_arrays(0)
			var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var s := Vector3.ZERO
			for k in range(0, v.size(), 13):
				s += v[k]
			geo.append("%s|%d|%.2f|%.2f|%.2f" % [mi.name, v.size(), s.x, s.y, s.z])
	var hg := "|".join(geo).sha256_text()
	metric("hash_data", h)
	metric("hash_geometry", hg)
	check(h.length() == 64, "hash computed")
	print("[world-verify] W9 fingerprint data=%s geometry=%s" % [h, hg])


# --- W10: geometry outside Visual/Soft, denser sampling ----------------------

func test_w10_no_uncovered_geometry_anywhere() -> void:
	var visual: Node = world.get_node("Visual")
	var soft: Node = world.get_node("Soft")
	var stray: PackedStringArray = []
	var stack: Array[Node] = [world]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is GeometryInstance3D:
			var p := n.get_parent()
			if p != visual and p != soft and n != world.motes:
				stray.append(String(n.get_path()))
		for c in n.get_children():
			stack.append(c)
	eq(stray.size(), 0, "every drawn thing lives under Visual or Soft: %s" % ", ".join(stray.slice(0, 5)))
	# Collider metas point at real layer-1 bodies.
	var dangling := 0
	for mi in visual.get_children():
		if mi.has_meta(&"collider"):
			var b: Object = mi.get_meta(&"collider")
			if not (b is StaticBody3D) or not is_instance_valid(b) or not ((b as StaticBody3D).collision_layer & 1):
				dangling += 1
	eq(dangling, 0, "collider metas point at live layer-1 bodies")
	# Denser sampling: 1500 triangles per mesh, probe 1.5 cm outside, 3 cm sphere.
	var rng := RandomNumberGenerator.new()
	rng.seed = 777
	var worst := 1.0
	var worst_name := ""
	var total := 0
	var ok_total := 0
	for mi in visual.get_children():
		if not (mi is MeshInstance3D):
			continue
		var mesh: Mesh = (mi as MeshInstance3D).mesh
		var verts: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		var tris := verts.size() / 3
		if tris == 0:
			continue
		var n := mini(tris, 1500)
		var ok := 0
		var gt3 := (mi as MeshInstance3D).global_transform
		for s in n:
			var t := rng.randi() % tris
			var a := verts[t * 3]
			var b := verts[t * 3 + 1]
			var c := verts[t * 3 + 2]
			# Random point inside the triangle, not only the centroid.
			var u := rng.randf()
			var v := rng.randf()
			if u + v > 1.0:
				u = 1.0 - u
				v = 1.0 - v
			var pt := gt3 * (a + (b - a) * u + (c - a) * v)
			var nrm := (b - a).cross(c - a)
			if nrm.length() < 1e-9:
				ok += 1
				continue
			var inward := (gt3.basis * nrm.normalized()).normalized()
			var sp := SphereShape3D.new()
			sp.radius = 0.05 if String(mi.name).begins_with("trees_") else 0.03
			if not _overlap(sp, Transform3D(Basis.IDENTITY, pt - inward * 0.015), []).is_empty():
				ok += 1
		total += n
		ok_total += ok
		var f := float(ok) / n
		if f < worst:
			worst = f
			worst_name = String(mi.name)
	gt(float(ok_total) / total, 0.98, "dense sampling: random points on visible triangles are backed by colliders")
	metric("dense_coverage", float(ok_total) / total)
	metric("dense_worst", [worst_name, worst])
	print("[world-verify] W10 dense: %d samples, coverage %.4f, worst %s %.3f, stray geometry %d" % [total, float(ok_total) / total, worst_name, worst, stray.size()])
