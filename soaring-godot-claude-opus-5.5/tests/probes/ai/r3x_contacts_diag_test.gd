extends "res://tests/unit/ai/ai_sim.gd"
## VERIFIER DIAGNOSTIC (round 3): replays r3x_contacts' hunting cases (same
## seeds) and names what the birds hit (collider node path) and, for the bird
## with the most contacts, its trajectory, state and hits over time.
##   tools/gd.sh ai_verify --headless res://tests/runner.tscn -- --dir=res://tests/probes/ai --suite=r3x_contacts_diag

const Seeker := preload("res://tests/probes/ai/r3x_seeker_player.gd")
const WARM_S := 20.0
const MEAS_S := 120.0


func _collider_name(w: World, hp: Vector3, nrm: Vector3) -> String:
	var q := PhysicsRayQueryParameters3D.create(hp + nrm * 0.3, hp - nrm * 0.3, 1)
	var hit := w.get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		return "?"
	var col: Object = hit["collider"]
	if col is Node:
		var nd := col as Node
		var s := String(nd.name)
		var par := nd.get_parent()
		if par:
			s = String(par.name) + "/" + s
			if par.get_parent():
				s = String(par.get_parent().name) + "/" + s
		return s
	return str(col)


func _case(w: World, tag: String, pm: float, seed_v: int) -> Dictionary:
	var c := w.get_player_spawn().origin
	var s := Seeker.new()
	add_child(s)
	s.setup(w, pm, c)
	var e := EcoScene.instantiate() as Ecosystem
	e.auto_step = false
	e.rng_seed = seed_v
	add_child(e)
	e.focus = s
	var chk: RefCounted = CatchChecker.new()
	chk.reach = 0.25
	var prev_hits := {}
	var prev_vel := {}
	var per_bird := {}
	var colliders := {}
	var trace := {}
	var r := {"spawn": c}
	for i in int((WARM_S + MEAS_S) / DT):
		var t := i * DT
		s.step(DT, e.get_npcs())
		e.step(DT)
		chk.step(DT)
		var pp := s.get_body_position()
		for n in e.get_npcs():
			var id := n.get_instance_id()
			var h: int = n.geo_hits
			if t >= WARM_S and prev_hits.has(id) and h > int(prev_hits[id]):
				var nrm: Vector3 = n.last_hit_normal
				var v0: Vector3 = prev_vel.get(id, n.velocity)
				var vin := maxf(-v0.dot(nrm), 0.0)
				var key := "%s#%d" % [n.species, id % 100000]
				per_bird[key] = per_bird.get(key, 0) + 1
				var cn := _collider_name(w, n.last_hit, nrm)
				var ck := "%s|%s" % [cn, n.state_name()]
				if vin >= 3.0 and n.global_position.distance_to(pp) < 60.0:
					colliders[ck] = colliders.get(ck, 0) + 1
				if not trace.has(key):
					trace[key] = []
				if trace[key].size() < 30 and (trace[key].is_empty() or t - float(trace[key][-1]["t"]) > 2.0):
					trace[key].append({"t": snappedf(t, 0.1), "pos": str(n.global_position.snapped(Vector3(0.1, 0.1, 0.1))), "state": n.state_name(),
						"hit": cn, "nrm": str(nrm.snapped(Vector3(0.1, 0.1, 0.1))), "vin": snappedf(vin, 0.1), "speed": snappedf(n.velocity.length(), 0.1),
						"agl": snappedf(n.agl(), 0.1), "energy": snappedf(n.energy, 0.01), "perched": n.perched, "flaring": n.is_flaring(),
						"player_d": snappedf(n.global_position.distance_to(pp), 0.1)})
			prev_hits[id] = h
			prev_vel[id] = n.velocity
	var worst := ""
	var wn := 0
	for k in per_bird:
		if per_bird[k] > wn:
			wn = per_bird[k]
			worst = k
	r["tag"] = tag
	r["per_bird_top"] = per_bird
	r["visible_hard_by_collider_state"] = colliders
	r["worst"] = worst
	r["worst_trace"] = trace.get(worst, [])
	print("[ai-r3x] diag %s: %s" % [tag, JSON.stringify(r)])
	e.queue_free()
	remove_child(s)
	s.queue_free()
	await wait_frames(2)
	return r


func test_r3_contacts_diag() -> void:
	var rw := (load("res://scenes/world/world.tscn") as PackedScene).instantiate() as World
	add_child(rw)
	await wait_physics(3)
	if not rw.is_generated:
		await rw.generated
	var res := {}
	for c in [["pigeon_hunting", 0.3, 863], ["sparrow_hunting", 0.03, 864]]:
		res[c[0]] = await _case(rw, c[0], c[1], c[2])
	rw.queue_free()
	Habitat.clear_cache()
	await wait_frames(2)
	var dir := Paths.artifacts("ai").path_join("verify/r3")
	DirAccess.make_dir_recursive_absolute(dir)
	var f := FileAccess.open(dir.path_join("contacts_diag.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(res, "  "))
	f.close()
	check(true, "diag written")
