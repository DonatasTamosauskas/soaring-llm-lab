extends Node
## Headless diagnostics for the world builder (not a test): generation
## timings, tree triangle budgets per species/chunk, forest metrics.
##
##   tools/gd.sh world --headless res://tests/shots/world_diag.tscn -- [--seed=1]


func _ready() -> void:
	var args := Paths.user_args()
	if args.has("contrast"):
		# Burrow-vs-band luminance in a colony screenshot: the darkest 0.2 %
		# of pixels (the mouths) against the median of the band rows.
		var img := Image.load_from_file(String(args["contrast"]))
		var lum := PackedFloat32Array()
		for y in range(int(img.get_height() * 0.1), int(img.get_height() * 0.72)):
			for x in range(0, img.get_width(), 2):
				var c := img.get_pixel(x, y)
				lum.append(0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b)
		lum.sort()
		var dark := 0.0
		var nd := maxi(1, int(lum.size() * 0.002))
		for i in nd:
			dark += lum[i]
		dark /= nd
		var med := lum[lum.size() / 2]
		print("[world] contrast %s: band median %.3f, mouths %.3f, ratio %.1f" % [args["contrast"], med, dark, med / maxf(dark, 1e-4)])
		get_tree().quit()
		return
	if args.has("terrain_check"):
		var t := WorldTerrain.new(1)
		var t0 := Time.get_ticks_usec()
		t.generate()
		var t1 := Time.get_ticks_usec()
		var seq := PackedFloat32Array()
		for j in t.n + 1:
			seq.append_array(t._gen_row(j)[2])
		var t2 := Time.get_ticks_usec()
		var diff := 0
		for k in seq.size():
			if seq[k] != t.heights[k]:
				diff += 1
		print("[world] terrain threaded %.0f ms, sequential %.0f ms, differing heights %d of %d" % [(t1 - t0) / 1000.0, (t2 - t1) / 1000.0, diff, seq.size()])
		get_tree().quit()
		return
	var w: SoaringWorld = load("res://scenes/world/world.tscn").instantiate()
	w.world_seed = int(args.get("seed", "1"))
	add_child(w)
	await get_tree().physics_frame
	await get_tree().physics_frame
	print("[world] generation %.0f ms" % w.generation_ms)
	var keys := w.timings.keys()
	keys.sort()
	for k in keys:
		print("[world]   %-18s %s" % [k, w.timings[k]])
	var lib: TreeLib = w.build.get_meta(&"tree_lib")
	var by_sp := {}
	for v in lib.variants:
		var sp: String = TreeLib.Species.keys()[v["species"]]
		var lod_tris: int = (v["lod_arr"][0] as PackedVector3Array).size() / 3
		print("[world] variant %-8s tris %4d lod %3d colliders %d" % [sp, v["tris"], lod_tris, (v["colliders"] as Array).size()])
	var per_chunk := {}
	for inst in lib.instances:
		var c: String = inst["chunk"]
		per_chunk[c] = per_chunk.get(c, 0) + int(lib.variants[inst["v"]]["tris"])
		by_sp[inst["district"]] = by_sp.get(inst["district"], 0) + 1
	print("[world] trees %d by district %s" % [lib.instances.size(), by_sp])
	var total := 0
	for c in per_chunk:
		total += per_chunk[c]
	print("[world] tree tris total %d; per chunk %s" % [total, per_chunk])
	print("[world] stats ", w.stats())
	if args.has("ground_at"):
		_ground_at(w, String(args["ground_at"]))
	if args.has("silhouettes"):
		_silhouettes(lib)
	if args.has("standins"):
		_standins(w, lib)
	if args.has("farterrain"):
		var space2 := w.get_world_3d().direct_space_state
		var v := Vector3(-502.8, 359.0, -567.6)
		var rq := PhysicsRayQueryParameters3D.create(v + Vector3(0, 50, 0), v - Vector3(0, 50, 0))
		var hit := space2.intersect_ray(rq)
		print("[world] far terrain probe: ray hit ", hit.get("position"), " ", (hit["collider"] as Node).name if hit else "none", " height_at ", w.terrain.height_at(v.x, v.z))
		var sp := SphereShape3D.new()
		sp.radius = 4.0
		var q := PhysicsShapeQueryParameters3D.new()
		q.shape = sp
		q.transform = Transform3D(Basis.IDENTITY, Vector3(v.x, w.terrain.height_at(v.x, v.z), v.z))
		print("[world] sphere on surface hits: ", space2.intersect_shape(q, 4).map(func(h: Dictionary) -> String: return String((h["collider"] as Node).name)))
	if args.has("longcast"):
		_longcast(w)
	if args.has("seedsweep"):
		_seedsweep(w)
	if args.has("overhangs"):
		_overhangs(w)
	if args.has("opening"):
		_opening(w, String(args["opening"]))
	if args.has("arenasweep"):
		_arenasweep(w)
	if args.has("openings"):
		var by := {}
		for o in w.get_openings():
			if not by.has(o["type"]):
				by[o["type"]] = []
			by[o["type"]].append(snappedf(float(o["max_span"]), 0.01))
		for t in by:
			var a: Array = by[t]
			a.sort()
			print("[world] openings %s (%d): %s" % [t, a.size(), a if a.size() < 40 else [a[0], a[a.size() / 2], a[-1]]])
		for rf in w.get_refuges():
			by[String(rf["name"]).get_slice("_", 0) + "_refuge"] = by.get(String(rf["name"]).get_slice("_", 0) + "_refuge", []) + [snappedf(float(rf["max_span"]), 0.01)]
		for t in by:
			if String(t).ends_with("_refuge"):
				var a: Array = by[t]
				a.sort()
				print("[world] refuges %s (%d): %s" % [t, a.size(), a if a.size() < 40 else [a[0], a[a.size() / 2], a[-1]]])
	var kinds := {}
	for l in w.get_landmarks():
		kinds[l["kind"]] = kinds.get(l["kind"], 0) + 1
	var fly := w.get_landmarks().filter(func(l: Dictionary) -> bool: return l["kind"] == "window").map(func(l: Dictionary) -> String: return l["name"])
	print("[world] landmark kinds ", kinds, " fly-through houses ", fly.size(), " ", fly)
	var sp_count := {}
	for inst in lib.instances:
		var sp: String = TreeLib.Species.keys()[lib.variants[inst["v"]]["species"]]
		sp_count[sp] = sp_count.get(sp, 0) + 1
	print("[world] trees by species ", sp_count)
	# Full-detail triangles in the wood, by species (what the budget pays
	# for within the full-detail radius).
	var wood := {}
	var wood_n := {}
	for inst in lib.instances:
		if not String(inst["chunk"]).begins_with("forest_c"):
			continue
		var spn: String = TreeLib.Species.keys()[lib.variants[inst["v"]]["species"]]
		wood[spn] = wood.get(spn, 0) + int(lib.variants[inst["v"]]["tris"])
		wood_n[spn] = wood_n.get(spn, 0) + 1
	print("[world] wood full tris by species ", wood, " trees ", wood_n)
	var bushes := w.build.footprints.filter(func(f: Dictionary) -> bool: return f["name"] == "bush").size()
	print("[world] bushes ", bushes)
	# Why a cast-only check calls the canyon arch "loose": the 30%-bigger
	# body's START point already overlaps the canyon walls, and a Jolt cast
	# ignores shapes it starts inside.
	var space := w.get_world_3d().direct_space_state
	for o in w.get_openings():
		if o["type"] != "arch":
			continue
		var k := WorldBuild.body_k()
		var r: float = k * float(o["max_span"]) * 1.3
		var n: Vector3 = o["normal"]
		var start: Vector3 = (o["position"] as Vector3) + n * (r + 1.0)
		var sp := SphereShape3D.new()
		sp.radius = r
		var q := PhysicsShapeQueryParameters3D.new()
		q.shape = sp
		q.collision_mask = 1
		q.transform = Transform3D(Basis.IDENTITY, start)
		var overl := space.intersect_shape(q, 4)
		q.motion = -n * (r + 1.0 + float(o["depth"]))
		var cm := space.cast_motion(q)
		var names := []
		for h in overl:
			names.append(String((h["collider"] as Node).name))
		print("[world] %s: 1.3x body r=%.2f m starts overlapping %s; cast_motion from there %s" % [o["name"], r, names, cm])
	get_tree().quit()


