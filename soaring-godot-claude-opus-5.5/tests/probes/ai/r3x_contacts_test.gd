extends "res://tests/unit/ai/ai_sim.gd"
## VERIFIER PROBE (round 3, experience lens): the builder bounds valley
## geometry contacts at < 4.0 per bird-minute (measured 0.3-3.4). A contact is
## the safety net stopping a bird at a wall and sliding it along (NpcBird
## _resolve). What matters to a player is whether it SEES birds bonk into
## houses: this probe records every contact with the bird's distance to the
## player, the speed it hit with (velocity into the surface the tick before),
## its state and species. "Visible hard hits": within 60 m of the player and
## >= 3 m/s into the surface.
## Cases (real valley, 20 s warm + 120 s): eagle- and gull-sized lapping mock
## players (the builder's worst case) and a pigeon-sized HUNTING player
## (r3x_seeker_player) that chases prey into the village.
## Report: artifacts/ai/verify/r3/contacts.json
##   tools/gd.sh ai_verify --headless res://tests/runner.tscn -- --dir=res://tests/probes/ai --suite=r3x_contacts

const Seeker := preload("res://tests/probes/ai/r3x_seeker_player.gd")
const WARM_S := 20.0
const MEAS_S := 120.0
const Safety := preload("res://tests/unit/ai/safety_monitor.gd")


func _case(w: World, tag: String, pm: float, hunting: bool, seed_v: int) -> Dictionary:
	var c := w.get_player_spawn().origin
	var p: Bird = null
	if hunting:
		var s := Seeker.new()
		add_child(s)
		s.setup(w, pm, c)
		p = s
	else:
		var mp := MockPlayer.new()
		mp.mass = pm
		mp.path_center = Vector3(c.x, 0, c.z)
		mp.path_radius = 90.0
		var gmax := 0.0
		for k in 36:
			var a := TAU * k / 36.0
			gmax = maxf(gmax, w.ground_height(c.x + cos(a) * 90.0, c.z + sin(a) * 90.0))
		mp.path_height = gmax + 22.0
		mp.speed = minf(SizeRules.cruise_speed(pm), 14.0)
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
	var meas: float = float(Paths.arg("r3_meas", str(MEAS_S))) if hunting else MEAS_S
	var safety: RefCounted = Safety.new(w)
	var prev_hits := {}
	var prev_vel := {}
	var r := {"contacts": 0, "near60": 0, "hard": 0, "visible_hard": 0, "by_state": {}, "by_species": {},
		"visible_hard_by_state": {}, "bird_s": 0.0, "examples": [], "per_bird": {}, "grind_trace": {}}
	for i in int((WARM_S + meas) / DT):
		var t := i * DT
		if hunting:
			(p as Object).call("step", DT, e.get_npcs())
		else:
			(p as Object).call("step", DT)
		e.step(DT)
		chk.step(DT)
		var pp := p.get_body_position()
		if t >= WARM_S:
			safety.step(DT, e.get_npcs())
		for n in e.get_npcs():
			var id := n.get_instance_id()
			var h: int = n.geo_hits
			if t >= WARM_S and prev_hits.has(id) and h > int(prev_hits[id]):
				var nrm: Vector3 = n.last_hit_normal
				var v0: Vector3 = prev_vel.get(id, n.velocity)
				var vin := maxf(-v0.dot(nrm), 0.0)
				var d := n.global_position.distance_to(pp)
				var st := n.state_name()
				r["contacts"] += 1
				var bk := "%s#%d" % [n.species, id % 100000]
				r["per_bird"][bk] = r["per_bird"].get(bk, 0) + 1
				if r["per_bird"][bk] > 40:
					var tr: Array = r["grind_trace"].get(bk, [])
					if tr.size() < 40 and (tr.is_empty() or t - float(tr[-1]["t"]) > 3.0):
						tr.append({"t": snappedf(t, 0.1), "pos": str(n.global_position.snapped(Vector3(0.1, 0.1, 0.1))), "hit": str(n.last_hit.snapped(Vector3(0.1, 0.1, 0.1))), "nrm": str(nrm.snapped(Vector3(0.1, 0.1, 0.1))), "state": n.state_name(), "speed": snappedf(n.velocity.length(), 0.1), "agl": snappedf(n.agl(), 0.1), "energy": snappedf(n.energy, 0.01), "flaring": n.is_flaring(), "player_d": snappedf(d, 0.1), "want": str(n.want_dir.snapped(Vector3(0.1, 0.1, 0.1))), "home_d": snappedf(Vector2(n.global_position.x - n.home.x, n.global_position.z - n.home.z).length(), 0.1)})
					r["grind_trace"][bk] = tr
				r["by_state"][st] = r["by_state"].get(st, 0) + 1
				r["by_species"][String(n.species)] = r["by_species"].get(String(n.species), 0) + 1
				if d < 60.0:
					r["near60"] += 1
				if vin >= 3.0:
					r["hard"] += 1
					if d < 60.0:
						r["visible_hard"] += 1
						r["visible_hard_by_state"][st] = r["visible_hard_by_state"].get(st, 0) + 1
						if r["examples"].size() < 8:
							r["examples"].append("%s %s %.1f m/s into %s at %.0f m from the player, pos %s" % [n.species, st, vin, str(nrm.snapped(Vector3(0.1, 0.1, 0.1))), d, str(n.last_hit.snapped(Vector3(0.1, 0.1, 0.1)))])
			prev_hits[id] = h
			prev_vel[id] = n.velocity
		if t >= WARM_S:
			r["bird_s"] += DT * e.count()
	var mins := meas / 60.0
	r["safety"] = safety.counts.duplicate()
	r["safety_examples"] = safety.examples.slice(0, 6)
	r["tag"] = tag
	r["contacts_per_bird_min"] = snappedf(r["contacts"] / maxf(r["bird_s"] / 60.0, 1e-3), 0.001)
	r["visible_hard_per_min"] = snappedf(r["visible_hard"] / mins, 0.01)
	r["near60_per_min"] = snappedf(r["near60"] / mins, 0.01)
	print("[ai-r3x] contacts %s: %s" % [tag, JSON.stringify(r)])
	e.queue_free()
	remove_child(p)
	p.queue_free()
	await wait_frames(2)
	return r


func test_r3_contacts_seen_by_the_player() -> void:
	var rw := (load("res://scenes/world/world.tscn") as PackedScene).instantiate() as World
	add_child(rw)
	await wait_physics(3)
	if not rw.is_generated:
		await rw.generated
	var res := {}
	for c in [["eagle_laps", 3.0, false, 861], ["gull_laps", 0.85, false, 862], ["pigeon_hunting", 0.3, true, 863], ["sparrow_hunting", 0.03, true, 864]]:
		res[c[0]] = await _case(rw, c[0], c[1], c[2], c[3])
	rw.queue_free()
	Habitat.clear_cache()
	await wait_frames(2)
	var dir := Paths.artifacts("ai").path_join("verify/r3")
	DirAccess.make_dir_recursive_absolute(dir)
	var f := FileAccess.open(dir.path_join("contacts.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(res, "  "))
	f.close()
	for k in res:
		lt(res[k]["visible_hard_per_min"], 1.0, "%s: hard (>= 3 m/s) wall hits within 60 m of the player per minute" % k)
