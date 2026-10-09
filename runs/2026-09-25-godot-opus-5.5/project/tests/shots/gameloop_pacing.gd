extends Node
## Pacing and danger tool (headless). Runs the integrated simulation
## (IntegratedSim: the real GameLoop, a mirror of the AI's sky, modelled
## players at three skills) and stores the evidence the pacing test asserts
## on; checks the AI mirror against the AI area's own duels; and a few
## diagnostics used while tuning.
##
##   tools/gd.sh gameloop --headless res://tests/shots/gameloop_pacing.tscn -- --integrated=10 --minutes=50
##
## --integrated=N   runs per skill (seeds 100..100+N-1), writes
##                  artifacts/gameloop/integrated.json (every run) and
##                  scripts/game/data/integrated_evidence.json (summaries,
##                  seeds, and IntegratedSim.fingerprint())
## --minutes=M      run length cap (default 50)
## --seed0=S        first seed (default 100; the evidence uses 100..)
## --skills=a,b     subset of novice,competent,expert (default all)
## --part=NAME      write artifacts/gameloop/integrated_part_NAME.json only
##                  (to run skills in parallel sandboxes), then
## --merge_parts=a,b,c  merge those parts into integrated.json and the evidence
## --live_ai        the same runs in the AI area's real sky: its Ecosystem in
##                  the world area's shipped valley (SoaringWorld;
##                  tests/shots/gameloop_live_sky.gd): files
##                  integrated_live[_part_NAME].json and
##                  scripts/game/data/live_ai_evidence.json (with hashes of
##                  the AI and world code it ran). --world=ai_test runs in
##                  the AI's own AiTestWorld instead (a tuning run).
## --holdout        with --live_ai and --seed0: the runs go to the evidence's
##                  "holdout" block (seeds never used for tuning)
## --model=a,b      fits PacingModel on the runs of integrated_live part files
##                  a,b (skill --skills, default competent; --mixed pools
##                  parts of different growth tunings) and prints its
##                  predictions for a grid of growth tunings; with
##                  --calibrate also writes scripts/game/data/
##                  pacing_model_calibration.json (what pacing_test checks the
##                  model against, out of sample)
## --duels=N        the AI's duel set with SimBrains on both sides, N trials
##                  per pair: artifacts/gameloop/duels.json
## Diagnostics: --hunt_detail=N [--quick] [--near_ground], --escape_detail=N
## [--npc_player] [--trace --tm= --tr=], --flight_check, --duel_detail=a>b,N,
## --laps (the AI's mock-player setup: hunting pressure and energy vs the
## AI snapshot), --sim_debug, --start_mass=.
## --quest_npcs=N [--quest_lod_near= --quest_lod_far=]: the AI's Ecosystem at
##                  the Quest quality tier's budget (28 NPCs, LOD 60/140 m).
## Knobs for sweeps (never the shipped values): --growth_gain=,
## --growth_exp=, --sky_growth_exp=, --sky_growth_floor=, --respite=, --grace=, --player_reach=, --reach_on_player=,
## --cone_on_player=, --horizon=, --horizon_exp=, --hunt_u=, --pilot_<key>=.

const EVIDENCE_PATH := "res://scripts/game/data/integrated_evidence.json"
## The same runs in the AI area's real sky (--live_ai).
const LIVE_EVIDENCE_PATH := "res://scripts/game/data/live_ai_evidence.json"
## The same in the Quest quality tier's sky (--quest_npcs=28, merged with
## --merge_parts=... --quest_evidence): fix round 5.
const LIVE_QUEST_EVIDENCE_PATH := "res://scripts/game/data/live_ai_quest_evidence.json"
const LiveSky := preload("res://tests/shots/gameloop_live_sky.gd")
const CALIBRATION_PATH := "res://scripts/game/data/pacing_model_calibration.json"


