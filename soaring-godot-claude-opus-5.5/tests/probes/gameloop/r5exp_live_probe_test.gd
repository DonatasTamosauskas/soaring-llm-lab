extends TestCase
## Verifier probe (fix-round-4 review, experience lens): whole modelled runs
## in the game's sky AS IT IS IN THE TREE NOW (the AI's current Ecosystem in
## the world's current valley, via the builder's own LiveSky / IntegratedSim),
## on fresh seeds (6100+, on no list in used_seeds.json), to check whether the
## G4 pacing still holds in the game that exists today (the builder's
## evidence ran a frozen 00:21 sky), plus two experience metrics the
## builder's harness does not collect:
##  * masked attacks: a predator hunting the player at attack strength
##    (own smoothed level >= 0.3) that the cue does NOT name, while the level
##    the cue reports is at least 0.15 below it (the HUD / haptics / call
##    understate the danger) - time, episodes, worst case;
##  * deaths without warning: at the moment of each catch of the player,
##    whether the killer was the named bird, and the highest level the cue
##    reported about the killer in the 1.5 s before.
## One or a few seeds per process:
##   GD_TIMEOUT=2700 tools/gd.sh gameloop_verify_a --headless res://tests/runner.tscn -- \
##     --dir=res://tests/probes/gameloop --suite=r5exp_live --r5_seeds=6100 --r5_tag=c6100
## Optional: --r5_skill=novice|competent|expert, --r5_minutes=50, --r5_quest (28 NPCs, LOD 60/140).
## Writes artifacts/gameloop/verify/r5exp_live_<tag>.json. Not part of any suite.

const LiveSky := preload("res://tests/shots/gameloop_live_sky.gd")


## ThreatWatch with per-step bookkeeping of what the cue shows versus what
## is actually attacking (the loop replaces nothing else).
class ProbeWatch extends ThreatWatch:
	var player_ref: Bird = null
	var masked_s := 0.0
	var masked_episodes := 0
	var masked_longest_s := 0.0
	var masked_worst_gap := 0.0
	var masked_worst := {}
	var _masked_run := 0.0
	## Attack onsets (an unnamed or named hunter's own level first >= 0.3):
	## seconds until the cue names it (INF if never within the episode).
	var onset_delays: Array[float] = []
	## instance id -> seconds since its own level crossed 0.3 while unnamed (or -1).
	var _pending := {}
	## Rolling history: [t, named id, reported level] for the last 2 s.
	var hist: Array = []
	var t := 0.0

	func update(p: Bird, birds: Array[Bird], dt: float, rule: CatchRule, apply_highlights: bool = true) -> int:
		var m := super.update(p, birds, dt, rule, apply_highlights)
		t += dt
		player_ref = p
		var named_id := predator.get_instance_id() if predator != null and is_instance_valid(predator) else 0
		hist.append([t, named_id, level])
		while hist.size() > 0 and t - float(hist[0][0]) > 2.0:
			hist.pop_front()
		# Worst hunter (own smoothed level) that is not the named bird.
		var worst := 0.0
		var worst_id := 0
		for id: int in _threats:
			var g = _threats[id]
			var q := instance_from_id(id) as Bird
			if q == null or not q.alive or not IntegratedSim.hunts(q, p):
				continue
			var lv: float = g.level
			if lv >= 0.3:
				if id == named_id:
					if _pending.has(id):
						onset_delays.append(float(_pending[id]))
						_pending.erase(id)
				elif not _pending.has(id):
					_pending[id] = 0.0
			if id != named_id and lv > worst:
				worst = lv
				worst_id = id
		for id: int in _pending.keys():
			var q2 := instance_from_id(id) as Bird
			var g2 = _threats.get(id)
			if q2 == null or g2 == null or not q2.alive or float(g2.level) < 0.1:
				onset_delays.append(INF)  # the attack ended unnamed
				_pending.erase(id)
			else:
				_pending[id] = float(_pending[id]) + dt
		var masked := worst >= 0.3 and worst - level >= 0.15
		if masked:
			masked_s += dt
			if _masked_run <= 0.0:
				masked_episodes += 1
			_masked_run += dt
			masked_longest_s = maxf(masked_longest_s, _masked_run)
			if worst - level > masked_worst_gap:
				masked_worst_gap = worst - level
				var wq := instance_from_id(worst_id) as Bird
				masked_worst = {"t": snappedf(t, 0.01), "hunter": String(wq.species) if wq else "?",
					"hunter_level": snappedf(worst, 0.001), "reported": snappedf(level, 0.001),
					"named": String(predator.species) if predator != null and is_instance_valid(predator) else "nobody",
					"named_raw": snappedf(raw_of(predator), 0.001) if predator != null and is_instance_valid(predator) else 0.0,
					"player": String(p.species)}
		else:
			_masked_run = 0.0
		return m


