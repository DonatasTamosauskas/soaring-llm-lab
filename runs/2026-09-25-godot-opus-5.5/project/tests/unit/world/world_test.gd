extends TestCase
## The valley, checked against the physics that was actually built.
##
##   tools/gd.sh world --headless res://tests/runner.tscn -- --suite=world
##
## One world is generated in before_all; every criterion below queries its
## colliders (rays, sphere casts, overlap tests), not the builder's intent.
## W7 (render budgets) and W8 (looks) need a renderer: see
## tests/shots/world_shots.gd and docs/areas/WORLD.md.

var world: SoaringWorld
var space: PhysicsDirectSpaceState3D
var k_body := 0.16


func before_all() -> void:
	k_body = WorldBuild.body_k()
	var t0 := Time.get_ticks_usec()
	world = load("res://scenes/world/world.tscn").instantiate()
	world.with_decoration = true
	add_child(world)
	metric("load_ms", (Time.get_ticks_usec() - t0) / 1000.0)
	await wait_physics(2)
	space = world.get_world_3d().direct_space_state


func after_all() -> void:
	if world:
		world.queue_free()


# --- helpers ------------------------------------------------------------

func _ray(a: Vector3, b: Vector3) -> Dictionary:
	var q := PhysicsRayQueryParameters3D.create(a, b)
	q.collision_mask = 1
	return space.intersect_ray(q)


func _sphere_cast(from: Vector3, to: Vector3, r: float) -> float:
	var sp := SphereShape3D.new()
	sp.radius = r
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = sp
	q.collision_mask = 1
	q.transform = Transform3D(Basis.IDENTITY, from)
	q.motion = to - from
	var res := space.cast_motion(q)
	return res[0] if res.size() > 0 else 1.0


## A body of radius r can fly from `from` to `to`: it starts clear (a cast
## ignores shapes it already overlaps) and the cast is untouched.
func _fits(from: Vector3, to: Vector3, r: float) -> bool:
	return _sphere_hits(from, r).is_empty() and _sphere_cast(from, to, r) >= 1.0


func _sphere_hits(c: Vector3, r: float) -> Array:
	var sp := SphereShape3D.new()
	sp.radius = r
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = sp
	q.collision_mask = 1
	q.transform = Transform3D(Basis.IDENTITY, c)
	return space.intersect_shape(q, 4)


## Bare ground: terrain or the water surface (NOT the water tower).
func _is_terrain(hit: Dictionary) -> bool:
	var col: Object = hit.get("collider")
	if not col is Node:
		return false
	var nm := String((col as Node).name)
	return nm.begins_with("terrain_") or nm == "water_body"


## What ground_height() calls ground: terrain, water, and the rock masses
## standing on the floor (cliff, canyon walls).
func _is_ground(hit: Dictionary) -> bool:
	if _is_terrain(hit):
		return true
	var col: Object = hit.get("collider")
	return col is Node and String((col as Node).name) in ["cliff_body", "canyon_body"]


# --- contract ---------------------------------------------------------------

func test_contract_and_generation_time() -> void:
	check(World.find(get_tree()) == world, "World.find returns the valley")
	check(world.is_generated, "is_generated set")
	var st := world.stats()
	metric("stats", st)
	lt(world.generation_ms, 2000.0, "generation under 2 s")
	metric("generation_ms", world.generation_ms)
	between(world.bounds_radius * 2.0, 1200.0, 1500.0, "arena diameter 1.2-1.5 km")
	near(world.ceiling, 300.0, 1e-3, "ceiling 300 m")
	var spawn := world.get_player_spawn()
	check(world.is_inside(spawn.origin + Vector3.UP * 0.5), "spawn inside the arena")
	gt(spawn.origin.y - world.ground_height(spawn.origin.x, spawn.origin.z), 5.0, "spawn is high enough to launch from")
	var hit := _ray(spawn.origin + Vector3.UP * 0.1, spawn.origin + Vector3.DOWN * 0.2)
	check(not hit.is_empty(), "spawn sits on geometry")
	near((-spawn.basis.z).y, 0.0, 1e-3, "spawn faces level")
	var kinds := {}
	for l in world.get_landmarks():
		kinds[l["kind"]] = true
	for k in ["thermal", "nest", "roost", "town", "forest", "cliff", "opening", "arch", "tower"]:
		check(kinds.has(k), "landmark kind %s present" % k)


## All crossings of ground bodies (terrain, water, cliff, canyon) along the
## vertical at (x, z) between y0 and y1, walking past everything else.
## Trimesh faces only collide from their front, so a downward walk sees
## the up-facing surfaces and an upward walk the down-facing ones.
func _ground_crossings(x: float, z: float, y0: float, y1: float) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
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
		if _is_ground(hit):
			out.append({"y": hp.y, "terrain": _is_terrain(hit)})
			from = Vector3(x, hp.y + dir * 0.002, z)
		else:
			ex.append(hit["rid"])
	return out


func test_ground_height_is_the_solid_ground() -> void:
	# ground_height(x, z) is the first solid-to-air boundary going up from
	# the floor (terrain or water), counting the rock masses standing on it
	# (cliff, canyon walls) and looking past everything free-standing
	# (houses, trees, bridges, arches). Under an overhang (the recess over
	# the swallow band, jittered face rows) the air in front of the face is
	# flyable, so the ground is the floor below. Checked against physics:
	# the downward walk finds every up-facing ground surface, the upward
	# walk from the floor every down-facing one.
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	var t0 := Time.get_ticks_usec()
	for i in 3000:
		world.ground_height(rng.randf_range(-700, 700), rng.randf_range(-700, 700))
	metric("ground_height_us", (Time.get_ticks_usec() - t0) / 3000.0)
	var pts := PackedVector2Array()
	while pts.size() < 6000:
		var q := Vector2(rng.randf_range(-680, 680), rng.randf_range(-680, 680))
		# Inside the arena and below the ray's start (the rim can be higher).
		if q.length() <= world.bounds_radius and world.ground_height(q.x, q.y) < 290.0:
			pts.append(q)
	# Under the village roofs and the forest canopy.
	for c in [WorldLayout.VILLAGE, WorldLayout.FOREST]:
		for i in 400:
			pts.append(c + Vector2.from_angle(rng.randf() * TAU) * sqrt(rng.randf()) * 100.0)
	# Dense over the rock masses, and along their faces (overhangs).
	for poly in [WorldLayout.CLIFF, WorldLayout.CANYON]:
		for i in 1500:
			var a: Vector2 = poly[rng.randi() % (poly.size() - 1)]
			pts.append(a + Vector2(rng.randf_range(-60, 60), rng.randf_range(-60, 60)))
	for o in world.get_openings():
		if o["type"] == "cliff_hole":
			var p: Vector3 = o["position"]
			var n: Vector3 = o["normal"]
			var along := Vector2(-n.z, n.x)
			# From 1 cm in front of the mouth (a column exactly in the face's
			# plane grazes it: degenerate for rays and for ground_height).
			for d in 12:
				for s in [-0.8, 0.0, 0.8]:
					pts.append(Vector2(p.x + n.x * (d * 0.25 + 0.01), p.z + n.z * (d * 0.25 + 0.01)) + along * s)
	var worst := 0.0
	var worst_at := Vector2.ZERO
	var worst_what := ""
	var n := 0
	var on_rock := 0
	var under_overhang := 0
	var layered := 0
	for p in pts:
		var down := _ground_crossings(p.x, p.y, 299.0, -80.0)
		var floor_y := -INF
		for c in down:
			if c["terrain"]:
				floor_y = maxf(floor_y, float(c["y"]))
		if floor_y == -INF:
			continue
		# Lowest crossing above the floor: up-facing (from the downward walk)
		# or down-facing (from the upward walk).
		var lowest := INF
		var lowest_up := false
		var rock_above := 0
		for c in down:
			if not c["terrain"] and float(c["y"]) > floor_y + 0.02:
				rock_above += 1
				if float(c["y"]) < lowest:
					lowest = c["y"]
					lowest_up = true
		if rock_above >= 2:
			layered += 1
		for c in _ground_crossings(p.x, p.y, floor_y + 0.02, 299.0):
			if not c["terrain"] and float(c["y"]) < lowest:
				lowest = c["y"]
				lowest_up = false
		var expect := lowest if lowest_up else floor_y
		if lowest_up:
			on_rock += 1
		elif lowest < INF:
			under_overhang += 1
		n += 1
		var got := world.ground_height(p.x, p.y)
		var err := absf(expect - got)
		if err > worst:
			worst = err
			worst_at = p
			worst_what = "expect %.3f got %.3f floor %.3f" % [expect, got, floor_y]
	gt(float(n), 8500.0, "ground samples")
	gt(float(on_rock), 800.0, "samples standing on the cliff and canyon rock")
	# The cliff has no overhang over open air any more (the cap over the
	# colony stops short of the ledge under it), so the exercised cases are
	# columns with several rock surfaces: a ledge under a cap, a burrow in
	# the rock, the rim above. The overhang rule itself is pinned on
	# synthetic rock in test_rock_ground_contract.
	gt(float(layered), 100.0, "samples with more than one rock surface above the floor (ledge under a cap, burrows)")
	lt(worst, 0.02, "ground_height equals the first solid-to-air boundary (worst at %s: %s)" % [worst_at, worst_what])
	metric("ground_height_worst_err", worst)
	metric("ground_samples", {"total": n, "on_rock": on_rock, "under_overhang": under_overhang, "layered": layered})
	# Every burrow's approach and every perch is in the air above it.
	var bad := 0
	for o in world.get_openings():
		var p: Vector3 = (o["position"] as Vector3) + (o["normal"] as Vector3) * 1.0
		if not world.is_inside(p):
			bad += 1
	for pr in world.get_perches():
		if not world.is_inside(pr.position + Vector3.UP * 0.05):
			bad += 1
	eq(bad, 0, "every opening approach and every perch is inside the arena")


func test_rock_ground_contract() -> void:
	# WorldTerrain.rock_ground_at on hand-made rock: the first solid-to-air
	# boundary going up from the floor. Triangles in Godot winding (A, C, B),
	# as MeshKit.faces stores them.
	var t := WorldTerrain.new(1)
	var up := func(y: float, x0: float, x1: float) -> PackedVector3Array:
		# A horizontal quad facing up over x0..x1, z -1..1.
		var a := Vector3(x0, y, -1)
		var b := Vector3(x1, y, -1)
		var c := Vector3(x1, y, 1)
		var d := Vector3(x0, y, 1)
		return PackedVector3Array([a, b, c, a, c, d])
	var down := func(y: float, x0: float, x1: float) -> PackedVector3Array:
		var a := Vector3(x0, y, -1)
		var b := Vector3(x1, y, -1)
		var c := Vector3(x1, y, 1)
		var d := Vector3(x0, y, 1)
		return PackedVector3Array([a, c, b, a, d, c])
	t.add_rock(up.call(5.0, 0.0, 10.0))      # a ledge 5 m up over x 0..10
	t.add_rock(down.call(8.0, 5.0, 20.0))    # an overhang 8 m up over x 5..20
	t.add_rock(up.call(12.0, 5.0, 20.0))     # its top, 12 m up
	near(t.rock_ground_at(2.0, 0.0, 0.0), 5.0, 1e-4, "rock under open sky: its top is the ground")
	near(t.rock_ground_at(7.0, 0.0, 0.0), 5.0, 1e-4, "a ledge under an overhang: the ledge is the ground")
	eq(t.rock_ground_at(15.0, 0.0, 0.0), -INF, "open air under an overhang: the floor is the ground")
	eq(t.rock_ground_at(25.0, 0.0, 0.0), -INF, "no rock: the floor")
	eq(t.rock_ground_at(7.0, 0.0, 6.0), -INF, "floor above the ledge: the next boundary up is the overhang's underside")


# --- W1 closed arena -------------------------------------------------------

## Bearing sweep: from the outermost airborne point on each bearing at each
## altitude, a ray and a wren-sized sphere fly outward; both must be stopped
## at the boundary, and is_inside must agree. Uses `space` (swappable for
## other seeds' worlds). Returns [escapes, casts, is_inside mismatches, by wall].
func _arena_escapes(w: SoaringWorld, altitudes: Array, step_deg := 1) -> Array:
	var R := w.bounds_radius
	var escapes := 0
	var total := 0
	var inside_mismatch := 0
	var by_wall := 0
	for deg in range(0, 360, step_deg):
		var a := deg_to_rad(float(deg))
		var dir := Vector3(cos(a), 0, sin(a))
		for y0 in altitudes:
			var y: float = y0
			# Start at the outermost airborne point on this bearing.
			var rs := R - 15.0
			while rs > 0.0 and w.ground_height(dir.x * rs, dir.z * rs) > y - 2.0:
				rs -= 15.0
			if y0 == 2.0:
				y = w.ground_height(dir.x * rs, dir.z * rs) + 2.0
			var p0 := dir * rs + Vector3(0, y, 0)
			if not w.is_inside(p0):
				inside_mismatch += 1
			var far := dir * (R + 150.0) + Vector3(0, y, 0)
			total += 1
			var hit := _ray(p0, far)
			if hit.is_empty():
				escapes += 1
				continue
			var hp: Vector3 = hit["position"]
			if Vector2(hp.x, hp.z).length() > R + 0.6:
				escapes += 1
			if (hit["collider"] as Node).name == "Boundary":
				by_wall += 1
			# A wren-sized body cannot slip through either, flown as a bird
			# flies: in short casts (see _sphere_march).
			if _sphere_march(p0, far, 0.02, 10.0) >= 1.0:
				escapes += 1
			# is_inside agrees with the barrier: just before it inside,
			# just past it (into rock or beyond the wall) outside.
			if not w.is_inside(hp - dir * 0.6 + Vector3(0, 0.0, 0)):
				if w.ground_height(hp.x - dir.x * 0.6, hp.z - dir.z * 0.6) < hp.y - 1.0:
					inside_mismatch += 1
			if w.is_inside(dir * (R + 3.0) + Vector3(0, y, 0)):
				inside_mismatch += 1
	return [escapes, total, inside_mismatch, by_wall]


