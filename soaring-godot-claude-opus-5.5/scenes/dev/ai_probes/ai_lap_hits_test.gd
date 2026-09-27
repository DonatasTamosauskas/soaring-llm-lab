extends "res://tests/unit/ai/ai_sim.gd"
## AI builder DIAGNOSTIC (not in the suite): the r3x_contacts probe's measure
## ("hard" hits, >= 3 m/s into a surface, within 60 m of the player) round a
## LAPPING mock player of mass --lh_mass in the real valley, over several
## seeds (20 s warm + --lh_s each), air driven from sim time. Uses only the
## NpcBird API every round had, so it runs on older AI code too.
##   tools/gd.sh ai --headless res://tests/runner.tscn -- --dir=res://scenes/dev/ai_probes --suite=ai_lap_hits --lh_mass=3.0 --lh_seeds=861,871,881,891 [--lh_s=120]


func test_lap_hits() -> void:
	var rw := (load("res://scenes/world/world.tscn") as PackedScene).instantiate() as World
	add_child(rw)
	await wait_physics(3)
	if not rw.is_generated:
		await rw.generated
	var pm := float(Paths.arg("lh_mass", "3.0"))
	var meas := float(Paths.arg("lh_s", "120"))
	var seeds: PackedStringArray = String(Paths.arg("lh_seeds", "861,871,881,891")).split(",")
	var tot := {"hits": 0, "min": 0.0, "contacts": 0}
	for sv in seeds:
		var c := rw.get_player_spawn().origin
		var mp := MockPlayer.new()
		mp.mass = pm
		mp.path_center = Vector3(c.x, 0, c.z)
		mp.path_radius = 90.0
		var gmax := 0.0
		for k in 36:
			var a := TAU * k / 36.0
			gmax = maxf(gmax, rw.ground_height(c.x + cos(a) * 90.0, c.z + sin(a) * 90.0))
		mp.path_height = gmax + 22.0
		mp.speed = minf(SizeRules.cruise_speed(pm), 14.0)
		add_child(mp)
		mp.step(0.0)
		var e := EcoScene.instantiate() as Ecosystem
		e.auto_step = false
		e.rng_seed = int(sv)
		add_child(e)
		e.focus = mp
		var chk: RefCounted = CatchChecker.new()
		chk.reach = 0.25
		var prev := {}
		var r := {"hits": 0, "contacts": 0, "by_state": {}, "by_species": {}}
		for i in int((20.0 + meas) / DT):
			var t := i * DT
			air(rw, t)
			mp.step(DT)
			e.step(DT)
			chk.step(DT)
			var pp := mp.get_body_position()
			for n in e.get_npcs():
				var id := n.get_instance_id()
				var pv: Dictionary = prev.get(id, {})
				if t >= 20.0 and not pv.is_empty() and n.geo_hits > int(pv["h"]):
					r["contacts"] += 1
					var vin := maxf(-(pv["v"] as Vector3).dot(n.last_hit_normal), 0.0)
					if vin >= 3.0 and n.global_position.distance_to(pp) < 60.0:
						r["hits"] += 1
						var st := n.state_name()
						r["by_state"][st] = r["by_state"].get(st, 0) + 1
						r["by_species"][String(n.species)] = r["by_species"].get(String(n.species), 0) + 1
				prev[id] = {"h": n.geo_hits, "v": n.velocity}
		print("[ai-lh] seed %s mass %.2f: %d hard hits within 60 m in %.0f s (%.2f a minute), %d contacts; by state %s, by species %s" % [sv, pm, r["hits"], meas, r["hits"] / (meas / 60.0), r["contacts"], r["by_state"], r["by_species"]])
		tot["hits"] += r["hits"]
		tot["contacts"] += r["contacts"]
		tot["min"] += meas / 60.0
		e.queue_free()
		remove_child(mp)
		mp.queue_free()
		await wait_frames(2)
	print("[ai-lh] pooled mass %.2f: %d hard hits within 60 m in %.0f min = %.2f a minute; %d contacts" % [pm, tot["hits"], tot["min"], tot["hits"] / maxf(tot["min"], 1e-3), tot["contacts"]])
	check(true, "measured")
	rw.queue_free()
	Habitat.clear_cache()
	await wait_frames(2)
