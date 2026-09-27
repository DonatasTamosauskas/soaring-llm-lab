class_name UIPanel
extends Node3D
## One surface that shows Control UI: a world-space quad in VR, a 2D overlay
## on desktop. The same Controls (under `content`) are used in both modes.
##
## VR: `content` lives in a SubViewport whose texture is drawn on a curved
## strip: a section of a vertical cylinder centred on the eye, radius
## `distance` x world_scale. Every column of text is then as far from the eye
## and as square-on as the centre column; on a flat 49-degree panel the text
## at the edges would be 11 % further away and seen obliquely, and shrink by
## up to 12 % of its visual angle. The panel is placed in *rig space* (so it
## travels with the flying rig) and follows head yaw lazily: it only moves
## once the head has turned past a dead zone, then eases back to centre. It is
## never rigidly head-locked (a head-locked panel fights the vestibular system
## for as long as it is up). A panel may instead take its yaw from a
## `yaw_source` (the HUD: where the player's body faces), which head turns
## never move.
##
## Rendering: the SubViewport renders only when something in it changed
## (any CanvasItem redraw, resize, visibility or an explicit keep_alive for
## animations), in that frame only. Hidden panels never render. See
## docs/areas/UI.md (U7).
##
## Desktop: `content` sits in a CanvasLayer, centred and scaled to fit
## (menus) or stretched full-screen (HUD).
##
## Bands (VR): a panel may show horizontal slices of its texture at their own
## elevations instead of the whole texture in one piece. The HUD uses this to
## keep its notices above the horizon and its growth strip low, with nothing
## in between, where the player looks for prey, perches and the ground ahead.
## Each band is its own section of the eye-centred cylinder, tilted to face
## the eye at its elevation, so text keeps its visual angle in every band.
## A band may have a home azimuth ("yaw": the HUD's notices live off to the
## side of the flight path) and can be moved off its home placement
## (set_band_offset: a turn about the eye, up or sideways), e.g. so a HUD
## notice moves to the other side when something stays behind it. That only
## changes the band mesh's transform: no re-render, and text keeps exactly
## the same visual angle.

## Pixel size of the SubViewport (= panel size in mm at world_scale 1).
@export var panel_size := UITheme.MENU_SIZE
## Eye-to-panel distance, m at world_scale 1.
@export var distance := UITheme.PANEL_DISTANCE
## Elevation of the panel centre relative to eye level, degrees (negative = below).
@export var pitch_deg := -4.0
## Head yaw (degrees) the panel tolerates before it starts re-centering.
@export var follow_deadzone_deg := 32.0
## Time constant of the yaw follow once triggered, s.
@export var follow_tau := 0.35
## Max follow speed, deg/s: keeps the motion gentle even for a 180 turn.
@export var follow_max_speed_deg := 110.0
## Time constant for following head translation (leaning, standing up), s.
@export var position_tau := 0.3
## With a yaw_source: the source is first smoothed (a first-order low-pass
## with this time constant, s), so a signal that jitters by a few degrees
## (a torso estimate from two swinging hands) gives a steady line...
@export var source_smooth_tau := 0.0
## ...which may wander this far (degrees) from the panel's centre line
## before the panel follows; it then eases all the way back onto it (within
## SOURCE_SETTLE_DEG) and stops, like the head follow, so it never rests
## off the source after a turn.
@export var source_leash_deg := 4.0
## With a yaw_source: time constant of that follow, s...
@export var source_tau := 0.3
## ...never faster than this, deg/s.
@export var source_max_speed_deg := 110.0
## A source follow stops once within this many degrees of the source.
const SOURCE_SETTLE_DEG := 0.5
## A head that moves further than this between two frames (tracker metres:
## 36 m/s at 72 Hz, which no neck does) has been re-seated, not moved: a
## respawn, a recenter, or a non-XR run whose camera sits at its unscaled
## menu height until flight first places it. The eye point follows at once
## instead of easing across the gap (it left the HUD a metre above the eye
## for a second after Play).
const HEAD_JUMP_M := 0.5

## Optional anchor for the panel's yaw instead of the head: () -> float, the
## yaw in rig space (radians, 0 = -Z, + = left, like head_yaw), or NAN when
## it has none right now (the head is used then). The HUD anchors to where
## the player's body faces this way: a head at rest looks that way, and
## where the head happened to point when the HUD appeared (a Play or Resume
## button, a bird) says nothing about it.
var yaw_source: Callable
## Desktop: true = centred and scaled to fit the window; false = full rect.
@export var desktop_fit := true
## Desktop: extra scale for full-rect panels (the HUD is smaller on a monitor).
@export var desktop_scale := 1.0
## CanvasLayer index in desktop mode.
@export var desktop_layer := 10
## Render priority of the quad: menus above HUD above world.
@export var render_priority := 10
## Curve the panel round the eye (see above). False = a flat quad.
@export var curved := true
## Optional slices of the texture shown at their own elevations (see above):
## [{"rows": Vector2(first_row, end_row) in px, "pitch": centre elevation in
## degrees, "yaw": optional home azimuth in degrees (+ = left, like
## set_band_offset)}], top to bottom, set before the panel enters the tree.
## Empty = one band: the whole texture, centred at pitch_deg. The panel's own
## transform stays the frame at pitch_deg; bands are placed relative to it
## by rotating about the eye.
@export var bands: Array[Dictionary] = []

