extends Control

signal launch_requested
signal resume_requested
signal restart_requested
signal calibrate_requested
signal comfort_changed(enabled: bool)
signal sound_changed(enabled: bool)
signal quit_requested

const INK := Color("102c32")
const PAPER := Color("f4eedc")
const MUTED := Color("b8cfc9")
const GOLD := Color("f4ba67")
const GREEN := Color("80dbb8")
var xr_mode := false
var state := "nest"
var previous_state := "nest"
var panel: PanelContainer
var title: Label
var subtitle: Label
var guide: Label
var primary: Button
var secondary: Button
var note: Label
var comfort: CheckButton
var sound: CheckButton
var settings: HBoxContainer
var calibration: Button
var calibration_row: HBoxContainer
var hud: Control
var tier_label: Label
var mass_label: Label
var speed_label: Label
var location_label: Label
var population_label: Label
var hint_label: Label
var toast_label: Label
var danger_label: Label
var progress: ProgressBar
var toast_left := 0.0

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build_theme()
	_build_menu()
	if not xr_mode:
		_build_hud()
	show_state("nest")

func _build_theme() -> void:
	var t := Theme.new()
	t.default_font_size = 22 if xr_mode else 19
	t.set_color("font_color", "Label", PAPER)
	t.set_color("font_color", "Button", PAPER)
	t.set_color("font_hover_color", "Button", INK)
	t.set_color("font_pressed_color", "Button", INK)
	t.set_color("font_color", "CheckButton", MUTED)
	t.set_stylebox("normal", "Button", _box(Color("23464b"), 12, 10))
	t.set_stylebox("hover", "Button", _box(GOLD, 12, 10))
	t.set_stylebox("pressed", "Button", _box(GREEN, 12, 10))
	t.set_stylebox("focus", "Button", _box(Color(0,0,0,0), 12, 10, GOLD))
	t.set_stylebox("background", "ProgressBar", _box(Color("284b50"), 4, 0))
	t.set_stylebox("fill", "ProgressBar", _box(GREEN, 4, 0))
	theme = t

func _box(color: Color, radius: int, padding: int, border := Color.TRANSPARENT) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = color
	box.set_corner_radius_all(radius)
	box.content_margin_left = padding
	box.content_margin_right = padding
	box.content_margin_top = padding
	box.content_margin_bottom = padding
	if border.a > 0:
		box.border_color = border
		box.set_border_width_all(2)
	return box

func _label(text: String, font_size: int, color := PAPER) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label

func _build_menu() -> void:
	panel = PanelContainer.new()
	panel.name = "FlightMenu"
	panel.add_theme_stylebox_override("panel", _box(Color(0.035,0.105,0.12,0.96), 22, 32))
	add_child(panel)
	if xr_mode:
		panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		panel.offset_left = 20
		panel.offset_top = 20
		panel.offset_right = -20
		panel.offset_bottom = -20
	else:
		panel.anchor_left = 0.04
		panel.anchor_top = 0.5
		panel.anchor_right = 0.04
		panel.anchor_bottom = 0.5
		panel.offset_top = -345
		panel.offset_bottom = 345
		panel.offset_right = 535
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 8)
	panel.add_child(column)
	var eyebrow := _label("THE WILD SKY    /    godot-sol", 19 if xr_mode else 14, GREEN)
	column.add_child(eyebrow)
	title = _label("SOARING", 70 if xr_mode else 66)
	column.add_child(title)
	subtitle = _label("Small wings. An enormous world.", 27 if xr_mode else 22, GOLD)
	column.add_child(subtitle)
	var line := HSeparator.new()
	line.modulate = Color(0.5,0.7,0.65,0.3)
	column.add_child(line)
	guide = _label("", 22 if xr_mode else 19, MUTED)
	guide.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	guide.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(guide)
	primary = Button.new()
	primary.name = "LaunchButton"
	primary.text = "TAKE FLIGHT   ↗"
	primary.custom_minimum_size.y = 58 if xr_mode else 50
	primary.add_theme_font_size_override("font_size", 28 if xr_mode else 22)
	primary.pressed.connect(_primary_pressed)
	column.add_child(primary)
	secondary = Button.new()
	secondary.text = "Flight field guide"
	secondary.custom_minimum_size.y = 42
	secondary.pressed.connect(_toggle_guide)
	column.add_child(secondary)
	settings = HBoxContainer.new()
	settings.add_theme_constant_override("separation", 10)
	column.add_child(settings)
	comfort = CheckButton.new()
	comfort.text = "Comfort"
	comfort.button_pressed = true
	comfort.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	comfort.toggled.connect(func(on: bool): comfort_changed.emit(on))
	settings.add_child(comfort)
	sound = CheckButton.new()
	sound.text = "Sound"
	sound.button_pressed = true
	sound.toggled.connect(func(on: bool): sound_changed.emit(on))
	settings.add_child(sound)
	calibration = Button.new()
	calibration.text = "Calibrate wings (2s)" if xr_mode else "Return to nest / restart"
	calibration.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	calibration.pressed.connect(func():
		if xr_mode: calibrate_requested.emit()
		else: restart_requested.emit())
	calibration_row = HBoxContainer.new()
	calibration_row.add_theme_constant_override("separation",8)
	column.add_child(calibration_row)
	calibration_row.add_child(calibration)
	if xr_mode:
		var restart := Button.new()
		restart.text = "Restart"
		restart.pressed.connect(func(): restart_requested.emit())
		calibration_row.add_child(restart)
	note = _label("", 16 if xr_mode else 13, MUTED)
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(note)