## Round-1 verifier's random escape loop (seed 4242, 2.5 km casts). For each
## 2 cm sphere cast that reports "no hit" over 2.5 km, repeat it only as far
## as where the ray along the same line hit (+2 m): if that short cast hits,
## the long one was a query artefact, not a gap.
func _longcast(w: SoaringWorld) -> void:
	var space := w.get_world_3d().direct_space_state
	var R := w.bounds_radius
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	var n := 0
	var long_esc := 0
	var short_esc := 0
	var at_edge := 0
	while n < 4000:
		var a := rng.randf() * TAU
		var rr := sqrt(rng.randf()) * (R - 3.0)
		var x := cos(a) * rr
		var z := sin(a) * rr
		var g := w.ground_height(x, z)
		if g > w.ceiling - 4.0:
			continue
		var y := rng.randf_range(g + 1.0, w.ceiling - 1.0)
		var p := Vector3(x, y, z)
		var d := Vector3(rng.randf_range(-1, 1), rng.randf_range(-0.2, 1.0), rng.randf_range(-1, 1)).normalized()
		var far := p + d * 2500.0
		n += 1
		var rq := PhysicsRayQueryParameters3D.create(p, far)
		rq.collision_mask = 1
		var hit := space.intersect_ray(rq)
		var sp := SphereShape3D.new()
		sp.radius = 0.02
		var q := PhysicsShapeQueryParameters3D.new()
		q.shape = sp
		q.collision_mask = 1
		q.transform = Transform3D(Basis.IDENTITY, p)
		q.motion = far - p
		if space.cast_motion(q)[0] < 1.0 or hit.is_empty():
			continue
		long_esc += 1
		var hp: Vector3 = hit["position"]
		if Vector2(hp.x, hp.z).length() > R - 40.0 or hp.y > w.ceiling - 1.0:
			at_edge += 1
		q.motion = hp + d * 2.0 - p
		if space.cast_motion(q)[0] >= 1.0:
			# Still long (to a far wall): now a 5 m cast right at the wall.
			q.transform = Transform3D(Basis.IDENTITY, hp - d * 3.0)
			q.motion = d * 5.0
			var at_wall := space.cast_motion(q)
			var ov := space.intersect_shape(q, 1)
			short_esc += 1 if at_wall[0] >= 1.0 else 0
			print("[world]   ray-length cast passes: from %s dir %s ray hit %s at %s (%.0f m away); a 5 m cast at the wall gives %s" % [p.snappedf(0.1), d.snappedf(0.01), (hit["collider"] as Node).name, hp.snappedf(0.1), p.distance_to(hp), at_wall])
	print("[world] longcast: %d rays; %d long (2.5 km) sphere casts report no hit (%d of them where the ray hit the arena edge); %d still pass a 5 m cast at the point where the ray was stopped" % [n, long_esc, at_edge, short_esc])