func _ready() -> void:
	var args := Paths.user_args()
	var n_int := int(args.get("integrated", "0"))
	var minutes := float(args.get("minutes", "50"))
	var skills: Array[StringName] = []
	for k in String(args.get("skills", "novice,competent,expert")).split(","):
		skills.append(StringName(k))
	var out_dir := Paths.artifacts("gameloop")
	if args.has("duel_detail"):
		# --duel_detail=hawk>pigeon[,n]: one line per duel (diagnostics).
		var spec: PackedStringArray = String(args["duel_detail"]).split(",")
		var pr := spec[0].split(">")
		var n := int(spec[1]) if spec.size() > 1 else 12
		var lab := ChaseLab.new()
		add_child(lab)
		for i in n:
			var r := lab.duel_trial(StringName(pr[0]), StringName(pr[1]), true, i, not args.has("game_rule"))
			print("[gameloop] %s #%d %s t=%.1f fled=%.1f min_d=%.2f jinks=%d stoop=%s" % [spec[0], i, r["reason"],
				r["t"], r["fled_at"], r["min_d"], r["jinks"], r["stooped"]])
		get_tree().quit(0)
		return
	if args.has("flight_check"):
		_flight_check()
		get_tree().quit(0)
		return
	if args.has("hunt_detail"):
		_hunt_detail(int(args["hunt_detail"]), args)
		get_tree().quit(0)
		return
	if args.has("escape_detail"):
		_escape_detail(int(args["escape_detail"]), args)
		get_tree().quit(0)
		return
	if args.has("merge_parts"):
		_merge_parts(String(args["merge_parts"]).split(","), out_dir, args.has("live_ai"), args.has("quest_evidence"))
		get_tree().quit(0)
		return
	if args.has("model"):
		_model(String(args["model"]).split(","), out_dir, args)
		get_tree().quit(0)
		return
	if args.has("duels"):
		await _duels(int(args.get("duels", "24")), out_dir)
	if n_int > 0:
		await _integrated(n_int, minutes, skills, out_dir, args)
	get_tree().quit(0)


## Experiment knobs (see the header). Nothing here is the shipped tuning.
static func _overrides(loop: GameLoop, args: Dictionary) -> void:
	if args.has("growth_gain"):
		SizeRules.growth_gain = float(args["growth_gain"])
	if args.has("growth_exp"):
		SizeRules.growth_size_exp = float(args["growth_exp"])
	if args.has("sky_growth_exp"):
		GameLoop.sky_growth_exp = float(args["sky_growth_exp"])
	if args.has("sky_growth_floor"):
		GameLoop.sky_growth_floor = float(args["sky_growth_floor"])
	if args.has("hunt_u"):
		AiMirror.hunt_utility_min = float(args["hunt_u"])
	if args.has("reach_on_player"):
		loop.rule.npc_reach_on_player = float(args["reach_on_player"])
	if args.has("cone_on_player"):
		loop.rule.npc_cone_on_player_deg = float(args["cone_on_player"])
	if args.has("horizon"):
		loop.watch.ttc_horizon = float(args["horizon"])
		loop.cue_horizon_exp = -1.0
	if args.has("horizon_exp"):
		loop.cue_horizon_exp = float(args["horizon_exp"])
	if args.has("no_overlap_on_player"):
		loop.rule.overlap_on_player = false
	if args.has("grace"):
		loop.escape_grace_s = float(args["grace"])
	if args.has("respite"):
		loop.attack_respite_s = float(args["respite"])
	if args.has("assist_respite"):
		loop.danger_assist_respite = float(args["assist_respite"])
	if args.has("opening"):
		loop.opening_respite_s = float(args["opening"])
	if args.has("bold_decay"):
		loop.bold_decay = float(args["bold_decay"])
	if args.has("bold_floor"):
		loop.bold_floor = float(args["bold_floor"])
	if args.has("respawn_respite"):
		loop.respawn_respite_s = float(args["respawn_respite"])
	if args.has("assist_cone"):
		loop.danger_assist_cone_deg = float(args["assist_cone"])
	if args.has("player_reach"):
		loop.rule.player_reach = float(args["player_reach"])
	if args.has("reach_exp"):
		loop.rule.player_reach_exp = float(args["reach_exp"])
	if args.has("no_sight_cue"):
		loop.sight_cue = false


static func _pilot_overrides(args: Dictionary) -> Dictionary:
	var out := {}
	for k: String in args:
		if k.begins_with("pilot_"):
			out[k.trim_prefix("pilot_")] = float(args[k])
	return out


