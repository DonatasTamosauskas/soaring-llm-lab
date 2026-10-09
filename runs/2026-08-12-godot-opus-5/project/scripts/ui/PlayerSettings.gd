class_name PlayerSettings
extends RefCounted

## The settings a player is genuinely going to want, and the only place they are
## described.
##
## Every knob here is declared once in [constant SPECS] — its range, its step,
## how it is worded on the panel and which [Tuning] field it drives — and the
## settings screen is built from that declaration rather than hand-laid out. A
## new comfort option is one entry, not an entry plus a row plus a save line
## plus a load line, which is how settings screens fall out of step with what
## they claim to control.
##
## No scene, no autoload lookup: [method tuning_values] hands back a plain
## dictionary and the caller pushes it into [Tuning]. That is the same push-in
## rule [BirdPlayer._sync_tuning] follows, and it is what lets the whole of this
## be tested headlessly where no autoload exists.

const FILE_PATH: String = "user://soaring.cfg"
const SECTION: String = "player"

enum Kind { NUMBER, CHOICE, FLAG }

## Declared order is the order they appear on the panel. Comfort first, because
## a player who feels ill is not going to scroll.
const SPECS: Array = [
	{
		"key": "comfort_vignette", "label": "COMFORT VIGNETTE", "kind": Kind.NUMBER,
		"min": 0.0, "max": 1.0, "step": 0.1, "default": 0.7,
		"tuning": "comfort_vignette",
		"hint": "narrows your view as you speed up",
	},
	{
		"key": "visual_roll", "label": "HORIZON ROLL", "kind": Kind.NUMBER,
		"min": 0.0, "max": 1.0, "step": 0.05, "default": 0.35,
		"tuning": "visual_roll_fraction",
		"hint": "how far the world tips when you bank",
	},
	{
		"key": "turning_comfort", "label": "VIEW TURNING", "kind": Kind.CHOICE,
		"choices": ["SMOOTH", "EASED", "STEPPED"], "default": 0.0,
		"tuning": "turning_comfort",
		"hint": "smooth, rate-limited, or in steps",
	},
	{
		"key": "tilt_sensitivity", "label": "TURN SENSITIVITY", "kind": Kind.NUMBER,
		"min": 0.5, "max": 1.6, "step": 0.1, "default": 1.0,
		"tuning": "tilt_sensitivity",
		"hint": "how much wing tilt a turn takes",
	},
	{
		"key": "pointer_hand", "label": "POINTING HAND", "kind": Kind.CHOICE,
		"choices": ["LEFT", "RIGHT"], "default": 1.0,
		"hint": "which hand aims at menus",
	},
	{
		"key": "show_guide", "label": "PREY MARKER", "kind": Kind.FLAG,
		"default": 1.0,
		"hint": "the arrow pointing at your next meal",
	},
]

## Not shown on the settings panel: state the game keeps about the player rather
## than a preference they set. Persisted alongside the rest.
const MEMORY: Dictionary = {
	"learned": 0.0,
	"best_score": 0.0,
}

var _values: Dictionary = {}


func _init() -> void:
	restore_defaults()
	for key: String in MEMORY:
		_values[key] = float(MEMORY[key])


static func spec(key: String) -> Dictionary:
	for entry: Dictionary in SPECS:
		if String(entry["key"]) == key:
			return entry
	return {}


func restore_defaults() -> void:
	for entry: Dictionary in SPECS:
		_values[String(entry["key"])] = float(entry["default"])


func has(key: String) -> bool:
	return _values.has(key)


func get_value(key: String) -> float:
	return float(_values.get(key, 0.0))


func flag(key: String) -> bool:
	return get_value(key) >= 0.5


