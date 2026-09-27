extends TestCase
## Verifier probe, round 3 (experience & requirements lens) for the world.
##
##   tools/gd.sh world_verify --headless res://tests/runner.tscn -- --dir=res://tests/probes/world --suite=r3exp
##
## Angles the builder's suite and rounds 1-2 did not cover:
## - things mounted on walls/trunks/poles/cliffs/mast tops (not on the
##   ground, so W6's footprints never see them): nest boxes, the cliff
##   shelves, and a generic detector of kit clusters that touch neither the
##   ground nor any other object;
## - winding: every closed piece of every kit must be wound outward (the
##   cliff shelves are built with a mirrored basis: inside-out, drawn and
##   collided, their perches inside the box);
## - W6 detector with a lift that really clears deep footings (round 2 lifted
##   1 m, less than the bridge's / lake arch's embedding);
## - the round-1 "escapes" on seeds 3 / 4242 / 90001 replayed as a bird flies
##   (1 m steps), plus fresh extreme seeds (0, 2147483647) end to end;
## - every opening can be lined up from open air (a 35 deg approach cone);
## - API robustness (NaN / huge inputs), perch-query cost at AI scale, and
##   memory/objects across generate/free cycles (restart safety).
## Screenshots of what these find: world_r3exp_shot.tscn -> artifacts/world/verify/r3/r3exp_*.png
## Prints "[world-r3] ..." lines; numbers land in report metrics.

var world: SoaringWorld
var space: PhysicsDirectSpaceState3D
var k_body := 0.16


func before_all() -> void:
	k_body = WorldBuild.body_k()
	world = load("res://scenes/world/world.tscn").instantiate()
	world.with_decoration = false
	add_child(world)
	await wait_physics(2)
	space = world.get_world_3d().direct_space_state


func after_all() -> void:
	if world:
		world.queue_free()


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


func _fits(from: Vector3, to: Vector3, r: float) -> bool:
	return not _overlaps(from, r) and _cast(from, to, r) >= 1.0


# --- mounted things ----------------------------------------------------------

## Every nest box's back board must touch the trunk/pole/wall it hangs on.
## Box geometry from props.gd nest_box(): origin = hole centre - out*0.1 -
## up*0.04; back board outer face at origin - out*0.1; 22 x 30 cm.
func test_nest_boxes_touch_their_mount() -> void:
	var floating: PackedStringArray = []
	var gaps := {}
	for o in world.get_openings():
		if o["type"] != "nest_box":
			continue
		var out: Vector3 = o["normal"]
		var c: Vector3 = o["position"]
		var origin := c - out * 0.1 - Vector3.UP * 0.04
		var right := Vector3.UP.cross(out).normalized()
		# The box collides: a ray from behind hits its back board.
		var own := _ray(origin - out * 0.6, origin, false)
		var min_gap := INF
		for u: float in [-0.07, 0.0, 0.07]:
			for v: float in [-0.1, 0.0, 0.1]:
				var p := origin - out * 0.11 + right * u + Vector3.UP * v
				var h := _ray(p, p - out * 1.0, false)
				var g := 1.01 if h.is_empty() else p.distance_to(h["position"]) + 0.01
				min_gap = minf(min_gap, g)
		gaps[o["name"]] = [snappedf(min_gap, 0.001), c.snappedf(0.1), not own.is_empty()]
		if min_gap > 0.05:
			floating.append("%s at %s: nearest support %.2f m behind the back board" % [o["name"], c.snappedf(0.1), min_gap])
	print("[world-r3] nest box back gaps: ", gaps)
	metric("nest_box_gaps", gaps)
	eq(floating.size(), 0, "every nest box touches its mount (gap <= 5 cm): %s" % "; ".join(floating))


