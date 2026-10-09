extends SceneTree

## Headless entry point:
##   godot --headless --script res://tests/run_tests.gd
## Exits non-zero if anything failed, so it drops straight into CI or a
## pre-commit hook.


func _initialize() -> void:
	var t := TestCase.new()
	var started: int = Time.get_ticks_msec()

	FlightTests.run(t)
	WingInputTests.run(t)
	GameRulesTests.run(t)
	ProgressionTests.run(t)
	WorldTests.run(t)
	PaletteTests.run(t)
	BirdTests.run(t)
	AITests.run(t)
	UITests.run(t)
	ComfortTests.run(t)
	AudioTests.run(t)

	var elapsed: int = Time.get_ticks_msec() - started
	print("")
	print("=== Soaring flight tests ===")
	print("%d assertions in %d ms" % [t.checks, elapsed])
	if t.failures.is_empty():
		print("ALL PASS")
		quit(0)
		return
	print("%d FAILURES:" % t.failures.size())
	for f: String in t.failures:
		print("  - %s" % f)
	quit(1)
