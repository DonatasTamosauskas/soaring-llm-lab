class_name LoadingCard
extends Node3D
## The card shown while the game loads (integration): a small flat-shaded
## panel with the game's name, what is being prepared and a segmented bar,
## floating in front of the player at eye height.
##
## It lives under the player's XROrigin3D (rig space), so in VR it is
## world-locked like the menus and the compositor reprojects it cleanly
## while a long load step blocks the main thread; it follows the head only
## lazily (a turn beyond FOLLOW_DEG), never head-locked. Sized by the rig's
## world_scale so it has the same visual angle for every bird size.
## Drawn without depth test: scenery generated behind it never cuts into it.
## Unshaded, one material per part: 4 draw calls, gone once the menu shows.

const DISTANCE := 1.8          # m (x world_scale), like UI panels (1.5-2 m)
const WIDTH := 1.10            # m
const HEIGHT := 0.46           # m
const PITCH_DEG := -4.0        # a little below eye level, as the menu
const FOLLOW_DEG := 30.0       # re-centre once the head turned further
const SEGMENTS := 8

var rig: XROrigin3D
var camera: Node3D
var progress := 0.0:
	set(v):
		progress = clampf(v, 0.0, 1.0)
		_update_bar()

var _title: Label3D
var _line: Label3D
var _bar_bg: MeshInstance3D
var _segs: Array[MeshInstance3D] = []
var _yaw := NAN
var _placed := false


func _init() -> void:
	name = "LoadingCard"
	process_mode = Node.PROCESS_MODE_ALWAYS


func _ready() -> void:
	var panel := MeshInstance3D.new()
	panel.name = "Panel"
	panel.mesh = _chamfered_panel(WIDTH, HEIGHT, 0.06)
	panel.material_override = _mat(UITheme.PANEL, 0)
	panel.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(panel)
	_title = _label("Soaring", 150, UITheme.TEXT, Vector3(0, 0.10, 0.002), 900)
	_line = _label("Loading", 72, UITheme.TEXT_DIM, Vector3(0, -0.035, 0.002), 700)
	_bar_bg = MeshInstance3D.new()
	_bar_bg.name = "BarBg"
	var bg := QuadMesh.new()
	bg.size = Vector2(0.80, 0.05)
	_bar_bg.mesh = bg
	_bar_bg.position = Vector3(0, -0.145, 0.002)
	_bar_bg.material_override = _mat(UITheme.INK, 1)
	add_child(_bar_bg)
	var seg_mat := _mat(UITheme.ACCENT, 2)
	var seg_w := 0.80 / SEGMENTS
	for i in SEGMENTS:
		var s := MeshInstance3D.new()
		var q := QuadMesh.new()
		q.size = Vector2(seg_w - 0.012, 0.032)
		s.mesh = q
		s.position = Vector3(-0.40 + seg_w * (i + 0.5), -0.145, 0.004)
		s.material_override = seg_mat
		s.visible = false
		add_child(s)
		_segs.append(s)
	_update_bar()


func set_text(t: String) -> void:
	if _line:
		_line.text = t


func _process(_dt: float) -> void:
	place()


## Keeps the card in front of the head: placed once, then re-centred only
## when the head has turned more than FOLLOW_DEG away (lazy, world-locked).
func place(force := false) -> void:
	if rig == null or not is_instance_valid(rig) or camera == null or not is_instance_valid(camera):
		return
	var ws := rig.world_scale if rig.world_scale > 0.0 else 1.0
	var head := camera.transform  # rig space (tracked metres x world_scale)
	var f := -head.basis.z
	var yaw := atan2(-f.x, -f.z) if Vector2(f.x, f.z).length() > 0.05 else (0.0 if is_nan(_yaw) else _yaw)
	if force or not _placed or absf(wrapf(yaw - _yaw, -PI, PI)) > deg_to_rad(FOLLOW_DEG):
		_yaw = yaw
		_placed = true
	var b := Basis(Vector3.UP, _yaw) * Basis(Vector3.RIGHT, deg_to_rad(PITCH_DEG))
	var eye := head.origin
	transform = Transform3D(b.scaled(Vector3.ONE * ws), eye + b * Vector3(0, 0, -DISTANCE * ws))


func _update_bar() -> void:
	var n := int(round(progress * SEGMENTS))
	for i in _segs.size():
		_segs[i].visible = i < n


func _label(text: String, size: int, color: Color, pos: Vector3, weight: int) -> Label3D:
	var l := Label3D.new()
	l.text = text
	l.font = UITheme.font(weight)
	l.font_size = size
	l.pixel_size = 0.001
	l.modulate = color
	l.outline_size = 0
	l.no_depth_test = true
	l.shaded = false
	l.double_sided = false
	l.render_priority = 3
	l.position = pos
	l.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(l)
	return l


static func _mat(c: Color, priority: int) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = c
	m.no_depth_test = true
	m.render_priority = priority
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m


## A chamfered rectangle (the UI's low-poly panel shape) facing +Z.
static func _chamfered_panel(w: float, h: float, c: float) -> ArrayMesh:
	var hw := w * 0.5
	var hh := h * 0.5
	var pts := PackedVector3Array([
		Vector3(-hw + c, -hh, 0), Vector3(hw - c, -hh, 0), Vector3(hw, -hh + c, 0), Vector3(hw, hh - c, 0),
		Vector3(hw - c, hh, 0), Vector3(-hw + c, hh, 0), Vector3(-hw, hh - c, 0), Vector3(-hw, -hh + c, 0)])
	var verts := PackedVector3Array()
	for i in range(1, pts.size() - 1):
		verts.append(pts[0])
		verts.append(pts[i + 1])
		verts.append(pts[i])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return m
