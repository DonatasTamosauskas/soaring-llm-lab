extends "res://tests/unit/game/game_fixture.gd"
## G8 — the apex goal (become the eagle, then make APEX_CATCHES worthwhile
## catches) with its celebration signals, and the run summary's content.

const DT := 1.0 / 72.0


func feed(p: SimBird, prey_mass: float) -> SimBird:
	var c := loop.rule.contact_distance(p.get_body_radius(), p.get_wingspan(), true,
			SizeRules.body_radius_for_mass(prey_mass))
	var q := make_bird(prey_mass, p.get_body_position() + p.get_forward() * c * 0.5)
	q.species = SizeRules.species_for_mass(prey_mass)
	loop.step(DT)
	loop.step(GameLoop.SWALLOW_MAX_S + 0.05)
	return q


func test_apex_goal_and_victory() -> void:
	make_loop()
	var p := make_bird(0.03, Vector3.ZERO, Vector3.FORWARD, true)
	loop.start_run()
	loop.set_protection(p, 0.0)
	var reached := []
	var progress := []
	var won := []
	loop.apex_reached.connect(func() -> void: reached.append(loop.stats.run_time))
	loop.apex_progress.connect(func(n: int, need: int) -> void: progress.append([n, need]))
	loop.victory.connect(func(s: Dictionary) -> void: won.append(s))
	start_logging()
	var eagle: float = SizeRules.species_data(&"eagle")["mass"]
	p.mass = eagle * 0.97  # a big hawk
	loop.step(DT)
	eq(reached.size(), 0, "not apex yet")
	eq(p.species, &"hawk", "(setup) a hawk")
	# The meal that makes you an eagle does not count toward the goal.
	feed(p, eagle * 0.3)
	eq(p.species, &"eagle", "became the eagle")
	eq(reached.size(), 1, "apex_reached once")
	eq(progress.size(), 0, "the promoting meal is not an apex catch")
	# Dust does not count either.
	feed(p, 0.03)
	check(not SizeRules.is_worthwhile(p.mass, 0.03), "(setup) a sparrow is dust to an eagle")
	eq(progress.size(), 0, "non-worthwhile catch does not count")
	# Worthwhile catches count; the last one wins the run.
	for i in GameLoop.APEX_CATCHES:
		eq(Game.state, Game.State.PLAYING, "still playing before catch %d" % (i + 1))
		check(SizeRules.is_worthwhile(p.mass, eagle * 0.3), "(setup) apex prey worthwhile")
		feed(p, eagle * 0.3)
	eq(progress.size(), GameLoop.APEX_CATCHES, "apex_progress per worthwhile catch")
	eq(progress[-1], [GameLoop.APEX_CATCHES, GameLoop.APEX_CATCHES], "progress reaches the goal")
	eq(won.size(), 1, "victory once")
	eq(Game.state, Game.State.ENDED, "run ended in victory")
	eq(count("run_ended"), 1, "run_ended once")
	var s: Dictionary = events("run_ended")[0][1]
	eq(s["reason"], &"victory", "reason victory")
	check(s["victory"], "summary.victory")
	eq(s["apex"]["catches"], GameLoop.APEX_CATCHES, "apex catches in summary")
	check(s["apex"]["reached"], "apex reached in summary")
	check(p.controls_enabled, "victory lap: controls stay on")
	# No further catches count after the end; reaching apex again doesn't re-fire.
	feed(p, eagle * 0.3)
	eq(won.size(), 1, "no second victory")
	eq(reached.size(), 1, "apex_reached still once")


func test_continue_after_victory() -> void:
	make_loop()
	var eagle: float = SizeRules.species_data(&"eagle")["mass"]
	var p := make_bird(0.03, Vector3.ZERO, Vector3.FORWARD, true)
	loop.start_run()
	loop.set_protection(p, 0.0)
	p.mass = eagle * 0.97
	loop.step(DT)
	feed(p, eagle * 0.3)
	for i in GameLoop.APEX_CATCHES:
		feed(p, eagle * 0.3)
	eq(Game.state, Game.State.ENDED, "won")
	# (No engine frames run in this suite, so the run clock is set by hand:
	# a 0 kept and a 0 reset would look the same - fix round 3 review.)
	Game.run_time = 1234.5
	loop.continue_after_victory()
	eq(Game.state, Game.State.PLAYING, "keep flying")
	check(loop.endless, "endless mode")
	near(Game.run_time, 1234.5, 1e-9, "run clock kept (Game resets it on ENDED -> PLAYING; the loop restores it)")
	start_logging()
	for i in 3:
		feed(p, p.mass / SizeRules.EAT_RATIO * 0.9)
	eq(count("run_ended"), 0, "no second victory in endless play")
	gt(float(loop.stats.catches), float(GameLoop.APEX_CATCHES + 2), "catches keep counting")