## Strips in the curved mesh: 32 over ~50 degrees keeps each chord within
## 0.3 mm of the true arc.
const CURVE_SEGMENTS := 32

## The Control root every screen is added to. Its size is panel_size in VR.
var content: Control
var vr_mode := false
var shown := false
## Rig (XROrigin3D) and camera the panel is placed relative to. Null = world
## origin / no placement (tests may set them directly).
var rig: Node3D
var camera: Node3D
## Number of frames this panel's SubViewport was asked to render.
var render_requests := 0
## Fastest yaw follow applied so far, deg/s of frame time (comfort test).
var peak_follow_speed := 0.0

var _vp: SubViewport
## One mesh per band (the first is also `_quad`); all share `_mat`.
var _quad: MeshInstance3D
var _quads: Array[MeshInstance3D] = []
var _band_on: Array[bool] = []
var _band_alpha: Array[float] = []
## Per band: offset from its home placement, degrees (x = yaw about the
## vertical through the eye, + = left; y = pitch, + = up). See
## set_band_offset.
var _band_off: Array[Vector2] = []
var _mat: ShaderMaterial
var _tonemap := {}
var _layer: CanvasLayer
var _host: Control
var _dirty := false
var _keep_alive := 0.0
var _last_request_frame := -1
## With a renderer: the request stands until this draw (a count of
## frame_pre_draw) has begun, however many frames that takes.
var _request_draw := 0
var _yaw := 0.0
## The yaw source smoothed (source_smooth_tau), radians; NAN = none yet.
var _src_f := NAN
## Head position the panel is centred on, in rig space *divided by
## world_scale* (tracker metres): growing the player then moves nothing.
var _anchor := Vector3.ZERO
## The head's position last frame (tracker metres), for HEAD_JUMP_M.
var _last_head := Vector3.INF
var _recentering := false
var _placed := false
var _fade := 0.0
var _last_pointer_px := Vector2(-1, -1)
var _pointer_buttons := 0


func _init() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func _ready() -> void:
	_hook_draw_signal()
	content = Control.new()
	content.name = "Content"
	content.theme = UITheme.get_theme()
	content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	content.size = Vector2(panel_size)
	_build_vr()
	_build_desktop()
	get_tree().node_added.connect(_on_node_added)
	_apply_mode()
	_set_visual_visible(false)


func _build_vr() -> void:
	_vp = SubViewport.new()
	_vp.name = "Viewport"
	_vp.size = panel_size
	_vp.transparent_bg = true
	_vp.disable_3d = true
	_vp.gui_embed_subwindows = true
	_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_vp.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	add_child(_vp)
	_mat = ShaderMaterial.new()
	_mat.shader = _panel_shader()
	_mat.render_priority = render_priority
	_mat.set_shader_parameter(&"panel", _vp.get_texture())
	set_tonemap(UITonemap.params(null))
	for i in band_count():
		var q := MeshInstance3D.new()
		q.name = "Quad" if i == 0 else "Quad%d" % i
		q.mesh = _build_mesh(i)
		q.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		q.material_override = _mat
		q.sorting_offset = 100.0
		add_child(q)
		_quads.append(q)
		_band_on.append(true)
		_band_alpha.append(1.0)
		_band_off.append(Vector2.ZERO)
	_quad = _quads[0]


# --- Bands --------------------------------------------------------------------

func band_count() -> int:
	return maxi(1, bands.size())


## Rows [first, end) of the texture that band i shows.
func band_rows(i: int) -> Vector2:
	if bands.is_empty():
		return Vector2(0.0, float(panel_size.y))
	return bands[i]["rows"]


## Centre elevation of band i relative to eye level, degrees.
func band_pitch(i: int) -> float:
	return pitch_deg if bands.is_empty() else float(bands[i]["pitch"])


## Home azimuth of band i about the vertical through the eye, degrees (+ =
## left of the panel's centre line; 0 unless the band says otherwise).
func band_yaw(i: int) -> float:
	return 0.0 if bands.is_empty() else float(bands[i].get("yaw", 0.0))


## Which band shows texture row `py` (rows between bands belong to the
## nearest one, so every pixel still maps somewhere sensible).
func band_of_row(py: float) -> int:
	var best := 0
	var best_d := INF
	for i in band_count():
		var r := band_rows(i)
		var d := 0.0 if py >= r.x and py <= r.y else minf(absf(py - r.x), absf(py - r.y))
		if d < best_d:
			best_d = d
			best = i
	return best


## True if texture row `py` is shown in VR (inside some band).
func is_row_shown(py: float) -> bool:
	var r := band_rows(band_of_row(py))
	return py >= r.x and py <= r.y


## Band i's orientation in the panel's *level* frame (the panel's yaw, no
## pitch) when offset by `off` (degrees): turned to its home azimuth plus
## `off.x` about the vertical through the eye (+ = left), then raised to its
## elevation plus `off.y`. A band turned sideways is thus exactly the home
## band seen from a turned head: its edges keep their elevations (it never
## dips towards the gaze).
func band_placement(i: int, off: Vector2) -> Basis:
	return Basis(Vector3.UP, deg_to_rad(band_yaw(i) + off.x)) * Basis(Vector3.RIGHT, deg_to_rad(band_pitch(i) + off.y))