## Clamped and quantised on the way in, so nothing downstream ever has to
## wonder whether a setting is in range — including a settings file a player
## has edited by hand, which is the one input path this game cannot test for.
func set_value(key: String, value: float) -> void:
	if not is_finite(value):
		return
	var entry: Dictionary = spec(key)
	if entry.is_empty():
		if MEMORY.has(key):
			_values[key] = value
		return
	match int(entry["kind"]):
		Kind.NUMBER:
			var low: float = float(entry["min"])
			var high: float = float(entry["max"])
			var step: float = float(entry["step"])
			var snapped_value: float = snappedf(clampf(value, low, high), step)
			_values[key] = clampf(snapped_value, low, high)
		Kind.CHOICE:
			var count: int = (entry["choices"] as Array).size()
			_values[key] = float(clampi(int(round(value)), 0, count - 1))
		Kind.FLAG:
			_values[key] = 1.0 if value >= 0.5 else 0.0


## One nudge of a setting. Everything cycles, including the numbers.
##
## Wrapping a slider looks odd written down, and it is here for a specific
## reason: in a headset the only input this menu has is "press the row", so a
## number that stopped dead at its maximum would be a comfort setting a player
## could turn up and then never turn back down. Every value has to be reachable
## by pressing one thing repeatedly.
func adjust(key: String, direction: int) -> void:
	var entry: Dictionary = spec(key)
	if entry.is_empty() or direction == 0:
		return
	var current: float = get_value(key)
	match int(entry["kind"]):
		Kind.NUMBER:
			var low: float = float(entry["min"])
			var high: float = float(entry["max"])
			var step: float = float(entry["step"]) * signf(float(direction))
			var wanted: float = current + step
			if wanted > high + 0.0001:
				wanted = low
			elif wanted < low - 0.0001:
				wanted = high
			set_value(key, wanted)
		Kind.CHOICE:
			var count: int = (entry["choices"] as Array).size()
			set_value(key, float(posmod(int(current) + signi(direction), count)))
		Kind.FLAG:
			set_value(key, 0.0 if current >= 0.5 else 1.0)


## What the panel prints to the right of the label.
func value_text(key: String) -> String:
	var entry: Dictionary = spec(key)
	if entry.is_empty():
		return ""
	var current: float = get_value(key)
	match int(entry["kind"]):
		Kind.CHOICE:
			return String((entry["choices"] as Array)[int(current)])
		Kind.FLAG:
			return "ON" if current >= 0.5 else "OFF"
		_:
			# A range that starts at zero reads as a percentage of itself. One
			# that does not — turn sensitivity runs 0.5 to 1.6 — reads as a
			# multiplier, because "63%" for the default setting is a lie about
			# what normal is.
			if float(entry["min"]) > 0.0:
				return "%.1fx" % current
			if is_zero_approx(current):
				return "OFF"
			return "%d%%" % int(round(current / float(entry["max"]) * 100.0))


## Where a number sits in its range, 0..1, for the little fill bar. Choices and
## flags have no bar — a two-state thing drawn as a 50%-full bar is a lie.
func value_fraction(key: String) -> float:
	var entry: Dictionary = spec(key)
	if entry.is_empty() or int(entry["kind"]) != Kind.NUMBER:
		return -1.0
	var low: float = float(entry["min"])
	var high: float = float(entry["max"])
	if high <= low:
		return -1.0
	return clampf((get_value(key) - low) / (high - low), 0.0, 1.0)


## The subset that [Tuning] owns, keyed by its field names. Anything without a
## `tuning` entry is the UI's own business and never leaves this object.
func tuning_values() -> Dictionary:
	var out: Dictionary = {}
	for entry: Dictionary in SPECS:
		if entry.has("tuning"):
			out[String(entry["tuning"])] = get_value(String(entry["key"]))
	return out


func pointer_is_right_handed() -> bool:
	return get_value("pointer_hand") >= 0.5


# --- persistence -------------------------------------------------------------

## Comfort settings that reset every launch are worse than no comfort settings:
## a player who has found the vignette strength that stops them feeling ill has
## to find it again every time, and will stop looking.
func save(path: String = FILE_PATH) -> bool:
	var config := ConfigFile.new()
	for key: String in _values:
		config.set_value(SECTION, key, get_value(key))
	return config.save(path) == OK


func load_from(path: String = FILE_PATH) -> bool:
	var config := ConfigFile.new()
	if config.load(path) != OK:
		return false
	for key: String in _values.keys():
		if config.has_section_key(SECTION, key):
			set_value(key, float(config.get_value(SECTION, key, get_value(key))))
	return true
