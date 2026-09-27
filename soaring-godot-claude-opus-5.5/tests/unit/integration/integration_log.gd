extends Logger
## TEST-ONLY: every engine and script error or warning while the composed
## game runs (Godot's Logger API), so the whole-game suites can assert "no
## SCRIPT ERROR, no push_error, no warning" for everything they drove,
## whichever area raised it.
##
## Tolerated: the engine's own exit noise listed in ARCHITECTURE §3 (it is
## never raised while a test runs) and nothing else.

const NOISE := ["p_tracker.is_null", "ObjectDB instance", "were leaked at exit"]

const BACKTRACE_FRAMES := 5

var errors := 0
var warnings := 0
## The first messages of each kind, for failure text.
var samples: Array[String] = []
var _mutex := Mutex.new()


static func install() -> Logger:
	var l: Logger = load("res://tests/unit/integration/integration_log.gd").new()
	OS.add_logger(l)
	return l


func uninstall() -> void:
	OS.remove_logger(self)


func clear() -> void:
	_mutex.lock()
	errors = 0
	warnings = 0
	samples.clear()
	_mutex.unlock()


func summary() -> String:
	return "%d errors, %d warnings: %s" % [errors, warnings, samples]


func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool,
		error_type: int, script_backtraces: Array[ScriptBacktrace]) -> void:
	var text := rationale if not rationale.is_empty() else code
	for n in NOISE:
		if text.contains(n):
			return
	var where := "%s:%d %s" % [file.get_file(), line, function]
	# The script frames that led here (up to BACKTRACE_FRAMES): an engine
	# error raised from a shared helper (bird.gd) says little without them.
	for bt in script_backtraces:
		if bt != null and bt.get_frame_count() > 0:
			for i in mini(bt.get_frame_count(), BACKTRACE_FRAMES):
				where += " <- %s:%d" % [bt.get_frame_file(i).get_file(), bt.get_frame_line(i)]
			break
	_mutex.lock()
	if error_type == ERROR_TYPE_WARNING:
		warnings += 1
	else:
		errors += 1
	if samples.size() < 10:
		samples.append("%s: %s (%s)" % ["WARNING" if error_type == ERROR_TYPE_WARNING else "ERROR", text, where])
	_mutex.unlock()


func _log_message(_message: String, _error: bool) -> void:
	pass
