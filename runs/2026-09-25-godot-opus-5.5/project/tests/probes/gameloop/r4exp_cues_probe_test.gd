extends TestCase
## Verifier probe (round 4, experience lens): how the threat and target cues
## BEHAVE over whole modelled runs, as the player would feel them through the
## HUD (ui_root marks a "real threat" from level 0.1), haptics (0.35) and audio
## (screech at 0.6): danger episodes a minute by peak level, how long they
## last, direct predator swaps during an attack, and how long a target marker
## is held before it changes (and why it changes).
##   tools/gd.sh gameloop_verify --headless res://tests/runner.tscn -- \
##     --dir=res://tests/probes/gameloop --suite=r4exp_cues [--r4_sky=valley] [--r4_seeds=311,523] [--r4_minutes=15]
## Writes artifacts/gameloop/verify/r4exp_cues_<sky>.json.

const LiveSky := preload("res://tests/shots/gameloop_live_sky.gd")


func test_cue_behaviour_over_runs() -> void:
	var args := Paths.user_args()
	var sky := String(args.get("r4_sky", "mirror"))
	var minutes := float(args.get("r4_minutes", "15"))
	var seeds: Array[int] = []
	for s in String(args.get("r4_seeds", "311,523,947")).split(","):
		seeds.append(int(s))
	var skill := StringName(args.get("r4_skill", "competent"))
	var sim := IntegratedSim.new()
	if sky == "valley":
		sim.sky_factory = func() -> Node:
			var k: Node = LiveSky.new()
			k.set(&"world_kind", &"valley")
			return k
	add_child(sim)
	await get_tree().process_frame
	var out := []
	var agg := {"min": 0.0, "ep_01": 0, "ep_03": 0, "ep_06": 0, "ep_all": 0, "short_01": 0, "swaps_hot": 0,
		"holds": [], "hold_lt_1_5_valid_swaps": 0, "valid_swaps": 0, "to_null": 0, "by_catch": 0}
	for seed_ in seeds:
		var tl := []  # [t, level, pred_id]
		var tg := []  # [t, prey_id]
		var earned := [0]
		var on_threat := func(level: float, pred: Bird) -> void:
			tl.append([sim.loop.stats.run_time, level, pred.get_instance_id() if pred != null else 0])
			# The named bird's own threat right now: a high level on a bird that
			# poses little (the level carried over from another bird) misdirects.
			if pred != null and is_instance_valid(pred):
				var own := sim.loop.watch.threat_of(sim.player, pred, sim.loop.rule)
				if own >= 0.3:
					earned[0] = pred.get_instance_id()
				if level >= 0.35:
					agg["hot_emits"] = int(agg.get("hot_emits", 0)) + 1
					if own < 0.1 and pred.get_instance_id() != int(earned[0]):
						agg["hot_emits_on_harmless"] = int(agg.get("hot_emits_on_harmless", 0)) + 1
		var prev := [null]
		var on_target := func(q: Bird) -> void:
			var o: Variant = prev[0]
			var o_ok: bool = o != null and is_instance_valid(o) and (o as Bird).alive \
					and SizeRules.is_worthwhile(sim.player.mass, (o as Bird).mass) and not CatchRule.is_hidden(o)
			tg.append([sim.loop.stats.run_time, q.get_instance_id() if q != null else 0, o_ok])
			prev[0] = q
		var caught_ids := {}
		var on_caught := func(pred: Bird, prey: Bird) -> void:
			if pred.is_player():
				caught_ids[prey.get_instance_id()] = sim.loop.stats.run_time
		Events.threat_changed.connect(on_threat)
		Events.target_changed.connect(on_target)
		Events.bird_caught.connect(on_caught)
		var r: Dictionary = await sim.run(skill, seed_, minutes * 60.0)
		Events.threat_changed.disconnect(on_threat)
		Events.target_changed.disconnect(on_target)
		Events.bird_caught.disconnect(on_caught)
		var played := float(r["ended_at"]) / 60.0
		agg["min"] += played
		# Danger episodes: from a predator being named to the level back at 0.
		var eps := []
		var cur := {}
		var last_pred := 0
		var prev_pred := 0
		var last_swap_t := -INF
		var prev_lv := 0.0
		var prev_t := 0.0
		for e: Array in tl:
			var t := float(e[0])
			var lv := float(e[1])
			var pid := int(e[2])
			# Time the HUD shows a real threat (level >= 0.1), piecewise constant.
			if prev_lv >= 0.1:
				agg["hud_s"] = float(agg.get("hud_s", 0.0)) + (t - prev_t)
			if prev_lv >= 0.3:
				agg["hot_s"] = float(agg.get("hot_s", 0.0)) + (t - prev_t)
			prev_lv = lv
			prev_t = t
			if pid != 0 and last_pred != 0 and pid != last_pred:
				agg["swaps_any"] = int(agg.get("swaps_any", 0)) + 1
				if pid == prev_pred and t - last_swap_t < 3.0:
					agg["ping_pong_3s"] = int(agg.get("ping_pong_3s", 0)) + 1
				prev_pred = last_pred
				last_swap_t = t
			if cur.is_empty() and lv > 0.0:
				cur = {"t0": t, "peak": lv, "preds": {pid: true}}
			elif not cur.is_empty():
				cur["peak"] = maxf(float(cur["peak"]), lv)
				if pid != 0 and pid != last_pred and last_pred != 0 and lv >= 0.3:
					agg["swaps_hot"] += 1
				if pid != 0:
					cur["preds"][pid] = true
				if lv <= 0.0:
					cur["t1"] = t
					eps.append(cur)
					cur = {}
			last_pred = pid
		for ep: Dictionary in eps:
			var pk := float(ep["peak"])
			var dur := float(ep["t1"]) - float(ep["t0"])
			agg["ep_all"] += 1
			if pk >= 0.1:
				agg["ep_01"] += 1
				if dur < 1.0:
					agg["short_01"] += 1
			if pk >= 0.3:
				agg["ep_03"] += 1
			if pk >= 0.6:
				agg["ep_06"] += 1
		# Target holds: time from a target being named to the next change.
		for i in tg.size() - 1:
			var a: Array = tg[i]
			var b: Array = tg[i + 1]
			if int(a[1]) == 0:
				continue
			var hold := float(b[0]) - float(a[0])
			(agg["holds"] as Array).append(hold)
			if int(b[1]) == 0:
				agg["to_null"] += 1
			elif caught_ids.has(int(a[1])):
				agg["by_catch"] += 1
			elif not bool(b[2]):
				agg["old_invalid"] = int(agg.get("old_invalid", 0)) + 1
			else:
				agg["valid_swaps"] += 1
				if hold < 1.5:
					agg["hold_lt_1_5_valid_swaps"] += 1
		out.append({"seed": seed_, "min": played, "threat_events": tl.size(), "target_events": tg.size(),
			"episodes": eps.size(), "catches": r["catches"], "deaths": r["deaths"]})
	sim.queue_free()
	await get_tree().process_frame
	var holds: Array = agg["holds"]
	holds.sort()
	var m := float(agg["min"])
	var res := {"sky": sky, "skill": skill, "minutes_played": m, "runs": out,
		"danger_episodes_per_min": {"any": agg["ep_all"] / m, "peak>=0.1 (HUD)": agg["ep_01"] / m,
			"peak>=0.3 (attack)": agg["ep_03"] / m, "peak>=0.6 (screech)": agg["ep_06"] / m},
		"hud_episodes_shorter_than_1s": agg["short_01"], "predator_swaps_while_level>=0.3": agg["swaps_hot"],
		"predator_swaps_any_level_per_min": agg.get("swaps_any", 0) / m, "ping_pong_swaps_within_3s": agg.get("ping_pong_3s", 0),
		"emits_level>=0.35": agg.get("hot_emits", 0), "emits_level>=0.35_naming_another_bird_whose_own_threat<0.1": agg.get("hot_emits_on_harmless", 0),
		"share_of_time_hud_threat": agg.get("hud_s", 0.0) / (m * 60.0), "share_of_time_level>=0.3": agg.get("hot_s", 0.0) / (m * 60.0),
		"target": {"holds": holds.size(), "median_hold_s": holds[holds.size() / 2] if not holds.is_empty() else -1.0,
			"p10_hold_s": holds[int(holds.size() * 0.1)] if not holds.is_empty() else -1.0,
			"ended_to_nothing": agg["to_null"], "ended_by_catch": agg["by_catch"], "swapped_to_other_while_old_still_valid": agg["valid_swaps"], "replaced_because_old_invalid": agg.get("old_invalid", 0),
			"swapped_within_1_5s": agg["hold_lt_1_5_valid_swaps"], "changes_per_min": (holds.size()) / m}}
	metric("cues", res)
	print("[gameloop] r4exp cues: ", JSON.stringify(res))
	var f := FileAccess.open(Paths.artifacts("gameloop").path_join("verify/r4exp_cues_%s_%s.json" % [sky, skill]), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(res, "  "))
	check(m > 1.0, "(setup) played")