## A small sphere flown from a to b in `step` m casts (a bird moves a few
## metres a tick at most): the fraction of the way it gets. One long cast is
## no substitute: Jolt's cast tolerance grows with the cast's length, and a
## 2 cm sphere cast ~700 m can pass terrain a ray hits (seed 4242, bearing
## 246 deg at 2 m: the ray and a 1 m-step march both stop at r 533 m on
## terrain_1_0, the single cast does not; world_diag --arenasweep).
func _sphere_march(a: Vector3, b: Vector3, r: float, step: float) -> float:
	var L := a.distance_to(b)
	var d := (b - a) / L
	var flown := 0.0
	while flown < L:
		var s := minf(step, L - flown)
		var f := _sphere_cast(a + d * flown, a + d * (flown + s), r)
		if f < 1.0:
			return (flown + s * f) / L
		flown += s
	return 1.0


func test_w1_closed_arena() -> void:
	var R := world.bounds_radius
	var res := _arena_escapes(world, [2.0, 20.0, 60.0, 120.0, 180.0, 240.0, 298.0])
	var escapes: int = res[0]
	var total: int = res[1]
	var inside_mismatch: int = res[2]
	var by_wall: int = res[3]
	eq(escapes, 0, "no bearing/altitude escapes the arena (%d casts)" % total)
	eq(inside_mismatch, 0, "is_inside agrees with the physical barrier")
	metric("bearings_x_altitudes", total)
	metric("blocked_by_wall_fraction", float(by_wall) / total)
	# The sky is closed too.
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var lid_miss := 0
	for i in 200:
		var p := Vector3(rng.randf_range(-600, 600), 250.0, rng.randf_range(-600, 600))
		if Vector2(p.x, p.z).length() > R - 5.0:
			continue
		var hit := _ray(p, p + Vector3(0, 200, 0))
		if hit.is_empty() or (hit["position"] as Vector3).y > world.ceiling + 0.6:
			lid_miss += 1
		if world.is_inside(Vector3(p.x, world.ceiling + 2.0, p.z)):
			lid_miss += 1
	eq(lid_miss, 0, "ceiling blocks and is_inside respects it")


func test_w1_no_gaps_anywhere() -> void:
	# Whole-degree bearings are ~12 m apart at the wall: also fire random 3D
	# rays (any direction, up and down too) and wren-sized spheres from
	# random airborne points; none may get out.
	var R := world.bounds_radius
	var rng := RandomNumberGenerator.new()
	rng.seed = 23
	var escapes := 0
	var n := 0
	var why: PackedStringArray = []
	while n < 4000:
		var p2 := Vector2.from_angle(rng.randf() * TAU) * sqrt(rng.randf()) * (R - 1.0)
		var g := world.ground_height(p2.x, p2.y)
		if g > world.ceiling - 3.0:
			continue
		var p := Vector3(p2.x, rng.randf_range(g + 0.5, world.ceiling - 0.5), p2.y)
		if not _sphere_hits(p, 0.05).is_empty():
			continue
		var d := Vector3(rng.randf_range(-1, 1), rng.randf_range(-0.6, 0.6), rng.randf_range(-1, 1)).normalized()
		var far := p + d * 2000.0
		n += 1
		var hit := _ray(p, far)
		if hit.is_empty():
			escapes += 1
			why.append("ray %s dir %s: no hit" % [p.snappedf(0.1), d.snappedf(0.01)])
			continue
		var hp: Vector3 = hit["position"]
		if Vector2(hp.x, hp.z).length() > R + 0.6 or hp.y > world.ceiling + 0.6:
			escapes += 1
			why.append("ray %s dir %s: hit %s at %s" % [p.snappedf(0.1), d.snappedf(0.01), (hit["collider"] as Node).name, hp.snappedf(0.1)])
		# Where the ray was stopped at the arena's edge (wall, lid, rim), a
		# wren-sized sphere must be stopped there too: a 5 m cast across the
		# point. (Sphere casts hundreds of metres long are unreliable in Jolt:
		# they can report no hit where a short one is stopped.)
		var at_edge := Vector2(hp.x, hp.z).length() > R - 40.0 or hp.y > world.ceiling - 1.0
		if at_edge and _sphere_cast(hp - d * 3.0, hp + d * 2.0, 0.02) >= 1.0:
			escapes += 1
			why.append("sphere %s dir %s passes %s at %s" % [p.snappedf(0.1), d.snappedf(0.01), (hit["collider"] as Node).name, hp.snappedf(0.1)])
	eq(escapes, 0, "no random ray or wren-sized sphere leaves the arena (%d rays): %s" % [n, "; ".join(why.slice(0, 5))])
	# And analytically: every boundary box overlaps its neighbour, so there
	# is no gap of any width between them.
	var body: StaticBody3D = world.get_node("Boundary")
	var boxes: Array = []
	for o in body.get_shape_owners():
		var sh := body.shape_owner_get_shape(o, 0)
		if sh is BoxShape3D and (sh as BoxShape3D).size.y < 100.0:
			continue  # the lid
		boxes.append([body.shape_owner_get_transform(o), (sh as BoxShape3D).size])
	var gaps := 0
	for i in boxes.size():
		var a: Transform3D = boxes[i][0]
		var asz: Vector3 = boxes[i][1]
		var b: Transform3D = boxes[(i + 1) % boxes.size()][0]
		var bsz: Vector3 = boxes[(i + 1) % boxes.size()][1]
		# Both inner-face corners of box i (the inner face is local -Z):
		# one must lie inside box i+1.
		var inside_next := false
		for sx in [-0.5, 0.5]:
			var corner := a * Vector3(asz.x * sx, 0.0, -asz.z * 0.5)
			var lb := b.affine_inverse() * corner
			if absf(lb.x) <= bsz.x * 0.5 and absf(lb.z) <= bsz.z * 0.5 + 1e-3:
				inside_next = true
		if not inside_next:
			gaps += 1
	gt(float(boxes.size()), 90.0, "boundary ring boxes found")
	eq(gaps, 0, "every boundary box overlaps its neighbour")
	metric("random_escape_rays", n)


func test_w1_soft_edge_turns_birds_back() -> void:
	# The invisible wall is not a surprise: over the last EDGE_BAND m the air
	# pushes inward, smoothly, up to EDGE_PUSH at the wall.
	var R := world.bounds_radius
	var band := WindField.EDGE_BAND
	var weak := 0
	var leaked := 0
	var worst_step := 0.0
	for deg in range(0, 360, 10):
		var dir := Vector3(cos(deg_to_rad(float(deg))), 0.0, sin(deg_to_rad(float(deg))))
		for y: float in [60.0, 180.0, 290.0]:
			var inner := world.wind.edge_push(dir * (R - band - 1.0) + Vector3(0, y, 0))
			if inner.length() > 1e-4:
				leaked += 1
			var at_wall := world.wind.edge_push(dir * (R - 0.5) + Vector3(0, y, 0))
			if -at_wall.dot(dir) < WindField.EDGE_PUSH * 0.95:
				weak += 1
			var prev := 0.0
			var r := R - band - 5.0
			while r <= R:
				var pv := world.wind.edge_push(dir * r + Vector3(0, y, 0)).length()
				worst_step = maxf(worst_step, absf(pv - prev) / 0.5)
				prev = pv
				r += 0.5
	eq(leaked, 0, "no push inside the edge band")
	eq(weak, 0, "the push reaches %.1f m/s inward at the wall" % WindField.EDGE_PUSH)
	lt(worst_step, 0.3, "the push ramps in smoothly (m/s per m)")
	# get_wind carries it.
	var p := Vector3(-R + 1.0, 200.0, 0.0)
	gt(world.get_wind(p).x - world.wind.breeze().x, 4.0, "get_wind includes the inward push")
	metric("edge_push_max_step", worst_step)


# --- W2 openings -----------------------------------------------------------

## Every opening of w: (1) the rated bird's body sphere flies from 1 m
## outside to `depth` inside untouched; (2) it is a real hole: rays from
## just inside its outer plane hit solid on all four sides within 1.35x the
## claimed half-size; (3) the rating is tight: a 30% bigger body does not
## fit. Returns [failures, types, min span, max span].
func _opening_failures(w: SoaringWorld) -> Array:
	var types := {}
	var min_span := INF
	var max_span := 0.0
	var fails: PackedStringArray = []
	for o in w.get_openings():
		var t: String = o["type"]
		types[t] = types.get(t, 0) + 1
		var span: float = o["max_span"]
		min_span = minf(min_span, span)
		max_span = maxf(max_span, span)
		var p: Vector3 = o["position"]
		var n: Vector3 = o["normal"]
		var up: Vector3 = o["up"]
		var ow: float = o["width"]
		var oh: float = o["height"]
		var r := k_body * span
		var outside := p + n * (r + 1.0)
		var inside := p - n * float(o["depth"])
		if not _fits(outside, inside, r):
			fails.append("%s: %.2f m bird blocked" % [o["name"], span])
			continue
		var right := up.cross(n).normalized()
		# Probe from just inside the hole's outer plane (nest-box fronts
		# are only 2 cm thick).
		var c := p - n * 0.008
		for d in [[right, ow], [-right, ow], [up, oh], [-up, oh]]:
			var reach: float = float(d[1]) * 0.5 * 1.35 + 0.1
			if _ray(c, c + (d[0] as Vector3) * reach).is_empty():
				fails.append("%s: open on one side" % o["name"])
				break
		if _fits(outside, inside, r * 1.3):
			fails.append("%s: a 30%% bigger bird still fits" % o["name"])
	return [fails, types, min_span, max_span]


func test_w2_openings_are_flyable_real_holes() -> void:
	var ops := world.get_openings()
	gt(ops.size(), 19.0, "at least 20 openings")
	var res := _opening_failures(world)
	var fails: PackedStringArray = res[0]
	var types: Dictionary = res[1]
	var min_span: float = res[2]
	var max_span: float = res[3]
	var names := {}
	for l in world.get_landmarks():
		names[l["name"]] = names.get(l["name"], 0) + 1
	var dup := names.keys().filter(func(k: String) -> bool: return names[k] > 1)
	eq(dup.size(), 0, "landmark names are unique: %s" % [dup])
	metric("rock_arches_measured", world.opening_report)
	metric("opening_failures", Array(fails))
	eq(fails.size(), 0, "every opening passes (%s)" % ", ".join(fails.slice(0, 6)))
	gt(types.size(), 3.0, "at least 4 kinds of opening")
	for need in ["window", "belfry", "barn_door", "barn_slat", "nest_box", "arch", "tower", "cliff_hole"]:
		check(types.has(need), "opening kind %s exists" % need)
	lt(min_span, 0.245, "some openings admit only wren/sparrow-sized birds")
	gt(max_span, 2.1, "some openings admit an eagle")
	metric("openings_by_type", types)
	metric("span_range", [min_span, max_span])
	# Every size of bird has holes of its own, counted two ways:
	#  - tight: the bird fits and one of twice its span does not (round 2's
	#    verifier found 3 for the pigeon and 2 for the crow; vents and broken
	#    boards made it 19 and 18);
	#  - refuge: the bird is the largest that fits, so the next size up (its
	#    predators) cannot follow it in.
	var tight := {}
	var refuge := {}
	for o in ops:
		var ms: float = o["max_span"]
		var tier := -1
		for i in SizeRules.SPECIES.size():
			var span: float = SizeRules.SPECIES[i]["span"]
			if ms >= span:
				tier = i
				if ms < span * 2.0:
					tight[SizeRules.SPECIES[i]["id"]] = tight.get(SizeRules.SPECIES[i]["id"], 0) + 1
		if tier >= 0:
			refuge[SizeRules.SPECIES[tier]["id"]] = refuge.get(SizeRules.SPECIES[tier]["id"], 0) + 1
	metric("openings_tight_for", tight)
	metric("openings_refuge_for", refuge)
	for sp_id in [&"wren", &"sparrow", &"swallow", &"starling", &"pigeon", &"crow", &"gull", &"hawk", &"eagle"]:
		gt(float(tight.get(sp_id, 0)), 2.0 if not sp_id in [&"pigeon", &"crow"] else 9.0, "tight openings for the %s" % sp_id)
		if sp_id != &"eagle":
			gt(float(refuge.get(sp_id, 0)), 2.0, "openings the %s fits and the next size up does not" % sp_id)
	# The belfry is the big birds' way through the village: its measured
	# rating stays an eagle's and more (4.43 m when the bell hangs clear).
	var belfry := 0
	for o in ops:
		if o["type"] == "belfry":
			belfry += 1
			gt(float(o["max_span"]), 4.0, "%s measured for a bird of 4 m span or more" % o["name"])
	eq(belfry, 4, "four belfry arches")


