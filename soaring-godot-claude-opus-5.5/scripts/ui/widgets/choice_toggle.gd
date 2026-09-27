class_name ChoiceToggle
extends HBoxContainer
## A segmented choice ("Standing | Seated"): toggle Buttons in one group, the
## selected one filled with the accent. Buttons reuse the theme, so hover and
## focus look like every other button.

signal selected(value: String)

var _buttons := {}
var _group := ButtonGroup.new()
var value := ""


func setup(options: Array, labels: Array) -> void:
	add_theme_constant_override("separation", 10)
	for i in options.size():
		var b := Button.new()
		b.name = "Opt_%s" % options[i]
		b.text = labels[i]
		b.toggle_mode = true
		b.button_group = _group
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.custom_minimum_size = Vector2(0, 90)
		b.alignment = HORIZONTAL_ALIGNMENT_CENTER
		var v: String = options[i]
		b.pressed.connect(func() -> void: _on_pressed(v))
		add_child(b)
		_buttons[v] = b


## Show `v` as the selected option. set_pressed_no_signal bypasses the
## ButtonGroup, so the other options are released here explicitly (a value
## changed elsewhere, e.g. by VR calibration, must never leave two lit).
func set_value(v: String) -> void:
	value = v
	for k: String in _buttons:
		(_buttons[k] as Button).set_pressed_no_signal(k == v)


func get_option_button(v: String) -> Button:
	return _buttons.get(v)


func _on_pressed(v: String) -> void:
	if v == value:
		return
	value = v
	selected.emit(v)
