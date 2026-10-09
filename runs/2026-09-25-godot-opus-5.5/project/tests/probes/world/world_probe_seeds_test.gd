extends TestCase
## Verifier probe (round 1): the world criteria on seeds the builder's suite
## never checks in depth (it only hashes seed 2). Each seed is generated in
## its own physics space (SubViewport with own_world_3d), checked, then freed.
##
##   tools/gd.sh wv_exp --headless res://tests/runner.tscn -- --dir=res://tests/probes/world --suite=seeds

const SEEDS := [2, 3, 17, 4242, 90001]

var k_body := 0.16
var space: PhysicsDirectSpaceState3D


func _ray(a: Vector3, b: Vector3) -> Dictionary:
	var q := PhysicsRayQueryParameters3D.create(a, b)
	q.collision_mask = 1
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


func test_criteria_hold_on_other_seeds() -> void:
	k_body = WorldBuild.body_k()
	var summary := {}
	for sd in SEEDS:
		var vp := SubViewport.new()
		vp.own_world_3d = true
		vp.size = Vector2i(8, 8)
		vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
		add_child(vp)
		var w: SoaringWorld = load("res://scenes/world/world.tscn").instantiate()
		w.world_seed = sd
		vp.add_child(w)
		await wait_physics(2)
		space = w.get_world_3d().direct_space_state
		var r := _check(w)
		r["generation_ms"] = snappedf(w.generation_ms, 1.0)
		summary[str(sd)] = r
		print("[world-verify] seed %d: %s" % [sd, r])
		lt(w.generation_ms, 2000.0, "seed %d generates < 2 s" % sd)
		gt(float(r["perches"]), 399.0, "seed %d >= 400 perches" % sd)
		gt(float(r["openings"]), 19.0, "seed %d >= 20 openings" % sd)
		gt(float(r["opening_types"]), 3.0, "seed %d >= 4 opening types" % sd)
		eq(r["opening_fail"], [], "seed %d every opening flyable, real hole, tight" % sd)
		eq(r["perch_no_support"], 0, "seed %d perches supported" % sd)
		eq(r["perch_no_clear"], 0, "seed %d perches clear" % sd)
		eq(r["float"], [], "seed %d nothing floats" % sd)
		eq(r["buried"], [], "seed %d nothing over-buried" % sd)
		eq(r["escapes"], 0, "seed %d arena closed" % sd)
		eq(r["window_blocked"], [], "seed %d windows fly-through" % sd)
		check(bool(r["spawn_ok"]), "seed %d spawn sits on geometry with room" % sd)
		gt(float(r["trees"]), 150.0, "seed %d >= 150 trees" % sd)
		vp.queue_free()
		await wait_frames(2)
	metric("seeds", summary)


func _check(w: SoaringWorld) -> Dictionary:
	var out := {}
	# Counts.
	out["perches"] = w.get_perches().size()
	var ops := w.get_openings()
	out["openings"] = ops.size()
	var types := {}
	var fails := []
	for o in ops:
		types[o["type"]] = true
		var span: float = o["max_span"]
		var p: Vector3 = o["position"]
		var n: Vector3 = o["normal"]
		var up: Vector3 = o["up"]
		var r := k_body * span
		var outside := p + n * (r + 1.0)
		var inside := p - n * float(o["depth"])
		if _cast(outside, inside, r) < 1.0:
			fails.append("%s blocked" % o["name"])
			continue
		var right := up.cross(n).normalized()
		var c := p - n * 0.008
		for d in [[right, float(o["width"])], [-right, float(o["width"])], [up, float(o["height"])], [-up, float(o["height"])]]:
			if _ray(c, c + (d[0] as Vector3) * (float(d[1]) * 0.5 * 1.35 + 0.1)).is_empty():
				fails.append("%s open side" % o["name"])
				break
		if _cast(outside, inside, r * 1.3) >= 1.0:
			fails.append("%s loose" % o["name"])
	out["opening_types"] = types.size()
	out["opening_fail"] = fails.slice(0, 8)
	# Perches.
	var ns := 0
	var nc := 0
	for p in w.get_perches():
		var hit := _ray(p.position + Vector3.UP * 0.1, p.position + Vector3.DOWN * 0.15)
		if hit.is_empty() or absf((hit["position"] as Vector3).y - p.position.y) > 0.03:
			ns += 1
		var rr := k_body * p.max_span
		if _overlaps(p.position + Vector3.UP * (rr + 0.02), rr):
			nc += 1
	out["perch_no_support"] = ns
	out["perch_no_clear"] = nc
	# Footprints.
	var fl := []
	var bu := []
	for fp in w.build.footprints:
		var base: float = fp["base_y"]
		for q in (fp["points"] as PackedVector2Array):
			var g := w.terrain.height_at(q.x, q.y)
			if base > g + 0.05:
				fl.append("%s %.2f" % [fp["name"], base - g])
				break
			if base < g - float(fp["max_embed"]) - 0.01:
				bu.append("%s %.2f" % [fp["name"], g - base])
				break
	out["float"] = fl.slice(0, 6)
	out["buried"] = bu.slice(0, 6)
	var lib: TreeLib = w.build.get_meta(&"tree_lib")
	out["trees"] = lib.instances.size()
	# Arena (reduced sweep: 120 bearings x 4 altitudes).
	var R := w.bounds_radius
	var esc := 0
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
			var hit := _ray(p0, far)
			if hit.is_empty() or Vector2((hit["position"] as Vector3).x, (hit["position"] as Vector3).z).length() > R + 0.6:
				esc += 1
			elif _cast(p0, far, 0.02) >= 1.0:
				esc += 1
	out["escapes"] = esc
	# Windows all the way through.
	var wb := []
	for l in w.get_landmarks():
		if l["kind"] != "window":
			continue
		var a: Vector3 = l["position"]
		var b: Vector3 = l["exit"]
		var d := (b - a).normalized()
		var rr := k_body * float(l["max_span"])
		if _cast(a - d * (rr + 2.0), b + d * (rr + 2.0), rr) < 1.0:
			wb.append(l["name"])
	out["window_blocked"] = wb
	# Spawn.
	var sp := w.get_player_spawn()
	var sr := k_body * 0.24
	out["spawn_ok"] = not _ray(sp.origin + Vector3.UP * 0.1, sp.origin + Vector3.DOWN * 0.2).is_empty() \
		and not _overlaps(sp.origin + Vector3.UP * (sr + 0.02), sr) and w.is_inside(sp.origin + Vector3.UP * 0.5)
	return out
