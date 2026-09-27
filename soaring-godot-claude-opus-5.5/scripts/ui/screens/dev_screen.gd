class_name DevScreen
extends UIScreen
## Developer menu (playtest build #1): flight-feel levers to try in the
## headset and report back. Every bar writes a 0..1 Settings key that
## PlayerBird._apply_settings maps to a real value (the label shows it), so
## changes apply live and persist. "Reset" restores Settings.DEFAULTS.

## [settings key, label, steps, formatter(v) -> String]
const BARS := [
	["dev_turn_deadzone", "Turn dead zone", 5],
	["dev_turn_sensitivity", "Turn sensitivity", 5],
	["dev_turn_curve", "Turn curve", 5],
	["dev_flap_power", "Flap power", 5],
	["dev_speed", "Speed / glide", 5],
	["dev_roll_rate", "Roll rate", 5],
]
## [settings key, label, off text, on text], two per row: tilt turning on/off,
## tilt direction normal/inverted, arm-height turning, glide pose T/relaxed.
const TOGGLES := [
	["dev_tilt_turn", "Tilt turn", "Off", "On"],
	["dev_tilt_invert", "Tilt dir", "Norm", "Inv"],
	["dev_arm_turn", "Arm turn", "Off", "On"],
	["dev_relaxed_glide", "Glide", "T", "Relax"],
]
const LABEL_W := 330.0
const VALUE_W := 170.0

var _bars := {}
var _values := {}
var _toggles := {}


func build() -> void:
	var m := margin_box()
	var col := vbox(2)
	m.add_child(col)
	var top := hbox()
	col.add_child(top)
	top.add_child(make_label("Developer", &"TitleLabel"))
	top.add_child(spacer(false))
	var reset := make_button(&"dev_reset", "Reset", 72)
	reset.custom_minimum_size.x = 180
	reset.pressed.connect(_reset)
	top.add_child(reset)
	var back := make_button(&"back", "Back", 72)
	back.custom_minimum_size.x = 180
	top.add_child(back)
	for spec in BARS:
		var key: String = spec[0]
		var row := hbox(16)
		col.add_child(row)
		var l := make_label(spec[1])
		l.custom_minimum_size.x = LABEL_W
		row.add_child(l)
		var bar := SegmentBar.new()
		bar.name = "Bar_%s" % key
		bar.steps = spec[2]
		bar.custom_minimum_size = Vector2(0, 46)
		bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		bar.value_changed.connect(func(v: float) -> void: _on_bar(key, v))
		row.add_child(bar)
		_bars[key] = bar
		var val := make_label("", &"AccentLabel")
		val.custom_minimum_size.x = VALUE_W
		val.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		row.add_child(val)
		_values[key] = val
	var row: HBoxContainer = null
	for i in TOGGLES.size():
		var spec: Array = TOGGLES[i]
		var key: String = spec[0]
		if i % 2 == 0:
			row = hbox(16)
			col.add_child(row)
		else:
			row.add_child(spacer(false))
		row.add_child(make_label(spec[1]))
		var t := ChoiceToggle.new()
		t.name = "Toggle_%s" % key
		t.setup(["off", "on"], [spec[2], spec[3]])
		t.selected.connect(func(v: String) -> void: Settings.set_value(key, v == "on"))
		row.add_child(t)
		_toggles[key] = t


func refresh(_ctx: Dictionary) -> void:
	for spec in BARS:
		var key: String = spec[0]
		var v := float(Settings.get_value(key, 0.5))
		(_bars[key] as SegmentBar).set_value_no_signal(v)
		_show(key, v)
	for spec in TOGGLES:
		var key: String = spec[0]
		(_toggles[key] as ChoiceToggle).set_value("on" if bool(Settings.get_value(key, false)) else "off")


func _on_bar(key: String, v: float) -> void:
	Settings.set_value(key, v)
	_show(key, v)


## The real value each bar sets (mirrors PlayerBird._apply_settings).
static func describe(key: String, v: float) -> String:
	match key:
		"dev_turn_deadzone":
			return "%d°" % roundi(20.0 * v)
		"dev_turn_sensitivity":
			return "full at %d°" % roundi(lerpf(70.0, 25.0, v))
		"dev_turn_curve":
			return "x^%.1f" % (1.0 + 2.0 * v)
		"dev_flap_power":
			return "x%.2f" % (0.5 + 2.0 * v)
		"dev_speed":
			return "x%.2f" % (0.8 + 0.8 * v)
		"dev_roll_rate":
			return "x%.2f" % (0.6 + 1.4 * v)
		"dev_stretch_bonus":
			return "+%d%%" % roundi(100.0 * v)
	return "%.2f" % v


func _show(key: String, v: float) -> void:
	(_values[key] as Label).text = describe(key, v)


func _reset() -> void:
	for spec in BARS + TOGGLES:
		Settings.set_value(spec[0], Settings.DEFAULTS[spec[0]])
	refresh({})
