extends "res://tests/unit/ai/ai_sim.gd"
## VERIFIER PROBE (ai, round 1) - not part of the area suite.
## A4 "in the wild": tests/unit/ai/safety_monitor.gd measures envelopes from
## each bird's self-reported `velocity`. This probe measures the bodies
## themselves: per-tick displacement / dt against max_speed, and against the
## reported velocity, in free flight (not perched, hidden, flaring, or
## bumping into something this tick), during an ecosystem soak (seed 7).
##
##   tools/gd.sh ai_verify2 --headless res://tests/runner.tscn -- --dir=res://tests/probes/ai --suite=body_motion [--probe_s=240]


func test_probe_bodies_move_as_their_flight_model_says() -> void:
	var sim_s := float(Paths.arg("probe_s", "240"))
	await make_world(false, 1)
	var e := make_eco(60, 7)
	var chk := make_checker()
	var prev := {}
	var prev_bumps := {}
	var prev_flares := {}
	var by_species := {}
	var dev_by_state := {}
	var n_ticks := 0
	var n_dev := 0
	var worst := {"ratio": 0.0, "what": ""}
	for i in int(sim_s / DT):
		e.step(DT)
		chk.step(DT)
		for n: NpcBird in e.get_npcs():
			if not n.alive or not n.is_inside_tree():
				continue
			var id := n.get_instance_id()
			var p := n.global_position
			var free := not (n.perched or n.hidden or n.is_flaring())
			if free and prev.has(id) and prev_bumps.get(id, -1) == n.bumps and prev_flares.get(id, -1) == n.flares:
				var v_pos: Vector3 = (p - prev[id]) / DT
				var vmax := float(SizeRules.performance(n.mass)["max_speed"])
				var wind := n.habitat.wind(p)
				var s: Dictionary = by_species.get(String(n.species), {"speed_ratio_max": 0.0, "ticks": 0})
				s["ticks"] += 1
				s["speed_ratio_max"] = maxf(s["speed_ratio_max"], (v_pos - wind).length() / vmax)
				by_species[String(n.species)] = s
				n_ticks += 1
				var vr := n.velocity.length()
				if vr > 0.5:
					var dev := (v_pos - n.velocity).length() / vr
					if dev > 0.1:
						n_dev += 1
						var k := n.state_name()
						dev_by_state[k] = dev_by_state.get(k, 0) + 1
					if dev > worst["ratio"]:
						worst = {"ratio": dev, "what": "%s %s |v_pos| %.2f |v_reported| %.2f target %s d %.2f" % [n.species, n.state_name(), v_pos.length(), vr, n.target.species if n.target else "-", n.global_position.distance_to(n.target.get_body_position()) if n.target else -1.0]}
			prev[id] = p
			prev_bumps[id] = n.bumps
			prev_flares[id] = n.flares
	var report := {"sim_s": sim_s, "free_ticks": n_ticks, "ticks_body_off_reported_velocity_gt10pct": n_dev,
		"share": float(n_dev) / maxf(n_ticks, 1), "by_state": dev_by_state, "worst": worst, "speed_vs_max_by_species": by_species}
	metric("body_motion", report)
	print("[ai-verify] body motion: ", JSON.stringify(report, "  "))
	for sp in by_species:
		lt(by_species[sp]["speed_ratio_max"], 1.0 + 1e-3, "%s body never faster (through the air) than max_speed" % sp)
	lt(float(n_dev) / maxf(n_ticks, 1), 0.001, "free-flight bodies move with their reported velocity (share of ticks off by >10%)")
	await clear_sim()
