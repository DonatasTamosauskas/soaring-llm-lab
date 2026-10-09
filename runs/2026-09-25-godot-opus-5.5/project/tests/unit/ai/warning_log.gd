extends Logger
## TEST-ONLY: counts the engine's warnings and errors while installed
## (Godot's Logger API, OS.add_logger). The definition of done forbids
## warning spam; this lets a suite assert "0 engine warnings" for the AI
## code paths it exercised instead of only grepping logs afterwards.
##
## Only messages the AI caused count: raised from a file under scripts/ai/,
## scenes/ai/ or tests/unit/ai/, or with one of those as the innermost
## GDScript frame (an engine warning such as Basis.looking_at's, raised
## from C++ on behalf of AI code). Other areas are built in parallel and may be
## half-written at any moment (a bird shader that does not compile yet):
## their messages are kept apart in `foreign` and never fail an AI test.
##
##   var log := WarningLog.install()
##   ...simulate...
##   eq(log.warnings, 0, "...")
##   log.uninstall()

const AI_PATHS := ["scripts/ai/", "scenes/ai/", "tests/unit/ai/", "scenes/dev/ai_"]

var warnings := 0
var errors := 0
## Messages from outside the AI (not counted above).
var foreign := 0
## A few of them, for the failure message.
var samples: Array[String] = []
var foreign_samples: Array[String] = []
var _mutex := Mutex.new()


static func install() -> Logger:
	var l: Logger = load("res://tests/unit/ai/warning_log.gd").new()
	OS.add_logger(l)
	return l


func uninstall() -> void:
	OS.remove_logger(self)


static func _is_ai(path: String) -> bool:
	for p in AI_PATHS:
		if path.contains(p):
			return true
	return false


func _log_error(_function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool, error_type: int, script_backtraces: Array[ScriptBacktrace]) -> void:
	# Ours if raised in an AI file, or if the innermost GDScript frame is
	# one (an engine warning raised on behalf of AI code). A bird shader
	# failing to compile when an NPC creates its model has the NPC further
	# down the stack, but the birds area's code on top: not ours.
	var ours := _is_ai(file)
	if not ours:
		for bt in script_backtraces:
			if bt != null and bt.get_frame_count() > 0:
				ours = _is_ai(bt.get_frame_file(0))
				break
	var text := "%s (%s:%d)" % [code if rationale.is_empty() else rationale, file.get_file(), line]
	_mutex.lock()
	if not ours:
		foreign += 1
		if foreign_samples.size() < 4:
			foreign_samples.append(text)
	else:
		if error_type == ERROR_TYPE_WARNING:
			warnings += 1
		else:
			errors += 1
		if samples.size() < 6:
			samples.append(text)
	_mutex.unlock()


func _log_message(_message: String, _error: bool) -> void:
	pass
