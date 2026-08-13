class_name ProgressionTests
extends RefCounted

## Pins down the shape of a run: the ladder you climb, the sky that gets worse as
## you climb it, what a catch and a death are worth, and — the part that cannot
## be checked by reading the code — whether the resulting curve is a game.
##
## The last of those is why [SessionSim] exists. The balance questions this area
## has to answer are "how long does it take to reach the top", "does difficulty
## actually rise", and "is being caught a setback or the end", and none of them
## can be answered by inspecting a constant. They are answered here by simulating
## a few hundred whole runs at different skill levels and asserting on the
## distribution, with the simulation itself calibrated against [SessionProbe],
## which flies the real game.

## Runs per skill level in the curve tests. Enough that the medians are stable
## across seeds, few enough that the suite stays under a second and a half.
const RUNS: int = 30
const NOVICE: float = 0.25
const COMPETENT: float = 0.75
const EXPERT: float = 0.90

## What [SessionProbe] measures in the real game for an autopilot that flies a
## solved intercept and breaks off when something commits to it. These two
## numbers are the calibration anchors for the whole simulation; if a change to
## the spawn bands or the catch rules moves the game away from them, the model
## stops describing the game and the curve tests stop meaning anything.
## Measured over 25 minutes of autopiloted flight in the real world (15 catches,
## 6 deaths, 121 chases at 15 % conversion).
const MEASURED_CATCH_RATE: float = 0.60
const MEASURED_DEATH_RATE: float = 0.24


static func run(t: TestCase) -> void:
	_test_the_ladder_is_a_ladder(t)
	_test_promotions_change_what_you_look_like(t)
	_test_rank_progress_fills_evenly(t)
	_test_the_sky_escalates_as_you_climb(t)
	_test_something_to_hunt_and_something_to_fear(t)
	_test_prey_can_actually_be_caught(t)
	_test_streaks_pay_and_are_lost(t)
	_test_a_run_begins(t)
	_test_a_run_can_be_won(t)
	_test_a_run_can_be_lost(t)
	_test_being_caught_costs_about_one_catch(t)
	_test_a_session_survives_hostile_input(t)
	_test_the_simulation_still_describes_the_game(t)
	_test_skill_is_what_decides_a_run(t)
	_test_a_run_is_long_enough_to_matter_and_short_enough_to_finish(t)
	_test_the_climb_gets_harder(t)
	_test_a_bad_run_still_goes_somewhere(t)
	_test_the_curve_is_reproducible(t)


# --- the ladder --------------------------------------------------------------

static func _test_the_ladder_is_a_ladder(t: TestCase) -> void:
	t.begin("the rank ladder is a ladder")
	var names: Array[String] = []
	var previous: float = -1.0
	for i in Progression.RANKS.size():
		var size: float = Progression.size_of_rank(i)
		t.greater(size, previous, "rank %d starts above rank %d" % [i, i - 1])
		previous = size
		var rank_name: String = Progression.name_of_rank(i)
		t.ok(not rank_name.is_empty(), "rank %d has a name" % i)
		t.ok(not names.has(rank_name), "%s appears once" % rank_name)
		names.append(rank_name)
		t.ok(
			Progression.rank_index(size) == i,
			"landing exactly on rank %d's threshold is rank %d" % [i, i]
		)
		t.ok(
			Progression.rank_index(size - 0.0001) == maxi(i - 1, 0),
			"a hair below rank %d is the rank below" % i
		)

	t.ok(Progression.size_of_rank(0) == GameRules.MIN_SIZE, "the bottom rank is the minimum size")
	t.ok(
		Progression.size_of_rank(Progression.RANKS.size() - 1) == Progression.APEX_SIZE,
		"the top rank is the win condition"
	)
	t.ok(Progression.rank_index(0.0) == 0, "nothing smaller than the ladder falls off it")
	t.ok(Progression.rank_index(NAN) == 0, "a NaN size is the bottom rank, not a crash")
	t.ok(Progression.rank_index(1e9) == Progression.RANKS.size() - 1, "and nothing above the top")

	var start: int = Progression.rank_index(Progression.START_SIZE)
	t.greater(float(start), 0.0, "a run starts above the bottom rank, so there is room to fall")
	t.less(
		float(start), float(Progression.RANKS.size() - 1),
		"and below the top, so there is room to climb"
	)
	t.ok(
		Progression.is_apex(Progression.APEX_SIZE) and not Progression.is_apex(
			Progression.APEX_SIZE - 0.01
		),
		"the apex is exactly the top rank's threshold"
	)
	t.ok(
		not Progression.threat_is_possible(GameRules.MAX_SIZE),
		"nothing can eat a bird at the size cap — which is why the run ends below it"
	)
	t.ok(
		Progression.threat_is_possible(Progression.APEX_SIZE),
		"something can still eat you at the moment you win"
	)


