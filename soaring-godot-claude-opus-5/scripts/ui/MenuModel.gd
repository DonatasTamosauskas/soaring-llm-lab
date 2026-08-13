class_name MenuModel
extends RefCounted

## What the menu says and what pressing things on it means. No scene, no nodes.
##
## The whole flow lives here — which screens exist, what is on them, what a row
## does, and how you get back out — so that "there is a way in and a way out"
## is a property a test can check rather than a thing somebody remembers to
## verify by putting a headset on. [MenuPanel] draws whatever this says; it
## makes no decisions of its own.

enum Screen { MAIN, PAUSE, SETTINGS, CONTROLS, SUMMARY }
enum Kind { ACTION, SETTING }

## Everything a row can ask the game to do. [MenuGate] is the only thing that
## interprets these; this object only decides which one a row carries.
const ACT_START := &"start"
const ACT_RESUME := &"resume"
const ACT_RESTART := &"restart"
const ACT_SETTINGS := &"settings"
const ACT_CONTROLS := &"controls"
const ACT_BACK := &"back"
const ACT_QUIT := &"quit"
const ACT_RECENTRE := &"recentre"
const ACT_DEFAULTS := &"defaults"
const ACT_TEACH := &"teach"
const ACT_NONE := &"none"

## Actions that hand the sky back to the player. Every screen must offer one of
## these or a way back to a screen that does — see [method escape_of].
const ESCAPES: Array[StringName] = [ACT_START, ACT_RESUME, ACT_RESTART, ACT_BACK]

## Gesture on the left, what it buys you on the right. See
## [constant MenuLayout.COLUMN_SEPARATOR].
const CONTROLS_LINES: PackedStringArray = [
	"BEAT BOTH ARMS DOWN|climb",
	"DROP ONE HAND|bank, turn",
	"BRING HANDS TOGETHER|dive",
	"ROLL WRISTS BACK|nose up, slow",
	"BEAT ONE ARM HARDER|yaw flick",
	"FLAP ON A BRANCH|take off",
	# Both halves kept short: the columns are laid out from the panel's edges and
	# a long right-hand phrase runs into a long left-hand one, which is what
	# "HOLD BOTH TRIGGERS re-trim, face forward" looked like in a capture.
	"SQUEEZE A GRIP|cling on",
	"HOLD BOTH TRIGGERS|recentre",
]

var settings: PlayerSettings
var screen: Screen = Screen.MAIN
## The last run's [method GameSession.summary], for the summary screen.
var summary: Dictionary = {}
## Set while the game will not accept a restart yet, so the summary can say so
## instead of offering a button that does nothing.
var restart_armed: bool = true
var hovered: int = -1

var _stack: Array[Screen] = []


func _init(settings_ref: PlayerSettings = null) -> void:
	settings = settings_ref if settings_ref != null else PlayerSettings.new()


# --- content -----------------------------------------------------------------

func title() -> String:
	match screen:
		Screen.MAIN:
			return "SOARING"
		Screen.PAUSE:
			return "PAUSED"
		Screen.SETTINGS:
			return "COMFORT"
		Screen.CONTROLS:
			return "HOW TO FLY"
		_:
			return String(summary.get("title", "RUN OVER"))


## Lines of plain text above the rows. Never interactive: a player who cannot
## tell a label from a button will press the label.
func body() -> PackedStringArray:
	match screen:
		Screen.MAIN:
			var lines: PackedStringArray = ["a bird, and a sky full of birds"]
			var best: int = int(settings.get_value("best_score"))
			if best > 0:
				lines.append("best score  %d" % best)
			return lines
		Screen.CONTROLS:
			return CONTROLS_LINES
		Screen.SUMMARY:
			return _summary_lines()
		Screen.SETTINGS:
			var index: int = hovered
			var rows_now: Array[Dictionary] = rows()
			if index >= 0 and index < rows_now.size():
				var hint: String = String(rows_now[index].get("hint", ""))
				if not hint.is_empty():
					return PackedStringArray([hint])
			return PackedStringArray(["point at a row and pull the trigger"])
		_:
			return PackedStringArray()


func _summary_lines() -> PackedStringArray:
	var lines: PackedStringArray = PackedStringArray([
		"%s in the air" % GameSession.clock(float(summary.get("elapsed", 0.0))),
		"%d caught,  %d times caught" % [
			int(summary.get("catches", 0)), int(summary.get("deaths", 0)),
		],
		"best run of %d,  score %d" % [
			int(summary.get("best_streak", 0)), int(summary.get("score", 0)),
		],
	])
	# The wingbeat restart is the one this game taught you; the button is for
	# players who would rather press a button. Both are offered, and neither is
	# offered before the delay that stops the flap which killed you from
	# skipping the summary it earned.
	if restart_armed:
		lines.append("— or just beat your wings —")
	return lines


