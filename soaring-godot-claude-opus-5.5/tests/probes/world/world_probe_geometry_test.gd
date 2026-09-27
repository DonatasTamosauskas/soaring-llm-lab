extends TestCase
## Verifier probes (round 1, independent) for the world area.
##
##   tools/gd.sh world_verify --headless res://tests/runner.tscn -- --dir=res://tests/probes/world
##
## Adversarial checks the builder's suite does not make: rooms/cavities closed
## from the INSIDE (one-sided trimesh walls would let a bird out), full
## front-to-back window traversal for every size that is rated to fit,
## oblique entries, API robustness far outside the arena, perch overlap and
## approachability, spawn clearance for every size, thermal circling
## geometry, exhaustive collider coverage, stray geometry outside Visual/Soft,
## geometry determinism (vertex hash, not only perches).

var world: SoaringWorld
var space: PhysicsDirectSpaceState3D
var k_body := 0.16


func before_all() -> void:
	k_body = WorldBuild.body_k()
	world = load("res://scenes/world/world.tscn").instantiate()
	add_child(world)
	await wait_physics(2)
	space = world.get_world_3d().direct_space_state


func after_all() -> void:
	if world:
		world.queue_free()


# --- helpers ---------------------------------------------------------------

func _ray(a: Vector3, b: Vector3, back_faces := true) -> Dictionary:
	var q := PhysicsRayQueryParameters3D.create(a, b)
	q.collision_mask = 1
	q.hit_back_faces = back_faces
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


func _overlaps(c: Vector3, r: float) -> bool:
	var sp := SphereShape3D.new()
	sp.radius = r
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = sp
	q.collision_mask = 1
	q.transform = Transform3D(Basis.IDENTITY, c)
	return not space.intersect_shape(q, 1).is_empty()


static func _fib_dirs(n: int) -> PackedVector3Array:
	var out := PackedVector3Array()
	var ga := PI * (3.0 - sqrt(5.0))
	for i in n:
		var y := 1.0 - (i + 0.5) * 2.0 / n
		var rr := sqrt(1.0 - y * y)
		var th := ga * i
		out.append(Vector3(cos(th) * rr, y, sin(th) * rr))
	return out


static func _refuge_type(nm: String) -> String:
	if nm.ends_with("_room"):
		return "room"
	for pre in ["hedge", "nest", "cliff", "hollow", "belfry", "loft", "tank", "ruin", "tree"]:
		if nm.begins_with(pre) or nm.contains(pre):
			return pre
	return nm.get_slice("_", 0)


# --- 1. cavities are closed from the inside ---------------------------------

func test_refuges_closed_from_inside() -> void:
	var dirs := _fib_dirs(160)
	var by_type := {}
	var in_solid: PackedStringArray = []
	var too_tight: PackedStringArray = []
	for rf in world.get_refuges():
		var nm: String = rf.get("name", "?")
		var t := _refuge_type(nm)
		var p: Vector3 = rf["position"]
		var span: float = rf["max_span"]
		if _overlaps(p, 0.015):
			in_solid.append(nm)
			continue
		if _overlaps(p, k_body * span):
			too_tight.append("%s(%.2f)" % [nm, span])
		# A wren-sized body moving outward in every direction: how many escape
		# 40 m without touching anything? One-sided walls would let most out.
		var esc_cast := 0
		var esc_ray_front := 0
		for d in dirs:
			if _cast(p, p + d * 40.0, 0.02) >= 1.0:
				esc_cast += 1
			if _ray(p, p + d * 40.0, false).is_empty():
				esc_ray_front += 1
		var e: Dictionary = by_type.get(t, {"n": 0, "cast_sum": 0.0, "cast_max": 0.0, "ray_sum": 0.0, "worst": ""})
		var fc := float(esc_cast) / dirs.size()
		e["n"] += 1
		e["cast_sum"] += fc
		e["ray_sum"] += float(esc_ray_front) / dirs.size()
		if fc > e["cast_max"]:
			e["cast_max"] = fc
			e["worst"] = nm
		by_type[t] = e
	var summary := {}
	for t in by_type:
		var e: Dictionary = by_type[t]
		summary[t] = {"n": e["n"], "escape_cast_mean": snappedf(e["cast_sum"] / e["n"], 0.001),
			"escape_cast_max": snappedf(e["cast_max"], 0.001), "escape_frontface_ray_mean": snappedf(e["ray_sum"] / e["n"], 0.001), "worst": e["worst"]}
		print("[world-verify] refuge %-8s n=%3d  escape(cast) mean %.3f max %.3f  (front-face ray %.3f)  worst %s" % [
			t, e["n"], e["cast_sum"] / e["n"], e["cast_max"], e["ray_sum"] / e["n"], e["worst"]])
	metric("refuge_escape", summary)
	metric("refuge_in_solid", Array(in_solid))
	metric("refuge_too_tight", Array(too_tight))
	eq(in_solid.size(), 0, "refuge centres are in open air: %s" % ", ".join(in_solid.slice(0, 8)))
	eq(too_tight.size(), 0, "refuge centre fits its max_span bird: %s" % ", ".join(too_tight.slice(0, 8)))
	# Closed cavities: rooms, tank, nest boxes, hollows, cliff holes. Only the
	# openings' solid angle may leak.
	for t in ["room", "tank", "nest", "hollow", "cliff"]:
		if summary.has(t):
			lt(float(summary[t]["escape_cast_max"]), 0.2, "%s cavities are closed from the inside" % t)