static func _test_promotions_change_what_you_look_like(t: TestCase) -> void:
	t.begin("a promotion changes your silhouette")
	# Ranks 1..3 are exactly the size-class boundaries in [BirdMesh], so crossing
	# one rebuilds the player as a different bird. This is the whole reason the
	# thresholds are these numbers and not rounder ones.
	for i in range(1, 4):
		var size: float = Progression.size_of_rank(i)
		t.near(
			size, BirdMesh.CLASS_BOUNDS[i - 1], 0.0001,
			"rank %s is exactly a bird size class" % Progression.name_of_rank(i)
		)
		var below: BirdMesh.Species = BirdMesh.species_for_size(size - 0.02)
		var above: BirdMesh.Species = BirdMesh.species_for_size(size + 0.2)
		t.ok(below != above, "%s looks like a different bird" % Progression.name_of_rank(i))

	# The last promotion is honestly not one of those: SOVEREIGN is a size inside
	# the seabird class, because putting it on the next class boundary (4.5) would
	# have added ten minutes of flapping to every run. Asserted so that the
	# exception stays deliberate and documented rather than drifting in.
	t.ok(
		BirdMesh.species_for_size(Progression.APEX_SIZE)
			== BirdMesh.species_for_size(Progression.size_of_rank(Progression.RANKS.size() - 2) + 0.2),
		"the final promotion is a size, not a new silhouette (deliberate: see APEX_SIZE)"
	)


static func _test_rank_progress_fills_evenly(t: TestCase) -> void:
	t.begin("the rank bar fills with what a catch actually adds")
	for i in Progression.RANKS.size() - 1:
		var low: float = Progression.size_of_rank(i)
		var high: float = Progression.size_of_rank(i + 1)
		t.near(Progression.rank_progress(low), 0.0, 0.001, "a fresh rank starts empty")
		t.near(
			Progression.rank_progress(high - 0.0001), 1.0, 0.01,
			"and is full a hair before the next one"
		)
		var previous: float = -1.0
		for step in 12:
			var size: float = lerpf(low, high - 0.0001, float(step) / 11.0)
			var progress: float = Progression.rank_progress(size)
			t.in_range(progress, 0.0, 1.0, "progress stays a fraction")
			t.greater(progress, previous, "progress only ever moves forward within a rank")
			previous = progress
		# Mass, not length: half way along the bar is half the mass, which is
		# what a catch adds. A length-based bar would crawl then leap.
		var mid_mass: float = 0.5 * (GameRules.mass_of(low) + GameRules.mass_of(high))
		t.near(
			Progression.rank_progress(GameRules.size_of_mass(mid_mass)), 0.5, 0.01,
			"the middle of the bar is half the mass of the rank"
		)
	t.near(Progression.rank_progress(Progression.APEX_SIZE), 1.0, 0.001, "the top rank is full")
	t.near(Progression.rank_progress(NAN), 0.0, 0.001, "a NaN size does not corrupt the bar")


# --- the sky -----------------------------------------------------------------