## Rotation (about the eye) from the panel frame at pitch_deg to band i at
## its home placement.
## (One rotation, not a product, for a band straight ahead: a single-band
## panel gets an exact identity, so rays at its very edge still hit it.)
func _home_basis(i: int) -> Basis:
	if band_yaw(i) == 0.0:
		return Basis(Vector3.RIGHT, deg_to_rad(band_pitch(i) - pitch_deg))
	return Basis(Vector3.RIGHT, deg_to_rad(-pitch_deg)) * band_placement(i, Vector2.ZERO)


## Rotation (about the eye) from the panel frame to band i where it is now.
func _band_basis(i: int) -> Basis:
	var off := band_offset(i)
	if off == Vector2.ZERO:
		return _home_basis(i)
	return Basis(Vector3.RIGHT, deg_to_rad(-pitch_deg)) * band_placement(i, off)


## Move band i off its home placement by `off` (degrees, see
## band_placement): a rotation about the eye, applied to the band mesh's
## transform only, so it costs no SubViewport render and every glyph keeps
## its visual angle. The pointer and the pixel <-> world maths follow it.
func set_band_offset(i: int, off: Vector2) -> void:
	if bands.is_empty() or i < 0 or i >= _band_off.size() or _band_off[i] == off:
		return
	_band_off[i] = off
	var r := _band_basis(i) * _home_basis(i).inverse()
	var eye := Vector3(0.0, 0.0, distance)
	_quads[i].transform = Transform3D(r, eye - r * eye)


func band_offset(i: int) -> Vector2:
	return _band_off[i] if i >= 0 and i < _band_off.size() else Vector2.ZERO


## The mesh drawing band i (tests compare it with the analytic surface).
func band_mesh(i: int) -> MeshInstance3D:
	return _quads[i] if i >= 0 and i < _quads.size() else null


## Show or hide one band's mesh (e.g. nothing in it to show: skip its fill).
func set_band_visible(i: int, on: bool) -> void:
	if i < 0 or i >= _band_on.size() or _band_on[i] == on:
		return
	_band_on[i] = on
	_set_visual_visible(shown)


func is_band_visible(i: int) -> bool:
	return i >= 0 and i < _band_on.size() and _band_on[i] and shown and vr_mode


## Opacity multiplier for one band, applied in the shader (a per-instance
## uniform): fading a band never re-renders the SubViewport.
func set_band_alpha(i: int, a: float) -> void:
	if i < 0 or i >= _quads.size() or is_equal_approx(_band_alpha[i], a):
		return
	_band_alpha[i] = a
	_quads[i].set_instance_shader_parameter(&"band_alpha", a)


func band_alpha(i: int) -> float:
	return _band_alpha[i] if i >= 0 and i < _band_alpha.size() else 0.0


## Band i's surface in panel space (metres at world_scale 1): a strip of
## the eye-centred cylinder, rotated about the eye to its elevation.
func _build_mesh(bi: int) -> Mesh:
	var r := band_rows(bi)
	var v0 := r.x / float(panel_size.y)
	var v1 := r.y / float(panel_size.y)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var segs := CURVE_SEGMENTS if curved else 1
	for i in segs:
		var u0 := float(i) / segs
		var u1 := float(i + 1) / segs
		# Built at the home placement; an offset only moves the mesh.
		var a := _band_point(bi, Vector2(u0, v0), true)
		var b := _band_point(bi, Vector2(u1, v0), true)
		var c := _band_point(bi, Vector2(u1, v1), true)
		var d := _band_point(bi, Vector2(u0, v1), true)
		# Clockwise seen from the eye (Godot's front face): top-left,
		# top-right, bottom-right, then top-left, bottom-right, bottom-left.
		for v: Array in [[a, Vector2(u0, v0)], [b, Vector2(u1, v0)], [c, Vector2(u1, v1)],
				[a, Vector2(u0, v0)], [c, Vector2(u1, v1)], [d, Vector2(u0, v1)]]:
			st.set_uv(v[1])
			st.add_vertex(v[0])
	st.generate_normals()
	return st.commit()


## Panel-space point (metres at world_scale 1) of a texture coordinate
## (0,0 top-left .. 1,1 bottom-right).
func local_point(uv: Vector2) -> Vector3:
	return _band_point(band_of_row(uv.y * panel_size.y), uv)


func _band_point(bi: int, uv: Vector2, home := false) -> Vector3:
	var r := band_rows(bi)
	var x := (uv.x - 0.5) * float(panel_size.x) / UITheme.PX_PER_M
	var y := ((r.x + r.y) * 0.5 - uv.y * panel_size.y) / UITheme.PX_PER_M
	var q := Vector3(x, y, 0.0)
	if curved:
		var phi := x / distance
		q = Vector3(distance * sin(phi), y, distance * (1.0 - cos(phi)))
	if bands.is_empty():
		return q
	var eye := Vector3(0.0, 0.0, distance)
	return eye + (_home_basis(bi) if home else _band_basis(bi)) * (q - eye)