## The AI area's duels with SimBrains on both sides (AiMirror.DUEL_*): the
## check that the mirror hunts and flees like the real AI.
func _duels(n: int, out_dir: String) -> void:
	var lab := ChaseLab.new()
	add_child(lab)
	var t := Time.get_ticks_msec()
	var res := {"trials": n, "ai_flee": AiMirror.DUEL_FLEE, "ai_calm": AiMirror.DUEL_CALM,
		"pairs": AiMirror.DUEL_PAIRS.map(func(pr: Array) -> String: return "%s>%s" % [pr[0], pr[1]])}
	for mode in [["flee_strict", true, true], ["calm_strict", false, true], ["flee_game", true, false], ["calm_game", false, false]]:
		var r := lab.measure_duels(mode[1], mode[2], n)
		res[mode[0]] = r
		var line := "[gameloop] duels %-11s overall %.2f |" % [mode[0], r["overall"]]
		for k: String in r["pairs"]:
			line += " %s %.2f" % [k, r["pairs"][k]["rate"]]
		print(line)
	# A few flight paths for the chart (the AI plots its own duels).
	lab.record_paths = true
	var paths := {}
	for pr: Array in [[&"hawk", &"pigeon"], [&"starling", &"sparrow"]]:
		for i in 2:
			var d := lab.duel_trial(pr[0], pr[1], true, i, true)
			paths["%s>%s #%d" % [pr[0], pr[1], i]] = {"reason": d["reason"], "t": d["t"],
				"hunter": _pts(d["path_hunter"]), "prey": _pts(d["path_prey"])}
	res["paths"] = paths
	print("[gameloop] duels in %.1f s" % ((Time.get_ticks_msec() - t) / 1000.0))
	_write(out_dir.path_join("duels.json"), JSON.stringify(res, "  "))
	lab.queue_free()
	await get_tree().process_frame


static func _pts(a: PackedVector3Array) -> Array:
	var out := []
	for v in a:
		out.append([snappedf(v.x, 0.01), snappedf(v.y, 0.01), snappedf(v.z, 0.01)])
	return out


