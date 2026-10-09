extends TestCase
## Round-4 engineering verifier probes for the world area (independent of the
## builder's suite). Headless:
##   tools/gd.sh world_verify2 --headless res://tests/runner.tscn -- --dir=res://tests/probes/world --suite=world_r4eng
## Prints "[world-r4eng]" lines; metrics go to artifacts/tests/report_world_r4eng.json.

var world: SoaringWorld
var space: PhysicsDirectSpaceState3D
var k_body := 0.16
var generated_count := 0


func before_all() -> void:
	k_body = WorldBuild.body_k()
	world = load("res://scenes/world/world.tscn").instantiate()
	world.generated.connect(func() -> void: generated_count += 1)
	add_child(world)
	await wait_physics(2)
	space = world.get_world_3d().direct_space_state


func after_all() -> void:
	if world:
		world.queue_free()


func _sphere_hits(c: Vector3, r: float) -> Array:
	var sp := SphereShape3D.new()
	sp.radius = r
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = sp
	q.collision_mask = 1
	q.transform = Transform3D(Basis.IDENTITY, c)
	return space.intersect_shape(q, 4)


func _cast(from: Vector3, to: Vector3, r: float) -> float:
	var sp := SphereShape3D.new()
	sp.radius = r
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = sp
	q.collision_mask = 1
	q.transform = Transform3D(Basis.IDENTITY, from)
	q.motion = to - from
	return space.cast_motion(q)[0]


func _fly(pts: Array, r: float) -> bool:
	if not _sphere_hits(pts[0], r).is_empty():
		return false
	for i in pts.size() - 1:
		if _cast(pts[i], pts[i + 1], r) < 1.0:
			return false
	return true


# --- contract -----------------------------------------------------------------

func test_contract_signatures_group_and_signal() -> void:
	# Every World contract method keeps the base signature in SoaringWorld.
	var base := {}
	for m in (load("res://scripts/world/world.gd") as Script).get_script_method_list():
		base[m["name"]] = m
	var sub := {}
	for m in (load("res://scripts/world/soaring_world.gd") as Script).get_script_method_list():
		sub[m["name"]] = m
	var bad: PackedStringArray = []
	for name in ["get_wind", "ground_height", "get_perches", "find_perches", "get_player_spawn", "get_landmarks",
			"get_refuges", "get_thermals", "is_inside", "find"]:
		if not base.has(name):
			bad.append("base lacks " + name)
			continue
		if sub.has(name):
			var a: Array = base[name]["args"]
			var b: Array = sub[name]["args"]
			if a.size() != b.size():
				bad.append("%s arg count %d vs %d" % [name, a.size(), b.size()])
			else:
				for i in a.size():
					if a[i]["type"] != b[i]["type"]:
						bad.append("%s arg %d type differs" % [name, i])
			if base[name]["return"]["type"] != sub[name]["return"]["type"]:
				bad.append("%s return type differs" % name)
	eq(bad.size(), 0, "SoaringWorld keeps every World contract signature: %s" % ", ".join(bad))
	check(world.is_in_group(&"world"), "world in group 'world'")
	check(World.find(get_tree()) == world, "World.find finds it")
	eq(generated_count, 1, "generated emitted exactly once")
	check(world.is_generated, "is_generated")
	eq(world.process_mode, Node.PROCESS_MODE_INHERIT, "world is pausable (inherits)")
	# Physics layers: static geometry on layer 1 only (+ perch layer 2 for trees).
	var odd: PackedStringArray = []
	for b in world.get_node("Bodies").get_children():
		var co := b as CollisionObject3D
		if co == null:
			continue
		if (co.collision_layer & 1) == 0 or (co.collision_layer & ~3) != 0:
			odd.append("%s layer %d" % [co.name, co.collision_layer])
	var bnd := world.get_node("Boundary") as CollisionObject3D
	if (bnd.collision_layer & 1) == 0:
		odd.append("Boundary layer %d" % bnd.collision_layer)
	eq(odd.size(), 0, "static geometry on layer 1 (trees also 2): %s" % ", ".join(odd.slice(0, 6)))
	var areas := world.find_children("*", "Area3D", true, false)
	eq(areas.size(), 0, "no Area3D (updrafts are get_wind)")


