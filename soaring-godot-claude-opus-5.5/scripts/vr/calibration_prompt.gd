class_name CalibrationPrompt
extends Node3D
## The calibration step's card: a small dark card floating in front of the
## player with a progress ring, a pictogram of the pose to hold (or a tick /
## a cross for the result), the instruction, and a dimmer hint line (what is
## wrong with the pose, or how to cancel).
##
## World-locked with a lazy follow (the comfortable way to show a VR
## instruction): it stays where it is while the player looks around a
## little, and glides back in front of them once they look more than
## FOLLOW_START away, so it never swims with every head motion yet can't be
## lost. Lives under the XROrigin3D; distances are metres x world_scale and
## nothing is node-scaled (the quad and the text are sized instead). The
## card grows wider to fit its text (never narrower than SIZE.x).
##
## Three draw calls while shown (the card, the text, the hint), none
## otherwise. The card is drawn by one shader (rounded box, ring, pictogram
## as distance fields), depth test off so scenery never cuts it.

enum Step { POSE, DONE, FAILED }

## Card size, m at world_scale 1 (the width grows with the text); distance
## and height below the eyes.
const SIZE := Vector2(0.80, 0.24)
const DISTANCE := 1.25
const DROP := 0.14
## Lazy follow: start re-centring beyond this yaw error, stop inside
## FOLLOW_STOP, with this time constant.
const FOLLOW_START := deg_to_rad(28.0)
const FOLLOW_STOP := deg_to_rad(3.0)
const FOLLOW_TAU := 0.25
## Text: in the UI's font, every line's capital height >= 1.5° at DISTANCE
## (the brief's legibility bar, measured the way the UI measures it:
## UITheme.cap_height_px). Integration round 2: 40 / 34 px in the fallback
## font gave the hint ~1.0° of cap height in the simulator's mirror ("B or
## Y: skip" about 8 px where the menus' smallest text is 14).
const FONT_SIZE := 56
const HINT_FONT_SIZE := 54
const PIXEL := 0.00088
## The UI's colours (navy panel, sunflower ring, cream text), so the first
## thing a new player reads after Play looks like the rest of the game
## (round 2: a black sans-serif box).
const CARD_COLOR := Color("1d2b3d")
const TRACK_COLOR := Color("2b4160")
const FILL_COLOR := Color("ffc94d")
const TEXT_COLOR := Color("fff4e0")
const HINT_COLOR := Color("c9d6e6")
## Card padding above and below the text (m at world_scale 1).
const PAD_Y := 0.03
## Space between the text and the card's right edge, and between the two
## text blocks (m at world_scale 1).
const MARGIN := 0.045
const GAP := 0.012

