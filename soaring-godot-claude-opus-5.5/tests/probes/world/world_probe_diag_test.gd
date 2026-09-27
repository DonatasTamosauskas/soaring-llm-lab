extends TestCase
## Verifier diagnostics (round 1, engineering lens): explains the failures of
## world_probe_test.gd so the report can say what is wrong and where.
##
##   tools/gd.sh world_verify2 --headless res://tests/runner.tscn -- --dir=res://tests/probes/world --suite=world_probe_diag

var world: SoaringWorld
var space: PhysicsDirectSpaceState3D
var ground_rids: Array[RID] = []


func before_all() -> void:
	world = load("res://scenes/world/world.tscn").instantiate()
	add_child(world)
	await wait_physics(2)
	space = world.get_world_3d().direct_space_state
	var stack: Array[Node] = [world]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is StaticBody3D:
			var nm := String(n.name)
			if nm.begins_with("terrain_") or nm.begins_with("water") or nm == "Boundary" or nm.begins_with("backdrop"):
				ground_rids.append((n as StaticBody3D).get_rid())
		for c in n.get_children():
			stack.append(c)


func after_all() -> void:
	if world:
		world.queue_free()


func _ray(a: Vector3, b: Vector3, exclude: Array[RID]) -> Dictionary:
	var q := PhysicsRayQueryParameters3D.create(a, b)
	q.collision_mask = 1
	q.exclude = exclude
	q.hit_from_inside = true
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


## For footprints with nothing solid at ground level: how high is the lowest
## solid thing above the ground right there?
func test_diag_w6_gaps() -> void:
	var by_kind := {}
	var worst := {}
	var sph := SphereShape3D.new()
	sph.radius = 0.15
	for fp in world.build.footprints:
		var nm: String = fp["name"]
		if nm.ends_with("_back"):
			continue
		var kind := nm.rstrip("0123456789").trim_suffix("_")
		var best_gap := INF
		var touched := false
		for q in (fp["points"] as PackedVector2Array):
			var g := world.terrain.height_at(q.x, q.y)
			var qq := PhysicsShapeQueryParameters3D.new()
			qq.shape = sph
			qq.collision_mask = 1
			qq.exclude = ground_rids
			qq.transform = Transform3D(Basis.IDENTITY, Vector3(q.x, g + 0.12, q.y))
			if not space.intersect_shape(qq, 1).is_empty():
				touched = true
				break
			# Lowest solid above the ground within 0.6 m horizontally.
			for o in [Vector2.ZERO, Vector2(0.3, 0), Vector2(-0.3, 0), Vector2(0, 0.3), Vector2(0, -0.3), Vector2(0.6, 0), Vector2(-0.6, 0), Vector2(0, 0.6), Vector2(0, -0.6)]:
				var p: Vector2 = q + o
				var gg := world.terrain.height_at(p.x, p.y)
				var hit := _ray(Vector3(p.x, gg + 0.01, p.y), Vector3(p.x, gg + 30.0, p.y), ground_rids)
				if not hit.is_empty():
					best_gap = minf(best_gap, (hit["position"] as Vector3).y - gg)
		if touched:
			continue
		by_kind[kind] = by_kind.get(kind, 0) + 1
		if not worst.has(kind) or best_gap > worst[kind][0]:
			var pts: PackedVector2Array = fp["points"]
			worst[kind] = [best_gap, pts[0]]
	metric("untouched_by_kind", by_kind)
	var out := {}
	for k in worst:
		out[k] = "gap %.2f m at %s" % [worst[k][0], worst[k][1]]
	metric("untouched_worst", out)
	print("[world-verify] W6 diag untouched by kind: %s" % by_kind)
	print("[world-verify] W6 diag worst gap per kind (INF = nothing above within 30 m / 0.6 m): %s" % out)
	# Trimesh faces are one-sided (a probe inside a solid sees nothing), so
	# look from OUTSIDE: 8 horizontal rays at 10 cm above the local ground
	# toward each footprint point, from `reach` m away. Grounded objects are
	# hit; floating ones are passed under.
	var none: PackedStringArray = []
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
			for k in 8:
				var a := TAU * k / 8.0
				var d := Vector3(cos(a), 0, sin(a))
				var from := Vector3(q.x, g + 0.1, q.y) + d * reach
				var h := _ray(from, Vector3(q.x, g + 0.1, q.y) - d * reach, ground_rids)
				if not h.is_empty():
					hit_any = true
					break
			if hit_any:
				break
		if not hit_any:
			none.append("%s@(%.0f,%.0f)" % [nm, (fp["points"] as PackedVector2Array)[0].x, (fp["points"] as PackedVector2Array)[0].y])
	metric("side_ray_ungrounded", Array(none))
	print("[world-verify] W6 side-ray probe: %d footprints, %d with nothing solid at 10 cm above ground: %s" % [n, none.size(), ", ".join(none.slice(0, 20))])
	check(true, "diagnostic")