static func _test_the_sky_escalates_as_you_climb(t: TestCase) -> void:
	t.begin("the sky gets worse as you climb")
	var previous_prey: float = 2.0
	var previous_predator: float = -1.0
	for step in 14:
		var size: float = lerpf(Progression.START_SIZE, Progression.APEX_SIZE, float(step) / 13.0)
		var mix: Vector3 = Progression.threat_mix(size)
		t.near(mix.x + mix.y + mix.z, 1.0, 0.0001, "the mix is a whole flock")
		t.greater(mix.x, 0.2, "there is always a real share of prey")
		t.greater(mix.z, 0.05, "and always a real share of predators")
		t.less(mix.x, previous_prey, "prey gets rarer the bigger you are")
		t.greater(mix.z, previous_predator, "predators get commoner")
		previous_prey = mix.x
		previous_predator = mix.z

	t.ok(
		Progression.climb_fraction(Progression.START_SIZE * 0.5) == 0.0,
		"falling below the starting size does not make the sky harder than day one"
	)
	t.near(Progression.climb_fraction(Progression.APEX_SIZE), 1.0, 0.0001, "the apex is the top")
	t.near(Progression.climb_fraction(NAN), 0.0, 0.0001, "a NaN size is survivable")

	# Predators get relatively bigger as well as commoner, which is the second,
	# separate lever: an apex-adjacent player is not merely meeting more of them.
	var early: float = Progression.size_for_role(
		Progression.START_SIZE, Progression.Role.PREDATOR, 1.0
	) / Progression.START_SIZE
	var late: float = Progression.size_for_role(
		Progression.APEX_SIZE, Progression.Role.PREDATOR, 1.0
	) / Progression.APEX_SIZE
	t.greater(late, early, "the worst thing in the sky is relatively bigger by the end")


static func _test_something_to_hunt_and_something_to_fear(t: TestCase) -> void:
	t.begin("there is always something to hunt and something to fear")
	for size: float in [GameRules.MIN_SIZE, 0.5, 1.0, 1.6, 2.4, 3.2, 4.5, 6.0, 8.0]:
		var prey: int = 0
		var predators: int = 0
		var peers: int = 0
		for sample in 200:
			var roll: float = float(sample) / 199.0
			var role: Progression.Role = Progression.role_for_roll(size, roll)
			var drawn: float = Progression.size_for_role(size, role, fmod(roll * 7.3, 1.0))
			t.finite(drawn, "a spawn size is a number")
			t.in_range(drawn, GameRules.MIN_SIZE, GameRules.MAX_SIZE, "and inside the size limits")
			match role:
				Progression.Role.PREY:
					prey += 1
					t.ok(
						GameRules.can_catch(size, drawn) or drawn <= GameRules.MIN_SIZE,
						"a bird spawned as prey for %.2f can be caught by it (%.2f)" % [size, drawn]
					)
				Progression.Role.PREDATOR:
					predators += 1
					t.ok(
						GameRules.can_catch(drawn, size) or not Progression.threat_is_possible(size),
						"a bird spawned as a predator of %.2f can catch it (%.2f)" % [size, drawn]
					)
				Progression.Role.PEER:
					peers += 1
					t.ok(
						not GameRules.can_catch(size, drawn)
							and not GameRules.can_catch(drawn, size),
						"a peer of %.2f is a standoff both ways (%.2f)" % [size, drawn]
					)
		t.greater(float(prey), 40.0, "at size %.2f at least a fifth of the sky is edible" % size)
		if Progression.threat_is_possible(size):
			t.greater(float(predators), 10.0, "and something at size %.2f can eat you" % size)
		t.greater(float(peers), 10.0, "and some of it is neither, so the sky is not a menu")


