extends "res://tests/unit/game/game_fixture.gd"
## Verifier probes (round 1) for G4: is the pacing claim robust to seeds?
## (a) the PacingModel's competent medians under four other seeds, (b) whole
## competent runs of the IntegratedSim (the primary evidence, only checked for
## the first 8 minutes by the area's suite) with fresh seeds, to eagle.

func test_model_other_seeds() -> void:
	var pig := SizeRules.species_index(&"pigeon")
	var eag := SizeRules.species_index(&"eagle")
	var out := {}
	var bad := 0
	for seed_ in [1, 2, 3, 1001]:
		var model := PacingModel.new()
		var res := model.simulate([&"competent"], 300, seed_)
		var c: Dictionary = res["competent"]
		var p := float(c["tiers"][pig]["median"]) / 60.0
		var e := float(c["tiers"][eag]["median"]) / 60.0
		out[seed_] = {"pigeon_min": snappedf(p, 0.01), "eagle_min": snappedf(e, 0.01),
				"deaths_median": c["deaths"]["median"], "deaths_q90": c["deaths"]["q90"], "ended_caught": c["ended_caught"]}
		if p < 5.0 or p > 8.0 or e < 20.0 or e > 30.0:
			bad += 1
	metric("model_competent_by_seed", out)
	eq(bad, 0, "model competent medians inside 5-8 / 20-30 min for every seed")


func test_integrated_competent_fresh_seeds() -> void:
	var sim := IntegratedSim.new()
	add_child(sim)
	await get_tree().process_frame
	var pig := SizeRules.species_index(&"pigeon")
	var eag := SizeRules.species_index(&"eagle")
	var pigs: Array[float] = []
	var eags: Array[float] = []
	var runs := []
	for seed_ in [1111, 2222, 3333, 4444, 5555]:
		var t0 := Time.get_ticks_msec()
		var run: Dictionary = await sim.run(&"competent", seed_, 34.0 * 60.0)
		var ta: Dictionary = run["tier_at"]
		var p := float(ta.get(pig, INF)) / 60.0
		var e := float(ta.get(eag, INF)) / 60.0
		pigs.append(p)
		eags.append(e)
		runs.append({"seed": seed_, "pigeon_min": snappedf(p, 0.01), "eagle_min": snappedf(e, 0.01),
				"deaths": run["deaths"], "attacks": run["attacks"], "catches": run["catches"],
				"npc_catches": run["npc_catches"], "end": run["end_reason"], "wall_s": (Time.get_ticks_msec() - t0) / 1000.0})
		print("[gameloop] probe integrated seed %d: pigeon %.2f min, eagle %.2f min, deaths %d, attacks %d" % [
				seed_, p, e, run["deaths"], run["attacks"]])
	sim.queue_free()
	await get_tree().process_frame
	pigs.sort()
	eags.sort()
	metric("integrated_competent_runs", runs)
	metric("median_pigeon_min", pigs[2])
	metric("median_eagle_min", eags[2])
	between(pigs[2], 5.0, 8.0, "fresh-seed integrated competent median time to pigeon (min)")
	between(eags[2], 20.0, 30.0, "fresh-seed integrated competent median time to eagle (min)")