func test_landmark_refuge_perch_shapes() -> void:
	var bad: PackedStringArray = []
	for l in world.get_landmarks():
		for key in ["name", "kind", "position", "radius"]:
			if not l.has(key):
				bad.append("%s lacks %s" % [l.get("name", "?"), key])
		if l.get("kind", "") == "opening":
			var n: Vector3 = l["normal"]
			var up: Vector3 = l["up"]
			if absf(n.length() - 1.0) > 1e-3 or absf(up.length() - 1.0) > 1e-3 or absf(n.dot(up)) > 0.02:
				bad.append("%s normal/up not orthonormal" % l["name"])
			for key in ["type", "width", "height", "max_span", "depth"]:
				if not l.has(key):
					bad.append("%s lacks %s" % [l["name"], key])
			if float(l.get("max_span", 0.0)) <= 0.0:
				bad.append("%s max_span <= 0" % l["name"])
		if l.has("measure"):
			bad.append("%s leaks the internal 'measure' key" % l["name"])
	for r in world.get_refuges():
		for key in ["name", "position", "radius", "max_span"]:
			if not r.has(key):
				bad.append("refuge lacks %s" % key)
		if float(r.get("max_span", 0.0)) <= 0.0:
			bad.append("refuge %s max_span %.3f" % [r.get("name", "?"), float(r.get("max_span", 0.0))])
	var nonflat := 0
	var nodistrict := 0
	for p in world.get_perches():
		if absf(p.facing.y) > 1e-4 or absf(p.facing.length() - 1.0) > 1e-3:
			nonflat += 1
		if p.district == &"":
			nodistrict += 1
	eq(nonflat, 0, "every perch faces a horizontal unit direction")
	eq(nodistrict, 0, "every perch names its district")
	for th in world.get_thermals():
		for key in ["name", "position", "radius", "strength", "base_strength", "top", "lean"]:
			if not th.has(key):
				bad.append("thermal lacks %s" % key)
	eq(bad.size(), 0, "landmark/refuge/thermal dictionaries follow the contract: %s" % ", ".join(bad.slice(0, 8)))


func test_find_perches_honours_occupants() -> void:
	# The contract: find_perches returns FREE perches. Occupy some and check.
	var ps := world.get_perches()
	var dummy := Bird.new()
	dummy.alive = true
	var taken: Array[Perch] = []
	for i in range(0, ps.size(), 7):
		ps[i].occupant = dummy
		taken.append(ps[i])
	var leaked := 0
	var rng := RandomNumberGenerator.new()
	rng.seed = 404
	for i in 80:
		var pos := Vector3(rng.randf_range(-450, 450), 20, rng.randf_range(-450, 450))
		for p in world.find_perches(pos, rng.randf_range(20, 150), 0.2):
			if p.occupant == dummy:
				leaked += 1
	for p in taken:
		p.occupant = null
	dummy.free()
	eq(leaked, 0, "find_perches never returns an occupied perch (%d occupied)" % taken.size())


# --- determinism, order independent ----------------------------------------------

func _geometry_hash(w: SoaringWorld) -> String:
	# Same definition as world_test._geometry_hash.
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


func _perch_hash(w: SoaringWorld) -> String:
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


func _isolated(seed: int) -> Array:
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


func test_determinism_does_not_depend_on_build_order() -> void:
	# The suite builds seed 1 first in every process. Here seed 4242 and seed 2
	# are built BEFORE a fresh seed 1 (static caches, shape caches, material
	# singletons warmed by other seeds), and seed 1's hashes must equal the
	# main world's (also seed 1, built first in this process) and the suite's
	# published hashes.
	var g_main := _geometry_hash(world)
	var h_main := _perch_hash(world)
	for sd in [4242, 2]:
		var pr := _isolated(sd)
		pr[0].queue_free()
		await wait_frames(1)
	var p1 := _isolated(1)
	var g1 := _geometry_hash(p1[1])
	var h1 := _perch_hash(p1[1])
	p1[0].queue_free()
	await wait_frames(1)
	print("[world-r4eng] geometry hash seed 1 (first): ", g_main)
	print("[world-r4eng] geometry hash seed 1 (after 4242, 2): ", g1)
	print("[world-r4eng] perch hash seed 1: ", h_main, " / ", h1)
	eq(g1, g_main, "seed 1 geometry is the same after other seeds were built")
	eq(h1, h_main, "seed 1 perches/landmarks/refuges the same after other seeds were built")
	eq(g_main, "7377817419b06a81eeeb32326d672bdc16c6fcc5a14fe3ad56a4f61b280fec5e", "geometry hash equals the one the builder published (73778174...)")
	eq(h_main, "150e671d8e5a02642d02bfde15b176e67dc39863e3762eae2a4b139c7a2b187a", "perch hash equals the published one (150e671d...)")