# --- 2. fly-through windows: the whole way through, every rated size --------

func test_windows_fly_through_front_to_back() -> void:
	var blocked: PackedStringArray = []
	var n := 0
	var margins := []
	for l in world.get_landmarks():
		if l["kind"] != "window":
			continue
		var a: Vector3 = l["position"]
		var b: Vector3 = l["exit"]
		var span: float = l["max_span"]
		var d := (b - a).normalized()
		n += 1
		for s in SizeRules.SPECIES:
			var sp: float = s["span"]
			if sp > span:
				continue
			var r := k_body * sp
			if _cast(a - d * (r + 2.0), b + d * (r + 2.0), r) < 1.0:
				blocked.append("%s:%s" % [l["name"], s["id"]])
		# Largest body that makes it all the way (bisection), vs the rating.
		var lo := 0.0
		var hi := 1.0
		for it in 14:
			var mid := (lo + hi) * 0.5
			if _cast(a - d * (mid + 2.0), b + d * (mid + 2.0), mid) >= 1.0:
				lo = mid
			else:
				hi = mid
		margins.append(snappedf(lo / (k_body * span), 0.01))
	gt(float(n), 7.0, "at least 8 fly-through houses")
	eq(blocked.size(), 0, "every rated size flies front window -> back window: %s" % ", ".join(blocked.slice(0, 8)))
	metric("fly_through_houses", n)
	metric("max_body_over_rated_body", margins)


# --- 3. oblique entries -------------------------------------------------------

