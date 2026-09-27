class_name HowToScreen
extends UIScreen
## How to fly: one illustrated gesture at a time. Tabs down the left, a big
## animated card and a short caption on the right. Captions stay under ~75
## characters so they fit three lines of body text (tested).

## "keys": the caption on the desktop (DesktopPoseSource's keys; integration
## round 2: the Buttons tab said "Flying needs no buttons" there too, and no
## screen named a key).
const CARDS := [
	{"id": &"flap", "tab": "Flap", "title": "Flap to climb",
		"text": "Sweep both arms down hard. Tip the wings forward to push ahead too.",
		"keys": "Hold Space to flap; a tap is one beat. Hold W as you flap to go ahead."},
	{"id": &"glide", "tab": "Glide", "title": "Glide",
		"text": "Hold your arms out wide and still. Trade height for distance.",
		"keys": "Let go of every key: wings out and still. Trade height for distance."},
	{"id": &"speed", "tab": "Speed", "title": "Speed and balloon",
		"text": "Twist both wrists. Edge up: balloon, then slow. Edge down: go faster.",
		"keys": "W tips the wings down: faster. S tips them up: balloon. Held, S stalls."},
	{"id": &"turn", "tab": "Turn", "title": "Bank to turn",
		"text": "Left edge up, right edge down banks right. Dipping one arm works too.",
		"keys": "A banks left, D banks right. Q or E beats one wing for a sharp turn."},
	{"id": &"dive", "tab": "Dive", "title": "Tuck to dive",
		"text": "Pull your arms in to fall fast. Spread them again to pull out.",
		"keys": "Hold Shift to pull the wings in and fall fast. Let go to pull out."},
	{"id": &"perch", "tab": "Perch", "title": "Perch",
		"text": "Glide in slowly onto a branch, wire or ledge to cling. Flap to leave.",
		"keys": "Glide in slowly onto a branch, wire or ledge to cling. Space to leave."},
	{"id": &"hunt", "tab": "Hunt", "title": "Eat or be eaten",
		"text": "Catch birds smaller than you and grow. Flee the bigger ones."},
	{"id": &"controls", "tab": "Buttons", "title": "Buttons",
		"text": "Flying needs no buttons. They are only for menus.",
		"keys": "Space flap, W/S tilt, A/D bank, Shift dive, mouse look, Esc menu."},
]

## Desktop captions ("keys") instead of the headset's (UIRoot.set_vr_mode).
var desktop := false

var _card: GestureCard
var _title: Label
var _text: Label
var _tabs := {}
var current := 0


func build() -> void:
	var m := margin_box()
	var col := vbox(16)
	m.add_child(col)
	var top := hbox()
	col.add_child(top)
	top.add_child(make_label("How to fly", &"TitleLabel"))
	top.add_child(spacer(false))
	var back := make_button(&"back", "Back", 92)
	back.custom_minimum_size.x = 220
	back.alignment = HORIZONTAL_ALIGNMENT_CENTER
	top.add_child(back)

	var row := hbox(40)
	row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(row)
	var tabs := vbox(6)
	tabs.custom_minimum_size = Vector2(290, 0)
	row.add_child(tabs)
	var group := ButtonGroup.new()
	for i in CARDS.size():
		var c: Dictionary = CARDS[i]
		var b := make_button(StringName("tab_%s" % c["id"]), c["tab"], 76)
		b.theme_type_variation = &"TabButton"
		b.toggle_mode = true
		b.button_group = group
		var idx := i
		b.pressed.connect(func() -> void: show_card(idx))
		tabs.add_child(b)
		_tabs[i] = b

	var right := vbox(10)
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(right)
	_title = make_label("", &"AccentLabel", UITheme.FS_TITLE)
	right.add_child(_title)
	_card = GestureCard.new()
	_card.name = "Card"
	_card.custom_minimum_size = Vector2(0, 336)
	right.add_child(_card)
	_text = make_label("")
	_text.name = "Caption"
	_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	# Three lines of body text (line box = 60 px x 1.36 - LINE_TIGHTEN).
	_text.custom_minimum_size = Vector2(0, 3 * 73)
	right.add_child(_text)
	show_card(0)


func show_card(i: int) -> void:
	current = clampi(i, 0, CARDS.size() - 1)
	var c: Dictionary = CARDS[current]
	_title.text = c["title"]
	_text.text = c.get("keys", c["text"]) if desktop else c["text"]
	_card.set_art(c["id"])
	# set_pressed_no_signal bypasses the ButtonGroup, so clear the others.
	for i2 in _tabs:
		(_tabs[i2] as Button).set_pressed_no_signal(i2 == current)


func refresh(_ctx: Dictionary) -> void:
	show_card(current)


func set_desktop(on: bool) -> void:
	desktop = on
	if _text != null:
		show_card(current)


func first_focus() -> Control:
	return _tabs[current]