func test_victory_then_strike_in_the_same_frame() -> void:
	# The winning catch ends the run early in a frame in which a bigger
	# eagle's strike on the player connects later: the run is over, so the
	# strike must not take the player (no death, no life lost, still a
	# victory). The contact order puts the win first: the prey is within
	# reach from the frame's start, the hunter only reaches the player
	# during the frame.
	make_loop()
	var eagle: float = SizeRules.species_data(&"eagle")["mass"]
	var p := make_bird(0.03, Vector3.ZERO, Vector3.FORWARD, true)
	loop.start_run()
	loop.set_protection(p, 0.0)
	p.mass = eagle * 0.97
	loop.step(DT)
	feed(p, eagle * 0.3)
	for i in GameLoop.APEX_CATCHES - 1:
		feed(p, eagle * 0.3)
	eq(loop.stats.apex_catches, GameLoop.APEX_CATCHES - 1, "(setup) one catch from the goal")
	loop.set_protection(p, 0.0)
	var lives := loop.lives
	# The hunter: behind the player, flying at it; last frame just outside
	# its strike reach, now well inside (a flight path, not a teleport:
	# under GameLoop.MAX_BIRD_SPEED).
	var bm := p.mass * 1.6
	var strike := loop.rule.contact_distance(SizeRules.body_radius_for_mass(bm), SizeRules.wingspan_for_mass(bm), false,
			p.get_body_radius(), true)
	var big := make_bird(bm, p.get_body_position() + Vector3(0, 0, strike + 1.2), Vector3.FORWARD)
	big.target = p
	loop.step(DT)
	eq(loop.phase, GameLoop.Phase.PLAYING, "(setup) the hunter has not struck yet")
	big.global_position = p.get_body_position() + Vector3(0, 0, strike * 0.5)
	lt(1.2 + strike * 0.5, GameLoop.MAX_BIRD_SPEED * DT + 1.0, "(setup) the strike is swept, not a teleport")
	# The winning prey, within reach from the start of the frame.
	var c := loop.rule.contact_distance(p.get_body_radius(), p.get_wingspan(), true, SizeRules.body_radius_for_mass(eagle * 0.3))
	var prey := make_bird(eagle * 0.3, p.get_body_position() + p.get_forward() * c * 0.5)
	start_logging()
	loop.step(DT)
	check(not prey.alive, "the winning catch happened")
	check(loop.stats.victory, "victory")
	eq(Game.state, Game.State.ENDED, "the run ended in victory")
	eq(count("player_caught"), 0, "the later strike did not take the player")
	check(p.alive, "the player is alive")
	eq(loop.lives, lives, "no life lost")
	eq(loop.stats.times_caught, 0, "not counted as caught")