## Round 2 lifted bodies 1 m, less than some footings (poles 1.2 m). Lift
## by 2.5 m and run the builder's own detector: every kind must be caught.
func test_w6_detector_with_a_real_lift() -> void:
	var wt: Node = (load("res://tests/unit/world/world_test.gd") as Script).new()
	wt.set("world", world)
	wt.set("space", space)
	var bodies: Node = world.get_node("Bodies")
	var cases := [["water_tower_body", "water_tower"], ["bridge_body", "bridge"], ["powerline_body", "pole"],
		["lake_arch_body", "lake_arch"], ["mast_body", "mast"]]
	var report := {}
	var missed: PackedStringArray = []
	for c in cases:
		var b := bodies.get_node_or_null(String(c[0])) as Node3D
		if b == null:
			report[c[1]] = "no body"
			missed.append("%s (no body %s)" % [c[1], c[0]])
			continue
		var total := 0
		for fp in world.build.footprints:
			if String(fp["name"]).begins_with(String(c[1])) and not String(fp["name"]).ends_with("_back"):
				total += 1
		# Lift past the deepest embedding of this kind's footprints.
		var embed := 0.0
		for fp in world.build.footprints:
			if String(fp["name"]).begins_with(String(c[1])) and not String(fp["name"]).ends_with("_back"):
				for q in (fp["points"] as PackedVector2Array):
					embed = maxf(embed, world.terrain.height_at(q.x, q.y) - float(fp["base_y"]))
		var lift := maxf(2.5, embed + 0.5)
		b.global_position += Vector3.UP * lift
		await wait_physics(2)
		var after: PackedStringArray = wt.call("_floating_footprints", String(c[1]))[0]
		b.global_position -= Vector3.UP * lift
		await wait_physics(2)
		report[c[1]] = "%d of %d (lift %.2f m, embed %.2f m)" % [after.size(), total, lift, embed]
		if total == 0 or after.size() < total:
			missed.append("%s (%s)" % [c[1], report[c[1]]])
	var back: PackedStringArray = wt.call("_floating_footprints", "")[0]
	wt.free()
	print("[world-r3] W6 detector, lift past embedding: ", report, " restored floating: ", back.size())
	metric("w6_lift_2_5m", report)
	eq(missed.size(), 0, "every footprint of every lifted kind flagged: %s" % ", ".join(missed))
	eq(back.size(), 0, "nothing floats after restoring")


# --- arena on other seeds, as a bird flies ------------------------------------

func _sweep_lines(w: SoaringWorld) -> Array:
	var R := w.bounds_radius
	var out := []
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
			out.append([dir * rs + Vector3(0, y, 0), dir * (R + 150.0) + Vector3(0, y, 0)])
	return out


## Short-step march of a 2 cm sphere (a bird moves < 1 m per tick): the
## distance from the centre where it was stopped, or INF if it got out.
func _march_out(p0: Vector3, p1: Vector3, step: float, R: float) -> float:
	var d := (p1 - p0).normalized()
	var at := p0
	var L := p0.distance_to(p1)
	var flown := 0.0
	while flown < L:
		var s := minf(step, L - flown)
		var f := _cast(at, at + d * s, 0.02)
		if f < 1.0:
			var stop := at + d * s * f
			return Vector2(stop.x, stop.z).length()
		at += d * s
		flown += s
		if Vector2(at.x, at.z).length() > R + 1.0 or at.y > w_ceiling + 1.0:
			return INF
	return INF

var w_ceiling := 300.0


func test_other_seeds_as_a_bird_flies() -> void:
	var summary := {}
	for sd: int in [3, 4242, 90001, 0, 2147483647]:
		var vp := SubViewport.new()
		vp.own_world_3d = true
		vp.size = Vector2i(8, 8)
		vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
		add_child(vp)
		var w: SoaringWorld = load("res://scenes/world/world.tscn").instantiate()
		w.world_seed = sd
		w.with_decoration = false
		vp.add_child(w)
		await wait_physics(2)
		var keep := space
		space = w.get_world_3d().direct_space_state
		w_ceiling = w.ceiling
		var R := w.bounds_radius
		var long_esc := []
		var real_esc := []
		for ln in _sweep_lines(w):
			var p0: Vector3 = ln[0]
			var p1: Vector3 = ln[1]
			var h := _ray(p0, p1)
			var leaks := h.is_empty() or Vector2((h["position"] as Vector3).x, (h["position"] as Vector3).z).length() > R + 0.6
			if not leaks and _cast(p0, p1, 0.02) >= 1.0:
				leaks = true
			if leaks:
				long_esc.append([p0.snappedf(0.1), p1.snappedf(0.1)])
			# Every line (not only the long-cast leaks) in 1 m steps.
			var stop := _march_out(p0, p1, 1.0, R)
			if stop > R + 0.6:
				real_esc.append([p0.snappedf(0.1), p1.snappedf(0.1), stop])
		# Counts the brief demands, on this seed.
		var ops := w.get_openings()
		var types := {}
		var op_fail := []
		for o in ops:
			types[o["type"]] = true
			var r := k_body * float(o["max_span"])
			var n: Vector3 = o["normal"]
			var pp: Vector3 = o["position"]
			if not _fits(pp + n * (r + 1.0), pp - n * float(o["depth"]), r):
				op_fail.append(o["name"])
		var lib: TreeLib = w.build.get_meta(&"tree_lib")
		var houses := 0
		var windows := 0
		for l in w.get_landmarks():
			if l["kind"] == "window":
				windows += 1
		var row := {"gen_ms": snappedf(w.generation_ms, 1.0), "perches": w.get_perches().size(), "openings": ops.size(),
			"types": types.size(), "op_fail": op_fail.slice(0, 6), "trees": lib.instances.size(),
			"thermals": w.get_thermals().size(), "fly_through_houses": windows,
			"long_cast_leaks": long_esc.size(), "short_step_escapes": real_esc.slice(0, 4)}
		summary[str(sd)] = row
		print("[world-r3] seed %d: %s" % [sd, row])
		lt(w.generation_ms, 2000.0, "seed %d generation < 2 s" % sd)
		gt(float(w.get_perches().size()), 399.0, "seed %d >= 400 perches" % sd)
		gt(float(ops.size()), 19.0, "seed %d >= 20 openings" % sd)
		gt(float(lib.instances.size()), 150.0, "seed %d >= 150 trees" % sd)
		gt(float(w.get_thermals().size()), 5.0, "seed %d >= 6 thermals" % sd)
		gt(float(windows), 7.0, "seed %d >= 8 fly-through houses" % sd)
		eq(op_fail.size(), 0, "seed %d every opening flyable by its rated bird" % sd)
		eq(real_esc.size(), 0, "seed %d no escape in 1 m steps" % sd)
		space = keep
		vp.queue_free()
		await wait_frames(2)
	metric("seeds", summary)