## Why the named predator changes, and who the danger cue is about, in whole
## runs: at every threat emission, the named bird's own threat and whether
## it is hunting the player; at every change of the named bird while the
## level is at attack strength (>= 0.3), the outgoing bird's own threat.
##   ... --suite=r4exp_cues --test=diagnose --r4_sky=valley --r4_seeds=311,523 --r4_minutes=10
func test_diagnose_threat_naming() -> void:
	var args := Paths.user_args()
	var sky := String(args.get("r4_sky", "mirror"))
	var minutes := float(args.get("r4_minutes", "10"))
	var seeds: Array[int] = []
	for s in String(args.get("r4_seeds", "311,523")).split(","):
		seeds.append(int(s))
	var sim := IntegratedSim.new()
	if sky == "valley":
		sim.sky_factory = func() -> Node:
			var k: Node = LiveSky.new()
			k.set(&"world_kind", &"valley")
			return k
	add_child(sim)
	await get_tree().process_frame
	var d := {"hud_s": 0.0, "hud_s_named_not_hunting": 0.0, "hud_s_named_hunting": 0.0, "hot_s": 0.0,
		"hot_s_named_not_hunting": 0.0, "hot_swaps": 0, "hot_swaps_old_raw_0": 0, "hot_swaps_old_raw_pos": 0,
		"hot_swaps_old_gone": 0, "hot_swaps_new_raw_lt_0_1": 0, "played_s": 0.0, "hold_before_swap": []}
	for seed_ in seeds:
		var st := {"t": -1.0, "lv": 0.0, "pred": null, "hunting": false, "prev_named": null, "named_at": 0.0}
		var on_threat := func(level: float, pred: Bird) -> void:
			var t := sim.loop.stats.run_time
			var dt: float = t - float(st["t"]) if float(st["t"]) >= 0.0 else 0.0
			if float(st["lv"]) >= 0.1:
				d["hud_s"] += dt
				d["hud_s_named_hunting" if st["hunting"] else "hud_s_named_not_hunting"] += dt
			if float(st["lv"]) >= 0.3:
				d["hot_s"] += dt
				if not st["hunting"]:
					d["hot_s_named_not_hunting"] += dt
			var old: Variant = st["pred"]
			if pred != null and old != null and pred != old and level >= 0.3:
				d["hot_swaps"] += 1
				if not is_instance_valid(old) or not (old as Bird).alive:
					d["hot_swaps_old_gone"] += 1
				else:
					var o_raw := sim.loop.watch.threat_of(sim.player, old as Bird, sim.loop.rule)
					if CatchRule.is_hidden(old) or o_raw <= 0.0:
						d["hot_swaps_old_raw_0"] += 1
					else:
						d["hot_swaps_old_raw_pos"] += 1
				var n_raw := sim.loop.watch.threat_of(sim.player, pred, sim.loop.rule)
				if n_raw < 0.1:
					d["hot_swaps_new_raw_lt_0_1"] += 1
				var o_h: bool = is_instance_valid(old) and (&"target" in old) and (old as Bird).get(&"target") == sim.player
				var n_h: bool = (&"target" in pred) and pred.get(&"target") == sim.player
				var key := "hot_swaps_hunting_%s_to_%s" % ["y" if o_h else "n", "y" if n_h else "n"]
				d[key] = int(d.get(key, 0)) + 1
				(d["hold_before_swap"] as Array).append(t - float(st["named_at"]))
				# A -> B -> A within 3 s at attack level.
				if pred == st["prev_named"] and t - float(st["named_at"]) < 3.0:
					d["hot_ping_pong_3s"] = int(d.get("hot_ping_pong_3s", 0)) + 1
			if pred != old:
				st["prev_named"] = old
				st["named_at"] = t
			st["t"] = t
			st["lv"] = level
			st["pred"] = pred
			st["hunting"] = pred != null and (&"target" in pred) and pred.get(&"target") == sim.player
		Events.threat_changed.connect(on_threat)
		var r: Dictionary = await sim.run(&"competent", seed_, minutes * 60.0)
		Events.threat_changed.disconnect(on_threat)
		d["played_s"] += float(r["ended_at"])
	sim.queue_free()
	await get_tree().process_frame
	var ps := float(d["played_s"])
	var res := {"sky": sky, "played_min": ps / 60.0, "share_time_hud_threat": d["hud_s"] / ps,
		"share_time_hud_threat_named_bird_not_hunting_player": d["hud_s_named_not_hunting"] / ps,
		"share_time_level>=0.3": d["hot_s"] / ps, "share_time_level>=0.3_named_not_hunting": d["hot_s_named_not_hunting"] / ps,
		"swaps_at_level>=0.3": d["hot_swaps"], "of_which_old_still_alive_with_raw_0": d["hot_swaps_old_raw_0"],
		"of_which_old_raw_positive": d["hot_swaps_old_raw_pos"], "of_which_old_gone": d["hot_swaps_old_gone"],
		"of_which_new_bird_own_threat<0.1": d["hot_swaps_new_raw_lt_0_1"],
		"hunting_old_to_new": {"y_to_y": d.get("hot_swaps_hunting_y_to_y", 0), "y_to_n": d.get("hot_swaps_hunting_y_to_n", 0),
			"n_to_y": d.get("hot_swaps_hunting_n_to_y", 0), "n_to_n": d.get("hot_swaps_hunting_n_to_n", 0)},
		"ping_pong_at_attack_level_within_3s": d.get("hot_ping_pong_3s", 0),
		"median_s_named_before_a_hot_swap": _med(d["hold_before_swap"])}
	metric("diagnosis", res)
	print("[gameloop] r4exp threat diagnosis: ", JSON.stringify(res))
	var f := FileAccess.open(Paths.artifacts("gameloop").path_join("verify/r4exp_threat_diag_%s.json" % sky), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(res, "  "))
	check(ps > 60.0, "(setup) played")
	# G6 "stable (no flicker)" and "correct", as the player feels it: during an
	# attack (level >= 0.3) the cue must keep naming the bird that is hunting
	# the player, not hop to a bystander and back.
	var hot_min := float(d["hot_s"]) / 60.0
	eq(int(d.get("hot_swaps_hunting_y_to_n", 0)), 0, "at attack level the named predator never jumps from the bird hunting the player to one that is not")
	lt(float(d.get("hot_ping_pong_3s", 0)) / maxf(hot_min, 1e-6), 1.0, "A -> B -> A within 3 s at attack level: under 1 per minute of attack time")
	eq(int(d["hot_swaps_new_raw_lt_0_1"]), 0, "the attack-level cue never moves to a bird whose own threat is < 0.1")


static func _med(xs: Array) -> float:
	if xs.is_empty():
		return -1.0
	var s := xs.duplicate()
	s.sort()
	return float(s[s.size() / 2])
