extends "res://tests/unit/game/game_fixture.gd"
## Verifier round 3 (experience & requirements lens): adversarial probes on
## what a player would notice, beyond the builder's own suite.
##
##   tools/gd.sh gameloop_verify_exp --headless res://tests/runner.tscn -- \
##       --dir=res://tests/probes/gameloop --suite=r3exp_experience
##
## Only core contracts + the area's public API + the fixture's SimBirds.

## Felt metres per player wingspan (WorldScaleDriver: span / (1.5 + 0.2)).
const FELT_PER_SPAN := 1.7


static func _pct(a: PackedFloat32Array, q: float) -> float:
	if a.is_empty():
		return 0.0
	var s := a.duplicate()
	s.sort()
	return s[clampi(int(round(q * (s.size() - 1))), 0, s.size() - 1)]


## Frame-time tail: a 60-bird sky that churns (NPCs eat each other and are
## replaced, a murmuration swirls round the player, raptors dive through), the
## valley's refuge count. G6 asks < 0.3 ms for the watch; a VR frame also cares
## about the whole step's tail (p99), which the builder never asserts.
func test_step_tail_latency_in_a_churning_sky() -> void:
	var world := _RefugeWorld.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = 3033
	for i in 320:
		var near := i < 250
		var a := rng.randf() * TAU
		var r := sqrt(rng.randf()) * (70.0 if near else 600.0)
		world.refuges.append({"name": "r%d" % i, "position": Vector3(cos(a) * r, 30.0 + rng.randf_range(-8, 8), sin(a) * r),
			"radius": rng.randf_range(0.3, 1.5), "max_span": 0.40 if near else rng.randf_range(0.2, 2.5)})
	add_child(world)
	make_loop()
	await get_tree().process_frame
	var p := make_bird(0.3, Vector3(0, 30, 0), Vector3.FORWARD, true)
	loop.start_run()
	p.global_position = Vector3(0, 30, 0)
	p.velocity = Vector3.FORWARD * 12.0
	loop.set_protection(p, 1e6)  # the player is only the observer here
	var npcs: Array[SimBird] = []
	var spawn := func(i: int) -> SimBird:
		var m: float
		var pos: Vector3
		if i < 30:
			m = 0.1  # murmuration of starlings round the player (worthwhile prey)
			pos = p.global_position + Vector3(rng.randf_range(-15, 15), rng.randf_range(-6, 6), rng.randf_range(-35, 5))
		elif i < 40:
			m = [0.5, 0.85, 1.3, 3.0][i % 4]  # raptors diving through the flock
			pos = p.global_position + Vector3(rng.randf_range(-40, 40), rng.randf_range(0, 25), rng.randf_range(-60, 20))
		else:
			m = exp(rng.randf_range(log(0.004), log(0.06)))  # small fry mixed in
			pos = p.global_position + Vector3(rng.randf_range(-30, 30), rng.randf_range(-8, 8), rng.randf_range(-40, 10))
		var b := make_bird(m, pos, Vector3(rng.randf_range(-1, 1), rng.randf_range(-0.2, 0.2), rng.randf_range(-1, 1)).normalized(), false, true)
		b.velocity = b.heading * (9.0 + 6.0 * m)
		return b
	for i in 59:
		npcs.append(spawn.call(i))
	var watch := PackedFloat32Array()
	var catch_us := PackedFloat32Array()
	var total := PackedFloat32Array()
	var npc_eats := [0]
	var on_c := func(_a: Bird, _b: Bird) -> void: npc_eats[0] += 1
	Events.bird_caught.connect(on_c)
	var dt := 1.0 / 72.0
	for step_i in 2160:  # 30 s at 72 Hz
		for k in npcs.size():
			var b := npcs[k]
			if not b.alive:
				# The ecosystem replaces eaten birds.
				b.queue_free()
				npcs[k] = spawn.call(k)
				b = npcs[k]
			# Swirl: raptors home on the flock, the flock circles the player.
			var to_p := p.global_position - b.global_position
			var steer := Vector3(-to_p.z, 0.0, to_p.x).normalized() * 0.6 + to_p.normalized() * 0.4
			if b.mass >= 0.5:
				steer = (npcs[rng.randi_range(0, 29)].global_position - b.global_position).normalized()
			b.velocity = (b.velocity + steer * 20.0 * dt).limit_length(9.0 + 8.0 * b.mass)
			b.global_position += b.velocity * dt
			b.set_heading(b.velocity)
		p.global_position += p.velocity * dt * 0.2
		loop.step(dt)
		if step_i >= 72:
			watch.append(float(loop.perf.get("watch", 0)))
			catch_us.append(float(loop.perf.get("catch", 0)))
			total.append(float(loop.perf.get("total", 0)))
	Events.bird_caught.disconnect(on_c)
	var res := {"npc_catches": npc_eats[0],
		"watch": [_pct(watch, 0.5), _pct(watch, 0.95), _pct(watch, 0.99), _pct(watch, 1.0)],
		"catch": [_pct(catch_us, 0.5), _pct(catch_us, 0.95), _pct(catch_us, 0.99), _pct(catch_us, 1.0)],
		"total": [_pct(total, 0.5), _pct(total, 0.95), _pct(total, 0.99), _pct(total, 1.0)]}
	metric("r3exp_tail_us", res)
	print("[gameloop-verify] tail latency (median/p95/p99/max us): %s" % [res])
	gt(npc_eats[0], 5.0, "(setup) the sky churns: NPCs catch each other")
	lt(res["watch"][0], 300.0, "G6: watch pass median < 0.3 ms for 60 birds in a churning sky")
	lt(res["total"][2], 1500.0, "whole step p99 < 1.5 ms on the dev Mac (Quest is 2-3x slower; a 72 Hz frame is 13.9 ms)")
	world.queue_free()