const SHADER_CODE := """
shader_type spatial;
render_mode unshaded, blend_mix, depth_test_disabled, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;

uniform vec2 size = vec2(0.80, 0.24);
uniform float progress = 0.0;
uniform int step = 0;
uniform float time = 0.0;
// Opaque (the edge alone is blended): blending happens in linear space,
// where even 3.5 % of the bright, tone-compensated text of a menu panel
// behind (the pause menu, when the step is chosen there) showed through
// as readable words.
uniform vec4 card : source_color = vec4(0.07, 0.09, 0.12, 1.0);
uniform vec3 track : source_color = vec3(0.22, 0.26, 0.32);
uniform vec3 fill : source_color = vec3(1.0, 0.78, 0.32);
uniform vec3 ok : source_color = vec3(0.45, 0.9, 0.55);
uniform vec3 bad : source_color = vec3(1.0, 0.45, 0.4);
uniform vec3 ink : source_color = vec3(0.93, 0.95, 0.98);

float sd_box(vec2 p, vec2 b, float r) {
	vec2 q = abs(p) - b + r;
	return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

float sd_seg(vec2 p, vec2 a, vec2 b) {
	vec2 pa = p - a;
	vec2 ba = b - a;
	return length(pa - ba * clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0));
}

// A stroke of width w (m) with a one-pixel soft edge.
float ink_of(float d, float w) {
	return 1.0 - smoothstep(w - fwidth(d), w + fwidth(d), d);
}

void fragment() {
	vec2 p = (UV - 0.5) * size;
	p.y = -p.y;
	float box = sd_box(p, size * 0.5, 0.028 * size.y / 0.24);
	float alpha = card.a * (1.0 - smoothstep(-fwidth(box), fwidth(box), box));
	vec3 col = card.rgb;
	// Progress ring on the left.
	vec2 c = vec2(-size.x * 0.5 + size.y * 0.5, 0.0);
	vec2 q = p - c;
	float rad = size.y * 0.36;
	float ring = abs(length(q) - rad);
	float frac = fract(atan(q.x, q.y) / 6.2831853 + 1.0);
	vec3 ring_col = track;
	if (step == 0 && frac <= progress) ring_col = fill;
	if (step == 1) ring_col = ok;
	if (step == 2) ring_col = bad;
	col = mix(col, ring_col, ink_of(ring, 0.0065 * size.y / 0.24));
	// Pictogram inside the ring: the pose to hold (a figure seen from the
	// front, arms straight out, level, hands flat), a tick when done, a
	// cross when it was cancelled or failed.
	float s = rad * 0.9;
	float f = 1e3;
	if (step == 0) {
		float breathe = 0.03 * sin(time * 3.0);
		f = min(f, abs(length(q - vec2(0.0, 0.42) * s) - 0.12 * s));
		f = min(f, sd_seg(q, vec2(0.0, 0.3) * s, vec2(0.0, -0.3) * s));
		f = min(f, sd_seg(q, vec2(0.0, -0.3) * s, vec2(-0.16, -0.72) * s));
		f = min(f, sd_seg(q, vec2(0.0, -0.3) * s, vec2(0.16, -0.72) * s));
		for (int i = 0; i < 2; i++) {
			float sg = i == 0 ? -1.0 : 1.0;
			f = min(f, sd_seg(q, vec2(0.0, 0.18) * s, vec2(sg * 0.8, 0.18 + breathe) * s));
			f = min(f, sd_seg(q, vec2(sg * 0.8, 0.18 + breathe) * s, vec2(sg * 0.97, 0.18 + breathe) * s) - 0.02 * s);
		}
		col = mix(col, ink, ink_of(f, 0.03 * s));
	} else if (step == 1) {
		f = min(sd_seg(q, vec2(-0.42, 0.0) * s, vec2(-0.1, -0.32) * s), sd_seg(q, vec2(-0.1, -0.32) * s, vec2(0.48, 0.34) * s));
		col = mix(col, ok, ink_of(f, 0.075 * s));
	} else {
		f = min(sd_seg(q, vec2(-0.36, -0.36) * s, vec2(0.36, 0.36) * s), sd_seg(q, vec2(-0.36, 0.36) * s, vec2(0.36, -0.36) * s));
		col = mix(col, bad, ink_of(f, 0.075 * s));
	}
	ALBEDO = col;
	ALPHA = alpha;
}
"""

var card: MeshInstance3D
var text: Label3D
var hint: Label3D
var step: Step = Step.POSE
var progress := 0.0
## Current heading of the card around the player (origin space, rad).
var yaw := 0.0
var following := false
## The card's width now (m at world_scale 1): SIZE.x, or wider for its text.
var width := SIZE.x

var _mat: ShaderMaterial
var _quad: QuadMesh
var _ws := -1.0
var _layout_key := ""
var _placed := false
var _time := 0.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var sh := Shader.new()
	sh.code = SHADER_CODE
	_mat = ShaderMaterial.new()
	_mat.shader = sh
	_mat.render_priority = Material.RENDER_PRIORITY_MAX - 1
	_quad = QuadMesh.new()
	card = MeshInstance3D.new()
	card.name = "Card"
	card.mesh = _quad
	card.material_override = _mat
	card.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	card.extra_cull_margin = 4.0
	add_child(card)
	_mat.set_shader_parameter("card", CARD_COLOR)
	_mat.set_shader_parameter("track", Color(TRACK_COLOR, 1.0))
	_mat.set_shader_parameter("fill", Color(FILL_COLOR, 1.0))
	_mat.set_shader_parameter("ink", Color(TEXT_COLOR, 1.0))
	text = _make_label("Text", FONT_SIZE, TEXT_COLOR)
	hint = _make_label("Hint", HINT_FONT_SIZE, HINT_COLOR)
	visible = false


func _make_label(n: String, font_size: int, color: Color) -> Label3D:
	var l := Label3D.new()
	l.name = n
	l.no_depth_test = true
	l.render_priority = Material.RENDER_PRIORITY_MAX
	l.fixed_size = false
	l.double_sided = true
	l.shaded = false
	l.font = card_font()
	l.font_size = font_size
	l.outline_size = 0
	l.modulate = color
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.autowrap_mode = TextServer.AUTOWRAP_OFF
	l.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(l)
	return l