func _integrated(n_int: int, minutes: float, skills: Array[StringName], out_dir: String, args: Dictionary) -> void:
	var t2 := Time.get_ticks_msec()
	var sim := IntegratedSim.new()
	sim.debug = args.has("sim_debug")
	sim.start_mass = float(args.get("start_mass", "-1"))
	sim.pilot_overrides = _pilot_overrides(args)
	sim.laps = args.has("laps")
	var live := args.has("live_ai")
	var world_kind := StringName(args.get("world", "valley"))
	if live:
		sim.sky_factory = func() -> Node:
			var sky: Node = LiveSky.new()
			sky.set(&"world_kind", world_kind)
			return sky
	sim.configure = func(s: IntegratedSim) -> void:
		_overrides(s.loop, args)
		if args.has("quest_npcs"):
			# The Quest quality tier (scripts/integration/quality_tier.gd):
			# the AI's Ecosystem at a smaller NPC budget and LOD radii.
			var e: Variant = s.eco.get(&"eco")
			if e is Node:
				(e as Node).set(&"max_npcs", int(args["quest_npcs"]))
				(e as Node).set(&"lod_near", float(args.get("quest_lod_near", "60")))
				(e as Node).set(&"lod_far", float(args.get("quest_lod_far", "140")))
		if s.laps:
			s.loop.player_catchable = false  # as the AI's mock player
		if args.has("open_air"):
			s.eco.set(&"ground_y", -INF)
			s.player.ground_y = -INF
	add_child(sim)
	var tuning := not _pilot_overrides(args).is_empty() or sim.laps or sim.start_mass > 0.0
	for k in ["growth_gain", "growth_exp", "sky_growth_exp", "sky_growth_floor", "hunt_u", "reach_on_player", "cone_on_player", "horizon", "horizon_exp",
			"no_overlap_on_player", "grace", "respite", "player_reach", "open_air", "reach_exp", "no_sight_cue",
			"assist_respite", "opening", "bold_decay", "bold_floor", "assist_cone",
			"respawn_respite", "quest_npcs"]:
		tuning = tuning or args.has(k)
	# Other seeds are a tuning run, unless they are the held-out ones.
	var holdout := args.has("holdout")
	tuning = tuning or (args.has("seed0") and not holdout) or (live and world_kind != &"valley")
	var full := {}
	var ev := {}
	full["minutes"] = minutes
	full["fingerprint"] = IntegratedSim.fingerprint()
	ev["minutes"] = minutes
	ev["fingerprint"] = IntegratedSim.fingerprint()
	ev["dt"] = IntegratedSim.DT
	if live:
		ev["sky"] = "live_ai"
		ev["world"] = String(world_kind)
		ev.merge(IntegratedSim.sky_code(world_kind))
		ev["date"] = Time.get_datetime_string_from_system()
		full["sky"] = "live_ai"
		full["world"] = String(world_kind)
	# Everything a sweep may vary (the merge refuses parts that differ).
	ev["tuning"] = {"growth_gain": float(args.get("growth_gain", SizeRules.GROWTH_GAIN)),
		"growth_exp": float(args.get("growth_exp", SizeRules.GROWTH_SIZE_EXP)),
		"respite": float(args.get("respite", GameLoop.ATTACK_RESPITE_S)),
		"sky_growth_exp": float(args.get("sky_growth_exp", GameLoop.SKY_GROWTH_EXP)),
		"sky_growth_floor": float(args.get("sky_growth_floor", GameLoop.SKY_GROWTH_FLOOR)),
		"bold_decay": float(args.get("bold_decay", GameLoop.BOLD_DECAY)),
		"bold_floor": float(args.get("bold_floor", GameLoop.BOLD_FLOOR)),
		"grace": float(args.get("grace", GameLoop.ESCAPE_GRACE_S)),
		"reach_on_player": float(args.get("reach_on_player", CatchRule.new().npc_reach_on_player)),
		"cone_on_player": float(args.get("cone_on_player", CatchRule.new().npc_cone_on_player_deg))}
	for k in ["assist_respite", "assist_cone", "respawn_respite", "opening", "reach_exp",
			"no_sight_cue", "player_reach", "horizon", "horizon_exp",
			"quest_npcs", "quest_lod_near", "quest_lod_far"]:
		if args.has(k):
			ev["tuning"][k] = args[k]
	var stem := "integrated_live" if live else "integrated"
	var skills_ev: Dictionary = ev.get("skills", {})
	for skill: StringName in skills:
		var runs: Array = []
		var seed0 := int(args.get("seed0", "100"))
		for i in n_int:
			var returns := _CueReturns.new(sim)
			Events.threat_changed.connect(returns.on_threat)
			var r: Dictionary = await sim.run(skill, seed0 + i, minutes * 60.0)
			Events.threat_changed.disconnect(returns.on_threat)
			r["cue_returns"] = returns.result()
			r["seed"] = seed0 + i
			runs.append(r)
			print("[gameloop] integrated %s run %d: %s" % [skill, i, _brief(r)])
			if args.has("part"):
				# Partial part after every run: a stopped batch keeps its runs.
				var so_far := ev.duplicate(true)
				so_far["partial"] = true
				so_far["holdout" if holdout else "skills"] = {String(skill): {"summary": IntegratedSim.summarize(runs),
					"runs": runs.map(_compact)}}
				_write(out_dir.path_join("%s_part_%s.json" % [stem, args["part"]]), _json({"evidence": so_far}))
		var summ := IntegratedSim.summarize(runs)
		full[String(skill)] = summ.duplicate()
		full[String(skill)]["raw"] = runs
		skills_ev[String(skill)] = {"summary": summ, "runs": runs.map(_compact)}
		var q: Dictionary = summ["tiers"]
		print("[gameloop] integrated %-9s%s pigeon %s eagle %s deaths %s caught-out %.0f%% (n=%d)" % [skill,
			" (holdout)" if holdout else "",
			_mmss(q[SizeRules.species_index(&"pigeon")]["median"]), _mmss(q[SizeRules.species_index(&"eagle")]["median"]),
			summ["deaths"]["median"], float(summ["ended_caught"]) * 100.0, n_int])
	if holdout:
		ev["holdout"] = skills_ev
	else:
		ev["skills"] = skills_ev
	if args.has("part"):
		full["evidence"] = ev
		_write(out_dir.path_join("%s_part_%s.json" % [stem, args["part"]]), _json(full))
		sim.queue_free()
		return
	_write(out_dir.path_join(stem + ".json"), _json(full))
	if tuning:
		print("[gameloop] (tuning run: evidence file left alone)")
	else:
		_write_evidence(LIVE_EVIDENCE_PATH if live else EVIDENCE_PATH, ev)
	print("[gameloop] integrated sim in %.1f s" % [(Time.get_ticks_msec() - t2) / 1000.0])
	sim.queue_free()


## Writes stored evidence into the project (and the real checkout when run
## in a sandbox copy).
static func _write_evidence(res_path: String, ev: Dictionary) -> void:
	_write(ProjectSettings.globalize_path(res_path), _json(ev))
	var root := OS.get_environment("SOARING_ROOT")
	if not root.is_empty():
		_write(root.path_join(res_path.trim_prefix("res://")), _json(ev))


## JSON with every non-finite number (a tier never reached: INF) as null:
## Godot's parser warns ("Exponent too high") on the 1e99999 that
## JSON.stringify writes for INF, once per value, every time a test loads
## the file. Readers map null back to INF (IntegratedSim.num).
static func _json(v: Variant) -> String:
	return JSON.stringify(_finite(v), "  ")


static func _finite(v: Variant) -> Variant:
	match typeof(v):
		TYPE_FLOAT:
			return v if is_finite(v) else null
		TYPE_DICTIONARY:
			var out := {}
			for k: Variant in v:
				out[k] = _finite(v[k])
			return out
		TYPE_ARRAY:
			var out := []
			for x: Variant in v:
				out.append(_finite(x))
			return out
	return v


