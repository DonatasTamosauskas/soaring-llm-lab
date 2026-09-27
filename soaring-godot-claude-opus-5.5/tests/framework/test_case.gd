class_name TestCase
extends Node
## Base class for test suites. See tests/README.md.
##
## A suite is any tests/unit/**/<name>_test.gd extending TestCase. Every
## method named test_* runs in declaration order; it may await (physics
## frames, timers). The suite node sits in the live SceneTree with all
## autoloads, so tests can add real scenes as children.
##
## Record numbers you want reviewers to see with metric(); they land in the
## JSON report next to the pass/fail results.

var _failures: PackedStringArray = []
var _assertions := 0
var _metrics := {}
var _current := ""


# --- Hooks (override as needed; may await) ---
func before_all() -> void:
	pass


func after_all() -> void:
	pass


func before_each() -> void:
	pass


func after_each() -> void:
	pass


# --- Assertions: each returns whether it passed ---
func check(cond: bool, msg: String) -> bool:
	_assertions += 1
	if not cond:
		_failures.append("%s: %s" % [_current, msg])
	return cond


func fail(msg: String) -> void:
	check(false, msg)


func eq(actual: Variant, expected: Variant, msg: String) -> bool:
	return check(actual == expected, "%s (got %s, want %s)" % [msg, str(actual), str(expected)])


func near(actual: float, expected: float, tol: float, msg: String) -> bool:
	return check(absf(actual - expected) <= tol, "%s (got %.4f, want %.4f ± %.4f)" % [msg, actual, expected, tol])


func vnear(actual: Vector3, expected: Vector3, tol: float, msg: String) -> bool:
	return check(actual.distance_to(expected) <= tol, "%s (got %s, want %s ± %.4f)" % [msg, actual, expected, tol])


func gt(actual: float, bound: float, msg: String) -> bool:
	return check(actual > bound, "%s (got %.4f, want > %.4f)" % [msg, actual, bound])


func lt(actual: float, bound: float, msg: String) -> bool:
	return check(actual < bound, "%s (got %.4f, want < %.4f)" % [msg, actual, bound])


func between(actual: float, lo: float, hi: float, msg: String) -> bool:
	return check(actual >= lo and actual <= hi, "%s (got %.4f, want in [%.4f, %.4f])" % [msg, actual, lo, hi])


func finite(v: Variant, msg: String) -> bool:
	var ok := true
	match typeof(v):
		TYPE_FLOAT:
			ok = is_finite(v)
		TYPE_VECTOR3:
			ok = is_finite(v.x) and is_finite(v.y) and is_finite(v.z)
	return check(ok, "%s is not finite: %s" % [msg, str(v)])


## Record a number (or small array/dict) for the report.
func metric(key: String, value: Variant) -> void:
	_metrics["%s.%s" % [_current, key]] = value


# --- Timing helpers ---
func wait_physics(frames: int = 1) -> void:
	for i in frames:
		await get_tree().physics_frame


func wait_frames(frames: int = 1) -> void:
	for i in frames:
		await get_tree().process_frame


func wait_seconds(sec: float) -> void:
	await get_tree().create_timer(sec, true, true).timeout
