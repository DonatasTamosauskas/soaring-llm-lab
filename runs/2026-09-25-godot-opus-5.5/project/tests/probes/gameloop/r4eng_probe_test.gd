extends TestCase
## Round-4 engineering verifier probes for the game loop (not part of the
## area's suite; run with --dir=res://tests/probes/gameloop).
##
## 1. The stored valley evidence is reproducible: re-run one held-out
##    competent seed in the AI's sky in the shipped valley (the same code
##    the evidence's hashes name) and compare every one-minute checkpoint
##    and catch with the stored run. A mismatch means the evidence cannot be
##    reproduced from the tree (non-determinism, or a stale file).
## 2. Small contract probes (restart tier events, npc_ignore after quitting).
##
##   tools/gd.sh gameloop_verify2 --headless res://tests/runner.tscn -- --dir=res://tests/probes/gameloop --suite=r4eng

const LiveSky := preload("res://tests/shots/gameloop_live_sky.gd")
const LIVE_EVIDENCE := "res://scripts/game/data/live_ai_evidence.json"
const REPLAY_S := 360.0


static func _load(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var d: Variant = JSON.parse_string(f.get_as_text())
	return d if d is Dictionary else {}


func _replay(block: String, skill: String, seed_: int, replay_s: float = REPLAY_S) -> Dictionary:
	var ev := _load(LIVE_EVIDENCE)
	var stored := {}
	for r: Dictionary in ev.get(block, {}).get(skill, {}).get("runs", []):
		if int(r["seed"]) == seed_:
			stored = r
	check(not stored.is_empty(), "(setup) stored %s %s run seed %d" % [block, skill, seed_])
	if stored.is_empty():
		return {}
	var now := IntegratedSim.sky_code(&"valley")
	eq(String(now["ai_code"]), String(ev.get("ai_code", "")), "(setup) AI code as the evidence ran")
	eq(String(now["world_code"]), String(ev.get("world_code", "")), "(setup) valley code as the evidence ran")
	eq(IntegratedSim.fingerprint(), String(ev.get("fingerprint", "")), "(setup) game-loop code as the evidence ran")
	var sim := IntegratedSim.new()
	sim.sky_factory = func() -> Node:
		var sky: Node = LiveSky.new()
		sky.set(&"world_kind", &"valley")
		return sky
	add_child(sim)
	await get_tree().process_frame
	var t0 := Time.get_ticks_msec()
	var r: Dictionary = await sim.run(StringName(skill), seed_, replay_s)
	var wall := (Time.get_ticks_msec() - t0) / 1000.0
	var want_cp: Array = []
	for c: Array in stored["checkpoints"]:
		if float(c[0]) <= replay_s + 1e-6:
			want_cp.append(c)
	var got_cp: Array = r["checkpoints"]
	var cp_diffs: Array = []
	for i in mini(want_cp.size(), got_cp.size()):
		var a: Array = got_cp[i]
		var b: Array = want_cp[i]
		for k in b.size():
			if absf(float(a[k]) - float(b[k])) > 1e-3:
				cp_diffs.append([i, k, a[k], b[k]])
	var want_c: Array = []
	for c: Array in stored["catch_log"]:
		if float(c[0]) <= replay_s:
			want_c.append(c)
	var got_c: Array = []
	for c: Array in r["catch_log"]:
		if float(c[0]) <= replay_s:
			got_c.append(c)
	var out := {"seed": seed_, "block": block, "skill": skill, "wall_s": wall,
		"stored_checkpoints": want_cp, "replayed_checkpoints": got_cp, "checkpoint_diffs": cp_diffs,
		"stored_catches": want_c, "replayed_catches": got_c, "replayed_cost_us": r.get("cost_us", {}),
		"stored_tier_at": stored["tier_at"], "replayed_tier_at": r["tier_at"], "stored_deaths": stored["death_times"],
		"replayed_deaths": r["death_times"], "stored_victory_at": stored["victory_at"], "replayed_victory_at": r["victory_at"],
		"stored_ended_at": stored["ended_at"], "replayed_ended_at": r["ended_at"]}
	var path := Paths.artifacts("gameloop").path_join("verify/r4eng_valley_replay_%s_%d_%ds.json" % [skill, seed_, int(replay_s)])
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(out, "  "))
	print("[gameloop] r4eng replay %s %d: %d/%d checkpoints, %d diffs; catches stored %d replayed %d; %.1f s wall" % [
		skill, seed_, got_cp.size(), want_cp.size(), cp_diffs.size(), want_c.size(), got_c.size(), wall])
	sim.queue_free()
	await get_tree().process_frame
	return out