func _build_hud() -> void:
	hud = Control.new()
	hud.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(hud)
	var top := PanelContainer.new()
	top.position = Vector2(30, 25)
	top.custom_minimum_size = Vector2(290, 110)
	top.add_theme_stylebox_override("panel", _box(Color(0.04,0.12,0.14,0.84), 14, 17))
	hud.add_child(top)
	var c := VBoxContainer.new()
	top.add_child(c)
	c.add_child(_label("S O A R I N G", 13, GREEN))
	tier_label = _label("WREN", 29)
	c.add_child(tier_label)
	mass_label = _label("1.00  /  0 catches", 15, MUTED)
	c.add_child(mass_label)
	progress = ProgressBar.new()
	progress.custom_minimum_size.y = 5
	progress.show_percentage = false
	c.add_child(progress)
	var top_right := VBoxContainer.new()
	top_right.anchor_left = 1.0
	top_right.anchor_right = 1.0
	top_right.offset_left = -280
	top_right.offset_right = -30
	top_right.offset_top = 28
	hud.add_child(top_right)
	population_label = _label("54 BIRDS  •  ONE LIVING SKY", 13, PAPER)
	population_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	top_right.add_child(population_label)
	var pause_hint := _label("ESC  Pause     C  Calibrate", 13, MUTED)
	pause_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	top_right.add_child(pause_hint)
	var bottom := VBoxContainer.new()
	bottom.anchor_top = 1.0
	bottom.anchor_bottom = 1.0
	bottom.offset_left = 30
	bottom.offset_top = -100
	bottom.offset_right = 440
	bottom.offset_bottom = -20
	hud.add_child(bottom)
	speed_label = _label("0.0 M/S", 34)
	bottom.add_child(speed_label)
	location_label = _label("18 M    /    THE NEST", 15, MUTED)
	bottom.add_child(location_label)
	hint_label = _label("", 16, PAPER)
	hint_label.anchor_left = 0.5
	hint_label.anchor_right = 0.5
	hint_label.anchor_top = 1.0
	hint_label.anchor_bottom = 1.0
	hint_label.offset_left = -330
	hint_label.offset_right = 330
	hint_label.offset_top = -56
	hint_label.offset_bottom = -22
	hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hud.add_child(hint_label)
	toast_label = _label("", 25, GOLD)
	toast_label.anchor_left = 0.5
	toast_label.anchor_right = 0.5
	toast_label.offset_left = -450
	toast_label.offset_right = 450
	toast_label.offset_top = 90
	toast_label.offset_bottom = 145
	toast_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hud.add_child(toast_label)
	danger_label = _label("", 19, Color("ffac92"))
	danger_label.anchor_left = 0.5
	danger_label.anchor_right = 0.5
	danger_label.anchor_top = 1.0
	danger_label.anchor_bottom = 1.0
	danger_label.offset_left = -400
	danger_label.offset_right = 400
	danger_label.offset_top = -100
	danger_label.offset_bottom = -65
	danger_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hud.add_child(danger_label)
	for label in [population_label, pause_hint, speed_label, location_label, hint_label, toast_label, danger_label]:
		label.add_theme_color_override("font_outline_color", INK)
		label.add_theme_constant_override("outline_size", 5)

