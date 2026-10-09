extends Node
## Discovers and runs TestCase suites; exits non-zero on any failure.
##
##   tools/gd.sh <sandbox> --headless res://tests/runner.tscn -- [--suite=flight] [--test=stall] [--dir=res://tests/unit]
##
## --suite matches a substring of the suite's path (e.g. "flight" runs
## tests/unit/flight/*_test.gd). --test matches a substring of method names.
## Writes artifacts/tests/<report>.json (report name = --suite or "all").

var _total_pass := 0
var _total_fail := 0
var _total_assert := 0
var _report := {"suites": []}


func _ready() -> void:
	var args := Paths.user_args()
	var dir: String = args.get("dir", "res://tests/unit")
	var suite_filter: String = args.get("suite", "")
	var test_filter: String = args.get("test", "")
	var files := _find(dir)
	files.sort()
	var t0 := Time.get_ticks_msec()
	for f in files:
		if suite_filter.is_empty() or f.contains(suite_filter):
			await _run_suite(f, test_filter)
	var secs := (Time.get_ticks_msec() - t0) / 1000.0
	_report["passed"] = _total_pass
	_report["failed"] = _total_fail
	_report["assertions"] = _total_assert
	_report["seconds"] = secs
	var name := suite_filter.replace("/", "_") if not suite_filter.is_empty() else "all"
	var path := Paths.artifacts("tests").path_join("report_%s.json" % name)
	var fa := FileAccess.open(path, FileAccess.WRITE)
	if fa:
		fa.store_string(JSON.stringify(_report, "  "))
	print("[test] ===== %d passed, %d failed, %d assertions, %.1f s =====" % [_total_pass, _total_fail, _total_assert, secs])
	print("[test] report: ", path)
	if files.is_empty():
		print("[test] no suites found under ", dir)
	get_tree().quit(1 if _total_fail > 0 or _total_pass == 0 else 0)


func _find(dir: String) -> PackedStringArray:
	var out: PackedStringArray = []
	var d := DirAccess.open(dir)
	if d == null:
		return out
	for sub in d.get_directories():
		out.append_array(_find(dir.path_join(sub)))
	for f in d.get_files():
		if f.ends_with("_test.gd"):
			out.append(dir.path_join(f))
	return out


func _run_suite(path: String, test_filter: String) -> void:
	var script := load(path) as Script
	if script == null or not script.can_instantiate():
		print("[test] FAIL %s: script failed to load (parse error?)" % path)
		_total_fail += 1
		_report["suites"].append({"path": path, "error": "load failed"})
		return
	var suite := script.new() as TestCase
	if suite == null:
		print("[test] FAIL %s: does not extend TestCase" % path)
		_total_fail += 1
		return
	suite.name = path.get_file().get_basename()
	add_child(suite)
	var entry := {"path": path, "tests": []}
	suite._current = "before_all"
	await suite.before_all()
	for m in script.get_script_method_list():
		var mname: String = m["name"]
		if not mname.begins_with("test_"):
			continue
		if not test_filter.is_empty() and not mname.contains(test_filter):
			continue
		suite._current = mname
		var before := suite._failures.size()
		var a0 := suite._assertions
		var t0 := Time.get_ticks_usec()
		await suite.before_each()
		await suite.call(mname)
		await suite.after_each()
		var ms := (Time.get_ticks_usec() - t0) / 1000.0
		var new_fail := suite._failures.slice(before)
		var ok := new_fail.is_empty() and suite._assertions > a0
		if suite._assertions == a0:
			new_fail.append("%s: made no assertions" % mname)
		if ok:
			_total_pass += 1
			print("[test]   ok   %s.%s (%d asserts, %.0f ms)" % [suite.name, mname, suite._assertions - a0, ms])
		else:
			_total_fail += 1
			print("[test]   FAIL %s.%s" % [suite.name, mname])
			for f in new_fail:
				print("[test]        - ", f)
		entry["tests"].append({"name": mname, "ok": ok, "ms": ms, "failures": Array(new_fail)})
	suite._current = "after_all"
	await suite.after_all()
	_total_assert += suite._assertions
	entry["metrics"] = suite._metrics
	_report["suites"].append(entry)
	suite.queue_free()
	await get_tree().process_frame
