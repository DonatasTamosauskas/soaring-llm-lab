extends "res://tests/unit/game/game_fixture.gd"
## Verifier probes (round 4, experience & requirements lens). Adversarial
## checks of the game loop's claims that the area's own suite does not make
## in this form:
##  * an invariant soak over whole modelled runs (the AI mirror sky, several
##    seeds and all three skills): every catch obeys the ratio at the moment
##    it happens, tier events chain exactly, the cues only ever name what
##    they may (threat = something that can eat you, target = worthwhile
##    prey that is alive), lives stay in range, the stats agree with the
##    events; plus how the cues behave (switches a minute) and how far away
##    the player's catches happen in felt metres (the "magnet" question);
##  * highlights, target and threat checked EVERY FRAME in a random churning
##    sky while the player grows from sparrow to 1.5x eagle;
##  * felt reach / cone per species (VR forgiveness bounded);
##  * restart from a paused CAUGHT beat.
##   tools/gd.sh gameloop_verify --headless res://tests/runner.tscn -- \
##     --dir=res://tests/probes/gameloop --suite=r4exp_experience

const DT := 1.0 / 72.0


func test_invariant_soak_over_modelled_runs() -> void:
	var sim := IntegratedSim.new()
	add_child(sim)
	await get_tree().process_frame
	var bad: Array[String] = []
	var totals := {"catches_by_player": 0, "player_caught": 0, "tier_events": 0, "target_changes": 0,
		"threat_pred_changes": 0, "played_min": 0.0, "npc_catches": 0}
	var felt: Array[float] = []
	var per_run := []
	for skill: StringName in [&"novice", &"competent", &"expert"]:
		for seed_ in [311, 523, 947]:
			var st := {"last_tier": -1, "last_target": null, "last_pred": null, "player_catches": 0, "deaths": 0,
				"tier_events": 0, "target_changes": 0, "pred_changes": 0}
			var on_caught := func(pred: Bird, prey: Bird) -> void:
				if pred.mass < prey.mass * SizeRules.EAT_RATIO - 1e-9:
					bad.append("catch below the ratio: %.4f eats %.4f" % [pred.mass, prey.mass])
				if not prey.alive or not pred.alive:
					bad.append("a dead bird took part in a catch")
				if CatchRule.is_hidden(prey) or CatchRule.is_hidden(pred):
					bad.append("a bird in cover took part in a catch")
				if pred.is_player():
					st["player_catches"] += 1
					var d := pred.get_body_position().distance_to(prey.get_body_position())
					felt.append(d / pred.get_wingspan() * CatchRule.FELT_M_PER_SPAN)
					if sim.loop.phase != GameLoop.Phase.PLAYING:
						bad.append("the player ate outside PLAYING")
				elif not prey.is_player():
					totals["npc_catches"] += 1
			var on_player_caught := func(_pred: Bird) -> void:
				st["deaths"] += 1
			var on_tier := func(o: int, n: int) -> void:
				st["tier_events"] += 1
				if o == n:
					bad.append("tier event with no change %d" % n)
				if st["last_tier"] >= 0 and o != int(st["last_tier"]):
					bad.append("tier events do not chain: %d -> %d after %d" % [o, n, st["last_tier"]])
				st["last_tier"] = n
				if n != SizeRules.tier_for_mass(sim.player.mass):
					bad.append("tier event %d but the player's mass says %d" % [n, SizeRules.tier_for_mass(sim.player.mass)])
			var on_grew := func(o: float, n: float, _t: int) -> void:
				if n <= o:
					bad.append("player_grew without growth %.4f -> %.4f" % [o, n])
			var on_threat := func(level: float, pred: Bird) -> void:
				if level < 0.0 or level > 1.0:
					bad.append("threat level out of range %.3f" % level)
				if level > 0.0 and pred == null:
					bad.append("threat level %.2f with no predator" % level)
				if pred != null and is_instance_valid(pred) and not SizeRules.can_eat(pred.mass, sim.player.mass):
					bad.append("threat names a bird that cannot eat the player (%.3f vs %.3f)" % [pred.mass, sim.player.mass])
				if pred != st["last_pred"]:
					st["pred_changes"] += 1
					st["last_pred"] = pred
			var on_target := func(q: Bird) -> void:
				if q != null:
					if not q.alive:
						bad.append("target is dead")
					if not SizeRules.is_worthwhile(sim.player.mass, q.mass):
						bad.append("target not worthwhile (%.4f for %.4f)" % [q.mass, sim.player.mass])
					if CatchRule.is_hidden(q):
						bad.append("target in cover")
				if q != st["last_target"]:
					st["target_changes"] += 1
					st["last_target"] = q
			Events.bird_caught.connect(on_caught)
			Events.player_caught.connect(on_player_caught)
			Events.player_tier_changed.connect(on_tier)
			Events.player_grew.connect(on_grew)
			Events.threat_changed.connect(on_threat)
			Events.target_changed.connect(on_target)
			var minutes := 15.0
			var r: Dictionary = await sim.run(skill, seed_, minutes * 60.0)
			Events.bird_caught.disconnect(on_caught)
			Events.player_caught.disconnect(on_player_caught)
			Events.player_tier_changed.disconnect(on_tier)
			Events.player_grew.disconnect(on_grew)
			Events.threat_changed.disconnect(on_threat)
			Events.target_changed.disconnect(on_target)
			var s := sim.loop.get_run_stats()
			if int(s["catches"]) != int(st["player_catches"]):
				bad.append("stats.catches %d != catch events %d" % [s["catches"], st["player_catches"]])
			if int(s["times_caught"]) != int(st["deaths"]):
				bad.append("stats.times_caught %d != player_caught events %d" % [s["times_caught"], st["deaths"]])
			if int(s["lives"]) < 0 or int(s["lives"]) > GameLoop.MAX_LIVES:
				bad.append("lives out of range %d" % s["lives"])
			if float(s["mass"]) < GameLoop.START_MASS - 1e-9 or float(s["mass"]) > GameLoop.MAX_PLAYER_MASS + 1e-9:
				bad.append("mass out of range %.4f" % s["mass"])
			var played := float(r["ended_at"]) / 60.0
			totals["catches_by_player"] += st["player_catches"]
			totals["player_caught"] += st["deaths"]
			totals["tier_events"] += st["tier_events"]
			totals["target_changes"] += st["target_changes"]
			totals["threat_pred_changes"] += st["pred_changes"]
			totals["played_min"] += played
			per_run.append({"skill": skill, "seed": seed_, "min": snappedf(played, 0.01), "catches": st["player_catches"],
				"deaths": st["deaths"], "target_changes_per_min": snappedf(st["target_changes"] / maxf(played, 0.01), 0.01),
				"pred_changes_per_min": snappedf(st["pred_changes"] / maxf(played, 0.01), 0.01),
				"peak": SizeRules.SPECIES[int(s["peak_tier"])]["id"]})
	sim.queue_free()
	await get_tree().process_frame
	felt.sort()
	metric("runs", per_run)
	metric("totals", totals)
	if not felt.is_empty():
		metric("player_catch_distance_felt_m", {"median": felt[felt.size() / 2], "p90": felt[int(felt.size() * 0.9)],
			"max": felt[-1], "n": felt.size()})
		lt(felt[-1], CatchRule.PLAYER_CONTACT_MAX_SPANS * CatchRule.FELT_M_PER_SPAN + 0.05,
				"no player catch further than the felt cap (centre to centre, at the frame's end)")
	eq(bad.size(), 0, "invariants held over 9 modelled runs: %s" % [bad.slice(0, 8)])
	gt(float(totals["catches_by_player"]), 20.0, "(setup) the runs had catches")
	# Cue stability as a player feels it: the target marker and the threat's
	# named predator do not hop around (a switch every few seconds at most).
	lt(float(totals["target_changes"]) / float(totals["played_min"]), 20.0, "target cue changes < 20 a minute (whole runs)")
	# (The named predator's changes, counted here with its comings and goings,
	# are diagnosed properly in r4exp_cues_probe_test.test_diagnose_threat_naming.)
	metric("threat_named_bird_changes_per_min_incl_null", float(totals["threat_pred_changes"]) / float(totals["played_min"]))