func test_reign_time_counts_play_as_the_eagle() -> void:
	# reign_time: seconds of play as the apex species (HUD, summary). It
	# counts PLAYING time at the apex tier only - not below it, not in the
	# CAUGHT beat.
	make_loop()
	var eagle: float = SizeRules.species_data(&"eagle")["mass"]
	var p := make_bird(eagle * 0.9, Vector3.ZERO, Vector3.FORWARD, true)
	loop.start_run()
	p.mass = eagle * 0.9
	loop.set_protection(p, 600.0)
	for i in 40:
		loop.step(0.25)
	near(loop.stats.reign_time, 0.0, 1e-9, "no reign below the apex tier")
	p.mass = eagle * 1.1
	for i in 40:
		loop.step(0.25)
	near(loop.stats.reign_time, 10.0, 0.26, "10 s as the eagle: 10 s of reign")
	near(float(loop.get_run_stats()["apex"]["reign_time"]), loop.stats.reign_time, 1e-9, "get_run_stats().apex.reign_time")
	# Caught: the beat is not reign.
	loop.set_protection(p, 0.0)
	var big := make_bird(p.mass * 1.6, p.get_body_position() + Vector3(0, 0, 0.5), Vector3.FORWARD)
	loop.step(DT)
	eq(loop.phase, GameLoop.Phase.CAUGHT, "(setup) caught")
	big.global_position = Vector3(0, -900, 0)
	var at_catch := loop.stats.reign_time
	for i in int((GameLoop.CAUGHT_BEAT_S - 0.1) / DT):
		loop.step(DT)
	near(loop.stats.reign_time, at_catch, 1e-9, "the caught beat does not count")
	loop.end_run(&"quit")
	near(float(loop.get_last_summary()["apex"]["reign_time"]), at_catch, 1e-9, "the summary carries it")


func test_what_hunts_you_is_what_is_in_the_sky() -> void:
	# get_run_stats().danger_species (the HUD's and the pause screen's "what
	# hunts you"): the ladder species that can eat the player, plus the
	# species of any live bird that can. At the top of the ladder nothing on
	# the ladder can eat an eagle - but the AI sends heavier eagles after a
	# big player, and the screen must not say "nothing hunts you" then.
	make_loop()
	var eagle: float = SizeRules.species_data(&"eagle")["mass"]
	var p := make_bird(0.03, Vector3.ZERO, Vector3.FORWARD, true)
	loop.start_run()
	p.mass = eagle
	loop.step(DT)
	eq((loop.get_run_stats()["danger_species"] as Array).size(), 0, "an empty sky: nothing can eat the eagle")
	var big := make_bird(eagle * 1.4, Vector3(0, 30, -300))
	big.species = &"eagle"
	var hawk := make_bird(1.3, Vector3(0, 30, 300))
	hawk.species = &"hawk"
	var ds: Array = loop.get_run_stats()["danger_species"]
	check(ds.size() == 1 and ds[0] == &"eagle", "a heavier eagle up there: 'eagle' hunts you (got %s)" % [ds])
	big.alive = false
	eq((loop.get_run_stats()["danger_species"] as Array).size(), 0, "a dead one does not count")
	# Small players: the ladder's species, in ladder order, plus live ones.
	p.mass = 0.03
	loop.step(DT)
	ds = loop.get_run_stats()["danger_species"]
	eq(ds[0], &"swallow", "a sparrow is hunted from the swallow up")
	eq(ds[-1], &"eagle", "...to the eagle")
	var sorted := true
	for i in range(1, ds.size()):
		sorted = sorted and SizeRules.species_index(ds[i]) > SizeRules.species_index(ds[i - 1])
	check(sorted, "in ladder order, no duplicates")


