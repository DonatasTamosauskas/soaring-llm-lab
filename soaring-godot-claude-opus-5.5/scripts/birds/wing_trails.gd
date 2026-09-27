class_name WingTrails
extends Node3D
## Subtle wingtip trails at speed: two thin ribbons of air streaming off a
## BirdModel's wingtips while its bird flies fast (a stoop, a dive), fading
## over ~0.2 s. Add with BirdFX.attach_trails(model); the node follows the
## model's drawn pose (BirdModel.get_wingtip), draws both ribbons as one
## triangle strip (one draw call) in world space, and disappears below the
## speed threshold. Freed with its model.
##
## Cheap by construction: the tip points live in fixed ring buffers (no
## allocation per frame), each ribbon is 2 vertices per point, and a trail
## that is not showing only tracks its bird's speed. At most MAX_ACTIVE
## trails draw at once, the ones nearest the camera: a trail is ranked from
## the frame after it first wants to draw, and one the budget cuts fades out
## within ~0.1 s and is dropped as soon as it is too faint to see, so the
## cost stays bounded however many birds stoop together (40 starting in the
## same frame never draw more than MAX_ACTIVE).

## Points kept per tip and how long a point lives, seconds.
const POINTS := 14
const LIFE := 0.22
## Trails show above this multiple of the bird's cruise speed (fully above
## FULL_AT x cruise).
const START_AT := 1.35
const FULL_AT := 1.9
## Trails drawn at once, at most (about 30 us of CPU each on an M1).
const MAX_ACTIVE := 12
## The ranking list never holds more than this (a safety net: it holds one
## frame's trails).
const MAX_WANT := 256
## A trail cut by the budget fades with this time constant (s) and is
## dropped below this strength (alpha 0.32 x 0.15 = 0.05: barely there).
const CUT_FADE := 0.04
const CUT_DROP := 0.15

## Speed threshold (m/s) when the model has no Bird parent to read.
var min_speed := 14.0
## Ribbon width at the tip, as a fraction of the wingspan.
var width := 0.035
var color := Color(1, 1, 1, 0.32)

var _model: BirdModel
var _mesh := ImmediateMesh.new()
var _mi: MeshInstance3D
# Ring buffers per tip (0 right, 1 left): point i of tip s at s * POINTS + i.
var _pts := PackedVector3Array()
var _age := PackedFloat32Array()
var _head := 0
var _count := 0
var _last_pos := Vector3.INF
var _speed := 0.0
var _strength := 0.0
var _drawn := false
# The Bird's cruise speed, refreshed when its mass changes.
var _cruise := 0.0
var _cruise_mass := -1.0
# This trail's camera distance when it last wanted to draw (budget ranking);
# INF until it has asked once, so a trail is ranked (and can be admitted over
# nearer ones) only from the frame after it first wants to draw.
var _want_d := INF
## The ranking frame this trail last asked in.
var _asked := -1

static var _material: StandardMaterial3D
# Nearest-first budget: distances of the trails that wanted to draw, per
# frame (BirdBatch.syncs counts drawn frames); last frame's ranking decides.
static var _want_frame := -1
static var _rank_frame := 0
static var _want_now := PackedFloat32Array()
static var _cutoff := INF


func _ready() -> void:
	_model = get_parent() as BirdModel
	_pts.resize(POINTS * 2)
	_age.resize(POINTS)
	_mi = MeshInstance3D.new()
	_mi.mesh = _mesh
	_mi.top_level = true
	_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_mi.material_override = _trail_material()
	_mi.visible = false
	add_child(_mi)
	_mi.global_transform = Transform3D.IDENTITY


## 0..1: how strongly the trails show right now.
func strength() -> float:
	return _strength


## Current ribbon length in points (per tip).
func point_count() -> int:
	return _count


func _process(delta: float) -> void:
	step(delta)


