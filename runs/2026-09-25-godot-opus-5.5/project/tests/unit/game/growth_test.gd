extends "res://tests/unit/game/game_fixture.gd"
## G2 — growth: the meal formula and its diminishing returns, growth through
## the real loop, tier/species transitions emitting their events exactly once,
## NPC growth caps, continuity of body size.

const DT := 1.0 / 72.0


func _species_mass(id: StringName) -> float:
	return float(SizeRules.species_data(id)["mass"])


## Puts a prey of prey_mass right in front of the player and steps once.
## Returns true if it was eaten. Then clears the player's handling time.
func feed(p: SimBird, prey_mass: float) -> bool:
	var c := loop.rule.contact_distance(p.get_body_radius(), p.get_wingspan(), true,
			SizeRules.body_radius_for_mass(prey_mass))
	var q := make_bird(prey_mass, p.get_body_position() + p.get_forward() * c * 0.5)
	loop.step(DT)
	var eaten := not q.alive
	loop.step(GameLoop.SWALLOW_MAX_S + 0.05)  # past the player's swallowing (at most SWALLOW_MAX_S)
	return eaten


func test_meal_gain_formula() -> void:
	# gain = MEAL_CONVERSION * growth_efficiency(eater) * prey * smoothstep(DUST, FULL, prey/eater),
	# growth_efficiency = GROWTH_GAIN * min(1, (eater / REF)^-EXP)
	near(SizeRules.MEAL_CONVERSION, 0.8, 1e-9, "conversion")
	near(SizeRules.GROWTH_GAIN, 1.8, 1e-9, "growth gain (pacing tune through the real flight chain, docs/areas/GAMELOOP.md)")
	near(SizeRules.GROWTH_SIZE_EXP, 0.42, 1e-9, "growth size exponent (pacing tune)")
	for pair in [[1.0, 0.5], [1.0, 0.25], [1.0, 0.1], [1.0, 0.03], [0.03, 0.012], [4.5, 0.6]]:
		var e: float = pair[0]
		var q: float = pair[1]
		var r := q / e
		var eff := SizeRules.GROWTH_GAIN * minf(1.0, pow(e / SizeRules.GROWTH_REF_MASS, -SizeRules.GROWTH_SIZE_EXP))
		# What it is worth chasing does not depend on the eater's size...
		near(SizeRules.meal_value(e, q), 0.8 * r * smoothstep(SizeRules.MEAL_DUST_RATIO, SizeRules.MEAL_FULL_RATIO, r) if SizeRules.can_eat(e, q) else 0.0,
				1e-12, "meal_value(%.3f, %.3f) depends only on the ratio" % [e, q])
		var want := 0.8 * eff * q * smoothstep(SizeRules.MEAL_DUST_RATIO, SizeRules.MEAL_FULL_RATIO, r)
		near(SizeRules.meal_gain(e, q), want, 1e-12, "gain(%.3f eats %.3f)" % [e, q])
		near(SizeRules.meal_worth(e, q), want / e, 1e-12, "worth = gain / eater mass")
	eq(SizeRules.meal_gain(1.0, 0.9), 0.0, "no gain from prey it cannot eat")
	eq(SizeRules.meal_efficiency(SizeRules.MEAL_DUST_RATIO), 0.0, "dust ratio worth nothing")
	eq(SizeRules.meal_efficiency(0.01), 0.0, "below dust ratio worth nothing")
	eq(SizeRules.meal_efficiency(SizeRules.MEAL_FULL_RATIO), 1.0, "full ratio worth everything")
	eq(SizeRules.meal_efficiency(0.6), 1.0, "above full ratio worth everything")
	# A best-case meal (the largest edible prey) grows a sparrow by 64%
	# (0.8 x 0.8 x GROWTH_GAIN)...
	near(SizeRules.meal_worth(0.03, 0.03 / SizeRules.EAT_RATIO), 0.64 * SizeRules.GROWTH_GAIN, 1e-9, "max worth per meal at sparrow size")
	# ...and growing gets harder with size (metabolic scaling).
	eq(SizeRules.growth_efficiency(0.01), SizeRules.GROWTH_GAIN, "full efficiency below the reference mass")
	near(SizeRules.growth_efficiency(SizeRules.GROWTH_REF_MASS * 10.0), SizeRules.GROWTH_GAIN * pow(10.0, -SizeRules.GROWTH_SIZE_EXP), 1e-9,
			"10x the reference mass: GROWTH_GAIN x 10^-exp")
	var prev := INF
	var ok := true
	for m in [0.03, 0.1, 0.3, 1.0, 3.0, 4.5]:
		var ge := SizeRules.growth_efficiency(m)
		ok = ok and ge < prev + 1e-12
		prev = ge
	check(ok, "growth efficiency never rises with size")
	# How much harder is a pacing value: GROWTH_SIZE_EXP, pinned exactly
	# above and tuned so the haul from pigeon to eagle takes the brief's time
	# in the shipped valley (round 1 also pinned the ratio below at < 0.4 -
	# its own tuning's value in the AI's test world). Pinned here: it is
	# harder (0.87 of a sparrow's with the fix round 4 tuning; 0.23 with the
	# core loop round's 1.15 / 0.32 - through the real flight chain big
	# players catch as often as small ones once they fly as well as a person
	# does, so the long haul from pigeon to eagle comes from the meals).
	lt(SizeRules.meal_worth(3.0, 3.0 / SizeRules.EAT_RATIO), SizeRules.meal_worth(0.03, 0.03 / SizeRules.EAT_RATIO) * 0.95,
			"an eagle-sized best meal is worth less than a sparrow's")