## Perches whose rated bird has no straight approach: in which of 26
## directions is there a clear 2 m+ corridor?
func test_diag_w3_boxed() -> void:
	var dirs: Array[Vector3] = []
	for dy in [-1, 0, 1]:
		for dx in [-1, 0, 1]:
			for dz in [-1, 0, 1]:
				if dx == 0 and dy == 0 and dz == 0:
					continue
				dirs.append(Vector3(dx, dy, dz).normalized())
	var k := WorldBuild.body_k()
	var boxed := 0
	var boxed_small := 0
	var by_span := {}
	var examples: PackedStringArray = []
	var what_blocks := {}
	for p in world.get_perches():
		var r := k * p.max_span
		var c := p.position + Vector3.UP * (r + 0.03)
		var free := false
		for d in dirs:
			if _cast(c, c + d * maxf(2.0, 6.0 * r), r) >= 1.0:
				free = true
				break
		if free:
			continue
		boxed += 1
		# Would the smallest bird (wren) get in?
		var rw := k * float(SizeRules.SPECIES[1]["span"])
		var cw := p.position + Vector3.UP * (rw + 0.03)
		var free_w := false
		for d in dirs:
			if _cast(cw, cw + d * 2.0, rw) >= 1.0:
				free_w = true
				break
		if not free_w:
			boxed_small += 1
		var bucket := "%.1f" % snappedf(p.max_span, 0.5)
		by_span[bucket] = by_span.get(bucket, 0) + 1
		# What is right above it?
		var hit := _ray(c, c + Vector3.UP * 3.0, [])
		var who := "nothing" if hit.is_empty() else String((hit["collider"] as Node).name).rstrip("0123456789")
		what_blocks[who] = what_blocks.get(who, 0) + 1
		if examples.size() < 6:
			examples.append("%s %s span %.2f %s" % [Perch.Kind.keys()[p.kind], p.position, p.max_span, p.district])
	metric("boxed_26dirs", boxed)
	metric("boxed_even_for_wren", boxed_small)
	metric("boxed_by_span", by_span)
	print("[world-verify] W3 diag: %d perches with no straight 26-direction approach for their rated bird; %d not even for a wren; spans %s; above: %s; e.g. %s" % [boxed, boxed_small, by_span, what_blocks, "; ".join(examples)])
	check(true, "diagnostic")


## Where is the wind gradient steep, restricted to the playable volume?
func test_diag_w4_gradient_inside() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 99
	var worst := 0.0
	var worst_at := Vector3.ZERO
	var n_over := 0
	var n := 0
	for t: float in [0.0, 55.0, 140.0]:
		world.set_air_time(t)
		for i in 60000:
			var p := Vector3(rng.randf_range(-680, 680), rng.randf_range(0.0, 300.0), rng.randf_range(-680, 680))
			if not world.is_inside(p):
				continue
			n += 1
			var d := Vector3(rng.randf_range(-1, 1), rng.randf_range(-1, 1), rng.randf_range(-1, 1)).normalized() * 0.25
			var g := (world.get_wind(p + d) - world.get_wind(p)).length() / 0.25
			if g > 0.6:
				n_over += 1
			if g > worst:
				worst = g
				worst_at = p
	metric("inside_worst_gradient", worst)
	metric("inside_over_0_6", [n_over, n])
	print("[world-verify] W4 diag inside arena: worst %.3f at %s (r=%.0f, agl %.1f), %d/%d samples > 0.6" % [worst, worst_at, Vector2(worst_at.x, worst_at.z).length(), worst_at.y - world.ground_height(worst_at.x, worst_at.z), n_over, n])
	# Per-thermal: measured core minus API strength (other lift sources add).
	world.set_air_time(0.0)
	var ths := world.get_thermals()
	var out := {}
	for i in ths.size():
		var th: Dictionary = ths[i]
		var g: float = (th["position"] as Vector3).y
		var worst_e := 0.0
		var y := g + 30.0
		while y < float(th["top"]) - 55.0:
			var c := world.wind.thermal_center(i, y)
			var e := world.get_wind(c).y - float(th["strength"])
			if absf(e) > absf(worst_e):
				worst_e = e
			y += 5.0
		out[th["name"]] = snappedf(worst_e, 0.001)
	metric("core_minus_strength", out)
	print("[world-verify] W4 diag core - strength per thermal: %s" % out)
	check(true, "diagnostic")


func test_diag_duplicate_names_and_docs() -> void:
	var seen := {}
	var dups: PackedStringArray = []
	for l in world.get_landmarks():
		if seen.has(l["name"]):
			dups.append("%s (%s)" % [l["name"], l["kind"]])
		seen[l["name"]] = true
	var through := 0
	for l in world.get_landmarks():
		if l["kind"] == "window" and String(l["name"]).begins_with("house_"):
			through += 1
	metric("dup_names", Array(dups))
	metric("village_through_houses", through)
	print("[world-verify] duplicate landmark names: %s; village fly-through houses: %d; trees: %d" % [", ".join(dups), through, (world.build.get_meta(&"tree_lib") as TreeLib).instances.size()])
	check(true, "diagnostic")