# --- behaviour the suite does not pin -----------------------------------------------

func test_air_moves_at_runtime_without_set_air_time() -> void:
	# "gently drifting/pulsing": the world advances its own air in physics
	# frames; nothing in the suite checks that the runtime wiring does it.
	var a := world.get_thermals()
	var p0: Array[Vector3] = []
	var s0: Array[float] = []
	for th in a:
		p0.append(th["position"])
		s0.append(th["strength"])
	await wait_physics(90)
	var b := world.get_thermals()
	var moved := 0.0
	var pulsed := 0.0
	for i in b.size():
		moved = maxf(moved, ((b[i]["position"] as Vector3) - p0[i]).length())
		pulsed = maxf(pulsed, absf(float(b[i]["strength"]) - s0[i]))
	metric("drift_in_90_ticks_m", moved)
	metric("pulse_in_90_ticks", pulsed)
	gt(moved, 0.001, "thermals drift at runtime")
	gt(pulsed, 1e-4, "thermals pulse at runtime")
	lt(moved, 3.0, "gently (under 3 m in 90 ticks)")
	# Drift speed bound over a long window (set_air_time).
	var worst_v := 0.0
	for t in range(0, 600, 5):
		world.set_air_time(float(t))
		var q := world.get_thermals()
		world.set_air_time(float(t) + 1.0)
		var r := world.get_thermals()
		for i in q.size():
			worst_v = maxf(worst_v, ((r[i]["position"] as Vector3) - (q[i]["position"] as Vector3)).length())
	world.set_air_time(0.0)
	metric("max_drift_speed_mps", worst_v)
	print("[world-r4eng] thermal drift: %.3f m in 90 ticks, pulse %.3f m/s, max drift speed %.2f m/s" % [moved, pulsed, worst_v])
	# (Real thermals drift with the wind at several m/s; a bird circles at
	# 5-15 m/s. 2 m/s is the probe's own bound for "gently".)
	lt(worst_v, 2.0, "thermal drift stays gentle (< 2 m/s)")


func test_tree_embedding_and_hollow_crowns() -> void:
	# How deep each tree's lowest drawn vertex sits in the ground (so a lift
	# mutation can be sized), and whether the crowns on the hollow trunks
	# really stand on the trunk (the suite's check is a 3 m ray that also
	# hits the crown's own trunk collider).
	var lib: TreeLib = world.build.get_meta(&"tree_lib")
	var embeds := PackedFloat32Array()
	var crowns: PackedStringArray = []
	var crown_bad := 0
	for inst in lib.instances:
		var p: Vector3 = inst["pos"]
		var v: Dictionary = lib.variants[inst["v"]]
		var foot := p.y + float(v["foot_y"]) * float(inst["s"])
		if inst["mounted"]:
			# The solid upper trunk under the crown: straight down from 3 m above
			# the crown's foot (past every tree body) the first solid is the
			# trunk's top, and the foot must be at or below it (within 5 cm).
			# Tree bodies are the only static bodies on the perch layer (2).
			var ex: Array[RID] = []
			for b in world.get_node("Bodies").find_children("*", "CollisionObject3D", true, false):
				if ((b as CollisionObject3D).collision_layer & 2) != 0:
					ex.append((b as CollisionObject3D).get_rid())
			var q := PhysicsRayQueryParameters3D.create(Vector3(p.x, foot + 3.0, p.z), Vector3(p.x, foot - 3.0, p.z))
			q.collision_mask = 1
			q.exclude = ex
			var h := space.intersect_ray(q)
			var gap := INF if h.is_empty() else foot - (h["position"] as Vector3).y
			if gap > 0.05:
				crown_bad += 1
			crowns.append("%s foot %.2f above trunk top (%s)" % [p.snapped(Vector3.ONE * 0.1), gap, "none" if h.is_empty() else String((h["collider"] as Node).name)])
			continue
		embeds.append(world.terrain.height_at(p.x, p.z) - foot)
	embeds.sort()
	var feet := {}
	for v in lib.variants:
		feet[TreeLib.Species.keys()[v["species"]]] = snappedf(float(v["foot_y"]), 0.01)
	print("[world-r4eng] variant foot_y (local, before scale): ", feet)
	var n := embeds.size()
	print("[world-r4eng] tree foot embedding (m): min %.3f p10 %.3f median %.3f max %.3f over %d trees" % [embeds[0], embeds[n / 10], embeds[n / 2], embeds[n - 1], n])
	print("[world-r4eng] hollow crowns: ", crowns)
	metric("tree_embed", {"min": embeds[0], "p10": embeds[n / 10], "median": embeds[n / 2], "max": embeds[n - 1]})
	gt(embeds[0], -0.05, "every tree's foot touches or sinks into the ground")
	gt(float(crowns.size()), 0.0, "hollow crowns found")
	eq(crown_bad, 0, "every hollow-tree crown's foot is within 5 cm of the trunk top under it: %s" % ", ".join(crowns))