func test_live_rerun_current_tree() -> void:
	var args := Paths.user_args()
	if not args.has("r5_seeds"):
		check(true, "(skipped: no --r5_seeds)")
		return
	var seeds: Array[int] = []
	for s in String(args["r5_seeds"]).split(","):
		seeds.append(int(s))
	var minutes := float(args.get("r5_minutes", "50"))
	var skill := StringName(args.get("r5_skill", "competent"))
	var tag := String(args.get("r5_tag", "x"))
	var quest := args.has("r5_quest")
	var sim := IntegratedSim.new()
	sim.sky_factory = func() -> Node:
		var sky: Node = LiveSky.new()
		sky.set(&"world_kind", &"valley")
		return sky
	var watches: Array = []
	sim.configure = func(s: IntegratedSim) -> void:
		var w := ProbeWatch.new()
		s.loop.watch = w
		watches.append(w)
		if quest:
			var e: Variant = s.eco.get(&"eco")
			if e is Node:
				(e as Node).set(&"max_npcs", 28)
				(e as Node).set(&"lod_near", 60.0)
				(e as Node).set(&"lod_far", 140.0)
	add_child(sim)
	await get_tree().process_frame
	var runs := []
	for seed_ in seeds:
		var t0 := Time.get_ticks_msec()
		var deaths_info: Array = []
		var on_bc := func(pred: Bird, prey: Bird) -> void:
			if not prey.is_player():
				return
			var w: ProbeWatch = watches[-1]
			var pid := pred.get_instance_id()
			var named_now := w.predator == pred
			var best_about := 0.0
			var named_ever := false
			for h: Array in w.hist:
				if w.t - float(h[0]) <= 1.5 and int(h[1]) == pid:
					named_ever = true
					best_about = maxf(best_about, float(h[2]))
			deaths_info.append({"t": snappedf(w.t, 0.1), "killer": String(pred.species), "player": String(prey.species),
				"killer_named_at_catch": named_now, "killer_named_last_1_5s": named_ever,
				"max_level_about_killer_1_5s": snappedf(best_about, 0.001),
				"named_at_catch": String(w.predator.species) if w.predator != null and is_instance_valid(w.predator) else "nobody",
				"level_at_catch": snappedf(w.level, 0.001),
				"killer_own_level": snappedf(w.level_of(pred), 0.001)})
		Events.bird_caught.connect(on_bc)
		# Target cue changes (non-null to a different non-null bird), and how
		# soon after the previous change they come.
		var tg := {"changes": 0, "to_null": 0, "within_3s": 0, "last_t": -INF, "last": 0}
		var on_tg := func(prey: Bird) -> void:
			var w0: ProbeWatch = watches[-1]
			var id := prey.get_instance_id() if prey != null else 0
			if id == 0:
				tg["to_null"] += 1
			elif int(tg["last"]) != 0 and id != int(tg["last"]):
				tg["changes"] += 1
				if w0.t - float(tg["last_t"]) < 3.0:
					tg["within_3s"] += 1
			if id != 0:
				tg["last_t"] = w0.t
			tg["last"] = id
		Events.target_changed.connect(on_tg)
		var r: Dictionary = await sim.run(skill, seed_, minutes * 60.0)
		Events.bird_caught.disconnect(on_bc)
		Events.target_changed.disconnect(on_tg)
		tg.erase("last_t")
		tg.erase("last")
		var w: ProbeWatch = watches[-1]
		var ta := {}
		for k in r["tier_at"]:
			ta[str(k)] = snappedf(float(r["tier_at"][k]) / 60.0, 0.001)
		var delays := w.onset_delays.duplicate()
		delays.sort()
		var finite_d := delays.filter(func(x: float) -> bool: return is_finite(x))
		var row := {"seed": seed_, "skill": skill, "quest": quest, "tier_min": ta, "deaths": r["deaths"],
			"death_min": (r["death_times"] as Array).map(func(x: Variant) -> float: return snappedf(float(x) / 60.0, 0.001)),
			"death_by": r["death_by"], "catches": r["catches"], "attacks": r["attacks"], "end": r["end_reason"],
			"ended_min": snappedf(float(r["ended_at"]) / 60.0, 0.001),
			"victory_min": snappedf(float(r["victory_at"]) / 60.0, 0.001), "escapes": r["escapes"],
			"chases": r["chases"], "cue": r["cue"], "cost_us": r["cost_us"],
			"catch_times_min": (r["catch_log"] as Array).map(func(c: Array) -> float: return snappedf(float(c[0]) / 60.0, 0.001)),
			"masked": {"seconds": snappedf(w.masked_s, 0.01), "episodes": w.masked_episodes,
				"longest_s": snappedf(w.masked_longest_s, 0.01), "worst_gap": snappedf(w.masked_worst_gap, 0.001),
				"worst": w.masked_worst},
			"attack_onsets": delays.size(), "onsets_never_named": delays.size() - finite_d.size(),
			"onset_delay_p50": finite_d[finite_d.size() / 2] if not finite_d.is_empty() else -1.0,
			"onset_delay_p90": finite_d[(finite_d.size() * 9) / 10] if not finite_d.is_empty() else -1.0,
			"onset_delay_max": finite_d[-1] if not finite_d.is_empty() else -1.0,
			"onsets_later_than_0_25s": finite_d.filter(func(x: float) -> bool: return x > 0.25).size(),
			"deaths_info": deaths_info, "target_cue": tg,
			"wall_s": (Time.get_ticks_msec() - t0) / 1000.0, "sky_code": IntegratedSim.sky_code(&"valley"),
			"fingerprint": IntegratedSim.fingerprint()}
		runs.append(row)
		print("[gameloop] r5exp live %s seed %d%s: pigeon %s eagle %s deaths %d catches %d end %s masked %.1fs/%d eps (worst gap %.2f) onsets %d late>0.25s %d never %d (%.0f s wall)" % [
			skill, seed_, " QUEST" if quest else "",
			ta.get(str(SizeRules.species_index(&"pigeon")), "-"), ta.get(str(SizeRules.species_index(&"eagle")), "-"),
			r["deaths"], r["catches"], r["end_reason"], w.masked_s, w.masked_episodes, w.masked_worst_gap,
			delays.size(), row["onsets_later_than_0_25s"], row["onsets_never_named"], row["wall_s"]])
		var f := FileAccess.open(Paths.artifacts("gameloop").path_join("verify/r5exp_live_%s.json" % tag), FileAccess.WRITE)
		if f:
			f.store_string(JSON.stringify({"skill": skill, "minutes": minutes, "quest": quest, "runs": runs}, "  "))
	sim.queue_free()
	await get_tree().process_frame
	check(runs.size() == seeds.size(), "all runs finished")
