extends TestCase
## Verifier probe (round 2, engineering lens): re-runs whole competent runs in
## the AI area's real sky with the AI code AS IT IS NOW (the stored live
## evidence was made against an older AI hash), to see whether the G4 pacing
## claim still holds. Writes artifacts/gameloop/verify/v3_live_<tag>.json.
##   GD_TIMEOUT=3000 tools/gd.sh gameloop_verify2b --headless res://tests/runner.tscn -- \
##     --dir=res://tests/probes/gameloop --suite=v3_live_rerun --v3_seeds=100,101 --v3_tag=a
## Not part of any suite (lives under tests/probes).

const LiveSky := preload("res://tests/shots/gameloop_live_sky.gd")


func test_live_competent_rerun() -> void:
	var args := Paths.user_args()
	if not args.has("v3_seeds"):
		check(true, "(skipped: no --v3_seeds)")
		return
	var seeds: Array[int] = []
	for s in String(args["v3_seeds"]).split(","):
		seeds.append(int(s))
	var minutes := float(args.get("v3_minutes", "50"))
	var skill := StringName(args.get("v3_skill", "competent"))
	var tag := String(args.get("v3_tag", "x"))
	var sim := IntegratedSim.new()
	sim.sky_factory = func() -> Node: return LiveSky.new()
	add_child(sim)
	await get_tree().process_frame
	var runs := []
	for seed_ in seeds:
		var t0 := Time.get_ticks_msec()
		var r: Dictionary = await sim.run(skill, seed_, minutes * 60.0)
		var ta := {}
		for k in r["tier_at"]:
			ta[str(k)] = snappedf(float(r["tier_at"][k]) / 60.0, 0.01)
		var row := {"seed": seed_, "tier_min": ta, "deaths": r["deaths"], "catches": r["catches"],
			"attacks": r["attacks"], "end": r["end_reason"], "ended_min": snappedf(float(r["ended_at"]) / 60.0, 0.01),
			"escapes": r["escapes"], "wall_s": (Time.get_ticks_msec() - t0) / 1000.0}
		runs.append(row)
		print("[gameloop] v3 live %s seed %d: %s" % [skill, seed_, JSON.stringify(row)])
		var f := FileAccess.open(Paths.artifacts("gameloop").path_join("verify/v3_live_%s.json" % tag), FileAccess.WRITE)
		if f:
			f.store_string(JSON.stringify({"skill": skill, "minutes": minutes, "fingerprint": IntegratedSim.fingerprint(),
				"runs": runs}, "  "))
	sim.queue_free()
	await get_tree().process_frame
	check(runs.size() == seeds.size(), "all runs finished")