func _merge_parts(names: PackedStringArray, out_dir: String, live: bool, quest: bool = false) -> void:
	# Parts may split one skill's seeds over several processes (a run of the
	# valley takes minutes, and gd.sh caps a process at 45): runs of the same
	# skill and block are concatenated, in seed order, and summarised again.
	var stem := "integrated_live" if live else "integrated"
	var full := {}
	var ev := {}
	var runs := {}  # "block/skill" -> {"compact": [], "raw": []}
	for nm in names:
		var part := _read_json(out_dir.path_join("%s_part_%s.json" % [stem, nm]))
		if part.is_empty():
			push_error("[gameloop] missing part " + nm)
			return
		var pev: Dictionary = part["evidence"]
		if bool(pev.get("partial", false)):
			push_error("[gameloop] part %s is unfinished (its batch did not complete)" % nm)
			return
		if ev.has("fingerprint") and ev["fingerprint"] != pev["fingerprint"]:
			push_error("[gameloop] parts come from different code (fingerprints differ)")
			return
		for k in ["ai_code", "world_code", "core_code", "world", "minutes"]:
			if ev.has(k) and ev[k] != pev.get(k):
				push_error("[gameloop] parts ran different %s" % k)
				return
		if ev.has("tuning") and JSON.stringify(ev["tuning"]) != JSON.stringify(pev.get("tuning")):
			push_error("[gameloop] parts ran different tunings")
			return
		for k in ["minutes", "fingerprint", "dt", "sky", "world", "ai_code", "world_code", "core_code", "date", "tuning"]:
			if pev.has(k):
				ev[k] = pev[k]
				full[k] = pev.get(k)
		for block in ["skills", "holdout"]:
			if not pev.has(block):
				continue
			for skill in pev[block]:
				var key := "%s/%s" % [block, skill]
				if not runs.has(key):
					runs[key] = {"compact": [], "raw": []}
				(runs[key]["compact"] as Array).append_array(pev[block][skill]["runs"])
				(runs[key]["raw"] as Array).append_array(part[skill]["raw"])
	for key: String in runs:
		var block := key.get_slice("/", 0)
		var skill := key.get_slice("/", 1)
		var by_seed := func(a: Dictionary, b: Dictionary) -> bool: return int(a["seed"]) < int(b["seed"])
		var compact: Array = runs[key]["compact"]
		var raw: Array = runs[key]["raw"]
		compact.sort_custom(by_seed)
		raw.sort_custom(by_seed)
		var seeds := {}
		for r: Dictionary in compact:
			if seeds.has(int(r["seed"])):
				push_error("[gameloop] seed %d of %s is in two parts" % [int(r["seed"]), key])
				return
			seeds[int(r["seed"])] = true
		var summ := IntegratedSim.summarize(raw.map(_restore))
		if not ev.has(block):
			ev[block] = {}
		ev[block][skill] = {"summary": summ, "runs": compact}
		var fk := ("holdout_" if block == "holdout" else "") + skill
		full[fk] = summ.duplicate()
		full[fk]["raw"] = raw
	if quest and not (ev.get("tuning", {}) as Dictionary).has("quest_npcs"):
		push_error("[gameloop] --quest_evidence: the parts did not run the Quest tier (--quest_npcs)")
		return
	_write(out_dir.path_join(stem + ("_quest" if quest else "") + ".json"), _json(full))
	_write_evidence(LIVE_QUEST_EVIDENCE_PATH if quest else (LIVE_EVIDENCE_PATH if live else EVIDENCE_PATH), ev)
	print("[gameloop] merged %d parts, fingerprint %s%s: %s" % [names.size(), ev.get("fingerprint", ""),
		(", AI code %s, world code %s" % [ev.get("ai_code", ""), ev.get("world_code", "")]) if live else "",
		runs.keys().map(func(k: String) -> String: return "%s x%d" % [k, (runs[k]["compact"] as Array).size()])])


## A run read back from JSON: a tier never reached (stored as null) is INF.
static func _restore(r: Dictionary) -> Dictionary:
	var out := r.duplicate()
	var ta := {}
	for k in r["tier_at"]:
		ta[int(k)] = INF if r["tier_at"][k] == null else float(r["tier_at"][k])
	out["tier_at"] = ta
	out["victory_at"] = -1.0 if r.get("victory_at") == null else float(r["victory_at"])
	return out


