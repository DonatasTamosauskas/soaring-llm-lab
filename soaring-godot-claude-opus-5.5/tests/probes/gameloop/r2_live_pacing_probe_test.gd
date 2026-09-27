extends "res://tests/unit/game/game_fixture.gd"
## Verifier round 2 (experience & requirements) probe for G4.
##
## The area's pacing claim is asserted on 10 stored seeds (100..109) that were
## also the seeds the growth/respite values were tuned on, against the AI code
## as of 06:45 (hash dbfb8b5ab3c07d89). This probe re-runs whole runs in the
## AI's real sky (tests/shots/gameloop_live_sky.gd, via IntegratedSim) on
## (a) FRESH seeds never used for tuning and (b) the CURRENT AI code, and
## writes every run to artifacts/gameloop/verify/r2_live_<tag>.json so the
## parts can be merged into medians outside the engine.
##
##   GD_TIMEOUT=7000 tools/gd.sh gl_r2a --headless res://tests/runner.tscn -- \
##       --dir=res://tests/probes/gameloop --suite=r2_live --r2_seeds=200,201 \
##       --r2_skill=competent --r2_minutes=50 --r2_tag=a
##
## --r2_sky=valley runs the same in the world area's shipped valley
## (SoaringWorld, tests/probes/gameloop/r2_valley_sky.gd) instead of the AI's
## AiTestWorld. Without --r2_seeds it runs one short smoke run (3 simulated
## minutes).

const LiveSky := preload("res://tests/shots/gameloop_live_sky.gd")
const ValleySky := preload("res://tests/probes/gameloop/r2_valley_sky.gd")
## IntegratedSim with a one-line guard (a freed chase target crashed the
## area's own copy on seed 202 with the current AI): --r2_original=1 uses the
## area's IntegratedSim instead.
const FixedSim := preload("res://tests/probes/gameloop/r2_integrated_sim_fixed.gd")


static func _ai_hash() -> String:
	var files: Array[String] = []
	for f in DirAccess.get_files_at("res://scripts/ai"):
		if f.ends_with(".gd"):
			files.append("res://scripts/ai".path_join(f))
	files.sort()
	files.append("res://scenes/dev/ai_test_world.gd")
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	for f in files:
		ctx.update(FileAccess.get_file_as_bytes(f))
	return ctx.finish().hex_encode().substr(0, 16)


func test_live_runs_on_fresh_seeds_and_current_ai() -> void:
	var args := Paths.user_args()
	var seeds: Array[int] = []
	for s in String(args.get("r2_seeds", "")).split(",", false):
		seeds.append(int(s))
	var minutes := float(args.get("r2_minutes", "50"))
	if seeds.is_empty():
		seeds = [300]
		minutes = 3.0
	var skill := StringName(args.get("r2_skill", "competent"))
	var tag := String(args.get("r2_tag", "smoke"))
	var sim = IntegratedSim.new() if args.has("r2_original") else FixedSim.new()
	var sky := String(args.get("r2_sky", "ai_test_world"))
	if sky == "valley":
		sim.sky_factory = func() -> Node: return ValleySky.new()
	else:
		sim.sky_factory = func() -> Node: return LiveSky.new()
	add_child(sim)
	await get_tree().process_frame
	var out := {"sky": sky, "skill": skill, "minutes": minutes, "ai_code": _ai_hash(), "fingerprint": IntegratedSim.fingerprint(),
		"started": Time.get_datetime_string_from_system(), "runs": []}
	var path := Paths.artifacts("gameloop/verify").path_join("r2_live_%s.json" % tag)
	for s in seeds:
		var t0 := Time.get_ticks_msec()
		var rv: Variant = await sim.run(skill, s, minutes * 60.0)
		if not (rv is Dictionary):
			out["runs"].append({"seed": s, "crashed": true})
			print("[gameloop-verify] r2 live %s seed %d: RUN CRASHED (see SCRIPT ERROR above)" % [skill, s])
			continue
		var r: Dictionary = rv
		var ta := {}
		for k in r["tier_at"]:
			ta[str(k)] = snappedf(float(r["tier_at"][k]), 0.1)
		var row := {"seed": s, "tier_at": ta, "deaths": r["deaths"], "death_by": r["death_by"],
			"death_times": r["death_times"], "catches": r["catches"], "chases": r["chases"],
			"victory_at": snappedf(float(r["victory_at"]), 0.1), "ended_at": snappedf(float(r["ended_at"]), 0.1),
			"end_reason": r["end_reason"], "attacks": r["attacks"], "close_attacks": r["close_attacks"],
			"escapes": r["escapes"], "evading_s": snappedf(float(r["evading_s"]), 0.1),
			"chasing_s": snappedf(float(r["chasing_s"]), 0.1), "cruising_s": snappedf(float(r["cruising_s"]), 0.1),
			"chase_ends": r["chase_ends"], "wall_s": (Time.get_ticks_msec() - t0) / 1000.0}
		out["runs"].append(row)
		print("[gameloop-verify] r2 live %s seed %d: pigeon %s eagle %s deaths %d catches %d end %s at %.1f min (wall %.0f s)" % [
			skill, s, ta.get("5", "-"), ta.get("9", "-"), r["deaths"], r["catches"], r["end_reason"],
			float(r["ended_at"]) / 60.0, row["wall_s"]])
		# Write after every run so a timeout still leaves the finished runs.
		var f := FileAccess.open(path, FileAccess.WRITE)
		if f:
			f.store_string(JSON.stringify(out, "  "))
			f.close()
	metric("r2_live_%s" % tag, out)
	check(out["runs"].size() == seeds.size(), "every requested run finished")
	sim.queue_free()
	await get_tree().process_frame