## Where the highest rock over a point is > 5 m above ground_height on the
## cliff and canyon (4 m grid): positions, grouped in 20 m cells, with the
## polyline station (distance along the face line) for context.
func _overhangs(w: SoaringWorld) -> void:
	var space := w.get_world_3d().direct_space_state
	var cells := {}
	var x := -676.0
	while x <= 676.0:
		var z := -676.0
		while z <= 676.0:
			var q := PhysicsRayQueryParameters3D.create(Vector3(x, 299.0, z), Vector3(x, -60.0, z))
			q.collision_mask = 1
			var hit := space.intersect_ray(q)
			if not hit.is_empty():
				var nm := String((hit["collider"] as Node).name)
				if nm == "cliff_body" or nm == "canyon_body":
					var d := (hit["position"] as Vector3).y - w.ground_height(x, z)
					if d > 5.0:
						var key := "%s@(%d,%d)" % [nm, int(floor(x / 20.0)) * 20, int(floor(z / 20.0)) * 20]
						cells[key] = cells.get(key, 0) + 1
			z += 4.0
		x += 4.0
	print("[world] overhang cells (16 m2 samples per 20 m cell): ", cells)
	var bands := []
	for o in w.get_openings():
		if o["type"] == "cliff_hole":
			bands.append((o["position"] as Vector3).snappedf(1.0))
	print("[world] colony burrows around ", bands.slice(0, 3))


