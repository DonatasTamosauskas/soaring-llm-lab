extends "res://tests/unit/game/game_fixture.gd"
## Verifier round 2 probe: WHY is the modelled player so much faster in the
## shipped valley than in the AI's test world? Records the context of every
## catch the player makes (was the prey perched? fleeing? what was it?) in
## both skies with the same seed and AI code.
##
##   GD_TIMEOUT=2000 tools/gd.sh gl_r2ctx --headless res://tests/runner.tscn -- \
##       --dir=res://tests/probes/gameloop --suite=r2_catch_context [--r2_seeds=103,100] [--r2_minutes=10]

const ValleySky := preload("res://tests/probes/gameloop/r2_valley_sky.gd")
const LiveSky := preload("res://tests/shots/gameloop_live_sky.gd")
const FixedSim := preload("res://tests/probes/gameloop/r2_integrated_sim_fixed.gd")

var _rows: Array = []


func _r2_on_bird_caught(pred: Bird, prey: Bird) -> void:
	if pred == null or not pred.is_player():
		return
	var st := ""
	if prey is NpcBird:
		st = String(NpcBird.State.keys()[(prey as NpcBird).state])
	var row := {"prey": prey.species, "perched": prey.perched, "state": st}
	var rf: Variant = prey.get(&"refuge")
	if st == "HIDE" and rf is Dictionary and not (rf as Dictionary).is_empty():
		var r: Dictionary = rf
		row["refuge"] = String(r.get("name", "?"))
		row["d_centre"] = snappedf(prey.get_body_position().distance_to(r["position"]), 0.01)
		row["radius"] = snappedf(float(r.get("radius", 0.0)), 0.01)
		row["max_span"] = snappedf(float(r.get("max_span", 0.0)), 0.01)
		row["player_span"] = snappedf(pred.get_wingspan(), 0.01)
		row["inside"] = float(row["d_centre"]) <= float(row["radius"])
		row["player_fits"] = float(row["player_span"]) <= float(row["max_span"])
	_rows.append(row)


func test_catch_context_in_both_skies() -> void:
	var args := Paths.user_args()
	var seeds: Array[int] = []
	for s in String(args.get("r2_seeds", "103,100")).split(",", false):
		seeds.append(int(s))
	var minutes := float(args.get("r2_minutes", "10"))
	Events.bird_caught.connect(_r2_on_bird_caught)
	var report := {}
	for sky in ["valley", "ai"]:
		var sim = FixedSim.new()
		sim.sky_factory = (func() -> Node: return LiveSky.new()) if sky == "ai" else (func() -> Node: return ValleySky.new())
		add_child(sim)
		await get_tree().process_frame
		for s in seeds:
			_rows.clear()
			var r: Dictionary = await sim.run(&"competent", s, minutes * 60.0)
			var perched := 0
			var hide_rows := []
			var states := {}
			var species := {}
			for row: Dictionary in _rows:
				if row["perched"]:
					perched += 1
				if row.has("refuge"):
					hide_rows.append(row)
				states[row["state"]] = int(states.get(row["state"], 0)) + 1
				species[String(row["prey"])] = int(species.get(String(row["prey"]), 0)) + 1
			var key := "%s_%d" % [sky, s]
			report[key] = {"minutes": snappedf(float(r["ended_at"]) / 60.0, 0.1), "catches": _rows.size(), "perched": perched,
				"prey_state": states, "species": species, "hide_catches": hide_rows, "chases": r["chases"], "chase_ends": r["chase_ends"],
				"tier_at_min": r["tier_at"].keys().map(func(k: Variant) -> String: return "%s@%.1f" % [SizeRules.SPECIES[int(k)]["id"], float(r["tier_at"][k]) / 60.0])}
			print("[gameloop-verify] catch context %s: %s" % [key, JSON.stringify(report[key])])
		sim.queue_free()
		await get_tree().process_frame
	Events.bird_caught.disconnect(_r2_on_bird_caught)
	metric("catch_context", report)
	var f := FileAccess.open(Paths.artifacts("gameloop/verify").path_join("r2_catch_context.json"), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(report, "  "))
		f.close()
	check(not report.is_empty(), "recorded")
