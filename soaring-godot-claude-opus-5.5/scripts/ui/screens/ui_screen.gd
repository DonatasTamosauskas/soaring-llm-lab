class_name UIScreen
extends Control
## Base for every menu screen. Screens are plain Controls built in code; they
## never talk to the game directly: buttons emit `action(id)` and UIRoot
## decides what that means. Data comes in through refresh(ctx).

signal action(id: StringName)

## Pointer and desktop mouse are only offered on interactive screens.
var interactive := true
var border_color := Color(UITheme.ACCENT, 0.9)
var background: FacetBackground
var _buttons := {}
var _built := false


func _init() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _ready() -> void:
	ensure_built()


func ensure_built() -> void:
	if _built:
		return
	_built = true
	background = FacetBackground.new()
	background.name = "Background"
	background.border_color = border_color
	background.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(background)
	build()


## Override: create child Controls.
func build() -> void:
	pass


## Override: update from game data. ctx keys are documented in UIRoot.context().
func refresh(_ctx: Dictionary) -> void:
	pass


## The Control keyboard/gamepad focus starts on (desktop convenience).
func first_focus() -> Control:
	for id in _buttons:
		var b: Button = _buttons[id]
		if b.visible and not b.disabled:
			return b
	return null


func get_button(id: StringName) -> Button:
	return _buttons.get(id)


func button_ids() -> Array:
	return _buttons.keys()


# --- builders ---------------------------------------------------------------

## Standard padded content box inside the facet background.
func margin_box(h: int = 60, v: int = 44) -> MarginContainer:
	var m := MarginContainer.new()
	m.name = "Margin"
	m.set_anchors_preset(Control.PRESET_FULL_RECT)
	m.mouse_filter = Control.MOUSE_FILTER_IGNORE
	m.add_theme_constant_override("margin_left", h)
	m.add_theme_constant_override("margin_right", h)
	m.add_theme_constant_override("margin_top", v)
	m.add_theme_constant_override("margin_bottom", v)
	add_child(m)
	return m


## hold_hint != "": a HoldButton that acts only after being held (for
## actions that discard a run); the hint is what it says on a short pull.
func make_button(id: StringName, text: String, min_h: float = 90.0, primary := false, hold_hint := "") -> Button:
	var b: Button = HoldButton.new() if hold_hint != "" else Button.new()
	b.name = "Btn_%s" % id
	b.text = text
	b.custom_minimum_size = Vector2(0, min_h)
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.focus_mode = Control.FOCUS_ALL
	set_primary(b, primary)
	if b is HoldButton:
		(b as HoldButton).hint = hold_hint
		(b as HoldButton).held.connect(func() -> void: action.emit(id))
	else:
		b.pressed.connect(func() -> void: action.emit(id))
	_buttons[id] = b
	return b


## The main action of a screen: accent fill, ink text (off = the theme's
## ordinary button). Screens whose main action changes switch it.
static func set_primary(b: Button, on: bool) -> void:
	if on:
		b.add_theme_stylebox_override("normal", UITheme.box(UITheme.ACCENT, 0, Color.TRANSPARENT, UITheme.CHAMFER, Vector4(28, 8, 28, 10)))
		b.add_theme_stylebox_override("hover", UITheme.box(UITheme.ACCENT.lightened(0.2), 6, UITheme.TEXT, UITheme.CHAMFER, Vector4(28, 8, 28, 10)))
		b.add_theme_color_override("font_color", UITheme.INK)
		b.add_theme_color_override("font_hover_color", UITheme.INK)
		b.add_theme_color_override("font_focus_color", UITheme.INK)
	else:
		for sb in ["normal", "hover"]:
			b.remove_theme_stylebox_override(sb)
		for c in ["font_color", "font_hover_color", "font_focus_color"]:
			b.remove_theme_color_override(c)


static func make_label(text: String, variation: StringName = &"", size: int = 0) -> Label:
	var l := Label.new()
	l.text = text
	if variation != &"":
		l.theme_type_variation = variation
	if size > 0:
		l.add_theme_font_size_override("font_size", size)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


static func vbox(sep: int = 14) -> VBoxContainer:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", sep)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return v


static func hbox(sep: int = 16) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", sep)
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return h


static func spacer(expand_v := true) -> Control:
	var c := Control.new()
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if expand_v:
		c.size_flags_vertical = Control.SIZE_EXPAND_FILL
	else:
		c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return c


## "3:07" style time.
static func format_time(seconds: float) -> String:
	var s := maxi(0, int(round(seconds)))
	return "%d:%02d" % [s / 60, s % 60]


## "12 450": thin grouping keeps big scores readable at a glance.
static func format_int(v: int) -> String:
	var s := str(absi(v))
	var out := ""
	while s.length() > 3:
		out = " " + s.substr(s.length() - 3) + out
		s = s.substr(0, s.length() - 3)
	return ("-" if v < 0 else "") + s + out


static func species_name(id: Variant) -> String:
	var d := SizeRules.species_data(StringName(str(id)))
	return d.get("name", str(id).capitalize())


## "a Hawk", "an Eagle": the article a noun takes (by its first letter,
## which is right for every species name in the ladder).
static func a_an(noun: String) -> String:
	return ("an " if noun.substr(0, 1).to_lower() in ["a", "e", "i", "o", "u"] else "a ") + noun


## Largest font size <= start (and >= min_size) at which `text` fits max_w
## px (headlines that carry a species name or a big number).
static func fit_size(font: Font, text: String, start: int, min_size: int, max_w: float) -> int:
	var sz := start
	while sz > min_size and font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, sz).x > max_w:
		sz -= 2
	return maxi(sz, min_size)
