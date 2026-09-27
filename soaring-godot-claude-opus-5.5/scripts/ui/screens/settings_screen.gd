class_name SettingsScreen
extends UIScreen
## Settings, one row per setting: comfort and audio as stepped bars (label,
## bar, value), then stance and pointer hand as segmented choices, then the
## actions (recalibrate, recenter, replay tutorial) with a status line that
## says what an action just did. Every change is written straight to
## Settings (which persists and emits Events.settings_changed), so there is
## no Apply button to forget.

## Bars: settings key, label, steps. "Turn speed" (integration round 2) is
## flight's turn-rate comfort cap (FlightTuning.TURN_COMFORT_RATES: Gentle
## 90, Calm 120, Brisk 180, Full 240 deg/s), shown by name.
const BARS := [
	["comfort_vignette", "Comfort vignette", 5],
	["turn_comfort", "Turn speed", 4],
	["master_volume", "Master volume", 10],
	["music_volume", "Music volume", 10],
	["haptics", "Haptics", 5],
]
## Width of the label column: the longest label at body size, plus a hair.
const LABEL_W := 480.0
const VALUE_W := 170.0
## Seconds a status message stays up.
const STATUS_TIME := 4.0
## What each action says it did. Each fits the slot beside "Replay
## tutorial" at body size (ui_legibility_test checks every one in place).
const STATUS_RECALIBRATE := "Recalibration started"
const STATUS_RECENTER := "View recentered"
const STATUS_REPLAY := "Tutorial on next flight"
const STATUS_TEXTS: Array[String] = [STATUS_RECALIBRATE, STATUS_RECENTER, STATUS_REPLAY]

var _bars := {}
var _values := {}
var _stance: ChoiceToggle
var _hand: ChoiceToggle
var _status: Label
var _status_left := 0.0


func build() -> void:
	var m := margin_box()
	# (Rows 8 px apart and the action buttons 82 px tall since the Turn speed
	# bar joined in integration round 2: the column is 812 px.)
	var col := vbox(8)
	m.add_child(col)
	var top := hbox()
	col.add_child(top)
	top.add_child(make_label("Settings", &"TitleLabel"))
	top.add_child(spacer(false))
	var back := make_button(&"back", "Back", 92)
	back.custom_minimum_size.x = 220
	back.alignment = HORIZONTAL_ALIGNMENT_CENTER
	top.add_child(back)

	for spec in BARS:
		var key: String = spec[0]
		var row := hbox(16)
		col.add_child(row)
		var name_l := make_label(spec[1])
		name_l.custom_minimum_size.x = LABEL_W
		name_l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		row.add_child(name_l)
		var bar := SegmentBar.new()
		bar.name = "Bar_%s" % key
		bar.steps = spec[2]
		# A turn speed of zero means nothing: the gentlest step is the floor.
		bar.allow_zero = key != "turn_comfort"
		bar.custom_minimum_size = Vector2(0, 64)
		bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		bar.value_changed.connect(func(v: float) -> void: _on_bar(key, v))
		row.add_child(bar)
		_bars[key] = bar
		var val := make_label("", &"AccentLabel")
		val.custom_minimum_size.x = VALUE_W
		val.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		val.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		row.add_child(val)
		_values[key] = val

	# Natural widths (577 + 201 + 389 px + gaps): exactly fits the content
	# width, so the two segmented choices never crowd the panel edge.
	var choices := hbox(16)
	col.add_child(choices)
	# "Standing | Seated" explains itself; no label needed.
	_stance = ChoiceToggle.new()
	_stance.name = "Stance"
	_stance.setup(["standing", "seated"], ["Standing", "Seated"])
	_stance.selected.connect(func(v: String) -> void: _store(&"seated", v == "seated"))
	choices.add_child(_stance)
	choices.add_child(spacer(false))
	var hand_l := make_label("Pointer")
	hand_l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	choices.add_child(hand_l)
	_hand = ChoiceToggle.new()
	_hand.name = "Hand"
	_hand.setup(["left", "right"], ["Left", "Right"])
	_hand.selected.connect(func(v: String) -> void: _store(&"handedness", v))
	choices.add_child(_hand)

	var actions := hbox(24)
	col.add_child(actions)
	for spec: Array in [[&"recalibrate", "Recalibrate wings"], [&"recenter", "Recenter view"]]:
		var b := make_button(spec[0], spec[1], 82)
		b.alignment = HORIZONTAL_ALIGNMENT_CENTER
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		actions.add_child(b)
	var last := hbox(24)
	col.add_child(last)
	var replay := make_button(&"replay_tutorial", "Replay tutorial", 82)
	replay.alignment = HORIZONTAL_ALIGNMENT_CENTER
	replay.custom_minimum_size.x = 500
	last.add_child(replay)
	_status = make_label("", &"AccentLabel")
	_status.name = "Status"
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	# Never widens its row: a message too long for the slot would push Back,
	# the percentages and "Right" off the panel (round 3). It is trimmed
	# instead, and the messages are chosen so none needs trimming.
	_status.clip_text = true
	_status.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	last.add_child(_status)


func refresh(_ctx: Dictionary) -> void:
	for spec in BARS:
		var key: String = spec[0]
		var v := float(Settings.get_value(key, 0.5))
		(_bars[key] as SegmentBar).set_value_no_signal(v)
		_show_value(key, v)
	_stance.set_value("seated" if bool(Settings.get_value("seated", false)) else "standing")
	_hand.set_value(str(Settings.get_value("handedness", "right")))


## Say what an action just did (the buttons themselves have no visible
## result otherwise). Clears after STATUS_TIME.
func show_status(text: String) -> void:
	_status.text = text
	_status_left = STATUS_TIME
	set_process(true)


func status_text() -> String:
	return _status.text


func status_label() -> Label:
	return _status


func _process(delta: float) -> void:
	advance(delta)


## Run the status line's clock by `delta` seconds (the frame loop calls it;
## tests drive it with synthetic time).
func advance(delta: float) -> void:
	if _status_left <= 0.0:
		set_process(false)
		return
	_status_left -= delta
	if _status_left <= 0.0:
		_status.text = ""


func _on_bar(key: String, v: float) -> void:
	_store(StringName(key), v)
	_show_value(key, v)


func _show_value(key: String, v: float) -> void:
	var l: Label = _values[key]
	if key == "turn_comfort":
		l.text = FlightTuning.TURN_COMFORT_NAMES[FlightTuning.turn_comfort_step(v)]
		return
	l.text = "Off" if v <= 0.001 else "%d%%" % int(round(v * 100.0))


func _store(key: StringName, v: Variant) -> void:
	Settings.set_value(String(key), v)


func get_bar(key: String) -> SegmentBar:
	return _bars.get(key)


func get_stance() -> ChoiceToggle:
	return _stance


func get_hand() -> ChoiceToggle:
	return _hand
