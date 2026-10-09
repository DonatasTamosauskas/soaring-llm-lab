class_name UITheme
extends RefCounted

## Every colour, size and material the menus are made of.
##
## The world's colours live in [Palette] and are chosen to sit in the air
## together; UI colour is a different job — it has to stay legible against
## whatever happens to be behind it, which in this game is the whole range from
## a snow rim to a shadowed gorge. So this is a small, separate palette with one
## rule: everything is either the panel (dark, desaturated, never black) or the
## text on it (warm, near-white, never pure white), plus exactly one accent that
## means "this is the thing you are pointing at".
##
## [UITests] scans `scripts/ui/` and fails if any other file names a colour, the
## same discipline [PaletteTests] holds the world to.

## Panel body is dark enough to read cream text against a snowfield and
## translucent enough that the world is still there behind it — an opaque slab
## floating in a VR sky reads as a bug in the game rather than a menu.
const COLOURS: Dictionary = {
	"panel": Color(0.07, 0.075, 0.09, 0.88),
	"panel_edge": Color(0.62, 0.59, 0.53, 0.85),
	# A cold pale wash rather than the warm accent: the accent is also the colour
	# of every value and every level bar, and a gold row under a gold bar is a
	# bar nobody can read. The pointer's own dot carries the rest of the signal.
	"highlight": Color(0.82, 0.88, 1.0, 0.20),
	"accent": Color(0.98, 0.78, 0.36, 0.95),
	"text": Color(0.96, 0.94, 0.88, 0.97),
	"text_dim": Color(0.72, 0.70, 0.66, 0.92),
	"text_accent": Color(1.0, 0.85, 0.52, 0.98),
	"bar_back": Color(0.42, 0.42, 0.45, 0.55),
	"bar_fill": Color(0.98, 0.78, 0.36, 0.92),
	"beam": Color(0.98, 0.78, 0.36, 0.40),
	"dot": Color(1.0, 0.93, 0.76, 0.95),
	"outline": Color(0.0, 0.0, 0.0, 0.80),
	"warn": Color(1.0, 0.55, 0.38, 0.96),
	# The in-flight readout. Colder and plainer than the menus on purpose: it is
	# read at 50 m/s out of the corner of an eye, so it is white text with a hard
	# black outline and one warm accent for anything that just happened.
	"hud_text": Color(1.0, 1.0, 1.0, 0.92),
	"hud_banner": Color(1.0, 0.94, 0.78, 1.0),
	"hud_coach": Color(1.0, 0.88, 0.62, 0.95),
	"hud_bar_back": Color(0.06, 0.07, 0.09, 0.65),
	"hud_bar_fill": Color(0.98, 0.78, 0.36, 0.95),
	# The prey marker is the one cold thing in the interface, matching the cyan
	# a bird you can eat is tinted with — the chevron and the bird it points at
	# have to be obviously the same statement.
	"guide": Color(0.60, 0.94, 0.92, 0.85),
	"outline_soft": Color(0.0, 0.0, 0.0, 0.75),
}

## Metres of text height per font pixel. One number, so "how big is this text"
## is answerable in metres and therefore in degrees of the player's view, which
## is the only unit legibility is actually measured in.
const PIXEL_SIZE: float = 0.0005

const TEXT_TITLE: float = 0.082
const TEXT_ROW: float = 0.056
const TEXT_BODY: float = 0.044
const TEXT_SMALL: float = 0.042

## Smallest text this game is allowed to draw, in degrees of visual angle at the
## distance it is drawn. Below about 1 degree a Quest panel cannot resolve a
## letterform at all; 1.5 is the point where reading it stops being work.
const MIN_TEXT_DEGREES: float = 1.5

## What fraction of a font's em box a capital letter actually fills.
##
## The number that matters for legibility is the height of a letter, not the
## height of the box it is drawn in, and the two differ by nearly a third. The
## in-flight readout was sized in em boxes against a floor of 1.4 degrees, which
## sounds safe and came out as a 0.9-degree capital — around a dozen pixels on a
## headset panel, measured off a real frame. Everything here is now checked as
## cap height.
const CAP_HEIGHT_RATIO: float = 0.72
## Smallest capital letter, in degrees. A Quest 3 resolves about twenty pixels
## per degree, so this is a fifteen-pixel letter: readable at a glance while
## something is trying to eat you.
const MIN_CAP_DEGREES: float = 1.0
## Smallest thing the player is asked to point a controller at. A hand-held ray
## wobbles by roughly half a degree; anything under about 2.5 degrees turns
## selecting into aiming.
const MIN_TARGET_DEGREES: float = 2.5


static func colour(name: String) -> Color:
	return COLOURS.get(name, COLOURS["text"])


## Angular size of something [param size] metres tall seen from [param distance]
## metres away, in degrees. The unit every legibility rule here is written in.
static func degrees_at(size: float, distance: float) -> float:
	if not is_finite(size) or not is_finite(distance) or distance <= 0.0:
		return 0.0
	return rad_to_deg(2.0 * atan(absf(size) * 0.5 / distance))


## The same, for the height of a capital letter in text whose em box is
## [param em] metres tall. This is the one the eye is actually reading.
static func cap_degrees_at(em: float, distance: float) -> float:
	return degrees_at(em * CAP_HEIGHT_RATIO, distance)


static func font_size_for(height: float) -> int:
	return maxi(8, int(round(maxf(height, 0.001) / PIXEL_SIZE)))


## A world-space label. Depth testing is off and fog is disabled on purpose: a
## menu that a tree can stand in front of, or that goes grey at 900 m of haze
## like everything else in this world does, is a menu you cannot use.
static func label(
	height: float, text: String, colour_name: String = "text",
	alignment: int = HORIZONTAL_ALIGNMENT_CENTER
) -> Label3D:
	var node := Label3D.new()
	node.text = text
	node.font_size = font_size_for(height)
	node.pixel_size = PIXEL_SIZE
	node.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	node.no_depth_test = true
	node.render_priority = 20
	node.outline_render_priority = 19
	node.modulate = colour(colour_name)
	node.outline_size = maxi(8, font_size_for(height) / 6)
	node.outline_modulate = colour("outline")
	node.horizontal_alignment = alignment
	node.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	node.fixed_size = false
	return node


## Flat unlit quads are the whole of this UI's geometry. Shared per colour so a
## menu of twenty rows still adds one material per colour it uses, not per row.
static var _materials: Dictionary = {}


static func quad_material(colour_name: String, priority: int) -> StandardMaterial3D:
	var key: String = "%s#%d" % [colour_name, priority]
	if _materials.has(key):
		return _materials[key] as StandardMaterial3D
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = colour(colour_name)
	material.no_depth_test = true
	material.disable_fog = true
	material.disable_receive_shadows = true
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.render_priority = priority
	_materials[key] = material
	return material


static func quad(size: Vector2, colour_name: String, priority: int) -> MeshInstance3D:
	var mesh := QuadMesh.new()
	mesh.size = size
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.material_override = quad_material(colour_name, priority)
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# The panel is a metre and a half from a camera that is looking at it, but
	# its own AABB is thin and the culler has been known to lose it edge-on.
	instance.extra_cull_margin = 8.0
	return instance