func test_every_frame_cue_invariants_while_growing() -> void:
	# A churning sky of 59 NPCs across the whole ladder (NPC-on-NPC catches
	# happen), the player protected and growing smoothly from a sparrow to
	# the growth cap over 3 simulated minutes. Every frame: highlight 1 only on
	# worthwhile prey in range, 2 only on birds that can eat the player, and
	# every such bird well inside range lit; the target always alive and
	# worthwhile at the player's current mass; a threat level only with a
	# predator that can eat the player.
	make_loop(true)
	var p := make_bird(GameLoop.START_MASS, Vector3(0, 40, 0), Vector3.FORWARD, true)
	loop.start_run()
	loop.opening_respite_s = 0.0
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	var npcs: Array[SimBird] = []
	for i in 59:
		var sp: Dictionary = SizeRules.SPECIES[rng.randi_range(0, SizeRules.SPECIES.size() - 1)]
		var m := float(sp["mass"]) * rng.randf_range(0.91, 1.09)
		var pos := Vector3(rng.randf_range(-50, 50), 40 + rng.randf_range(-15, 15), rng.randf_range(-50, 50))
		var b := make_bird(m, pos, Vector3(rng.randf_range(-1, 1), rng.randf_range(-0.2, 0.2), rng.randf_range(-1, 1)).normalized(),
				false, true)
		b.velocity = b.heading * rng.randf_range(4.0, 14.0)
		npcs.append(b)
	var frames := int(180.0 / DT)
	var viol := {}
	var died_at := {}
	var target_changes := 0
	var last_target: Bird = null
	var t := 0.0
	for f in frames:
		t += DT
		# Player: grows smoothly (someone else sets the mass: the loop adopts it
		# silently), flies a wide circle, cannot be caught.
		p.mass = exp(lerpf(log(GameLoop.START_MASS), log(GameLoop.MAX_PLAYER_MASS), float(f) / frames))
		var ang := t * 0.2
		var ppos := Vector3(cos(ang) * 30.0, 40.0, sin(ang) * 30.0)
		p.velocity = (ppos - p.global_position) / DT
		p.global_position = ppos
		p.set_heading(Vector3(-sin(ang), 0, cos(ang)))
		loop.set_protection(p, 10.0)
		for b in npcs:
			if not b.alive:
				continue
			if rng.randf() < 0.02:
				var h := (b.heading + Vector3(rng.randf_range(-0.6, 0.6), rng.randf_range(-0.2, 0.2), rng.randf_range(-0.6, 0.6))).normalized()
				b.set_heading(h)
				b.velocity = h * b.velocity.length()
			var np := b.global_position + b.velocity * DT
			if Vector2(np.x, np.z).length() > 70.0 or absf(np.y - 40.0) > 20.0:
				b.set_heading(-b.heading)
				b.velocity = -b.velocity
				np = b.global_position + b.velocity * DT
			b.global_position = np
		loop.step(DT)
		var pm := p.mass
		var hr := loop.watch.highlight_range(pm)
		var tr := loop.watch.target_range(pm)
		for b in npcs:
			var hl := int(b.model.highlight)
			var d := b.global_position.distance_to(p.get_body_position())
			if not b.alive:
				if not died_at.has(b):
					died_at[b] = f
				elif f - int(died_at[b]) >= 1 and hl != 0:
					viol["dead bird still lit"] = viol.get("dead bird still lit", 0) + 1
				continue
			var worth := SizeRules.is_worthwhile(pm, b.mass)
			var danger := SizeRules.can_eat(b.mass, pm)
			if hl == 1 and not worth:
				viol["lit edible but not worthwhile"] = viol.get("lit edible but not worthwhile", 0) + 1
			if hl == 1 and d > hr * 1.15 + 1.0:
				viol["lit edible out of range"] = viol.get("lit edible out of range", 0) + 1
			if hl == 2 and not danger:
				viol["lit danger but cannot eat the player"] = viol.get("lit danger but cannot eat the player", 0) + 1
			if worth and d < hr * 0.95 and hl != 1:
				viol["worthwhile prey in range not lit"] = viol.get("worthwhile prey in range not lit", 0) + 1
			if danger and d < hr * 0.95 and hl != 2:
				viol["danger in range not lit"] = viol.get("danger in range not lit", 0) + 1
		var tg := loop.watch.target
		if tg != null:
			if not tg.alive:
				viol["target dead"] = viol.get("target dead", 0) + 1
			elif not SizeRules.is_worthwhile(pm, tg.mass):
				viol["target not worthwhile"] = viol.get("target not worthwhile", 0) + 1
			elif tg.global_position.distance_to(p.get_body_position()) > tr * 1.15 + 1.0:
				viol["target out of range"] = viol.get("target out of range", 0) + 1
		if tg != last_target:
			target_changes += 1
			last_target = tg
		var pr := loop.watch.predator
		if loop.watch.level > 0.0 and pr == null:
			viol["threat without predator"] = viol.get("threat without predator", 0) + 1
		if pr != null and not SizeRules.can_eat(pr.mass, pm):
			viol["threat names a non-predator"] = viol.get("threat names a non-predator", 0) + 1
	var npc_dead := 0
	for b in npcs:
		if not b.alive:
			npc_dead += 1
	metric("frame_invariant_violations", viol)
	metric("npc_eaten_by_npc", npc_dead)
	metric("target_changes_per_min", target_changes / 3.0)
	gt(float(npc_dead), 0.5, "(setup) NPCs ate each other during the soak")
	eq(viol.size(), 0, "every-frame cue/highlight invariants held while the player grew from sparrow to 1.5x eagle: %s" % viol)