# --- openings can be lined up from open air -----------------------------------

## A bird cannot enter a hole it cannot line up with. For each opening, at
## least one straight 5 m run-in within a 35 deg cone of its normal must be
## clear for the rated body (it ends 1 m outside the mouth).
func test_every_opening_can_be_lined_up() -> void:
	var blocked: PackedStringArray = []
	var by_type := {}
	for o in world.get_openings():
		var n: Vector3 = o["normal"]
		var up: Vector3 = o["up"]
		var right := up.cross(n).normalized()
		var r := k_body * float(o["max_span"])
		var mouth: Vector3 = o["position"] + n * (r + 1.0)
		var run := clampf(5.0 + 4.0 * r, 5.0, 60.0)
		var ok := false
		for a: float in [0.0, 20.0, -20.0, 35.0, -35.0]:
			for e: float in [0.0, 20.0, -20.0]:
				var d := n.rotated(up, deg_to_rad(a))
				d = d.rotated(right, deg_to_rad(e)).normalized()
				var start := mouth + d * run
				if not world.is_inside(start):
					continue
				if _fits(start, mouth, r):
					ok = true
					break
			if ok:
				break
		var t: String = o["type"]
		by_type[t] = by_type.get(t, 0) + (0 if ok else 1)
		if not ok:
			blocked.append("%s (%s, span %.2f)" % [o["name"], t, float(o["max_span"])])
	print("[world-r3] openings that cannot be lined up: ", blocked.size(), " ", blocked.slice(0, 20))
	metric("unapproachable_by_type", by_type)
	eq(blocked.size(), 0, "every opening has a clear run-in: %s" % ", ".join(blocked.slice(0, 20)))


# --- robustness and cost ----------------------------------------------------

func test_api_survives_bad_inputs() -> void:
	var bad := [Vector3(NAN, 10, 0), Vector3(0, NAN, 0), Vector3(INF, 0, 0), Vector3(-INF, 5, INF),
		Vector3(1e9, 1e9, -1e9), Vector3(0, -1e6, 0)]
	var t0 := Time.get_ticks_usec()
	var nonfinite := []
	for p: Vector3 in bad:
		var w := world.get_wind(p)
		if not (is_finite(w.x) and is_finite(w.y) and is_finite(w.z)):
			nonfinite.append("wind %s -> %s" % [p, w])
		var g := world.ground_height(p.x, p.z)
		if not is_finite(g):
			nonfinite.append("ground %s -> %s" % [p, g])
		world.is_inside(p)
		world.find_perches(p, 50.0, 1.0)
	var ms := (Time.get_ticks_usec() - t0) / 1000.0
	print("[world-r3] bad inputs: %.1f ms, non-finite: %s" % [ms, nonfinite])
	metric("bad_inputs_ms", ms)
	metric("nonfinite", nonfinite)
	lt(ms, 200.0, "bad inputs return promptly")
	# NaN in, NaN out is acceptable; infinite or huge inputs must not
	# produce non-finite air or ground.
	var from_finite_or_inf := []
	for e in nonfinite:
		if not String(e).contains("nan, ") and not String(e).begins_with("wind (0.0, nan"):
			from_finite_or_inf.append(e)
	eq(from_finite_or_inf.size(), 0, "no NaN/INF comes back for infinite or huge inputs")


