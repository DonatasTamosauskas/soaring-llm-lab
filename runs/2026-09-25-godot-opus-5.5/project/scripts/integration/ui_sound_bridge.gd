class_name UISoundBridge
extends Node
## Gives the menus their sounds (integration): the UI area's screens emit
## semantic actions and its buttons receive hover events; the audio area's
## AudioDirector has the sounds (`play_ui(kind)`, each at its own level).
## Neither area knows the other, so this node connects them.
##
## Pause open/close are already played by the director on Game state
## changes; actions that only change that state (Resume) stay silent here
## so nothing sounds twice.

## What each UIScreen action sounds like (missing: silent).
const ACTION_SOUND := {
	&"play": &"confirm", &"again": &"confirm", &"keep_flying": &"confirm",
	&"restart": &"confirm", &"quit_menu": &"confirm",
	&"menu": &"select", &"back": &"back",
	&"howto": &"open", &"settings": &"open",
	&"quit": &"close",
	&"skip_tutorial": &"select", &"recalibrate": &"select",
	&"recenter": &"select", &"replay_tutorial": &"select",
}
## Two hover sounds closer than this are one (a pointer sweeping a column
## of buttons must not rattle).
const HOVER_GAP_MS := 90

var ui: Node
var audio: Node
## Sounds played, by kind (tests).
var played := {}
var _last_hover_ms := -100000


func _init() -> void:
	name = "UISounds"
	process_mode = Node.PROCESS_MODE_ALWAYS


## Wires every screen of `p_ui` (a UIRoot) to `p_audio` (an AudioDirector).
func attach(p_ui: Node, p_audio: Node) -> void:
	ui = p_ui
	audio = p_audio
	var screens: Dictionary = ui.get(&"screens") if ui != null else {}
	for id in screens:
		var s: Node = screens[id]
		if s.has_signal(&"action") and not s.is_connected(&"action", _on_action):
			s.connect(&"action", _on_action)
		for c in s.find_children("*", "BaseButton", true, false):
			var b := c as BaseButton
			if not b.mouse_entered.is_connected(_on_hover):
				b.mouse_entered.connect(_on_hover.bind(b))
		for c in s.find_children("*", "", true, false):
			# Settings widgets (segment bars, choice toggles): a click each.
			if c.has_signal(&"value_changed") and not (c is BaseButton) and not c.is_connected(&"value_changed", _on_value):
				c.connect(&"value_changed", _on_value)
			if c.has_signal(&"selected") and not c.is_connected(&"selected", _on_choice):
				c.connect(&"selected", _on_choice)


func _on_action(id: StringName) -> void:
	var kind: StringName = ACTION_SOUND.get(id, &"")
	if kind != &"":
		_play(kind)


func _on_hover(b: BaseButton) -> void:
	if b.disabled or not b.is_visible_in_tree():
		return
	var now := Time.get_ticks_msec()
	if now - _last_hover_ms < HOVER_GAP_MS:
		return
	_last_hover_ms = now
	_play(&"hover")


func _on_value(_v: Variant = null) -> void:
	_play(&"click")


func _on_choice(_v: Variant = null) -> void:
	_play(&"click")


func _play(kind: StringName) -> void:
	played[kind] = int(played.get(kind, 0)) + 1
	if audio != null and is_instance_valid(audio) and audio.has_method(&"play_ui"):
		audio.call(&"play_ui", kind)