## How far away a caught bird is, as the player feels it (felt metres =
## wingspans x 1.7), at each size, without and with the full catch assist.
## The brief: VR-friendly forgiveness, prey in front. Reported, and pinned so
## that the felt reach never exceeds ~3 arm spans nor falls under half one.
func test_felt_catch_reach_by_size() -> void:
	var rule := CatchRule.new()
	var rows := {}
	var worst_hi := 0.0
	var worst_lo := INF
	for s in SizeRules.SPECIES.slice(2):
		var m: float = s["mass"]
		var span := SizeRules.wingspan_for_mass(m)
		rule.player_time_scale = SizeRules.time_scale(m)
		# A typical worthwhile prey: a third of the player's mass.
		var q := m / 3.0
		var out := []
		for assist in [0.0, 1.0]:
			rule.player_assist = assist
			var c := rule.contact_distance(SizeRules.body_radius_for_mass(m), span, true, SizeRules.body_radius_for_mass(q))
			out.append(snappedf(c / span * FELT_PER_SPAN, 0.01))
		rows[String(s["id"])] = {"felt_m_no_assist": out[0], "felt_m_full_assist": out[1]}
		worst_hi = maxf(worst_hi, out[1])
		worst_lo = minf(worst_lo, out[0])
	metric("r3exp_felt_reach_m", rows)
	print("[gameloop-verify] felt catch reach (m, centre to centre): %s" % [rows])
	lt(worst_hi, 3.0 * 1.7, "felt catch reach at full assist stays within ~3 arm spans (sparrow worst case)")
	gt(worst_lo, 0.85, "felt catch reach never needs closer than half an arm span (eagle worst case)")