func test_find_perches_cost_at_ai_scale() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 33
	var R := world.bounds_radius * 0.8
	var n := 5000
	var found := 0
	var t0 := Time.get_ticks_usec()
	for i in n:
		var p := Vector3(rng.randf_range(-R, R), rng.randf_range(2, 80), rng.randf_range(-R, R))
		found += world.find_perches(p, 80.0, rng.randf_range(0.16, 2.1)).size()
	var us := float(Time.get_ticks_usec() - t0) / n
	print("[world-r3] find_perches r=80: %.1f us/call, %.1f found on average" % [us, float(found) / n])
	metric("find_perches_us", us)
	# 60 NPCs each querying once a second at 72 Hz is < 1 call per frame;
	# even every NPC every frame must stay under ~2 ms.
	lt(us * 60.0, 2000.0, "60 queries per frame fit in 2 ms")


func test_generate_free_cycles_do_not_leak() -> void:
	var samples := []
	for cyc in 3:
		var vp := SubViewport.new()
		vp.own_world_3d = true
		vp.size = Vector2i(8, 8)
		vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
		add_child(vp)
		var w: SoaringWorld = load("res://scenes/world/world.tscn").instantiate()
		w.world_seed = 5
		vp.add_child(w)
		await wait_physics(2)
		vp.queue_free()
		await wait_frames(3)
		await wait_physics(2)
		samples.append({"objects": Performance.get_monitor(Performance.OBJECT_COUNT),
			"resources": Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT),
			"nodes": Performance.get_monitor(Performance.OBJECT_NODE_COUNT),
			"static_mb": snappedf(Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0, 0.1)})
	print("[world-r3] after each generate/free cycle: ", samples)
	metric("cycles", samples)
	var d_obj: float = float(samples[2]["objects"]) - float(samples[1]["objects"])
	var d_mem: float = float(samples[2]["static_mb"]) - float(samples[1]["static_mb"])
	lt(absf(d_obj), 50.0, "object count stable between cycles 2 and 3")
	lt(d_mem, 20.0, "static memory stable between cycles 2 and 3 (MB)")