# --- W3 perches --------------------------------------------------------------

## The rated body can fly onto the perch and off it again: a clear 2.5 m
## final approach from at least one of 16 directions (horizontal-ish all
## round, and from above), starting clear, flown both ways (a perch walled
## in by inward-facing faces has a way in but none out).
func _approach_ok(body: Vector3, r: float) -> bool:
	for a in 16:
		var el := 0.3 if a < 12 else 1.4
		var h := Vector3.FORWARD.rotated(Vector3.UP, TAU * a / (12.0 if a < 12 else 4.0))
		var d := (h + Vector3.UP * el).normalized()
		var start := body + d * (2.5 + r)
		if _fits(start, body + d * 0.01, r) and _sphere_cast(body, start, r) >= 1.0:
			return true
	return false


## Support (a ray finds the surface within 3 cm), clearance (the rated body
## fits above) and a clear approach for every perch of w. Returns
## [no support, no clearance, kinds, districts, big, small, no approach].
func _perch_failures(w: SoaringWorld) -> Array:
	var kinds := {}
	var districts := {}
	var no_support := 0
	var no_clear := 0
	var no_approach := 0
	var big := 0
	var small := 0
	for p in w.get_perches():
		var kn: String = Perch.Kind.keys()[p.kind]
		kinds[kn] = kinds.get(kn, 0) + 1
		districts[p.district] = districts.get(p.district, 0) + 1
		var hit := _ray(p.position + Vector3.UP * 0.1, p.position + Vector3.DOWN * 0.15)
		if hit.is_empty() or absf((hit["position"] as Vector3).y - p.position.y) > 0.03:
			no_support += 1
		var r := k_body * p.max_span
		if not _sphere_hits(p.position + Vector3.UP * (r + 0.02), r).is_empty():
			no_clear += 1
		elif not _approach_ok(p.position + Vector3.UP * (r + 0.02), r):
			no_approach += 1
		if p.max_span >= 2.0:
			big += 1
		if p.max_span <= 0.7:
			small += 1
	return [no_support, no_clear, kinds, districts, big, small, no_approach]


func test_w3_perches_on_real_geometry_with_clearance() -> void:
	var perches := world.get_perches()
	gt(perches.size(), 399.0, "at least 400 perches")
	var res := _perch_failures(world)
	var no_support: int = res[0]
	var no_clear: int = res[1]
	var kinds: Dictionary = res[2]
	var districts: Dictionary = res[3]
	var big: int = res[4]
	var small: int = res[5]
	eq(int(res[6]), 0, "every perch can be flown onto by its rated bird")
	eq(no_support, 0, "every perch sits on geometry")
	eq(no_clear, 0, "every perch has room for its largest bird")
	gt(kinds.size(), 5.0, "at least 6 kinds of perch")
	for k in kinds:
		lt(float(kinds[k]) / perches.size(), 0.45, "no perch kind dominates (%s)" % k)
	var rich := 0
	for d in districts:
		if districts[d] >= 5:
			rich += 1
	gt(rich, 7.0, "perches spread over at least 8 districts")
	gt(big, 19.0, "eagle-sized perches exist")
	gt(small, 99.0, "small-bird-only perches exist")
	metric("perch_kinds", kinds)
	metric("perch_districts", districts)
	metric("validation", world.perch_report)


func test_find_perches_matches_brute_force() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 3
	var mism := 0
	for i in 60:
		var pos := Vector3(rng.randf_range(-450, 450), 20, rng.randf_range(-450, 450))
		var rad := rng.randf_range(10, 120)
		var span := rng.randf_range(0.2, 2.0)
		var fast := world.find_perches(pos, rad, span)
		var slow := 0
		for p in world.get_perches():
			if p.is_free() and p.fits(span) and p.position.distance_to(pos) <= rad:
				slow += 1
		if fast.size() != slow:
			mism += 1
	eq(mism, 0, "grid-accelerated find_perches equals brute force")


# --- W1-W3 on other seeds ------------------------------------------------------

func test_w123_hold_on_other_seeds() -> void:
	# The district plan is fixed; the seed varies every detail (jagged rock,
	# tree placement, hedges, perches). The closed arena, the openings and
	# the perches must hold for any seed, not just the one the art was
	# tuned on.
	var main_space := space
	var out := {}
	# 4242: round 3's verifier found a hedge tunnel there whose approach ran
	# into the ground (the mouth now clears the ground in front of it).
	for sd in [2, 3, 4242]:
		var pair := _isolated_world(sd)
		var w: SoaringWorld = pair[1]
		space = w.get_world_3d().direct_space_state
		var arena := _arena_escapes(w, [2.0, 60.0, 180.0, 298.0], 2)
		var ops := _opening_failures(w)
		var per := _perch_failures(w)
		eq(int(arena[0]), 0, "seed %d: no bearing escapes the arena" % sd)
		eq(int(arena[2]), 0, "seed %d: is_inside agrees with the barrier" % sd)
		eq((ops[0] as PackedStringArray).size(), 0, "seed %d: every opening passes (%s)" % [sd, ", ".join((ops[0] as PackedStringArray).slice(0, 5))])
		gt(float(w.get_openings().size()), 19.0, "seed %d: >= 20 openings" % sd)
		eq(int(per[0]), 0, "seed %d: every perch sits on geometry" % sd)
		eq(int(per[1]), 0, "seed %d: every perch has room for its bird" % sd)
		eq(int(per[6]), 0, "seed %d: every perch can be flown onto" % sd)
		gt(float(w.get_perches().size()), 399.0, "seed %d: >= 400 perches" % sd)
		lt(w.generation_ms, 2000.0, "seed %d: generation under 2 s" % sd)
		out[sd] = {"casts": arena[1], "openings": w.get_openings().size(), "perches": w.get_perches().size(),
			"generation_ms": w.generation_ms, "arches": w.opening_report}
		space = main_space
		pair[0].queue_free()
		await wait_frames(1)
	metric("other_seeds", out)


# --- W4 updrafts ---------------------------------------------------------------

func test_w4_thermals_ridge_lift_and_cost() -> void:
	var ths := world.get_thermals()
	gt(ths.size(), 5.0, "at least 6 thermals")
	var core_min := INF
	var core_max := 0.0
	var bad_outside := 0
	for t in [0.0, 37.0, 91.0, 180.0, 333.0]:
		world.set_air_time(t)
		ths = world.get_thermals()
		for i in ths.size():
			var th: Dictionary = ths[i]
			for y: float in [60.0, 120.0, 180.0]:
				var c := world.wind.thermal_center(i, y)
				var w := world.get_wind(c).y
				core_min = minf(core_min, w)
				core_max = maxf(core_max, w)
				# Just outside the bell, in every direction.
				for k in 8:
					var a := TAU * k / 8.0
					var q := c + Vector3(cos(a), 0, sin(a)) * float(th["radius"]) * 1.05
					if world.wind.lift_strength_at(q.x, q.z) > 0.0:
						continue
					if absf(world.get_wind(q).y) >= 0.5:
						bad_outside += 1
	gt(core_min, 3.0, "thermal cores lift >= 3 m/s (min over time/height)")
	lt(core_max, 5.0, "thermal cores lift < 5 m/s")
	eq(bad_outside, 0, "< 0.5 m/s just outside every thermal")
	metric("core_range", [core_min, core_max])
	# Still air away from every source.
	var rng := RandomNumberGenerator.new()
	rng.seed = 21
	var still_bad := 0
	var n_still := 0
	for i in 4000:
		var p := Vector3(rng.randf_range(-650, 650), rng.randf_range(5, 290), rng.randf_range(-650, 650))
		if world.wind.lift_strength_at(p.x, p.z) > 0.0:
			continue
		var near_th := false
		for j in ths.size():
			var c := world.wind.thermal_center(j, p.y)
			if Vector2(p.x - c.x, p.z - c.z).length() < float(ths[j]["radius"]) * 1.01:
				near_th = true
		if near_th:
			continue
		n_still += 1
		if absf(world.get_wind(p).y) >= 0.5:
			still_bad += 1
	eq(still_bad, 0, "no vertical air outside thermals and ridge zones (%d samples)" % n_still)
	# Ridge lift in front of the west cliff at mid height, into the breeze.
	var cl := WorldLayout.CLIFF
	var mid := cl[2].lerp(cl[3], 0.5)
	var ridge_best := 0.0
	for d: float in [12.0, 20.0, 30.0]:
		for y: float in [30.0, 45.0, 60.0]:
			var g := world.ground_height(mid.x + d, mid.y)
			ridge_best = maxf(ridge_best, world.get_wind(Vector3(mid.x + d, g + y, mid.y)).y)
	gt(ridge_best, 2.0, "ridge lift in front of the west cliff > 2 m/s")
	metric("ridge_lift_best", ridge_best)


func test_w4_thermals_carry_every_size() -> void:
	# Each species circles a thermal at 30 degrees of bank just above its
	# stall speed (1.2 x SizeRules min_speed): radius v^2 / (g tan 30).
	# FLIGHT_SPEC FM-19 puts the sink of such a circle at ~0.7-1.0 m/s, so
	# the mean lift round the circle (centred on the live, drifting, leaning
	# column at 120 m) must be >= 1.5 m/s for every species in every thermal
	# at every moment of 10 minutes of air (round 2: the eagle got 1.18 m/s
	# in the forest glade and 1.44 in the hay field).
	var worst := INF
	var worst_at := ""
	var per_species := {}
	var y := 120.0
	for sp in SizeRules.SPECIES:
		var perf := SizeRules.performance(float(sp["mass"]))
		var v := 1.2 * float(perf["min_speed"])
		var rad := v * v / (9.81 * tan(deg_to_rad(30.0)))
		var sp_worst := INF
		for step in 61:
			world.set_air_time(step * 10.0)
			for th in world.get_thermals():
				var c: Vector3 = (th["position"] as Vector3) + (th["lean"] as Vector3) * y
				var lift := 0.0
				for k in 24:
					var a := TAU * k / 24.0
					lift += world.get_wind(Vector3(c.x + cos(a) * rad, y, c.z + sin(a) * rad)).y / 24.0
				sp_worst = minf(sp_worst, lift)
				if lift < worst:
					worst = lift
					worst_at = "%s (circle %.1f m) in %s at %d s" % [sp["id"], rad, th["name"], step * 10]
		per_species[String(sp["id"])] = [snappedf(rad, 0.1), snappedf(sp_worst, 0.01)]
	world.set_air_time(0.0)
	gt(worst, 1.5, "every species gains >= 1.5 m/s circling every thermal (worst %s)" % worst_at)
	metric("thermal_circle_lift_worst", per_species)


func test_w4_wind_is_smooth() -> void:
	world.set_air_time(12.0)
	var worst := 0.0
	var ths := world.get_thermals()
	for i in ths.size():
		var c := world.wind.thermal_center(i, 100.0)
		var R: float = ths[i]["radius"]
		for axis in [Vector3(1, 0, 0), Vector3(0, 0, 1), Vector3(0.7, 0, 0.7).normalized()]:
			var prev := world.get_wind(c - axis * R * 1.4).y
			var s := -R * 1.4 + 0.5
			while s <= R * 1.4:
				var w := world.get_wind(c + axis * s).y
				worst = maxf(worst, absf(w - prev) / 0.5)
				prev = w
				s += 0.5
		# Vertically through the core (ground ramp and top fade).
		var prev_v := world.get_wind(world.wind.thermal_center(i, 1.0)).y
		for y in range(2, 300):
			var w := world.get_wind(world.wind.thermal_center(i, float(y))).y
			worst = maxf(worst, absf(w - prev_v))
			prev_v = w
	# Across the cliff's ridge-lift band.
	var cl := WorldLayout.CLIFF
	var mid := cl[2].lerp(cl[3], 0.5)
	for y: float in [20.0, 40.0, 60.0, 80.0]:
		var prev := world.get_wind(Vector3(mid.x - 20.0, y, mid.y)).y
		for k in 400:
			var x := mid.x - 20.0 + k * 0.5
			var w := world.get_wind(Vector3(x, y, mid.y)).y
			worst = maxf(worst, absf(w - prev) / 0.5)
			prev = w
	lt(worst, 0.6, "wind gradient bounded through thermals and the cliff (m/s per m)")
	metric("max_gradient", worst)
	# Everywhere in the arena: random points, random 0.25 m steps, three
	# times (lift zones and their band edges on steep slopes, the soft edge,
	# the breeze's height ramp, thermal walls).
	var rng := RandomNumberGenerator.new()
	rng.seed = 99
	var worst_any := 0.0
	var worst_at := Vector3.ZERO
	var n := 0
	for t: float in [0.0, 55.0, 140.0]:
		world.set_air_time(t)
		for i in 40000:
			var q := Vector3(rng.randf_range(-680, 680), rng.randf_range(0.0, 300.0), rng.randf_range(-680, 680))
			if not world.is_inside(q):
				continue
			n += 1
			var d := Vector3(rng.randf_range(-1, 1), rng.randf_range(-1, 1), rng.randf_range(-1, 1)).normalized() * 0.25
			var g := (world.get_wind(q + d) - world.get_wind(q)).length() / 0.25
			if g > worst_any:
				worst_any = g
				worst_at = q
	lt(worst_any, 0.6, "wind gradient bounded everywhere in the arena (worst at %s, %d samples)" % [worst_at.snappedf(1.0), n])
	metric("max_gradient_arena", worst_any)
	# In time: one 72 Hz tick changes the air by only a little.
	var p := world.wind.thermal_center(2, 120.0)
	world.set_air_time(40.0)
	var w0 := world.get_wind(p)
	world.set_air_time(40.0 + 1.0 / 72.0)
	lt((world.get_wind(p) - w0).length(), 0.05, "wind changes smoothly in time")