func test_summary_content() -> void:
	make_loop()
	var p := make_bird(0.03, Vector3.ZERO, Vector3.FORWARD, true)
	loop.start_run()
	loop.set_protection(p, 0.0)
	start_logging()
	# Script a run: moth (dust later, fine now), wren, 3 bigger meals, a death,
	# then two more meals.
	var eaten: Array[float] = []
	for qm in [0.004, 0.012, 0.03, 0.045, 0.065]:
		var q := feed(p, qm)
		check(not q.alive, "ate %.3f" % qm)
		eaten.append(qm)
	var m_before_death := p.mass
	var peak := p.mass
	var hawk := make_bird(1.3, p.get_body_position() + Vector3(0, 0, 0.3))
	hawk.species = &"hawk"
	loop.step(DT)
	hawk.global_position = Vector3(0, -900, 0)
	run_steps(int(GameLoop.CAUGHT_BEAT_S / DT) + 2, DT)
	var m_after_death := p.mass
	loop.set_protection(p, 0.0)
	for qm in [0.02, 0.03]:
		feed(p, qm)
		eaten.append(qm)
	run_steps(72, DT)
	loop.end_run(&"quit")
	var s: Dictionary = events("run_ended")[0][1]
	var keys := ["reason", "victory", "duration_s", "score", "lives_left", "catches", "worthwhile_catches",
		"catches_by_species", "biggest_prey", "biggest_prey_mass", "mass_gained", "start_mass", "final_mass",
		"final_tier", "final_species", "peak_mass", "peak_tier", "peak_species", "times_caught", "caught_by",
		"best_streak", "escapes", "tier_timeline", "time_in_tier", "npc_catches", "apex", "new_records", "records"]
	for k in keys:
		check(s.has(k), "summary has %s" % k)
	eq(s["reason"], &"quit", "reason")
	check(not s["victory"], "no victory")
	eq(s["catches"], eaten.size(), "catch count")
	eq(s["times_caught"], 1, "one death")
	eq(s["caught_by"], {&"hawk": 1}, "who caught you")
	eq(s["lives_left"], loop.lives, "lives left")
	eq(s["best_streak"], 5, "best streak before the death")
	eq(s["biggest_prey"], &"swallow", "biggest prey species (0.065 kg is swallow-sized)")
	near(s["biggest_prey_mass"], 0.065, 1e-9, "biggest prey mass")
	near(s["start_mass"], GameLoop.START_MASS, 1e-12, "start mass")
	near(s["final_mass"], p.mass, 1e-12, "final mass")
	near(s["peak_mass"], peak, 1e-12, "peak mass (before the death)")
	eq(s["peak_species"], SizeRules.species_for_mass(peak), "peak species")
	eq(s["final_species"], p.species, "final species")
	check(m_after_death < m_before_death, "the death cost mass (%.4f -> %.4f)" % [m_before_death, m_after_death])
	var by: Dictionary = s["catches_by_species"]
	eq(by.get(&"moth", 0), 1, "moths")
	eq(by.get(&"wren", 0), 2, "wren-sized: 0.012, 0.02")
	eq(by.get(&"sparrow", 0), 3, "sparrow-sized: 0.03, 0.045, 0.03")
	eq(by.get(&"swallow", 0), 1, "swallow-sized: 0.065")
	var total := 0
	for k in by:
		total += int(by[k])
	eq(total, s["catches"], "per-species counts add up")
	# Timeline: starts as a sparrow at t=0, strictly ordered.
	var tl: Array = s["tier_timeline"]
	eq(tl[0]["species"], &"sparrow", "timeline starts as sparrow")
	near(tl[0]["at"], 0.0, 1e-9, "at t=0")
	var ok := true
	for i in range(1, tl.size()):
		if tl[i]["tier"] <= tl[i - 1]["tier"] or tl[i]["at"] < tl[i - 1]["at"]:
			ok = false
	check(ok, "timeline ordered by tier and time")
	eq(tl[-1]["tier"], s["peak_tier"], "timeline ends at the peak tier")
	var tsum := 0.0
	for x in s["time_in_tier"]:
		tsum += float(x)
	near(tsum, s["duration_s"], 1e-6, "time in tiers adds up to the run length")
	# Duration excludes the caught beat (only PLAYING time counts).
	var expected_play := 5 * (DT + GameLoop.SWALLOW_MAX_S + 0.05) + DT + 2 * (DT + GameLoop.SWALLOW_MAX_S + 0.05) + 72 * DT
	near(s["duration_s"], expected_play, 0.05, "duration counts play time only")
	var want_score := roundi(peak * 1000.0) + RunStats.POINTS_PER_WORTHWHILE_CATCH * int(s["worthwhile_catches"])
	eq(s["score"], want_score, "score = peak grams + 25 per worthwhile catch")
	eq(s["apex"]["needed"], GameLoop.APEX_CATCHES, "apex goal size in summary")
	check(not s["apex"]["reached"], "apex not reached")
	metric("summary_example", JSON.stringify(s, "", false))


func test_score_formula_with_victory() -> void:
	var st := RunStats.new()
	st.reset(0.03)
	st.on_player_mass(4.8)
	st.worthwhile_catches = 20
	eq(st.score(), 4800 + 25 * 20, "no victory")
	st.victory = true
	st.run_time = 1800.0
	eq(st.score(), 4800 + 500 + RunStats.VICTORY_BONUS + 1500, "victory + half the time bonus at 30 min")
	st.run_time = 4000.0
	eq(st.score(), 4800 + 500 + RunStats.VICTORY_BONUS, "no time bonus after an hour")