static func _test_prey_can_actually_be_caught(t: TestCase) -> void:
	t.begin("prey is drawn small enough to be catchable in practice")
	# Not a rules question, a physics one. Every bird flies the same FlightModel,
	# whose trim speed barely moves with size, so a bird at 0.86 of the player's
	# size runs away at 98 % of the player's speed and is never caught: measured
	# at 4 % of 77 chases, against 20 % at 0.80. The legal limit (1/CATCH_MARGIN,
	# about 0.89) is therefore not the useful limit.
	const CATCHABLE_CEILING: float = 0.84
	for band: Vector2 in [Progression.PREY_BAND_START, Progression.PREY_BAND_APEX]:
		t.less(band.y, CATCHABLE_CEILING, "the prey band stays under the measured ceiling")
		t.less(band.y, 1.0 / GameRules.CATCH_MARGIN, "and under the legal one")
		t.greater(band.x, 0.3, "but prey is worth eating")
		t.less(band.x, band.y, "and the band is a band")
	# A big bird's minimum meal must still be worth swallowing: at the apex, the
	# smallest prey has to move the mass needle by something.
	var smallest: float = Progression.size_for_role(
		Progression.APEX_SIZE, Progression.Role.PREY, 0.0
	)
	t.greater(
		GameRules.grown_size(Progression.APEX_SIZE, smallest) - Progression.APEX_SIZE, 0.02,
		"even the smallest late-game meal is worth taking"
	)


static func _test_streaks_pay_and_are_lost(t: TestCase) -> void:
	t.begin("streaks pay, and being caught takes them")
	t.near(Progression.streak_multiplier(0), 1.0, 0.0001, "no streak is no bonus")
	t.near(Progression.streak_multiplier(1), 1.0, 0.0001, "one catch is no bonus yet")
	var previous: float = 1.0
	for streak in range(2, 30):
		var multiplier: float = Progression.streak_multiplier(streak)
		t.ok(multiplier >= previous, "a longer streak is never worth less")
		t.in_range(multiplier, 1.0, Progression.MAX_STREAK_MULTIPLIER, "and is capped")
		previous = multiplier
	t.near(
		Progression.streak_multiplier(1000), Progression.MAX_STREAK_MULTIPLIER, 0.0001,
		"the cap is reached"
	)
	t.greater(
		float(Progression.score_for_catch(1.0, 5)), float(Progression.score_for_catch(1.0, 1)),
		"the same bird is worth more on a streak"
	)
	t.greater(
		float(Progression.score_for_catch(2.0, 1)), float(Progression.score_for_catch(1.0, 1)),
		"and a bigger bird is worth more than a smaller one"
	)


# --- the run ------------------------------------------------------------------

static func _test_a_run_begins(t: TestCase) -> void:
	t.begin("a run begins")
	var session := GameSession.new()
	session.record_catch(0.5, 1.4)
	session.record_death(2.0)
	session.begin(Progression.START_SIZE)
	t.ok(session.state == GameSession.State.FLYING, "a fresh run is being flown")
	t.ok(session.lives == Progression.LIVES, "with all its lives")
	t.ok(session.score == 0 and session.catches == 0 and session.deaths == 0, "and a clean sheet")
	t.ok(session.streak == 0 and session.best_streak == 0, "and no streak")
	t.near(session.elapsed, 0.0, 0.0001, "and no time on the clock")
	t.ok(session.rank == Progression.rank_index(Progression.START_SIZE), "at the starting rank")
	t.near(session.rank_times[session.rank], 0.0, 0.0001, "which it reached at zero seconds")
	for i in session.rank_times.size():
		if i != session.rank:
			t.less(session.rank_times[i], 0.0, "and no other rank has been reached")
	t.ok(not session.is_over(), "and it is not over")