func test_w4_get_wind_cost() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var pts := PackedVector3Array()
	for i in 100000:
		pts.append(Vector3(rng.randf_range(-680, 680), rng.randf_range(0, 300), rng.randf_range(-680, 680)))
	var acc := Vector3.ZERO
	var t0 := Time.get_ticks_usec()
	for p in pts:
		acc += world.get_wind(p)
	var us := (Time.get_ticks_usec() - t0) / 100000.0
	lt(us, 5.0, "get_wind mean cost < 5 us (uniform)")
	# Worst case: only positions inside thermal columns or lift bands.
	var hot := PackedVector3Array()
	var ths := world.get_thermals()
	while hot.size() < 100000:
		var i := rng.randi() % ths.size()
		var y := rng.randf_range(10, 280)
		var c := world.wind.thermal_center(i, y)
		hot.append(c + Vector3(rng.randf_range(-40, 40), 0, rng.randf_range(-40, 40)))
		var cl := WorldLayout.CLIFF[rng.randi() % WorldLayout.CLIFF.size()]
		hot.append(Vector3(cl.x + rng.randf_range(-10, 90), rng.randf_range(5, 90), cl.y + rng.randf_range(-20, 20)))
	t0 = Time.get_ticks_usec()
	for p in hot:
		acc += world.get_wind(p)
	var us_hot := (Time.get_ticks_usec() - t0) / float(hot.size())
	lt(us_hot, 5.0, "get_wind mean cost < 5 us (inside thermals/ridges)")
	metric("wind_us", us)
	metric("wind_us_hot", us_hot)
	finite(acc, "wind sum")


func test_w4_every_thermal_has_a_visible_cue() -> void:
	check(world.motes != null and world.motes.visible, "mote cue exists")
	var per := {}
	for t in world.motes.instance_thermal:
		per[t] = per.get(t, 0) + 1
	var ths := world.get_thermals()
	for i in ths.size():
		gt(float(per.get(i, 0)), 99.0, "thermal %d has >= 100 motes" % i)
	eq(world.motes.multimesh.instance_count, world.motes.instance_thermal.size(), "one draw call carries them all")
	# The shader places each thermal's motes around its LIVE column (the
	# centres are pushed every frame): they must match get_thermals().
	world.set_air_time(77.0)
	await wait_frames(2)
	ths = world.get_thermals()
	var centers: PackedVector4Array = (world.motes.material_override as ShaderMaterial).get_shader_parameter(&"centers")
	var off := 0.0
	for i in ths.size():
		var p: Vector3 = ths[i]["position"]
		off = maxf(off, Vector2(centers[i].x - p.x, centers[i].z - p.z).length() + absf(centers[i].w - float(ths[i]["radius"])))
	# (Tolerance: one physics tick of drift between the push and this read.)
	lt(off, 0.05, "mote columns follow the live thermal centres (max offset %.3f m)" % off)
	# Ridge motes stand on real ridge lift, in every lift zone.
	var zones := {"cliff": 0, "canyon": 0, "west_slopes": 0}
	var off_lift := 0
	for o in world.motes.ridge_origins:
		if world.wind.lift_strength_at(o.x, o.z) < 0.5:
			off_lift += 1
		var q := Vector2(o.x, o.z)
		if WorldLayout.polyline_distance(q, WorldLayout.CLIFF) < 90.0:
			zones["cliff"] += 1
		elif WorldLayout.polyline_distance(q, WorldLayout.CANYON) < 140.0:
			zones["canyon"] += 1
		else:
			zones["west_slopes"] += 1
	eq(world.motes.ridge_origins.size(), world.motes.instance_thermal.count(-1), "every ridge mote has an origin")
	eq(off_lift, 0, "ridge motes rise only where there is ridge lift")
	for z in zones:
		gt(float(zones[z]), 99.0, "lift zone %s shows >= 100 motes" % z)
	metric("ridge_motes", zones)


# --- W5 vastness and density ------------------------------------------------------

func test_w5_vast_open_space_and_dense_features() -> void:
	# Open: a 150 m disc around the meadow centre holds only ground.
	var c := WorldLayout.MEADOW
	var obstructed := 0
	var n := 0
	var x := -150.0
	while x <= 150.0:
		var z := -150.0
		while z <= 150.0:
			if Vector2(x, z).length() <= 150.0:
				var p := Vector3(c.x + x, 0, c.y + z)
				var hit := _ray(Vector3(p.x, 290, p.z), Vector3(p.x, -40, p.z))
				n += 1
				if hit.is_empty() or not _is_terrain(hit):
					obstructed += 1
			z += 10.0
		x += 10.0
	eq(obstructed, 0, "nothing but ground within 150 m of the meadow centre (%d rays)" % n)
	# Dense: 95% of the inner valley within 120 m of a feature.
	var feats := world.build.features
	var covered := 0
	var total := 0
	var cell := 10.0
	var gx := -WorldLayout.INNER_R
	while gx <= WorldLayout.INNER_R:
		var gz := -WorldLayout.INNER_R
		while gz <= WorldLayout.INNER_R:
			if Vector2(gx, gz).length() <= WorldLayout.INNER_R:
				total += 1
				for f in feats:
					if Vector2(f.x - gx, f.y - gz).length() - f.z <= 120.0:
						covered += 1
						break
			gz += cell
		gx += cell
	var frac := float(covered) / total
	gt(frac, 0.95, "inner valley within 120 m of a feature")
	metric("density_coverage", frac)
	# The feature list is honest: sampled features have solid geometry there.
	var rng := RandomNumberGenerator.new()
	rng.seed = 13
	var real := 0
	var sampled := 0
	var unbacked := {}
	for i in 400:
		var f := feats[rng.randi() % feats.size()]
		var g := world.terrain.height_at(f.x, f.y)
		var r := clampf(f.z, 1.0, 8.0)
		sampled += 1
		# Rays straight down at the feature and around it: the first thing
		# hit must be something other than bare ground or water.
		var found := false
		for o in [Vector2.ZERO, Vector2(0.3, 0), Vector2(-0.3, 0), Vector2(0, 0.3), Vector2(0, -0.3),
				Vector2(0.6, 0), Vector2(-0.6, 0), Vector2(0, 0.6), Vector2(0, -0.6)]:
			var q: Vector2 = Vector2(f.x, f.y) + o * r
			var hit := _ray(Vector3(q.x, g + 80.0, q.y), Vector3(q.x, g - 5.0, q.y))
			if not hit.is_empty() and not _is_terrain(hit):
				found = true
				break
		if found:
			real += 1
		else:
			var kind: String = world.build.feature_kinds[feats.find(f)]
			unbacked[kind] = unbacked.get(kind, 0) + 1
	metric("unbacked_features", unbacked)
	gt(float(real) / sampled, 0.98, "sampled features are backed by solid geometry")
	metric("feature_backing", float(real) / sampled)


# --- W6 grounded ------------------------------------------------------------------

## RIDs of the bare-ground bodies (terrain chunks, water surface).
func _ground_rids() -> Array[RID]:
	var out: Array[RID] = []
	for b in world.get_node("Bodies").get_children():
		var nm := String(b.name)
		if nm.begins_with("terrain_") or nm == "water_body":
			out.append((b as CollisionObject3D).get_rid())
	return out


## Per 1 m cell, how far the lowest drawn vertex of a mesh stands above the
## terrain (negative: sunk into it). The drawn geometry, not the colliders:
## a capsule's rounded end reaches below the rod it stands for.
func _vertex_clearance(mi: MeshInstance3D) -> Dictionary:
	var out := {}
	var verts: PackedVector3Array = mi.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var xf := mi.global_transform
	for t in verts.size() / 3:
		# Vertices, and points along long edges (a fallen log's underside
		# has vertices only at its two ends).
		for e in 3:
			var a := xf * verts[t * 3 + e]
			var b := xf * verts[t * 3 + (e + 1) % 3]
			var n := maxi(1, int(a.distance_to(b) / 0.8))
			for k in n:
				var v := a.lerp(b, float(k) / n)
				var key := Vector2i(floori(v.x), floori(v.z))
				out[key] = minf(float(out.get(key, INF)), v.y - world.terrain.height_at(v.x, v.z))
	return out


## Footprints whose object does not reach the ground, measured two ways on
## the BUILT geometry (declared bases prove nothing: they are computed from
## the same terrain they would be compared with):
##  - rays: eight horizontal rays 10 cm above the local ground cross each
##    footprint point from outside; only the owner's own collider counts
##    (a neighbour's bush must not hold up a lifted tree);
##  - vertices: some drawn vertex of the owner within reach of the point
##    must touch or sink into the ground (colliders can reach lower than
##    what is drawn, e.g. a rod's capsule end).
## A small thing must pass at every point, a big one at most points (a ray
## through a big footprint's centre may pass between its walls).
## Returns [floating descriptions, checked, kinds, flagged footprint indices].
func _floating_footprints(only := "") -> Array:
	var ex := _ground_rids()
	var floating: PackedStringArray = []
	var flagged := {}
	var checked := 0
	var kinds := {}
	var clear_cache := {}
	var visual: Node = world.get_node("Visual")
	var lib: TreeLib = world.build.get_meta(&"tree_lib")
	for fi in world.build.footprints.size():
		var fp: Dictionary = world.build.footprints[fi]
		var nm: String = fp["name"]
		# Rock-mass back feet run deep under the mountains (not visible).
		if nm.ends_with("_back") or (only != "" and not nm.begins_with(only)):
			continue
		var small := nm in ["tree", "fence_post", "log"] or nm.begins_with("pole") or nm.begins_with("bale")
		var reach: float = fp.get("reach", -1.0)
		if reach < 0.0:
			reach = 1.2 if small else 3.0
		var pts: PackedVector2Array = fp["points"]
		var owner: Variant = fp.get("owner", "")
		# Drawn-geometry source: the owner kit's mesh, or a tree's own foot.
		var clear: Dictionary = {}
		var tree_foot := INF
		if owner is String and owner != "":
			if not clear_cache.has(owner):
				var mi := visual.get_node_or_null(NodePath(String(owner))) as MeshInstance3D
				clear_cache[owner] = _vertex_clearance(mi) if mi else {}
			clear = clear_cache[owner]
		elif owner is StaticBody3D:
			var b := owner as StaticBody3D
			var inst: Dictionary = lib.instances[int(String(b.name).trim_prefix("tree_"))]
			var v: Dictionary = lib.variants[inst["v"]]
			tree_foot = b.global_position.y + float(v["foot_y"]) * float(inst["s"])
		var hits := 0
		var touch := 0
		for q in pts:
			var gq := world.terrain.height_at(q.x, q.y)
			var c := Vector3(q.x, gq + 0.1, q.y)
			for k in 8:
				var d := Vector3(cos(TAU * k / 8.0), 0, sin(TAU * k / 8.0)) * reach
				var rq := PhysicsRayQueryParameters3D.create(c + d, c - d)
				rq.collision_mask = 1
				rq.exclude = ex
				var h := space.intersect_ray(rq)
				if h.is_empty():
					continue
				var col: Node = h["collider"]
				if owner is Node and col != owner:
					continue
				if owner is String and owner != "" and String(col.name) != String(owner) + "_body":
					continue
				hits += 1
				break
			if tree_foot < INF:
				if tree_foot - gq <= 0.05:
					touch += 1
			else:
				var lowest := INF
				var r := ceili(reach)
				for dz in range(-r, r + 1):
					for dx in range(-r, r + 1):
						lowest = minf(lowest, float(clear.get(Vector2i(floori(q.x) + dx, floori(q.y) + dz), INF)))
				if lowest <= 0.05:
					touch += 1
		checked += 1
		var kind := nm.rstrip("0123456789_ab") if nm.begins_with("hedge") else nm.rstrip("0123456789_")
		kinds[kind] = kinds.get(kind, 0) + 1
		var need := pts.size() if pts.size() <= 2 else ceili(pts.size() * 0.6)
		if hits < need or touch < need:
			floating.append("%s@(%.0f,%.0f) rays %d/%d drawn %d/%d" % [nm, pts[0].x, pts[0].y, hits, pts.size(), touch, pts.size()])
			flagged[fi] = true
	return [floating, checked, kinds, flagged]