func test_diminishing_returns() -> void:
	# For a fixed prey, the eater's gain *fraction* falls as the eater grows,
	# and falls faster than 1/mass once the prey is below the full ratio.
	for prey: Dictionary in SizeRules.SPECIES:
		var qm: float = prey["mass"]
		var prev := INF
		var m := qm * SizeRules.EAT_RATIO
		while m < 7.0:
			var w := SizeRules.meal_worth(m, qm)
			check(w <= prev + 1e-12, "%s: worth never rises as the eater grows (m=%.3f)" % [prey["id"], m])
			prev = w
			m *= 1.1
	# Faster than proportional: doubling the eater from ratio 0.2 to 0.1
	# costs more than half the worth.
	var w1 := SizeRules.meal_worth(1.0, 0.2)
	var w2 := SizeRules.meal_worth(2.0, 0.2)
	lt(w2, w1 * 0.5, "diminishing: 2x eater gets < half the relative worth from the same prey")
	# Absolute gain also shrinks for small prey (not just relative).
	lt(SizeRules.meal_gain(2.0, 0.2), SizeRules.meal_gain(1.0, 0.2), "absolute gain from small prey shrinks as you grow")
	# The worthwhile threshold removes the smallest species as you climb.
	var table := {}
	for eater: Dictionary in SizeRules.SPECIES:
		var row := []
		for prey: Dictionary in SizeRules.SPECIES:
			row.append(snappedf(SizeRules.meal_worth(eater["mass"], prey["mass"]), 0.001))
		table[eater["id"]] = row
	metric("worth_table", table)
	check(SizeRules.is_worthwhile(_species_mass(&"sparrow"), _species_mass(&"moth")), "a sparrow still wants moths")
	check(not SizeRules.is_worthwhile(_species_mass(&"starling"), _species_mass(&"moth")), "a starling ignores moths")
	check(not SizeRules.is_worthwhile(_species_mass(&"pigeon"), _species_mass(&"wren")), "a pigeon ignores wrens")
	check(not SizeRules.is_worthwhile(_species_mass(&"hawk"), _species_mass(&"sparrow")), "a hawk ignores sparrows")
	check(SizeRules.is_worthwhile(_species_mass(&"eagle"), _species_mass(&"gull")), "an eagle hunts gulls")
	check(SizeRules.is_worthwhile(_species_mass(&"eagle"), _species_mass(&"hawk")), "an eagle hunts hawks")
	check(not SizeRules.is_worthwhile(_species_mass(&"eagle"), _species_mass(&"pigeon")), "pigeons are beneath an eagle")


