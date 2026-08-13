class_name GameRulesTests
extends RefCounted

## Pins down the growth curve. The feel of an agar.io progression lives entirely
## in these numbers: how transformative the first catch is, how long the last
## one takes, and whether being caught is a setback or a reason to quit.


static func run(t: TestCase) -> void:
	_test_catching_requires_a_real_size_advantage(t)
	_test_growth_follows_mass_not_size(t)
	_test_early_catches_matter_more_than_late_ones(t)
	_test_growth_is_bounded_and_monotonic(t)
	_test_being_caught_is_a_setback_not_a_wipe(t)
	_test_catch_distance_scales_with_both_birds(t)
	_test_reach_at_speed_is_still_not_a_vacuum(t)
	_test_a_strike_has_to_be_aimed(t)
	_test_a_bird_that_is_not_flying_is_not_hunting(t)
	_test_the_strike_test_survives_hostile_input(t)


static func _test_catching_requires_a_real_size_advantage(t: TestCase) -> void:
	t.begin("catching requires a real size advantage")
	t.ok(GameRules.can_catch(2.0, 1.0), "a much bigger bird catches a smaller one")
	t.ok(not GameRules.can_catch(1.0, 2.0), "a smaller bird cannot catch a bigger one")
	t.ok(not GameRules.can_catch(1.0, 1.0), "equals cannot eat each other")
	t.ok(not GameRules.can_catch(1.05, 1.0), "a hair's difference is a standoff, not a meal")
	t.ok(GameRules.can_catch(1.30, 1.0), "a clear advantage does win")
	# The rule must be strictly one-way, or two birds could eat each other.
	for a: float in [0.5, 0.9, 1.0, 1.4, 3.0]:
		for b: float in [0.5, 0.9, 1.0, 1.4, 3.0]:
			t.ok(
				not (GameRules.can_catch(a, b) and GameRules.can_catch(b, a)),
				"sizes %.1f and %.1f cannot both eat each other" % [a, b]
			)


static func _test_growth_follows_mass_not_size(t: TestCase) -> void:
	t.begin("growth adds mass, not length")
	# Eating your own mass should scale length by the cube root of 2, less
	# digestion losses — not double it.
	var grown: float = GameRules.grown_size(1.0, 1.0)
	var ideal: float = pow(1.0 + GameRules.DIGESTION, 1.0 / 3.0)
	t.near(grown, ideal, 0.01, "eating an equal bird grows length by the cube root")
	t.less(grown, 1.35, "one catch does not make you a giant")


static func _test_early_catches_matter_more_than_late_ones(t: TestCase) -> void:
	t.begin("early catches matter more than late ones")
	var small_gain: float = GameRules.grown_size(1.0, 0.8) - 1.0
	var large_gain: float = GameRules.grown_size(4.0, 0.8) - 4.0
	t.greater(small_gain, large_gain * 4.0, "the same prey barely moves a big bird")
	t.greater(small_gain, 0.05, "but it is a real gain when you are small")


static func _test_growth_is_bounded_and_monotonic(t: TestCase) -> void:
	t.begin("growth is bounded and always forward")
	var size: float = GameRules.MIN_SIZE
	var previous: float = 0.0
	for i in 400:
		var next: float = GameRules.grown_size(size, size * 0.7)
		t.ok(next >= size, "catching never shrinks you (step %d)" % i)
		size = next
	t.near(size, GameRules.MAX_SIZE, 0.001, "400 catches reaches, but never exceeds, the cap")
	t.finite(size, "size stayed finite across a long session")


static func _test_being_caught_is_a_setback_not_a_wipe(t: TestCase) -> void:
	t.begin("being caught is a setback, not a wipe")
	var after: float = GameRules.size_after_being_caught(3.0)
	t.less(after, 3.0, "you lose something real")
	t.greater(after, GameRules.MIN_SIZE, "but you are not sent back to the very start")
	t.greater(after, 1.5, "a big bird stays respectable after one bad encounter")
	t.greater(
		GameRules.size_after_being_caught(1.0), GameRules.MIN_SIZE * 0.99,
		"even a small bird survives being caught"
	)


static func _test_catch_distance_scales_with_both_birds(t: TestCase) -> void:
	t.begin("catch distance scales with both birds")
	var small: float = GameRules.catch_distance(1.0, 0.5)
	var large: float = GameRules.catch_distance(5.0, 0.5)
	t.greater(large, small, "a bigger hunter has a longer reach")
	t.greater(small, 1.0, "even small birds have a forgiving catch radius at speed")
	t.less(large, 12.0, "reach never becomes an auto-win vacuum")