## Panel-space normal (towards the eye) at a texture coordinate.
func local_normal(uv: Vector2) -> Vector3:
	var n := Vector3.BACK
	if curved:
		var phi := (uv.x - 0.5) * float(panel_size.x) / UITheme.PX_PER_M / distance
		n = Vector3(-sin(phi), 0.0, cos(phi))
	if bands.is_empty():
		return n
	return _band_basis(band_of_row(uv.y * panel_size.y)) * n


func _build_desktop() -> void:
	_layer = CanvasLayer.new()
	_layer.name = "Overlay"
	_layer.layer = desktop_layer
	add_child(_layer)
	_host = Control.new()
	_host.name = "Host"
	_host.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_host.set_anchors_preset(Control.PRESET_FULL_RECT)
	_layer.add_child(_host)
	_host.resized.connect(_fit_desktop)


## Switch between the world-space quad (true) and the 2D overlay (false).
func set_vr_mode(on: bool) -> void:
	vr_mode = on
	if is_node_ready():
		_apply_mode()


func _apply_mode() -> void:
	var parent: Node = _vp if vr_mode else _host
	if content.get_parent() != parent:
		if content.get_parent():
			content.get_parent().remove_child(content)
		parent.add_child(content)
	if vr_mode:
		content.scale = Vector2.ONE
		content.position = Vector2.ZERO
		content.size = Vector2(panel_size)
	else:
		_fit_desktop()
	_set_visual_visible(shown)
	mark_dirty()


func _fit_desktop() -> void:
	if vr_mode or content == null or _host == null:
		return
	var avail := _host.size
	if avail.x < 1.0 or avail.y < 1.0:
		avail = Vector2(get_viewport().get_visible_rect().size) if is_inside_tree() else Vector2(1280, 720)
	if desktop_fit:
		var s := minf(avail.x * 0.92 / panel_size.x, avail.y * 0.92 / panel_size.y)
		content.size = Vector2(panel_size)
		content.scale = Vector2.ONE * s
		content.position = (avail - Vector2(panel_size) * s) * 0.5
	else:
		content.scale = Vector2.ONE * desktop_scale
		content.position = Vector2.ZERO
		content.size = avail / desktop_scale


func show_panel(snap := true) -> void:
	if shown:
		return
	shown = true
	if snap or not _placed:
		snap_to_head()
	_fade = 0.0
	if _mat:
		_mat.set_shader_parameter(&"fade", 0.0)
	_set_visual_visible(true)
	mark_dirty()


func hide_panel() -> void:
	if not shown:
		return
	shown = false
	# An animation cut short (a celebration when the run ends) must not
	# resume rendering every frame the next time the panel is shown.
	_keep_alive = 0.0
	_set_visual_visible(false)
	pointer_exit()


func _set_visual_visible(on: bool) -> void:
	for i in _quads.size():
		_quads[i].visible = on and vr_mode and _band_on[i]
	if _layer:
		_layer.visible = on and not vr_mode
	if content:
		# Hidden Controls take no GUI input and trigger no redraws.
		content.visible = on
	if _vp:
		_vp.gui_disable_input = not (on and vr_mode)
		if not (on and vr_mode):
			_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
			_last_request_frame = -1


## Ask for one render of the SubViewport this frame (no-op when hidden or
## on desktop, where the overlay is part of the main viewport).
func mark_dirty() -> void:
	_dirty = true
	_request_render()


## Keep rendering every frame for `seconds` (fades, animated illustrations).
func keep_alive(seconds: float) -> void:
	_keep_alive = maxf(_keep_alive, seconds)
	_request_render()


## True only in a frame in which this panel's SubViewport will render.
func is_rendering_enabled() -> bool:
	return _vp != null and _vp.render_target_update_mode != SubViewport.UPDATE_DISABLED


func get_viewport_node() -> SubViewport:
	return _vp


func _request_render() -> void:
	if not (shown and vr_mode and _vp):
		return
	var f := Engine.get_process_frames()
	# A change made after this frame's draw began (a frame_post_draw
	# continuation, an XR callback) can only be drawn next frame: book it as
	# next frame's request, so _process there does not cancel it before the
	# draw. Otherwise the texture would keep showing the old state (e.g. a
	# lesson card that was already hidden) until something else changed.
	if _draw_started_frame == f:
		f += 1
	# Already asked for this frame (a hide cancels the booking, see
	# _set_visual_visible, so a show after it asks again).
	if f == _last_request_frame:
		return
	_last_request_frame = f
	# The next draw to begin from now on is the one that shows this change.
	_request_draw = _draws_started + 1
	_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	# The server may already have consumed an earlier ONCE this frame while
	# the property still reads ONCE; ask the server directly as well.
	RenderingServer.viewport_set_update_mode(_vp.get_viewport_rid(), RenderingServer.VIEWPORT_UPDATE_ONCE)
	render_requests += 1