func test_player_growth_through_loop() -> void:
	make_loop(true)
	var p := make_bird(0.03, Vector3.ZERO, Vector3.FORWARD, true)
	loop.start_run()
	loop.set_protection(p, 0.0)
	start_logging()
	var m0 := p.mass
	var qm := 0.012  # wren
	var expected := m0 + SizeRules.meal_gain(m0, qm)
	check(feed(p, qm), "wren eaten")
	near(p.mass, expected, 1e-9, "player mass grew by exactly meal_gain")
	eq(count("grew"), 1, "player_grew once per meal")
	var g: Array = events("grew")[0]
	near(g[1], m0, 1e-9, "player_grew old mass")
	near(g[2], expected, 1e-9, "player_grew new mass")
	eq(g[3], SizeRules.tier_for_mass(expected), "player_grew tier")
	eq(p.species, SizeRules.species_for_mass(expected), "species follows mass")
	var st := loop.get_run_stats()
	eq(st["catches"], 1, "stats count the catch")
	near(st["mass_gained"], expected - m0, 1e-9, "stats track mass gained")
	eq(st["catches_by_species"].get(&"wren", 0), 1, "per-species count")


func test_tier_events_exactly_once_up_the_ladder() -> void:
	make_loop(true)
	var p := make_bird(0.03, Vector3.ZERO, Vector3.FORWARD, true)
	loop.start_run()
	loop.set_protection(p, 0.0)
	start_logging()
	var meals := 0
	var species_seen: Array[StringName] = [p.species]
	while p.species != &"eagle" and meals < 40:
		# Always the biggest edible prey: the fastest possible climb.
		check(feed(p, p.mass / SizeRules.EAT_RATIO * 0.999), "meal %d eaten" % meals)
		meals += 1
		if species_seen[-1] != p.species:
			species_seen.append(p.species)
			loop.step(GameLoop.TIER_SETTLE_S)  # (the new species settles in)
	eq(p.species, &"eagle", "reached the eagle")
	eq(count("grew"), meals, "one player_grew per meal")
	var tiers := events("tier")
	var prev_new := SizeRules.species_index(&"sparrow")
	var ok_chain := true
	for e in tiers:
		if e[1] != prev_new or e[2] <= e[1]:
			ok_chain = false
		prev_new = e[2]
	check(ok_chain, "tier events chain old->new without gaps or repeats: %s" % str(tiers))
	eq(prev_new, SizeRules.species_index(&"eagle"), "last tier event lands on eagle")
	eq(tiers.size(), species_seen.size() - 1, "exactly one tier event per species change")
	# Each tier crossed at most once: no duplicates.
	var seen := {}
	for e in tiers:
		check(not seen.has(e[2]), "tier %d announced once" % e[2])
		seen[e[2]] = true
	metric("meals_sparrow_to_eagle_best_case", meals)
	metric("species_path", species_seen)
	# Nothing grows past the cap (growing at eagle size takes many meals).
	# Endless mode, or the fifth eagle meal would win the run (apex goal).
	loop.endless = true
	var extra := 0
	var over := false
	while p.mass < GameLoop.MAX_PLAYER_MASS - 1e-9 and extra < 80:
		feed(p, p.mass / SizeRules.EAT_RATIO * 0.999)
		over = over or p.mass > GameLoop.MAX_PLAYER_MASS + 1e-9
		extra += 1
	feed(p, p.mass / SizeRules.EAT_RATIO * 0.999)
	check(not over, "never above the cap")
	metric("meals_eagle_to_cap_best_case", extra)
	lt(p.mass, GameLoop.MAX_PLAYER_MASS + 1e-9, "player mass capped")
	near(p.mass, GameLoop.MAX_PLAYER_MASS, 1e-6, "cap reached")
	near(GameLoop.MAX_PLAYER_MASS, float(SizeRules.species_data(&"eagle")["mass"]) * 1.5, 1e-9,
			"cap is 1.5x the apex species")


