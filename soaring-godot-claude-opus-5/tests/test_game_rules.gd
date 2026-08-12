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
