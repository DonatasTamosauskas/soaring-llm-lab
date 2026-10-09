extends Logger
## TEST-ONLY: counts engine and script errors (and warnings) while
## installed, through Godot's Logger API (OS.add_logger). The definition of
## done forbids SCRIPT ERRORs and error spam; with this a test can assert
## "no errors" for the code paths it drives instead of grepping logs.
##
##   var log := ErrorLog.install()
##   ...
##   log.uninstall()
##   eq(log.errors, 0, "no errors: %s" % [log.samples])

var errors := 0
var warnings := 0
## The first few messages, for the failure text.
var samples: Array[String] = []
var _mutex := Mutex.new()


static func install() -> Logger:
	var l: Logger = load("res://tests/unit/audio/audio_error_log.gd").new()
	OS.add_logger(l)
	return l


func uninstall() -> void:
	OS.remove_logger(self)


func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool,
		error_type: int, _script_backtraces: Array[ScriptBacktrace]) -> void:
	_mutex.lock()
	if error_type == ERROR_TYPE_WARNING:
		warnings += 1
	else:
		errors += 1
	if samples.size() < 6:
		samples.append("%s (%s:%d %s)" % [rationale if not rationale.is_empty() else code, file.get_file(), line, function])
	_mutex.unlock()


func _log_message(_message: String, _error: bool) -> void:
	pass