static func _test_a_run_can_be_won(t: TestCase) -> void:
	t.begin("a run can be won")
	var session := GameSession.new()
	session.begin(Progression.START_SIZE)
	var promotions: Array[int] = []
	session.rank_changed.connect(
		func(index: int, _name: String, promoted: bool) -> void:
			if promoted:
				promotions.append(index)
	)
	var endings: Array[bool] = []
	session.ended.connect(func(won: bool) -> void: endings.append(won))

	var size: float = Progression.START_SIZE
	var catches: int = 0
	while not session.is_over() and catches < 200:
		session.tick(20.0, size)
		var prey: float = size * 0.7
		size = GameRules.grown_size(size, prey)
		var gained: int = session.record_catch(prey, size)
		catches += 1
		t.greater(float(gained), 0.0, "every catch is worth something")

	t.ok(session.state == GameSession.State.WON, "eating enough wins the run")
	t.ok(endings.size() == 1 and endings[0], "and says so exactly once")
	t.ok(session.lives == Progression.LIVES, "without having lost a life")
	t.in_range(
		float(catches), 8.0, 30.0,
		"the climb is between eight and thirty catches (it is %d)" % catches
	)
	t.ok(promotions.size() >= 2, "with at least two promotions on the way")
	for i in range(1, promotions.size()):
		t.greater(float(promotions[i]), float(promotions[i - 1]), "promotions arrive in order")
	t.greater(session.rank_times[session.rank], 0.0, "the top rank has a time against it")

	var frozen: int = session.score
	t.ok(session.record_catch(0.5, size) == 0, "a finished run does not keep scoring")
	t.ok(session.score == frozen, "and its score is final")
	t.ok(not session.record_death(9.0), "and cannot then be lost")
	t.ok(session.state == GameSession.State.WON, "the ending stays what it was")
	t.ok(session.outcome_title().length() > 0, "and has something to put on the summary")


static func _test_a_run_can_be_lost(t: TestCase) -> void:
	t.begin("a run can be lost")
	var session := GameSession.new()
	session.begin(Progression.START_SIZE)
	var lives_seen: Array[int] = []
	session.lives_changed.connect(func(lives: int) -> void: lives_seen.append(lives))

	var size: float = Progression.START_SIZE
	for i in range(Progression.LIVES - 1):
		session.record_catch(size * 0.6, size)
		t.greater(float(session.streak), 0.0, "a catch builds a streak")
		var over: bool = session.record_death(size * 1.5)
		size = GameRules.size_after_being_caught(size)
		session.tick(30.0, size)
		t.ok(not over, "life %d is not the last one" % (i + 1))
		t.ok(session.streak == 0, "being caught takes the streak")
		t.ok(session.lives == Progression.LIVES - i - 1, "and a life")
		t.ok(not session.is_over(), "and the run goes on")

	t.ok(session.record_death(size * 1.5), "the last life ends the run")
	t.ok(session.state == GameSession.State.LOST, "as a loss")
	t.ok(session.lives == 0, "with no lives left")
	t.ok(not session.record_death(9.0), "and further deaths are not counted")
	t.ok(session.lives == 0, "lives never go negative")
	t.ok(session.deaths == Progression.LIVES, "the run remembers every death")
	t.ok(lives_seen.size() == Progression.LIVES, "and announced each one")
	t.greater(float(session.best_streak), 0.0, "the best streak of the run is remembered")


static func _test_being_caught_costs_about_one_catch(t: TestCase) -> void:
	t.begin("being caught costs about what a catch gains")
	# The single balance invariant this whole area rests on. A run is a race
	# between growth per catch and loss per death; [SessionProbe] measures a
	# competent player catching roughly three or four birds per death, so if a
	# death costs much more than about two catches the loop runs backwards no
	# matter how well it is flown, and if it costs much less there are no stakes.
	for size: float in [0.8, 1.0, 1.6, 2.4, 3.2]:
		var prey: float = size * 0.68
		var gain: float = log(GameRules.grown_size(size, prey) / size)
		var loss: float = log(size / GameRules.size_after_being_caught(size))
		t.greater(gain, 0.0, "a catch at size %.1f grows you" % size)
		t.greater(loss, 0.0, "and being caught at size %.1f costs you" % size)
		t.greater(loss / gain, 0.5, "a death is worth more than half a catch (%.1f)" % size)
		t.less(loss / gain, 2.5, "and less than two and a half of them (%.1f)" % size)