## Has the render request made in an earlier frame been drawn?
## With a renderer: once a draw has *begun* since the request (counted by
## frame_pre_draw), whatever the frame numbers. A draw can be skipped (a
## window that cannot draw; a headset session that is not visible), and a
## request cancelled by frame number then would never reach the texture:
## the screenshots caught this once (a hidden lesson card stayed in the HUD
## texture). Headless there are no draws at all: a request is "drawn" at
## the end of the frame it was booked for, so tests still see each frame's
## truth.
func _request_done() -> bool:
	if _real_draws:
		return _draws_started >= _request_draw
	return _last_request_frame < Engine.get_process_frames()


## Process frame whose draw has started (RenderingServer.frame_pre_draw).
## Stays -1 without a renderer (--headless), where nothing is drawn at all.
static var _draw_started_frame := -1
## Draws begun so far (frame_pre_draw), and whether draws happen at all.
static var _draws_started := 0
static var _real_draws := false
static var _draw_hook := false


static func _hook_draw_signal() -> void:
	if _draw_hook:
		return
	_draw_hook = true
	_real_draws = DisplayServer.get_name() != "headless"
	RenderingServer.frame_pre_draw.connect(_on_frame_pre_draw)


static func _on_frame_pre_draw() -> void:
	_draws_started += 1
	note_draw_started()


## Test hook (headless has no draw): mark "the draw of this frame has
## begun", as RenderingServer.frame_pre_draw does with a renderer.
static func note_draw_started() -> void:
	_draw_started_frame = Engine.get_process_frames()


## Test hook: forget a draw marked by note_draw_started().
static func clear_draw_started() -> void:
	_draw_started_frame = -1


func _on_node_added(n: Node) -> void:
	# Every CanvasItem that appears under the content root reports redraws,
	# so the panel re-renders exactly when its pixels could have changed.
	if content == null or not (n is CanvasItem) or not (n == content or content.is_ancestor_of(n)):
		return
	var ci := n as CanvasItem
	if not ci.draw.is_connected(mark_dirty):
		ci.draw.connect(mark_dirty)
		ci.visibility_changed.connect(mark_dirty)
		if ci is Control:
			(ci as Control).item_rect_changed.connect(mark_dirty)
	mark_dirty()


func _process(delta: float) -> void:
	# A one-off render asked for earlier has been drawn. The server drops
	# back to "disabled" by itself, but the node's property keeps reading
	# UPDATE_ONCE; reset it so is_rendering_enabled() (and anything sampling
	# the viewport) tells the truth about this frame. A request whose draw
	# has not happened yet is kept (see _request_done).
	if _vp and _vp.render_target_update_mode != SubViewport.UPDATE_DISABLED and _request_done():
		_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	if not shown:
		return
	if _keep_alive > 0.0:
		_keep_alive -= delta
		_request_render()
	if vr_mode:
		follow(delta)
		if _fade < 1.0:
			_fade = minf(1.0, _fade + delta / 0.18)
			_mat.set_shader_parameter(&"fade", _ease(_fade))


static func _ease(x: float) -> float:
	return 1.0 - pow(1.0 - x, 3.0)


# --- Material ---------------------------------------------------------------

## Pre-compensate the world's tonemapper (see UITonemap). Rebuilds the LUT
## only when the tonemap settings actually changed.
func set_tonemap(p: Dictionary) -> void:
	if p == _tonemap:
		return
	_tonemap = p.duplicate()
	var lut: Array = UITonemap.build_lut(p)
	_mat.set_shader_parameter(&"inv_lut", lut[0])
	_mat.set_shader_parameter(&"lut_scale", lut[1])
	var identity: bool = p["mode"] == Environment.TONE_MAPPER_LINEAR and is_equal_approx(p["exposure"], 1.0)
	_mat.set_shader_parameter(&"compensate", UITonemap.supported(p["mode"]) and not identity)


func get_material() -> ShaderMaterial:
	return _mat


static var _shader_cache: Shader

## Stencil value the player's hands and wings write (see mark_occluder); the
## panel shader's stencil_mode line uses the same literal.
const OCCLUDER_STENCIL := 64


## Contract for the VR area (hands, wings, controllers): an opaque material
## passed here writes OCCLUDER_STENCIL, and UI panels, the laser's reticle
## and the HUD cues are not drawn over it. Without this, a panel that must
## ignore depth (so scenery never cuts into it) would paint over the hand
## pointing at it, a depth conflict that is uncomfortable in VR.
static func mark_occluder(mat: BaseMaterial3D) -> void:
	mat.stencil_mode = BaseMaterial3D.STENCIL_MODE_CUSTOM
	mat.stencil_flags = BaseMaterial3D.STENCIL_FLAG_WRITE
	mat.stencil_compare = BaseMaterial3D.STENCIL_COMPARE_ALWAYS
	mat.stencil_reference = OCCLUDER_STENCIL


## The same stencil test for UI meshes drawn with StandardMaterial3D
## (reticle, cues): skip pixels an occluder has marked.
static func respect_occluders(mat: BaseMaterial3D) -> void:
	mat.stencil_mode = BaseMaterial3D.STENCIL_MODE_CUSTOM
	mat.stencil_flags = BaseMaterial3D.STENCIL_FLAG_READ
	mat.stencil_compare = BaseMaterial3D.STENCIL_COMPARE_NOT_EQUAL
	mat.stencil_reference = OCCLUDER_STENCIL


