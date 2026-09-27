class_name UIProgress
extends RefCounted
## What the UI remembers between sessions that is not a setting: tutorial
## completion and the best score (if the game loop does not keep one).
## Its own file so it never collides with Settings' keys; tests point `path`
## at a scratch file.

const DEFAULT_PATH := "user://ui_progress.cfg"

var path := DEFAULT_PATH
var _cfg := ConfigFile.new()


func _init(p_path: String = DEFAULT_PATH) -> void:
	path = p_path
	_cfg.load(path)


func onboarding_done() -> bool:
	return bool(_cfg.get_value("onboarding", "done", false))


func set_onboarding_done(done: bool) -> void:
	_cfg.set_value("onboarding", "done", done)
	_save()


func lessons_done() -> Array:
	return _cfg.get_value("onboarding", "lessons", [])


func mark_lesson(id: StringName) -> void:
	var l := lessons_done()
	if not String(id) in l:
		l.append(String(id))
	_cfg.set_value("onboarding", "lessons", l)
	_save()


func reset_onboarding() -> void:
	_cfg.set_value("onboarding", "done", false)
	_cfg.set_value("onboarding", "lessons", [])
	_save()


func best_score() -> int:
	return int(_cfg.get_value("stats", "best_score", 0))


## Returns true if score is a new best (and stores it).
func submit_score(score: int) -> bool:
	if score <= best_score():
		return false
	_cfg.set_value("stats", "best_score", score)
	_save()
	return true


func _save() -> void:
	_cfg.save(path)