static func _test_a_session_survives_hostile_input(t: TestCase) -> void:
	t.begin("a run survives hostile input")
	var session := GameSession.new()
	session.begin(NAN)
	t.ok(session.state == GameSession.State.FLYING, "a NaN starting size still starts a run")
	for delta: float in [NAN, INF, -1.0, 0.0, 1e9]:
		session.tick(delta, NAN)
		t.finite(session.elapsed, "the clock stays finite whatever it is fed")
	t.less(session.elapsed, 10.0, "and a garbage frame cannot fast-forward a run")
	session.tick(1.0, 1.0)
	t.near(session.elapsed, 1.0, 0.5, "a real frame still advances it")
	session.record_catch(NAN, NAN)
	t.finite(float(session.score), "a NaN catch does not poison the score")
	t.ok(session.catches == 1, "but it is still a catch")
	session.record_death(NAN)
	t.ok(session.lives == Progression.LIVES - 1, "and a NaN predator still takes a life")
	t.ok(GameSession.clock(NAN) == "--:--", "an unknown time prints as unknown")
	t.ok(GameSession.clock(-5.0) == "--:--", "so does a negative one")
	t.ok(GameSession.clock(125.0) == "2:05", "and a real one prints as minutes and seconds")
	for roll: float in [NAN, INF, -1.0, 2.0]:
		t.finite(
			Progression.spawn_size(1.0, roll, roll), "a spawn roll of %s is survivable" % str(roll)
		)
		t.finite(Progression.size_for_role(NAN, Progression.Role.PREY, roll), "and so is a NaN size")


# --- the curve, by simulation -------------------------------------------------

static func _test_the_simulation_still_describes_the_game(t: TestCase) -> void:
	t.begin("the simulation still describes the game it is simulating")
	var measured: Dictionary = SessionSim.sweep(COMPETENT, RUNS, 4242)
	var catch_rate: float = measured["catch_rate_median"]
	var death_rate: float = measured["death_rate_median"]
	# Within half again of what SessionProbe measured flying the real thing. This
	# is deliberately a loose bound and deliberately a test: it is the alarm that
	# goes off when someone retunes the spawn bands or the catch rules and the
	# model quietly stops matching the game, taking every curve number below with
	# it. If it fires, re-run: godot --headless --xr-mode off --fixed-fps 90 --
	#   --hunt=1200 --hunt_evade=1 --hunt_endless=1
	t.in_range(
		catch_rate, MEASURED_CATCH_RATE / 1.5, MEASURED_CATCH_RATE * 1.5,
		"simulated catch rate still matches the measured game"
	)
	t.in_range(
		death_rate, MEASURED_DEATH_RATE / 2.0, MEASURED_DEATH_RATE * 2.0,
		"simulated death rate still matches the measured game"
	)


static func _test_skill_is_what_decides_a_run(t: TestCase) -> void:
	t.begin("skill is what decides a run")
	var novice: Dictionary = SessionSim.sweep(NOVICE, RUNS, 11)
	var competent: Dictionary = SessionSim.sweep(COMPETENT, RUNS, 11)
	var expert: Dictionary = SessionSim.sweep(EXPERT, RUNS, 11)

	t.greater(expert["win_rate"], competent["win_rate"], "a better player wins more often")
	t.greater(competent["win_rate"], novice["win_rate"] - 0.001, "and a worse one wins less")
	t.greater(expert["win_rate"], 0.6, "the game is winnable by someone who is good at it")
	t.less(novice["win_rate"], 0.15, "and not by someone on their first go")
	t.greater(expert["catch_rate_median"], competent["catch_rate_median"], "skill catches more")
	t.greater(competent["catch_rate_median"], novice["catch_rate_median"], "at every level")
	t.less(expert["death_rate_median"], competent["death_rate_median"], "and dies less")
	t.less(competent["death_rate_median"], novice["death_rate_median"], "at every level")
	t.greater(
		expert["deaths_mean"], 0.05,
		"but nobody is untouchable — a run with no stakes is not this game"
	)


