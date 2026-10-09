class_name TestCase
extends RefCounted

## Minimal assertion helper. Deliberately tiny — the value here is in the flight
## assertions themselves, not in reinventing a test framework.

var failures: PackedStringArray = []
var checks: int = 0
var _current: String = ""


func begin(name: String) -> void:
	_current = name


func ok(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append("%s: %s" % [_current, message])


func in_range(value: float, low: float, high: float, message: String) -> void:
	ok(
		is_finite(value) and value >= low and value <= high,
		"%s (got %.4f, expected %.4f..%.4f)" % [message, value, low, high]
	)


func greater(value: float, than: float, message: String) -> void:
	ok(
		is_finite(value) and value > than,
		"%s (got %.4f, expected > %.4f)" % [message, value, than]
	)


func less(value: float, than: float, message: String) -> void:
	ok(
		is_finite(value) and value < than,
		"%s (got %.4f, expected < %.4f)" % [message, value, than]
	)


func near(value: float, expected: float, tolerance: float, message: String) -> void:
	ok(
		is_finite(value) and absf(value - expected) <= tolerance,
		"%s (got %.4f, expected %.4f +/- %.4f)" % [message, value, expected, tolerance]
	)


func finite(value: Variant, message: String) -> void:
	var good: bool = false
	if value is float:
		good = is_finite(value)
	elif value is Vector3:
		good = (value as Vector3).is_finite()
	ok(good, "%s (got %s)" % [message, str(value)])