## Apex progress when the eagle is knocked back down a tier: the count is
## kept (or reset) consistently, apex_reached fires once per run, and the
## victory still comes after exactly APEX_CATCHES worthwhile eagle catches.
func test_apex_progress_across_a_tier_drop() -> void:
	make_loop()
	var p := make_bird(GameLoop.START_MASS, Vector3(0, 30, 0), Vector3.FORWARD, true)
	loop.start_run()
	start_logging()
	var reached := [0]
	var progress: Array = []
	var won := [0]
	loop.apex_reached.connect(func() -> void: reached[0] += 1)
	loop.apex_progress.connect(func(c: int, n: int) -> void: progress.append([c, n]))
	loop.victory.connect(func(_s: Dictionary) -> void: won[0] += 1)
	loop.set_protection(p, 0.0)
	# Skip the ladder: a hawk (the loop adopts a mass set from outside), then
	# one real meal makes it an eagle so apex_reached fires the normal way.
	p.mass = 2.5
	loop.step(0.02)
	var feed := func(prey_mass: float) -> void:
		var q := make_bird(prey_mass, p.global_position + Vector3(0, 0, -0.3))
		q.velocity = Vector3.ZERO
		loop.set_protection(q, 0.0)
		p.velocity = Vector3.FORWARD * 5.0
		loop.step(0.02)
		loop.step(0.25)  # past the handling time
	feed.call(1.0)
	eq(SizeRules.tier_for_mass(p.mass), GameLoop.apex_tier(), "(setup) an eagle after one meal")
	eq(reached[0], 1, "apex_reached on becoming the eagle")
	eq(progress.size(), 0, "the promoting meal is not an apex catch")
	# A crow meal as an eagle counts.
	feed.call(0.5)
	eq(progress.size(), 1, "one apex catch recorded")
	# Knocked down: an eagle-eater is not in the ladder, so force a death via a
	# bigger NPC (4.2 kg > 1.25 x eagle) striking head-on.
	var mass_before := p.mass
	var killer := make_bird(p.mass * 1.4, p.global_position + Vector3(0, 0, -3.0), Vector3.BACK)
	killer.velocity = Vector3.BACK * 20.0
	loop.set_protection(killer, 0.0)
	for i in 30:
		killer.global_position += killer.velocity * 0.02
		loop.step(0.02)
		if loop.phase == GameLoop.Phase.CAUGHT:
			break
	eq(loop.phase, GameLoop.Phase.CAUGHT, "(setup) the eagle was caught")
	killer.alive = false
	for i in 200:
		loop.step(0.02)
	lt(p.mass, mass_before * 0.75, "the penalty took 30%")
	var st := loop.get_run_stats()
	var apex: Dictionary = st["apex"]
	metric("r3exp_apex_after_drop", {"species": st["species"], "apex": apex})
	# Regrow to eagle with meals and finish the goal.
	var guard := 0
	while SizeRules.tier_for_mass(p.mass) < GameLoop.apex_tier() and guard < 20:
		feed.call(p.mass * 0.7)
		guard += 1
	var guard2 := 0
	while won[0] == 0 and guard2 < 10:
		feed.call(p.mass * 0.3)
		guard2 += 1
	metric("r3exp_apex_progress_log", {"progress": progress, "reached": reached[0], "won": won[0], "meals_after_regrow": guard2})
	eq(won[0], 1, "exactly one victory")
	lt(float(reached[0]), 2.0, "apex_reached fires at most once per run")
	var total_apex_catches: int = (progress.back() as Array)[0]
	eq(total_apex_catches, GameLoop.APEX_CATCHES, "victory at exactly APEX_CATCHES worthwhile eagle catches")
	stop_logging()


## Highlights at the edge of the highlight range must not flicker when a bird
## wobbles back and forth across it (a pulsing marker far away reads as noise).
func test_highlight_edge_does_not_flicker() -> void:
	make_loop()
	var p := make_bird(0.1, Vector3(0, 30, 0), Vector3.FORWARD, true)
	loop.start_run()
	p.global_position = Vector3(0, 30, 0)
	loop.set_protection(p, 1e6)
	var r := loop.watch.highlight_range(p.mass)
	var prey := make_bird(0.03, Vector3(0, 30, -r * 0.9), Vector3.FORWARD, false, true)
	var hawk := make_bird(1.3, Vector3(r * 0.9, 30, 0), Vector3.RIGHT, false, true)
	loop.set_protection(prey, 1e6)
	loop.set_protection(hawk, 1e6)
	hawk.target = null  # not hunting: pure range test
	var toggles := {"prey": 0, "hawk": 0}
	var last := {"prey": -1, "hawk": -1}
	for i in 720:
		# Starts inside, then wobbles +-12% across the range edge (tracking
		# noise and a bird circling at the edge of view).
		var wob := 0.9 if i < 10 else 1.0 + 0.12 * sin(float(i) * 0.3)
		prey.global_position = Vector3(0, 30, -r * wob)
		hawk.global_position = Vector3(r * wob, 30, 0)
		loop.step(1.0 / 72.0)
		for k in ["prey", "hawk"]:
			var b: SimBird = prey if k == "prey" else hawk
			var h: int = b.model.highlight
			if last[k] >= 0 and h != last[k]:
				toggles[k] += 1
			last[k] = h
	metric("r3exp_highlight_edge_toggles", toggles)
	lt(float(toggles["prey"]), 2.0, "prey highlight does not flicker at the range edge")
	lt(float(toggles["hawk"]), 2.0, "danger highlight does not flicker at the range edge")