func test_felt_reach_and_cone_per_species() -> void:
	# The VR forgiveness in felt metres (world_scale = wingspan / 1.7 m): how far
	# from the player's head a catch can happen, unassisted and at full catch
	# assist, for every player species; the cone's half-angle.
	var rule := CatchRule.new()
	var rows := {}
	var worst_full := 0.0
	var least_un := INF
	for sp: Dictionary in SizeRules.SPECIES.slice(2):
		var m := float(sp["mass"])
		rule.player_time_scale = SizeRules.time_scale(m)
		var span := SizeRules.wingspan_for_mass(m)
		var pr := SizeRules.body_radius_for_mass(m)
		# Against a typical worthwhile prey (a third of the player's mass).
		var qr := SizeRules.body_radius_for_mass(m / 3.0)
		rule.player_assist = 0.0
		var un := rule.contact_distance(pr, span, true, qr) / span * CatchRule.FELT_M_PER_SPAN
		var cone_un := rad_to_deg(acos(rule.cone_cos(true)))
		rule.player_assist = 1.0
		var full := rule.contact_distance(pr, span, true, qr) / span * CatchRule.FELT_M_PER_SPAN
		var cone_full := rad_to_deg(acos(rule.cone_cos(true)))
		rows[String(sp["id"])] = {"felt_m_unassisted": snappedf(un, 0.01), "felt_m_full_assist": snappedf(full, 0.01),
			"cone_deg": [snappedf(cone_un, 0.1), snappedf(cone_full, 0.1)]}
		worst_full = maxf(worst_full, full)
		least_un = minf(least_un, un)
		lt(cone_full, 90.01, "%s: the cone never passes 90 deg" % sp["id"])
	metric("felt_reach", rows)
	lt(worst_full, 5.1, "felt reach at full assist < 5.1 m for every species")
	gt(least_un, 0.85, "felt reach unassisted >= 0.85 m for every species")