## The bound above is measured at a standstill, which is the one closing speed
## nobody ever hunts at. The reach a size-5 hunter really gets in a 60 m/s stoop
## is 19.8 m, not 10.8, and until this test existed nothing looked at it.
static func _test_reach_at_speed_is_still_not_a_vacuum(t: TestCase) -> void:
	t.begin("reach at speed is still not a vacuum")
	var previous: float = 0.0
	for closing: float in [0.0, 5.0, 12.0, 20.0, 30.0, 45.0, 60.0]:
		var reach: float = GameRules.catch_distance(5.0, 0.5, closing)
		t.greater(reach, previous, "a faster pass reaches further (at %.0f m/s)" % closing)
		previous = reach
	t.near(
		GameRules.catch_distance(5.0, 0.5, 200.0), GameRules.catch_distance(5.0, 0.5, 60.0),
		0.001, "and stops growing past the fastest closure the game affords"
	)

	# The real bound, in the units the player experiences it: the biggest bird in
	# the game, in the fastest stoop it can fly, cannot reach further than its own
	# wings are wide. That is what stops a generous window being a vacuum.
	var fastest: float = GameRules.catch_distance(GameRules.MAX_SIZE, 0.5, 60.0)
	var span: float = 5.0 * BirdMesh.wingspan(BirdMesh.species_for_size(5.0))
	t.less(GameRules.catch_distance(5.0, 0.5, 60.0), span, "a size-5 stoop reaches one wingspan")
	t.less(fastest, 25.0, "and nothing in the game reaches further than 25 m, ever")

	# Why the speed term exists: what has to stay roughly constant is the time a
	# strike spends inside the window, not its radius. It does not manage
	# constant — dwell still falls from 1.05 s to 0.33 s between 12 and 60 m/s —
	# but it is nearly twice what a fixed radius would leave at the top end.
	var dwell_fast: float = GameRules.catch_distance(5.0, 0.5, 60.0) / 60.0
	var dwell_fixed: float = GameRules.catch_distance(5.0, 0.5, 0.0) / 60.0
	t.greater(dwell_fast, dwell_fixed * 1.5, "a fast pass gets real dwell, not a lottery tick")
	t.in_range(dwell_fast, 0.25, 0.60, "but a stoop is still over in a third of a second")

	t.near(
		GameRules.catch_distance(1.0, 0.5, NAN), GameRules.catch_distance(1.0, 0.5, 0.0),
		0.001, "an unknown closing speed is treated as none"
	)
	t.near(
		GameRules.catch_distance(1.0, 0.5, -40.0), GameRules.catch_distance(1.0, 0.5, 0.0),
		0.001, "and so is a nonsensical one"
	)


## The cone. Nothing asserted on it before, which is how it could be set to -1.0
## — catch anything, in any direction, including birds behind you — with every
## gate still green.
static func _test_a_strike_has_to_be_aimed(t: TestCase) -> void:
	t.begin("a strike has to be aimed")
	var speed: float = 20.0
	var velocity := Vector3(0.0, 0.0, -speed)
	var still := Vector3.ZERO

	# 5 m off the nose is comfortably inside the reach of a 1.0 on a 0.5 at this
	# closing speed (7.8 m), so every result below is the cone talking.
	t.ok(
		GameRules.within_strike(
			Vector3.ZERO, velocity, 1.0, Vector3(0.0, 0.0, -5.0), still, 0.5
		),
		"a bird straight ahead is caught"
	)
	t.ok(
		not GameRules.within_strike(
			Vector3.ZERO, velocity, 1.0, Vector3(0.0, 0.0, 5.0), still, 0.5
		),
		"a bird directly behind is not"
	)
	t.ok(
		not GameRules.within_strike(
			Vector3.ZERO, velocity, 1.0, Vector3(5.0, 0.0, 0.0), still, 0.5
		),
		"nor is one you slide past at ninety degrees"
	)
	t.ok(
		not GameRules.within_strike(
			Vector3.ZERO, velocity, 1.0, Vector3(0.0, 5.0, 0.0), still, 0.5
		),
		"nor one directly above you"
	)

	# The boundary itself: acos(0.72) is 43.9 degrees.
	var limit: float = rad_to_deg(acos(GameRules.STRIKE_COSINE))
	t.in_range(limit, 40.0, 48.0, "the cone is about forty-four degrees off the nose")
	for angle: float in [0.0, 10.0, 25.0, 40.0, 43.0]:
		t.ok(_strike_at(angle, speed), "%.0f degrees off the nose still connects" % angle)
	for angle: float in [46.0, 60.0, 90.0, 135.0, 180.0]:
		t.ok(not _strike_at(angle, speed), "%.0f degrees off the nose does not" % angle)

	# Reach and cone are independent: on the nose but too far away is still a miss.
	t.ok(
		not GameRules.within_strike(
			Vector3.ZERO, velocity, 1.0, Vector3(0.0, 0.0, -40.0), still, 0.5
		),
		"and being pointed at something forty metres away is not a catch"
	)

	# The prey's own motion reaches the test through the closing speed: a bird
	# coming at you is inside the window from further out than one running away.
	var head_on := Vector3(0.0, 0.0, 20.0)
	var fleeing := Vector3(0.0, 0.0, -18.0)
	var at: Vector3 = Vector3(0.0, 0.0, -10.0)
	t.ok(
		GameRules.within_strike(Vector3.ZERO, velocity, 1.0, at, head_on, 0.5),
		"a bird flying at you is struck from ten metres"
	)
	t.ok(
		not GameRules.within_strike(Vector3.ZERO, velocity, 1.0, at, fleeing, 0.5),
		"a bird running away from you at the same distance is not"
	)