func test_fly_through_houses_front_to_back() -> void:
	# The brief: open windows front AND back you can fly through, room
	# between. The suite flies each window straight in to `depth`; here the
	# rated bird flies in the front window, across the room and OUT of the
	# back window (the 'window' landmark's exit), as one path.
	var ops := {}
	for o in world.get_openings():
		ops[o["name"]] = o
	var n := 0
	var bad: PackedStringArray = []
	for l in world.get_landmarks():
		if l["kind"] != "window":
			continue
		n += 1
		var base := String(l["name"]).trim_suffix("_window")
		var f: Dictionary = ops.get(base + "_front_window", {})
		var bk: Dictionary = ops.get(base + "_back_window", {})
		if f.is_empty() or bk.is_empty():
			bad.append("%s: openings missing" % base)
			continue
		var span := minf(float(f["max_span"]), float(bk["max_span"]))
		var r := k_body * span
		var fp: Vector3 = f["position"]
		var fnrm: Vector3 = f["normal"]
		var bp: Vector3 = bk["position"]
		var bn: Vector3 = bk["normal"]
		var path := [fp + fnrm * (r + 1.0), fp - fnrm * 0.4, bp - bn * 0.4, bp + bn * (r + 1.0)]
		if not _fly(path, r):
			bad.append("%s (span %.2f)" % [base, span])
		# A straight line too (how a bird actually shoots a house).
		if not _fly([fp + fnrm * (r + 1.0), bp + bn * (r + 1.0)], r * 0.8):
			bad.append("%s straight line (0.8 x rated)" % base)
	metric("fly_through_houses", n)
	gt(float(n), 7.0, ">= 8 fly-through houses")
	eq(bad.size(), 0, "rated bird flies in the front window and out of the back: %s" % ", ".join(bad))


func test_spawn_is_launchable() -> void:
	# The spawn perch: a sparrow (0.24 m) fits there and can launch forward
	# and glide down 20 m without hitting anything.
	var sp := world.get_player_spawn()
	var r := k_body * 0.24
	var body := sp.origin + Vector3.UP * (r + 0.03)
	eq(_sphere_hits(body, r).size(), 0, "spawn body clear")
	var fwd := -sp.basis.z
	var end := body + fwd * 20.0 + Vector3.DOWN * 4.0
	gt(_cast(body, end, r), 0.999, "a 20 m launch glide from the spawn is clear")


func test_is_inside_rejects_solid_ground() -> void:
	# is_inside must say "no" inside the ground and the rock masses.
	var rng := RandomNumberGenerator.new()
	rng.seed = 77
	var wrong := 0
	var n := 0
	for i in 3000:
		var q := Vector2.from_angle(rng.randf() * TAU) * sqrt(rng.randf()) * (world.bounds_radius - 5.0)
		var g := world.ground_height(q.x, q.y)
		if g > world.ceiling - 5.0:
			continue
		n += 1
		if world.is_inside(Vector3(q.x, g - 3.0, q.y)):
			wrong += 1
	metric("is_inside_underground_samples", n)
	eq(wrong, 0, "is_inside is false 3 m under the solid ground (%d samples)" % n)