## rocks.gd:414-417 builds the cliff "shelves up the face for big birds"
## (3.4 x 0.6 x 2.2 m) with Basis(x=(-N.z,0,N.x), UP, z=(N.x,0,N.z)), whose
## determinant is -1: every face is wound inside-out, drawn and collided.
## The perch placed on its top was snapped by perch validation onto the
## inner side of its bottom face. Checks, per shelf:
##  - from outside, level flight into its front and a drop onto its top
##    stop at its faces (a solid shelf);
##  - a bird on its perch is not boxed in (it can leave up or forward);
##  - its back touches the cliff face.
func test_cliff_shelves_are_solid_and_attached() -> void:
	var holes: Array[Vector3] = []
	for o in world.get_openings():
		if o["type"] == "cliff_hole":
			holes.append(o["position"])
	var rows := []
	var inside_out: PackedStringArray = []
	var boxed: PackedStringArray = []
	var detached: PackedStringArray = []
	for p in world.get_perches():
		if p.kind != Perch.Kind.LEDGE or p.district != &"cliff":
			continue
		var near_colony := false
		for h in holes:
			if h.distance_to(p.position) < 40.0:
				near_colony = true
		if near_colony:
			continue
		var N := p.facing
		var T := Vector3(-N.z, 0, N.x)
		# Every LEDGE/cliff perch away from the colony is a shelf (rocks.gd
		# 403-417). Built right, its perch is on the top (centre 0.3 m
		# below); if a face hangs 0.6 m above the perch, the perch was
		# snapped onto the inner side of the bottom (centre 0.3 m above).
		var lid := _ray(p.position + Vector3.UP * 0.05, p.position + Vector3.UP * 1.0, true)
		var snapped_inside := not lid.is_empty() and absf((lid["position"] as Vector3).y - p.position.y - 0.6) < 0.04
		var sc := p.position + Vector3.UP * (0.3 if snapped_inside else -0.3) - N * 0.5
		var r := k_body * p.max_span
		# 1. Drop onto the top from outside (front faces only, as flight's casts).
		var drop := _ray(sc + Vector3.UP * 3.0, sc - Vector3.UP * 3.0, false)
		var drop_y: float = (drop["position"] as Vector3).y if not drop.is_empty() else -INF
		# 2. Level flight into the front face, a sparrow-size body.
		var fa := sc + N * 4.0
		var ff := _cast(fa, sc - N * 0.5, 0.04)
		var front_stop := 4.0 - ff * 4.5   # distance from the centre along N where it stopped
		# 3. A bird on the perch: can it leave up / forward / sideways (3 m)?
		var body := p.position + Vector3.UP * (r + 0.02)
		var exits := 0
		for d: Vector3 in [Vector3.UP, N, T, -T, (N + Vector3.UP).normalized()]:
			if _cast(body, body + d * 3.0, r) >= 1.0:
				exits += 1
		# 4. Its back against the face.
		var touching := 0
		var min_gap := INF
		for u: float in [-1.5, -0.75, 0.0, 0.75, 1.5]:
			for v: float in [-0.2, 0.0, 0.2]:
				var q := sc + T * u + Vector3.UP * v - N * 1.12
				var g := 0.0
				if world.ground_height(q.x, q.z) < q.y - 0.05:
					var h := _ray(q, q - N * 20.0, false)
					g = 20.0 if h.is_empty() else q.distance_to(h["position"]) + 0.02
				min_gap = minf(min_gap, g)
				if g <= 0.05:
					touching += 1
		var row := {"shelf": sc.snappedf(0.1), "perch_inside": snapped_inside, "perch_y": snappedf(p.position.y, 0.01), "top_y": snappedf(sc.y + 0.3, 0.01),
			"drop_stops_y": snappedf(drop_y, 0.01), "front_stop_from_centre": snappedf(front_stop, 0.01),
			"exits_of_5": exits, "back_min_gap": snappedf(min_gap, 0.01), "max_span": p.max_span}
		rows.append(row)
		if absf(drop_y - (sc.y + 0.3)) > 0.03 or front_stop < 1.0:
			inside_out.append(str(sc.snappedf(0.1)))
		if exits == 0:
			boxed.append(str(sc.snappedf(0.1)))
		if touching == 0:
			detached.append("%s (%.2f m)" % [sc.snappedf(0.1), min_gap])
	print("[world-r3] cliff shelves (%d):" % rows.size())
	for rw in rows:
		print("    ", rw)
	metric("cliff_shelves", rows)
	gt(float(rows.size()), 0.0, "shelves found")
	eq(inside_out.size(), 0, "shelves stop a bird from outside (drop onto the top, fly into the front): %s" % ", ".join(inside_out))
	eq(boxed.size(), 0, "a bird on a shelf perch can leave it: %s" % ", ".join(boxed))
	eq(detached.size(), 0, "every shelf's back touches the cliff: %s" % ", ".join(detached))


