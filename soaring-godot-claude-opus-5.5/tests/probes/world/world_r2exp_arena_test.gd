extends TestCase
## Verifier probe (round 2, experience & requirements lens): is the arena
## closed for a BODY THAT ACTUALLY MOVES, not only for long sweep queries?
##
##   tools/gd.sh world_verify --headless res://tests/runner.tscn -- --dir=res://tests/probes/world --suite=r2exp_arena
##
## Round-1 probes report "sphere escapes" from 2.5 km cast_motion sweeps, and
## the seeds probe reports one escape on seed 17. The builder says long Jolt
## sweeps are unreliable and the arena is closed. Settle it physically:
## replay those exact rays with a CharacterBody3D pushed by move_and_collide
## (the collision path a flying bird would use) in short steps, and add
## adversarial pushes: every corner of the 96-gon boundary at many heights,
## and thousands of random bodies of every bird size flying outward/upward.
## A real escape = a body ends beyond the boundary polygon or above the lid.

var world: SoaringWorld
var space: PhysicsDirectSpaceState3D
var probe_body: CharacterBody3D
var probe_shape: SphereShape3D


func before_all() -> void:
	world = load("res://scenes/world/world.tscn").instantiate()
	world.with_decoration = false
	add_child(world)
	await wait_physics(2)
	space = world.get_world_3d().direct_space_state
	probe_body = _make_body(self)


func after_all() -> void:
	if world:
		world.queue_free()


func _make_body(parent: Node) -> CharacterBody3D:
	var b := CharacterBody3D.new()
	b.collision_layer = 0
	b.collision_mask = 1
	var cs := CollisionShape3D.new()
	probe_shape = SphereShape3D.new()
	probe_shape.radius = 0.02
	cs.shape = probe_shape
	b.add_child(cs)
	parent.add_child(b)
	return b


func _ray(s: PhysicsDirectSpaceState3D, a: Vector3, b: Vector3) -> Dictionary:
	var q := PhysicsRayQueryParameters3D.create(a, b)
	q.collision_mask = 1
	return s.intersect_ray(q)


func _cast(s: PhysicsDirectSpaceState3D, from: Vector3, to: Vector3, r: float) -> float:
	var sp := SphereShape3D.new()
	sp.radius = r
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = sp
	q.collision_mask = 1
	q.transform = Transform3D(Basis.IDENTITY, from)
	q.motion = to - from
	var res := s.cast_motion(q)
	return res[0] if res.size() > 0 else 1.0


## Pushes body (radius r) from p along d for up to dist metres in step-metre
## moves. Returns [escaped, final position, blocked].
func _fly(body: CharacterBody3D, w: SoaringWorld, p: Vector3, d: Vector3, dist: float, r: float, step := 4.0) -> Array:
	(body.get_child(0) as CollisionShape3D).shape.radius = r
	body.global_position = p
	var moved := 0.0
	var poly_r := w.bounds_radius / cos(PI / 96.0)
	while moved < dist:
		var m := minf(step, dist - moved)
		var col := body.move_and_collide(d * m, false, 0.001)
		var pos := body.global_position
		if Vector2(pos.x, pos.z).length() > poly_r + 1.0 or pos.y > w.ceiling + 1.0:
			return [true, pos, false]
		if col != null:
			return [false, pos, true]
		moved += m
	return [false, body.global_position, false]


# --- 1. the round-1 "sphere escapes", replayed with a moving body ----------

