extends "res://tests/unit/game/game_fixture.gd"
## Verifier probes (round 1) for G2/G5: a long random walk of meals (big,
## small, dust), deaths and restarts through the real loop, checking after
## every operation that tier events chain exactly once per actual change,
## player_grew fires exactly for growth, species follows mass, and caps/floors
## hold. Plus the worth threshold vs the highlight at the exact boundary.

const DT := 1.0 / 72.0


func _feed(p: SimBird, qm: float) -> SimBird:
	var c := loop.rule.contact_distance(p.get_body_radius(), p.get_wingspan(), true,
			SizeRules.body_radius_for_mass(qm))
	var q := make_bird(qm, p.get_body_position() + p.get_forward() * c * 0.5)
	loop.step(DT)
	loop.step(0.25)
	return q


func test_random_walk_tier_events_exactly_once() -> void:
	for seed_ in [3, 11, 2718]:
		var rng := RandomNumberGenerator.new()
		rng.seed = seed_
		make_loop()
		var p := make_bird(0.03, Vector3.ZERO, Vector3.FORWARD, true)
		loop.start_run()
		loop.set_protection(p, 0.0)
		loop.endless = true  # keep the walk going past the apex
		start_logging()
		var problems: Array[String] = []
		var tier_seen := SizeRules.tier_for_mass(p.mass)
		var tier_changes := 0
		var growth_meals := 0
		var ops := 0
		var hawk := make_bird(10.0, Vector3(0, -900, 0))
		for i in 500:
			var n_tier_before := count("tier")
			var n_grew_before := count("grew")
			var m_before := p.mass
			var r := rng.randf()
			var grew_expected := false
			if loop.phase == GameLoop.Phase.ENDED:
				loop.start_run()
				loop.set_protection(p, 0.0)
				loop.endless = true
				tier_seen = SizeRules.tier_for_mass(p.mass)
				n_tier_before = count("tier")
				n_grew_before = count("grew")
				m_before = p.mass
			if r < 0.75:
				# A meal: ratio from dust (1%) to the largest edible (0.8).
				var ratio := exp(rng.randf_range(log(0.01), log(0.79)))
				var q := _feed(p, p.mass * ratio)
				if q.alive:
					problems.append("seed %d op %d: meal not eaten" % [seed_, i])
				grew_expected = SizeRules.meal_gain(m_before, p.mass * 0 + m_before * ratio) > 0.0 and m_before < GameLoop.MAX_PLAYER_MASS - 1e-9
			elif r < 0.85:
				# Caught and the beat played out.
				loop.set_protection(p, 0.0)
				hawk.mass = maxf(10.0, p.mass * 2.0)
				hawk.global_position = p.get_body_position() + Vector3(0, 0, 0.3)
				loop.teleported(hawk)
				loop.step(DT)
				hawk.global_position = Vector3(0, -900, 0)
				loop.teleported(hawk)
				run_steps(int(GameLoop.CAUGHT_BEAT_S / DT) + 2, DT)
				loop.set_protection(p, 0.0)
			else:
				run_steps(rng.randi_range(1, 30), DT)
			ops += 1
			# --- invariants ---
			var tier_now := SizeRules.tier_for_mass(p.mass)
			var new_tier_events := events("tier").slice(n_tier_before)
			if loop.phase == GameLoop.Phase.ENDED:
				continue  # the restart above re-syncs
			if tier_now != tier_seen:
				tier_changes += 1
				if new_tier_events.size() != 1:
					problems.append("seed %d op %d: tier %d->%d emitted %d events" % [seed_, i, tier_seen, tier_now, new_tier_events.size()])
				elif new_tier_events[0][1] != tier_seen or new_tier_events[0][2] != tier_now:
					problems.append("seed %d op %d: event %s but tier %d->%d" % [seed_, i, str(new_tier_events[0]), tier_seen, tier_now])
			elif new_tier_events.size() != 0:
				problems.append("seed %d op %d: %d tier events without a tier change" % [seed_, i, new_tier_events.size()])
			tier_seen = tier_now
			var grew_n := count("grew") - n_grew_before
			if p.mass > m_before + 1e-12:
				growth_meals += 1
				if grew_n != 1:
					problems.append("seed %d op %d: grew %.4f->%.4f with %d player_grew" % [seed_, i, m_before, p.mass, grew_n])
			elif grew_n != 0:
				problems.append("seed %d op %d: player_grew without growth" % [seed_, i])
			if p.species != SizeRules.species_for_mass(p.mass):
				problems.append("seed %d op %d: species %s at %.4f kg" % [seed_, i, p.species, p.mass])
			if p.mass > GameLoop.MAX_PLAYER_MASS + 1e-9 or p.mass < GameLoop.START_MASS - 1e-9:
				problems.append("seed %d op %d: mass %.4f out of [start, cap]" % [seed_, i, p.mass])
			if loop.stats.peak_tier < tier_now:
				problems.append("seed %d op %d: peak tier below current" % [seed_, i])
		metric("seed_%d" % seed_, {"ops": ops, "tier_changes": tier_changes, "growth_meals": growth_meals,
				"final_species": p.species, "problems": problems.slice(0, 6)})
		gt(float(tier_changes), 10.0, "seed %d: the walk crossed many tiers" % seed_)
		eq(problems.size(), 0, "seed %d: tier/grow events exactly once per change, species follows mass, caps hold" % seed_)
		await cleanup()


func test_worth_boundary_matches_highlight_and_target() -> void:
	# At every player species, prey just above / just below the worth
	# threshold: highlight 1 and targetable only above.
	var wrong: Array[String] = []
	for t in range(SizeRules.species_index(&"sparrow"), SizeRules.SPECIES.size()):
		var pm: float = float(SizeRules.SPECIES[t]["mass"]) * 1.2
		# Find the prey mass where meal_value crosses WORTH_MIN (bisection).
		var lo := pm * SizeRules.MEAL_DUST_RATIO
		var hi := pm / SizeRules.EAT_RATIO
		for k in 60:
			var mid := (lo + hi) * 0.5
			if SizeRules.is_worthwhile(pm, mid):
				hi = mid
			else:
				lo = mid
		for f in [0.97, 1.03]:
			make_loop()
			var p := make_bird(pm, Vector3.ZERO, Vector3.FORWARD, true)
			loop.start_run()
			p.mass = pm
			loop.set_protection(p, 1e6)
			var q := make_bird(hi * f, p.get_body_position() + Vector3(0, 0, -10.0 * p.get_wingspan()), Vector3.RIGHT, false, true)
			loop.set_protection(q, 1e6)
			loop.step(DT)
			loop.step(DT)
			var want_hl := 1 if f > 1.0 else 0
			if q.model.highlight != want_hl:
				wrong.append("%s eats %.4f (x%.2f of threshold): highlight %d" % [SizeRules.SPECIES[t]["id"], q.mass, f, q.model.highlight])
			if (loop.watch.target == q) != (f > 1.0):
				wrong.append("%s eats %.4f (x%.2f): target=%s" % [SizeRules.SPECIES[t]["id"], q.mass, f, loop.watch.target == q])
			await cleanup()
	eq(wrong.size(), 0, "highlight and target follow is_worthwhile exactly at the threshold: %s" % str(wrong))