## What the evidence keeps of a run (enough to replay-check and chart it).
static func _compact(r: Dictionary) -> Dictionary:
	var ta := {}
	for k in r["tier_at"]:
		ta[str(k)] = snappedf(float(r["tier_at"][k]), 0.001)
	return {"seed": r["seed"], "tier_at": ta, "deaths": r["deaths"], "death_times": r.get("death_times", []),
		"death_by": r.get("death_by", []), "catches": r["catches"], "victory_at": snappedf(float(r["victory_at"]), 0.001),
		"ended_at": snappedf(float(r["ended_at"]), 0.001), "end_reason": r["end_reason"], "attacks": r.get("attacks", 0),
		"close_attacks": r.get("close_attacks", 0), "escapes": r.get("escapes", 0), "npc_catches": r.get("npc_catches", 0),
		"evading_s": snappedf(float(r.get("evading_s", 0.0)), 0.1), "chasing_s": snappedf(float(r.get("chasing_s", 0.0)), 0.1),
		"calm_energy": r.get("calm_energy", []), "checkpoints": r.get("checkpoints", []),
		"world_hits": r.get("world_hits", 0), "stuck_s": r.get("stuck_s", 0.0), "unpins": r.get("unpins", 0),
		"hidden_catches": r.get("hidden_catches", 0),
		"ground_launches": r.get("ground_launches", 0), "slow_s": r.get("slow_s", 0.0),
		"cost_us": r.get("cost_us", {}), "catch_log": r.get("catch_log", []), "cue": r.get("cue", {}),
		"cue_returns": r.get("cue_returns", {}), "target_cue": r.get("target_cue", {}),
		"bands": _compact_bands(r.get("bands", {}))}


static func _compact_bands(b: Dictionary) -> Dictionary:
	if b.is_empty():
		return {}
	var t := []
	for x in b["t"]:
		t.append(snappedf(float(x), 0.01))
	return {"t": t, "chases": b["chases"], "deaths": b["deaths"], "ratios": b["ratios"]}


## Fits PacingModel on the runs of part files and prints what it predicts for
## a grid of growth tunings (and, with --calibrate, stores the fit).
func _model(parts: PackedStringArray, out_dir: String, args: Dictionary) -> void:
	var skill := String(args.get("skills", "competent"))
	var runs: Array = []
	var tuning := {}
	var meta := {}
	for nm in parts:
		var part := _read_json(out_dir.path_join("integrated_live_part_%s.json" % nm))
		if part.is_empty():
			push_error("[gameloop] missing part " + nm)
			return
		var pev: Dictionary = part["evidence"]
		if not tuning.is_empty() and JSON.stringify(tuning) != JSON.stringify(pev.get("tuning", {})) and not args.has("mixed"):
			push_error("[gameloop] model parts ran different tunings (--mixed pools them: the model's band rates do not depend on the growth tuning)")
			return
		tuning = pev.get("tuning", {})
		for k in ["fingerprint", "ai_code", "world_code", "core_code", "world"]:
			# (--mixed also pools parts of this area's code versions that
			# only differ in diagnostics: a tuning aid, never --calibrate.)
			if meta.has(k) and meta[k] != pev.get(k, "") and not (args.has("mixed") and k == "fingerprint" and not args.has("calibrate")):
				push_error("[gameloop] model parts ran different %s" % k)
				return
			meta[k] = pev.get(k, "")
		for block in ["skills", "holdout"]:
			if pev.has(block) and (pev[block] as Dictionary).has(skill):
				runs.append_array(pev[block][skill]["runs"])
	var total := PacingModel.pool_runs(runs)
	var model := PacingModel.new().fit(total, runs.size())
	# (Stored runs keep a tier never reached as null: restore INF first.)
	var measured := IntegratedSim.summarize(runs.map(_restore))
	print("[gameloop] model fitted on %d %s runs (tuning %s)" % [runs.size(), skill, tuning])
	print("[gameloop] measured: pigeon %s eagle %s deaths %s" % [_mmss(measured["tiers"][5]["median"]),
		_mmss(measured["tiers"][9]["median"]), measured["deaths"]["median"]])
	var at_fit := model.simulate(2000, 1, 50.0 * 60.0, float(tuning.get("growth_gain", 1.0)),
			float(tuning.get("growth_exp", 0.22)))
	print("[gameloop] model at the fitted tuning: pigeon %s eagle %s deaths %s victory %.0f%%" % [
		_mmss(at_fit["tiers"][5]["median"]), _mmss(at_fit["tiers"][9]["median"]), at_fit["deaths"]["median"],
		float(at_fit["victory"]["reached"]) * 100.0])
	var gains := [0.8, 0.9, 1.0, 1.1, 1.2, 1.3, 1.45, 1.6]
	var exps := [0.15, 0.22, 0.3, 0.4]
	if args.has("grid_g"):
		gains = Array(String(args["grid_g"]).split(",")).map(func(x: String) -> float: return float(x))
	if args.has("grid_e"):
		exps = Array(String(args["grid_e"]).split(",")).map(func(x: String) -> float: return float(x))
	for g in gains:
		var line := "[gameloop] model gain %.2f:" % g
		for e in exps:
			var sm := model.simulate(1000, 2, 50.0 * 60.0, g, e)
			line += "  exp %.2f pigeon %s eagle %s" % [e, _mmss(sm["tiers"][5]["median"]), _mmss(sm["tiers"][9]["median"])]
		print(line)
	# The Quest tier's growth factor (GameLoop.sky_growth): x (60 / npcs)^(k x
	# ramp), the ramp 1 (flat) or rising with log mass from the sparrow to the
	# eagle (--sky_ramp), for k in --grid_sky, at --sky_npcs (default 28),
	# with the growth tuning of --sky_gain / --sky_exp (default the shipped).
	if args.has("grid_sky"):
		var npcs := float(args.get("sky_npcs", "28"))
		var ramped := args.has("sky_ramp")
		var floor_ := float(args.get("sky_floor", "0.0"))
		var sg := float(args.get("sky_gain", str(SizeRules.GROWTH_GAIN)))
		var se := float(args.get("sky_exp", str(SizeRules.GROWTH_SIZE_EXP)))
		for k in Array(String(args["grid_sky"]).split(",")).map(func(x: String) -> float: return float(x)):
			model.meal_factor = func(mm: float) -> float:
				var ramp := lerpf(floor_, 1.0, clampf(log(mm / GameLoop.START_MASS) / log(3.0 / GameLoop.START_MASS), 0.0, 1.0)) if ramped else 1.0
				return minf(pow(60.0 / npcs, k * ramp), GameLoop.SKY_GROWTH_MAX)
			var sm := model.simulate(1000, 3, 50.0 * 60.0, sg, se)
			print("[gameloop] model sky k %.2f%s: pigeon %s eagle %s (reached %.0f%%) victory %.0f%%" % [k, " ramped" if ramped else "",
				_mmss(sm["tiers"][5]["median"]), _mmss(sm["tiers"][9]["median"]), float(sm["tiers"][9]["reached"]) * 100.0,
				float(sm["victory"]["reached"]) * 100.0])
		model.meal_factor = Callable()
	if args.has("calibrate"):
		var cal := {"skill": skill, "n_runs": runs.size(), "tuning": tuning, "bands": total,
			"measured": {"pigeon_min": float(measured["tiers"][5]["median"]) / 60.0,
				"eagle_min": float(measured["tiers"][9]["median"]) / 60.0},
			"model": model.to_dict()}
		cal.merge(meta)
		_write_evidence(CALIBRATION_PATH, cal)