func test_round1_sphere_escapes_with_a_moving_body() -> void:
	# The exact loop of world_probe_test.test_w1_random_3d_escape (rng 4242).
	var R := world.bounds_radius
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	var n := 0
	var cast_escapes := 0
	var body_escapes := 0
	var body_escapes_wren := 0
	var seg_escapes := 0
	var examples: Array = []
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
		var d := Vector3(rng.randf_range(-1, 1), rng.randf_range(-0.2, 1.0), rng.randf_range(-1, 1)).normalized()
		var far := p + d * 2500.0
		n += 1
		if _cast(space, p, far, 0.02) < 1.0:
			continue
		cast_escapes += 1
		# Physical flight with a 2 cm body and a wren-sized body.
		var f1 := _fly(probe_body, world, p, d, 2500.0, 0.02)
		var f2 := _fly(probe_body, world, p, d, 2500.0, 0.16 * 0.16)
		if f1[0]:
			body_escapes += 1
		if f2[0]:
			body_escapes_wren += 1
		# The same sweep cut into 20 m casts, each from a clear start.
		var s := 0.0
		var seg_escaped := true
		while s < 2500.0:
			var a0 := p + d * s
			var sp := SphereShape3D.new()
			sp.radius = 0.02
			var q := PhysicsShapeQueryParameters3D.new()
			q.shape = sp
			q.collision_mask = 1
			q.transform = Transform3D(Basis.IDENTITY, a0)
			if not space.intersect_shape(q, 1).is_empty() or _cast(space, a0, a0 + d * 20.0, 0.02) < 1.0:
				seg_escaped = false
				break
			s += 20.0
		if seg_escaped:
			seg_escapes += 1
		if examples.size() < 6:
			examples.append("from %s dir %s: body stopped at r=%.1f y=%.1f" % [p.snapped(Vector3.ONE * 0.1), d.snapped(Vector3.ONE * 0.01),
				Vector2((f1[1] as Vector3).x, (f1[1] as Vector3).z).length(), (f1[1] as Vector3).y])
	print("[world-r2exp] round-1 replay: %d rays, %d long-cast 'escapes'; moving 2 cm body escapes %d, wren body %d; 20 m segmented casts escape %d" % [
		n, cast_escapes, body_escapes, body_escapes_wren, seg_escapes])
	print("[world-r2exp]   e.g. ", examples)
	metric("round1_replay", {"rays": n, "long_cast_escapes": cast_escapes, "body_escapes": body_escapes,
		"wren_body_escapes": body_escapes_wren, "segmented_cast_escapes": seg_escapes})
	gt(float(cast_escapes), 0.0, "the long-cast artefact still reproduces (sanity: we replayed the same rays)")
	eq(body_escapes, 0, "no moving 2 cm body leaves along any of those rays")
	eq(body_escapes_wren, 0, "no moving wren-sized body leaves along any of those rays")
	eq(seg_escapes, 0, "no 20 m segmented sweep leaves along any of those rays")


# --- 2. adversarial pushes: 96-gon corners and random bodies ----------------

func _corner_and_random_pushes(w: SoaringWorld, body: CharacterBody3D, rng_seed: int, n_random: int) -> Dictionary:
	var R := w.bounds_radius
	var corner_tries := 0
	var corner_esc: Array = []
	for i in 96:
		# Box i spans angles (i .. i+1) * TAU / 96 around its centre (i + 0.5).
		var ang := TAU * float(i) / 96.0
		var dir := Vector3(cos(ang), 0, sin(ang))
		for y0: float in [15.0, 60.0, 120.0, 180.0, 240.0, 285.0, 297.0, 299.5]:
			var rs := R - 20.0
			while rs > 0.0 and w.ground_height(dir.x * rs, dir.z * rs) > y0 - 1.0:
				rs -= 10.0
			if rs < R - 300.0:
				continue
			var p := dir * rs + Vector3(0, y0, 0)
			corner_tries += 1
			for r: float in [0.005, 0.02]:
				var f := _fly(body, w, p, dir, 400.0, r, 2.0)
				if f[0]:
					corner_esc.append("corner %d y %.0f r %.3f -> %s" % [i, y0, r, (f[1] as Vector3).snapped(Vector3.ONE * 0.1)])
			# Also diagonally up into the wall/lid seam.
			var up := (dir + Vector3.UP * 0.35).normalized()
			var fu := _fly(body, w, p, up, 600.0, 0.005, 2.0)
			if fu[0]:
				corner_esc.append("corner %d y %.0f up -> %s" % [i, y0, (fu[1] as Vector3).snapped(Vector3.ONE * 0.1)])
	var rng := RandomNumberGenerator.new()
	rng.seed = rng_seed
	var radii: Array[float] = [0.005, 0.02, 0.0384, 0.1056, 0.208, 0.336]
	var rnd_esc: Array = []
	var tries := 0
	var at_wall := 0
	var travelled := 0.0
	while tries < n_random:
		var a := rng.randf() * TAU
		var rr := sqrt(rng.randf()) * (R - 3.0)
		var x := cos(a) * rr
		var z := sin(a) * rr
		var g := w.ground_height(x, z)
		if g > w.ceiling - 4.0:
			continue
		var r: float = radii[tries % radii.size()]
		var p := Vector3(x, rng.randf_range(g + 1.0 + r, w.ceiling - 1.0 - r), z)
		# Outward-biased random direction (a fleeing bird heads for the edge).
		var out := Vector3(x, 0, z).normalized()
		var d := (out * rng.randf_range(0.2, 1.0) + Vector3(rng.randf_range(-1, 1), rng.randf_range(-0.3, 0.8), rng.randf_range(-1, 1))).normalized()
		tries += 1
		var f := _fly(body, w, p, d, 1600.0, r, 6.0)
		var fp: Vector3 = f[1]
		travelled += fp.distance_to(p)
		if Vector2(fp.x, fp.z).length() > R - r - 1.0 or fp.y > w.ceiling - r - 1.0:
			at_wall += 1
		if f[0]:
			rnd_esc.append("r %.3f from %s dir %s -> %s" % [r, p.snapped(Vector3.ONE * 0.1), d.snapped(Vector3.ONE * 0.01), (f[1] as Vector3).snapped(Vector3.ONE * 0.1)])
	return {"corner_tries": corner_tries, "corner_escapes": corner_esc, "random_tries": tries, "random_escapes": rnd_esc,
		"random_stopped_by_wall_or_lid": at_wall, "random_mean_travel_m": travelled / maxf(tries, 1)}