## Generic detector for things attached to other things (walls, roofs,
## trunks, poles, cliffs), which W6's ground footprints never examine:
## split every full-detail kit mesh into connected pieces (shared vertices)
## and flag any piece whose box (grown by 3 cm) touches neither the ground
## nor another piece of any kit or a tree/terrain collider.
func test_no_detached_pieces_in_kits() -> void:
	var visual: Node = world.get_node("Visual")
	var skip_prefix := ["terrain", "water", "backdrop", "trees_", "clouds", "cloud", "grass", "flowers", "reeds", "soft", "motes", "sky"]
	var pieces := []   # [kit, AABB, tri_count]
	var names := []
	for n in visual.get_children():
		var mi := n as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		var nm := String(mi.name)
		names.append(nm)
		var skip := false
		for sp in skip_prefix:
			if nm.begins_with(sp):
				skip = true
		if skip or mi.mesh.get_surface_count() == 0 or mi.mesh.surface_get_primitive_type(0) != Mesh.PRIMITIVE_TRIANGLES:
			continue
		var arr := mi.mesh.surface_get_arrays(0)
		var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		if arr[Mesh.ARRAY_INDEX] != null and (arr[Mesh.ARRAY_INDEX] as PackedInt32Array).size() > 0:
			continue
		var xf := mi.global_transform
		# Union-find over snapped vertex keys.
		var key_id := {}
		var parent := PackedInt32Array()
		var tri_ids := PackedInt32Array()
		for i in v.size():
			var k := (v[i] * 1000.0).round()
			if not key_id.has(k):
				key_id[k] = parent.size()
				parent.append(parent.size())
			tri_ids.append(key_id[k])
		var find := func(x: int) -> int:
			while parent[x] != x:
				parent[x] = parent[parent[x]]
				x = parent[x]
			return x
		for t in range(0, v.size(), 3):
			var a: int = find.call(tri_ids[t])
			for j in [1, 2]:
				var b: int = find.call(tri_ids[t + j])
				if a != b:
					parent[b] = a
		var boxes := {}
		var counts := {}
		for t in range(0, v.size(), 3):
			var r: int = find.call(tri_ids[t])
			for j in 3:
				var p := xf * v[t + j]
				if boxes.has(r):
					boxes[r] = (boxes[r] as AABB).expand(p)
				else:
					boxes[r] = AABB(p, Vector3.ZERO)
			counts[r] = counts.get(r, 0) + 1
		for r in boxes:
			pieces.append([nm, boxes[r], counts[r]])
	# Spatial hash of grown boxes on a 4 m grid.
	var cell := 4.0
	var grid := {}
	for i in pieces.size():
		var bb: AABB = (pieces[i][1] as AABB).grow(0.03)
		for x in range(floori(bb.position.x / cell), floori(bb.end.x / cell) + 1):
			for z in range(floori(bb.position.z / cell), floori(bb.end.z / cell) + 1):
				var k := Vector2i(x, z)
				if not grid.has(k):
					grid[k] = []
				grid[k].append(i)
	# Grounded pieces; clusters of pieces whose grown boxes touch.
	var grounded := PackedByteArray()
	grounded.resize(pieces.size())
	var up := PackedInt32Array()
	for i in pieces.size():
		up.append(i)
		var bb: AABB = (pieces[i][1] as AABB).grow(0.03)
		var c := bb.get_center()
		for q: Vector2 in [Vector2(c.x, c.z), Vector2(bb.position.x, bb.position.z), Vector2(bb.end.x, bb.end.z),
				Vector2(bb.position.x, bb.end.z), Vector2(bb.end.x, bb.position.z)]:
			if bb.position.y <= maxf(world.terrain.height_at(q.x, q.y), world.ground_height(q.x, q.y)) + 0.03:
				grounded[i] = 1
				break
	var root := func(x: int) -> int:
		while up[x] != x:
			up[x] = up[up[x]]
			x = up[x]
		return x
	for k in grid:
		var ids: Array = grid[k]
		for ii in ids.size():
			for jj in range(ii + 1, ids.size()):
				var i: int = ids[ii]
				var j: int = ids[jj]
				if (pieces[i][1] as AABB).grow(0.03).intersects(pieces[j][1] as AABB):
					var ri: int = root.call(i)
					var rj: int = root.call(j)
					if ri != rj:
						up[rj] = ri
	var clusters := {}
	for i in pieces.size():
		var r: int = root.call(i)
		if not clusters.has(r):
			clusters[r] = []
		clusters[r].append(i)
	var detached := []
	for r in clusters:
		var members: Array = clusters[r]
		var ok := false
		var box := AABB()
		var kits := {}
		for i in members:
			kits[String(pieces[i][0]) + "_body"] = true
			box = (pieces[i][1] as AABB) if box.size == Vector3.ZERO else box.merge(pieces[i][1] as AABB)
			if grounded[i]:
				ok = true
		if ok:
			continue
		# Held by another object's collider (a trunk, a pole's capsule)?
		for i in members:
			var bb: AABB = (pieces[i][1] as AABB).grow(0.05)
			var sh := BoxShape3D.new()
			sh.size = bb.size
			var q3 := PhysicsShapeQueryParameters3D.new()
			q3.shape = sh
			q3.collision_mask = 1
			q3.transform = Transform3D(Basis.IDENTITY, bb.get_center())
			for h in space.intersect_shape(q3, 256):
				if not kits.has(String((h["collider"] as Node).name)):
					ok = true
					break
			if ok:
				break
		if ok:
			continue
		detached.append([kits.keys(), box.get_center().snappedf(0.01), box.size.snappedf(0.01), members.size()])
	print("[world-r3] kit meshes: ", names.size(), " pieces: ", pieces.size(), " clusters: ", clusters.size())
	print("[world-r3] detached pieces (%d):" % detached.size())
	for d in detached.slice(0, 60):
		print("    ", d)
	metric("detached_pieces", detached.slice(0, 100))
	eq(detached.size(), 0, "no cluster of kit pieces floats free of the ground and of every other object")


