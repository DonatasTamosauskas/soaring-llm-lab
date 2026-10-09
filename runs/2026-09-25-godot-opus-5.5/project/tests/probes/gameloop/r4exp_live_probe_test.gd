extends TestCase
## Verifier probe (round 4, experience lens): whole modelled runs in the
## game's own sky (the AI's Ecosystem in the shipped valley, exactly as the
## pacing tool's --live_ai runs them) on seeds that NO tuning batch has ever
## run (300+), to test the G4 pacing claim genuinely out of sample, plus the
## cadence (dry spells) and first-flight claims. One or two seeds per process.
##   GD_TIMEOUT=2700 tools/gd.sh gameloop_verify_a --headless res://tests/runner.tscn -- \
##     --dir=res://tests/probes/gameloop --suite=r4exp_live --r4_seeds=300 --r4_tag=s300
## Writes artifacts/gameloop/verify/r4exp_live_<tag>.json. Not part of any suite.

const LiveSky := preload("res://tests/shots/gameloop_live_sky.gd")


func test_live_rerun_unseen_seeds() -> void:
	var args := Paths.user_args()
	if not args.has("r4_seeds"):
		check(true, "(skipped: no --r4_seeds)")
		return
	var seeds: Array[int] = []
	for s in String(args["r4_seeds"]).split(","):
		seeds.append(int(s))
	var minutes := float(args.get("r4_minutes", "50"))
	var skill := StringName(args.get("r4_skill", "competent"))
	var tag := String(args.get("r4_tag", "x"))
	var sim := IntegratedSim.new()
	sim.sky_factory = func() -> Node:
		var sky: Node = LiveSky.new()
		sky.set(&"world_kind", &"valley")
		return sky
	add_child(sim)
	await get_tree().process_frame
	var runs := []
	for seed_ in seeds:
		var t0 := Time.get_ticks_msec()
		var r: Dictionary = await sim.run(skill, seed_, minutes * 60.0)
		var ta := {}
		for k in r["tier_at"]:
			ta[str(k)] = snappedf(float(r["tier_at"][k]) / 60.0, 0.001)
		var catch_t := []
		for c: Array in r["catch_log"]:
			catch_t.append([snappedf(float(c[0]) / 60.0, 0.001), c[1], c[2], c[3]])
		var row := {"seed": seed_, "skill": skill, "tier_min": ta, "deaths": r["deaths"],
			"death_min": (r["death_times"] as Array).map(func(x: Variant) -> float: return snappedf(float(x) / 60.0, 0.001)),
			"catches": r["catches"], "catch_log_min": catch_t, "attacks": r["attacks"], "end": r["end_reason"],
			"ended_min": snappedf(float(r["ended_at"]) / 60.0, 0.001),
			"victory_min": snappedf(float(r["victory_at"]) / 60.0, 0.001), "escapes": r["escapes"],
			"chases": r["chases"], "wall_s": (Time.get_ticks_msec() - t0) / 1000.0,
			"sky_code": IntegratedSim.sky_code(&"valley")}
		runs.append(row)
		print("[gameloop] r4exp live %s seed %d: pigeon %s eagle %s deaths %d catches %d end %s (%.0f s wall)" % [skill, seed_,
			ta.get(str(SizeRules.species_index(&"pigeon")), "-"), ta.get(str(SizeRules.species_index(&"eagle")), "-"),
			r["deaths"], r["catches"], r["end_reason"], row["wall_s"]])
		var f := FileAccess.open(Paths.artifacts("gameloop").path_join("verify/r4exp_live_%s.json" % tag), FileAccess.WRITE)
		if f:
			f.store_string(JSON.stringify({"skill": skill, "minutes": minutes, "fingerprint": IntegratedSim.fingerprint(),
				"runs": runs}, "  "))
	sim.queue_free()
	await get_tree().process_frame
	check(runs.size() == seeds.size(), "all runs finished")