## Stand-in calibration: projected area of each variant's mid, far and far
## shadow meshes against the full tree, from four sides (10 deg up) and from
## above (70 deg up), as ratios (1.0 = same silhouette).
func _silhouettes(lib: TreeLib) -> void:
	var dirs: Array[Vector3] = []
	for a in 4:
		dirs.append(Vector3(cos(PI * 0.25 * a), -0.17, sin(PI * 0.25 * a)))
	dirs.append(Vector3(0.34, -0.94, 0.0))
	for v in lib.variants:
		var sp: String = TreeLib.Species.keys()[v["species"]]
		var row := []
		for key in ["lod_arr", "far_arr", "crude_arr"]:
			var side := 0.0
			var top := 0.0
			for di in dirs.size():
				var full := TreeLib.silhouette_area(v["full"][0], dirs[di])
				var sa := TreeLib.silhouette_area(v[key][0], dirs[di])
				if di < 4:
					side += sa / full / 4.0
				else:
					top = sa / full
			row.append("%s side %.2f top %.2f (%d tris)" % [key.substr(0, key.find("_")), side, top, (v[key][0] as PackedVector3Array).size() / 3])
		print("[world] silhouette %-8s full %3d tris | %s" % [sp, v["tris"], " | ".join(row)])


## Every rock/terrain crossing of the vertical at x,z (both directions)
## against ground_height: to explain a ground-contract mismatch.
func _ground_at(w: SoaringWorld, xz: String) -> void:
	var p := xz.split(",")
	var x := float(p[0])
	var z := float(p[1])
	var space := w.get_world_3d().direct_space_state
	for dir in [-1.0, 1.0]:
		var from := Vector3(x, 299.0 if dir < 0.0 else -80.0, z)
		var to := Vector3(x, -80.0 if dir < 0.0 else 299.0, z)
		var ex: Array[RID] = []
		for k in 24:
			var q := PhysicsRayQueryParameters3D.create(from, to)
			q.collision_mask = 1
			q.exclude = ex
			q.hit_back_faces = false
			var hit := space.intersect_ray(q)
			if hit.is_empty():
				break
			var hp: Vector3 = hit["position"]
			print("[world] ground_at %s dir %+d: %s y %.3f normal %s" % [xz, int(dir), (hit["collider"] as Node).name, hp.y, (hit["normal"] as Vector3).snapped(Vector3.ONE * 0.01)])
			from = Vector3(x, hp.y + dir * 0.002, z)
	print("[world] ground_at %s: terrain %.3f ground_height %.3f" % [xz, w.terrain.height_at(x, z), w.ground_height(x, z)])
	# Scan +-1 m around it with the suite's expectation.
	var worst := 0.0
	var worst_s := ""
	for i in 41:
		for j in 41:
			var px := x - 1.0 + i * 0.05
			var pz := z - 1.0 + j * 0.05
			var e := _expect_ground(space, px, pz)
			var gh := w.ground_height(px, pz)
			if absf(e - gh) > worst:
				worst = absf(e - gh)
				worst_s = "%.4f,%.4f expect %.3f got %.3f" % [px, pz, e, gh]
	print("[world] ground_at scan worst %.3f at %s" % [worst, worst_s])
	# The suite's dense pattern in front of every burrow.
	for o in w.get_openings():
		if o["type"] != "cliff_hole":
			continue
		var op: Vector3 = o["position"]
		var on: Vector3 = o["normal"]
		var along := Vector2(-on.z, on.x)
		for d in 12:
			for sa in [-0.8, 0.0, 0.8]:
				var q: Vector2 = Vector2(op.x + on.x * d * 0.25, op.z + on.z * d * 0.25) + along * sa
				var e := _expect_ground(space, q.x, q.y)
				var gh := w.ground_height(q.x, q.y)
				if absf(e - gh) > 0.02:
					print("[world] ground_at MISMATCH %s d %d s %.1f: expect %.3f got %.3f" % [o["name"], d, sa, e, gh])