static func _panel_shader() -> Shader:
	if _shader_cache:
		return _shader_cache
	var sh := Shader.new()
	# The SubViewport has a transparent background, so what it stores is
	# premultiplied colour (Godot's canvas blend is SRC_ALPHA / ONE for
	# alpha). Un-premultiply, undo the tonemapper through the LUT, then draw
	# premultiplied. Unshaded, no fog, no depth test: a menu must never sink
	# into the branch the bird is perched beside. But the player's own hands
	# and wings are always nearer than a panel, so wherever they have marked
	# the stencil (mark_occluder, value OCCLUDER_STENCIL = 64) the panel is
	# not drawn: they stay in front, as depth says they should.
	sh.code = """
shader_type spatial;
render_mode unshaded, blend_premul_alpha, depth_test_disabled, depth_draw_never, cull_back, fog_disabled, shadows_disabled;
stencil_mode read, compare_not_equal, 64;

uniform sampler2D panel : source_color, filter_linear, repeat_disable;
uniform sampler2D inv_lut : filter_linear, repeat_disable;
uniform float lut_scale = 1.0;
uniform bool compensate = false;
uniform float fade = 1.0;
// Per-band opacity (UIPanel.set_band_alpha): fades without re-rendering.
instance uniform float band_alpha = 1.0;

float inv1(float t) {
	float u = sqrt(clamp(t, 0.0, 1.0));
	// Sample texel centres: u = i / (N - 1) lives at (i + 0.5) / N.
	return texture(inv_lut, vec2(u * (255.0 / 256.0) + 0.5 / 256.0, 0.5)).r * lut_scale;
}

void fragment() {
	vec4 c = texture(panel, UV);
	vec3 straight = c.a > 0.0001 ? c.rgb / c.a : vec3(0.0);
	vec3 col = compensate ? vec3(inv1(straight.r), inv1(straight.g), inv1(straight.b)) : straight;
	float a = c.a * fade * band_alpha;
	ALBEDO = col * a;
	ALPHA = a;
}
"""
	_shader_cache = sh
	return sh


# --- Placement (VR) -------------------------------------------------------

func _world_scale() -> float:
	if rig is XROrigin3D:
		return (rig as XROrigin3D).world_scale
	return 1.0


func _rig_xform() -> Transform3D:
	return rig.global_transform if rig and rig.is_inside_tree() else Transform3D.IDENTITY


## Head pose in rig space (positions already include world_scale, as XR
## nodes apply it).
func _head_local() -> Transform3D:
	if camera == null or not camera.is_inside_tree():
		return Transform3D(Basis.IDENTITY, Vector3(0, 1.6 * _world_scale(), 0))
	return _rig_xform().affine_inverse() * camera.global_transform


## Yaw of a basis' look direction around +Y (0 = looking down -Z).
static func head_yaw(b: Basis, fallback: float) -> float:
	var f := -b.z
	var flat := Vector2(f.x, f.z)
	if flat.length() < 0.15:
		# Looking straight up/down: use the top of the head instead.
		var u := b.y
		flat = Vector2(-u.x, -u.z) if f.y < 0.0 else Vector2(u.x, u.z)
		if flat.length() < 1e-4:
			return fallback
	return atan2(-flat.x, -flat.y)


## The yaw source's yaw now (radians, rig space), or NAN without one.
func source_yaw() -> float:
	if not yaw_source.is_valid():
		return NAN
	var v: Variant = yaw_source.call()
	return float(v) if (v is float or v is int) and is_finite(float(v)) else NAN


## Place the panel on its anchor now: straight in front of the head, or on
## the yaw source's yaw if it has one (the head still sets the eye point).
func snap_to_head() -> void:
	var h := _head_local()
	var s := source_yaw()
	_yaw = s if is_finite(s) else head_yaw(h.basis, _yaw)
	_src_f = s
	_anchor = h.origin / _world_scale()
	_last_head = _anchor
	_recentering = false
	_placed = true
	_apply_transform()