func test_openings_oblique_entry() -> void:
	# Birds rarely arrive dead square. For each opening: the largest angle off
	# the normal (bisection, 4 tilt planes, worst plane kept) at which the
	# RATED bird still passes the whole depth through the hole's centre.
	# Informational per type; the assertion is only that a bird two sizes
	# smaller than the rating gets through at 10 degrees (usable in play).
	var per := {}
	var small_by_type := {}
	for o in world.get_openings():
		var t: String = o["type"]
		var p: Vector3 = o["position"]
		var n: Vector3 = o["normal"]
		var up: Vector3 = o["up"]
		var right := up.cross(n).normalized()
		var span: float = o["max_span"]
		var depth: float = o["depth"]
		var worst := 40.0
		for tilt in [right, -right, up, -up]:
			var lo := 0.0
			var hi := 40.0
			for it in 8:
				var mid := (lo + hi) * 0.5
				if _pass_at(p, n, tilt, mid, k_body * span, depth):
					lo = mid
				else:
					hi = mid
			worst = minf(worst, lo)
		var arr: Array = per.get(t, [])
		arr.append(worst)
		per[t] = arr
		# Two species below the rating (or 60% of the rated span).
		var smaller := span * 0.6
		for i in range(SizeRules.SPECIES.size() - 1, -1, -1):
			if float(SizeRules.SPECIES[i]["span"]) <= span * 0.999:
				smaller = float(SizeRules.SPECIES[maxi(i - 2, 0)]["span"])
				break
		var all_dirs := true
		for tilt in [right, -right, up, -up]:
			all_dirs = all_dirs and _pass_at(p, n, tilt, 10.0, k_body * smaller, minf(depth, 1.0))
		var sb: Array = small_by_type.get(t, [0, 0])
		sb[0] += 1 if all_dirs else 0
		sb[1] += 1
		small_by_type[t] = sb
	var out := {}
	for t in per:
		var a: Array = per[t]
		a.sort()
		out[t] = {"median_deg": snappedf(a[a.size() / 2], 0.1), "min_deg": snappedf(a[0], 0.1)}
	print("[world-verify] max entry angle for the RATED bird (full depth), by type: ", out)
	var sm := {}
	var ok_open := 0
	var n_open := 0
	for t in small_by_type:
		sm[t] = "%d/%d" % small_by_type[t]
		# Tunnels (hedge gaps, cliff holes) need alignment by nature; the
		# fly-through openings should forgive a 10 degree approach.
		if not (t in ["hedge_gap", "cliff_hole", "bridge_arch"]):
			ok_open += small_by_type[t][0]
			n_open += small_by_type[t][1]
	print("[world-verify] two-sizes-smaller bird at 10 deg (first 1 m) by type: ", sm)
	metric("rated_max_entry_angle", out)
	metric("smaller_bird_10deg_by_type", sm)
	gt(float(ok_open) / n_open, 0.9, "a bird two sizes below the rating enters non-tunnel openings at 10 deg")


func _pass_at(p: Vector3, n: Vector3, tilt: Vector3, deg: float, r: float, depth: float) -> bool:
	var dir := ((-n) * cos(deg_to_rad(deg)) + tilt * sin(deg_to_rad(deg))).normalized()
	return _cast(p - dir * (r + 1.0), p + dir * depth, r) >= 1.0


# --- 4. API robustness -------------------------------------------------------------

func test_api_far_outside_and_edges() -> void:
	var pts := [Vector3(5000, 50, 5000), Vector3(-5000, -100, -5000), Vector3(0, 1e6, 0), Vector3(0, -1e6, 0),
		Vector3(703.99, 120, 0), Vector3(704.0, 120, 704.0), Vector3(-704.0, 120, -704.0), Vector3(1e9, 0, -1e9),
		Vector3(-703.99, 60, 0), Vector3(0, 60, 703.99), Vector3(760, 10, 0), Vector3(-900, 10, 900)]
	var bad := 0
	for p in pts:
		var w := world.get_wind(p)
		if not (is_finite(w.x) and is_finite(w.y) and is_finite(w.z)):
			bad += 1
			print("[world-verify] non-finite wind at ", p, " -> ", w)
		var g := world.ground_height(p.x, p.z)
		if not is_finite(g):
			bad += 1
			print("[world-verify] non-finite ground at ", p)
		if Vector2(p.x, p.z).length() > world.bounds_radius + 1.0 and world.is_inside(p):
			bad += 1
			print("[world-verify] is_inside true far outside at ", p)
	eq(bad, 0, "wind/ground/is_inside behave far outside the arena")
	# find_perches edge cases.
	eq(world.find_perches(Vector3(0, 20, 0), 0.0, 1.0).size(), 0, "radius 0 finds nothing (no perch at the origin)")
	var all_fit := 0
	for p in world.get_perches():
		if p.is_free() and p.fits(0.1):
			all_fit += 1
	eq(world.find_perches(Vector3.ZERO, 5000.0, 0.1).size(), all_fit, "huge radius finds every fitting perch")
	eq(world.find_perches(Vector3.ZERO, -5.0, 0.1).size(), 0, "negative radius finds nothing")
	# Hot-path cost at the arena edge (grid borders) stays small.
	var t0 := Time.get_ticks_usec()
	var acc := Vector3.ZERO
	for i in 20000:
		var a := i * 0.000314
		acc += world.get_wind(Vector3(cos(a) * 679.0, 150.0, sin(a) * 679.0))
	var us := (Time.get_ticks_usec() - t0) / 20000.0
	lt(us, 5.0, "get_wind at the rim < 5 us")
	metric("wind_us_rim", us)
	finite(acc, "rim wind")


