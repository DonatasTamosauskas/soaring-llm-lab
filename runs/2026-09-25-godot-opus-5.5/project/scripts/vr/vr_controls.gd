class_name VRControls
extends Node
## Controller buttons -> game intents, and analog trigger/grip for UI and
## perching. Lives under the VR autoload (PROCESS_MODE_ALWAYS), reads the
## OpenXR controller trackers directly, so it works in every scene and never
## depends on the player rig's node names.
##
## The body does the flying; buttons are only for discrete intents
## (flight_vr.md §5.3). Action names are those of openxr_action_map.tres.
##
## | input                        | intent                                   |
## |------------------------------|------------------------------------------|
## | menu (left ≡; the right one  | Events.menu_requested (pause / resume)   |
## |  is the system button)       |                                          |
## | B (right by_button) hold 0.8 s | Events.menu_requested while flying:    |
## |                              | a pause for right-handed players         |
## |                              | (short B/Y press = Back, owned by UI)    |
## | A or X hold 1.0 s            | Events.recenter_requested                |
## | Y (left by_button) hold 1.5 s| recalibrate_requested (the calibration |
## |                              | step; a B/Y press cancels its card)      |
## | trigger (analog)             | trigger(hand); trigger_changed on 0.6/0.4|
## | grip (analog)                | grip(hand); grip_changed on 0.6/0.4      |

signal button_changed(hand: StringName, action: StringName, pressed: bool)
signal long_pressed(hand: StringName, action: StringName)
signal trigger_changed(hand: StringName, pressed: bool)
signal grip_changed(hand: StringName, pressed: bool)
signal recalibrate_requested()

const HANDS: Array[StringName] = [&"left_hand", &"right_hand"]
const BUTTONS: Array[StringName] = [&"menu_button", &"ax_button", &"by_button", &"primary_click"]
const ANALOG_ON := 0.6
const ANALOG_OFF := 0.4
const HOLD_PAUSE := 0.8
const HOLD_RECENTER := 1.0
const HOLD_RECALIBRATE := 1.5

## Reads one input: Callable(hand: StringName, action: StringName) -> Variant
## (bool for buttons, float for analog, null when absent). Tests inject a
## fake. Left empty (the default), inputs are read straight from XRServer's
## controller trackers: one tracker lookup per hand per frame (fix round 6:
## the default used to be a sentinel Callable whose body never ran, since
## tick() compared against it and took the inline path).
var reader: Callable
## Tests set false and call tick(dt) themselves.
@export var auto_tick := true
## Emit the intents on the Events bus (tests may only watch the signals).
@export var emit_events := true

var _down_a: Array[bool] = [false, false, false, false, false, false, false, false]
var _held_a: Array[float] = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
var _fired_a: Array[bool] = [false, false, false, false, false, false, false, false]
var _trigger: Array[float] = [0.0, 0.0]
var _grip: Array[float] = [0.0, 0.0]
var _trigger_down: Array[bool] = [false, false]
var _grip_down: Array[bool] = [false, false]
## A hand with no tracker whose buttons and axes all read released already:
## reading it again changes nothing (skipped: fix round 5, 8 of the area's
## ~75 us a frame went to re-reading absent controllers).
var _idle: Array[bool] = [false, false]


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func _process(delta: float) -> void:
	if auto_tick:
		var t0 := VRProfile.begin()
		tick(delta)
		VRProfile.add(&"controls", t0)


func trigger(hand: StringName) -> float:
	return _trigger[HANDS.find(hand)] if hand in HANDS else 0.0


func grip(hand: StringName) -> float:
	return _grip[HANDS.find(hand)] if hand in HANDS else 0.0


func is_trigger_down(hand: StringName) -> bool:
	return _trigger_down[HANDS.find(hand)] if hand in HANDS else false


func is_grip_down(hand: StringName) -> bool:
	return _grip_down[HANDS.find(hand)] if hand in HANDS else false


