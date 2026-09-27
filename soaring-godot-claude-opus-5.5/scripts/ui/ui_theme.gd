class_name UITheme
extends RefCounted
## The UI's look: palette, fonts, sizes and the Theme every screen uses.
##
## One place for every colour and size so legibility (glyph angle) and
## contrast can be computed and tested instead of eyeballed. The style is
## "low-poly flat": solid fills, chamfered (45 degree) corners instead of
## rounded ones, no gradients, no shadows.
##
## Sizes are in panel pixels. Panels are authored at PX_PER_M pixels per
## metre and shown at PANEL_DISTANCE metres (both times world_scale), so a
## font size maps to a fixed visual angle whatever the player's size.

# --- Geometry shared by panels and the legibility maths ---
## Panel texture density: 1 px = 1 mm at world_scale 1.
const PX_PER_M := 1000.0
## Distance from the eyes to a menu panel, metres at world_scale 1.
const PANEL_DISTANCE := 1.5
## Distance from the eyes to the HUD panel, metres at world_scale 1.
const HUD_DISTANCE := 1.5
## Menu panel size in px (= mm): 1.36 m x 0.90 m. Curved round the eye at
## 1.5 m that is 52 x 33 degrees: wide enough for two columns of 1.5-degree
## text, still inside the comfortable +-30 degree band of eye rotation.
const MENU_SIZE := Vector2i(1360, 900)
## HUD texture size in px: notices (lesson card, tier-up) in the top 344
## rows, the growth strip in the bottom 172; in VR the two are shown as
## separate bands (see HUD.bands()), far above and below the gaze.
const HUD_SIZE := Vector2i(1100, 540)

# --- Type scale (px). Every size here must clear MIN_GLYPH_DEG *where the
# text sits*: panels are curved round the eye, so a glyph loses angle only
# with its height above or below the eye line (up to 8 % at the panel's top
# and bottom edges). 60 px Nunito has a 42.9 px cap = 1.64 deg at 1.5 m,
# >= 1.5 deg anywhere on the panel. ui_legibility_test measures every text
# run at its real position from the real camera. ---
const FS_DISPLAY := 132   # logo word
const FS_TITLE := 84      # screen titles, tier-up headline
const FS_BUTTON := 60     # button labels
const FS_BODY := 60       # body text, captions, labels (the smallest size)
## Minimum angular cap height, degrees (docs/DESIGN.md: >= 1.5 deg).
const MIN_GLYPH_DEG := 1.5
## WCAG AA contrast for text.
const MIN_CONTRAST := 4.5

# --- Palette. Deep dusk-blue panels, warm cream text, a sunflower accent.
# Prey/threat hues match the birds' edible/danger readability colours in
# spirit: teal-green = food, coral-red = danger. ---
const INK := Color("16212f")          # darkest: text on accent fills
const PANEL := Color("1d2b3d")        # panel base
## Menu panels are solid: in VR the quad blends with the world in *linear*
## light, where even 6 % of a bright sky visibly lifts a dark panel.
const PANEL_ALPHA := 1.0
const FACET_LIGHT := Color("24354b")  # lightest background facet
const BUTTON := Color("2b4160")
const BUTTON_HOVER := Color("37557c")
const BUTTON_PRESSED := Color("ffc94d")
const BUTTON_DISABLED := Color("25364d")
const TEXT := Color("fff4e0")         # cream
const TEXT_DIM := Color("c9d6e6")     # secondary text, still >= 4.5:1
const TEXT_DISABLED := Color("8193a8")
const ACCENT := Color("ffc94d")       # sunflower: hover ring, highlights
const PREY := Color("5fe0a8")         # edible / target
const THREAT := Color("ff6b5e")       # danger / threat (graphics)
const THREAT_TEXT := Color("ff9a8f")  # danger hue light enough for text on panels
## Edible but not worth the chase (icons only): a greyed, faded prey green.
const DUST := Color(0.42, 0.56, 0.53, 0.85)
const SKY := Color("8ec5ec")          # illustration sky
const FEATHER := Color("f2e6cf")      # illustration wing
const FEATHER_DARK := Color("b9a584")
const SKIN := Color("e9b98f")
const HUD_PLATE := Color("16212f")    # backing plate behind HUD text
## HUD plates stay a touch see-through (they sit over the flight path);
## 0.95 keeps every text colour >= 4.5:1 even over a white (linear 1.0) sky
## with VR's linear blending and Filmic tonemapping (0.9 did not: 3.6:1).
const HUD_PLATE_ALPHA := 0.95

