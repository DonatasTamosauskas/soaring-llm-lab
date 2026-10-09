class_name UIPointer
extends Node3D

## The ray a player points at a menu with, and the dot where it lands.
##
## A beam plus a dot rather than a beam alone: the beam says which hand is
## driving, the dot says exactly where, and the dot is the part people actually
## aim with. The beam stops at the panel instead of passing through it, which is
## the difference between pointing at something and shining a torch past it.

const BEAM_RADIUS: float = 0.0035
const DOT_RADIUS: float = 0.010
const MAX_LENGTH: float = 6.0

var _beam: MeshInstance3D
var _dot: MeshInstance3D


func _ready() -> void:
	if _beam != null:
		return
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = BEAM_RADIUS
	cylinder.bottom_radius = BEAM_RADIUS
	cylinder.height = 1.0
	cylinder.radial_segments = 6
	cylinder.rings = 0
	cylinder.cap_top = false
	cylinder.cap_bottom = false
	_beam = MeshInstance3D.new()
	_beam.mesh = cylinder
	_beam.material_override = UITheme.quad_material("beam", MenuPanel.BAR_PRIORITY)
	_beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_beam.extra_cull_margin = 8.0
	add_child(_beam)

	var sphere := SphereMesh.new()
	sphere.radius = DOT_RADIUS
	sphere.height = DOT_RADIUS * 2.0
	sphere.radial_segments = 8
	sphere.rings = 4
	_dot = MeshInstance3D.new()
	_dot.mesh = sphere
	_dot.material_override = UITheme.quad_material("dot", MenuPanel.BAR_PRIORITY + 2)
	_dot.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_dot.extra_cull_margin = 8.0
	add_child(_dot)


## Points the beam along -Z of this node, ending [param length] metres out.
## [param landed] draws the dot; a beam that ends in nothing tells the player
## they are pointing at nothing, which is information worth keeping.
func aim(length: float, landed: bool, with_beam: bool = true) -> void:
	if _beam == null:
		_ready()
	var reach: float = clampf(length if is_finite(length) else MAX_LENGTH, 0.05, MAX_LENGTH)
	# The cylinder is built along +Y, so stand it up along -Z and stretch it.
	_beam.rotation = Vector3(-PI * 0.5, 0.0, 0.0)
	_beam.scale = Vector3(1.0, reach, 1.0)
	_beam.position = Vector3(0.0, 0.0, -reach * 0.5)
	_beam.visible = with_beam
	_dot.position = Vector3(0.0, 0.0, -reach if with_beam else 0.0)
	_dot.visible = landed


func set_shown(shown: bool) -> void:
	visible = shown
