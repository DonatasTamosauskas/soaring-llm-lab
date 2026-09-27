extends "res://tests/unit/ai/ai_sim.gd"
## AI builder DIAGNOSTIC (fix round 3, not part of the suite): why do birds
## hit walls hard in front of a player who chases them? Runs a hunting
## player (tests/unit/ai/seeker_player.gd, colliding) in the valley and, for
## every hit of >= 3 m/s into a surface within 60 m of the player, records
## what the bird was doing the tick before and whether its obstacle memory
## already held that surface (and since when, from how far):
##   jink      - an evasive break was under way
##   refuge    - flying at a chosen refuge (guard off near it)
##   known     - the feelers had seen the surface (memory normal within 25 deg)
##   unknown   - nothing in memory with that normal
##   tools/gd.sh ai --headless res://tests/runner.tscn -- --dir=res://scenes/dev/ai_probes --suite=ai_bonk_diag [--bd_mass=0.3] [--bd_seed=871] [--bd_s=180]

const Seeker := preload("res://tests/unit/ai/seeker_player.gd")
const Safety := preload("res://tests/unit/ai/safety_monitor.gd")
const WARM_S := 20.0


func test_bonk_diag() -> void:
	var rw := (load("res://scenes/world/world.tscn") as PackedScene).instantiate() as World
	add_child(rw)
	await wait_physics(3)
	if not rw.is_generated:
		await rw.generated
	var masses: PackedStringArray = String(Paths.arg("bd_mass", "0.3,0.5")).split(",")
	var seed0 := int(Paths.arg("bd_seed", "871"))
	var meas := float(Paths.arg("bd_s", "180"))
	var all := {}
	for ms in masses:
		var pm := float(ms)
		var s := Seeker.new()
		add_child(s)
		s.setup(rw, pm, rw.get_player_spawn().origin)
		var e := EcoScene.instantiate() as Ecosystem
		e.auto_step = false
		e.rng_seed = seed0
		add_child(e)
		e.focus = s
		var chk: RefCounted = CatchChecker.new()
		chk.reach = 0.25
		var safety: RefCounted = Safety.new(rw)
		var prev := {}
		var mem := {}
		var r := {"hard60": 0, "cats": {}, "by_state": {}, "examples": [], "normals": {}, "known_detail": []}
		for i in int((WARM_S + meas) / DT):
			var t := i * DT
			air(rw, t)
			s.active = t >= WARM_S
			s.step(DT, e.get_npcs())
			e.step(DT)
			chk.step(DT)
			if t >= WARM_S:
				safety.step(DT, e.get_npcs())
			var eye := s.get_body_position()
			for n in e.get_npcs():
				var id := n.get_instance_id()
				var br := n.brain
				var pv: Dictionary = prev.get(id, {})
				if t >= WARM_S and not pv.is_empty() and n.geo_hits > int(pv["hits"]):
					var nrm: Vector3 = n.last_hit_normal
					var v0: Vector3 = pv["v"]
					var vin := maxf(-v0.dot(nrm), 0.0)
					var d := n.global_position.distance_to(eye)
					if vin >= 3.0 and d < 60.0:
						r["hard60"] += 1
						var cat := "unknown"
						if float(pv["jink"]) > 0.0:
							cat = "jink"
						elif pv["state"] == "flee" and bool(pv["refuge"]):
							cat = "refuge"
						elif bool(pv["flare"]):
							cat = "flare"
						# Since when did the memory hold this surface?
						var seen_t := -1.0
						var seen_d := -1.0
						var h: Array = mem.get(id, [])
						for k in range(h.size() - 1, -1, -1):
							var mk: Array = h[k]
							var has := false
							for q: Vector3 in mk[1]:
								if q.dot(nrm) > 0.9:
									has = true
							if has:
								seen_t = t - float(mk[0])
								seen_d = float(mk[2])
							else:
								break
						if cat == "unknown" and seen_t >= 0.0:
							cat = "known"
						r["cats"][cat] = r["cats"].get(cat, 0) + 1
						var sk := "%s/%s" % [pv["state"], cat]
						r["by_state"][sk] = r["by_state"].get(sk, 0) + 1
						var nk := "wall" if absf(nrm.y) < 0.6 else ("roof_under" if nrm.y < 0.0 else "top")
						r["normals"][nk] = r["normals"].get(nk, 0) + 1
						var line := "%s %s %s vin=%.1f spd=%.1f at %.0fm hitn=%s seen %.2fs/%.1fm before, look=%.1f want=%s v=%s obs_d=%.1f near=%s st_t=%.1f" % [
							n.species, pv["state"], cat, vin, v0.length(), d, str(nrm.snapped(Vector3.ONE * 0.1)), seen_t, seen_d,
							float(pv["look"]), str((pv["want"] as Vector3).snapped(Vector3.ONE * 0.1)), str(v0.snapped(Vector3.ONE * 0.1)),
							float(pv["obs_d"]), str(pv["near"]), float(pv["st_t"])] + " pos=%s indoors=%s roofed=%s id=%d thr=%s" % [
							str(n.global_position.snapped(Vector3.ONE * 0.1)), n.habitat.indoors(n.global_position), n.habitat.roofed_in(n.global_position),
							id % 10000, (n.threat.species if n.threat != null and is_instance_valid(n.threat) else "-")]
						if r["examples"].size() < 60:
							r["examples"].append(line)
				var sp := n.velocity.length()
				var rt := sp / maxf(n.flight.max_turn_rate(maxf(sp, 0.1)), 0.3)
				prev[id] = {"hits": n.geo_hits, "v": n.velocity, "state": n.state_name(), "jink": br._jink_t,
					"refuge": not n.refuge.is_empty(), "flare": n.is_flaring(), "look": clampf(sp + rt * 1.2, 3.0, 110.0),
					"want": n.want_dir, "obs_d": br.obs_plane_d(), "near": n.near_geometry,
					"st_t": n.state_time}
				var hm: Array = mem.get(id, [])
				var fresh: Array[Vector3] = []
				for k2 in br._ob_n.size():
					if br._ob_age[k2] < 0.5:
						fresh.append(br._ob_n[k2])
				hm.append([t, fresh, br.obs_plane_d()])
				if hm.size() > 150:
					hm.pop_front()
				mem[id] = hm
		r["hard60_per_min"] = snappedf(r["hard60"] / (meas / 60.0), 0.01)
		r["safety"] = safety.counts.duplicate()
		r["safety_examples"] = safety.examples.duplicate()
		r["player_catches"] = s.catches.size()
		var reasons := {}
		for pu in s.pursuits:
			reasons[pu["reason"]] = reasons.get(pu["reason"], 0) + 1
		r["pursuits"] = reasons
		print("[ai-bonk] mass %s: hard60/min %.2f cats %s by_state %s normals %s safety %s pursuits %s catches %d" % [ms, r["hard60_per_min"], r["cats"], r["by_state"], r["normals"], r["safety"], reasons, s.catches.size()])
		for ex in r["examples"]:
			print("[ai-bonk]   ", ex)
		all[ms] = r
		e.queue_free()
		remove_child(s)
		s.queue_free()
		await wait_frames(2)
	var f := FileAccess.open(Paths.artifacts("ai").path_join("fix_r3/bonk_diag_%d.json" % seed0), FileAccess.WRITE)
	f.store_string(JSON.stringify(all, "  "))
	f.close()
	check(true, "diag")
	rw.queue_free()
	Habitat.clear_cache()
	await wait_frames(2)