func _crossings(space: PhysicsDirectSpaceState3D, x: float, z: float, y0: float, y1: float) -> Array:
	var out := []
	var dir := signf(y1 - y0)
	var from := Vector3(x, y0, z)
	var to := Vector3(x, y1, z)
	var ex: Array[RID] = []
	for k in 16:
		var q := PhysicsRayQueryParameters3D.create(from, to)
		q.collision_mask = 1
		q.exclude = ex
		q.hit_back_faces = false
		var hit := space.intersect_ray(q)
		if hit.is_empty():
			break
		var hp: Vector3 = hit["position"]
		var nm := String((hit["collider"] as Node).name)
		if nm.begins_with("terrain_") or nm == "water_body" or nm in ["cliff_body", "canyon_body"]:
			out.append([hp.y, nm.begins_with("terrain_") or nm == "water_body"])
			from = Vector3(x, hp.y + dir * 0.002, z)
		else:
			ex.append(hit["rid"])
	return out


func _expect_ground(space: PhysicsDirectSpaceState3D, x: float, z: float) -> float:
	var down := _crossings(space, x, z, 299.0, -80.0)
	var floor_y := -INF
	for c in down:
		if c[1]:
			floor_y = maxf(floor_y, c[0])
	var lowest := INF
	var up := false
	for c in down:
		if not c[1] and c[0] > floor_y + 0.02 and c[0] < lowest:
			lowest = c[0]
			up = true
	for c in _crossings(space, x, z, floor_y + 0.02, 299.0):
		if not c[1] and c[0] < lowest:
			lowest = c[0]
			up = false
	return lowest if up else floor_y


## Stand-in vertices farthest from any collider (W10's 1-degree rule): the
## worst few with the tree they belong to, in that tree's own frame.
func _standins(w: SoaringWorld, lib: TreeLib) -> void:
	var space := w.get_world_3d().direct_space_state
	var sp := SphereShape3D.new()
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = sp
	q.collision_mask = 1
	var rows: Array = []
	for mi in w.get_node("Visual").get_children():
		if not mi.has_meta(&"stand_in_min_dist"):
			continue
		var m := mi as MeshInstance3D
		var begin: float = m.get_meta(&"stand_in_min_dist") + m.mesh.get_aabb().size.length() * 0.5
		var centre := m.global_transform * m.mesh.get_aabb().get_center()
		var verts: PackedVector3Array = m.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		var seen := {}
		for v0 in verts:
			var v := m.global_transform * v0
			var key := v.snapped(Vector3.ONE * 0.01)
			if seen.has(key):
				continue
			seen[key] = true
			var d_min := begin - v.distance_to(centre)
			var tol := maxf(0.15, d_min * tan(deg_to_rad(1.0)))
			sp.radius = tol
			q.transform = Transform3D(Basis.IDENTITY, v)
			if not space.intersect_shape(q, 1).is_empty():
				continue
			var r := tol
			while r < 8.0:
				r *= 1.15
				sp.radius = r
				if not space.intersect_shape(q, 1).is_empty():
					break
			# The nearest tree.
			var best := -1
			var bd := INF
			for i in lib.instances.size():
				var p: Vector3 = lib.instances[i]["pos"]
				var dd := Vector2(p.x - v.x, p.z - v.z).length()
				if dd < bd:
					bd = dd
					best = i
			var inst: Dictionary = lib.instances[best]
			var loc := lib.instance_xform(inst).affine_inverse() * v
			rows.append([r / tol, "%s %s: %.2f m off (allowed %.2f at %.0f m); tree %s local %s" % [m.name, TreeLib.Species.keys()[lib.variants[inst["v"]]["species"]], r, tol, d_min, best, loc.snapped(Vector3.ONE * 0.01)]])
	rows.sort_custom(func(a: Array, b: Array) -> bool: return a[0] > b[0])
	print("[world] stand-in vertices off: %d" % rows.size())
	var kinds := {}
	for r in rows:
		var nm: String = String(r[1]).get_slice(" ", 0)
		var kind := "far" if nm.begins_with("trees_far") else "mid"
		var spc := String(r[1]).get_slice(" ", 1).trim_suffix(":")
		kinds[kind + "_" + spc] = kinds.get(kind + "_" + spc, 0) + 1
	print("[world] by kind: ", kinds)
	# Per variant, in its own frame: how far each stand-in vertex is from
	# the variant's colliders (capsules exactly, hulls by their nearest
	# point: an upper bound).
	for vi in lib.variants.size():
		var v: Dictionary = lib.variants[vi]
		for key in ["lod_arr", "far_arr"]:
			var worst := 0.0
			var worst_p := Vector3.ZERO
			for p in (v[key][0] as PackedVector3Array):
				var best := INF
				for c in v["colliders"]:
					if c[0] == "cap":
						var a: Vector3 = c[1]
						var b: Vector3 = c[2]
						var ab := b - a
						var t := clampf((p - a).dot(ab) / maxf(ab.length_squared(), 1e-9), 0.0, 1.0)
						best = minf(best, p.distance_to(a + ab * t) - float(c[3]))
					else:
						for hp in (c[1] as PackedVector3Array):
							best = minf(best, p.distance_to(hp))
				if best > worst:
					worst = best
					worst_p = p
			if worst > 0.6:
				print("[world]   variant %d %s %s: worst %.2f m at %s" % [vi, TreeLib.Species.keys()[v["species"]], key, worst, worst_p.snapped(Vector3.ONE * 0.01)])
	for r in rows.slice(0, 12):
		print("[world]   ", r[1])