func test_adversarial_pushes_seed1() -> void:
	var res := _corner_and_random_pushes(world, probe_body, 777, 1500)
	print("[world-r2exp] seed 1 pushes: corners %d (x3 bodies), escapes %s; random bodies %d, escapes %s" % [
		res["corner_tries"], (res["corner_escapes"] as Array).slice(0, 6), res["random_tries"], (res["random_escapes"] as Array).slice(0, 6)])
	print("[world-r2exp] seed 1 random bodies stopped by the wall/lid: %d, mean travel %.0f m" % [res["random_stopped_by_wall_or_lid"], res["random_mean_travel_m"]])
	gt(float(res["random_stopped_by_wall_or_lid"]), 50.0, "sanity: many random bodies really reach the invisible wall or lid")
	metric("seed1_pushes", {"corner_tries": res["corner_tries"], "corner_escapes": (res["corner_escapes"] as Array).size(),
		"stopped_by_wall_or_lid": res["random_stopped_by_wall_or_lid"], "mean_travel": res["random_mean_travel_m"],
		"random_tries": res["random_tries"], "random_escapes": (res["random_escapes"] as Array).size()})
	eq((res["corner_escapes"] as Array).size(), 0, "no body escapes through a boundary corner or the wall/lid seam")
	eq((res["random_escapes"] as Array).size(), 0, "no random outward-flying body of any bird size escapes")


# --- 3. seed 17: the round-1 seeds probe's escape ---------------------------

func test_seed17_escape_is_real_or_not() -> void:
	var vp := SubViewport.new()
	vp.own_world_3d = true
	vp.size = Vector2i(8, 8)
	vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(vp)
	var w: SoaringWorld = load("res://scenes/world/world.tscn").instantiate()
	w.world_seed = 17
	w.with_decoration = false
	vp.add_child(w)
	await wait_physics(2)
	var s := w.get_world_3d().direct_space_state
	var body := _make_body(vp)
	var R := w.bounds_radius
	# The seeds probe's reduced sweep, verbatim, recording which case escapes.
	var found: Array = []
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
			var hit := _ray(s, p0, far)
			var ray_escape := hit.is_empty() or Vector2((hit["position"] as Vector3).x, (hit["position"] as Vector3).z).length() > R + 0.6
			var cast_escape := (not ray_escape) and _cast(s, p0, far, 0.02) >= 1.0
			if ray_escape or cast_escape:
				var f := _fly(body, w, p0, dir, p0.distance_to(far), 0.02, 2.0)
				var hit_name := "" if hit.is_empty() else String((hit["collider"] as Node).name)
				var hit_r := -1.0 if hit.is_empty() else Vector2((hit["position"] as Vector3).x, (hit["position"] as Vector3).z).length()
				found.append({"bearing_deg": snappedf(rad_to_deg(a), 0.1), "y": snappedf(y, 0.1), "from_r": rs,
					"ray_escape": ray_escape, "cast_escape": cast_escape, "ray_hit": hit_name, "ray_hit_r": snappedf(hit_r, 0.01),
					"cast_len": snappedf(p0.distance_to(far), 1.0), "body_escaped": f[0], "body_stop": (f[1] as Vector3).snapped(Vector3.ONE * 0.01)})
	print("[world-r2exp] seed 17 sweep escapes: ", found)
	var res := _corner_and_random_pushes(w, body, 1717, 800)
	print("[world-r2exp] seed 17 pushes: corners %d, escapes %s; random %d, escapes %s" % [
		res["corner_tries"], (res["corner_escapes"] as Array).slice(0, 6), res["random_tries"], (res["random_escapes"] as Array).slice(0, 6)])
	metric("seed17_sweep_escapes", found)
	metric("seed17_pushes", {"corner_escapes": (res["corner_escapes"] as Array).size(), "random_escapes": (res["random_escapes"] as Array).size()})
	var real := 0
	for f in found:
		if f["body_escaped"] or f["ray_escape"]:
			real += 1
	eq(real, 0, "seed 17: no escape is real (a ray or a moving body gets out)")
	eq((res["corner_escapes"] as Array).size() + (res["random_escapes"] as Array).size(), 0, "seed 17: no pushed body escapes")
	vp.queue_free()
	await wait_frames(2)