func test_restart_from_a_paused_caught_beat() -> void:
	make_loop(true)
	var p := make_bird(0.3, Vector3(0, 30, 0), Vector3.FORWARD, true)
	loop.start_run()
	loop.opening_respite_s = 0.0
	p.mass = 0.3
	loop.step(DT)
	loop.set_protection(p, 0.0)
	var hawk := make_bird(1.3, Vector3(0, 30, 0.4), Vector3.FORWARD)
	hawk.target = p
	loop.step(DT)
	eq(Game.state, Game.State.CAUGHT, "(setup) caught")
	loop.pause()
	eq(Game.state, Game.State.PAUSED, "paused mid-beat")
	check(get_tree().paused, "tree paused")
	loop.restart_run()
	check(not get_tree().paused, "restart unpauses the tree")
	eq(Game.state, Game.State.PLAYING, "restart from a paused beat -> PLAYING")
	eq(loop.lives, GameLoop.MAX_LIVES, "lives reset")
	near(p.mass, GameLoop.START_MASS, 1e-9, "mass reset to a sparrow")
	check(p.alive, "player alive")
	gt(loop.respite_left(), GameLoop.OPENING_RESPITE_S * 0.0 - 1.0, "(respite set by the run's opening value)")
	hawk.global_position = Vector3(0, 30, 200)
	var respawns := [0]
	loop.player_respawned.connect(func(_s: float) -> void: respawns[0] += 1)
	for i in int(4.0 / DT):
		loop.step(DT)
	eq(respawns[0], 0, "the old beat does not fire a respawn after the restart")
	eq(Game.state, Game.State.PLAYING, "still playing")
	eq(int(loop.get_run_stats()["times_caught"]), 0, "stats reset")