# --- 5. perches ---------------------------------------------------------------------

func test_perch_overlap_facing_and_approach() -> void:
	var perches := world.get_perches()
	var bad_facing := 0
	var outside := 0
	var overlap_pairs := 0
	var overlap_examples: PackedStringArray = []
	var cell := 2.0
	var grid := {}
	for i in perches.size():
		var p := perches[i]
		if absf(p.facing.length() - 1.0) > 1e-3 or absf(p.facing.y) > 1e-3:
			bad_facing += 1
		var r := k_body * p.max_span
		if not world.is_inside(p.position + Vector3.UP * r):
			outside += 1
		var key := Vector3i(floori(p.position.x / cell), floori(p.position.y / cell), floori(p.position.z / cell))
		var arr: Array = grid.get(key, [])
		arr.append(i)
		grid[key] = arr
	for i in perches.size():
		var a := perches[i]
		var ra := k_body * a.max_span
		var ca := a.position + Vector3.UP * ra
		var key := Vector3i(floori(a.position.x / cell), floori(a.position.y / cell), floori(a.position.z / cell))
		for dx in [-1, 0, 1]:
			for dy in [-1, 0, 1]:
				for dz in [-1, 0, 1]:
					for j in grid.get(key + Vector3i(dx, dy, dz), []):
						if j <= i:
							continue
						var b := perches[j]
						var rb := k_body * b.max_span
						var cb := b.position + Vector3.UP * rb
						# Two birds of the SMALLEST size that fits both would still touch?
						if ca.distance_to(cb) < minf(ra, rb) * 2.0:
							overlap_pairs += 1
							if overlap_examples.size() < 6:
								overlap_examples.append("%s/%s %.2fm" % [Perch.Kind.keys()[a.kind], Perch.Kind.keys()[b.kind], a.position.distance_to(b.position)])
	# Approach: a bird of max_span must be able to arrive from SOME direction
	# (16 level + 8 descending directions, 3 m of clear path).
	var unreachable := {}
	var n_unreach := 0
	var dirs: Array[Vector3] = []
	for k in 16:
		var ang := TAU * k / 16.0
		dirs.append(Vector3(cos(ang), 0, sin(ang)))
	for k in 8:
		var ang := TAU * k / 8.0
		dirs.append(Vector3(cos(ang), 1.0, sin(ang)).normalized())
	dirs.append(Vector3.UP)
	for p in perches:
		var r := k_body * p.max_span
		var c := p.position + Vector3.UP * (r + 0.03)
		var ok := false
		for d in dirs:
			if _cast(c + d * 3.0, c, r) >= 1.0:
				ok = true
				break
		if not ok:
			n_unreach += 1
			var key := "%s/%s" % [Perch.Kind.keys()[p.kind], p.district]
			unreachable[key] = unreachable.get(key, 0) + 1
	eq(bad_facing, 0, "perch facing is unit and horizontal")
	eq(outside, 0, "perched body is inside the arena")
	metric("overlapping_perch_pairs", overlap_pairs)
	metric("overlap_examples", Array(overlap_examples))
	metric("unreachable_perches", unreachable)
	print("[world-verify] perches: %d, overlapping pairs %d %s, unreachable %d %s" % [perches.size(), overlap_pairs, overlap_examples, n_unreach, unreachable])
	lt(float(n_unreach) / perches.size(), 0.02, "< 2% of perches cannot be approached by their rated bird")
	# How many perches does each species have (sizes spanning the ladder)?
	var per_species := {}
	for s in SizeRules.SPECIES:
		var c := 0
		for p in perches:
			if p.fits(s["span"]):
				c += 1
		per_species[String(s["id"])] = c
	metric("perches_per_species", per_species)
	print("[world-verify] perches usable per species: ", per_species)
	gt(float(per_species["eagle"]), 19.0, "eagle has >= 20 perches")


