class_name MenuProbe
extends Node

## Drives the real menu, in the real game, the way a player does: it points a
## ray at a row, presses it, and then checks what the game did about it.
##
## [UITests] proves the menu's model and its geometry in isolation, which is
## most of it — but "pressing FLY starts the game" and "pausing actually stops
## the world" are claims about the scene tree, and the last time this project
## trusted an isolated test about something a player touches, a bug reached a
## headset. Run it with:
##   godot --headless --xr-mode off --fixed-fps 90 -- --uiprobe=1

signal finished(passed: bool)

var player: BirdPlayer
var manager: GameManager
var menu: GameMenu

var _steps: Array[Dictionary] = []
var _index: int = -1
var _timer: float = 0.0
var _failures: PackedStringArray = []
var _log: PackedStringArray = []
var _mark: Vector3 = Vector3.ZERO
var _aim_row: int = -1


func start(player_ref: BirdPlayer, manager_ref: GameManager, menu_ref: GameMenu) -> void:
	player = player_ref
	manager = manager_ref
	menu = menu_ref
	# The probe has to keep thinking while the thing it is testing has stopped
	# the world.
	process_mode = Node.PROCESS_MODE_ALWAYS
	# Start from the shipped defaults, into a scratch file: a probe that read the
	# player's saved comfort settings would pass or fail depending on what they
	# had chosen, and one that wrote to them would quietly change their game.
	menu.settings_path = "user://uiprobe-settings.cfg"
	menu.settings.restore_defaults()
	menu.apply_settings()
	menu.ray_source = _ray
	_build_routine()
	_advance()


## Aims from the player's head at whichever row this step wants. A real ray
## through the real panel, so a panel that is mispositioned, facing away, or
## the wrong size fails here exactly as it would in a headset.
func _ray() -> Array:
	var head: Vector3 = player.head_position()
	if _aim_row < 0:
		return [head, Vector3.UP]
	var target: Vector3 = menu.row_point(_aim_row)
	var direction: Vector3 = target - head
	if direction.length_squared() < 1e-6:
		return [head, Vector3.FORWARD]
	return [head, direction.normalized()]


## [param aim] is the row to point at before the step's wait, and [param press]
## presses it once the wait is over. Each check is a method name because a
## multi-line lambda inside a Dictionary literal does not parse — the same
## workaround [FlightProbe] uses.
func _step(name: String, seconds: float, aim: int, press: bool, check: String) -> Dictionary:
	return {
		"name": name, "seconds": seconds, "aim": aim, "press": press, "check": check,
	}


## Each row is: point at [param aim], wait, run the check while the game is in
## that state, then press if the step presses. The settings screen's rows are
## the entries in [constant PlayerSettings.SPECS] followed by RECENTRE, DEFAULTS
## and BACK, which is where the row numbers below come from — so adding a
## comfort setting moves them, and this is where that shows up.
func _build_routine() -> void:
	# Derived rather than written down, because they moved once already when the
	# comfort screen grew a row and the failure looked like a broken BACK button.
	var recentre_row: int = PlayerSettings.SPECS.size()
	var back_row: int = PlayerSettings.SPECS.size() + 2
	_steps = [
		_step("the game opens on a menu", 0.3, 0, false, "_check_opens_on_menu"),
		_step("pointing at FLY highlights it", 0.2, 0, true, "_check_hover_fly"),
		_step("FLY hands back the sky", 0.6, -1, false, "_check_flying"),
		_step("the menu button pauses", 0.5, -1, false, "_check_paused"),
		_step("a paused world does not move", 0.5, 2, true, "_check_frozen"),
		_step("COMFORT opens the settings", 0.2, 0, true, "_check_settings_open"),
		_step("a comfort row changes a setting", 0.2, recentre_row, true, "_check_setting_changed"),
		_step("recentring does not break flight", 0.2, back_row, true, "_check_recentred"),
		_step("BACK returns to the pause screen", 0.2, 0, true, "_check_back"),
		_step("KEEP FLYING resumes the world", 0.6, -1, false, "_check_resumed"),
		_step("losing the run raises the summary", 0.4, 0, false, "_check_summary"),
		_step("the pause screen is reachable from it", 0.2, 0, true, "_check_pause_over_summary"),
		_step("and leads back to it", 0.2, 0, true, "_check_summary_returns"),
		_step("FLY AGAIN starts a new run", 0.4, -1, false, "_check_restarted"),
	]


func _advance() -> void:
	if _index >= 0:
		var step: Dictionary = _steps[_index]
		call(String(step["check"]))
		if bool(step["press"]):
			menu.repoint()
			menu.press()
	_index += 1
	if _index >= _steps.size():
		_report()
		return
	_before(_index)
	_aim_row = int(_steps[_index]["aim"])
	_timer = float(_steps[_index]["seconds"])
	menu.repoint()


## Whatever the game has to be doing for the next step to mean anything. Kept
## out of the checks so that a step reads as "do this, then assert that".
func _before(index: int) -> void:
	match String(_steps[index]["name"]):
		"the menu button pauses":
			_mark = player.global_position
		"a paused world does not move":
			_mark = player.global_position
		"KEEP FLYING resumes the world":
			_mark = player.global_position
		"losing the run raises the summary":
			# The one thing a probe cannot do by flying: lose. Spend the lives
			# directly and let the real signal chain do the rest.
			for i in Progression.LIVES:
				manager.session.record_death(2.4)
		"the pause screen is reachable from it":
			menu.toggle()