func is_pressed(hand: StringName, action: StringName) -> bool:
	var i := HANDS.find(hand)
	var b := BUTTONS.find(action)
	return i >= 0 and b >= 0 and _down_a[i * BUTTONS.size() + b]


func tick(dt: float) -> void:
	var fast := not reader.is_valid()
	var nb := BUTTONS.size()
	for i in 2:
		var hand := HANDS[i]
		# Fast path: one tracker lookup per hand per frame and direct reads;
		# no tracker (desktop, controller asleep) reads as all released.
		var t: XRPositionalTracker = XRServer.get_tracker(hand) as XRPositionalTracker if fast else null
		if fast and t == null:
			if _idle[i]:
				continue
		else:
			_idle[i] = false
		for b in nb:
			var action := BUTTONS[b]
			var idx := i * nb + b
			var v: Variant = (t.get_input(action) if t != null else null) if fast else reader.call(hand, action)
			var now := _as_bool(v)
			if now != _down_a[idx]:
				_down_a[idx] = now
				_held_a[idx] = 0.0
				_fired_a[idx] = false
				button_changed.emit(hand, action, now)
				if now:
					_on_press(hand, action)
			elif now:
				_held_a[idx] += dt
				_check_hold(hand, action, _held_a[idx], idx)
		_update_analog(i, hand, t, fast)
		# Everything now reads released on a hand without a tracker.
		_idle[i] = fast and t == null


func _read(t: XRPositionalTracker, fast: bool, hand: StringName, action: StringName) -> Variant:
	if fast:
		return t.get_input(action) if t != null else null
	return reader.call(hand, action)


func _update_analog(i: int, hand: StringName, tr: XRPositionalTracker, fast: bool) -> void:
	var t := maxf(_as_float(_read(tr, fast, hand, &"trigger")), 1.0 if _as_bool(_read(tr, fast, hand, &"trigger_click")) else 0.0)
	var g := maxf(_as_float(_read(tr, fast, hand, &"grip")), 1.0 if _as_bool(_read(tr, fast, hand, &"grip_click")) else 0.0)
	_trigger[i] = t
	_grip[i] = g
	var td: bool = _trigger_down[i]
	if (not td and t >= ANALOG_ON) or (td and t <= ANALOG_OFF):
		_trigger_down[i] = not td
		trigger_changed.emit(hand, not td)
	var gd: bool = _grip_down[i]
	if (not gd and g >= ANALOG_ON) or (gd and g <= ANALOG_OFF):
		_grip_down[i] = not gd
		grip_changed.emit(hand, not gd)


func _on_press(_hand: StringName, action: StringName) -> void:
	if action == &"menu_button" and emit_events:
		# UI de-duplicates presses it also saw itself (250 ms), so both may emit.
		Events.menu_requested.emit()


func _check_hold(hand: StringName, action: StringName, held: float, idx: int) -> void:
	if _fired_a[idx]:
		return
	var need := -1.0
	match action:
		&"ax_button":
			need = HOLD_RECENTER
		&"by_button":
			need = HOLD_PAUSE if hand == &"right_hand" else HOLD_RECALIBRATE
	if need < 0.0 or held < need:
		return
	_fired_a[idx] = true
	long_pressed.emit(hand, action)
	match action:
		&"ax_button":
			if emit_events:
				Events.recenter_requested.emit()
		&"by_button":
			if hand == &"right_hand":
				# Only as a pause, and only in play: in a menu B is Back (a
				# toggle would resume), and in BOOT UI would turn the request
				# into the main menu.
				if emit_events and Game.state in [Game.State.PLAYING, Game.State.CAUGHT]:
					Events.menu_requested.emit()
			else:
				recalibrate_requested.emit()


static func _as_bool(v: Variant) -> bool:
	if v == null:
		return false
	if v is bool:
		return v
	if v is float or v is int:
		return float(v) >= 0.5
	return false


static func _as_float(v: Variant) -> float:
	if v == null:
		return 0.0
	if v is float or v is int:
		return float(v)
	if v is bool:
		return 1.0 if v else 0.0
	return 0.0

