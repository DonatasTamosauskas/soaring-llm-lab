extends SceneTree

## godot --headless --xr-mode off --script res://tests/run_tests.gd [-- --only=flight]
## Runs every headless suite and exits 0 on ALL PASS, 1 otherwise.

const SUITES: Dictionary = {
	"flight": "res://tests/test_flight.gd",
	"wing_input": "res://tests/test_wing_input.gd",
}

func _init() -> void:
	var only: String = Args.value("only")
	var t := TestCase.new()
	var total_p: int = 0
	var total_f: int = 0
	var extra: Dictionary = _discover()
	var all: Dictionary = SUITES.duplicate()
	all.merge(extra)
	for name: String in all:
		if only != "" and name != only:
			continue
		var script: Script = load(all[name])
		if script == null:
			print("MISSING suite %s" % name)
			total_f += 1
			continue
		var suite: Object = script.new()
		t.suite = name
		var before_p: int = t.passed
		var before_f: int = t.failed
		var t0: int = Time.get_ticks_msec()
		suite.run(t)
		print("%-14s %4d passed %3d failed  (%d ms)" % [name, t.passed - before_p, t.failed - before_f, Time.get_ticks_msec() - t0])
		total_p = t.passed
		total_f = t.failed
	if total_f == 0:
		print("ALL PASS (%d assertions)" % total_p)
		quit(0)
	else:
		print("FAILED: %d of %d assertions" % [total_f, total_p + total_f])
		for f in t.failures:
			print("  - " + f)
		quit(1)

## Any tests/test_*.gd not listed above is picked up automatically so area
## agents can add suites without editing this file.
func _discover() -> Dictionary:
	var found: Dictionary = {}
	var dir := DirAccess.open("res://tests")
	if dir == null:
		return found
	for f in dir.get_files():
		if f.begins_with("test_") and f.ends_with(".gd"):
			var name: String = f.trim_prefix("test_").trim_suffix(".gd")
			if not SUITES.has(name):
				found[name] = "res://tests/" + f
	return found