## The round-1 seeds probe's arena sweep (120 bearings x 4 altitudes, a ray
## and a 2 cm sphere cast from inside to 150 m past the wall). For every
## line where the long cast reports no hit although the ray stopped at the
## wall, fly the same line again in 20 m sphere casts: if one of them hits,
## the "escape" was the long cast skipping the wall, not a gap.
func _seedsweep(w: SoaringWorld) -> void:
	var space := w.get_world_3d().direct_space_state
	var R := w.bounds_radius
	var sp := SphereShape3D.new()
	sp.radius = 0.02
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = sp
	q.collision_mask = 1
	var long_esc := 0
	var real_esc := 0
	for k in 120:
		var a := TAU * k / 120.0
		var dir := Vector3(cos(a), 0, sin(a))
		for y0: float in [2.0, 90.0, 200.0, 297.0]:
			var rs := R - 15.0
			while rs > 0.0 and w.ground_height(dir.x * rs, dir.z * rs) > y0 - 2.0:
				rs -= 15.0
			var y := y0
			if y0 == 2.0:
				y = w.ground_height(dir.x * rs, dir.z * rs) + 2.0
			var p0 := dir * rs + Vector3(0, y, 0)
			var far := dir * (R + 150.0) + Vector3(0, y, 0)
			q.transform = Transform3D(Basis.IDENTITY, p0)
			q.motion = far - p0
			if space.cast_motion(q)[0] < 1.0:
				continue
			long_esc += 1
			var stopped := false
			var from := p0
			while from.distance_to(far) > 0.01:
				var to := from + (far - from).limit_length(20.0)
				q.transform = Transform3D(Basis.IDENTITY, from)
				q.motion = to - from
				if space.cast_motion(q)[0] < 1.0:
					stopped = true
					break
				from = to
			if not stopped:
				real_esc += 1
				print("[world] seedsweep seed %d: REAL escape along bearing %d at %.0f m" % [w.world_seed, k * 3, y0])
	print("[world] seedsweep seed %d: %d long casts report no hit; %d of them get through in 20 m casts" % [w.world_seed, long_esc, real_esc])


