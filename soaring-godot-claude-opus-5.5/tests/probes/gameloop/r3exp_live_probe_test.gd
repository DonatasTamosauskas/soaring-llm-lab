extends TestCase
## Verifier round 3 (experience & requirements lens) - live valley probe.
##
## The builder's G4 evidence ran the AI as of 12:56 (4638dab4f94c650d); the AI
## has changed since. This probe runs whole runs through the area's own
## IntegratedSim with the AI's real Ecosystem in the shipped valley
## (tests/shots/gameloop_live_sky.gd, world_kind valley) on FRESH seeds and the
## CURRENT AI code, and records per catch what a player would feel:
##  * when it happened (catch cadence, droughts),
##  * how far away the prey was, in wingspans and in felt metres
##    (world_scale = span / 1.7, WorldScaleDriver),
##  * how much catch assist was on at that moment,
## plus per-death times and the tier timeline. Output:
## artifacts/gameloop/verify/r3exp_live_<tag>.json (written after every run).
##
##   GD_TIMEOUT=2700 tools/gd.sh gl_r3exp_a --headless res://tests/runner.tscn -- \
##       --dir=res://tests/probes/gameloop --suite=r3exp_live --r3_seeds=300,301 \
##       --r3_skill=competent --r3_minutes=50 --r3_tag=a
##
## Without --r3_seeds it runs one 2-minute smoke run (keeps a whole-directory
## probe run bounded).

const LiveSky := preload("res://tests/shots/gameloop_live_sky.gd")
## Felt metres per player wingspan: WorldScaleDriver target = span / (arm 1.5 + 0.2).
const FELT_PER_SPAN := 1.7


func test_live_valley_runs_on_current_ai() -> void:
	var args := Paths.user_args()
	var seeds: Array[int] = []
	for s in String(args.get("r3_seeds", "")).split(",", false):
		seeds.append(int(s))
	var minutes := float(args.get("r3_minutes", "50"))
	if seeds.is_empty():
		seeds = [399]
		minutes = 2.0
	var skill := StringName(args.get("r3_skill", "competent"))
	var tag := String(args.get("r3_tag", "smoke"))
	var sim := IntegratedSim.new()
	sim.sky_factory = func() -> Node:
		var sky: Node = LiveSky.new()
		sky.set(&"world_kind", &"valley")
		return sky
	add_child(sim)
	await get_tree().process_frame
	var out := {"skill": skill, "minutes": minutes, "fingerprint": IntegratedSim.fingerprint(),
		"started": Time.get_datetime_string_from_system(), "runs": []}
	out.merge(IntegratedSim.sky_code(&"valley"))
	var path := Paths.artifacts("gameloop/verify").path_join("r3exp_live_%s.json" % tag)
	for s in seeds:
		var t0 := Time.get_ticks_msec()
		var catches: Array = []
		var deaths: Array = []
		var on_catch := func(pred: Bird, prey: Bird) -> void:
			if sim.loop == null:
				return
			if pred.is_player():
				var d := pred.get_body_position().distance_to(prey.get_body_position())
				var span := pred.get_wingspan()
				catches.append({"t": snappedf(sim.loop._clock, 0.1), "prey": String(prey.species),
					"prey_g": snappedf(prey.mass * 1000.0, 0.1), "me_g": snappedf(pred.mass * 1000.0, 0.1),
					"d_m": snappedf(d, 0.01), "d_spans": snappedf(d / span, 0.01),
					"d_felt_m": snappedf(d / span * FELT_PER_SPAN, 0.01),
					"assist": snappedf(sim.loop.rule.player_assist, 0.01),
					"worth": SizeRules.is_worthwhile(pred.mass, prey.mass)})
			elif prey.is_player():
				deaths.append({"t": snappedf(sim.loop._clock, 0.1), "by": String(pred.species),
					"me_g": snappedf(prey.mass * 1000.0, 0.1)})
		Events.bird_caught.connect(on_catch)
		var rv: Variant = await sim.run(skill, s, minutes * 60.0)
		Events.bird_caught.disconnect(on_catch)
		var r: Dictionary = rv
		var ta := {}
		for k in r["tier_at"]:
			ta[str(k)] = snappedf(float(r["tier_at"][k]), 0.1)
		var row := {"seed": s, "tier_at": ta, "deaths": r["deaths"], "catches": r["catches"], "chases": r["chases"],
			"victory_at": snappedf(float(r["victory_at"]), 0.1), "ended_at": snappedf(float(r["ended_at"]), 0.1),
			"end_reason": r["end_reason"], "attacks": r["attacks"], "escapes": r["escapes"],
			"slow_s": r["slow_s"], "stuck_s": r["stuck_s"], "hidden_catches": r["hidden_catches"],
			"cost_us": r["cost_us"], "chase_ends": r["chase_ends"],
			"catch_log": catches, "death_log": deaths, "wall_s": (Time.get_ticks_msec() - t0) / 1000.0}
		out["runs"].append(row)
		print("[gameloop-verify] r3exp live %s seed %d: pigeon %s eagle %s deaths %d catches %d end %s at %.1f min (wall %.0f s, ai %s)" % [
			skill, s, ta.get("5", "-"), ta.get("9", "-"), r["deaths"], r["catches"], r["end_reason"],
			float(r["ended_at"]) / 60.0, row["wall_s"], out.get("ai_code", "?")])
		var f := FileAccess.open(path, FileAccess.WRITE)
		if f:
			f.store_string(JSON.stringify(out, "  "))
			f.close()
	check(out["runs"].size() == seeds.size(), "every requested run finished")
	sim.queue_free()
	await get_tree().process_frame