func _flight_check() -> void:
	for sp in [[&"sparrow", 0.03], [&"gull", 1.05], [&"hawk", 1.3], [&"pigeon", 0.35]]:
		var b := SimBird.new()
		b.species = sp[0]
		b.mass = sp[1]
		add_child(b)
		b.global_position = Vector3(0, 200, 0)
		b.speed = b.cruise_speed()
		b.set_heading(Vector3.FORWARD)
		var line := "[gameloop] flight %s m=%.2f cruise %.1f sprint %.1f:" % [sp[0], sp[1], b.cruise_speed(), b.sprint_speed()]
		for i in 300:
			b.fly(Vector3.FORWARD, b.max_speed(), 1.0 / 30.0, 1.0, 1.0)
			if i % 30 == 29:
				line += " %.1f(e%.2f)" % [b.speed, b.energy]
		print(line)
		b.queue_free()


func _hunt_detail(n: int, args: Dictionary) -> void:
	var lab := ChaseLab.new()
	add_child(lab)
	_overrides(lab.loop, args)
	lab.near_ground = args.has("near_ground")
	lab.pilot_overrides = _pilot_overrides(args)
	for skill: StringName in [&"novice", &"competent", &"expert"]:
		var line := "[gameloop] hunt %-9s" % skill
		for m in ([0.03, 0.09, 0.35] if args.has("quick") else [0.03, 0.09, 0.35, 1.1, 4.5]):
			for r in [0.6, 0.32, 0.14]:
				var e := lab.measure_hunt(m, r, skill, n, 5, float(args.get("assist", "0")))
				line += " m%.2f/r%.2f %.2f(%.0fs)" % [m, r, e["p"], e["t_catch"]]
		print(line)