func show_state(new_state: String, details := "") -> void:
	state = new_state
	title.add_theme_font_size_override("font_size", 70 if xr_mode else 66)
	panel.visible = state != "flying"
	if hud: hud.visible = state == "flying"
	secondary.text = "Flight field guide"
	secondary.visible = state != "guide"
	settings.visible = state != "guide"
	calibration.visible = state != "guide"
	calibration_row.visible = state != "guide"
	note.visible = state != "guide"
	match state:
		"nest":
			title.text = "SOARING"
			subtitle.text = "Small wings. An enormous world."
			primary.text = "TAKE FLIGHT   ↗"
			guide.text = "Catch smaller birds. Outfly the larger ones.\nGrow from a wren into the ruler of the sky.\n\nRide warm rising air, thread open windows,\nand find a branch to rest your wings."
		"paused":
			title.text = "RESTING"
			title.add_theme_font_size_override("font_size", 70 if xr_mode else 66)
			subtitle.text = "The sky can wait."
			primary.text = "CONTINUE FLIGHT   ↗"
			guide.text = "Your flight and the flock are paused.\n\nKeep your elbows soft. Short downstrokes\ngive you lift; squeeze to glide with your\narms relaxed."
		"caught":
			title.text = "FLY AGAIN"
			title.add_theme_font_size_override("font_size", 65 if xr_mode else 59)
			subtitle.text = "A bigger bird caught your trail."
			primary.text = "FLY AGAIN   ↗"
			guide.text = details + "\n\nLose pursuers in the grove and narrow\nwindows. Catch birds closer to your size\nto grow faster."
		"guide":
			title.text = "FIELD GUIDE"
			title.add_theme_font_size_override("font_size", 61 if xr_mode else 51)
			subtitle.text = "Learn the language of the air."
			primary.text = "BACK"
			secondary.text = "Back to flight menu"
			guide.text = "DOWNSTROKE  •  Short flaps lift you up.\nSPREAD  •  More lift; tuck for a fast dive.\nTILT WRISTS  •  Pitch up or trade height for speed.\nONE WING LOW  •  Bank toward the lower wing.\nSQUEEZE  •  Relax your arms and keep gliding.\nTHERMALS  •  Golden spirals carry you upward.\nPERCH  •  Touch a ledge slowly to rest.\n\nTeal birds are prey. Coral birds are threats.\nA bird must be 18% larger to make a catch."
	if state == "nest": title.add_theme_font_size_override("font_size", 70 if xr_mode else 66)
	note.text = "Point + trigger to select • Left menu pauses • A flaps\nCalibrate with your elbows relaxed before taking off." if xr_mode else "SPACE flap • A/D bank • W/S pitch • SHIFT tuck\nCTRL brake • Q/E snap turn • Mouse look • ESC pause"
	primary.grab_focus()

func _primary_pressed() -> void:
	match state:
		"nest": launch_requested.emit()
		"paused": resume_requested.emit()
		"caught": restart_requested.emit()
		"guide": show_state(previous_state)

func _toggle_guide() -> void:
	if state == "guide": show_state(previous_state)
	else:
		previous_state = state
		show_state("guide")

func update_hud(stats: Dictionary, speed: float, altitude: float, zone: String, thermal: float) -> void:
	if not hud: return
	tier_label.text = str(stats.get("tier", "Wren")).to_upper()
	mass_label.text = "%.2f MASS   /   %d CATCHES" % [stats.get("mass",1.0), stats.get("catches",0)]
	progress.value = float(stats.get("progress",0.0)) * 100
	speed_label.text = "%.1f M/S" % speed
	location_label.text = "%d M   /   %s%s" % [int(altitude), zone.to_upper(), "   ↑ WARM AIR" if thermal > 0.2 else ""]
	population_label.text = "%d BIRDS  •  ONE LIVING SKY" % int(stats.get("population",54))
	danger_label.text = stats.get("danger_text", "")
	hint_label.text = "Squeeze to rest your arms while gliding" if xr_mode else "SPACE  Flap     SHIFT  Tuck     CTRL  Spread     A / D  Bank"
	if stats.get("perched",false): hint_label.text = "PERCHED  •  A short flap takes you back into the sky" if xr_mode else "PERCHED  •  SPACE to take flight"

func toast(message: String, seconds := 3.5) -> void:
	toast_left = seconds
	if toast_label: toast_label.text = message

func _process(dt: float) -> void:
	toast_left = maxf(0.0, toast_left - dt)
	if toast_label: toast_label.visible = toast_left > 0
