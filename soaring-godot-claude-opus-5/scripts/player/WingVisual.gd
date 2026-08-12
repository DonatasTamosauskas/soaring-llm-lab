class_name WingVisual
extends Node3D

## The wing the player actually sees, growing outward from one hand.
##
## This is not decoration. Every control in the game is expressed through the
## angle and spread of the wings, and a player cannot fly a surface they cannot
## see. Watching the membrane tilt as you roll your wrist is what turns an
## abstract "angle of attack" number into something you can aim.
##
## Built as one continuous swept, tapered, washed-out planform plus a few splayed
## primaries at the tip. A single mesh, one draw call, and — unlike a row of
## separate slabs — an actual surface rather than a staircase of gaps.

const STATIONS: int = 8
const ROOT_CHORD: float = 0.40
const TIP_CHORD: float = 0.17
const LENGTH: float = 1.30
## Wings sweep back hard. A wing drawn straight out from the hand sits across
## the middle of the view, and the one thing a bird must see is where it is
## going.
const SWEEP: float = 0.42
## Wings ride slightly below the hands, out of the forward sightline.
const DROP: float = 0.10
## Twist toward the tip. Real wings wash out, and the changing highlight along
## the span is what makes roll readable at a glance.
const WASHOUT: float = 0.20
## How far back the wing sweeps when fully tucked, in radians.
const FOLD_ANGLE: float = 1.15

## Which hand this wing belongs to: -1 for left, +1 for right.
var side: float = 1.0

var _surface: MeshInstance3D
var _primaries: Node3D
var _material: StandardMaterial3D
var _span: float = 1.0


func build(which_side: float, tint: Color) -> void:
	side = signf(which_side) if which_side != 0.0 else 1.0
	_material = _make_material(tint)

	_surface = MeshInstance3D.new()
	_surface.mesh = _build_membrane()
	_surface.material_override = _material
	# No shadow casting: a surface this close to the eye throws a shadow across
	# the player's own view every time the sun swings around.
	_surface.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_surface)

	_build_primaries(tint)


func _make_material(tint: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = tint
	m.roughness = 0.85
	m.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	# Wings are usually seen from underneath, backlit by the sky, where a purely
	# lit material collapses to a black silhouette. A little self-illumination
	# keeps them readable at every attitude without looking like neon.
	m.emission_enabled = true
	m.emission = tint
	m.emission_energy_multiplier = 0.30
	# Visible from underneath as well as above — you spend a lot of this game
	# looking up at your own wings from the inside of a turn.
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m


## Chord, sweep, droop and twist at a fractional distance [param u] along the
## span. One place to change the wing's shape.
func _station(u: float) -> Dictionary:
	var chord: float = lerpf(ROOT_CHORD, TIP_CHORD, u * u * 0.6 + u * 0.4)
	var twist: float = -side * WASHOUT * u * u
	var centre := Vector3(side * LENGTH * u, -DROP * u * u, SWEEP * u * u)
	return {"chord": chord, "twist": twist, "centre": centre}


func _edge(u: float, fore: bool) -> Vector3:
	var s: Dictionary = _station(u)
	var chord: float = s["chord"]
	var twist: float = s["twist"]
	var offset: float = -chord * 0.5 if fore else chord * 0.5
	# Twisting about the span axis lifts one edge and drops the other.
	return (s["centre"] as Vector3) + Vector3(0.0, offset * sin(twist), offset * cos(twist))


func _build_membrane() -> ArrayMesh:
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in STATIONS:
		var u0: float = float(i) / float(STATIONS)
		var u1: float = float(i + 1) / float(STATIONS)
		var a: Vector3 = _edge(u0, true)
		var b: Vector3 = _edge(u1, true)
		var c: Vector3 = _edge(u1, false)
		var d: Vector3 = _edge(u0, false)
		# Wound so the outward face is consistent on both wings.
		if side > 0.0:
			_quad(tool, a, b, c, d)
		else:
			_quad(tool, d, c, b, a)
	tool.generate_normals()
	return tool.commit()


func _quad(tool: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	for v: Vector3 in [a, b, c, a, c, d]:
		tool.add_vertex(v)


## Splayed primaries at the wingtip. Purely for silhouette, but the silhouette
## is what the player reads out of the corner of their eye at 50 m/s.
func _build_primaries(tint: Color) -> void:
	_primaries = Node3D.new()
	add_child(_primaries)
	var tip: Vector3 = _station(1.0)["centre"]
	for i in 3:
		var t: float = float(i) / 2.0
		var mesh := BoxMesh.new()
		mesh.size = Vector3(0.30, 0.018, 0.075)

		var feather := MeshInstance3D.new()
		feather.mesh = mesh
		feather.material_override = _material
		feather.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		feather.position = tip + Vector3(side * 0.15, -0.01, lerpf(-0.05, 0.11, t))
		feather.rotation = Vector3(0.0, side * lerpf(-0.22, 0.30, t), -side * 0.26)
		_primaries.add_child(feather)


## [param span] is the same 0..1 wing extension the flight model uses, so the
## wings visibly fold when the player tucks to dive. Folding both shortens and
## sweeps the wing back, which reads as a tuck rather than as the mesh shrinking.
func set_span(span: float, delta: float) -> void:
	if not is_finite(span):
		return
	_span = lerpf(_span, clampf(span, 0.0, 1.0), clampf(delta * 9.0, 0.0, 1.0))
	var extension: float = lerpf(0.22, 1.0, _span)
	scale = Vector3(extension, 1.0, lerpf(0.7, 1.0, _span))
	rotation.y = -side * FOLD_ANGLE * (1.0 - _span)


func set_tint(colour: Color) -> void:
	if _material != null:
		_material.albedo_color = colour
		_material.emission = colour