## Diagnostic: the candidates the detached-piece detector found.
func test_diag_detached_candidates() -> void:
	for c: Vector3 in [Vector3(-160.0, 4.3, 25.0), Vector3(-20.0, 4.3, 35.0)]:
		var g := world.terrain.height_at(c.x, c.z)
		var gh := world.ground_height(c.x, c.z)
		var down := _ray(Vector3(c.x, c.y + 2.2, c.z), Vector3(c.x, g - 1.0, c.z))
		var below := _ray(Vector3(c.x + 0.4, c.y - 1.5, c.z), Vector3(c.x + 0.4, g - 1.0, c.z))
		print("[world-r3] candidate %s: terrain %.3f ground %.3f bottom %.3f; down-ray hit %s on %s; beside-ray %s on %s" % [
			c, g, gh, c.y - 2.0, down.get("position", "-"), (down["collider"] as Node).name if not down.is_empty() else "-",
			below.get("position", "-"), (below["collider"] as Node).name if not below.is_empty() else "-"])
	var m := Vector3(468.0, 105.33, 110.0)
	for dy: float in [-1.7, -2.0, -2.5, -3.0, -4.0]:
		var h := _ray(m + Vector3(0.3, dy + 0.3, 0.3), m + Vector3(0.3, dy - 0.3, 0.3))
		var h2 := _ray(m + Vector3(2, dy, 2), m + Vector3(-2, dy, -2))
		print("[world-r3] mast top probe dy %.1f: vertical %s, diagonal %s" % [dy, h.get("position", "-"), h2.get("position", "-")])
	var down2 := _ray(m + Vector3(0, -1.65, 0), m + Vector3(0, -8, 0))
	print("[world-r3] below the mast-top cluster: ", down2.get("position", "-"), " ", (down2["collider"] as Node).name if not down2.is_empty() else "-")
	check(true, "diagnostic")


## Inside-out pieces anywhere: the signed volume of every connected piece
## of every full-detail kit mesh (divergence theorem with the stored
## normals: > 0 when wound outward). A clearly negative volume is a piece
## drawn and collided inside-out (like the cliff shelves).
func test_no_inside_out_pieces() -> void:
	var visual: Node = world.get_node("Visual")
	var skip_prefix := ["terrain", "water", "backdrop", "trees_far", "clouds", "grass", "flowers", "reeds", "motes"]
	var bad := []
	var checked := 0
	for n in visual.get_children():
		var mi := n as MeshInstance3D
		if mi == null or mi.mesh == null or mi.mesh.get_surface_count() == 0:
			continue
		var nm := String(mi.name)
		var skip := false
		for sp in skip_prefix:
			if nm.begins_with(sp):
				skip = true
		if skip or mi.mesh.surface_get_primitive_type(0) != Mesh.PRIMITIVE_TRIANGLES:
			continue
		var arr := mi.mesh.surface_get_arrays(0)
		var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var nn: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
		if arr[Mesh.ARRAY_INDEX] != null and (arr[Mesh.ARRAY_INDEX] as PackedInt32Array).size() > 0:
			continue
		var key_id := {}
		var parent := PackedInt32Array()
		var ids := PackedInt32Array()
		for i in v.size():
			var k := (v[i] * 1000.0).round()
			if not key_id.has(k):
				key_id[k] = parent.size()
				parent.append(parent.size())
			ids.append(key_id[k])
		var find := func(x: int) -> int:
			while parent[x] != x:
				parent[x] = parent[parent[x]]
				x = parent[x]
			return x
		for t in range(0, v.size(), 3):
			var a: int = find.call(ids[t])
			for j in [1, 2]:
				var b: int = find.call(ids[t + j])
				if a != b:
					parent[b] = a
		var vol := {}
		var box := {}
		var ntri := {}
		for t in range(0, v.size(), 3):
			var r: int = find.call(ids[t])
			var A := v[t]
			var B := v[t + 1]
			var C := v[t + 2]
			var area := (B - A).cross(C - A).length() * 0.5
			var cen := (A + B + C) / 3.0
			# Relative to a local origin per piece for precision.
			if not box.has(r):
				box[r] = AABB(A, Vector3.ZERO)
			box[r] = (box[r] as AABB).expand(A).expand(B).expand(C)
			vol[r] = vol.get(r, 0.0) + (cen - (box[r] as AABB).position).dot(nn[t]) * area / 3.0
			ntri[r] = ntri.get(r, 0) + 1
		for r in vol:
			var bb: AABB = box[r]
			var bv := bb.size.x * bb.size.y * bb.size.z
			checked += 1
			# Only closed-ish solids with real volume: 12+ triangles, box >= 1 litre.
			if int(ntri[r]) >= 12 and bv > 0.001 and float(vol[r]) < -0.3 * bv:
				bad.append([nm, (mi.global_transform * bb.get_center()).snappedf(0.01), bb.size.snappedf(0.01), snappedf(float(vol[r]), 0.001), ntri[r]])
	print("[world-r3] pieces checked: %d, inside-out: %d" % [checked, bad.size()])
	for b in bad.slice(0, 40):
		print("    ", b)
	metric("inside_out_pieces", bad.slice(0, 60))
	eq(bad.size(), 0, "no piece is wound inside-out")