## Lazy follow: translation eases; yaw only moves past the dead zone (head)
## or past the leash (the smoothed yaw source).
func follow(delta: float) -> void:
	if not _placed:
		snap_to_head()
		return
	var h := _head_local()
	var s := source_yaw()
	if is_finite(s):
		# Anchored to the source: head turns never move it. The source is
		# smoothed first; inside the leash the panel holds still; past it,
		# it eases back onto the smoothed source and stops there.
		if not is_finite(_src_f):
			_src_f = s
		elif source_smooth_tau > 0.0:
			_src_f = wrapf(_src_f + wrapf(s - _src_f, -PI, PI) * (1.0 - exp(-delta / source_smooth_tau)), -PI, PI)
		else:
			_src_f = s
		var cap_s := deg_to_rad(source_max_speed_deg) * delta
		var e := wrapf(_src_f - _yaw, -PI, PI)
		if absf(e) > deg_to_rad(source_leash_deg):
			_recentering = true
		if _recentering:
			var st := clampf(e * (1.0 - exp(-delta / source_tau)), -cap_s, cap_s)
			_yaw = wrapf(_yaw + st, -PI, PI)
			if delta > 0.0:
				peak_follow_speed = maxf(peak_follow_speed, rad_to_deg(absf(st)) / delta)
			# Stop once on it: the smoothed source and the source itself both
			# within SOURCE_SETTLE_DEG (the smoothed one alone could still be
			# on its way, and the panel would rest short of the source).
			var settle := deg_to_rad(SOURCE_SETTLE_DEG)
			if absf(wrapf(_src_f - _yaw, -PI, PI)) < settle and absf(wrapf(s - _yaw, -PI, PI)) < settle:
				_recentering = false
	else:
		_src_f = NAN
		var cap := deg_to_rad(follow_max_speed_deg) * delta
		var target_yaw := head_yaw(h.basis, _yaw)
		var err := wrapf(target_yaw - _yaw, -PI, PI)
		if absf(err) > deg_to_rad(follow_deadzone_deg):
			_recentering = true
		if _recentering:
			var step := err * (1.0 - exp(-delta / follow_tau))
			step = clampf(step, -cap, cap)
			_yaw += step
			if delta > 0.0:
				peak_follow_speed = maxf(peak_follow_speed, rad_to_deg(absf(step)) / delta)
			if absf(err) < deg_to_rad(2.0):
				_recentering = false
	# Eased in tracker metres, so leaning is smoothed but a growing player
	# (world_scale changing every frame) leaves the panel exactly in place.
	# A head re-seated between two frames (HEAD_JUMP_M) is followed at once.
	var head_m := h.origin / _world_scale()
	if _last_head.is_finite() and head_m.distance_to(_last_head) > HEAD_JUMP_M:
		_anchor = head_m
	else:
		_anchor = _anchor.lerp(head_m, 1.0 - exp(-delta / position_tau))
	_last_head = head_m
	_apply_transform()


func _apply_transform() -> void:
	var ws := _world_scale()
	var p := deg_to_rad(pitch_deg)
	var dir := Vector3(-sin(_yaw) * cos(p), sin(p), -cos(_yaw) * cos(p))
	var local_pos := (_anchor + dir * distance) * ws
	# -Z away from the eye, so the quad's front (+Z) faces the viewer.
	var b := Basis.looking_at(dir, Vector3.UP).scaled(Vector3.ONE * ws)
	global_transform = _rig_xform() * Transform3D(b, local_pos)


## Current yaw offset of the panel from the head's yaw, radians.
func yaw_error() -> float:
	return wrapf(head_yaw(_head_local().basis, _yaw) - _yaw, -PI, PI)


## The panel's centre-line yaw in rig space, radians (+ = left of -Z).
func panel_yaw() -> float:
	return _yaw


## Offset of the panel from its anchor (the yaw source as it is now, not
## smoothed; else the head), radians.
func anchor_error() -> float:
	var s := source_yaw()
	return wrapf(s - _yaw, -PI, PI) if is_finite(s) else yaw_error()


# --- Pointer (VR) -----------------------------------------------------------

## Ray against the panel surface (the eye-centred cylinder, or the flat
## quad). Only the front (the side facing the eye) is hit. Returns {} on a
## miss, else {point, distance, pixel, normal} (world space).
func intersect_ray(origin: Vector3, dir: Vector3) -> Dictionary:
	if not (shown and vr_mode and is_inside_tree()):
		return {}
	var xf := global_transform
	var inv := xf.affine_inverse()
	var o_panel := inv * origin
	var d_panel := inv.basis * dir
	var eye := Vector3(0.0, 0.0, distance)
	var best := {}
	var best_t := INF
	for bi in band_count():
		if not (bi < _band_on.size() and _band_on[bi]):
			continue
		# Into the band's own frame (undo its rotation about the eye).
		var rot := _band_basis(bi).inverse()
		var o := eye + rot * (o_panel - eye)
		var d := rot * d_panel
		var h := _intersect_band(bi, o, d)
		if not h.is_empty() and float(h["t"]) < best_t:
			best_t = h["t"]
			best = h
	if best.is_empty():
		return {}
	var uv: Vector2 = best["uv"]
	var world := xf * local_point(uv)
	return {"point": world, "distance": origin.distance_to(world), "pixel": uv * Vector2(panel_size),
		"normal": (xf.basis * local_normal(uv)).normalized()}


## Ray (in band bi's own frame, units of the panel frame) against that band:
## {t, uv} of the first front-facing hit inside it, or {}.
func _intersect_band(bi: int, o: Vector3, d: Vector3) -> Dictionary:
	var rows := band_rows(bi)
	var w := float(panel_size.x) / UITheme.PX_PER_M
	var half_h := (rows.y - rows.x) * 0.5 / UITheme.PX_PER_M
	var mid := (rows.x + rows.y) * 0.5
	var hits: Array[float] = []
	if not curved:
		# The ray must travel towards -Z in panel space to see the front.
		if d.z < -1e-6:
			hits.append(-o.z / d.z)
	else:
		# Cylinder x^2 + (z - R)^2 = R^2 round the vertical axis through the
		# eye. Its front is the concave side: a ray sees it while moving away
		# from the axis.
		var r := distance
		var oz := o.z - r
		var a := d.x * d.x + d.z * d.z
		var b := 2.0 * (o.x * d.x + oz * d.z)
		var c := o.x * o.x + oz * oz - r * r
		var disc := b * b - 4.0 * a * c
		if a > 1e-9 and disc >= 0.0:
			var sq := sqrt(disc)
			hits.append((-b - sq) / (2.0 * a))
			hits.append((-b + sq) / (2.0 * a))
	for t in hits:
		if t <= 0.0:
			continue
		var p := o + d * t
		var x := p.x
		if curved:
			if d.x * p.x + d.z * (p.z - distance) <= 0.0:
				continue
			# Arc length from the centre line; p.z < R is the front half.
			if p.z >= distance:
				continue
			x = atan2(p.x, distance - p.z) * distance
		if absf(x) > w * 0.5 or absf(p.y) > half_h:
			continue
		return {"t": t, "uv": Vector2(x / w + 0.5, (mid - p.y * UITheme.PX_PER_M) / float(panel_size.y))}
	return {}