func test_w6_nothing_floats() -> void:
	var res := _floating_footprints()
	var floating: PackedStringArray = res[0]
	var checked: int = res[1]
	var kinds: Dictionary = res[2]
	eq(floating.size(), 0, "every footprint has its own solid and drawn geometry at the ground: %s" % ", ".join(floating.slice(0, 8)))
	gt(float(checked), 1500.0, "footprints cover trees, houses, poles, rocks, props")
	metric("footprints_checked", checked)
	metric("footprint_kinds", kinds)
	# Every footprint names the object it belongs to (so only that object's
	# geometry can ground it).
	var ownerless: PackedStringArray = []
	for fp in world.build.footprints:
		var owner: Variant = fp.get("owner", "")
		if not (owner is Node or (owner is String and owner != "")):
			ownerless.append(fp["name"])
	eq(ownerless.size(), 0, "every footprint has an owner: %s" % ", ".join(ownerless.slice(0, 8)))
	# Declared bases agree with the terrain (builders' bookkeeping).
	var buried: PackedStringArray = []
	var declared_high: PackedStringArray = []
	for fp in world.build.footprints:
		var base: float = fp["base_y"]
		for q in (fp["points"] as PackedVector2Array):
			var g := world.terrain.height_at(q.x, q.y)
			if base > g + 0.05:
				declared_high.append("%s (%.2f m up)" % [fp["name"], base - g])
			if base < g - float(fp["max_embed"]) - 0.01:
				buried.append("%s (%.2f m)" % [fp["name"], g - base])
	eq(declared_high.size(), 0, "no footprint declared above the ground: %s" % ", ".join(declared_high.slice(0, 6)))
	eq(buried.size(), 0, "no footprint sunk deeper than its allowance: %s" % ", ".join(buried.slice(0, 6)))
	# Loose things resting on the ground (bushes, logs, boulders, rubble,
	# the jetty) whether or not a builder registered them: in
	# every 1 m cell holding a downward face 0-60 cm above the ground, some
	# vertex of that mesh must touch (or sink into) the ground within a cell.
	var visual: Node = world.get_node("Visual")
	var floaters: PackedStringArray = []
	var cells_checked := 0
	for mi in visual.get_children():
		var m := mi as MeshInstance3D
		if m == null or m.visibility_range_begin > 0.0:
			continue
		var mname := String(m.name)
		# Kits of loose props only. Buildings carry raised parts on plinths
		# and walls (room floors, barn door leaves resting on the plinth)
		# that this vertex test cannot tell from floating; their grounding
		# is the footprint test above (bales and fences included).
		if not (mname.begins_with("forest_floor") or mname.begins_with("boulders") or mname.begins_with("ruin")
				or mname.begins_with("props")):
			continue
		var verts: PackedVector3Array = m.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		var xf := m.global_transform
		var cell_min := {}
		var cell_down := {}
		for t in verts.size() / 3:
			var a := xf * verts[t * 3]
			var b := xf * verts[t * 3 + 1]
			var c := xf * verts[t * 3 + 2]
			for v in [a, b, c]:
				var key := Vector2i(floori(v.x), floori(v.z))
				cell_min[key] = minf(float(cell_min.get(key, INF)), v.y - world.ground_height(v.x, v.z))
			var nrm := (c - a).cross(b - a)
			if nrm.length() > 1e-8 and nrm.normalized().y < -0.7:
				var cen := (a + b + c) / 3.0
				var gg := cen.y - world.ground_height(cen.x, cen.z)
				if gg > 0.0 and gg < 0.6:
					cell_down[Vector2i(floori(cen.x), floori(cen.z))] = true
		for key in cell_down:
			cells_checked += 1
			var mn: float = cell_min.get(key, INF)
			for dx in [-1, 0, 1]:
				for dz in [-1, 0, 1]:
					mn = minf(mn, float(cell_min.get(key + Vector2i(dx, dz), INF)))
			if mn > 0.03 and mn < 0.8:
				floaters.append("%s@(%d,%d) gap %.2f" % [mname, key.x, key.y, mn])
	eq(floaters.size(), 0, "loose ground props touch the ground: %s" % ", ".join(floaters.slice(0, 8)))
	metric("prop_cells_checked", cells_checked)
	# Crowns on hollow trunks sit on the trunk.
	var lib: TreeLib = world.build.get_meta(&"tree_lib")
	var loose := 0
	for inst in lib.instances:
		if inst["mounted"]:
			var p: Vector3 = inst["pos"]
			if _ray(p + Vector3.UP * 0.5, p + Vector3.DOWN * 2.5).is_empty():
				loose += 1
	eq(loose, 0, "crowns on hollow trunks sit on the trunk")
	gt(float(lib.instances.size()), 150.0, ">= 150 trees")
	metric("trees", lib.instances.size())


func test_w6_detector_catches_floating() -> void:
	# The grounding test must be able to fail, for EVERY kind of grounded
	# object: lift each owner (a kit's body and its drawn mesh, or a tree's
	# body) by its deepest embedding + 0.3 m, so every point of it floats at
	# least 30 cm, and every one of its footprints must be flagged; then put
	# everything back and nothing may be flagged. (Round 2's version lifted
	# only houses and trees by 1 m and missed a lifted water tower, whose
	# leg capsules reach below the drawn legs.)
	var visual: Node = world.get_node("Visual")
	var lift := {}
	var fps_of := {}
	var trees_taken := 0
	for fi in world.build.footprints.size():
		var fp: Dictionary = world.build.footprints[fi]
		if String(fp["name"]).ends_with("_back"):
			continue
		var owner: Variant = fp["owner"]
		if owner is StaticBody3D:
			# Every 25th tree (60-odd), the rest stay put.
			if not fps_of.has(owner):
				if trees_taken % 25 != 0:
					trees_taken += 1
					continue
				trees_taken += 1
		var embed := 0.0
		for q in (fp["points"] as PackedVector2Array):
			embed = maxf(embed, world.terrain.height_at(q.x, q.y) - float(fp["base_y"]))
		lift[owner] = maxf(float(lift.get(owner, 0.0)), embed + 0.3)
		if not fps_of.has(owner):
			fps_of[owner] = []
		fps_of[owner].append(fi)
	var moved: Array = []
	for owner in lift:
		var up := Vector3.UP * float(lift[owner])
		if owner is Node3D:
			moved.append([owner, up])
		else:
			var body := world.get_node("Bodies").get_node_or_null(NodePath(String(owner) + "_body")) as Node3D
			var mesh := visual.get_node_or_null(NodePath(String(owner))) as Node3D
			for n in [body, mesh]:
				if n:
					moved.append([n, up])
	for m in moved:
		(m[0] as Node3D).global_position += m[1]
	await wait_physics(2)
	var flagged: Dictionary = _floating_footprints()[3]
	for m in moved:
		(m[0] as Node3D).global_position -= m[1]
	await wait_physics(2)
	var missed: PackedStringArray = []
	var caught := {}
	var total := 0
	for owner in fps_of:
		for fi in fps_of[owner]:
			var nm: String = world.build.footprints[fi]["name"]
			var kind := nm.rstrip("0123456789_ab") if nm.begins_with("hedge") else nm.rstrip("0123456789_")
			total += 1
			if flagged.has(fi):
				caught[kind] = caught.get(kind, 0) + 1
			else:
				missed.append(nm)
	eq(missed.size(), 0, "every lifted object is caught (%d footprints of %d owners): missed %s" % [total, fps_of.size(), ", ".join(missed.slice(0, 8))])
	gt(float(caught.size()), 15.0, "lifted kinds include houses, barn, church, water tower, poles, mast, bridge, hedges, bales, fences, rock, trees")
	eq((_floating_footprints()[0] as PackedStringArray).size(), 0, "and the restored world is grounded again")
	metric("mutation_caught", caught)


# --- pieces: winding and attachment ------------------------------------------------

## Full-detail kit meshes split into connected pieces (triangles sharing a
## vertex, keyed to the millimetre), in world space: a box, a pole, a batten,
## a whole rock face. Cached: the geometry does not change between tests.
var _pieces_cache: Array = []
const PIECE_SKIP := ["terrain", "water", "backdrop", "trees_", "cloud", "grass", "flowers", "reeds", "motes", "sky"]


func _kit_pieces() -> Array:
	if not _pieces_cache.is_empty():
		return _pieces_cache
	for n in world.get_node("Visual").get_children():
		var mi := n as MeshInstance3D
		if mi == null or mi.mesh == null or mi.mesh.get_surface_count() == 0 or mi.has_meta(&"shadow_only") \
				or mi.visibility_range_begin > 0.0:
			continue
		var nm := String(mi.name)
		var skip := false
		for sp in PIECE_SKIP:
			if nm.begins_with(sp):
				skip = true
		if not skip:
			var verts: PackedVector3Array = mi.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
			_pieces_cache.append_array(_pieces_of(nm, mi.global_transform * verts))
	return _pieces_cache


## Connected pieces of a triangle soup in Godot winding (each triangle stored
## clockwise from outside, A C B): [{kit, box, tris, vol, pts}], vol being
## the divergence-theorem volume, positive when the piece is wound outward
## (exact for a closed piece), pts up to 96 of its vertices.
static func _pieces_of(kit_name: String, v: PackedVector3Array) -> Array:
	var key_id := {}
	var parent := PackedInt32Array()
	var ids := PackedInt32Array()
	ids.resize(v.size())
	for i in v.size():
		var k := Vector3i((v[i] * 1000.0).round())
		var id: int = key_id.get(k, -1)
		if id < 0:
			id = parent.size()
			key_id[k] = id
			parent.append(id)
		ids[i] = id
	for t in range(0, v.size(), 3):
		var a := ids[t]
		while parent[a] != a:
			parent[a] = parent[parent[a]]
			a = parent[a]
		for j in [1, 2]:
			var b := ids[t + j]
			while parent[b] != b:
				parent[b] = parent[parent[b]]
				b = parent[b]
			if a != b:
				parent[b] = a
	var slot := {}
	var boxes: Array[AABB] = []
	var tris := PackedInt32Array()
	var vols := PackedFloat64Array()
	var origin := PackedVector3Array()
	var pts: Array = []
	for t in range(0, v.size(), 3):
		var r := ids[t]
		while parent[r] != r:
			r = parent[r]
		var pi: int = slot.get(r, -1)
		var A := v[t]
		var C := v[t + 1]
		var B := v[t + 2]
		if pi < 0:
			pi = boxes.size()
			slot[r] = pi
			boxes.append(AABB(A, Vector3.ZERO))
			tris.append(0)
			vols.append(0.0)
			origin.append(A)
			pts.append([])
		boxes[pi] = boxes[pi].expand(A).expand(B).expand(C)
		tris[pi] += 1
		var o := origin[pi]
		vols[pi] += (A - o).dot((B - o).cross(C - o)) / 6.0
		if (pts[pi] as Array).size() < 96:
			(pts[pi] as Array).append_array([A, B, C])
	var out := []
	for pi in boxes.size():
		out.append({"kit": kit_name, "box": boxes[pi], "tris": tris[pi], "vol": vols[pi], "pts": pts[pi]})
	return out


func test_w10_no_inside_out_solids() -> void:
	# Round 3's cliff shelves were boxes wound inside-out (a mirrored frame):
	# see-through from outside, a trap from inside, and their perches snapped
	# inside them, while every other test passed (W10 probes each face from
	# its own front, whichever way that points). Every piece of every kit
	# with real volume must be wound outward.
	var pieces := _kit_pieces()
	var bad: Array = []
	var outward := 0
	for p in pieces:
		var bb: AABB = p["box"]
		var bv := bb.size.x * bb.size.y * bb.size.z
		if int(p["tris"]) < 12 or bv < 0.001:
			continue
		if float(p["vol"]) < -0.3 * bv:
			bad.append("%s at %s (%.2f m3 of a %.2f m3 box)" % [p["kit"], bb.get_center().snapped(Vector3.ONE * 0.1), p["vol"], bv])
		elif float(p["vol"]) > 0.3 * bv:
			outward += 1
	# The detector on a known case: the shelf's box wound both ways.
	var k := MeshKit.new("probe")
	k.box(Transform3D(Basis.IDENTITY, Vector3(0, 50, 0)), Vector3(3.4, 0.6, 2.2), Color.WHITE)
	var rev := PackedVector3Array()
	for i in range(0, k.verts.size(), 3):
		rev.append_array([k.verts[i], k.verts[i + 2], k.verts[i + 1]])
	var vol_ok: float = _pieces_of("probe", k.verts)[0]["vol"]
	var vol_rev: float = _pieces_of("probe", rev)[0]["vol"]
	near(vol_ok, 3.4 * 0.6 * 2.2, 1e-3, "detector: an outward box has its volume")
	near(vol_rev, -3.4 * 0.6 * 2.2, 1e-3, "detector: the same box inside-out is negative")
	metric("pieces", {"checked": pieces.size(), "outward_solids": outward, "inside_out": bad.size()})
	print("[world] kit pieces %d, clearly outward solids %d, inside-out %d" % [pieces.size(), outward, bad.size()])
	gt(float(outward), 2000.0, "thousands of closed, outward solids were checked")
	eq(bad.size(), 0, "no piece is wound inside-out: %s" % ", ".join(bad.slice(0, 8)))