func test_a_feast_never_skips_the_ladder() -> void:
	# Core loop fix round 1 (the verifier's "murmuration buffet": a swallow
	# ate five starlings in 0.6 s and went sparrow -> crow in 54 s, four
	# tier-up celebrations): after a catch the player swallows - no catch for
	# SWALLOW_S_PER_GAIN x the share of its mass the meal added (0.2-1.2 s) -
	# and for TIER_SETTLE_S after a tier-up meals grow it at most to just
	# under the next species. A feast with prey at every turn: never two
	# tier-ups within 30 s.
	eq([GameLoop.SWALLOW_S_PER_GAIN, GameLoop.SWALLOW_MAX_S, GameLoop.TIER_SETTLE_S], [2.5, 1.2, 30.0], "the numbers (literal)")
	make_loop(true)
	var p := make_bird(0.03, Vector3.ZERO, Vector3.FORWARD, true)
	loop.start_run()
	loop.set_protection(p, 0.0)
	# A big meal, and a second prey at the beak right after it: swallowing.
	var c := loop.rule.contact_distance(p.get_body_radius(), p.get_wingspan(), true, SizeRules.body_radius_for_mass(0.02))
	var q1 := make_bird(0.02, p.get_body_position() + p.get_forward() * c * 0.5)
	var m0 := p.mass
	loop.step(DT)
	check(not q1.alive, "(setup) the first meal is eaten")
	var gain := (p.mass - m0) / m0
	var swallow := minf(GameLoop.SWALLOW_MAX_S, GameLoop.SWALLOW_S_PER_GAIN * gain)
	gt(swallow, 0.5, "(setup) a big meal: %.0f%% of its mass, %.2f s to swallow" % [gain * 100.0, swallow])
	var q2 := make_bird(0.02, p.get_body_position() + p.get_forward() * c * 0.5)
	var t := 0.0
	while q2.alive and t < 3.0:
		loop.step(DT)
		t += DT
		q2.global_position = p.get_body_position() + p.get_forward() * c * 0.5
	check(not q2.alive, "the second prey is eaten once swallowed")
	near(t, swallow, 2.0 * DT, "...not before: %.2f s after the first (swallowing %.2f s)" % [t, swallow])
	# A feast: the biggest edible prey at the beak whenever it can eat, for
	# three minutes - tier-ups at least TIER_SETTLE_S apart.
	var ups: Array[float] = []
	var tier := SizeRules.tier_for_mass(p.mass)
	var el := 0.0
	var q: SimBird = null
	while el < 180.0 and p.species != &"eagle":
		if q == null or not q.alive:
			q = make_bird(p.mass / SizeRules.EAT_RATIO * 0.999, p.get_body_position() + p.get_forward() * c * 0.3)
		q.global_position = p.get_body_position() + p.get_forward() * loop.rule.contact_distance(p.get_body_radius(),
				p.get_wingspan(), true, q.get_body_radius()) * 0.3
		loop.step(DT)
		el += DT
		var nt := SizeRules.tier_for_mass(p.mass)
		if nt > tier:
			ups.append(el)
			tier = nt
	metric("feast_tier_ups_s", ups)
	gt(float(ups.size()), 3.0, "(setup) the feast climbs the ladder (%d tier-ups in 3 min)" % ups.size())
	var closest := INF
	for i in range(1, ups.size()):
		closest = minf(closest, ups[i] - ups[i - 1])
	gt(closest, GameLoop.TIER_SETTLE_S - 2.0 * DT, "never two tier-ups within %.0f s (closest %.1f s)" % [GameLoop.TIER_SETTLE_S, closest])


func test_shrinking_emits_tier_down_once_and_no_growth() -> void:
	make_loop(true)
	var p := make_bird(0.03, Vector3.ZERO, Vector3.FORWARD, true)
	loop.start_run()
	loop.set_protection(p, 0.0)
	# Grow to just above the pigeon threshold.
	var pigeon: float = SizeRules.species_data(&"pigeon")["mass"]
	p.mass = pigeon * 1.03
	loop.step(DT)  # adopt the externally set mass silently
	start_logging()
	var hawk := make_bird(1.3, p.get_body_position() + Vector3(0, 0, 0.3))
	hawk.set_heading(Vector3.FORWARD)
	loop.step(DT)
	eq(count("player_caught"), 1, "caught")
	run_steps(int(GameLoop.CAUGHT_BEAT_S / DT) + 2, DT)
	# (a first death: the danger assist is DANGER_ASSIST_PER_DEATH, which
	# cuts the penalty by DANGER_ASSIST_PENALTY_CUT x that)
	near(p.mass, pigeon * 1.03 * (1.0 - GameLoop.CAUGHT_MASS_LOSS * (1.0 - GameLoop.DANGER_ASSIST_PENALTY_CUT * GameLoop.DANGER_ASSIST_PER_DEATH)), 1e-9, "penalty applied")
	eq(count("grew"), 0, "losing mass is not growth")
	var t := events("tier")
	eq(t.size(), 1, "one tier event for the drop")
	if t.size() == 1:
		eq(t[0][1], SizeRules.species_index(&"pigeon"), "from pigeon")
		eq(t[0][2], SizeRules.species_index(&"starling"), "to starling")
	eq(p.species, &"starling", "species follows the drop")