## Diagnostic: the one opening that fails on seed 4242.
func test_diag_seed4242_hedge() -> void:
	var vp := SubViewport.new()
	vp.own_world_3d = true
	vp.size = Vector2i(8, 8)
	vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(vp)
	var w: SoaringWorld = load("res://scenes/world/world.tscn").instantiate()
	w.world_seed = 4242
	w.with_decoration = false
	vp.add_child(w)
	await wait_physics(2)
	var keep := space
	space = w.get_world_3d().direct_space_state
	for o in w.get_openings():
		if o["name"] != "hedge_8a_0_tunnel":
			continue
		var r := k_body * float(o["max_span"])
		var n: Vector3 = o["normal"]
		var pp: Vector3 = o["position"]
		var a := pp + n * (r + 1.0)
		var b := pp - n * float(o["depth"])
		var sp := SphereShape3D.new()
		sp.radius = r
		var q := PhysicsShapeQueryParameters3D.new()
		q.shape = sp
		q.collision_mask = 1
		q.transform = Transform3D(Basis.IDENTITY, a)
		var hits := space.intersect_shape(q, 8)
		var names := hits.map(func(h): return String((h["collider"] as Node).name))
		print("[world-r3] seed 4242 hedge_8a_0_tunnel: span %.2f r %.3f start %s overlaps %s; cast %.3f; ground at start %.2f (start y %.2f); depth %.2f" % [
			float(o["max_span"]), r, a, names, _cast(a, b, r), w.ground_height(a.x, a.z), a.y, float(o["depth"])])
	space = keep
	vp.queue_free()
	await wait_frames(2)
	check(true, "diagnostic")


## Does generating (and freeing) a second world disturb the first one's
## colliders? Rays at the trunks behind the nest boxes, before and after.
func test_second_world_leaves_the_first_intact() -> void:
	var probes := []
	for o in world.get_openings():
		if o["type"] == "nest_box" and String(o["name"]) != "nest_box_13":
			var out: Vector3 = o["normal"]
			var c: Vector3 = o["position"] - out * 0.21 + Vector3.UP * 0.4
			probes.append([c + out * 0.0 - out * 0.0, c - out * 0.6])
	var count := func() -> int:
		var n := 0
		for p in probes:
			if not _ray(p[0], p[1]).is_empty():
				n += 1
		return n
	var trees_body := 0
	for b in world.get_node("Bodies").get_children():
		if String(b.name).begins_with("tree_"):
			trees_body += 1
	var before: int = count.call()
	var vp := SubViewport.new()
	vp.own_world_3d = true
	vp.size = Vector2i(8, 8)
	vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(vp)
	var w: SoaringWorld = load("res://scenes/world/world.tscn").instantiate()
	w.world_seed = 5
	vp.add_child(w)
	await wait_physics(2)
	var during: int = count.call()
	vp.queue_free()
	await wait_frames(3)
	await wait_physics(2)
	var after: int = count.call()
	var trees_after := 0
	for b in world.get_node("Bodies").get_children():
		if String(b.name).begins_with("tree_"):
			trees_after += 1
	print("[world-r3] trunk rays hit: before %d, with a 2nd world %d, after freeing it %d (of %d); tree bodies %d -> %d; World.find is the first: %s" % [
		before, during, after, probes.size(), trees_body, trees_after, World.find(get_tree()) == world])
	metric("trunk_hits", [before, during, after, probes.size()])
	eq(after, before, "the first world's trunk colliders survive a second world's generate/free")