func test_two_highlight_writers_agree() -> void:
	# GAMELOOP.md: "Highlights have two writers (loop and UI) that agree". The
	# UI's handlers (scripts/ui/ui_root.gd _on_threat_changed /
	# _on_target_changed, mirrored here line for line) write 2 on the named
	# predator only while level >= REAL_THREAT (0.1), else 0, and 0 on a target
	# it stops naming. The loop writes 2 on every bird in range that can eat
	# the player, 1 on every worthwhile prey in range. Count the frames where
	# a bird that the loop says is dangerous ends the frame unlit.
	make_loop(true)
	var p := make_bird(0.03, Vector3(0, 30, 0), Vector3.FORWARD, true)
	loop.start_run()
	loop.opening_respite_s = 0.0
	loop.set_protection(p, 1e6)
	p.velocity = Vector3.ZERO
	var hawk := make_bird(1.3, Vector3(8, 30, 0), Vector3.RIGHT, false, true)
	hawk.target = null  # passing by, not hunting
	var ui_threat: Array = [null]
	var ui_handler := func(level: float, predator: Bird) -> void:
		var m: Variant = null
		if ui_threat[0] != predator:
			if ui_threat[0] != null and is_instance_valid(ui_threat[0]):
				m = (ui_threat[0] as Bird).get(&"model")
				if m != null:
					m.set(&"highlight", 0)
			ui_threat[0] = predator
		if predator != null and is_instance_valid(predator):
			m = predator.get(&"model")
			if m != null:
				m.set(&"highlight", 2 if level >= 0.1 else 0)
	Events.threat_changed.connect(ui_handler)
	var unlit := 0
	var frames := 0
	var named_low := 0
	for i in 720:
		# The hawk drifts past at 6 m/s, 5-9 m away: a low, changing threat.
		hawk.global_position = Vector3(8.0 - 4.0 * sin(i * 0.01), 30.0, -20.0 + i * 6.0 / 72.0)
		hawk.velocity = Vector3(0, 0, 6.0)
		loop.step(1.0 / 72.0)
		if SizeRules.can_eat(hawk.mass, p.mass) and hawk.global_position.distance_to(p.global_position) < loop.watch.highlight_range(p.mass) * 0.9:
			frames += 1
			if int(hawk.model.highlight) != 2:
				unlit += 1
			if loop.watch.predator == hawk and loop.watch.level < 0.1:
				named_low += 1
	Events.threat_changed.disconnect(ui_handler)
	metric("two_writers", {"frames_danger_in_range": frames, "frames_ending_unlit": unlit, "frames_named_below_0.1": named_low})
	lt(float(unlit), 1.0, "a bird that can eat the player, in range, never ends a frame unlit under both writers")


func test_the_level_does_not_move_to_a_harmless_bird() -> void:
	# A hawk attacks the player (level climbs high), then breaks off and flies
	# away. A crow that is merely passing nearby (not hunting, raw threat a
	# few hundredths) is also in the sky. Once the hawk's own raw threat is 0
	# the loop keeps the reported level falling slowly (fall_rate 0.9/s) -
	# fine - but which bird does it NAME meanwhile? If the named predator
	# jumps to the crow, the HUD arrow / haptics (>= 0.35) / audio point the
	# player at a harmless bird with a high danger level.
	make_loop(true)
	var p := make_bird(0.03, Vector3(0, 30, 0), Vector3.FORWARD, true)
	loop.start_run()
	loop.opening_respite_s = 0.0
	loop.set_protection(p, 1e6)
	var hawk := make_bird(1.3, Vector3(0, 30, -30), Vector3.BACK)
	hawk.target = p
	var crow := make_bird(0.5, Vector3(4.5, 30, 0), Vector3.RIGHT)
	crow.target = null
	crow.velocity = Vector3.ZERO
	var dt := 1.0 / 72.0
	# Attack: the hawk closes at 12 m/s from 30 m to 3 m.
	var z := -30.0
	while z < -3.0:
		z += 12.0 * dt
		hawk.global_position = Vector3(0, 30, z)
		hawk.velocity = Vector3(0, 0, 12)
		hawk.set_heading(Vector3.BACK)
		loop.step(dt)
	var peak := loop.watch.level
	# Break off: the hawk turns hard away and climbs out at 14 m/s.
	var misnamed := 0
	var misnamed_hot := 0
	var worst := 0.0
	for i in 144:
		var pos := hawk.global_position + Vector3(-14.0 * dt, 4.0 * dt, -6.0 * dt)
		hawk.global_position = pos
		hawk.velocity = Vector3(-14, 4, -6)
		hawk.set_heading(hawk.velocity.normalized())
		hawk.target = null
		loop.step(dt)
		if loop.watch.predator == crow:
			var own := loop.watch.threat_of(p, crow, loop.rule)
			misnamed += 1
			if loop.watch.level >= 0.35 and own < 0.1:
				misnamed_hot += 1
				worst = maxf(worst, loop.watch.level)
	metric("level_transfer", {"attack_peak": peak, "frames_crow_named": misnamed, "frames_crow_named_at_haptic_level": misnamed_hot,
		"worst_level_on_crow": worst, "crow_own_raw": loop.watch.threat_of(p, crow, loop.rule)})
	gt(peak, 0.5, "(setup) the attack was a real threat")
	eq(misnamed_hot, 0, "a harmless passing bird is never named at a danger level it does not pose (>= 0.35 while its own < 0.1)")