func _process(delta: float) -> void:
	if _index < 0 or _index >= _steps.size():
		return
	_timer -= delta
	# The menu button is not reachable from a headless probe, so the two steps
	# that need it call the same public method the button does.
	if String(_steps[_index]["name"]) == "the menu button pauses" and _timer <= 0.0:
		menu.toggle()
	if _timer <= 0.0:
		_advance()


# --- checks ------------------------------------------------------------------

func _check_opens_on_menu() -> void:
	_expect(menu.is_open, "the menu is open")
	_expect(menu.model.screen == MenuModel.Screen.MAIN, "it is the main menu")
	_expect(get_tree().paused, "the world is stopped behind it")
	_expect(menu.model.rows().size() >= 4, "it offers at least four things to do")


func _check_hover_fly() -> void:
	_expect(menu.hovered_row() == 0, "the ray lands on FLY (row %d)" % menu.hovered_row())


func _check_flying() -> void:
	_expect(not menu.is_open, "the menu is gone")
	_expect(not get_tree().paused, "the world is running")
	_expect(player.airspeed() > 5.0, "the bird is flying (%.1f m/s)" % player.airspeed())


func _check_paused() -> void:
	_expect(player.global_position.distance_to(_mark) > 1.0, "the bird flew while unpaused")
	_expect(menu.is_open, "the menu came back")
	_expect(menu.model.screen == MenuModel.Screen.PAUSE, "on the pause screen")
	_expect(get_tree().paused, "and it stopped the world")


func _check_frozen() -> void:
	var drift: float = player.global_position.distance_to(_mark)
	_expect(drift < 0.001, "nothing moved while paused (%.4f m)" % drift)


func _check_settings_open() -> void:
	_expect(menu.model.screen == MenuModel.Screen.SETTINGS, "the comfort screen is up")
	_expect(get_tree().paused, "still paused inside a submenu")
	_mark = Vector3(menu.settings.get_value("comfort_vignette"), 0.0, 0.0)


## The previous step pressed row 0, the comfort vignette. It should have moved,
## and the game should already be flying with the new value.
func _check_setting_changed() -> void:
	var now: float = menu.settings.get_value("comfort_vignette")
	_expect(not is_equal_approx(now, _mark.x), "the vignette moved (%.2f)" % now)
	_expect(
		is_equal_approx(Tuning.comfort_vignette, now),
		"and the game is using it (Tuning %.2f)" % Tuning.comfort_vignette
	)


func _check_recentred() -> void:
	_expect(menu.model.screen == MenuModel.Screen.SETTINGS, "recentring stayed put")
	_expect(is_finite(player.model.airspeed), "flight survived it")


func _check_back() -> void:
	_expect(menu.model.screen == MenuModel.Screen.PAUSE, "back on the pause screen")


func _check_resumed() -> void:
	_expect(not get_tree().paused, "the world is running again")
	_expect(not menu.is_open, "the menu is closed")
	_expect(
		player.global_position.distance_to(_mark) > 1.0,
		"and the bird moved again (%.1f m)" % player.global_position.distance_to(_mark)
	)


func _check_summary() -> void:
	_expect(menu.is_open, "the summary appeared by itself")
	_expect(menu.model.screen == MenuModel.Screen.SUMMARY, "it is the summary")
	_expect(
		not get_tree().paused,
		"and the bird is still gliding — a summary is not a pause"
	)


## A player who opens the pause menu over a finished run and then leaves it must
## land back on the summary, not in a sky with nothing left to play.
func _check_pause_over_summary() -> void:
	_expect(menu.model.screen == MenuModel.Screen.PAUSE, "the pause screen came up")
	_expect(get_tree().paused, "and stopped the world even though the run is over")


func _check_summary_returns() -> void:
	_expect(menu.model.screen == MenuModel.Screen.SUMMARY, "leaving it returns to the summary")
	_expect(menu.is_open, "which is still there")
	_expect(not get_tree().paused, "and the sky is moving again")


func _check_restarted() -> void:
	_expect(not menu.is_open, "the menu closed")
	_expect(not manager.session.is_over(), "a new run is under way")
	_expect(
		is_equal_approx(player.size, Progression.START_SIZE),
		"back at the starting size (%.2f)" % player.size
	)
	_expect(not get_tree().paused, "and the world is running")


func _expect(condition: bool, message: String) -> void:
	var name: String = String(_steps[_index]["name"]) if _index < _steps.size() else "?"
	_log.append("  %s  %s — %s" % ["ok  " if condition else "FAIL", name, message])
	if not condition:
		_failures.append("%s: %s" % [name, message])


func _report() -> void:
	menu.ray_source = Callable()
	for line: String in _log:
		print(line)
	if _failures.is_empty():
		print("MENU PROBE PASS — %d checks" % _log.size())
	else:
		print("MENU PROBE FAIL — %d of %d checks" % [_failures.size(), _log.size()])
	finished.emit(_failures.is_empty())