## Shows the card. head: the XRCamera3D's transform in origin space (its
## origin already x world_scale); lines: the instruction or result; hint:
## the dim line under it ("" for none).
func show_step(p_step: Step, p_progress: float, lines: String, p_hint: String, head: Transform3D, ws: float, dt: float) -> void:
	step = p_step
	progress = clampf(p_progress, 0.0, 1.0)
	_time += dt
	if not visible:
		visible = true
		_placed = false
	if text.text != lines:
		text.text = lines
	if hint.text != p_hint:
		hint.text = p_hint
	_layout(ws)
	_follow(head, dt)
	_mat.set_shader_parameter("progress", progress)
	_mat.set_shader_parameter("step", int(step))
	_mat.set_shader_parameter("time", _time)


func hide_prompt() -> void:
	visible = false
	_placed = false
	following = false


## The card's font: the UI's (bold), or the engine's without the UI.
static func card_font() -> Font:
	var f: Font = UITheme.font(700)
	return f if f != null else ThemeDB.fallback_font


## Size (m at world_scale 1) of a text block in the card's font.
static func text_size(t: String, font_size: int) -> Vector2:
	if t == "":
		return Vector2.ZERO
	return card_font().get_multiline_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size) * PIXEL


## Angular capital height (deg) of text at this font size on the card.
static func cap_deg(font_size: int) -> float:
	return rad_to_deg(atan(UITheme.cap_height_px(card_font(), font_size) * PIXEL / DISTANCE))


## The card's height (m at world_scale 1): SIZE.y, or taller for its text.
var height := SIZE.y


## Sizes the card for its text and places the two text blocks (right of the
## ring, centred together vertically). Only when the text or the scale
## changed.
func _layout(ws: float) -> void:
	var key := "%s|%s|%.5f" % [text.text, hint.text, ws]
	if key == _layout_key:
		return
	_layout_key = key
	_ws = ws
	var a := text_size(text.text, FONT_SIZE)
	var b := text_size(hint.text, HINT_FONT_SIZE)
	var gap := GAP if b.y > 0.0 else 0.0
	var total := a.y + gap + b.y
	height = maxf(SIZE.y, total + 2.0 * PAD_Y)
	var left := height + 0.02
	width = maxf(SIZE.x, left + maxf(a.x, b.x) + MARGIN)
	_quad.size = Vector2(width, height) * ws
	_mat.set_shader_parameter("size", Vector2(width, height) * ws)
	var x := (-width * 0.5 + left) * ws
	for l: Label3D in [text, hint]:
		l.pixel_size = PIXEL * ws
	text.position = Vector3(x, (total * 0.5 - a.y * 0.5) * ws, 0.002 * ws)
	hint.position = Vector3(x, (-total * 0.5 + b.y * 0.5) * ws, 0.002 * ws)


## Heading of the gaze in origin space (continuous for any head pitch).
static func gaze_yaw(head: Basis) -> float:
	return VRMath.yaw_of(VRMath.head_forward(head))


## Lazy follow: hold still while the gaze stays within FOLLOW_START, then
## glide (tau FOLLOW_TAU) until centred within FOLLOW_STOP. Distance and
## height track the head directly (small; keeps the card at reading range).
func _follow(head: Transform3D, dt: float) -> void:
	var want := gaze_yaw(head.basis)
	if not _placed:
		yaw = want
		_placed = true
		following = false
	var err := VRMath.wrap_angle(want - yaw)
	if absf(err) > FOLLOW_START:
		following = true
	if following:
		yaw += err * VRMath.lp(dt, FOLLOW_TAU)
		if absf(VRMath.wrap_angle(want - yaw)) < FOLLOW_STOP:
			following = false
	yaw = VRMath.wrap_angle(yaw)
	var fwd := Basis(Vector3.UP, yaw) * Vector3.FORWARD
	var pos := head.origin + (fwd * DISTANCE + Vector3(0.0, -DROP, 0.0)) * _ws
	# Face the eyes (billboard about the card's own centre, upright).
	var to_eye := head.origin - pos
	var b := Basis.looking_at(-to_eye, Vector3.UP) if to_eye.length() > 1e-5 else Basis(Vector3.UP, yaw)
	transform = Transform3D(b, pos)