func test_npc_growth_is_capped() -> void:
	make_loop()
	var hawk := make_bird(1.3, Vector3(0, 20, 0))
	var base := hawk.mass
	var gains: Array[float] = []
	for i in 12:
		var prev := hawk.mass
		# (A small first meal, whose share is under the cap; then pigeons.)
		var qm := 0.13 if i == 0 else 0.35
		var q := make_bird(qm, hawk.global_position + Vector3(0, 0, -0.5))
		loop.step(DT)
		check(not q.alive, "hawk eats meal %d" % i)
		gains.append(hawk.mass - prev)
		loop.step(1.5)  # handling time
		q.global_position = Vector3(0, -500, 0)
	lt(SizeRules.meal_gain(base, 0.13) * GameLoop.NPC_GROWTH_SHARE, base * GameLoop.NPC_GROWTH_CAP, "(setup) the first meal's share is under the cap")
	near(gains[0], SizeRules.meal_gain(base, 0.13) * 0.5, 1e-9, "NPC keeps half of the first meal's gain (NPC_GROWTH_SHARE)")
	near(hawk.mass, base * (1.0 + GameLoop.NPC_GROWTH_CAP), 1e-9, "NPC growth capped at +%d%%" % roundi(GameLoop.NPC_GROWTH_CAP * 100.0))
	eq(hawk.species, &"hawk", "NPC keeps its species")
	eq(SizeRules.tier_for_mass(hawk.mass), SizeRules.species_index(&"hawk"), "capped growth never crosses a tier")
	metric("npc_gains", gains)


## The AI's spawn band: a species spawns within +-9% of its ladder mass
## (docs/areas/AI.md; the AI's Ecosystem._make_npc). A copy, not a
## reference: the game suite never loads the AI's code.
const AI_SPAWN_BAND := 0.09


func test_no_bird_eats_its_own_kind_however_well_fed() -> void:
	# The heaviest bird of a species the AI can spawn, fed to the loop's cap,
	# still cannot eat the lightest of its kind - nor a player who has just
	# become that species (round 2's +15% cap allowed both: a well-fed NPC
	# eagle ate a player eagle).
	for s in SizeRules.SPECIES:
		var nominal: float = s["mass"]
		var fed := nominal * (1.0 + AI_SPAWN_BAND) * (1.0 + GameLoop.NPC_GROWTH_CAP)
		check(not SizeRules.can_eat(fed, nominal * (1.0 - AI_SPAWN_BAND)), "%s: a fed heavy one cannot eat a light one" % s["id"])
		check(not SizeRules.can_eat(fed, nominal), "%s: ...nor a player just grown into the species" % s["id"])
	# Through the loop: a heavy sparrow eats wrens to the cap, then meets a
	# light sparrow head on.
	make_loop()
	var heavy := make_bird(0.03 * (1.0 + AI_SPAWN_BAND), Vector3(0, 20, 0))
	for i in 12:
		var q := make_bird(0.012, heavy.global_position + Vector3(0, 0, -0.05))
		loop.step(DT)
		loop.step(1.5)
		q.global_position = Vector3(0, -500, 0)
	near(heavy.mass, 0.03 * (1.0 + AI_SPAWN_BAND) * (1.0 + GameLoop.NPC_GROWTH_CAP), 1e-9, "(setup) fed to the cap")
	var light := make_bird(0.03 * (1.0 - AI_SPAWN_BAND), heavy.global_position + Vector3(0, 0, -0.05))
	loop.step(DT)
	check(light.alive, "the fed sparrow cannot eat the light sparrow")


func test_npc_catches_are_counted_in_a_run() -> void:
	# The run's stats count the NPC catches that happen while it is on (the
	# summary's "the sky was alive" line); outside a run NPCs still eat each
	# other (the sky behind the menu), uncounted.
	make_loop()
	var hawk := make_bird(1.3, Vector3(0, 20, 0))
	var q1 := make_bird(0.3, hawk.global_position + Vector3(0, 0, -0.5))
	loop.step(DT)
	check(not q1.alive, "(setup) an NPC catch outside a run")
	eq(loop.stats.npc_catches, 0, "not counted outside a run")
	var p := make_bird(0.03, Vector3(200, 20, 0), Vector3.FORWARD, true)
	loop.start_run()
	loop.set_protection(p, 600.0)
	loop.step(1.5)
	var q2 := make_bird(0.3, hawk.global_position + Vector3(0, 0, -0.5))
	loop.step(DT)
	check(not q2.alive, "(setup) an NPC catch in the run")
	eq(loop.stats.npc_catches, 1, "counted in the run")
	eq(int(loop.get_run_stats()["npc_catches"]), 1, "get_run_stats().npc_catches")
	loop.end_run(&"quit")
	eq(int(loop.get_last_summary()["npc_catches"]), 1, "in the run summary")