const CHAMFER := 14                   # corner cut, px
## Nunito's line box reserves ~0.3 em above the caps for accents; UI text is
## plain English, so tighten each line by this many px (caps are untouched,
## so legibility is unchanged) to fit more rows of large text per panel.
const LINE_TIGHTEN := 10
const FONT_PATH := "res://scenes/ui/fonts/Nunito-Variable.ttf"

static var _theme: Theme
static var _fonts := {}


## Font at a weight (100..1000). Nunito is a variable font whose default
## instance is ExtraLight, so the weight axis must be set explicitly.
static func font(weight: int = 700) -> Font:
	if _fonts.has(weight):
		return _fonts[weight]
	var base := load(FONT_PATH) as FontFile
	var f: Font
	if base == null:
		f = ThemeDB.fallback_font
	else:
		var fv := FontVariation.new()
		fv.base_font = base
		var ts := TextServerManager.get_primary_interface()
		fv.variation_opentype = {ts.name_to_tag("wght"): weight}
		fv.spacing_top = -LINE_TIGHTEN
		f = fv
	_fonts[weight] = f
	return f


static func get_theme() -> Theme:
	if _theme:
		return _theme
	var t := Theme.new()
	t.default_font = font(700)
	t.default_font_size = FS_BODY

	t.set_color("font_color", "Label", TEXT)
	t.set_font_size("font_size", "Label", FS_BODY)

	# Buttons: chunky facets. Hover gets the accent ring and a lighter fill,
	# pressed flips to the accent fill with ink text so a click is unmistakable
	# even in peripheral vision.
	t.set_stylebox("normal", "Button", box(BUTTON, 0, Color.TRANSPARENT, CHAMFER, Vector4(28, 8, 28, 10)))
	t.set_stylebox("hover", "Button", box(BUTTON_HOVER, 6, ACCENT, CHAMFER, Vector4(28, 8, 28, 10)))
	t.set_stylebox("pressed", "Button", box(BUTTON_PRESSED, 6, ACCENT, CHAMFER, Vector4(28, 8, 28, 10)))
	t.set_stylebox("hover_pressed", "Button", box(BUTTON_PRESSED, 6, ACCENT, CHAMFER, Vector4(28, 8, 28, 10)))
	t.set_stylebox("disabled", "Button", box(BUTTON_DISABLED, 0, Color.TRANSPARENT, CHAMFER, Vector4(28, 8, 28, 10)))
	t.set_stylebox("focus", "Button", box(Color.TRANSPARENT, 4, ACCENT.darkened(0.15), CHAMFER + 4, Vector4.ZERO, 6))
	t.set_color("font_color", "Button", TEXT)
	t.set_color("font_hover_color", "Button", TEXT)
	t.set_color("font_focus_color", "Button", TEXT)
	t.set_color("font_pressed_color", "Button", INK)
	t.set_color("font_hover_pressed_color", "Button", INK)
	t.set_color("font_disabled_color", "Button", TEXT_DISABLED)
	t.set_font_size("font_size", "Button", FS_BUTTON)
	t.set_font("font", "Button", font(800))
	t.set_constant("h_separation", "Button", 16)

	# Title labels use a type variation so screens stay declarative.
	t.set_type_variation("TitleLabel", "Label")
	t.set_font("font", "TitleLabel", font(900))
	t.set_font_size("font_size", "TitleLabel", FS_TITLE)
	t.set_color("font_color", "TitleLabel", TEXT)
	t.set_type_variation("DimLabel", "Label")
	t.set_color("font_color", "DimLabel", TEXT_DIM)
	t.set_type_variation("AccentLabel", "Label")
	t.set_color("font_color", "AccentLabel", ACCENT)
	t.set_font("font", "AccentLabel", font(900))

	# Tab buttons (how-to-fly list): quieter until selected.
	t.set_type_variation("TabButton", "Button")
	t.set_stylebox("normal", "TabButton", box(Color(BUTTON, 0.0), 0, Color.TRANSPARENT, CHAMFER, Vector4(24, 2, 24, 4)))
	t.set_stylebox("hover", "TabButton", box(BUTTON_HOVER, 6, ACCENT, CHAMFER, Vector4(24, 2, 24, 4)))
	t.set_stylebox("pressed", "TabButton", box(BUTTON_PRESSED, 0, Color.TRANSPARENT, CHAMFER, Vector4(24, 2, 24, 4)))
	t.set_stylebox("hover_pressed", "TabButton", box(BUTTON_PRESSED, 6, ACCENT, CHAMFER, Vector4(24, 2, 24, 4)))
	t.set_color("font_color", "TabButton", TEXT_DIM)

	t.set_constant("separation", "VBoxContainer", 14)
	t.set_constant("separation", "HBoxContainer", 16)
	_theme = t
	return t