## Restart pressed during the CAUGHT beat: nothing of the old death leaks into
## the new run (no late penalty, no second respawn, full lives, PLAYING).
func test_restart_during_the_caught_beat_is_clean() -> void:
	make_loop()
	var p := make_bird(0.2, Vector3(0, 30, 0), Vector3.FORWARD, true)
	loop.start_run()
	p.mass = 0.2
	loop.step(0.02)
	loop.set_protection(p, 0.0)
	var hawk := make_bird(1.3, p.global_position + Vector3(0, 0, -2.0), Vector3.BACK)
	hawk.velocity = Vector3.BACK * 15.0
	loop.set_protection(hawk, 0.0)
	for i in 30:
		hawk.global_position += hawk.velocity * 0.02
		loop.step(0.02)
		if loop.phase == GameLoop.Phase.CAUGHT:
			break
	eq(loop.phase, GameLoop.Phase.CAUGHT, "(setup) caught")
	hawk.queue_free()
	await get_tree().process_frame
	loop.step(1.0)  # mid-beat
	var changes: Array = []
	loop.player_mass_changed.connect(func(o: float, n: float, why: StringName) -> void: changes.append([o, n, why]))
	var respawns := [0]
	loop.player_respawned.connect(func(_s: float) -> void: respawns[0] += 1)
	loop.restart_run()
	for i in 250:
		loop.step(0.02)
	var reasons := changes.map(func(c: Array) -> StringName: return c[2])
	metric("r3exp_restart_mid_beat", {"mass_changes": reasons, "respawns": respawns[0], "lives": loop.lives,
		"state": Game.state_name(), "mass": p.mass})
	check(not reasons.has(&"penalty"), "no penalty from the old death after the restart")
	eq(respawns[0], 0, "no respawn from the old beat after the restart")
	eq(loop.lives, GameLoop.MAX_LIVES, "full lives")
	eq(Game.state, Game.State.PLAYING, "PLAYING")
	near(p.mass, GameLoop.START_MASS, 1e-6, "back to a sparrow")
	check(p.alive, "player alive")


## The apex fantasy: a player who has just become the eagle is "top of the
## ladder" (the loop's HUD block says danger_species = none). The AI spawns
## NPCs at 0.91-1.09 x the species mass (scripts/ai/ecosystem.gd) and the
## loop lets an NPC grow +15% by eating: can a well-fed NPC eagle eat a fresh
## player eagle, while the HUD lists nobody to flee? (The valley evidence
## logged "eagle/eagle" deaths: holdout seed 202, expert seed 103.)
func test_a_fresh_player_eagle_is_safe_from_npc_eagles() -> void:
	make_loop()
	var p := make_bird(GameLoop.START_MASS, Vector3(0, 30, 0), Vector3.FORWARD, true)
	loop.start_run()
	p.mass = 3.0  # just became the eagle
	loop.step(0.02)
	loop.set_protection(p, 1e6)  # observe only
	var npc := make_bird(3.0 * 1.09, Vector3(200, 30, 0), Vector3.FORWARD)  # AI's largest spawn
	npc.target = null
	loop.set_protection(npc, 0.0)
	loop.step(0.02)  # the loop records its spawn mass
	for i in 4:
		var q := make_bird(0.85, npc.global_position + Vector3(0, 0, -0.5))
		loop.set_protection(q, 0.0)
		loop.step(0.02)
		loop.step(1.3)  # NPC handling time
	var st := loop.get_run_stats()
	var can := SizeRules.can_eat(npc.mass, p.mass)
	metric("r3exp_apex_safety", {"npc_eagle_kg": npc.mass, "player_kg": p.mass, "npc_can_eat_player": can,
		"hud_danger_species": st["danger_species"], "player_species": st["species"]})
	print("[gameloop-verify] apex safety: NPC eagle %.3f kg vs player eagle %.3f kg: can eat %s, HUD danger %s" % [
		npc.mass, p.mass, can, st["danger_species"]])
	check(not (can and (st["danger_species"] as Array).is_empty()),
		"a bird that can eat the player is never hidden by the HUD's 'flee: nobody' at the apex")
	check(not can, "a fresh player eagle cannot be eaten by an NPC eagle (the apex is the top)")


class _RefugeWorld extends World:
	var refuges: Array[Dictionary] = []

	func get_refuges() -> Array[Dictionary]:
		return refuges