## Clusters of kit pieces (pieces whose boxes, grown 3 cm, touch) that reach
## neither the ground nor, within 3 cm of one of their vertices, a collider
## of anything else (another kit, a tree, the terrain). Returns
## [descriptions, cluster count].
func _detached_clusters(pieces: Array) -> Array:
	var cell := 4.0
	var grid := {}
	for i in pieces.size():
		var bb: AABB = (pieces[i]["box"] as AABB).grow(0.03)
		for x in range(floori(bb.position.x / cell), floori(bb.end.x / cell) + 1):
			for z in range(floori(bb.position.z / cell), floori(bb.end.z / cell) + 1):
				var key := Vector2i(x, z)
				if not grid.has(key):
					grid[key] = []
				grid[key].append(i)
	var up := PackedInt32Array()
	var grounded := PackedByteArray()
	grounded.resize(pieces.size())
	for i in pieces.size():
		up.append(i)
		var bb: AABB = (pieces[i]["box"] as AABB).grow(0.03)
		for q: Vector2 in [Vector2(bb.get_center().x, bb.get_center().z), Vector2(bb.position.x, bb.position.z), Vector2(bb.end.x, bb.end.z),
				Vector2(bb.position.x, bb.end.z), Vector2(bb.end.x, bb.position.z)]:
			if bb.position.y <= maxf(world.terrain.height_at(q.x, q.y), world.ground_height(q.x, q.y)) + 0.03:
				grounded[i] = 1
				break
	for key in grid:
		var ids: Array = grid[key]
		for ii in ids.size():
			for jj in range(ii + 1, ids.size()):
				var i: int = ids[ii]
				var j: int = ids[jj]
				if not (pieces[i]["box"] as AABB).grow(0.03).intersects(pieces[j]["box"] as AABB):
					continue
				var ri := i
				while up[ri] != ri:
					ri = up[ri]
				var rj := j
				while up[rj] != rj:
					rj = up[rj]
				if ri != rj:
					up[rj] = ri
	var clusters := {}
	for i in pieces.size():
		var r := i
		while up[r] != r:
			r = up[r]
		if not clusters.has(r):
			clusters[r] = []
		clusters[r].append(i)
	var sp := SphereShape3D.new()
	sp.radius = 0.03
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = sp
	q.collision_mask = 1
	var out: PackedStringArray = []
	for r in clusters:
		var members: Array = clusters[r]
		var own := {}
		var ok := false
		for i in members:
			own[String(pieces[i]["kit"]) + "_body"] = true
			if grounded[i]:
				ok = true
		var n := 0
		for i in members:
			if ok:
				break
			for v: Vector3 in pieces[i]["pts"]:
				q.transform = Transform3D(Basis.IDENTITY, v)
				n += 1
				for h in space.intersect_shape(q, 8):
					if not own.has(String((h["collider"] as Node).name)):
						ok = true
						break
				if ok:
					break
		if not ok:
			var box: AABB = pieces[members[0]]["box"]
			for i in members:
				box = box.merge(pieces[i]["box"])
			out.append("%s at %s (%s)" % [own.keys(), box.get_center().snapped(Vector3.ONE * 0.01), box.size.snapped(Vector3.ONE * 0.01)])
	return [out, clusters.size()]


func test_w6_mounted_things_are_attached() -> void:
	# W6's footprints cover what stands on the ground. Things mounted on
	# other things (nest boxes on trunks and poles, lamps, the mast's top
	# plate and beacon, shelves on the cliff) are checked here: every cluster
	# of touching pieces must reach the ground or touch something else's
	# collider. Round 3 had four floating: the mast top 1.6 m above its
	# lattice, a nest box 2 m from its pole, two lamp posts 10 cm up.
	var res := _detached_clusters(_kit_pieces())
	var detached: PackedStringArray = res[0]
	# The detector on known cases: a box on the meadow floor and the same box
	# 0.5 m up (the probe kit has no collider of its own).
	var m := WorldLayout.MEADOW
	var g := world.ground_height(m.x, m.y)
	var k := MeshKit.new("probe")
	k.box_between(Vector3(m.x, g - 0.1, m.y), Vector3(m.x + 1, g + 0.9, m.y + 1), Color.WHITE)
	k.box_between(Vector3(m.x + 5, g + 0.5, m.y), Vector3(m.x + 6, g + 1.5, m.y + 1), Color.WHITE)
	var probe: PackedStringArray = _detached_clusters(_pieces_of("probe", k.verts))[0]
	eq(probe.size(), 1, "detector: of a grounded and a lifted box, only the lifted one is flagged (%s)" % ", ".join(probe))
	metric("attachment", {"clusters": res[1], "detached": Array(detached)})
	print("[world] attachment: %d clusters, %d detached %s" % [res[1], detached.size(), detached])
	eq(detached.size(), 0, "every mounted thing touches its support: %s" % ", ".join(detached.slice(0, 8)))


## Drawn triangles (full detail, any kit or tree chunk except `skip`) whose
## boxes come within `r` of p.
func _drawn_tris_near(p: Vector3, r: float, skip: String) -> PackedVector3Array:
	var out := PackedVector3Array()
	for n in world.get_node("Visual").get_children():
		var mi := n as MeshInstance3D
		if mi == null or mi.mesh == null or mi.has_meta(&"shadow_only") or mi.visibility_range_begin > 0.0 or String(mi.name) == skip:
			continue
		var gb := mi.global_transform * mi.mesh.get_aabb()
		if not gb.grow(r).has_point(p):
			continue
		var v: PackedVector3Array = mi.global_transform * (mi.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array)
		var near_box := AABB(p - Vector3.ONE * r, Vector3.ONE * 2.0 * r)
		for t in range(0, v.size(), 3):
			if near_box.intersects(AABB(v[t], Vector3.ZERO).expand(v[t + 1]).expand(v[t + 2])):
				out.append_array([v[t], v[t + 1], v[t + 2]])
	return out


func test_w6_nest_boxes_hang_on_their_trunk_or_pole() -> void:
	# Round 3's boxes were placed from a nominal trunk radius: 7-8 cm off the
	# collider, more off the drawn bark, and one hung in mid-air 2 m from its
	# pole. Now each is seated on the post's collider over its whole back
	# board and nailed to the drawn wood by a batten, and its inside is clear.
	var nb := world.get_node("Bodies/nest_boxes_body") as CollisionObject3D
	var ex: Array[RID] = [nb.get_rid()]
	var bad: PackedStringArray = []
	var rows := {}
	var n := 0
	for o in world.get_openings():
		if o["type"] != "nest_box":
			continue
		n += 1
		var out: Vector3 = o["normal"]
		var origin: Vector3 = o["position"] - out * 0.1 - Vector3.UP * 0.04
		var lat := Vector3.UP.cross(out).normalized()
		var board := origin - out * 0.1
		# 1. The post's collider is right behind the board (seated 1.2 cm off it at its
		# nearest point), and no corner more than 5 cm off (a flat board on a
		# round, leaning post opens a little at the far corners).
		var worst := 0.0
		var nearest := INF
		for u: float in [-0.07, 0.0, 0.07]:
			for v: float in [-0.1, 0.0, 0.1]:
				var p := board + lat * u + Vector3.UP * v
				var rq := PhysicsRayQueryParameters3D.create(p, p - out * 1.0)
				rq.collision_mask = 1
				rq.exclude = ex
				rq.hit_back_faces = false
				var h := space.intersect_ray(rq)
				var gap := 1.0 if h.is_empty() else p.distance_to(h["position"])
				worst = maxf(worst, gap)
				nearest = minf(nearest, gap)
		# 2. Inside, only the box itself.
		var sp := SphereShape3D.new()
		sp.radius = 0.07
		var q := PhysicsShapeQueryParameters3D.new()
		q.shape = sp
		q.collision_mask = 1
		q.exclude = ex
		q.transform = Transform3D(Basis.IDENTITY, origin)
		var inside := space.intersect_shape(q, 4).size()
		# 3. The batten reaches into the drawn wood: along its centre line the
		# drawn post is met before the batten's own back end.
		var rq2 := PhysicsRayQueryParameters3D.create(board - out * 0.6, board)
		rq2.collision_mask = 1
		var passed: Array[RID] = []
		var hb := {}
		for tries in 3:
			hb = space.intersect_ray(rq2)
			if hb.is_empty() or hb["collider"] == nb:
				break
			# The far side of the post (the ray starts behind it): look past it.
			passed.append((hb["collider"] as CollisionObject3D).get_rid())
			rq2.exclude = passed
		var d_batten := INF if hb.is_empty() or hb["collider"] != nb else board.distance_to(hb["position"])
		var tris := _drawn_tris_near(board, 0.6, "nest_boxes")
		var d_wood := 0.0
		for v: float in [-0.2, 0.0, 0.2]:
			var from := board + Vector3.UP * v
			var best := INF
			for t in range(0, tris.size(), 3):
				var hit: Variant = Geometry3D.ray_intersects_triangle(from, -out, tris[t], tris[t + 1], tris[t + 2])
				if hit != null:
					best = minf(best, from.distance_to(hit as Vector3))
			d_wood = maxf(d_wood, best)
		rows[o["name"]] = {"collider_gap": [snappedf(nearest, 0.001), snappedf(worst, 0.001)], "inside_hits": inside,
			"batten": snappedf(d_batten, 0.001), "wood": snappedf(d_wood, 0.001)}
		if nearest > 0.02 or worst > 0.05 or inside > 0 or d_wood > d_batten or d_batten > 0.2:
			bad.append("%s %s" % [o["name"], rows[o["name"]]])
	metric("nest_box_mounts", rows)
	gt(float(n), 11.0, "nest boxes present")
	eq(bad.size(), 0, "every box sits on its post's collider (touching within 2 cm: it is seated 1.2 cm off; no corner 5 cm off), is clear inside, and its batten reaches the drawn wood: %s" % ", ".join(bad))


func test_w3_cliff_shelves_are_solid_and_set_in_the_face() -> void:
	# The eagle shelves up the west cliff: solid from outside (a drop lands
	# on the top, level flight meets the front), a bird on one can leave, and
	# the shelf runs back into the rock along its whole width (round 3 had
	# five standing 0.1-1 m off the face).
	# The shelves are built into the boulders kit (no draw call of their own):
	# its pieces carrying a cliff ledge perch.
	var cliff_ledges := world.get_perches().filter(func(p: Perch) -> bool: return p.kind == Perch.Kind.LEDGE and p.district == &"cliff")
	var shelves := _kit_pieces().filter(func(p: Dictionary) -> bool:
		if p["kit"] != "boulders":
			return false
		for pr: Perch in cliff_ledges:
			if (p["box"] as AABB).grow(0.1).has_point(pr.position):
				return true
		return false)
	eq(shelves.size(), int(world.build.get_meta(&"cliff_shelves", -1)), "one solid piece, with its perch, per shelf built")
	gt(float(shelves.size()), 8.0, "the cliff has shelves for big birds")
	var ledges := world.get_node("Bodies/boulders_body") as CollisionObject3D
	var cliff := world.get_node("Bodies/cliff_body") as CollisionObject3D
	var bad: PackedStringArray = []
	var rows := []
	for sh in shelves:
		var bb: AABB = sh["box"]
		var perch: Perch = null
		for p in world.get_perches():
			if p.kind == Perch.Kind.LEDGE and p.district == &"cliff" and bb.grow(0.1).has_point(p.position):
				perch = p
		if perch == null:
			bad.append("shelf at %s has no perch" % bb.get_center().snapped(Vector3.ONE * 0.1))
			continue
		var f := perch.facing
		var lat := Vector3.UP.cross(f).normalized()
		var r := k_body * perch.max_span
		var row := {"at": perch.position.snapped(Vector3.ONE * 0.1), "max_span": snappedf(perch.max_span, 0.01)}
		# A drop onto it stops on its top, at the perch (front faces only).
		var rq := PhysicsRayQueryParameters3D.create(perch.position + Vector3.UP * 3.0, perch.position + Vector3.DOWN * 3.0)
		rq.hit_back_faces = false
		var drop := space.intersect_ray(rq)
		row["drop"] = snappedf((drop["position"] as Vector3).y - perch.position.y, 0.001) if not drop.is_empty() else "none"
		if drop.is_empty() or drop["collider"] != ledges or absf((drop["position"] as Vector3).y - perch.position.y) > 0.03:
			bad.append("drop onto %s: %s" % [row["at"], row["drop"]])
		# Level flight at a sparrow's size meets its front, ahead of the perch.
		var lvl := perch.position + Vector3.DOWN * 0.3
		var frac := _sphere_cast(lvl + f * 5.0, lvl - f * 1.0, 0.04)
		row["front_ahead"] = snappedf(5.0 - frac * 6.0, 0.01)
		if frac >= 1.0 or 5.0 - frac * 6.0 < 0.4:
			bad.append("front of %s: %s" % [row["at"], row["front_ahead"]])
		# A bird on it can leave (up, out or up-and-out).
		var body := perch.position + Vector3.UP * (r + 0.02)
		var exits := 0
		for d: Vector3 in [Vector3.UP, f, (f + Vector3.UP).normalized()]:
			if _sphere_cast(body, body + d * 3.0, r) >= 1.0:
				exits += 1
		row["exits"] = exits
		if exits == 0 or perch.max_span < 2.0:
			bad.append("%s: exits %d, rated %.2f" % [row["at"], exits, perch.max_span])
		# Set in the face: from in front of the lip, a ray back through the
		# shelf meets the cliff before reaching the shelf's back end, across
		# its whole width and at two heights.
		var back := INF
		for v: Vector3 in sh["pts"]:
			back = minf(back, (v - perch.position).dot(f))
		var misses := 0
		for u: float in [-1.5, -0.75, 0.0, 0.75, 1.5]:
			for dy: float in [-0.2, -0.9]:
				var a := perch.position + lat * u + Vector3.UP * dy + f * 1.2
				var rq2 := PhysicsRayQueryParameters3D.create(a, a + f * (back - 1.2 + 0.02))
				rq2.exclude = [ledges.get_rid()]
				rq2.hit_back_faces = false
				var h := space.intersect_ray(rq2)
				if h.is_empty() or h["collider"] != cliff:
					misses += 1
		row["face_behind_back"] = misses
		if misses > 0:
			bad.append("%s stands off the face at %d of 10 points" % [row["at"], misses])
		rows.append(row)
	metric("cliff_shelves", rows)
	eq(bad.size(), 0, "every shelf is solid, leavable, eagle-rated and set in the face: %s" % ", ".join(bad))