# --- 6. spawn -----------------------------------------------------------------------

func test_spawn_fits_every_size() -> void:
	var sp := world.get_player_spawn()
	var fwd := -sp.basis.z
	var fits := {}
	var launch := {}
	for s in SizeRules.SPECIES:
		var r := k_body * float(s["span"])
		var c := sp.origin + Vector3.UP * (r + 0.02)
		fits[String(s["id"])] = not _overlaps(c, r)
		# Launch: level 3 m then a 15-degree glide for 25 m, clear of everything.
		var a := c + fwd * 3.0
		var b := a + (fwd * cos(deg_to_rad(15.0)) + Vector3.DOWN * sin(deg_to_rad(15.0))) * 25.0
		launch[String(s["id"])] = _cast(c, a, r) >= 1.0 and _cast(a, b, r) >= 1.0
	print("[world-verify] spawn %s  fits %s  launch-clear %s" % [sp.origin, fits, launch])
	metric("spawn_fits", fits)
	metric("spawn_launch_clear", launch)
	check(fits["sparrow"] and launch["sparrow"], "the starting sparrow fits and can launch")
	var all_fit := true
	for k in fits:
		all_fit = all_fit and fits[k] and launch[k]
	check(all_fit, "respawn spawn fits and launches every size (respawn happens at any size): %s %s" % [fits, launch])


# --- 7. thermal circling geometry ------------------------------------------------

func test_thermal_circling_geometry() -> void:
	# Mean updraft a bird feels circling at radius rc around each core at
	# 120 m. A real 3 kg eagle circles at ~12-20 m radius (v 10-13 m/s, 35-45
	# deg bank); a sparrow at ~4-6 m.
	world.set_air_time(0.0)
	var ths := world.get_thermals()
	var table := {}
	var worst_at_15 := INF
	var worst_at_20 := INF
	for i in ths.size():
		var c := world.wind.thermal_center(i, 120.0)
		var row := {}
		for rc: float in [5.0, 10.0, 15.0, 20.0, 25.0, 30.0]:
			var s := 0.0
			for k in 36:
				var a := TAU * k / 36.0
				s += world.get_wind(c + Vector3(cos(a), 0, sin(a)) * rc).y
			row[str(int(rc))] = snappedf(s / 36.0, 0.01)
		table[String(ths[i]["name"])] = row
		worst_at_15 = minf(worst_at_15, row["15"])
		worst_at_20 = minf(worst_at_20, row["20"])
	print("[world-verify] circling lift by radius (m/s): ", table)
	metric("circling_lift", table)
	metric("worst_mean_lift_r15", worst_at_15)
	metric("worst_mean_lift_r20", worst_at_20)
	# A big bird circling at 15 m must still climb (sink ~1-1.5 m/s banked).
	gt(worst_at_15, 1.5, "every thermal gives > 1.5 m/s mean lift on a 15 m circle")


# --- 8. exhaustive collider coverage, stray geometry ----------------------------

func test_every_drawn_triangle_collides_dense() -> void:
	var visual: Node = world.get_node("Visual")
	var rng := RandomNumberGenerator.new()
	rng.seed = 99
	var total := 0
	var hit := 0
	var worst := {}
	for mi in visual.get_children():
		if not (mi is MeshInstance3D):
			continue
		var m := mi as MeshInstance3D
		var arr := m.mesh.surface_get_arrays(0)
		var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var tris := verts.size() / 3
		var n := mini(tris, 2500)
		var ok := 0
		for s in n:
			var t := s if tris <= 2500 else rng.randi() % tris
			var a := verts[t * 3]
			var b := verts[t * 3 + 1]
			var c := verts[t * 3 + 2]
			# Random point on the triangle, not only the centroid.
			var u := rng.randf()
			var v := rng.randf()
			if u + v > 1.0:
				u = 1.0 - u
				v = 1.0 - v
			var q := m.global_transform * (a + (b - a) * u + (c - a) * v)
			var nrm := (b - a).cross(c - a)
			if nrm.length() < 1e-9:
				ok += 1
				continue
			var inward := (m.global_transform.basis * nrm.normalized()).normalized()
			# 1 cm outside the face, 2 cm sphere: collider must be within 1 cm.
			if _overlaps(q - inward * 0.01, 0.02):
				ok += 1
		total += n
		hit += ok
		worst[String(m.name)] = snappedf(float(ok) / maxf(n, 1), 0.001)
	var worst_list := []
	for k in worst:
		if worst[k] < 0.995:
			worst_list.append("%s=%.3f" % [k, worst[k]])
	print("[world-verify] dense collider coverage %.4f over %d samples; below 99.5%%: %s" % [float(hit) / total, total, worst_list])
	metric("dense_coverage", float(hit) / total)
	metric("dense_below_995", worst_list)
	gt(float(hit) / total, 0.99, "dense random-point coverage (1 cm tolerance)")