## --opening=<name>: fly the rated body through one opening and name what
## stops it (start overlap, or the first collider the cast meets).
func _opening(w: SoaringWorld, oname: String) -> void:
	var space := w.get_world_3d().direct_space_state
	var k := WorldBuild.body_k()
	for o in w.get_openings():
		if o["name"] != oname:
			continue
		var r := k * float(o["max_span"])
		var n: Vector3 = o["normal"]
		var p: Vector3 = o["position"]
		var a := p + n * (r + 1.0)
		var b := p - n * float(o["depth"])
		var sp := SphereShape3D.new()
		sp.radius = r
		var q := PhysicsShapeQueryParameters3D.new()
		q.shape = sp
		q.collision_mask = 1
		q.transform = Transform3D(Basis.IDENTITY, a)
		var over := space.intersect_shape(q, 8).map(func(h: Dictionary) -> String: return String((h["collider"] as Node).name))
		q.motion = b - a
		var f := space.cast_motion(q)
		var info := {}
		if f[1] < 1.0:
			q.transform = Transform3D(Basis.IDENTITY, a + (b - a) * f[1])
			q.motion = Vector3.ZERO
			info = space.get_rest_info(q)
		print("[world] opening %s span %.3f r %.3f at %s normal %s: start overlaps %s; cast safe %.3f unsafe %.3f; stopped by %s at %s" % [
			oname, float(o["max_span"]), r, p, n, over, f[0], f[1],
			(instance_from_id(info["collider_id"]) as Node).name if not info.is_empty() else "-", info.get("point", "-")])


## --arenasweep: the suite's _arena_escapes sweep (2-degree bearings, the
## other-seed altitudes); every line it would count as an escape is printed
## with what the ray, the long 2 cm sphere cast and a 1 m-step march of the
## same sphere meet.
func _arenasweep(w: SoaringWorld) -> void:
	var space := w.get_world_3d().direct_space_state
	var R := w.bounds_radius
	var sp := SphereShape3D.new()
	sp.radius = 0.02
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = sp
	q.collision_mask = 1
	var n := 0
	for deg in range(0, 360, 2):
		var a := deg_to_rad(float(deg))
		var dir := Vector3(cos(a), 0, sin(a))
		for y0: float in [2.0, 60.0, 180.0, 298.0]:
			var y := y0
			var rs := R - 15.0
			while rs > 0.0 and w.ground_height(dir.x * rs, dir.z * rs) > y - 2.0:
				rs -= 15.0
			if y0 == 2.0:
				y = w.ground_height(dir.x * rs, dir.z * rs) + 2.0
			var p0 := dir * rs + Vector3(0, y, 0)
			var far := dir * (R + 150.0) + Vector3(0, y, 0)
			var rq := PhysicsRayQueryParameters3D.create(p0, far)
			rq.collision_mask = 1
			var hit := space.intersect_ray(rq)
			q.transform = Transform3D(Basis.IDENTITY, p0)
			q.motion = far - p0
			var f := space.cast_motion(q)[0]
			var ray_out := hit.is_empty() or Vector2((hit["position"] as Vector3).x, (hit["position"] as Vector3).z).length() > R + 0.6
			if not ray_out and f < 1.0:
				continue
			n += 1
			# March the same sphere in 1 m steps.
			var at := p0
			var stop := INF
			var L := p0.distance_to(far)
			var flown := 0.0
			var stopped_by := "-"
			while flown < L:
				var st := minf(1.0, L - flown)
				q.transform = Transform3D(Basis.IDENTITY, at)
				q.motion = dir * st
				var ff := space.cast_motion(q)
				if ff[0] < 1.0:
					var sp_at := at + dir * st * ff[1]
					stop = Vector2(sp_at.x, sp_at.z).length()
					q.transform = Transform3D(Basis.IDENTITY, sp_at)
					q.motion = Vector3.ZERO
					var info := space.get_rest_info(q)
					stopped_by = (instance_from_id(info["collider_id"]) as Node).name if not info.is_empty() else "?"
					break
				at += dir * st
				flown += st
			print("[world] arena line %d deg y %.1f from r %.0f: ray %s (%s), long cast %.4f, 1 m march stopped at r %.2f by %s" % [
				deg, y, rs, "out" if ray_out else "stops", (hit["collider"] as Node).name if not hit.is_empty() else "-",
				f, stop, stopped_by])
	print("[world] arena sweep: %d suspicious lines" % n)