## Bearing [param degrees] off the nose, at a distance well inside the reach.
static func _strike_at(degrees: float, speed: float) -> bool:
	var direction := Vector3(0.0, 0.0, -1.0)
	var offset: Vector3 = direction.rotated(Vector3.UP, deg_to_rad(degrees)) * 5.0
	return GameRules.within_strike(
		Vector3.ZERO, direction * speed, 1.0, offset, Vector3.ZERO, 0.5
	)


## The vacuum the cone left open at the bottom of the speed range: a hunter with
## no heading used to strike in every direction at once. A player sitting on a
## branch ate everything smaller that came within five metres of it, and so did
## every roosting bird in a communal roost.
static func _test_a_bird_that_is_not_flying_is_not_hunting(t: TestCase) -> void:
	t.begin("a bird that is not flying is not hunting")
	var perched := Vector3(10.0, 40.0, -8.0)
	for bearing in 16:
		var angle: float = TAU * float(bearing) / 16.0
		var offset := Vector3(cos(angle), 0.0, sin(angle)) * 3.0
		t.ok(
			not GameRules.within_strike(
				perched, Vector3.ZERO, 2.0, perched + offset, Vector3.ZERO, 0.5
			),
			"a perched bird does not eat what walks past it (bearing %.0f)" % rad_to_deg(angle)
		)
	t.ok(
		not GameRules.within_strike(
			perched, Vector3(0.3, 0.0, 0.2), 2.0, perched + Vector3(0.0, 0.0, -2.0),
			Vector3.ZERO, 0.5
		),
		"nor does one shuffling about on its branch"
	)
	t.ok(
		not GameRules.within_strike(perched, Vector3.ZERO, 2.0, perched, Vector3.ZERO, 0.5),
		"and standing on top of it is not a catch either"
	)
	t.greater(
		GameRules.MIN_STRIKE_SPEED, 0.5, "the floor is well above a perched bird's drift"
	)
	t.less(GameRules.MIN_STRIKE_SPEED, 8.0, "and well below anything the flight model will fly")

	# Being perched protects the hunter, not the hunted: a stoop onto a roosting
	# bird is exactly the manoeuvre the AI spends its height on.
	t.ok(
		GameRules.within_strike(
			perched + Vector3(0.0, 8.0, 0.0), Vector3(0.0, -18.0, 0.0), 2.0,
			perched, Vector3.ZERO, 0.5
		),
		"but a bird diving onto a perched one still catches it"
	)
	t.ok(
		GameRules.within_strike(
			perched, Vector3(0.0, 0.0, -16.0), 2.0, perched + Vector3(0.0, 0.0, -4.0),
			Vector3.ZERO, 0.5
		),
		"and a bird at flying speed catches what is ahead of it"
	)


static func _test_the_strike_test_survives_hostile_input(t: TestCase) -> void:
	t.begin("the strike test survives hostile input")
	var bad: Array[Vector3] = [
		Vector3(NAN, 0.0, 0.0), Vector3(INF, INF, INF), Vector3(-INF, 0.0, 1.0),
		Vector3(1e30, 1e30, 1e30),
	]
	for position: Vector3 in bad:
		t.ok(
			not GameRules.within_strike(
				position, Vector3(0.0, 0.0, -20.0), 1.0, Vector3.ZERO, Vector3.ZERO, 0.5
			),
			"a nonsense hunter position is not a catch (%s)" % str(position)
		)
		t.ok(
			not GameRules.within_strike(
				Vector3.ZERO, position, 1.0, Vector3(0.0, 0.0, -3.0), Vector3.ZERO, 0.5
			),
			"nor is a nonsense velocity (%s)" % str(position)
		)
		t.ok(
			not GameRules.within_strike(
				Vector3.ZERO, Vector3(0.0, 0.0, -20.0), 1.0, position, Vector3.ZERO, 0.5
			),
			"nor is a prey nowhere in particular (%s)" % str(position)
		)
	t.ok(
		not GameRules.within_strike(
			Vector3.ZERO, Vector3(0.0, 0.0, -20.0), NAN, Vector3(0.0, 0.0, -3.0),
			Vector3.ZERO, NAN
		),
		"and a bird of no particular size catches nothing"
	)
