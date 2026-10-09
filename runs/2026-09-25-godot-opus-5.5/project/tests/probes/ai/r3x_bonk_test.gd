extends "res://tests/unit/ai/ai_sim.gd"
## VERIFIER PROBE (round 3): A5 safety and visible wall hits in the shipped
## valley with players the builder's tests never fly: a player HUNTING low
## (r3x_seeker_player) at three sizes and a sparrow lapping low (8 m) over
## the village, on fresh seeds, 20 s warm + 180 s each, with the builder's
## own SafetyMonitor. "Visible bonk": a hit >= 3 m/s into a surface, inside
## the player's 100x90 deg view and >= 0.5 deg across (~10 px on a Quest Pro).
## Report: artifacts/ai/verify/r3/bonk.json
##   tools/gd.sh ai_verify --headless res://tests/runner.tscn -- --dir=res://tests/probes/ai --suite=r3x_bonk [--r3_seed=871]

const Seeker := preload("res://tests/probes/ai/r3x_seeker_player.gd")
const Safety := preload("res://tests/unit/ai/safety_monitor.gd")
const WARM_S := 20.0
const MEAS_S := 180.0


func _case(w: World, tag: String, pm: float, hunting: bool, seed_v: int) -> Dictionary:
	var c := w.get_player_spawn().origin
	var p: Bird = null
	if hunting:
		var s := Seeker.new()
		add_child(s)
		s.setup(w, pm, c)
		s.collide = Paths.arg("r3_collide", "0") == "1"
		p = s
	else:
		var mp := MockPlayer.new()
		mp.mass = pm
		mp.path_center = Vector3(c.x, 0, c.z)
		mp.path_radius = 45.0
		mp.path_height = w.ground_height(c.x, c.z) + 8.0
		mp.speed = SizeRules.cruise_speed(pm)
		add_child(mp)
		mp.step(0.0)
		p = mp
	var e := EcoScene.instantiate() as Ecosystem
	e.auto_step = false
	e.rng_seed = seed_v
	add_child(e)
	e.focus = p
	var chk: RefCounted = CatchChecker.new()
	chk.reach = 0.25
	var safety: RefCounted = Safety.new(w)
	var prev_hits := {}
	var prev_vel := {}
	var r := {"hard": 0, "hard60": 0, "visible_bonks": 0, "visible_by_state": {}, "contacts": 0, "bird_s": 0.0, "examples": []}
	for i in int((WARM_S + MEAS_S) / DT):
		var t := i * DT
		if hunting:
			(p as Object).call("step", DT, e.get_npcs())
		else:
			(p as Object).call("step", DT)
		e.step(DT)
		chk.step(DT)
		if t < WARM_S:
			for n in e.get_npcs():
				prev_hits[n.get_instance_id()] = n.geo_hits
				prev_vel[n.get_instance_id()] = n.velocity
			continue
		safety.step(DT, e.get_npcs())
		r["bird_s"] += DT * e.count()
		var eye := p.get_body_position()
		var f: Vector3 = (p as Object).call("get_view_direction")
		f = Vector3(f.x, 0.0, f.z).normalized()
		var right := f.cross(Vector3.UP).normalized()
		for n in e.get_npcs():
			var id := n.get_instance_id()
			var h: int = n.geo_hits
			if prev_hits.has(id) and h > int(prev_hits[id]):
				r["contacts"] += 1
				var nrm: Vector3 = n.last_hit_normal
				var v0: Vector3 = prev_vel.get(id, n.velocity)
				var vin := maxf(-v0.dot(nrm), 0.0)
				if vin >= 3.0:
					r["hard"] += 1
					var rel := n.global_position - eye
					var d := rel.length()
					if d < 60.0:
						r["hard60"] += 1
					var fz := rel.dot(f)
					var ang := rad_to_deg(n.get_wingspan() / maxf(d, 0.1))
					if fz > 0.0 and rad_to_deg(atan2(absf(rel.dot(right)), fz)) < 50.0 and rad_to_deg(atan2(absf(rel.y), fz)) < 45.0 and ang >= 0.5:
						r["visible_bonks"] += 1
						r["visible_by_state"][n.state_name()] = r["visible_by_state"].get(n.state_name(), 0) + 1
						if r["examples"].size() < 6:
							r["examples"].append("%s %s %.1f m/s at %.0f m (%.1f deg)" % [n.species, n.state_name(), vin, d, ang])
			prev_hits[id] = h
			prev_vel[id] = n.velocity
	var mins := MEAS_S / 60.0
	r["tag"] = tag
	r["contacts_per_bird_min"] = snappedf(r["contacts"] / maxf(r["bird_s"] / 60.0, 1e-3), 0.01)
	r["visible_bonks_per_min"] = snappedf(r["visible_bonks"] / mins, 0.01)
	r["hard60_per_min"] = snappedf(r["hard60"] / mins, 0.01)
	r["safety"] = safety.counts.duplicate()
	r["player_wall_hits"] = int((p as Object).get("wall_hits")) if hunting else 0
	r["safety_examples"] = safety.examples.slice(0, 6)
	print("[ai-r3x] bonk %s: %s" % [tag, JSON.stringify(r)])
	e.queue_free()
	remove_child(p)
	p.queue_free()
	await wait_frames(2)
	return r


func test_r3_bonk_and_safety() -> void:
	var rw := (load("res://scenes/world/world.tscn") as PackedScene).instantiate() as World
	add_child(rw)
	await wait_physics(3)
	if not rw.is_generated:
		await rw.generated
	var base := int(Paths.arg("r3_seed", "871"))
	var res := {}
	for c in [["sparrow_hunting", 0.03, true], ["starling_hunting", 0.1, true], ["pigeon_hunting", 0.3, true], ["crow_hunting", 0.5, true], ["sparrow_laps_low", 0.03, false]]:
		res[c[0]] = await _case(rw, c[0], c[1], c[2], base + res.size())
	rw.queue_free()
	Habitat.clear_cache()
	await wait_frames(2)
	var dir := Paths.artifacts("ai").path_join("verify/r3")
	DirAccess.make_dir_recursive_absolute(dir)
	var f := FileAccess.open(dir.path_join("bonk_%d%s.json" % [base, "_collide" if Paths.arg("r3_collide", "0") == "1" else ""]), FileAccess.WRITE)
	f.store_string(JSON.stringify(res, "  "))
	f.close()
	for k in res:
		for s in res[k]["safety"]:
			eq(res[k]["safety"][s], 0, "%s: A5 %s" % [k, s])
		lt(res[k]["visible_bonks_per_min"], 1.0, "%s: visible hard wall hits per minute" % k)