## A flat, chamfered StyleBox. corner_detail = 1 turns every rounded corner
## into a single 45 degree cut: the low-poly facet look.
static func box(fill: Color, border: int = 0, border_color := Color.TRANSPARENT,
		chamfer: int = CHAMFER, margins := Vector4(16, 12, 16, 12), expand: int = 0) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = fill
	s.set_border_width_all(border)
	s.border_color = border_color
	s.set_corner_radius_all(chamfer)
	s.corner_detail = 1
	s.anti_aliasing = true
	s.anti_aliasing_size = 1.0
	s.content_margin_left = margins.x
	s.content_margin_top = margins.y
	s.content_margin_right = margins.z
	s.content_margin_bottom = margins.w
	if expand > 0:
		s.set_expand_margin_all(expand)
	return s


# --- Legibility and contrast maths (used by tests and the shot script) ---

## Height of the capital H in px for a font at a size, from the real glyph
## outline (TextServer contours), so it is exact for whatever font ships.
static func cap_height_px(f: Font, size: int) -> float:
	var ts := TextServerManager.get_primary_interface()
	var rids := f.get_rids()
	if rids.is_empty():
		return size * 0.7
	var rid: RID = rids[0]
	var gi := ts.font_get_glyph_index(rid, size, "H".unicode_at(0), 0)
	var c := ts.font_get_glyph_contours(rid, size, gi)
	var pts: PackedVector3Array = c.get("points", PackedVector3Array())
	if pts.is_empty():
		return size * 0.7
	var lo := INF
	var hi := -INF
	for p in pts:
		lo = minf(lo, p.y)
		hi = maxf(hi, p.y)
	return hi - lo


## Visual angle (degrees) of a length in panel px seen at a distance (m),
## with the panel at PX_PER_M. world_scale cancels (size and distance both
## scale), which the U6 test checks on the real panels.
static func px_to_deg(px: float, distance_m: float) -> float:
	var h := px / PX_PER_M
	return rad_to_deg(2.0 * atan(h * 0.5 / distance_m))


## WCAG 2 relative luminance of an sRGB colour.
static func luminance(c: Color) -> float:
	var ch := func(v: float) -> float:
		return v / 12.92 if v <= 0.04045 else pow((v + 0.055) / 1.055, 2.4)
	return 0.2126 * ch.call(c.r) + 0.7152 * ch.call(c.g) + 0.0722 * ch.call(c.b)


static func contrast(a: Color, b: Color) -> float:
	var la := luminance(a)
	var lb := luminance(b)
	return (maxf(la, lb) + 0.05) / (minf(la, lb) + 0.05)


## fg with alpha composited over an opaque bg.
static func over(fg: Color, bg: Color) -> Color:
	return Color(lerpf(bg.r, fg.r, fg.a), lerpf(bg.g, fg.g, fg.a), lerpf(bg.b, fg.b, fg.a), 1.0)
