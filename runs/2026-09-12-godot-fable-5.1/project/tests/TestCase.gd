class_name TestCase
extends RefCounted

## Minimal assertion helpers for headless suites. Each suite is a class with
## `func run(t: TestCase)`; failures are collected, not thrown.

var passed: int = 0
var failed: int = 0
var failures: PackedStringArray = []
var suite: String = ""

func ok(cond: bool, msg: String) -> bool:
	if cond:
		passed += 1
	else:
		failed += 1
		failures.append("%s: %s" % [suite, msg])
		print("  FAIL %s: %s" % [suite, msg])
	return cond

func near(a: float, b: float, tol: float, msg: String) -> bool:
	return ok(absf(a - b) <= tol, "%s (got %.4f, want %.4f ± %.4f)" % [msg, a, b, tol])

func lt(a: float, b: float, msg: String) -> bool:
	return ok(a < b, "%s (%.4f < %.4f)" % [msg, a, b])

func gt(a: float, b: float, msg: String) -> bool:
	return ok(a > b, "%s (%.4f > %.4f)" % [msg, a, b])

func finite3(v: Vector3, msg: String) -> bool:
	return ok(is_finite(v.x) and is_finite(v.y) and is_finite(v.z), "%s (%s)" % [msg, v])