func test_new_peak_tier_gives_a_life_back() -> void:
	make_loop(true)
	var p := make_bird(0.03, Vector3.ZERO, Vector3.FORWARD, true)
	loop.start_run()
	loop.set_protection(p, 0.0)
	loop.lives = 1
	# Sparrow -> swallow: new peak tier.
	while p.species == &"sparrow":
		feed(p, p.mass / SizeRules.EAT_RATIO * 0.999)
	eq(loop.lives, 2, "new tier restored a life")
	var peak := loop.stats.peak_tier
	# Drop back and re-reach the same tier (with small meals, so no meal
	# overshoots into a new peak): no extra life.
	loop.lives = 1
	loop.meals_since_life_lost = 0
	p.mass = SizeRules.SPECIES[peak - 1]["mass"] * 1.2
	loop.step(DT)
	var meals := 0
	while SizeRules.tier_for_mass(p.mass) <= peak - 1:
		feed(p, p.mass * 0.15)
		meals += 1
	eq(SizeRules.tier_for_mass(p.mass), peak, "(setup) back at the old peak tier, not beyond")
	eq(loop.lives, mini(1 + meals / GameLoop.LIFE_PER_MEALS, GameLoop.MAX_LIVES),
			"re-reaching a tier already reached gives nothing (only eat-to-heal: %d meals)" % meals)
	loop.lives = GameLoop.MAX_LIVES
	while SizeRules.tier_for_mass(p.mass) <= peak:
		feed(p, p.mass / SizeRules.EAT_RATIO * 0.999)
	eq(loop.lives, GameLoop.MAX_LIVES, "lives never exceed the maximum")


func test_eat_to_heal() -> void:
	# Every LIFE_PER_MEALS-th worthwhile catch since a life was last lost
	# gives it back (up to MAX_LIVES); dust does not count; losing a life
	# starts the count again.
	make_loop(true)
	var p := make_bird(0.03, Vector3.ZERO, Vector3.FORWARD, true)
	loop.start_run()
	# (A crow with small meals: no new tier on the way.)
	p.mass = 0.5
	loop.step(DT)
	loop.set_protection(p, 0.0)
	loop.lives = 1
	var tier0 := SizeRules.tier_for_mass(p.mass)
	for i in GameLoop.LIFE_PER_MEALS - 1:
		feed(p, p.mass * 0.12)
	check(SizeRules.is_worthwhile(p.mass, p.mass * 0.12), "(setup) worthwhile meals")
	eq(loop.lives, 1, "%d worthwhile catches: not yet" % (GameLoop.LIFE_PER_MEALS - 1))
	check(not SizeRules.is_worthwhile(p.mass, p.mass * 0.02), "(setup) dust")
	feed(p, p.mass * 0.02)
	eq(loop.lives, 1, "dust does not count")
	feed(p, p.mass * 0.12)
	eq(SizeRules.tier_for_mass(p.mass), tier0, "(setup) still the same tier")
	eq(loop.lives, 2, "the %d-th worthwhile catch gives a life back" % GameLoop.LIFE_PER_MEALS)
	loop.lives = GameLoop.MAX_LIVES
	loop.meals_since_life_lost = 0
	for i in GameLoop.LIFE_PER_MEALS + 1:
		feed(p, p.mass * 0.12)
	eq(loop.lives, GameLoop.MAX_LIVES, "never above MAX_LIVES")
	eq(loop.meals_since_life_lost, 0, "no count while at full lives")