func _escape_detail(n: int, args: Dictionary) -> void:
	var lab := ChaseLab.new()
	add_child(lab)
	_overrides(lab.loop, args)
	lab.pilot_overrides = _pilot_overrides(args)
	lab.trace = args.has("trace")
	lab.npc_player = args.has("npc_player")
	if lab.trace:
		var one := lab.escape_trial(float(args.get("tm", "0.09")), float(args.get("tr", "3.0")), &"competent", 5)
		print("[gameloop] escape trial ", one)
		return
	for skill: StringName in [&"novice", &"competent", &"expert"]:
		var line := "[gameloop] escape %-9s" % skill
		for m in [0.03, 0.09, 0.35, 1.1]:
			for r in [1.8, 3.0, 5.0]:
				var e := lab.measure_escape(m, r, skill, n, 5)
				line += " m%.2f/r%.1f %.2f" % [m, r, e["p"]]
		print(line)


static func _mmss(s: Variant) -> String:
	var x := float(s)
	if not is_finite(x):
		return "never"
	return "%d:%02d" % [int(x) / 60, int(x) % 60]


static func _read_json(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var d: Variant = JSON.parse_string(f.get_as_text())
	return d if d is Dictionary else {}


static func _write(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string(text)
		print("[gameloop] wrote ", path)
	else:
		push_error("[gameloop] cannot write " + path)


static func _brief(r: Dictionary) -> String:
	var parts: Array[String] = []
	var ta: Dictionary = r["tier_at"]
	for t in range(3, SizeRules.SPECIES.size()):
		if ta.has(t):
			parts.append("%s %s" % [SizeRules.SPECIES[t]["id"], _mmss(ta[t])])
	return "%s | deaths %d %s catches %d chases %d %s | chase %.0fs cruise %.0fs evade %.0fs | hunts-on-player %d (%.2f/min) close %d escapes %d ends %s | calm energy %s | npc_catches %d wall hits %d stuck %.0fs slow %.0fs launches %d hidden catches %d end %s at %s" % [
		", ".join(parts), r["deaths"], r.get("death_by", []), r["catches"], r["chases"], r.get("chase_ends", {}),
		r.get("chasing_s", 0.0), r.get("cruising_s", 0.0), r.get("evading_s", 0.0),
		r.get("attacks", 0), float(r.get("attacks", 0)) / maxf(float(r["ended_at"]) / 60.0, 0.01), r.get("close_attacks", 0),
		r.get("escapes", 0), r.get("hunt_ends", {}), r.get("calm_energy", []), r.get("npc_catches", 0),
		r.get("world_hits", 0), float(r.get("stuck_s", 0.0)), float(r.get("slow_s", 0.0)), r.get("ground_launches", 0),
		r.get("hidden_catches", 0), r["end_reason"], _mmss(r["ended_at"])]


## The threat cue's A -> B -> A returns in a run (IntegratedSim's "cue"
## ping_pong: a shown cue hops to another shown bird and back within
## IntegratedSim.CUE_PING_PONG_S), split by what they were: two birds taking
## turns at attack strength (each one's own raw threat at least
## GameLoop.ATTACK_LEVEL when it took the name - two hunters diving in turn,
## which the cue must follow) or anything else (flicker: the defect fix
## round 4 removed, the name bouncing through a bird that was not attacking).
## Kept here, not in IntegratedSim, so adding it changed no evidence
## fingerprint (fix round 4: the mirror's old AI sends two or three hunters
## at once).
class _CueReturns:
	var sim: IntegratedSim
	var id := 0
	var lv := 0.0
	var prev := 0
	var at := -INF
	var hop := false
	var prev_attacking := false
	var cur_attacking := false
	var total := 0
	var between_attackers := 0

	func _init(s: IntegratedSim) -> void:
		sim = s

	func on_threat(level: float, pred: Bird) -> void:
		var t := sim.loop.stats.run_time
		var nid := pred.get_instance_id() if pred != null else 0
		if id != 0 and nid != 0 and nid != id:
			var h := lv >= IntegratedSim.CUE_VISIBLE and level >= IntegratedSim.CUE_VISIBLE
			var attacking := sim.loop.watch.raw_of(pred) >= GameLoop.ATTACK_LEVEL
			if h and nid == prev and hop and t - at < IntegratedSim.CUE_PING_PONG_S:
				total += 1
				if attacking and cur_attacking:
					between_attackers += 1
			prev = id
			at = t
			hop = h
			prev_attacking = cur_attacking
			cur_attacking = attacking
		elif nid != id:
			cur_attacking = pred != null and sim.loop.watch.raw_of(pred) >= GameLoop.ATTACK_LEVEL
		id = nid
		lv = level

	func result() -> Dictionary:
		return {"total": total, "between_attackers": between_attackers, "flicker": total - between_attackers}