func test_no_geometry_outside_visual_or_soft() -> void:
	var stray: PackedStringArray = []
	var stack: Array[Node] = [world]
	while not stack.is_empty():
		var nd: Node = stack.pop_back()
		for ch in nd.get_children():
			stack.append(ch)
		if nd is GeometryInstance3D and (nd as GeometryInstance3D).visible:
			var par := nd.get_parent()
			if par == null or not (String(par.name) in ["Visual", "Soft"]):
				stray.append(String(world.get_path_to(nd)))
	print("[world-verify] geometry outside Visual/Soft: ", stray)
	metric("stray_geometry", Array(stray))
	eq(stray.size(), 0, "every visible geometry lives under Visual (collides) or Soft (allow-listed)")


# --- 9. density honesty ------------------------------------------------------------

func test_density_without_minor_features() -> void:
	# The 120 m density criterion counted every feature, including single
	# boulders, bales, bushes, logs and hedge segments. Recompute with only
	# the things that make flight intricate.
	var feats := world.build.features
	var kinds := world.build.feature_kinds
	var kind_count := {}
	for k in kinds:
		kind_count[k] = kind_count.get(k, 0) + 1
	metric("feature_kinds", kind_count)
	var minor := ["boulder", "bale", "bush", "log", "fence", "hedge", "anchor", "well", ""]
	var strong := PackedVector3Array()
	for i in feats.size():
		if not (kinds[i] in minor):
			strong.append(feats[i])
	var covered := 0
	var total := 0
	var R := WorldLayout.INNER_R
	var gx := -R
	while gx <= R:
		var gz := -R
		while gz <= R:
			if Vector2(gx, gz).length() <= R:
				total += 1
				for f in strong:
					if Vector2(f.x - gx, f.y - gz).length() - f.z <= 120.0:
						covered += 1
						break
			gz += 10.0
		gx += 10.0
	var frac := float(covered) / total
	print("[world-verify] feature kinds %s; coverage with only major features: %.3f" % [kind_count, frac])
	metric("coverage_major_only", frac)
	gt(frac, 0.9, "coverage without hedges/boulders/bales/logs/fences (informational floor)")


# --- 10. geometry determinism --------------------------------------------------------

func _geometry_hash(w: SoaringWorld) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	for mi in w.get_node("Visual").get_children():
		if mi is MeshInstance3D:
			var arr := (mi as MeshInstance3D).mesh.surface_get_arrays(0)
			ctx.update(String(mi.name).to_utf8_buffer())
			ctx.update((arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).to_byte_array())
			ctx.update((arr[Mesh.ARRAY_COLOR] as PackedColorArray).to_byte_array())
	return ctx.finish().hex_encode()


func test_geometry_is_deterministic() -> void:
	var h0 := _geometry_hash(world)
	# Disturb the global RNG first: a builder that used it would diverge.
	seed(987654)
	randi()
	var vp := SubViewport.new()
	vp.own_world_3d = true
	vp.size = Vector2i(8, 8)
	vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(vp)
	var w: SoaringWorld = load("res://scenes/world/world.tscn").instantiate()
	w.world_seed = 1
	vp.add_child(w)
	var h1 := _geometry_hash(w)
	vp.queue_free()
	await wait_frames(1)
	eq(h1, h0, "seed 1 draws the identical valley twice (vertex+colour hash)")
	metric("geometry_hash", h0)