# --- the forest demands weaving -----------------------------------------------------

## Straight-line flights through a wood: from random clear points 3-12 m
## above the ground on random headings, how far does a body of radius r get
## (capped at L)? Returns mean free path, blocked fraction, and the share of
## start points with a clear 15 m line on at least one of 16 headings.
func _free_path(centre: Vector2, radius: float, r_body: float, seed_: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_
	var L := 120.0
	var total := 0.0
	var n := 0
	var blocked := 0
	var escapable := 0
	var tried := 0
	for i in 400:
		var p2 := centre + Vector2.from_angle(rng.randf() * TAU) * sqrt(rng.randf()) * radius
		var h := rng.randf_range(3.0, 12.0)
		var p := Vector3(p2.x, world.ground_height(p2.x, p2.y) + h, p2.y)
		if not _sphere_hits(p, r_body).is_empty():
			continue
		var d := Vector2.from_angle(rng.randf() * TAU)
		var e2 := p2 + d * L
		var f := _sphere_cast(p, Vector3(e2.x, world.ground_height(e2.x, e2.y) + h, e2.y), r_body)
		total += f * L
		n += 1
		if f < 1.0:
			blocked += 1
		if n % 4 == 1:
			tried += 1
			for k in 16:
				var dk := Vector2.from_angle(TAU * k / 16.0) * 15.0
				if _sphere_cast(p, p + Vector3(dk.x, 0.0, dk.y), r_body) >= 1.0:
					escapable += 1
					break
	return {"mfp": total / maxf(n, 1), "blocked": float(blocked) / maxf(n, 1), "n": n,
		"weavable": float(escapable) / maxf(tried, 1)}


## Fraction of the ground (2 m grid) inside radius with a tree, log or bush
## directly overhead.
func _canopy(centre: Vector2, radius: float) -> float:
	var covered := 0
	var n := 0
	var x := -radius
	while x <= radius:
		var z := -radius
		while z <= radius:
			if Vector2(x, z).length() <= radius:
				var q := centre + Vector2(x, z)
				var g := world.ground_height(q.x, q.y)
				var hit := _ray(Vector3(q.x, g + 60.0, q.y), Vector3(q.x, g - 1.0, q.y))
				n += 1
				if not hit.is_empty() and not _is_terrain(hit):
					covered += 1
			z += 2.0
		x += 2.0
	return float(covered) / maxf(n, 1)


func test_forest_demands_weaving() -> void:
	# The brief: trees "with real branch structure to weave through", places
	# that make acrobatic flight "required and rewarding". So: straight
	# lines through the wood end quickly, the canopy closes over, yet from
	# anywhere inside there is a gap to fly on through.
	var fc := WorldLayout.FOREST
	var region := WorldLayout.FOREST_R * 0.8
	var core := WorldLayout.FOREST_CORE_R
	var out := {}
	for sp in [["sparrow", 0.24], ["crow", 0.95], ["eagle", 2.1]]:
		out["wood_" + String(sp[0])] = _free_path(fc, region, k_body * float(sp[1]), 5)
	out["core_sparrow"] = _free_path(fc, core, k_body * 0.24, 9)
	out["open_meadow_sparrow"] = _free_path(WorldLayout.MEADOW, 120.0, k_body * 0.24, 6)
	var cover_wood := _canopy(fc, region)
	var cover_core := _canopy(fc, core)
	out["canopy_wood"] = cover_wood
	out["canopy_core"] = cover_core
	# Trunk spacing in the core (trees proper, not saplings).
	var lib: TreeLib = world.build.get_meta(&"tree_lib")
	var pts := PackedVector2Array()
	for inst in lib.instances:
		var p: Vector3 = inst["pos"]
		if lib.variants[inst["v"]]["species"] != TreeLib.Species.SAPLING and Vector2(p.x, p.z).distance_to(fc) < core:
			pts.append(Vector2(p.x, p.z))
	var nn := 0.0
	for i in pts.size():
		var best := INF
		for j in pts.size():
			if i != j:
				best = minf(best, pts[i].distance_squared_to(pts[j]))
		nn += sqrt(best)
	nn /= maxf(pts.size(), 1)
	out["core_trees"] = pts.size()
	out["core_nn_spacing"] = nn
	metric("forest", out)
	print("[world] forest ", out)
	# (Round 1 measured the old parkland at 71.5 m / 11.7 % cover.)
	lt(float(out["wood_sparrow"]["mfp"]), 38.0, "sparrow mean free path through the wood < 38 m")
	lt(float(out["core_sparrow"]["mfp"]), 24.0, "sparrow mean free path in the old wood < 24 m")
	lt(float(out["wood_eagle"]["mfp"]), 28.0, "an eagle cannot cruise straight through the wood")
	gt(float(out["open_meadow_sparrow"]["mfp"]), 110.0, "while the meadow stays open")
	gt(cover_wood, 0.42, "canopy covers most of the wood")
	gt(cover_core, 0.55, "canopy closes over the old wood")
	between(nn, 4.0, 7.5, "old-wood trunks ~4-7.5 m apart")
	gt(float(out["core_sparrow"]["weavable"]), 0.9, "from anywhere in the old wood a sparrow has a 15 m gap to fly on")
	gt(float(out["wood_crow"]["weavable"]), 0.8, "and so does a crow in most of the wood")


# --- W9 determinism -------------------------------------------------------------------

func _hash(w: SoaringWorld) -> String:
	var parts := PackedStringArray()
	for p in w.get_perches():
		parts.append("%d|%.3f|%.3f|%.3f|%.3f|%s" % [p.kind, p.position.x, p.position.y, p.position.z, p.max_span, p.district])
	for l in w.get_landmarks():
		var pos: Vector3 = l["position"]
		parts.append("%s|%s|%.3f|%.3f|%.3f" % [l["name"], l["kind"], pos.x, pos.y, pos.z])
	for r in w.get_refuges():
		var pos: Vector3 = r["position"]
		parts.append("%.3f|%.3f|%.3f|%.3f" % [pos.x, pos.y, pos.z, r["max_span"]])
	return "|".join(parts).sha256_text()


func _isolated_world(seed: int) -> Array:
	var vp := SubViewport.new()
	vp.own_world_3d = true
	vp.size = Vector2i(8, 8)
	vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(vp)
	var w: SoaringWorld = load("res://scenes/world/world.tscn").instantiate()
	w.world_seed = seed
	w.with_decoration = false
	vp.add_child(w)
	return [vp, w]


## Everything built: every drawn mesh's vertices and colours (and where it
## is placed, to the millimetre) and every collision shape with its
## transform. Node transforms are snapped: other tests lift and restore
## bodies, which may leave an ulp of drift.
func _geometry_hash(w: SoaringWorld) -> String:
	var hc := HashingContext.new()
	hc.start(HashingContext.HASH_SHA256)
	for n in w.get_node("Visual").get_children():
		var mi := n as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		hc.update(("%s|%s" % [mi.name, mi.position.snapped(Vector3.ONE * 0.001)]).to_utf8_buffer())
		for si in mi.mesh.get_surface_count():
			var arr := mi.mesh.surface_get_arrays(si)
			hc.update((arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).to_byte_array())
			if arr[Mesh.ARRAY_COLOR] != null:
				hc.update((arr[Mesh.ARRAY_COLOR] as PackedColorArray).to_byte_array())
	var stack: Array[Node] = [w.get_node("Bodies")]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for c in node.get_children():
			stack.append(c)
		var co := node as CollisionObject3D
		if co == null:
			continue
		hc.update(("%s|%s" % [co.name, co.position.snapped(Vector3.ONE * 0.001)]).to_utf8_buffer())
		for owner in co.get_shape_owners():
			hc.update(var_to_bytes(co.shape_owner_get_transform(owner)))
			for si in co.shape_owner_get_shape_count(owner):
				var sh := co.shape_owner_get_shape(owner, si)
				if sh is ConcavePolygonShape3D:
					hc.update((sh as ConcavePolygonShape3D).get_faces().to_byte_array())
				elif sh is ConvexPolygonShape3D:
					hc.update((sh as ConvexPolygonShape3D).points.to_byte_array())
				elif sh is CapsuleShape3D:
					hc.update(var_to_bytes([(sh as CapsuleShape3D).radius, (sh as CapsuleShape3D).height]))
				elif sh is BoxShape3D:
					hc.update(var_to_bytes((sh as BoxShape3D).size))
				else:
					hc.update(sh.get_class().to_utf8_buffer())
	return hc.finish().hex_encode()


func test_w9_deterministic_by_seed() -> void:
	var h0 := _hash(world)
	var g0 := _geometry_hash(world)
	var a := _isolated_world(1)
	var ha := _hash(a[1])
	var ga := _geometry_hash(a[1])
	a[0].queue_free()
	await wait_frames(1)
	var b := _isolated_world(2)
	var hb := _hash(b[1])
	var gb := _geometry_hash(b[1])
	b[0].queue_free()
	await wait_frames(1)
	eq(ha, h0, "same seed, same perches/landmarks/refuges")
	check(hb != h0, "a different seed varies the details")
	# The geometry too (colour jitter drawn from a global RNG would pass the
	# first hash and fail this one).
	eq(ga, g0, "same seed, same drawn meshes, colours and colliders")
	check(gb != g0, "a different seed builds different geometry")
	metric("hash_seed1", h0)
	metric("geometry_hash_seed1", g0)


# --- W10 collision coverage ------------------------------------------------------------

const SOFT_OK := ["grass", "flowers", "reeds", "cloud", "motes"]


func test_tree_levels_are_wired() -> void:
	# The render budget (W7) depends on each tree chunk being drawn at exactly
	# one level: full detail is shown only while its mid stand-in is out of
	# range (visibility_parent), the mid only while its far group is. Checked
	# here on the built nodes (the engine behaviour itself: world_hlod_check;
	# the budgets: world_perf), so a lost wiring fails the headless suite.
	var visual: Node = world.get_node("Visual")
	var bad: PackedStringArray = []
	var full := 0
	var wired := 0
	var grouped := 0
	for n in visual.get_children():
		var nm := String(n.name)
		if not nm.begins_with("trees_") or nm.begins_with("trees_lod_") or nm.begins_with("trees_far_") or nm.begins_with("trees_shadow"):
			continue
		var mi := n as MeshInstance3D
		full += 1
		var lod := visual.get_node_or_null("trees_lod_" + nm.trim_prefix("trees_")) as MeshInstance3D
		if lod == null:
			# Understory-only chunks have no stand-ins: they must end.
			if mi.visibility_range_end <= 0.0:
				bad.append("%s has neither a stand-in nor an end distance" % nm)
			continue
		if mi.get_node_or_null(mi.visibility_parent) != lod:
			bad.append("%s is not handed over to %s" % [nm, lod.name])
			continue
		if lod.visibility_range_begin <= 0.0 or mi.visibility_range_end > 0.0 or mi.visibility_range_begin > 0.0:
			bad.append("%s: full [%.0f, %.0f], mid begins %.0f" % [nm, mi.visibility_range_begin, mi.visibility_range_end, lod.visibility_range_begin])
			continue
		wired += 1
		var far := lod.get_node_or_null(lod.visibility_parent) as MeshInstance3D
		if far:
			grouped += 1
			if not String(far.name).begins_with("trees_far_") or far.visibility_range_begin <= lod.visibility_range_begin:
				bad.append("%s's far group %s begins at %.0f, before the mid (%.0f)" % [lod.name, far.name, far.visibility_range_begin, lod.visibility_range_begin])
	metric("tree_levels", {"chunks": full, "handed_over": wired, "in_far_groups": grouped})
	gt(float(wired), 20.0, "tree chunks with stand-ins")
	gt(float(grouped), float(wired) * 0.9, "nearly all of them in far groups")
	eq(bad.size(), 0, "every chunk is drawn at one level at a time: %s" % ", ".join(bad.slice(0, 6)))


func test_tree_stand_ins_keep_the_silhouette() -> void:
	# Round 2's stand-ins were inscribed in the colliders: a dense wood seen
	# from 60 m looked like sparse parasols and crowns jumped in size as a
	# bird flew in. Now every tree variant's mid and far stand-ins must cover
	# the same projected area as the full tree, from four sides (10 deg
	# above the horizon) and from above (70 deg): mid within 15 %, far
	# (seen from 55 m and more) within 22 %.
	var lib: TreeLib = world.build.get_meta(&"tree_lib")
	var dirs: Array[Vector3] = []
	for a in 4:
		dirs.append(Vector3(cos(PI * 0.25 * a), -0.17, sin(PI * 0.25 * a)))
	dirs.append(Vector3(0.34, -0.94, 0.0))
	var bad: PackedStringArray = []
	var ratios := {}
	var lo := {"lod_arr": INF, "far_arr": INF}
	var hi := {"lod_arr": 0.0, "far_arr": 0.0}
	for v in lib.variants:
		if v["species"] == TreeLib.Species.SAPLING:
			continue  # never drawn as a stand-in
		var sp: String = TreeLib.Species.keys()[v["species"]]
		for key in ["lod_arr", "far_arr"]:
			var side := 0.0
			var top := 0.0
			for di in dirs.size():
				var r := TreeLib.silhouette_area(v[key][0], dirs[di], 0.12) / TreeLib.silhouette_area(v["full"][0], dirs[di], 0.12)
				if di < 4:
					side += r / 4.0
				else:
					top = r
			var tol := 0.15 if key == "lod_arr" else 0.22
			for r2: float in [side, top]:
				lo[key] = minf(lo[key], r2)
				hi[key] = maxf(hi[key], r2)
				if absf(r2 - 1.0) > tol:
					bad.append("%s %s %.2f" % [sp, key, r2])
			ratios["%s_%s" % [sp, key]] = [snappedf(side, 0.01), snappedf(top, 0.01)]
	eq(bad.size(), 0, "stand-ins keep the full tree's silhouette: %s" % ", ".join(bad))
	metric("stand_in_area_ratio_range", {"mid": [lo["lod_arr"], hi["lod_arr"]], "far": [lo["far_arr"], hi["far_arr"]]})
	metric("stand_in_area_ratios", ratios)


func test_w10_no_invisible_colliders() -> void:
	# The converse of W10: nothing collides that is not drawn. Trimeshes are
	# the drawn faces by construction and hulls a clump's own vertices; the
	# capsules (poles, rods, wires, the mast's legs, fence rails) are laid
	# along drawn tubes, and must stay on them: every point of every capsule
	# axis must have drawn geometry of its own kit within its radius + 25 cm.
	# (Round 3's mast legs ran 1.2 m above the drawn lattice.)
	var visual: Node = world.get_node("Visual")
	var bad: PackedStringArray = []
	var capsules := 0
	var samples := 0
	var buried := 0
	var cell := 0.5
	for b in world.get_node("Bodies").get_children():
		var co := b as CollisionObject3D
		if co == null or not String(co.name).ends_with("_body"):
			continue
		var caps := []
		for owner in co.get_shape_owners():
			for si in co.shape_owner_get_shape_count(owner):
				var sh := co.shape_owner_get_shape(owner, si) as CapsuleShape3D
				if sh:
					var xf := co.global_transform * co.shape_owner_get_transform(owner)
					var half := maxf(sh.height * 0.5 - sh.radius, 0.0)
					caps.append([xf * Vector3(0, -half, 0), xf * Vector3(0, half, 0), sh.radius])
		if caps.is_empty():
			continue
		var mi := visual.get_node_or_null(NodePath(String(co.name).trim_suffix("_body"))) as MeshInstance3D
		if mi == null:
			bad.append("%s has capsules but no drawn mesh" % co.name)
			continue
		# Drawn points: every triangle's corners, centre and points every
		# 20 cm along its edges, hashed on a 0.5 m grid.
		var v: PackedVector3Array = mi.global_transform * (mi.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array)
		var grid := {}
		for t in range(0, v.size(), 3):
			var pts: Array[Vector3] = [(v[t] + v[t + 1] + v[t + 2]) / 3.0]
			for e in 3:
				var a := v[t + e]
				var c := v[t + (e + 1) % 3]
				var m := maxi(1, ceili(a.distance_to(c) / 0.2))
				for kk in m:
					pts.append(a.lerp(c, float(kk) / m))
			for p in pts:
				var key := Vector3i((p / cell).floor())
				if not grid.has(key):
					grid[key] = PackedVector3Array()
				var arr: PackedVector3Array = grid[key]
				arr.append(p)
				grid[key] = arr
		for cp in caps:
			capsules += 1
			var a: Vector3 = cp[0]
			var c: Vector3 = cp[1]
			var reach: float = float(cp[2]) + 0.25
			var m := maxi(1, ceili(a.distance_to(c) / 0.5))
			for kk in m + 1:
				var p := a.lerp(c, float(kk) / m)
				samples += 1
				var found := false
				var k0 := Vector3i(((p - Vector3.ONE * reach) / cell).floor())
				var k1 := Vector3i(((p + Vector3.ONE * reach) / cell).floor())
				for x in range(k0.x, k1.x + 1):
					for y in range(k0.y, k1.y + 1):
						for z in range(k0.z, k1.z + 1):
							var arr: Variant = grid.get(Vector3i(x, y, z))
							if arr == null:
								continue
							for q: Vector3 in (arr as PackedVector3Array):
								if q.distance_to(p) <= reach:
									found = true
									break
							if found:
								break
						if found:
							break
					if found:
						break
				# Or buried: under the terrain, or inside a closed drawn solid of
				# the kit (a mast leg's foot in its plinth): the first drawn face
				# straight above faces up, i.e. leaves the solid.
				if not found and p.y < world.terrain.height_at(p.x, p.z):
					found = true
				if not found:
					var best := INF
					var up_facing := false
					for t in range(0, v.size(), 3):
						var hit: Variant = Geometry3D.ray_intersects_triangle(p, Vector3.UP, v[t], v[t + 1], v[t + 2])
						if hit != null and (hit as Vector3).y - p.y < best:
							best = (hit as Vector3).y - p.y
							up_facing = (v[t + 2] - v[t]).cross(v[t + 1] - v[t]).y > 0.0
					found = up_facing
					buried += 1
				if not found:
					bad.append("%s capsule point %s (r %.2f)" % [co.name, p.snapped(Vector3.ONE * 0.01), cp[2]])
					break
	metric("capsules_checked", {"capsules": capsules, "axis_points": samples, "inside_a_drawn_solid_checked": buried})
	gt(float(capsules), 500.0, "capsules of poles, wires, rods and the mast checked")
	eq(bad.size(), 0, "every collider is drawn: %s" % ", ".join(bad.slice(0, 8)))


func test_w10_every_visible_solid_collides() -> void:
	var visual: Node = world.get_node("Visual")
	var soft: Node = world.get_node("Soft")
	var rng := RandomNumberGenerator.new()
	rng.seed = 17
	var missing: PackedStringArray = []
	var samples := 0
	var covered := 0
	var per_node := {}
	var stand_ins: Array[MeshInstance3D] = []
	for mi in visual.get_children():
		if not (mi is MeshInstance3D):
			missing.append("%s is not a mesh" % mi.name)
			continue
		# Shadow-only casters are never drawn (not "visible solids"); they
		# must really be shadow-only.
		if mi.has_meta(&"shadow_only"):
			if (mi as GeometryInstance3D).cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY:
				missing.append("%s claims shadow-only but is drawn" % mi.name)
			continue
		var has_col: bool = mi.has_meta(&"collider") or mi.has_meta(&"collider_group")
		if not has_col:
			missing.append(String(mi.name))
			continue
		if mi.has_meta(&"stand_in_min_dist"):
			stand_ins.append(mi)
			continue
		var mesh: Mesh = (mi as MeshInstance3D).mesh
		var arr := mesh.surface_get_arrays(0)
		var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var tris := verts.size() / 3
		var n := mini(tris, 250)
		var ok := 0
		for s in n:
			var t := rng.randi() % tris
			var a := verts[t * 3]
			var b := verts[t * 3 + 1]
			var c := verts[t * 3 + 2]
			var cen: Vector3 = (mi as MeshInstance3D).global_transform * ((a + b + c) / 3.0)
			var nrm := (b - a).cross(c - a)
			# Godot winding is clockwise, so this normal points inward. Probe
			# from just OUTSIDE the face: one-sided trimesh faces only collide
			# from their front.
			var inward := nrm.normalized() if nrm.length() > 1e-9 else Vector3.ZERO
			var probe := cen - ((mi as MeshInstance3D).global_transform.basis * inward).normalized() * 0.02
			var rad := 0.06 if String(mi.name).begins_with("trees_") else 0.04
			if not _sphere_hits(probe, rad).is_empty():
				ok += 1
		samples += n
		covered += ok
		per_node[String(mi.name)] = float(ok) / maxf(n, 1)
	eq(missing.size(), 0, "every visual mesh declares its collider: %s" % ", ".join(missing))
	var worst_name := ""
	var worst := 1.0
	for k in per_node:
		if per_node[k] < worst:
			worst = per_node[k]
			worst_name = k
	gt(float(covered) / maxf(samples, 1), 0.99, "sampled visible triangles are backed by colliders")
	gt(worst, 0.96, "worst mesh coverage (%s)" % worst_name)
	metric("coverage", float(covered) / maxf(samples, 1))
	metric("coverage_worst", [worst_name, worst])
	# Tree stand-ins (mid and far levels) are drawn only from their switch
	# distance on, and match the full tree's silhouette rather than its
	# colliders (test_tree_stand_ins_keep_the_silhouette). They may stray
	# from the colliders by what 1 degree covers at the nearest distance they
	# are ever seen from: every sampled vertex must be that close to one.
	var si_samples := 0
	var si_dev_terrain := 0.0
	var si_bad := 0
	var si_worst := 0.0
	var si_worst_at := ""
	var min_dist := INF
	for mi in stand_ins:
		# The camera is at least `begin` from the mesh's bounds centre when
		# it shows, so a vertex is at least begin - |vertex - centre| away.
		# Tree stand-ins switch on a visibility range from their bounds'
		# centre, so a vertex is at least (begin - its offset from the
		# centre) away; far terrain switches on its nearest point, so every
		# vertex is at least stand_in_min_dist away.
		var flat: bool = mi.get_meta(&"stand_in_flat", false)
		var begin: float = mi.get_meta(&"stand_in_min_dist") + mi.mesh.get_aabb().size.length() * 0.5
		var centre := mi.global_transform * mi.mesh.get_aabb().get_center()
		var arrs := mi.mesh.surface_get_arrays(0)
		var verts: PackedVector3Array = arrs[Mesh.ARRAY_VERTEX]
		var norms: PackedVector3Array = arrs[Mesh.ARRAY_NORMAL]
		for k in mini(verts.size(), 200):
			# Vertices, and random points on the faces (a face can stray
			# further than its corners: far terrain between lattice points).
			var vi := rng.randi() % verts.size()
			var local := verts[vi]
			if k % 2 == 1:
				var t0 := (vi / 3) * 3
				var b1 := rng.randf()
				var b2 := rng.randf() * (1.0 - b1)
				local = verts[t0] + (verts[t0 + 1] - verts[t0]) * b1 + (verts[t0 + 2] - verts[t0]) * b2
			# A hair out along the facet's normal: a one-sided trimesh (the
			# terrain) ignores a probe whose centre is on or behind it.
			var v := mi.global_transform * (local + norms[vi] * 0.03)
			var d_min: float = float(mi.get_meta(&"stand_in_min_dist")) if flat else begin - v.distance_to(centre)
			min_dist = minf(min_dist, d_min)
			var tol := maxf(0.15, d_min * tan(deg_to_rad(1.0)))
			si_samples += 1
			if flat:
				# Far terrain: its distance from the collided terrain, exactly
				# (vertically, an upper bound; a sphere probe is no use under
				# a one-sided trimesh).
				var dev := absf(v.y - 0.03 - world.terrain.height_at(v.x, v.z))
				si_dev_terrain = maxf(si_dev_terrain, dev)
				if dev > tol:
					si_bad += 1
					if dev / tol > si_worst:
						si_worst = dev / tol
						si_worst_at = "%s seen from %.0f m: %.2f m off, allowed %.2f (point %s)" % [mi.name, d_min, dev, tol, v.snapped(Vector3.ONE * 0.1)]
				continue
			if _sphere_hits(v, tol).is_empty():
				si_bad += 1
				# How far is it really? Grow the probe until it touches.
				var r := tol
				while r < 6.0 and _sphere_hits(v, r).is_empty():
					r *= 1.25
				if r / tol > si_worst:
					si_worst = r / tol
					si_worst_at = "%s seen from %.0f m: %.2f m off, allowed %.2f (point %s)" % [mi.name, d_min, r, tol, v.snapped(Vector3.ONE * 0.1)]
	gt(float(stand_ins.size()), 40.0, "stand-ins present (tree mid and far levels, far terrain)")
	gt(min_dist, 25.0, "no stand-in is ever seen from closer than 25 m")
	eq(si_bad, 0, "stand-in vertices and faces within 1 degree of the colliders at their nearest (%d of %d off; worst %s)" % [si_bad, si_samples, si_worst_at])
	metric("stand_ins", {"meshes": stand_ins.size(), "points": si_samples, "off": si_bad, "nearest_m": min_dist, "worst": si_worst_at,
		"far_terrain_max_dev_m": si_dev_terrain})
	# Soft things are only the allowed low decoration, clouds and motes.
	var soft_bad: PackedStringArray = []
	for n in soft.get_children():
		var cat: String = n.get_meta(&"soft", "")
		if not cat in SOFT_OK:
			soft_bad.append(String(n.name))
			continue
		if n is MultiMeshInstance3D and cat != "motes":
			var aabb := (n as MultiMeshInstance3D).multimesh.get_aabb()
			var mm := (n as MultiMeshInstance3D).multimesh
			for i in mini(mm.instance_count, 200):
				var xf := mm.get_instance_transform(i)
				var top := (xf * Vector3(0, aabb.end.y, 0)).y
				if top - world.terrain.height_at(xf.origin.x, xf.origin.z) > SoftDecor.MAX_H:
					soft_bad.append("%s too tall" % n.name)
					break
		if cat == "cloud":
			var ab := (n as MeshInstance3D).get_aabb()
			if ab.position.y < world.ceiling:
				soft_bad.append("clouds reach below the ceiling")
	eq(soft_bad.size(), 0, "non-solid visuals are only low decoration, clouds above the ceiling, motes: %s" % ", ".join(soft_bad))