func test_tier_progress_is_in_log_mass() -> void:
	# The HUD's size bar: progress to the next species in log mass - a meal
	# grows the player by a fraction, so the same meal fills the same share
	# of the bar at every size. Halfway in log terms between two species is
	# 0.5 (a linear bar would show 0.42 between sparrow and swallow).
	make_loop()
	var p := make_bird(GameLoop.START_MASS, Vector3(0, 30, 0), Vector3.FORWARD, true)
	loop.start_run()
	for pair: Array in [[&"sparrow", &"swallow"], [&"hawk", &"eagle"]]:
		p.mass = sqrt(_species_mass(pair[0]) * _species_mass(pair[1]))
		loop.step(DT)
		near(float(loop.get_run_stats()["tier_progress"]), 0.5, 1e-6, "halfway (log mass) from %s to %s" % pair)
	p.mass = _species_mass(&"pigeon") * 1.0001
	loop.step(DT)
	near(float(loop.get_run_stats()["tier_progress"]), 0.0, 1e-3, "just a pigeon: an empty bar")


## A stand-in for the AI's Ecosystem: only its NPC budget.
class _Budget extends Node:
	var max_npcs := 60

	func _enter_tree() -> void:
		add_to_group(&"ecosystem")


func test_a_sparser_sky_grows_the_player_more_per_meal() -> void:
	# The Quest tier's Ecosystem runs 28 NPCs (the governor down to 20), not
	# the 60 the growth was tuned for: fewer chases, so each meal grows the
	# player x (60 / budget) ^ (0.08 x ramp; 0.55 before core loop fix round
	# 1, whose tuning found the Quest's sky no longer short of meals) - the
	# ramp flat at 1 since the
	# core loop round's second pass (the Quest sky's shortage is worst in
	# the swallow-to-pigeon middle; the old ramp from 0.3 helped least
	# there) - at most x2 (GameLoop.sky_growth; fix round 5 review: at 28 NPCs
	# a competent player reached the eagle at 39:44, the brief is 20-30;
	# core loop round: 0.3, was 0.6 - with the danger director and the
	# pellets the Quest tier's sky is less of a handicap: at 0.6 its
	# real-chain eagle came at 16:51 against the full tier's 24:03).
	# Literal values.
	make_loop()
	var p := make_bird(GameLoop.START_MASS, Vector3(0, 30, 0), Vector3.FORWARD, true)
	loop.start_run()
	eq(loop.sky_budget(), 0, "(setup) no Ecosystem")
	near(loop.sky_growth(3.0), 1.0, 1e-12, "no Ecosystem (dev scenes, the AI mirror): x1")
	var eco := _Budget.new()
	add_child(eco)
	for row: Array in [[60, 3.0, 1.0], [90, 3.0, 1.0], [28, 0.03, 1.062868], [28, 0.3, 1.062868], [28, 3.0, 1.062868],
			[28, 4.5, 1.062868], [20, 3.0, 1.091867], [10, 3.0, 1.154123]]:
		eco.max_npcs = row[0]
		near(loop.sky_growth(float(row[1])), float(row[2]), 1e-4, "%d NPCs, %.2f kg: x%.3f" % row)
	# Through a meal (the player's; an NPC's growth is its own).
	eco.max_npcs = 28
	loop.set_protection(p, 0.0)
	var before := p.mass
	check(feed(p, 0.01), "(setup) the meal is eaten")
	near(p.mass - before, SizeRules.meal_gain(before, 0.01) * 1.062868, 1e-7, "a sparrow's meal at 28 NPCs grows it x1.06")
	eco.queue_free()


func test_body_size_is_continuous_across_tiers() -> void:
	# The player's world_scale follows wingspan: no jumps at tier-ups.
	var m := 0.003
	var prev := SizeRules.wingspan_for_mass(m)
	var worst_step := 0.0
	var not_increasing := 0
	var samples := 0
	while m < 7.0:
		var m2 := m * 1.001
		var s2 := SizeRules.wingspan_for_mass(m2)
		if s2 <= prev:
			not_increasing += 1
		worst_step = maxf(worst_step, s2 / prev)
		prev = s2
		m = m2
		samples += 1
	eq(not_increasing, 0, "span strictly increasing over %d samples from 3 g to 7 kg" % samples)
	lt(worst_step, 1.0015, "no step bigger than 0.15% for a 0.1% mass change (continuous)")
	metric("worst_span_step_ratio", worst_step)
	for s: Dictionary in SizeRules.SPECIES:
		near(SizeRules.wingspan_for_mass(s["mass"]), s["span"], 1e-9, "%s exact span" % s["id"])
		near(SizeRules.body_radius_for_mass(s["mass"]), float(s["span"]) * 0.16, 1e-9, "%s radius" % s["id"])