func step(delta: float) -> void:
	if _model == null or delta <= 0.0:
		return
	var p := _model.global_position
	if _last_pos != Vector3.INF:
		_speed = lerpf(_speed, p.distance_to(_last_pos) / delta, 1.0 - exp(-delta / 0.1))
	_last_pos = p
	var target := 0.0
	var bird := _model.get_parent() as Bird
	if bird != null:
		if bird.mass != _cruise_mass:
			_cruise_mass = bird.mass
			_cruise = float(SizeRules.performance(bird.mass)["cruise"])
		# A Bird knows its true speed; the position delta is the fallback.
		if bird.velocity.length_squared() > 0.0:
			_speed = bird.velocity.length()
		target = clampf((_speed / _cruise - START_AT) / (FULL_AT - START_AT), 0.0, 1.0)
	else:
		target = clampf((_speed - min_speed) / (min_speed * 0.4), 0.0, 1.0)
	var cut := false
	if target > 0.0 and not _within_budget(p):
		target = 0.0
		cut = true
	elif target <= 0.0:
		# Not wanting to draw: next time it asks it starts unranked again.
		_want_d = INF
	_strength = lerpf(_strength, target, 1.0 - exp(-delta / (CUT_FADE if cut else 0.15)))
	if cut and _strength < CUT_DROP:
		# Out of the budget and too faint to see: drop it now rather than
		# rebuild a strip nobody sees.
		_strength = 0.0
		_count = 0
	if _count == 0 and _strength <= 0.02:
		# Nothing showing and nothing to show: done.
		if _drawn:
			_mesh.clear_surfaces()
			_mi.visible = false
			_drawn = false
		return
	# Age the points and drop the expired ones (the oldest end).
	for k in _count:
		_age[(_head - 1 - k + POINTS) % POINTS] += delta
	while _count > 0 and _age[(_head - _count + POINTS) % POINTS] > LIFE:
		_count -= 1
	if _strength > 0.02:
		_pts[_head] = _model.get_wingtip(1)
		_pts[POINTS + _head] = _model.get_wingtip(-1)
		_age[_head] = 0.0
		_head = (_head + 1) % POINTS
		_count = mini(_count + 1, POINTS)
	_rebuild()


## True when this trail is among the MAX_ACTIVE nearest to the camera that
## wanted to draw last frame.
func _within_budget(p: Vector3) -> bool:
	# A new ranking frame starts when a trail asks a second time (every trail
	# asks at most once a frame), or when the birds have synced since (once
	# per drawn frame): so the list holds one frame's trails, drawn or not,
	# headless or stepped by hand.
	if _asked == _rank_frame or BirdBatch.syncs != _want_frame or _want_now.size() >= MAX_WANT:
		_want_frame = BirdBatch.syncs
		_rank_frame += 1
		_cutoff = INF
		if _want_now.size() > MAX_ACTIVE:
			_want_now.sort()
			_cutoff = _want_now[MAX_ACTIVE - 1]
		_want_now.clear()
	_asked = _rank_frame
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	var d := p.distance_to(cam.global_position) if cam else 0.0
	_want_now.append(d)
	# Ranked on last frame's distances, this trail's included (comparing
	# today's distance with yesterday's cutoff would flicker at the edge).
	var ok := _want_d <= _cutoff
	_want_d = d
	return ok


## Both ribbons as one triangle strip (joined by two degenerate vertices),
## facing the camera, fading and thinning with age.
func _rebuild() -> void:
	_mesh.clear_surfaces()
	if _count < 2:
		_mi.visible = false
		_drawn = false
		return
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	var eye := cam.global_position if cam else Vector3(0, 1000, 0)
	var w := width * _model.global_transform.basis.x.length() * 0.5
	_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	for s in 2:
		var base := s * POINTS
		var prev := Vector3.INF
		for k in _count:
			# Oldest to newest.
			var i := (_head - _count + k + POINTS) % POINTS
			var a := _pts[base + i]
			var nxt := _pts[base + (i + 1) % POINTS] if k < _count - 1 else a
			var dir := (nxt - a) if k < _count - 1 else (a - prev)
			if dir.length_squared() < 1e-12:
				dir = Vector3.FORWARD
			var side := dir.cross(eye - a).normalized() * w
			var ka := 1.0 - clampf(_age[i] / LIFE, 0.0, 1.0)
			var c := Color(color.r, color.g, color.b, color.a * ka * _strength)
			var off := side * ka
			if s == 1 and k == 0:
				# Degenerate join from the first ribbon's end.
				_mesh.surface_set_color(c)
				_mesh.surface_add_vertex(a - off)
			_mesh.surface_set_color(c)
			_mesh.surface_add_vertex(a - off)
			_mesh.surface_set_color(c)
			_mesh.surface_add_vertex(a + off)
			if s == 0 and k == _count - 1:
				_mesh.surface_set_color(c)
				_mesh.surface_add_vertex(a + off)
			prev = a
	_mesh.surface_end()
	_mi.visible = true
	_drawn = true


static func _trail_material() -> StandardMaterial3D:
	if _material == null:
		_material = StandardMaterial3D.new()
		_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_material.vertex_color_use_as_albedo = true
		_material.cull_mode = BaseMaterial3D.CULL_DISABLED
		_material.no_depth_test = false
		_material.resource_name = "WingTrailMaterial"
	return _material