## Where a world direction from the panel's eye point meets band bi's
## surface, in texture pixels, *ignoring the band's edges* (so a caller can
## test a margin around what is drawn). Non-finite if it points away.
func direction_pixel(bi: int, dir: Vector3) -> Vector2:
	return band_frame_pixel(bi, _band_basis(bi).inverse() * (global_transform.basis.inverse() * dir))


## A world direction in the panel's level frame (unit length): the frame
## band_placement() works in, so band_placement(i, off).inverse() * it is
## the direction in band i's frame at any candidate offset.
func level_direction(dir: Vector3) -> Vector3:
	return (Basis(Vector3.RIGHT, deg_to_rad(pitch_deg)) * (global_transform.basis.inverse() * dir)).normalized()


## Texture pixel where a direction given in band bi's own frame meets its
## surface (edges ignored); non-finite if it points away.
func band_frame_pixel(bi: int, d: Vector3) -> Vector2:
	var rows := band_rows(bi)
	var mid := (rows.x + rows.y) * 0.5
	var x := 0.0
	var y := 0.0
	if curved:
		var flat := sqrt(d.x * d.x + d.z * d.z)
		var yaw := atan2(d.x, -d.z)
		if flat < 1e-6 or absf(yaw) > PI * 0.5:
			return Vector2(INF, INF)
		x = yaw * distance
		y = d.y / flat * distance
	else:
		if d.z > -1e-6:
			return Vector2(INF, INF)
		x = d.x * distance / -d.z
		y = d.y * distance / -d.z
	return Vector2((x * UITheme.PX_PER_M) + panel_size.x * 0.5, mid - y * UITheme.PX_PER_M)


## Unit direction, in band bi's own frame, from the eye to texture pixel
## `px` on the band's surface (edges ignored): the inverse of
## band_frame_pixel.
func band_frame_direction(bi: int, px: Vector2) -> Vector3:
	var rows := band_rows(bi)
	var x := (px.x - panel_size.x * 0.5) / UITheme.PX_PER_M
	var y := ((rows.x + rows.y) * 0.5 - px.y) / UITheme.PX_PER_M
	if curved:
		var yaw := x / distance
		return Vector3(sin(yaw), y / distance, -cos(yaw)).normalized()
	return Vector3(x, y, -distance).normalized()


## World position of a pixel on the panel (tests aim rays with this).
func pixel_to_world(px: Vector2) -> Vector3:
	return global_transform * local_point(px / Vector2(panel_size))


## World position of a Control's centre (it must live under `content`).
func control_to_world(c: Control) -> Vector3:
	var r := c.get_global_rect()
	return pixel_to_world(r.get_center())


func pointer_move(px: Vector2) -> void:
	if _vp == null or not _vp.is_inside_tree():
		return
	var ev := InputEventMouseMotion.new()
	ev.position = px
	ev.global_position = px
	ev.relative = px - _last_pointer_px if _last_pointer_px.x >= 0.0 else Vector2.ZERO
	ev.button_mask = _pointer_buttons
	_last_pointer_px = px
	_vp.push_input(ev, true)


func pointer_button(px: Vector2, pressed: bool) -> void:
	if _vp == null or not _vp.is_inside_tree():
		return
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = pressed
	ev.position = px
	ev.global_position = px
	_pointer_buttons = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	ev.button_mask = _pointer_buttons
	_vp.push_input(ev, true)


## The pointer left the panel: clear hover, and release a held press so a
## drag cannot get stuck when the ray slides off the edge. The pointer moves
## off first, with the press still held, and is released out there: sliding
## off a button with the trigger held cancels, as on any screen. (Released
## at the last pixel, which was on the button, it clicked it: pull on Play,
## slide into the sky, let go, and a run started.)
func pointer_exit() -> void:
	if _vp == null or not _vp.is_inside_tree() or _last_pointer_px.x < 0.0:
		return
	var off := Vector2(-10000, -10000)
	var ev := InputEventMouseMotion.new()
	ev.position = off
	ev.global_position = off
	ev.relative = off - _last_pointer_px
	ev.button_mask = _pointer_buttons
	_vp.push_input(ev, true)
	if _pointer_buttons != 0:
		pointer_button(off, false)
	_last_pointer_px = Vector2(-1, -1)


func hovered_control() -> Control:
	return _vp.gui_get_hovered_control() if _vp else null