## The rows of the current screen, top to bottom.
func rows() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	match screen:
		Screen.MAIN:
			out.append(_action(ACT_START, "FLY"))
			out.append(_action(ACT_CONTROLS, "HOW TO FLY"))
			out.append(_action(ACT_SETTINGS, "COMFORT"))
			out.append(_action(ACT_QUIT, "QUIT"))
		Screen.PAUSE:
			out.append(_action(ACT_RESUME, "KEEP FLYING"))
			out.append(_action(ACT_CONTROLS, "HOW TO FLY"))
			out.append(_action(ACT_SETTINGS, "COMFORT"))
			out.append(_action(ACT_RESTART, "START A NEW RUN"))
			out.append(_action(ACT_QUIT, "QUIT"))
		Screen.SETTINGS:
			for entry: Dictionary in PlayerSettings.SPECS:
				out.append(_setting(entry))
			out.append(_action(ACT_RECENTRE, "RECENTRE MY WINGS"))
			out.append(_action(ACT_DEFAULTS, "BACK TO DEFAULTS"))
			out.append(_action(ACT_BACK, "BACK"))
		Screen.CONTROLS:
			out.append(_action(ACT_TEACH, "TEACH ME AS I FLY"))
			out.append(_action(ACT_BACK, "BACK"))
		Screen.SUMMARY:
			out.append(_action(ACT_RESTART, "FLY AGAIN"))
			out.append(_action(ACT_SETTINGS, "COMFORT"))
			out.append(_action(ACT_QUIT, "QUIT"))
	return out


func _action(id: StringName, label: String) -> Dictionary:
	return {"id": id, "label": label, "kind": Kind.ACTION, "value": "", "fill": -1.0}


func _setting(entry: Dictionary) -> Dictionary:
	var key: String = String(entry["key"])
	return {
		"id": StringName("set:%s" % key), "label": String(entry["label"]),
		"kind": Kind.SETTING, "key": key, "value": settings.value_text(key),
		"fill": settings.value_fraction(key), "hint": String(entry.get("hint", "")),
	}


## Whether opening this screen should stop the world. Everything except the
## end-of-run summary does: the summary appears while the bird is still gliding,
## because freezing a player in mid-air in a headset is how you get one taken
## off, and because a wingbeat is what starts the next run.
func is_pausing() -> bool:
	return screen != Screen.SUMMARY


func has_title() -> bool:
	return true


# --- navigation --------------------------------------------------------------

func open(target: Screen) -> void:
	if target == screen:
		return
	_stack.append(screen)
	screen = target
	hovered = -1


func back() -> void:
	if _stack.is_empty():
		screen = Screen.MAIN
	else:
		screen = _stack.pop_back()
	hovered = -1


## Enters a screen fresh, forgetting where the player had been. Used when the
## menu is opened from the game rather than navigated to, so that backing out
## of Comfort returns to the pause screen you opened it from and not to a stale
## summary from two runs ago.
func reset_to(target: Screen) -> void:
	_stack.clear()
	screen = target
	hovered = -1


func depth() -> int:
	return _stack.size()


# --- input -------------------------------------------------------------------

func hover(row: int) -> void:
	var count: int = rows().size()
	hovered = row if row >= 0 and row < count else -1


## Presses row [param row]. Settings cycle in place and report [constant
## ACT_NONE] — a comfort slider that closed the menu every time you nudged it
## would be unusable.
func activate(row: int) -> StringName:
	var all: Array[Dictionary] = rows()
	if row < 0 or row >= all.size():
		return ACT_NONE
	var entry: Dictionary = all[row]
	if int(entry["kind"]) == Kind.SETTING:
		settings.adjust(String(entry["key"]), 1)
		return ACT_NONE
	var id: StringName = entry["id"]
	match id:
		ACT_SETTINGS:
			open(Screen.SETTINGS)
			return ACT_NONE
		ACT_CONTROLS:
			open(Screen.CONTROLS)
			return ACT_NONE
		ACT_BACK:
			back()
			return ACT_NONE
		ACT_DEFAULTS:
			settings.restore_defaults()
			return ACT_DEFAULTS
	return id


## Nudges a setting row without pressing it — the thumbstick path, and the only
## way to turn a setting [i]down[/i] without cycling all the way round.
func adjust(row: int, direction: int) -> bool:
	var all: Array[Dictionary] = rows()
	if row < 0 or row >= all.size():
		return false
	var entry: Dictionary = all[row]
	if int(entry["kind"]) != Kind.SETTING:
		return false
	settings.adjust(String(entry["key"]), direction)
	return true


## The row on this screen that gets the player back out, or -1 if there is none.
## [UITests] asserts that this is never -1, which is the whole "no dead ends"
## rule in one line.
func escape_of() -> int:
	var all: Array[Dictionary] = rows()
	for i in all.size():
		if int(all[i]["kind"]) == Kind.ACTION and ESCAPES.has(all[i]["id"] as StringName):
			return i
	return -1
