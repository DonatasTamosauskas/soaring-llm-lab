class_name WingVisual
extends Node3D

## The wing the player actually sees, growing outward from one hand.
##
## This is not decoration. Every control in the game is expressed through the
## angle and spread of the wings, and a player cannot fly a surface they cannot
## see. Watching the membrane tilt as you roll your wrist is what turns an
## abstract "angle of attack" number into something you can aim.
##
## The geometry is the same [BirdMesh] wing every other bird in the game wears,
## scaled from the species' own span to the player's arm — layered coverts,
## scalloped secondaries, splayed primaries, dark tips, pale underside, and the
## same single shared material. The player is made of the same stuff as the
## things they are eating, and when they grow into a new size class their own
## wings change shape to say so.

## How far the wing reaches from the hand, in metres, before the rig's size scale
## is applied. Set by the player's arm rather than by the bird: a wing that does
## not reach where your hand reaches feels detached from you.
const LENGTH: float = 1.30
## Wings ride slightly below the hands, out of the forward sightline.
const DROP: float = 0.10
## Tilted down and back a little at the shoulder, which is where a hand held out
## flat actually wants a wing to be.
const ANHEDRAL: float = 0.12
## How far back the wing sweeps when fully tucked, in radians.
const FOLD_ANGLE: float = 1.15
## Spanwise bend of the primaries when the wing is fully tucked. The player's
## hand cannot fold a wrist, so the feathers do it for them.
const TUCK_BEND: float = 0.55
## How far the primaries flex up on a hard downstroke, in metres.
const TIP_LIFT: float = 0.09
const REFERENCE_STROKE: float = 3.2

## Which hand this wing belongs to: -1 for left, +1 for right.
var side: float = 1.0
var species: BirdMesh.Species = BirdMesh.Species.FALCON

var _surface: MeshInstance3D
var _tint: Color = Palette.colour("plumage_player")
var _span: float = 1.0
var _stroke: float = 0.0


func build(
	which_side: float, tint: Color,
	wing_species: BirdMesh.Species = BirdMesh.Species.FALCON
) -> void:
	side = signf(which_side) if which_side != 0.0 else 1.0
	species = wing_species
	_tint = tint

	_surface = MeshInstance3D.new()
	_surface.name = "Membrane"
	_surface.mesh = BirdMesh.wing_mesh(species, side)
	_surface.material_override = BirdMesh.material()
	# No shadow casting: a surface this close to the eye throws a shadow across
	# the player's own view every time the sun swings around.
	_surface.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_surface)

	position = Vector3(0.0, -DROP, 0.0)
	rotation = Vector3(0.0, 0.0, -side * ANHEDRAL)
	set_tint(tint)
	_apply()


## The player's wings follow their own size class, so growing into a raptor is
## something you can see by looking at your own arm.
func set_species(new_species: BirdMesh.Species) -> void:
	if new_species == species or _surface == null:
		return
	species = new_species
	_surface.mesh = BirdMesh.wing_mesh(species, side)
	_apply()


## [param span] is the same 0..1 wing extension the flight model uses, so the
## wings visibly fold when the player tucks to dive. Folding both shortens and
## sweeps the wing back, which reads as a tuck rather than as the mesh shrinking.
## [param stroke] is the commanded downstroke speed, which flexes the primaries.
func set_span(span: float, delta: float, stroke: float = 0.0) -> void:
	if not is_finite(span) or not is_finite(delta):
		return
	_span = lerpf(_span, clampf(span, 0.0, 1.0), clampf(delta * 9.0, 0.0, 1.0))
	_stroke = clampf(
		(stroke if is_finite(stroke) else 0.0) / REFERENCE_STROKE, 0.0, 1.0
	)
	_apply()


func set_tint(colour: Color) -> void:
	_tint = colour
	if _surface != null:
		_surface.set_instance_shader_parameter("plumage", colour)


func _apply() -> void:
	if _surface == null:
		return
	# The species' own span is normalised away, so a falcon wing and an eagle
	# wing both reach exactly as far as the player's arm does — only their
	# shape changes.
	var reach: float = LENGTH / maxf(float(BirdMesh.profile(species)["span"]), 0.01)
	var extension: float = lerpf(0.22, 1.0, _span)
	_surface.scale = Vector3(reach * extension, reach, reach * lerpf(0.7, 1.0, _span))
	rotation = Vector3(0.0, -side * FOLD_ANGLE * (1.0 - _span), -side * ANHEDRAL)
	_surface.set_instance_shader_parameter("flex", Vector4(
		side * TUCK_BEND * (1.0 - _span),
		TIP_LIFT * (0.3 + _stroke),
		0.0, 0.0
	))