static func _test_a_run_is_long_enough_to_matter_and_short_enough_to_finish(t: TestCase) -> void:
	t.begin("a run is long enough to matter and short enough to finish")
	var expert: Dictionary = SessionSim.sweep(EXPERT, RUNS, 909)
	var median: float = expert["win_time_median"]
	t.greater(median, 5.0 * 60.0, "winning takes more than five minutes even for an expert")
	t.less(median, 20.0 * 60.0, "and less than twenty — this is a game you play standing up")
	t.less(expert["win_time_p90"], 32.0 * 60.0, "and even a slow winning run ends")
	t.greater(expert["win_time_p10"], 4.0 * 60.0, "and even a fast one is a session, not a sprint")
	var competent: Dictionary = SessionSim.sweep(COMPETENT, RUNS, 909)
	t.greater(
		competent["elapsed_median"], 6.0 * 60.0,
		"a competent player's run lasts long enough to be a run"
	)
	t.greater(competent["catches_median"], 6.0, "and contains a real number of catches")


static func _test_the_climb_gets_harder(t: TestCase) -> void:
	t.begin("the climb gets harder the higher you get")
	var expert: Dictionary = SessionSim.sweep(EXPERT, RUNS, 77)
	var times: PackedFloat32Array = expert["rank_time_median"]
	var reached: PackedFloat32Array = expert["rank_reached"]
	var start: int = Progression.rank_index(Progression.START_SIZE)

	var previous_time: float = 0.0
	var previous_gap: float = 0.0
	var last: int = Progression.RANKS.size() - 1
	for i in range(start + 1, Progression.RANKS.size()):
		var rank_name: String = Progression.name_of_rank(i)
		t.greater(reached[i], 0.5, "most good runs reach %s" % rank_name)
		var arrival: float = times[i]
		t.greater(arrival, previous_time, "%s comes after the rank below it" % rank_name)
		var gap: float = arrival - previous_time
		t.greater(gap, 45.0, "%s is a climb, not a formality" % rank_name)
		if previous_gap > 0.0 and i < last:
			# Every rank but the last is a bigger climb than the one below it: the
			# mass a rank costs goes up faster than the catches get bigger. The
			# last one is exempt on purpose — SOVEREIGN sits closer above CORSAIR
			# than CORSAIR does above RAIDER, so the run ends with a sprint you
			# can see coming rather than with the longest grind of the session.
			t.greater(gap, previous_gap, "%s is a longer climb than the rank below" % rank_name)
		previous_time = arrival
		previous_gap = gap
	t.greater(previous_time, 0.0, "the top rank is reached at all")


static func _test_a_bad_run_still_goes_somewhere(t: TestCase) -> void:
	t.begin("a bad run still goes somewhere")
	# A first session that produces nothing at all — no promotion, no catches — is
	# the one outcome that guarantees the headset comes off. A novice should lose,
	# but they should lose having eaten something and having been something.
	var novice: Dictionary = SessionSim.sweep(NOVICE, RUNS, 5150)
	t.greater(novice["catches_median"], 1.0, "even a novice eats")
	t.greater(novice["elapsed_median"], 4.0 * 60.0, "and stays airborne for minutes, not seconds")
	t.greater(novice["score_median"], 0.0, "and scores")
	var promoted: PackedFloat32Array = novice["rank_reached"]
	var start: int = Progression.rank_index(Progression.START_SIZE)
	t.greater(
		promoted[start + 1], 0.15,
		"and a fair share of first runs earn a promotion"
	)


static func _test_the_curve_is_reproducible(t: TestCase) -> void:
	t.begin("the curve is reproducible")
	var first: Dictionary = SessionSim.new().run(31337, COMPETENT)
	var second: Dictionary = SessionSim.new().run(31337, COMPETENT)
	t.ok(first["catches"] == second["catches"], "the same seed catches the same birds")
	t.ok(first["deaths"] == second["deaths"], "and dies the same deaths")
	t.near(float(first["elapsed"]), float(second["elapsed"]), 0.001, "in the same time")
	t.ok(first["won"] == second["won"], "and ends the same way")
	var different: Dictionary = SessionSim.new().run(31338, COMPETENT)
	t.ok(
		different["catches"] != first["catches"] or different["elapsed"] != first["elapsed"],
		"and a different seed is a different run"
	)
	t.finite(float(first["final_size"]), "a simulated run leaves a finite bird")
	t.in_range(
		float(first["final_size"]), GameRules.MIN_SIZE, GameRules.MAX_SIZE,
		"of a legal size"
	)