func test_valley_evidence_run_is_reproducible() -> void:
	var o := await _replay("holdout", "competent", 200)
	if o.is_empty():
		return
	eq((o["replayed_checkpoints"] as Array).size(), (o["stored_checkpoints"] as Array).size(), "same number of checkpoints")
	eq((o["checkpoint_diffs"] as Array).size(), 0, "every checkpoint (catches, deaths, mass, position) matches the stored run")
	eq((o["replayed_catches"] as Array).size(), (o["stored_catches"] as Array).size(), "same catches in the replayed minutes")


## A restart from a big bird drops the tier without a player_tier_changed
## (reason &"reset"): documents what UI/audio see on restart.
func test_restart_tier_event() -> void:
	var loop := GameLoop.new()
	loop.auto_step = false
	loop.verbose = false
	loop.records_path = "user://r4eng_records_%d.json" % OS.get_process_id()
	add_child(loop)
	var p := SimBird.new()
	p.player_mode = true
	p.mass = 0.03
	add_child(p)
	loop.start_run()
	p.mass = 3.2
	loop.step(1.0 / 60.0)
	var tiers: Array = []
	var cb := func(o: int, n: int) -> void: tiers.append([o, n])
	Events.player_tier_changed.connect(cb)
	loop.restart_run()
	Events.player_tier_changed.disconnect(cb)
	print("[gameloop] r4eng restart from eagle: tier events %s, species now %s" % [tiers, p.species])
	eq(p.species, &"sparrow", "species reset")
	metric("restart_tier_events", tiers)
	loop.quit_run()
	Game.set_state(Game.State.MENU)
	p.queue_free()
	loop.queue_free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://r4eng_records_%d.json" % OS.get_process_id()))
	await get_tree().process_frame


## A whole stored run, end to end (user args --r4_block, --r4_skill,
## --r4_seed, --r4_s; defaults: held-out competent seed 200, 50 minutes).
func test_valley_full_run_matches() -> void:
	var args := Paths.user_args()
	var block: String = args.get("r4_block", "holdout")
	var skill: String = args.get("r4_skill", "competent")
	var seed_ := int(args.get("r4_seed", "200"))
	var secs := float(args.get("r4_s", "3000"))
	var o := await _replay(block, skill, seed_, secs)
	if o.is_empty():
		return
	eq((o["checkpoint_diffs"] as Array).size(), 0, "every checkpoint matches over the whole run")
	eq((o["replayed_catches"] as Array).size(), (o["stored_catches"] as Array).size(), "same catches")
	eq(JSON.stringify(o["replayed_deaths"]), JSON.stringify(o["stored_deaths"]), "same deaths at the same times")
	near(float(o["replayed_ended_at"]), float(o["stored_ended_at"]), 0.01, "same end")


## Whole runs on seeds no tuning batch ever ran (--r4_seeds=400,401,...,
## --r4_tag): a genuinely out-of-sample check of the G4 medians (the
## evidence's "held-out" seeds 200-219 were run in the g5/g6/g7 tuning
## batches that chose GROWTH_GAIN). Writes verify/r4eng_unseen_<tag>.json.
func test_unseen_seeds() -> void:
	var args := Paths.user_args()
	if not args.has("r4_seeds"):
		check(true, "(skipped: no --r4_seeds)")
		return
	var tag := String(args.get("r4_tag", "x"))
	var sim := IntegratedSim.new()
	sim.sky_factory = func() -> Node:
		var sky: Node = LiveSky.new()
		sky.set(&"world_kind", &"valley")
		return sky
	add_child(sim)
	await get_tree().process_frame
	var rows := []
	for s in String(args["r4_seeds"]).split(","):
		var seed_ := int(s)
		var t0 := Time.get_ticks_msec()
		var r: Dictionary = await sim.run(&"competent", seed_, 3000.0)
		var ta := {}
		for k in r["tier_at"]:
			ta[str(k)] = float(r["tier_at"][k])
		rows.append({"seed": seed_, "tier_at": ta, "deaths": r["deaths"], "death_times": r["death_times"],
			"catches": r["catches"], "end_reason": r["end_reason"], "ended_at": r["ended_at"],
			"victory_at": r["victory_at"], "catch_log": r["catch_log"], "wall_s": (Time.get_ticks_msec() - t0) / 1000.0})
		print("[gameloop] r4eng unseen seed %d: pigeon %s eagle %s deaths %d end %s" % [seed_,
			ta.get(str(SizeRules.species_index(&"pigeon")), "-"), ta.get(str(SizeRules.species_index(&"eagle")), "-"),
			r["deaths"], r["end_reason"]])
		var f := FileAccess.open(Paths.artifacts("gameloop").path_join("verify/r4eng_unseen_%s.json" % tag), FileAccess.WRITE)
		if f:
			f.store_string(JSON.stringify({"fingerprint": IntegratedSim.fingerprint(), "sky": IntegratedSim.sky_code(&"valley"),
				"runs": rows}, "  "))
	sim.queue_free()
	await get_tree().process_frame
	check(rows.size() > 0, "runs finished")