func test_perch_ratings_are_sensible() -> void:
	# Ratings match what a real perch holds: wires and nest rims are small-
	# bird perches; branches' ratings scale with the wood under them.
	var by_kind := {}
	var wire_big := 0
	var nest_big := 0
	for p in world.get_perches():
		var k: String = Perch.Kind.keys()[p.kind]
		if not by_kind.has(k):
			by_kind[k] = [INF, 0.0]
		by_kind[k][0] = minf(by_kind[k][0], p.max_span)
		by_kind[k][1] = maxf(by_kind[k][1], p.max_span)
		if p.kind == Perch.Kind.WIRE and p.max_span > 1.1:
			wire_big += 1
		if p.kind == Perch.Kind.NEST and p.max_span > 0.5:
			nest_big += 1
	metric("span_range_by_kind", by_kind)
	print("[world-r4eng] perch span range by kind ", by_kind)
	eq(wire_big, 0, "no wire is rated for a gull or bigger")
	eq(nest_big, 0, "no nest-box rim is rated above a starling")


func test_clouds_follow_the_light() -> void:
	# set_lighting() is the public way to change the light (shot_dusk uses
	# it). Palette.LIGHT.dusk defines its own cloud colours; check the built
	# clouds take them.
	var clouds := world.get_node("Soft").find_child("clouds", false, false) as MeshInstance3D
	check(clouds != null, "clouds exist")
	if clouds == null:
		return
	var before: PackedColorArray = clouds.mesh.surface_get_arrays(0)[Mesh.ARRAY_COLOR]
	world.set_lighting(&"dusk")
	var mat_after := clouds.material_override
	var after: PackedColorArray = clouds.mesh.surface_get_arrays(0)[Mesh.ARRAY_COLOR]
	world.set_lighting(&"day")
	var day_c: Color = Palette.LIGHT[&"day"]["cloud"]
	var dusk_c: Color = Palette.LIGHT[&"dusk"]["cloud"]
	print("[world-r4eng] cloud vertex colour before %s after dusk %s (palette day %s, dusk %s), material %s" % [before[0], after[0], day_c, dusk_c, mat_after])
	check(before != after or mat_after != Palette.cloud_material(), "set_lighting(dusk) re-tints the clouds (Palette.LIGHT.dusk.cloud)")


func test_refuges_admit_their_bird_and_keep_bigger_ones_out() -> void:
	# get_refuges contract: "A bird whose wingspan exceeds max_span cannot
	# follow inside." Heuristic: the rated body fits at the refuge point, and
	# a body 30% bigger either does not fit there or cannot fly straight out
	# to open air (26 directions, 40 m) from it.
	var dirs: Array[Vector3] = []
	for x in [-1, 0, 1]:
		for y in [-1, 0, 1]:
			for z in [-1, 0, 1]:
				if x != 0 or y != 0 or z != 0:
					dirs.append(Vector3(x, y, z).normalized())
	var no_fit: PackedStringArray = []
	var leaky: PackedStringArray = []
	var by_kind := {}
	for rf in world.get_refuges():
		var nm := String(rf["name"])
		var kind := nm.rstrip("0123456789_")
		by_kind[kind] = by_kind.get(kind, 0) + 1
		var p: Vector3 = rf["position"]
		var r := k_body * float(rf["max_span"])
		if not _sphere_hits(p, r).is_empty():
			no_fit.append("%s (span %.2f)" % [nm, rf["max_span"]])
		var rb := r * 1.3
		if _sphere_hits(p, rb).is_empty():
			for d in dirs:
				if _cast(p, p + d * 40.0, rb) >= 1.0:
					leaky.append("%s (span %.2f) out along %s" % [nm, rf["max_span"], d.snapped(Vector3.ONE * 0.01)])
					break
	metric("refuges_by_kind", by_kind)
	metric("refuge_no_fit", Array(no_fit))
	metric("refuge_leaky", Array(leaky))
	print("[world-r4eng] refuges %d: rated body does not fit at %d: %s" % [world.get_refuges().size(), no_fit.size(), ", ".join(no_fit.slice(0, 12))])
	print("[world-r4eng] refuges a 30%%-bigger bird can fly straight out of: %d: %s" % [leaky.size(), ", ".join(leaky.slice(0, 12))])
	eq(no_fit.size(), 0, "the rated bird fits at every refuge point")
	eq(leaky.size(), 0, "no 30%-bigger bird can fly straight out of a refuge")
